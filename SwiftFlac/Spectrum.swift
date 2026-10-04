import Accelerate
import AVFoundation
import os

/// Recent decoded audio, shared between the engine's tap and the UI.
final class SpectrumBuffer: @unchecked Sendable {
    /// Room for the analysis window plus Bluetooth-sized output latency.
    static let capacity = 32768

    private struct State {
        var writeIndex = 0
        var written = 0
        var sequence: UInt64 = 0
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

    /// `count` samples ending `delay` seconds before the newest, oldest first, plus a
    /// counter that advances whenever audio arrives. Nil until enough audio has played.
    func latest(_ count: Int, delay: TimeInterval = 0) -> (samples: [Float], sampleRate: Double, sequence: UInt64)? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let current = state.pointee
        guard current.sampleRate > 0, count > 0, current.written >= count else { return nil }
        let offset = min(max(0, Int(delay * current.sampleRate)), current.written - count)
        let start = ((current.writeIndex - offset - count) % Self.capacity + Self.capacity) % Self.capacity
        let recent = (0 ..< count).map { samples[(start + $0) % Self.capacity] }
        return (recent, current.sampleRate, current.sequence)
    }

    /// Forgets buffered audio, so a new track never shows the previous one's tail.
    func reset() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        state.pointee.written = 0
    }

    /// From the engine's tap, off the audio thread: the first channel is enough for a display.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        state.pointee.sampleRate = buffer.format.sampleRate
        appendLocked(data[0], count: Int(buffer.frameLength))
    }

    /// Caller holds the lock.
    private func appendLocked(_ data: UnsafePointer<Float>, count: Int) {
        var index = state.pointee.writeIndex
        for frame in 0 ..< count {
            samples[index] = data[frame]
            index = (index + 1) % Self.capacity
        }
        state.pointee.writeIndex = index
        state.pointee.written = min(state.pointee.written + count, Self.capacity)
        state.pointee.sequence &+= UInt64(count)
    }

    /// Feeds mono samples as the tap would, for tests.
    func append(_ mono: [Float], sampleRate: Double) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        state.pointee.sampleRate = sampleRate
        mono.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            appendLocked(base, count: pointer.count)
        }
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
    private let analyzer = SpectrumAnalyzer()
    private var smoothed = [Float](repeating: 0, count: bandCount)
    private var lastSequence: UInt64?
    private var staleFrames = 0
    private var lastUpdate: Date?
    private var silentSince: Date?
    /// False once playback has gone 1.5 s with no audio reaching the tap, as over AirPlay;
    /// a track change's short gap doesn't count.
    private(set) var hasSignal = true

    func reset() {
        buffer.reset()
        lastSequence = nil
    }

    /// Called per frame while playing. `delay` holds the display back by the output latency
    /// so bars line up with what is heard.
    func update(delay: TimeInterval = 0, at date: Date = .now) -> [Float] {
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
        var fresh: [Float]?
        if let analyzer, let window = buffer.latest(SpectrumAnalyzer.windowLength, delay: delay) {
            staleFrames = window.sequence == lastSequence ? staleFrames + 1 : 0
            lastSequence = window.sequence
            // Taps deliver roughly every 20 ms; much longer without audio means none is coming.
            if staleFrames < 6 {
                fresh = analyzer.levels(of: window.samples, sampleRate: window.sampleRate, bands: Self.bandCount)
            }
        }
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
