import Foundation
@testable import SwiftFlac
import Testing

struct AudioQualityTests {
    @Test func flacReadsStreamInfoAndCountsOnlyAudioInTheBitrate() throws {
        let quality = try #require(FlacMetadata.quality(from: fixture("tagged.flac")))
        #expect(quality.format == "FLAC" && quality.bitDepth == 16 && quality.sampleRate == 8000)
        // ffprobe puts the whole file at ~59 kbps; tags and cover art are excluded here.
        let kilobits = try #require(quality.kilobitsPerSecond)
        #expect(kilobits > 0 && kilobits < 59)
        #expect(quality.summary == "FLAC · 16-bit / 8 kHz · \(kilobits) kbps")
        let sample = try #require(FlacMetadata.quality(from: fixture("sample.flac")))
        #expect(sample.sampleRate == 44100 && sample.summary.hasPrefix("FLAC · 16-bit / 44.1 kHz"))
    }

    @Test func malformedFlacHasNoQuality() throws {
        let store = try TestStore()
        #expect(try FlacMetadata.quality(from: store.file("empty.flac")) == nil)
        #expect(try FlacMetadata.quality(from: store.file("short.flac", data: Data("fLaC".utf8) + Data([0x80, 0, 0, 34]))) == nil)
    }

    @Test(arguments: [
        ("tagged.mp3", "MP3", nil as Int?, 1 ... 16),
        ("tagged.m4a", "AAC", nil, 16 ... 40),
        ("plain.aac", "AAC", nil, 16 ... 40),
        ("lossless.m4a", "ALAC", 16, 16 ... 40),
        ("plain.wav", "WAV", 16, 128 ... 128),
        ("plain.aiff", "AIFF", 16, 128 ... 128),
    ])
    func otherFormatsReportCodecDepthAndBitrate(_ name: String, _ format: String, _ bitDepth: Int?,
                                                _ kilobits: ClosedRange<Int>) async throws
    {
        let quality = try #require(await AudioQuality.read(from: fixture(name)))
        #expect(quality.format == format && quality.bitDepth == bitDepth)
        #expect(kilobits.contains(quality.kilobitsPerSecond ?? -1))
        // Lossy files show only the bitrate; sample rates would suggest a resolution they don't have.
        #expect(quality.summary.contains("kHz") == (bitDepth != nil))
    }

    @Test @MainActor func playerPublishesQualityForTheCurrentTrackOnly() async throws {
        let store = try TestStore()
        let tracks = testTracks(root: store.root)
        let gate = AsyncGate<AudioQuality?>()
        let player = PlayerController(transport: FakeTransport(), defaults: store.defaults, systemIntegration: false,
                                      activate: {}, metadataLoader: { _ in TrackMetadata() },
                                      qualityLoader: { url in
                                          url == tracks[0].url ? await gate.wait() : AudioQuality(format: "MP3", kilobitsPerSecond: 320)
                                      },
                                      durationLoader: { _ in 120 })
        player.play(tracks[0], in: tracks)
        await gate.waitUntilEntered()
        player.next()
        try await eventually { player.audioQuality?.summary == "MP3 · 320 kbps" }
        await gate.finish(AudioQuality(format: "FLAC", bitDepth: 24, sampleRate: 96000, kilobitsPerSecond: 2304))
        await Task.yield()
        #expect(player.audioQuality?.format == "MP3")
    }
}
