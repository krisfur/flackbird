import Accelerate
import AVFoundation

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

/// Feeds our decoders' PCM to AVSampleBufferAudioRenderer, which gives AirPlay 2 its long-form
/// buffering. The synchronizer's clock is the position being heard.
@MainActor
final class AudioRendererTransport: PlaybackTransport {
    var onEvent: ((PlaybackEvent) -> Void)?
    var spectrum: SpectrumBuffer? {
        didSet { feeder.setSpectrum(spectrum) }
    }

    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private lazy var feeder = Feeder(renderer: renderer) { [weak self] event in
        Task { @MainActor in self?.handle(event) }
    }

    private var generation = 0
    private var sampleRate: Double = 0
    private var length: AVAudioFramePosition = 0
    /// Reported until the renderer has audio for the current position.
    private var heldTime: TimeInterval = 0
    private var isLoaded = false
    private var isPrimed = false
    private var wantsPlayback = false
    private var endObserver: Any?

    init() {
        synchronizer.addRenderer(renderer)
        // Route changes can make the renderer drop what it holds; carry on from where it stopped.
        NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: .main
        ) { [weak self] notification in
            let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            MainActor.assumeIsolated { self?.refill(from: flushTime) }
        }
    }

    /// Lets tests play without sound.
    var outputVolume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    private var duration: TimeInterval {
        sampleRate > 0 ? Double(length) / sampleRate : 0
    }

    var currentTime: TimeInterval {
        guard isPrimed else { return heldTime }
        let time = synchronizer.currentTime().seconds
        return time.isFinite ? min(max(0, time), duration) : heldTime
    }

    func load(_ url: URL, at time: TimeInterval) {
        generation += 1
        isLoaded = false
        isPrimed = false
        heldTime = max(0, time)
        removeEndObserver()
        synchronizer.rate = 0
        feeder.open(url, generation: generation)
    }

    func play() {
        wantsPlayback = true
        guard isPrimed else { return }
        synchronizer.setRate(1, time: synchronizer.currentTime())
    }

    func pause() {
        heldTime = currentTime
        wantsPlayback = false
        synchronizer.rate = 0
    }

    func seek(to time: TimeInterval) {
        heldTime = min(max(0, time), duration)
        guard isLoaded else { return }
        restart()
    }

    /// Flushes and feeds from `heldTime`; the clock starts once the renderer has audio.
    private func restart() {
        generation += 1
        isPrimed = false
        removeEndObserver()
        synchronizer.setRate(0, time: CMTime(seconds: heldTime, preferredTimescale: CMTimeScale(sampleRate)))
        feeder.start(at: min(AVAudioFramePosition(heldTime * sampleRate), length), generation: generation)
    }

    private func refill(from time: CMTime?) {
        guard isLoaded else { return }
        heldTime = time.map(\.seconds).flatMap { $0.isFinite ? $0 : nil } ?? currentTime
        restart()
    }

    private func handle(_ event: Feeder.Event) {
        switch event {
        case let .opened(generation, sampleRate, length):
            guard generation == self.generation else { return }
            self.sampleRate = sampleRate
            self.length = length
            isLoaded = true
            heldTime = min(heldTime, duration)
            onEvent?(.loaded(duration: duration))
            // Feeding while paused makes Play instant.
            restart()
        case let .primed(generation):
            guard generation == self.generation else { return }
            isPrimed = true
            observeEnd(generation: generation)
            let start = CMTime(seconds: heldTime, preferredTimescale: CMTimeScale(sampleRate))
            synchronizer.setRate(wantsPlayback ? 1 : 0, time: start)
        case let .failed(generation):
            guard generation == self.generation else { return }
            isPrimed = false
            synchronizer.rate = 0
            onEvent?(.failed)
        }
    }

    private func observeEnd(generation: Int) {
        let end = NSValue(time: CMTime(value: length, timescale: CMTimeScale(sampleRate)))
        endObserver = synchronizer.addBoundaryTimeObserver(forTimes: [end], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.finish(generation: generation) }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            synchronizer.removeTimeObserver(endObserver)
        }
        endObserver = nil
    }

    private func finish(generation: Int) {
        guard generation == self.generation else { return }
        heldTime = duration
        isPrimed = false
        synchronizer.rate = 0
        onEvent?(.finished)
    }
}

