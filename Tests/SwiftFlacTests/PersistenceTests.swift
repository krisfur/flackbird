import Foundation
@testable import SwiftFlac
import Testing

@MainActor
struct PersistenceTests {
    @Test func sessionRestoresPausedAfterRelocationIncludingOriginalOrder() async throws {
        let store = try TestStore()
        let oldRoot = store.root.appendingPathComponent("old")
        let newRoot = store.root.appendingPathComponent("new")
        let tracks = testTracks(root: oldRoot)
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport)
        player.libraryRootPath = oldRoot.path
        player.play(tracks[1], in: tracks)
        try await eventually { player.duration == 120 }
        player.toggleShuffle()
        player.cycleRepeatMode()
        player.seek(to: 35)
        transport.completeSeek()
        try await eventually { store.defaults.double(forKey: "sessionTime") == 35 }
        let restored = testPlayer(store)
        restored.libraryRootPath = newRoot.path
        let relocated = testTracks(root: newRoot)
        restored.restoreSession(from: relocated)
        #expect(!restored.isPlaying && restored.currentTrack == relocated[1])
        #expect(restored.currentTime == 35 && restored.isShuffling && restored.repeatMode == .all)
        #expect(Set(restored.queue) == Set(relocated))
        restored.toggleShuffle()
        #expect(restored.queue == relocated)
        restored.next()
        restored.restoreSession(from: relocated)
        #expect(restored.currentTrack == relocated[2])
    }

    @Test func missingTracksAreDroppedWithoutOverridingFreshSelection() throws {
        let store = try TestStore()
        let tracks = testTracks(root: store.root)
        let player = testPlayer(store)
        player.play(tracks[1], in: tracks)
        let restored = testPlayer(store)
        restored.restoreSession(from: Array(tracks.dropFirst()))
        #expect(restored.queue == Array(tracks.dropFirst()))
        #expect(restored.currentTrack == tracks[1])
        let fresh = testPlayer(store)
        fresh.play(tracks[2], in: tracks)
        fresh.restoreSession(from: tracks)
        #expect(fresh.currentTrack == tracks[2] && fresh.isPlaying)
        let deleted = testPlayer(store)
        deleted.restoreSession(from: [tracks[0]])
        #expect(deleted.currentTrack == nil && deleted.queue.isEmpty)
    }

    @Test func invalidStateFallsBackAndOldSessionsStillRestore() throws {
        let store = try TestStore()
        let tracks = testTracks(root: store.root)
        store.defaults.set([tracks[0].url.path], forKey: "sessionQueuePaths")
        store.defaults.set(tracks[0].url.path, forKey: "sessionTrackPath")
        store.defaults.set(-80, forKey: "sessionTime")
        store.defaults.set("invalid", forKey: "playerRepeatMode")
        let player = testPlayer(store)
        player.restoreSession(from: tracks)
        #expect(player.currentTrack == tracks[0] && player.currentTime == 0)
        #expect(player.repeatMode == .off && !player.isPlaying)
        player.toggleShuffle()
        player.toggleShuffle()
        #expect(player.queue == [tracks[0]])
        store.defaults.set("corrupt", forKey: "sessionQueuePaths")
        let corrupt = testPlayer(store)
        corrupt.restoreSession(from: tracks)
        #expect(corrupt.queue.isEmpty)
    }

    @Test func libraryCacheRelocatesThenRefreshesWithNewestSnapshot() async throws {
        let store = try TestStore()
        _ = try store.file("old/one.flac", data: Data(contentsOf: fixture("tagged.flac")))
        let oldRoot = store.root.appendingPathComponent("old")
        let library = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, rootURL: oldRoot)
        await library.waitForPendingWork()
        let gate = AsyncGate<LibraryContent>()
        let newRoot = store.root.appendingPathComponent("new")
        let relocated = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, rootURL: newRoot,
                                     scan: { _ in await gate.wait() })
        #expect(relocated.allTracks.first?.url == newRoot.appendingPathComponent("one.flac"))
        #expect(relocated.allTracks.first?.title == "First Song")
        await gate.waitUntilEntered()
        await gate.finish(LibraryContent())
        await relocated.waitForPendingWork()
        #expect(relocated.allTracks.isEmpty)
        let final = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, rootURL: newRoot)
        #expect(final.allTracks.isEmpty)
        await final.waitForPendingWork()
    }

    @Test func corruptCacheRecoversFromFilesystem() async throws {
        let store = try TestStore()
        _ = try store.file("song.flac", data: Data(contentsOf: fixture("tagged.flac")))
        try Data("invalid json".utf8).write(to: store.cache)
        let library = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, rootURL: store.root)
        #expect(library.allTracks.isEmpty)
        await library.waitForPendingWork()
        #expect(library.allTracks.first?.title == "First Song")
    }
}
