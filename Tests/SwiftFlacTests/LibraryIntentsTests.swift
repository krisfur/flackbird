import Foundation
@testable import SwiftFlac
import Testing

@MainActor
struct LibraryIntentsTests {
    private func sampleContent(root: URL) -> LibraryContent {
        let tracks = testTracks(root: root.appendingPathComponent("Road Trip"))
        let album = Album(name: "Beyoncé Live", artist: "Artist", tracks: Array(tracks.prefix(2)))
        return LibraryContent(playlists: [Playlist(name: "Road Trip", folderURL: root.appendingPathComponent("Road Trip"), tracks: tracks)],
                              albums: [album], artists: [Artist(name: "Artist", tracks: tracks)], allTracks: tracks)
    }

    @Test func itemsCoverFoldersAlbumsAndArtistsAndResolveBack() throws {
        let store = try TestStore()
        let content = sampleContent(root: store.root)
        let items = LibraryItemEntity.all(in: content, root: store.root)
        #expect(items.map(\.detail) == ["Folder", "Album by Artist", "Artist"])
        #expect(Set(items.map(\.id)).count == 3)
        for item in items {
            #expect(NavigationPersistence.resolve(item.id, content: content, root: store.root) != nil)
        }
        #expect(items.filter { $0.name.matchesSearch("beyonce live") }.map(\.name) == ["Beyoncé Live"])
    }

    @Test func playingAnItemQueuesItsTracksInOrderAndKeepsTheMode() throws {
        let store = try TestStore()
        let content = sampleContent(root: store.root)
        let player = testPlayer(store)
        let album = try #require(LibraryItemEntity.all(in: content, root: store.root).first { $0.detail.hasPrefix("Album") })
        try LibraryPlayback.play(album.id, shuffled: nil, content: content, root: store.root, player: player)
        #expect(player.queue == content.albums[0].tracks && player.currentTrack == content.albums[0].tracks[0])
        #expect(player.isPlaying && !player.isShuffling)
    }

    @Test func shufflingTurnsShuffleOnAndStartsInsideTheItem() throws {
        let store = try TestStore()
        let content = sampleContent(root: store.root)
        let player = testPlayer(store)
        let folder = try #require(LibraryItemEntity.all(in: content, root: store.root).first)
        try LibraryPlayback.play(folder.id, shuffled: true, content: content, root: store.root, player: player)
        #expect(player.isShuffling && player.isPlaying)
        #expect(Set(player.queue) == Set(content.playlists[0].tracks))
        #expect(player.queue.first == player.currentTrack)
    }

    @Test func missingItemsAndEmptyLibrariesFailWithoutTouchingPlayback() throws {
        let store = try TestStore()
        let player = testPlayer(store)
        #expect(throws: LibraryIntentError.notFound) {
            try LibraryPlayback.play("album|gone", shuffled: nil, content: sampleContent(root: store.root), root: store.root, player: player)
        }
        #expect(throws: LibraryIntentError.empty) {
            try LibraryPlayback.play([], shuffled: true, player: player)
        }
        #expect(player.currentTrack == nil && !player.isShuffling)
    }

    @Test func exactNamesWinOverPartialMatches() throws {
        let store = try TestStore()
        let content = LibraryContent(albums: [Album(name: "Blue", artist: "A", tracks: []), Album(name: "Blue Train", artist: "B", tracks: [])],
                                     artists: [Artist(name: "Blue", tracks: [])])
        #expect(LibraryItemEntity.matching("blue", in: content, root: store.root).map(\.detail) == ["Album by A", "Artist"])
        #expect(LibraryItemEntity.matching("blu", in: content, root: store.root).count == 3)
    }

    @Test func intentsWaitForAScanInProgressAndContentChangesAreReported() async throws {
        let store = try TestStore()
        let gate = AsyncGate<LibraryContent>()
        var reportedRoots: [URL?] = []
        let library = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, rootURL: store.root,
                                   scan: { _ in await gate.wait() }, fingerprint: { _ in 0 },
                                   onContentChange: { reportedRoots.append($0.rootURL) })
        let settled = Task { await library.settledContent() }
        await gate.waitUntilEntered()
        await gate.finish(sampleContent(root: store.root))
        #expect(await settled.value.allTracks.count == 3)
        #expect(reportedRoots == [store.root])
    }
}
