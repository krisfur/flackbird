import Foundation
@testable import SwiftFlac
import Testing

struct ArtworkTests {
    @Test func embeddedCoverDownsamplesAndBadImagesFallBack() throws {
        let data = try #require(FlacMetadata.read(from: fixture("sample.flac")).artworkData)
        let thumbnail = try #require(downsampled(data, maxPixelSize: 40))
        #expect(max(thumbnail.image.width, thumbnail.image.height) <= 40)
        #expect(min(thumbnail.image.width, thumbnail.image.height) > 0)
        #expect(downsampled(Data("bad image".utf8), maxPixelSize: 40) == nil)
        #expect(artworkImage(from: nil) == nil)
    }

    @Test @MainActor func cacheReusesArtworkAndSeparatesSizesAndMisses() async throws {
        actor Loader {
            var requests = 0
            let data: Data
            init(_ data: Data) {
                self.data = data
            }

            func load(_ url: URL) -> Data? {
                requests += 1
                return url.lastPathComponent == "missing" ? nil : data
            }
        }
        let data = try #require(FlacMetadata.read(from: fixture("sample.flac")).artworkData)
        let loader = Loader(data)
        let store = ArtworkStore(loadArtwork: { await loader.load($0) })
        let track = Track(url: URL(fileURLWithPath: "/cover.flac"))
        #expect(await store.thumbnail(for: track, maxPixelSize: 40) != nil)
        #expect(await store.thumbnail(for: track, maxPixelSize: 40) != nil)
        #expect(await loader.requests == 1)
        #expect(await store.thumbnail(for: track, maxPixelSize: 200) != nil)
        #expect(await loader.requests == 2)
        let missing = Track(url: URL(fileURLWithPath: "/missing"))
        #expect(await store.thumbnail(for: missing, maxPixelSize: 40) == nil)
        #expect(await store.thumbnail(for: missing, maxPixelSize: 200) == nil)
        #expect(await loader.requests == 3)
    }
}

extension ArtworkTests {
    @Test @MainActor func canceledLoadStillCachesTheDecode() async throws {
        actor Calls {
            var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let gate = AsyncGate<Data?>()
        let calls = Calls()
        // Only the first load has artwork, so an uncached second load misses.
        let store = ArtworkStore(loadArtwork: { _ in await calls.next() == 1 ? await gate.wait() : nil })
        let track = Track(url: URL(fileURLWithPath: "/old.flac"))
        let pending = Task { await store.thumbnail(for: track, maxPixelSize: 40) }
        await gate.waitUntilEntered()
        pending.cancel()
        let data = try #require(FlacMetadata.read(from: fixture("sample.flac")).artworkData)
        await gate.finish(data)
        _ = await pending.value
        #expect(await store.thumbnail(for: track, maxPixelSize: 40) != nil)
        #expect(await calls.count == 1)
    }
}
