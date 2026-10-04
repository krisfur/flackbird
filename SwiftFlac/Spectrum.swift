import Accelerate
import AVFoundation
import os

/// Decoded audio by position, written as it's fed to the renderer and read at the playback time.
/// Kept at 48 kHz or below: hi-res keeps every 2nd or 4th sample, plenty for a display.
final class SpectrumBuffer: @unchecked Sendable {
    /// Covers the renderer's read-ahead: four seconds at 48 kHz.
    static let capacity = 196_608

    private struct State {
        /// Stored index just past the newest sample.
        var end = 0
        var written = 0
        var sampleRate: Double = 0
    }

    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let state = UnsafeMutablePointer<State>.allocate(capacity: 1)

    init() {
        samples.initialize(repeating: 0, count: Self.capacity)
        lock.initialize(to: os_unfair_lock())
        state.initialize(to: State())
    }

    deinit {
        samples.deallocate()
        lock.deallocate()
        state.deallocate()
    }

    /// `count` samples ending at `time`, oldest first. Nil if that stretch isn't held.
    func window(_ count: Int, endingAt time: TimeInterval) -> (samples: [Float], sampleRate: Double)? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let current = state.pointee
        guard current.sampleRate > 0, count > 0, time.isFinite else { return nil }
        let last = Int(time * current.sampleRate)
        guard last <= current.end, last - count >= current.end - current.written else { return nil }
        let recent = (last - count ..< last).map { samples[$0 % Self.capacity] }
        return (recent, current.sampleRate)
    }

    /// Forgets buffered audio, so a seek or new track never shows stale levels.
    func reset() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        state.pointee.written = 0
    }

    /// The first channel of `buffer`, which starts at track frame `frame`.
    func write(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition) {
        guard let data = buffer.floatChannelData else { return }
        write(data[0], count: Int(buffer.frameLength), at: Int(frame), sampleRate: buffer.format.sampleRate)
    }

    /// Mono samples starting at track frame `frame`.
    func append(_ mono: [Float], sampleRate: Double, at frame: Int = 0) {
        mono.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            write(base, count: pointer.count, at: frame, sampleRate: sampleRate)
        }
    }

    private func write(_ data: UnsafePointer<Float>, count: Int, at frame: Int, sampleRate: Double) {
        let step = max(1, Int(sampleRate / 48000))
        // Keep source frames that are multiples of `step`, so consecutive writes line up.
        let first = (step - frame % step) % step
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let start = (frame + first) / step
        if start != state.pointee.end || state.pointee.sampleRate != sampleRate / Double(step) {
            state.pointee.written = 0
            state.pointee.sampleRate = sampleRate / Double(step)
        }
        var index = start
        for source in stride(from: first, to: count, by: step) {
            samples[index % Self.capacity] = data[source]
            index += 1
        }
        state.pointee.written = min(state.pointee.written + index - start, Self.capacity)
        state.pointee.end = index
    }
}

