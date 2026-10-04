import Foundation
#if os(iOS)
    import AVFAudio
#endif

/// Serializes activation requests and discards completions superseded by a
/// pause, interruption, or track change. Cancellation cannot undo an audio
/// session activation already in progress, so the next request waits for it.
@MainActor
final class PlaybackActivation {
    private var pending: Task<Void, Never>?
    private let activate: @Sendable () async throws -> Void

    init(activate: @escaping @Sendable () async throws -> Void) {
        self.activate = activate
    }

    func cancel() {
        pending?.cancel()
    }

    func request(
        onActivated: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        let previous = pending
        previous?.cancel()
        let activate = activate
        pending = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await activate()
                guard !Task.isCancelled else { return }
                onActivated()
            } catch {
                guard !Task.isCancelled else { return }
                onFailure(error)
            }
        }
    }
}

enum PlaybackAudioSession {
    private enum ActivationError: LocalizedError {
        case declined

        var errorDescription: String? {
            "Audio session activation was declined."
        }
    }

    static func activate() async throws {
        // Category configuration and the pre-iOS 27 synchronous activation
        // must not block the main actor. A plain Task would inherit it.
        #if os(iOS)
            try await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                // Long-form routing gives AirPlay 2 its buffered, multi-room playback.
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                #if compiler(>=6.4)
                    if #available(iOS 27.0, *) {
                        guard try await session.activate() else { throw ActivationError.declined }
                        return
                    }
                #endif
                try session.setActive(true)
            }.value
        #endif
    }
}
