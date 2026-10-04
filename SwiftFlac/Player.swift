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

    init(_ type: MPRepeatType) {
        switch type {
        case .one: self = .one
        case .all: self = .all
        default: self = .off
        }
    }

    var remoteType: MPRepeatType {
        switch self {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }
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
    /// The track `nowPlaying` describes; nil while a new track's metadata loads.
    private(set) var nowPlayingSource: URL?
    private(set) var audioQuality: AudioQuality?
    @ObservationIgnored let spectrum = SpectrumMonitor()
    /// AirPlay's delay puts the bars out of sync, so the visualiser hides.
    private(set) var isAirPlaying = false
    static let visualizerKey = "showVisualizer"
    /// Taps the decoded audio for the visualiser; off costs nothing.
    var visualizerEnabled = false {
        didSet {
            player.spectrum = visualizerEnabled ? spectrum.buffer : nil
        }
    }

    private(set) var isShuffling = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private let player: any PlaybackTransport
    private let defaults: UserDefaults
    private let systemIntegration: Bool
    private let metadataLoader: @Sendable (Track) async -> TrackMetadata
    private let qualityLoader: @Sendable (URL) async -> AudioQuality?
    private let playbackActivation: PlaybackActivation
    private let now: () -> Date
    /// Bumped per track, so late async results for an earlier one are dropped.
    private var loadToken = 0
    @ObservationIgnored private(set) var nowPlayingInfo: [String: Any]?
    private static let logger = Logger(subsystem: "com.kfurman.SwiftFlac", category: "Playback")

    private var originalQueue: [Track] = []
    private var timeUpdates: Timer?
    @ObservationIgnored private(set) var metadataTask: Task<Void, Never>?
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

    /// Scanned tags stand in while a new track's metadata loads, so the text never blanks.
    var displayArtist: String? {
        nowPlaying.artist ?? currentTrack?.artist
    }

    var displayAlbum: String? {
        nowPlaying.album ?? currentTrack?.album
    }

    init(
        transport: (any PlaybackTransport)? = nil,
        defaults: UserDefaults = .standard,
        systemIntegration: Bool = true,
        activate: @escaping @Sendable () async throws -> Void = PlaybackAudioSession.activate,
        metadataLoader: @escaping @Sendable (Track) async -> TrackMetadata = loadMetadata,
        qualityLoader: @escaping @Sendable (URL) async -> AudioQuality? = AudioQuality.read,
        now: @escaping () -> Date = Date.init
    ) {
        player = transport ?? AudioRendererTransport()
        self.defaults = defaults
        self.systemIntegration = systemIntegration
        self.metadataLoader = metadataLoader
        self.qualityLoader = qualityLoader
        self.now = now
        playbackActivation = PlaybackActivation(activate: activate)
        isShuffling = defaults.bool(forKey: Self.shuffleKey)
        repeatMode = defaults.string(forKey: Self.repeatKey)
            .flatMap(RepeatMode.init(rawValue:)) ?? .off
        visualizerEnabled = defaults.object(forKey: Self.visualizerKey) as? Bool ?? true
        player.onEvent = { [weak self] event in self?.handle(event) }
        spectrum.playbackPosition = { [weak self] in
            guard let self, isPlaying else { return nil }
            return player.currentTime
        }
        guard systemIntegration else { return }
        configureRemoteCommands()
        publishPlaybackModes()
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
            updateAirPlayRoute()
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let deviceGone = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init) == .oldDeviceUnavailable
                MainActor.assumeIsolated {
                    self?.updateAirPlayRoute()
                    // Unplugged headphones must not switch to the speaker mid-song.
                    if deviceGone, self?.isPlaying == true {
                        self?.pausePlayback()
                    }
                }
            }
        #endif
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case let .loaded(duration):
            self.duration = duration
            consecutiveFailures = 0
            updateNowPlayingInfo()
        case .failed:
            currentTrackFailed()
        case .finished:
            trackFinished()
        }
    }

    /// Twice a second while playing, with slack so the system can batch the wakeups.
    private func startTimeUpdates() {
        guard systemIntegration, timeUpdates == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePlaybackTime(self.player.currentTime)
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        timeUpdates = timer
    }

    private func stopTimeUpdates() {
        timeUpdates?.invalidate()
        timeUpdates = nil
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
        stopTimeUpdates()
        currentTime = player.currentTime
        isPlaying = false
        updateNowPlayingInfo()
        saveSession()
    }

    private func resumePlayback() {
        guard currentTrack != nil else { return }
        let token = loadToken
        // Reflect the requested state immediately so Pause also works while
        // activation is pending. Audio starts only after activation succeeds.
        isPlaying = true
        playbackActivation.request { [weak self] in
            guard let self, isPlaying, token == loadToken else { return }
            player.play()
            startTimeUpdates()
            updateNowPlayingInfo()
        } onFailure: { [weak self] error in
            guard let self, token == loadToken else { return }
            pausePlayback()
            Self.logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
        updateNowPlayingInfo()
        saveSession()
    }

    /// Starts `tracks` in the given mode without first reshuffling the queue being replaced.
    func play(_ track: Track, in tracks: [Track], shuffled: Bool) {
        if shuffled != isShuffling {
            storeShuffle(shuffled)
        }
        play(track, in: tracks)
    }

    private func storeShuffle(_ enabled: Bool) {
        isShuffling = enabled
        defaults.set(isShuffling, forKey: Self.shuffleKey)
        publishPlaybackModes()
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
        setShuffle(!isShuffling)
    }

    func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffling else { return }
        storeShuffle(enabled)
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
        case .off: setRepeatMode(.all)
        case .all: setRepeatMode(.one)
        case .one: setRepeatMode(.off)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        defaults.set(repeatMode.rawValue, forKey: Self.repeatKey)
        publishPlaybackModes()
    }

    /// Siri and accessories read the current modes from the command center.
    private func publishPlaybackModes() {
        guard systemIntegration else { return }
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = isShuffling ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = repeatMode.remoteType
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
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
        guard currentTrack != nil, time.isFinite else { return }
        // Scrubbing into the last second means jump straight to the
        // end-of-track behaviour.
        if duration > 0, time >= duration - 1 {
            trackFinished()
            return
        }
        let target = min(max(0, time), max(duration - 0.1, 0))
        player.seek(to: target)
        currentTime = target
        updateNowPlayingInfo()
        saveSessionTime()
    }

    func updatePlaybackTime(_ seconds: Double) {
        guard seconds.isFinite else { return }
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
            guard currentTrack != nil else { return }
            player.seek(to: 0)
            currentTime = 0
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
        loadToken += 1
        let token = loadToken
        playbackActivation.cancel()
        spectrum.reset()
        currentTime = startTime
        duration = 0
        // Loading leaves the transport paused; playback waits for the audio session below.
        player.load(track.url, at: startTime)
        if paused {
            isPlaying = false
            stopTimeUpdates()
        }
        if !paused {
            resumePlayback()
        }
        saveSession()
        guard reloadMetadata else {
            updateNowPlayingInfo()
            return
        }
        nowPlaying = TrackMetadata()
        nowPlayingSource = nil
        updateNowPlayingInfo()
        metadataTask = Task {
            let metadata = await metadataLoader(track)
            guard token == loadToken else { return }
            nowPlaying = metadata
            nowPlayingSource = track.url
            updateNowPlayingInfo()
            // After the metadata, so it never competes with loading the cover. The previous
            // track's value stays until then, so the line updates in place.
            let quality = await qualityLoader(track.url)
            guard token == loadToken else { return }
            audioQuality = quality
        }
    }

    #if os(iOS)
        private func updateAirPlayRoute() {
            isAirPlaying = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        }
    #endif

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
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let enabled = event.shuffleType != .off
            Task { @MainActor in self?.setShuffle(enabled) }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode = RepeatMode(event.repeatType)
            Task { @MainActor in self?.setRepeatMode(mode) }
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
        if let artist = displayArtist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = displayAlbum {
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