/// Turns a window of samples into log-spaced band levels from 0 to 1.
struct SpectrumAnalyzer {
    /// The newest ~46 ms at 44.1 kHz, zero-padded to `size` so bass bands still get distinct bins.
    /// A longer window would lag: the Hann taper barely weighs the newest samples.
    static let windowLength = 2048
    static let size = 4096
    static let lowestFrequency = 50.0
    static let highestFrequency = 16000.0

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    init?() {
        guard let fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.windowLength, isHalfWindow: false)
    }

    func levels(of samples: [Float], sampleRate: Double, bands: Int) -> [Float] {
        guard samples.count == Self.windowLength, sampleRate > 0, bands > 0 else { return Array(repeating: 0, count: max(bands, 0)) }
        let half = Self.size / 2
        let windowed = vDSP.multiply(samples, window) + [Float](repeating: 0, count: Self.size - Self.windowLength)
        var power = [Float](repeating: 0, count: half)
        var inputReal = [Float](repeating: 0, count: half)
        var inputImaginary = [Float](repeating: 0, count: half)
        var outputReal = [Float](repeating: 0, count: half)
        var outputImaginary = [Float](repeating: 0, count: half)
        inputReal.withUnsafeMutableBufferPointer { inReal in
            inputImaginary.withUnsafeMutableBufferPointer { inImaginary in
                outputReal.withUnsafeMutableBufferPointer { outReal in
                    outputImaginary.withUnsafeMutableBufferPointer { outImaginary in
                        guard let inR = inReal.baseAddress, let inI = inImaginary.baseAddress,
                              let outR = outReal.baseAddress, let outI = outImaginary.baseAddress else { return }
                        var input = DSPSplitComplex(realp: inR, imagp: inI)
                        var output = DSPSplitComplex(realp: outR, imagp: outI)
                        windowed.withUnsafeBufferPointer { pointer in
                            pointer.withMemoryRebound(to: DSPComplex.self) { complex in
                                guard let base = complex.baseAddress else { return }
                                vDSP_ctoz(base, 2, &input, 1, vDSP_Length(half))
                            }
                        }
                        fft.forward(input: input, output: &output)
                        // Packed format: imagp[0] holds Nyquist, not DC's imaginary part.
                        output.imagp[0] = 0
                        power.withUnsafeMutableBufferPointer { powerPointer in
                            guard let base = powerPointer.baseAddress else { return }
                            vDSP_zvmags(&output, 1, base, 1, vDSP_Length(half))
                        }
                    }
                }
            }
        }
        let binWidth = sampleRate / Double(Self.size)
        let top = min(Self.highestFrequency, sampleRate / 2)
        let ratio = top / Self.lowestFrequency
        return (0 ..< bands).map { band in
            let low = Self.lowestFrequency * pow(ratio, Double(band) / Double(bands))
            let high = Self.lowestFrequency * pow(ratio, Double(band + 1) / Double(bands))
            let first = max(1, Int(low / binWidth))
            let last = max(first + 1, min(half, Int(high / binWidth)))
            let peak = first < half ? power[first ..< last].max() ?? 0 : 0
            // A full-scale sine lands near -6 dB; 64 dB below that reads as silence.
            let decibels = 10 * log10(Double(peak) / Double(Self.windowLength * Self.windowLength) + 1e-12)
            return Float(min(1, max(0, (decibels + 70) / 64)))
        }
    }
}

/// Smoothed levels for the display: bars jump up and fall back gently, and drop
/// quickly when no fresh audio arrives. Several views can share one per frame.
@MainActor
final class SpectrumMonitor {
    static let bandCount = 32
    let buffer = SpectrumBuffer()
    /// The position being heard while playing, nil otherwise.
    var playbackPosition: @MainActor () -> TimeInterval? = { nil }
    private let analyzer = SpectrumAnalyzer()
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var lastPosition: TimeInterval?
    private var lastUpdate: Date?
    private var silentSince: Date?
    /// False once playback has gone 1.5 s with no audio to show; a seek's short gap doesn't count.
    private(set) var hasSignal = true

    func reset() {
        buffer.reset()
        lastPosition = nil
    }

    /// Called per frame while playing: the window ending at the playback position.
    func update(at date: Date = .now) -> [Float] {
        if let lastUpdate {
            let elapsed = date.timeIntervalSince(lastUpdate)
            // Another view already advanced this frame.
            if abs(elapsed) < 0.008 {
                return smoothed
            }
            // A long gap means playback was paused; silence before it doesn't count.
            if elapsed > 0.5 {
                silentSince = nil
            }
        }
        lastUpdate = date
        let position = playbackPosition()
        var fresh: [Float]?
        // A position that stops moving means a stall: let the bars fall.
        if let analyzer, let position, position != lastPosition,
           let window = buffer.window(SpectrumAnalyzer.windowLength, endingAt: position)
        {
            fresh = analyzer.levels(of: window.samples, sampleRate: window.sampleRate, bands: Self.bandCount)
        }
        lastPosition = position
        if let fresh {
            smoothed = zip(fresh, smoothed).map { max($0, $1 * 0.85) }
            silentSince = nil
        } else {
            smoothed = smoothed.map { $0 * 0.6 }
            silentSince = silentSince ?? date
        }
        hasSignal = silentSince.map { date.timeIntervalSince($0) < 1.5 } ?? true
        return smoothed
    }
}