/// Decodes on its own queue whenever the renderer wants more. All state lives on `queue`;
/// commands carry the generation they belong to, and stale ones are dropped.
private final class Feeder: @unchecked Sendable {
    enum Event: Sendable {
        case opened(generation: Int, sampleRate: Double, length: AVAudioFramePosition)
        case primed(generation: Int)
        case failed(generation: Int)
    }

    private static let secondsPerBuffer = 0.5

    private let queue = DispatchQueue(label: "com.kfurman.SwiftFlac.decoder", qos: .userInitiated)
    private let renderer: AVSampleBufferAudioRenderer
    private let send: @Sendable (Event) -> Void
    private var decoder: (any AudioDecoder)?
    private var scratch: AVAudioPCMBuffer?
    private var formatDescription: CMAudioFormatDescription?
    private var spectrum: SpectrumBuffer?
    private var generation = 0
    private var nextFrame: AVAudioFramePosition = 0
    private var reachedEnd = false

    init(renderer: AVSampleBufferAudioRenderer, send: @escaping @Sendable (Event) -> Void) {
        self.renderer = renderer
        self.send = send
    }

    func setSpectrum(_ spectrum: SpectrumBuffer?) {
        queue.async { [self] in self.spectrum = spectrum }
    }

    func open(_ url: URL, generation: Int) {
        queue.async { [self] in
            stopFeeding(generation)
            decoder = nil
            do {
                let decoder = try makeAudioDecoder(for: url)
                let format = decoder.processingFormat
                // The renderer takes interleaved PCM.
                let interleaved = format.channelLayout.map {
                    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: true, channelLayout: $0)
                } ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                   channels: format.channelCount, interleaved: true)
                guard let interleaved,
                      let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * Self.secondsPerBuffer))
                else { throw AudioDecoderError.unreadable }
                self.decoder = decoder
                self.scratch = scratch
                formatDescription = interleaved.formatDescription
                send(.opened(generation: generation, sampleRate: format.sampleRate, length: decoder.length))
            } catch {
                send(.failed(generation: generation))
            }
        }
    }

    func start(at frame: AVAudioFramePosition, generation: Int) {
        queue.async { [self] in
            stopFeeding(generation)
            guard let decoder else { return }
            do {
                try decoder.seek(to: frame)
            } catch {
                send(.failed(generation: generation))
                return
            }
            nextFrame = frame
            reachedEnd = false
            spectrum?.reset()
            guard feed() else { return }
            send(.primed(generation: generation))
            if !reachedEnd {
                renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                    guard let self, generation == self.generation else { return }
                    _ = feed()
                }
            }
        }
    }

    private func stopFeeding(_ generation: Int) {
        self.generation = generation
        renderer.stopRequestingMediaData()
        renderer.flush()
    }

    /// Enqueues until the renderer is full or the track ends; false after a failure.
    private func feed() -> Bool {
        guard let decoder, let scratch, let formatDescription else { return false }
        while renderer.isReadyForMoreMediaData, !reachedEnd {
            do {
                try decoder.read(into: scratch)
            } catch {
                renderer.stopRequestingMediaData()
                send(.failed(generation: generation))
                return false
            }
            guard scratch.frameLength > 0 else {
                reachedEnd = true
                renderer.stopRequestingMediaData()
                break
            }
            guard let sample = Self.sampleBuffer(from: scratch, at: nextFrame, description: formatDescription) else {
                send(.failed(generation: generation))
                return false
            }
            spectrum?.write(scratch, at: nextFrame)
            renderer.enqueue(sample)
            nextFrame += AVAudioFramePosition(scratch.frameLength)
        }
        if renderer.status == .failed {
            send(.failed(generation: generation))
            return false
        }
        return true
    }

    /// Interleaves into a new block buffer stamped with the frame's presentation time.
    private static func sampleBuffer(
        from pcm: AVAudioPCMBuffer, at frame: AVAudioFramePosition, description: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let frames = Int(pcm.frameLength)
        let channels = Int(pcm.format.channelCount)
        let bytes = frames * channels * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &data)
            == kCMBlockBufferNoErr, let data, let source = pcm.floatChannelData else { return nil }
        data.withMemoryRebound(to: Float.self, capacity: frames * channels) { output in
            var zero: Float = 0
            for channel in 0 ..< channels {
                // A strided copy: adding zero into every `channels`-th slot.
                vDSP_vsadd(source[channel], 1, &zero, output + channel, vDSP_Stride(channels), vDSP_Length(frames))
            }
        }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: CMTime(value: frame, timescale: CMTimeScale(pcm.format.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
