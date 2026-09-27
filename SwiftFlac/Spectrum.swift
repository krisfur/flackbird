import Accelerate
import AVFoundation
import MediaToolbox
import os

/// Recent decoded audio, shared between a real-time audio tap and the UI. The
/// tap side never allocates, retains, or blocks: it skips a buffer if the UI holds the lock.
final class SpectrumBuffer: @unchecked Sendable {
    static let capacity = 8192

    private struct State {
        var writeIndex = 0
        var written = 0
        var sampleRate: Double = 0
        var channels = 0
        var isUsable = false
        var isInterleaved = false
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

    /// The newest `count` samples, oldest first; nil until enough audio has played.
    func latest(_ count: Int) -> (samples: [Float], sampleRate: Double)? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let current = state.pointee
        guard current.sampleRate > 0, current.written >= count, count <= Self.capacity else { return nil }
        let start = (current.writeIndex - count + Self.capacity) % Self.capacity
        let recent = (0 ..< count).map { samples[(start + $0) % Self.capacity] }
        return (recent, current.sampleRate)
    }

    /// A tap to put on an audio mix; each tap keeps this buffer alive until it is finalized.
    func makeTap() -> MTAudioProcessingTap? {
        let owner = Unmanaged.passRetained(self)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: owner.toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<SpectrumBuffer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<SpectrumBuffer>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    ._withUnsafeGuaranteedRef { $0.prepare(format.pointee) }
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<SpectrumBuffer>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    ._withUnsafeGuaranteedRef { $0.write(bufferList, frames: framesOut.pointee) }
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr
        else {
            // Init and finalize never ran, so the retain is ours to drop.
            owner.release()
            return nil
        }
        return tap
    }

    private func prepare(_ format: AudioStreamBasicDescription) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        state.pointee.sampleRate = format.mSampleRate
        state.pointee.channels = Int(format.mChannelsPerFrame)
        state.pointee.isUsable = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        state.pointee.isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    /// Real-time thread: the first channel is enough for a display.
    private func write(_ list: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        let current = state.pointee
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard current.isUsable, current.channels > 0, let first = buffers.first,
              let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let stride = current.isInterleaved ? current.channels : 1
        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
        let count = min(Int(frames), available)
        var index = current.writeIndex
        for frame in 0 ..< count {
            samples[index] = data[frame * stride]
            index = (index + 1) % Self.capacity
        }
        state.pointee.writeIndex = index
        state.pointee.written = min(current.written + count, Self.capacity)
    }
}

/// Turns a window of samples into log-spaced band levels from 0 to 1.
struct SpectrumAnalyzer {
    /// About 93 ms at 44.1 kHz, fine enough that bass bands still span a bin.
    static let size = 4096
    static let lowestFrequency = 50.0
    static let highestFrequency = 16000.0

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    init?() {
        guard let fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
    }

    func levels(of samples: [Float], sampleRate: Double, bands: Int) -> [Float] {
        guard samples.count == Self.size, sampleRate > 0, bands > 0 else { return Array(repeating: 0, count: max(bands, 0)) }
        let half = Self.size / 2
        let windowed = vDSP.multiply(samples, window)
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
            let decibels = 10 * log10(Double(peak) / Double(Self.size * Self.size) + 1e-12)
            return Float(min(1, max(0, (decibels + 70) / 64)))
        }
    }
}

/// Smoothed levels for the display: bars jump up and fall back gently.
@MainActor
final class SpectrumMonitor {
    static let bandCount = 32
    let buffer = SpectrumBuffer()
    private let analyzer = SpectrumAnalyzer()
    private var smoothed = [Float](repeating: 0, count: bandCount)

    func update(isPlaying: Bool) -> [Float] {
        var fresh = [Float](repeating: 0, count: Self.bandCount)
        if isPlaying, let analyzer, let window = buffer.latest(SpectrumAnalyzer.size) {
            fresh = analyzer.levels(of: window.samples, sampleRate: window.sampleRate, bands: Self.bandCount)
        }
        smoothed = zip(fresh, smoothed).map { max($0, $1 * 0.85) }
        return smoothed
    }
}
