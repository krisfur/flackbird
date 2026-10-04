import AVFAudio
@testable import SwiftFlac
import Testing

struct DecoderTests {
    /// Every frame from the current position to the end, first channel.
    private func drain(_ decoder: any AudioDecoder, chunk: AVAudioFrameCount = 1000) throws -> [Float] {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: chunk))
        var samples: [Float] = []
        while true {
            try decoder.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    @Test(arguments: ["sample.flac", "tagged.flac"])
    func flacMatchesCoreAudioSampleForSample(name: String) throws {
        let url = try fixture(name)
        let flac = try FlacDecoder(url: url)
        let reference = try CoreAudioDecoder(url: url)
        #expect(flac.length == reference.length)
        #expect(flac.processingFormat.sampleRate == reference.processingFormat.sampleRate)
        #expect(flac.processingFormat.channelCount == reference.processingFormat.channelCount)
        let expected = try drain(reference)
        // An odd chunk size crosses FLAC's block boundaries mid-buffer.
        #expect(try drain(flac, chunk: 777) == expected)
        #expect(Int64(expected.count) == flac.length)

        for target in [Int64(0), flac.length / 3, flac.length - 1] {
            try flac.seek(to: target)
            #expect(try drain(flac) == Array(expected[Int(target)...]))
        }
        try flac.seek(to: flac.length)
        #expect(try drain(flac).isEmpty)
    }

    @Test func coreAudioDecoderSeeksAndEnds() throws {
        let decoder = try CoreAudioDecoder(url: fixture("plain.wav"))
        let all = try drain(decoder)
        #expect(Int64(all.count) == decoder.length)
        try decoder.seek(to: 4000)
        #expect(try drain(decoder) == Array(all[4000...]))
    }

    /// Every non-FLAC format the library scans goes through Core Audio; the fixtures are two-second tones.
    @Test(arguments: ["tagged.mp3", "tagged.m4a", "lossless.m4a", "plain.aac", "plain.wav", "plain.aiff"])
    func otherFormatsDecodeAndSeek(name: String) throws {
        let decoder = try makeAudioDecoder(for: fixture(name))
        #expect(decoder is CoreAudioDecoder)
        let seconds = Double(decoder.length) / decoder.processingFormat.sampleRate
        // Raw AAC and MP3 keep the encoder's priming and padding: 0.16-0.18 s at this 8 kHz rate.
        #expect(seconds >= 2 && seconds < 2.2)
        #expect(try Int64(drain(decoder).count) == decoder.length)
        try decoder.seek(to: decoder.length / 2)
        #expect(try Int64(drain(decoder).count) == decoder.length - decoder.length / 2)
    }

    @Test func factoryPicksLibFlacAndFallsBack() throws {
        #expect(try makeAudioDecoder(for: fixture("sample.flac")) is FlacDecoder)
        #expect(try makeAudioDecoder(for: fixture("tagged.mp3")) is CoreAudioDecoder)
        let store = try TestStore()
        #expect(throws: (any Error).self) { try FlacDecoder(url: store.file("bad.flac", data: Data("not audio".utf8))) }
        #expect(throws: (any Error).self) { try makeAudioDecoder(for: store.file("bad.flac", data: Data("not audio".utf8))) }
    }
}
