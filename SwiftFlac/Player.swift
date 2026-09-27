import AVFoundation
import MediaPlayer
import Observation
import OSLog
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

enum RepeatMode: String {
    case off, all, one
}

/// Carries the cover into MediaPlayer's artwork handler. That handler runs on
/// MediaPlayer's own queue, so the closure must not inherit the main-actor
/// isolation of the code building it; the image is only read there, which both
/// platforms allow off the main thread.
private struct DetachedArtwork: @unchecked Sendable {
    #if canImport(UIKit)
        let image: UIImage
    #else
        let image: NSImage
    #endif

    var mediaItemArtwork: MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}

@MainActor
@Observable
final class PlayerController {
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var nowPlaying = TrackMetadata()
    private(set) var isShuffling = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private let player: any PlaybackTransport
    private let defaults: UserDefaults
    private let systemIntegration: Bool
    private let metadataLoader: @Sendable (Track) async -> TrackMetadata
    private let durationLoader: @MainActor (AVPlayerItem) async -> Double
    private let playbackActivation: PlaybackActivation
    private let now: () -> Date
    private var seekGeneration = 0
    @ObservationIgnored private(set) var nowPlayingInfo: [String: Any]?
    private static let logger = Logger(subsystem: "com.kfurman.SwiftFlac", category: "Playback")
    /// The macOS route picker needs the player reference to offer AirPlay.
    var routePickerPlayer: AVPlayer? {
        player.avPlayer
    }

    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private var isSeeking = false
    @ObservationIgnored private(set) var metadataTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var consecutiveFailures = 0
    private var resumeAfterInterruption = false

    private static let shuffleKey = "playerShuffle"
    private static let repeatKey = "playerRepeatMode"
    private static let sessionQueueKey = "sessionQueuePaths"
    private static let sessionOriginalQueueKey = "sessionOriginalQueuePaths"
    private static let sessionTrackKey = "sessionTrackPath"
    private static let sessionTimeKey = "sessionTime"

    private var hasRestoredSession = false
    private var lastSessionSave = Date.distantPast

    /// Set before session restore; sessions persist root-relative paths
    /// because the app's container path changes across updates.
    var libraryRoot: URL?

    private func sessionKey(for url: URL) -> String {
        NavigationPersistence.relativePath(url, root: libraryRoot)
    }

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var displayTitle: String {
        nowPlaying.title ?? currentTrack?.displayTitle ?? ""
    }

