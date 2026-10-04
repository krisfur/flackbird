import AVFAudio

enum PlaybackEvent: Equatable {
    case loaded(duration: TimeInterval)
    case failed
    case finished
}

/// The transport boundary keeps queue and recovery rules independent of audio hardware.
@MainActor
protocol PlaybackTransport: AnyObject {
    /// Reported for the most recent `load` only.
    var onEvent: ((PlaybackEvent) -> Void)? { get set }
    /// Receives decoded audio for the visualiser while set.
    var spectrum: SpectrumBuffer? { get set }
    /// The position being played, exact after a seek.
    var currentTime: TimeInterval { get }
    /// Replaces the current track, paused at `time`.
    func load(_ url: URL, at time: TimeInterval)
    func play()
    func pause()
    func seek(to time: TimeInterval)
}

/// Decodes on its own queue and plays through AVAudioEngine.
@MainActor
final class AudioEngineTransport: PlaybackTransport {
    var onEvent: ((PlaybackEvent) -> Void)?
    var spectrum: SpectrumBuffer? {
        didSet { installTap() }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private lazy var feeder = Feeder(node: node) { [weak self] event in
        Task { @MainActor in self?.handle(event) }
    }
    private var generation = 0
    private var connectedFormat: AVAudioFormat?
    private var sampleRate: Double = 0
    private var length: AVAudioFramePosition = 0
    /// The track frame the node's timeline starts from.
    private var startFrame: AVAudioFramePosition = 0
    /// Reported while the node isn't playing: paused, loading, or seeking.
    private var heldTime: TimeInterval = 0
    private var isLoaded = false
    private var isPrimed = false
    private var wantsPlayback = false

    init() {
        engine.attach(node)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    /// Lets tests play without sound.
    var outputVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    private var duration: TimeInterval {
        sampleRate > 0 ? Double(length) / sampleRate : 0
    }

    var currentTime: TimeInterval {
        guard isPrimed, let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return heldTime }
        return min(max(0, Double(startFrame + playerTime.sampleTime) / sampleRate), duration)
    }

    func load(_ url: URL, at time: TimeInterval) {
        generation += 1
        isLoaded = false
        isPrimed = false
        heldTime = max(0, time)
        feeder.open(url, generation: generation)
    }

    func play() {
        wantsPlayback = true
        guard isLoaded else { return }
        beginPlayback()
    }

    func pause() {
        heldTime = currentTime
        wantsPlayback = false
        isPrimed = false
        generation += 1
        feeder.stop(generation: generation)
        // Releases the audio hardware, as AVPlayer does when paused.
        engine.pause()
    }

    func seek(to time: TimeInterval) {
        heldTime = min(max(0, time), duration)
        guard wantsPlayback, isLoaded else { return }
        beginPlayback()
    }

    /// Pause, seek and route changes all restart from `heldTime`: decoding a fresh
    /// start is a few milliseconds and keeps one path to get right.
    private func beginPlayback() {
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            wantsPlayback = false
            onEvent?(.failed)
            return
        }
        generation += 1
        isPrimed = false
        startFrame = min(AVAudioFramePosition(heldTime * sampleRate), length)
        feeder.start(at: startFrame, generation: generation)
    }

    private func handle(_ event: Feeder.Event) {
        switch event {
        case let .opened(generation, format, length):
            guard generation == self.generation else { return }
            connect(format)
            sampleRate = format.sampleRate
            self.length = length
            isLoaded = true
            heldTime = min(heldTime, duration)
            onEvent?(.loaded(duration: duration))
            if wantsPlayback {
                beginPlayback()
            }
        case let .primed(generation):
            guard generation == self.generation, wantsPlayback else { return }
            node.play()
            isPrimed = true
        case let .finished(generation):
            guard generation == self.generation else { return }
            heldTime = duration
            isPrimed = false
            onEvent?(.finished)
        case let .failed(generation):
            guard generation == self.generation else { return }
            isPrimed = false
            onEvent?(.failed)
        }
    }

    private func connect(_ format: AVAudioFormat) {
        guard format != connectedFormat else { return }
        node.removeTap(onBus: 0)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        installTap()
    }

