import AVFoundation
import Foundation
@testable import SwiftFlac
import Testing

final class TestStore: @unchecked Sendable {
    let root: URL
    /// An absolute suite path keeps the plist inside `root`, so cleanup removes it.
    let suite: String
    var defaults: UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    var cache: URL {
        root.appendingPathComponent("cache.json")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = root.appendingPathComponent("defaults").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ name: String, data: Data = Data()) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}

private final class FixtureBundle {}
func fixture(_ name: String) throws -> URL {
    try #require(Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

@MainActor
func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), sourceLocation: sourceLocation)
}

actor AsyncGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.forEach { $0.resume() }
            entered.removeAll()
        }
    }

    func waitUntilEntered() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { entered.append($0) }
    }

    func finish(_ value: Value) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

@MainActor
final class FakeTransport: PlaybackTransport {
    var onEvent: ((PlaybackEvent) -> Void)?
    var spectrum: SpectrumBuffer?
    var currentTime: TimeInterval = 0
    var loads: [(url: URL, time: TimeInterval)] = []
    var plays = 0
    var pauses = 0
    var seeks: [TimeInterval] = []
    /// Reported after each load, as the engine does once the file is open.
    var loadedDuration: TimeInterval = 120

    func load(_ url: URL, at time: TimeInterval) {
        loads.append((url, time))
        currentTime = time
        let duration = loadedDuration
        Task { @MainActor in self.onEvent?(.loaded(duration: duration)) }
    }

    func play() {
        plays += 1
    }

    func pause() {
        pauses += 1
    }

    func seek(to time: TimeInterval) {
        seeks.append(time)
        currentTime = time
    }
}

@MainActor
func testPlayer(_ store: TestStore, transport: FakeTransport = FakeTransport(),
                activate: @escaping @Sendable () async throws -> Void = {},
                now: @escaping () -> Date = Date.init) -> PlayerController
{
    PlayerController(transport: transport, defaults: store.defaults, systemIntegration: false,
                     activate: activate, metadataLoader: { TrackMetadata(title: $0.title, artist: $0.artist, album: $0.album) },
                     now: now)
}

func testTracks(root: URL, count: Int = 3) -> [Track] {
    (1 ... count).map { Track(url: root.appendingPathComponent("\($0).flac"), title: "Song \($0)", artist: "Artist", album: "Album", trackNumber: $0) }
}
