internal import CFLAC
import Accelerate
import AVFAudio

/// Float PCM from a file for the playback engine. Not thread-safe: one queue owns each decoder.
protocol AudioDecoder: AnyObject {
    /// Deinterleaved Float32 at the file's own rate and channel count.
    var processingFormat: AVAudioFormat { get }
    /// Total frames.
    var length: AVAudioFramePosition { get }
    /// Fills `buffer` from the current position; a `frameLength` of 0 means the end.
    func read(into buffer: AVAudioPCMBuffer) throws
    func seek(to frame: AVAudioFramePosition) throws
}

enum AudioDecoderError: Error {
    case unreadable
    case corrupt
}

/// FLAC goes through libFLAC: AVFoundation either scans the whole file or seeks to the wrong place.
func makeAudioDecoder(for url: URL) throws -> any AudioDecoder {
    if url.pathExtension.lowercased() == "flac", let flac = try? FlacDecoder(url: url) {
        return flac
    }
    return try CoreAudioDecoder(url: url)
}

final class CoreAudioDecoder: AudioDecoder {
    private let file: AVAudioFile

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
    }

    var processingFormat: AVAudioFormat {
        file.processingFormat
    }

    var length: AVAudioFramePosition {
        file.length
    }

    func read(into buffer: AVAudioPCMBuffer) throws {
        guard file.framePosition < file.length else {
            buffer.frameLength = 0
            return
        }
        try file.read(into: buffer)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        file.framePosition = min(max(0, frame), file.length)
    }
}

final class FlacDecoder: AudioDecoder {
    let processingFormat: AVAudioFormat
    let length: AVAudioFramePosition
    private let decoder: UnsafeMutablePointer<FLAC__StreamDecoder>
    private let state = State()

    /// What libFLAC's callbacks write into: STREAMINFO, then decoded samples not yet handed out.
    private final class State {
        var sampleRate = 0.0
        var channels = 0
        var bitsPerSample = 0
        var totalSamples: UInt64 = 0
        var pending: [[Float]] = []
        var pendingOffset = 0

        var available: Int {
            (pending.first?.count ?? 0) - pendingOffset
        }

        func append(_ frame: FLAC__Frame, _ buffer: UnsafePointer<UnsafePointer<FLAC__int32>?>) {
            let count = Int(frame.header.blocksize)
            let channels = Int(frame.header.channels)
            var scale = 1 / Float(1 << (Int(frame.header.bits_per_sample) - 1))
            if pending.count != channels {
                pending = Array(repeating: [], count: channels)
            }
            if pendingOffset > 0, available == 0 {
                for channel in pending.indices {
                    pending[channel].removeAll(keepingCapacity: true)
                }
                pendingOffset = 0
            }
            for channel in 0 ..< channels {
                guard let samples = buffer[channel] else { continue }
                let start = pending[channel].count
                pending[channel].append(contentsOf: repeatElement(0, count: count))
                pending[channel].withUnsafeMutableBufferPointer { destination in
                    guard let base = destination.baseAddress else { return }
                    vDSP_vflt32(samples, 1, base + start, 1, vDSP_Length(count))
                    vDSP_vsmul(base + start, 1, &scale, base + start, 1, vDSP_Length(count))
                }
            }
        }

        func clear() {
            for channel in pending.indices {
                pending[channel].removeAll(keepingCapacity: true)
            }
            pendingOffset = 0
        }
    }

    init(url: URL) throws {
        guard let decoder = FLAC__stream_decoder_new() else { throw AudioDecoderError.unreadable }
        self.decoder = decoder
        FLAC__stream_decoder_set_md5_checking(decoder, 0)
        let status = FLAC__stream_decoder_init_file(
            decoder, url.path,
            { _, frame, buffer, client in
                guard let frame, let buffer, let client else { return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT }
                Unmanaged<State>.fromOpaque(client).takeUnretainedValue().append(frame.pointee, buffer)
                return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
            },
            { _, metadata, client in
                guard let metadata, let client, metadata.pointee.type == FLAC__METADATA_TYPE_STREAMINFO else { return }
                let info = metadata.pointee.data.stream_info
                let state = Unmanaged<State>.fromOpaque(client).takeUnretainedValue()
                state.sampleRate = Double(info.sample_rate)
                state.channels = Int(info.channels)
                state.bitsPerSample = Int(info.bits_per_sample)
                state.totalSamples = info.total_samples
            },
            // Lost sync and bad frames are skipped; the decoder carries on.
            { _, _, _ in },
            Unmanaged.passUnretained(state).toOpaque()
        )
        guard status == FLAC__STREAM_DECODER_INIT_STATUS_OK,
              FLAC__stream_decoder_process_until_end_of_metadata(decoder) != 0,
              state.sampleRate > 0, state.channels > 0, state.totalSamples > 0
        else {
            FLAC__stream_decoder_delete(decoder)
            throw AudioDecoderError.unreadable
        }
        let channels = AVAudioChannelCount(state.channels)
        let sampleRate = state.sampleRate
        // Beyond stereo a format needs a layout; FLAC's channel order is fixed per count.
        let layout = channels > 2 ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) : nil
        guard let format = layout.map({ AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: $0) })
            ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        else {
            FLAC__stream_decoder_delete(decoder)
            throw AudioDecoderError.unreadable
        }
        processingFormat = format
        length = AVAudioFramePosition(state.totalSamples)
    }

    deinit {
        FLAC__stream_decoder_finish(decoder)
        FLAC__stream_decoder_delete(decoder)
    }

    /// Source bit depth, for the quality line.
    var bitsPerSample: Int {
        state.bitsPerSample
    }

    func read(into buffer: AVAudioPCMBuffer) throws {
        guard let output = buffer.floatChannelData else { throw AudioDecoderError.corrupt }
        let capacity = Int(buffer.frameCapacity)
        var filled = 0
        while filled < capacity {
            let available = state.available
            if available > 0 {
                let count = min(available, capacity - filled)
                for channel in 0 ..< min(state.pending.count, Int(processingFormat.channelCount)) {
                    state.pending[channel].withUnsafeBufferPointer { samples in
                        guard let base = samples.baseAddress else { return }
                        (output[channel] + filled).update(from: base + state.pendingOffset, count: count)
                    }
                }
                state.pendingOffset += count
                filled += count
                continue
            }
            let position = FLAC__stream_decoder_get_state(decoder)
            if position == FLAC__STREAM_DECODER_END_OF_STREAM {
                break
            }
            guard FLAC__stream_decoder_process_single(decoder) != 0 else { throw AudioDecoderError.corrupt }
        }
        buffer.frameLength = AVAudioFrameCount(filled)
    }

    func seek(to frame: AVAudioFramePosition) throws {
        state.clear()
        let target = UInt64(min(max(0, frame), length))
        // libFLAC can't seek to the end itself; decoding past the last frame reaches it.
        guard target < state.totalSamples else {
            while FLAC__stream_decoder_get_state(decoder) != FLAC__STREAM_DECODER_END_OF_STREAM {
                guard FLAC__stream_decoder_skip_single_frame(decoder) != 0 else { throw AudioDecoderError.corrupt }
            }
            return
        }
        if FLAC__stream_decoder_seek_absolute(decoder, target) == 0 {
            // A failed seek leaves the decoder needing a flush before it decodes again.
            FLAC__stream_decoder_flush(decoder)
            state.clear()
            throw AudioDecoderError.corrupt
        }
    }
}
