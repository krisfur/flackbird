import AVFoundation
import Foundation
@testable import SwiftFlac
import Testing

@Suite(.serialized)
struct MetadataTests {
    @Test func flacTagsAndCover() throws {
        let tags = try FlacMetadata.read(from: fixture("tagged.flac"))
        #expect(tags.title == "First Song")
        #expect(tags.artist == "Test Artist")
        #expect(tags.albumArtist == "Test Artist")
        #expect(tags.trackNumber == 2 && tags.discNumber == 1)
        let cover = try FlacMetadata.read(from: fixture("sample.flac"))
        #expect(cover.artworkData?.isEmpty == false)
        #expect(try FlacMetadata.read(from: fixture("sample.flac"), readArtwork: false).artworkData == nil)
    }

    @Test(arguments: [Data(), Data("notFLAC".utf8), Data("fLaC".utf8) + Data([0x84, 0xFF, 0xFF, 0xFF]),
                      Data("fLaC".utf8) + Data([0x86, 0, 0, 3, 0, 0, 0])])
    func malformedMetadataIsSafe(_ data: Data) throws {
        let store = try TestStore()
        #expect(try FlacMetadata.read(from: store.file("broken.flac", data: data)) == TrackMetadata())
    }

    @Test(arguments: ["tagged.mp3", "tagged.m4a", "lossless.m4a"])
    func taggedFormats(_ name: String) async throws {
        let metadata = try await loadMetadata(from: fixture(name), includeArtwork: false)
        #expect(metadata.title == "First Song")
        #expect(metadata.albumArtist == "Test Artist")
        #expect(metadata.trackNumber == 2)
        #expect(metadata.discNumber == 1)
    }

    @Test(arguments: ["tagged.flac", "tagged.mp3", "tagged.m4a", "lossless.m4a", "plain.wav", "plain.aiff", "plain.aac"])
    @MainActor func supportedFormatsLoadAndDecode(_ name: String) async throws {
        let item = try AVPlayerItem(url: fixture(name))
        // Item status only advances once attached to a player.
        let player = AVPlayer(playerItem: item)
        defer { player.replaceCurrentItem(with: nil) }
        try await eventually { item.status != .unknown }
        #expect(item.status == .readyToPlay)
        let duration = try await item.asset.load(.duration).seconds
        #expect(duration.isFinite && duration > 0)
        // Decode directly: a playback clock needs an audio device CI runners may lack.
        let track = try #require(await item.asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: item.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        #expect(reader.startReading())
        let buffer = try #require(output.copyNextSampleBuffer())
        #expect(CMSampleBufferGetNumSamples(buffer) > 0)
    }
}

extension MetadataTests {
    @Test func malformedCommentsAreSkippedAndFirstNonemptyTagWins() throws {
        let store = try TestStore()
        let entries = [Data("TITLE=".utf8), Data([0xFF]), Data("title=First".utf8),
                       Data("TITLE=Later".utf8), Data("TRACKNUMBER=3/12".utf8), Data("DISCNUMBER=2/3".utf8)]
        var comments = integer(0, littleEndian: true) + integer(entries.count, littleEndian: true)
        for entry in entries {
            comments += integer(entry.count, littleEndian: true) + entry
        }
        let tags = try FlacMetadata.read(from: store.file("tags.flac", data: flac([(4, comments)])))
        #expect(tags.title == "First" && tags.trackNumber == 3 && tags.discNumber == 2)
        let corruptLength = integer(0, littleEndian: true) + integer(1, littleEndian: true) + integer(1000, littleEndian: true)
        #expect(try FlacMetadata.read(from: store.file("bad.flac", data: flac([(4, corruptLength)]))) == TrackMetadata())
    }

    @Test func frontCoverWinsWithOtherPicturesAsFallback() throws {
        let store = try TestStore()
        func picture(_ type: Int, _ bytes: Data) -> Data {
            integer(type) + Data(repeating: 0, count: 24) + integer(bytes.count) + bytes
        }
        let back = Data([1, 2]), front = Data([3, 4])
        let file = try store.file("cover.flac", data: flac([(6, picture(4, back)), (6, picture(3, front)), (6, picture(0, back))]))
        #expect(FlacMetadata.read(from: file).artworkData == front)
        #expect(FlacMetadata.read(from: file, readArtwork: false).artworkData == nil)
        let fallback = try store.file("fallback.flac", data: flac([(6, picture(4, back))]))
        #expect(FlacMetadata.read(from: fallback).artworkData == back)
    }

    private func integer(_ value: Int, littleEndian: Bool = false) -> Data {
        let bytes = (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return Data(littleEndian ? bytes : bytes.reversed())
    }

    private func flac(_ blocks: [(UInt8, Data)]) -> Data {
        var data = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            data.append(block.0 | (index == blocks.count - 1 ? 0x80 : 0))
            data += integer(block.1.count).dropFirst()
            data += block.1
        }
        return data
    }
}