    private func installTap() {
        node.removeTap(onBus: 0)
        guard let spectrum, connectedFormat != nil else { return }
        node.installTap(onBus: 0, bufferSize: 4096, format: nil, block: Self.tap(writingTo: spectrum))
    }

    /// Taps run on the engine's own thread, so the block must not inherit main-actor isolation.
    private nonisolated static func tap(writingTo spectrum: SpectrumBuffer) -> AVAudioNodeTapBlock {
        { buffer, _ in spectrum.write(buffer) }
    }

    /// A route or hardware format change stops the engine; carry on from the same place.
    private func restartAfterConfigurationChange() {
        guard wantsPlayback, isLoaded else { return }
        heldTime = currentTime
        isPrimed = false
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        beginPlayback()
    }
}

/// Keeps about two seconds of decoded audio scheduled on the node. All state lives on `queue`;
/// commands carry the generation they belong to, and stale callbacks are dropped.
private final class Feeder: @unchecked Sendable {
    enum Event: @unchecked Sendable {
        case opened(generation: Int, format: AVAudioFormat, length: AVAudioFramePosition)
        case primed(generation: Int)
        case finished(generation: Int)
        case failed(generation: Int)
    }

    /// Unchecked: a buffer is only touched on `queue` or by the node while it holds it.
    private struct PooledBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private static let buffersAhead = 4
    private static let secondsPerBuffer = 0.5

    private let queue = DispatchQueue(label: "com.kfurman.SwiftFlac.decoder", qos: .userInitiated)
    private let node: AVAudioPlayerNode
    private let send: @Sendable (Event) -> Void
    private var decoder: (any AudioDecoder)?
    private var generation = 0
    private var outstanding = 0
    private var reachedEnd = false
    private var pool: [AVAudioPCMBuffer] = []

    init(node: AVAudioPlayerNode, send: @escaping @Sendable (Event) -> Void) {
        self.node = node
        self.send = send
    }

    func open(_ url: URL, generation: Int) {
        queue.async { [self] in
            reset(generation)
            decoder = nil
            pool.removeAll()
            do {
                let decoder = try makeAudioDecoder(for: url)
                self.decoder = decoder
                send(.opened(generation: generation, format: decoder.processingFormat, length: decoder.length))
            } catch {
                send(.failed(generation: generation))
            }
        }
    }

    func start(at frame: AVAudioFramePosition, generation: Int) {
        queue.async { [self] in
            reset(generation)
            guard let decoder else { return }
            do {
                try decoder.seek(to: frame)
            } catch {
                send(.failed(generation: generation))
                return
            }
            fill()
            send(.primed(generation: generation))
        }
    }

    func stop(generation: Int) {
        queue.async { [self] in reset(generation) }
    }

    private func reset(_ generation: Int) {
        self.generation = generation
        // Stopping fires the completions of everything scheduled; they see the new generation.
        node.stop()
        outstanding = 0
        reachedEnd = false
    }

    private func fill() {
        guard let decoder else { return }
        let format = decoder.processingFormat
        let capacity = AVAudioFrameCount(format.sampleRate * Self.secondsPerBuffer)
        while outstanding < Self.buffersAhead, !reachedEnd {
            guard let buffer = pool.popLast() ?? AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            do {
                try decoder.read(into: buffer)
            } catch {
                send(.failed(generation: generation))
                return
            }
            guard buffer.frameLength > 0 else {
                reachedEnd = true
                pool.append(buffer)
                break
            }
            outstanding += 1
            let generation = generation
            let pooled = PooledBuffer(buffer: buffer)
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                queue.async { self.consumed(pooled.buffer, generation: generation) }
            }
        }
        if reachedEnd, outstanding == 0 {
            send(.finished(generation: generation))
        }
    }

    private func consumed(_ buffer: AVAudioPCMBuffer, generation: Int) {
        if buffer.format == decoder?.processingFormat {
            pool.append(buffer)
        }
        guard generation == self.generation else { return }
        outstanding -= 1
        fill()
    }
}
