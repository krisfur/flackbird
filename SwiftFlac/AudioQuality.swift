import AVFoundation
import Foundation

/// What the file itself holds. Output routes such as AirPlay or Bluetooth may
/// resample or re-encode it, so this never claims to be what is heard.
struct AudioQuality: Equatable {
    var format: String
    /// Only known for lossless and PCM sources.
    var bitDepth: Int?
    var sampleRate: Double?
    var kilobitsPerSecond: Int?

    /// "FLAC · 24-bit / 96 kHz · 2,304 kbps" or "MP3 · 320 kbps".
    var summary: String {
        var parts = [format]
        if let bitDepth, let sampleRate {
            let kilohertz = (sampleRate / 1000).formatted(.number.precision(.fractionLength(0 ... 1)))
            parts.append("\(bitDepth)-bit / \(kilohertz) kHz")
        }
        if let kilobitsPerSecond, kilobitsPerSecond > 0 {
            parts.append("\(kilobitsPerSecond.formatted()) kbps")
        }
        return parts.joined(separator: " · ")
    }

    static func read(from url: URL) async -> AudioQuality? {
        if url.pathExtension.lowercased() == "flac" {
            return FlacMetadata.quality(from: url)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let (descriptions, dataRate) = try? await track.load(.formatDescriptions, .estimatedDataRate),
              let description = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        var bitsPerSecond = Double(dataRate)
        // Raw ADTS AAC carries no rate estimate; its container overhead is negligible.
        if bitsPerSecond <= 0, let seconds = try? await asset.load(.duration).seconds, seconds > 0,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            bitsPerSecond = Double(size) * 8 / seconds
        }
        return quality(of: stream, estimatedDataRate: bitsPerSecond, fileExtension: url.pathExtension)
    }

    static func quality(of stream: AudioStreamBasicDescription, estimatedDataRate: Double,
                        fileExtension: String) -> AudioQuality
    {
        let kilobits = estimatedDataRate > 0 ? Int((estimatedDataRate / 1000).rounded()) : nil
        switch stream.mFormatID {
        case kAudioFormatMPEGLayer3:
            return AudioQuality(format: "MP3", kilobitsPerSecond: kilobits)
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
            return AudioQuality(format: "AAC", kilobitsPerSecond: kilobits)
        case kAudioFormatAppleLossless:
            // ALAC keeps the source bit depth in its format flags.
            let depths: [UInt32: Int] = [
                kAppleLosslessFormatFlag_16BitSourceData: 16, kAppleLosslessFormatFlag_20BitSourceData: 20,
                kAppleLosslessFormatFlag_24BitSourceData: 24, kAppleLosslessFormatFlag_32BitSourceData: 32,
            ]
            return AudioQuality(format: "ALAC", bitDepth: depths[stream.mFormatFlags],
                                sampleRate: stream.mSampleRate, kilobitsPerSecond: kilobits)
        case kAudioFormatLinearPCM:
            // Uncompressed, so the exact rate beats any estimate.
            let bits = Int(stream.mBitsPerChannel)
            let pcmKilobits = Int((stream.mSampleRate * Double(bits) * Double(stream.mChannelsPerFrame) / 1000).rounded())
            let format = ["aif", "aiff"].contains(fileExtension.lowercased()) ? "AIFF" : "WAV"
            return AudioQuality(format: format, bitDepth: bits > 0 ? bits : nil,
                                sampleRate: stream.mSampleRate, kilobitsPerSecond: pcmKilobits)
        default:
            return AudioQuality(format: fileExtension.uppercased(), kilobitsPerSecond: kilobits)
        }
    }
}