    init(
        transport: (any PlaybackTransport)? = nil,
        defaults: UserDefaults = .standard,
        systemIntegration: Bool = true,
        activate: @escaping @Sendable () async throws -> Void = PlaybackAudioSession.activate,
        metadataLoader: @escaping @Sendable (Track) async -> TrackMetadata = loadMetadata,
        durationLoader: @escaping @MainActor (AVPlayerItem) async -> Double = {
            await (try? $0.asset.load(.duration))?.seconds ?? 0
        },
        now: @escaping () -> Date = Date.init
    ) {
        player = transport ?? AVPlayer()
        self.defaults = defaults
        self.systemIntegration = systemIntegration
        self.metadataLoader = metadataLoader
        self.durationLoader = durationLoader
        self.now = now
        playbackActivation = PlaybackActivation(activate: activate)
        isShuffling = defaults.bool(forKey: Self.shuffleKey)
        repeatMode = defaults.string(forKey: Self.repeatKey)
            .flatMap(RepeatMode.init(rawValue:)) ?? .off
        guard systemIntegration, let livePlayer = player.avPlayer else { return }
        configureRemoteCommands()
        #if os(macOS)
            // Focused lists swallow bare Space (scroll page-down) before menu
            // shortcuts see it, so play/pause is handled app-wide here instead.
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // NSEvent is not Sendable, so the two values the handler needs
                // are read out here rather than letting the event itself cross
                // into the main-actor block.
                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self,
                          keyCode == 49, // space
                          modifiers.intersection([.command, .option, .control]).isEmpty,
                          !(NSApp.keyWindow?.firstResponder is NSText),
                          self.currentTrack != nil
                    else { return false }
                    self.togglePlayPause()
                    return true
                }
                return handled ? nil : event
            }
        #endif

        timeObserver = livePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.updatePlaybackTime(time.seconds)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Notification is not Sendable, so only the identity of the item
            // that finished crosses to the main actor - which is all the
            // `item === player.currentItem` check ever needed.
            let finished = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self, let finished,
                      let current = self.player.currentItem,
                      ObjectIdentifier(current) == finished else { return }
                self.trackFinished()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let failed = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            Task { @MainActor in
                guard let self, let failed,
                      let current = self.player.currentItem,
                      ObjectIdentifier(current) == failed else { return }
                self.currentTrackFailed()
            }
        }
        #if os(iOS)
            // Another app taking the audio session pauses the player
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
                MainActor.assumeIsolated {
                    self?.handleInterruption(began: type == .began, shouldResume: shouldResume)
                }
            }
        #endif
    }

    func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            guard isPlaying else { return }
            resumeAfterInterruption = true
            pausePlayback()
        } else {
            let resume = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            // Interruptions that end without shouldResume (another app
            // took over as the primary audio source) stay paused.
            guard resume, currentTrack != nil else { return }
            resumePlayback()
        }
    }

    private func pausePlayback() {
        playbackActivation.cancel()
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
        saveSession()
    }

    private func resumePlayback() {
        guard let item = player.currentItem else { return }
        // Reflect the requested state immediately so Pause also works while
        // activation is pending. AVPlayer starts only after activation succeeds.
        isPlaying = true
        playbackActivation.request { [weak self] in
            guard let self, isPlaying, item === player.currentItem else { return }
            player.play()
            updateNowPlayingInfo()
        } onFailure: { [weak self] error in
            guard let self, item === player.currentItem else { return }
            pausePlayback()
            Self.logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
        updateNowPlayingInfo()
        saveSession()
    }

    func play(_ track: Track, in tracks: [Track]) {
        guard tracks.contains(track) else { return }
        consecutiveFailures = 0
        originalQueue = tracks
        if isShuffling {
            var rest = tracks.filter { $0 != track }
            rest.shuffle()
            queue = [track] + rest
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = tracks.firstIndex(of: track)
        }
        startCurrentTrack()
    }

    func toggleShuffle() {
        isShuffling.toggle()
        defaults.set(isShuffling, forKey: Self.shuffleKey)
        guard let current = currentTrack else { return }
        if isShuffling {
            var rest = queue.filter { $0 != current }
            rest.shuffle()
            queue = [current] + rest
            currentIndex = 0
        } else {
            queue = originalQueue
            currentIndex = originalQueue.firstIndex(of: current)
        }
        saveSession()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        defaults.set(repeatMode.rawValue, forKey: Self.repeatKey)
    }

    func togglePlayPause() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func next() {
        advance(by: 1)
    }

    func previous() {
        // Restart the current track unless we're right at its start.
        if currentTime > 3 {
            seek(to: 0)
        } else {
            advance(by: -1)
        }
    }

    func seek(to time: TimeInterval) {
        guard let item = player.currentItem, time.isFinite else { return }
        seekGeneration += 1
        let generation = seekGeneration
        // Scrubbing into the last second means jump straight to the
        // end-of-track behaviour.
        if duration > 0, time >= duration - 1 {
            // The bump above orphans any in-flight seek, and stopping at the queue end starts none.
            isSeeking = false
            trackFinished()
            return
        }
        let target = min(max(0, time), max(duration - 0.1, 0))
        // Freeze observer updates until the async seek lands, otherwise the
        // slider briefly snaps back to the pre-seek position.
        isSeeking = true
        currentTime = target
        // Sample-exact seeks can wedge near the end of a FLAC; allow slack
        // before the target (never after, so we can't trip the track end).
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, item === self.player.currentItem,
                      generation == self.seekGeneration else { return }
                self.isSeeking = false
                // Republish once the seek lands: the tolerance means the
                // player can settle before the target, and nothing else
                // refreshes the lock screen until the next track change.
                let landed = self.player.currentTime().seconds
                self.currentTime = landed.isFinite ? landed : target
                self.updateNowPlayingInfo()
                self.saveSessionTime()
            }
        }
        updateNowPlayingInfo()
    }

    func updatePlaybackTime(_ seconds: Double) {
        guard !isSeeking, seconds.isFinite else { return }
        currentTime = max(0, seconds)
        if now().timeIntervalSince(lastSessionSave) > 5 {
            saveSessionTime()
        }
    }

    private func advance(by offset: Int) {
        guard let currentIndex, !queue.isEmpty else { return }
        var target = currentIndex + offset
        if !queue.indices.contains(target) {
            guard repeatMode == .all else {
                // End of queue: stop but keep the last track visible.
                pausePlayback()
                return
            }
            target = (target + queue.count) % queue.count
        }
        self.currentIndex = target
        startCurrentTrack()
    }

    /// A track that cannot play behaves like one that ended, except it is
    /// never retried (repeat-one would loop on it forever), and a queue
    /// where every track fails stops instead of skip-looping.
    func currentTrackFailed() {
        consecutiveFailures += 1
        guard consecutiveFailures < max(queue.count, 1) else {
            pausePlayback()
            return
        }
        advance(by: 1)
    }

    func trackFinished() {
        if repeatMode == .one {
            guard let item = player.currentItem else { return }
            seekGeneration += 1
            let generation = seekGeneration
            // The seek is async: publishing the reset before it lands leaves
            // the lock screen stuck at the end of the track, so republish from
            // the completion handler once the player really is back at zero.
            isSeeking = true
            currentTime = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, item === self.player.currentItem,
                          generation == self.seekGeneration else { return }
                    self.isSeeking = false
                    self.currentTime = 0
                    self.updateNowPlayingInfo()
                }
            }
            resumePlayback()
        } else {
            advance(by: 1)
        }
    }

    /// Restores the last session's queue and track, paused at the saved
    /// position. Tracks are matched by path against the scanned library;
    /// anything that no longer exists is silently dropped.
    func restoreSession(from tracks: [Track]) {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true
        guard currentTrack == nil,
              let savedTrackPath = defaults.string(forKey: Self.sessionTrackKey) else { return }
        let savedQueuePaths = defaults.stringArray(forKey: Self.sessionQueueKey) ?? []
        let rawTime = defaults.double(forKey: Self.sessionTimeKey)
        let savedTime = rawTime.isFinite ? max(0, rawTime) : 0

        let byPath = Dictionary(tracks.map { (sessionKey(for: $0.url), $0) }, uniquingKeysWith: { first, _ in first })
        let restoredQueue = savedQueuePaths.compactMap { byPath[$0] }
        guard let track = byPath[savedTrackPath],
              let index = restoredQueue.firstIndex(of: track) else { return }

        queue = restoredQueue
        let originalPaths = defaults.stringArray(forKey: Self.sessionOriginalQueueKey) ?? savedQueuePaths
        let restoredOriginal = originalPaths.compactMap { byPath[$0] }
        originalQueue = Set(restoredOriginal.map(\.url)) == Set(restoredQueue.map(\.url))
            ? restoredOriginal : restoredQueue
        currentIndex = index
        startCurrentTrack(paused: true, startTime: savedTime)
    }

    private func saveSession() {
        guard let track = currentTrack else { return }
        defaults.set(queue.map { sessionKey(for: $0.url) }, forKey: Self.sessionQueueKey)
        defaults.set(originalQueue.map { sessionKey(for: $0.url) }, forKey: Self.sessionOriginalQueueKey)
        defaults.set(sessionKey(for: track.url), forKey: Self.sessionTrackKey)
        saveSessionTime()
    }

    /// Progress and seeks only move the time; the queue is saved when it changes.
    private func saveSessionTime() {
        guard currentTrack != nil else { return }
        lastSessionSave = now()
        defaults.set(currentTime, forKey: Self.sessionTimeKey)
    }

    private func startCurrentTrack(reloadMetadata: Bool = true, paused: Bool = false, startTime: TimeInterval = 0) {
        guard let track = currentTrack else { return }
        // Without the precise-timing option AVFoundation only estimates the
        // duration of compressed audio, so tracks outrun their slider.
        let asset = AVURLAsset(url: track.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                switch status {
                case .failed:
                    self.currentTrackFailed()
                case .readyToPlay:
                    self.consecutiveFailures = 0
                default:
                    break
                }
            }
        }
        playbackActivation.cancel()
        seekGeneration += 1
        // Replacing an item on a running AVPlayer can start it immediately.
        // Hold playback until the new request has activated the audio session.
        player.pause()
        player.replaceCurrentItem(with: item)
        if paused {
            isPlaying = false
            if startTime > 0 {
                player.seek(
                    to: CMTime(seconds: startTime, preferredTimescale: 600),
                    toleranceBefore: .positiveInfinity,
                    toleranceAfter: .zero,
                    completionHandler: { _ in }
                )
            }
        }
        isSeeking = false
        currentTime = startTime
        duration = 0
        if !paused {
            resumePlayback()
        }
        saveSession()
        Task {
            let seconds = await durationLoader(item)
            guard item === player.currentItem else { return }
            duration = seconds.isFinite ? seconds : 0
            updateNowPlayingInfo()
        }
        guard reloadMetadata else {
            updateNowPlayingInfo()
            return
        }
        nowPlaying = TrackMetadata()
        updateNowPlayingInfo()
        metadataTask = Task {
            let metadata = await metadataLoader(track)
            guard item === player.currentItem else { return }
            nowPlaying = metadata
            updateNowPlayingInfo()
            // AirPlay receivers read metadata from the item itself, not
            // from MPNowPlayingInfoCenter. (iOS-only API.)
            #if os(iOS)
                item.externalMetadata = externalMetadata(for: track)
            #endif
        }
    }

    func externalMetadata(for track: Track) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        add(.commonIdentifierTitle, (nowPlaying.title ?? track.displayTitle) as NSString)
        add(.commonIdentifierArtist, nowPlaying.artist as NSString?)
        add(.commonIdentifierAlbumName, nowPlaying.album as NSString?)
        add(.commonIdentifierArtwork, nowPlaying.artworkData as NSData?)
        return items
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == false {
                    self?.togglePlayPause()
                }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true {
                    self?.togglePlayPause()
                }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            nowPlayingInfo = nil
            if systemIntegration {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlaying.title ?? track.displayTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = nowPlaying.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = nowPlaying.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        #if canImport(UIKit)
            if let data = nowPlaying.artworkData, let image = UIImage(data: data) {
                info[MPMediaItemPropertyArtwork] = DetachedArtwork(image: image).mediaItemArtwork
            }
        #else
            if let data = nowPlaying.artworkData, let image = NSImage(data: data) {
                info[MPMediaItemPropertyArtwork] = DetachedArtwork(image: image).mediaItemArtwork
            }
        #endif
        nowPlayingInfo = info
        if systemIntegration {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
