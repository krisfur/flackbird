import Foundation
@testable import SwiftFlac
import Testing

@MainActor
struct LibraryIntentsTests {
    private func library(root: URL) -> LibraryContent {
        let tracks = testTracks(root: root.appendingPathComponent("Road Trip"))
        let album = Album(name: "Beyoncé Live", artist: "Artist", tracks: Array(tracks.prefix(2)))
        return LibraryContent(playlists: [Playlist(name: "Road Trip", folderURL: root.appendingPathComponent("Road Trip"), tracks: tracks)],
                              albums: [album], artists: [Artist(name: "Artist", tracks: tracks)], allTracks: tracks)
    }

    @Test func itemsCoverFoldersAlbumsAndArtistsAndResolveBack() throws {
        let store = try TestStore()
        let content = library(root: store.root)
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
        let content = library(root: store.root)
        let player = testPlayer(store)
        let album = try #require(LibraryItemEntity.all(in: content, root: store.root).first { $0.detail.hasPrefix("Album") })
        try LibraryPlayback.play(album.id, shuffled: nil, content: content, root: store.root, player: player)
        #expect(player.queue == content.albums[0].tracks && player.currentTrack == content.albums[0].tracks[0])
        #expect(player.isPlaying && !player.isShuffling && player.libraryRoot == store.root)
    }

    @Test func shufflingTurnsShuffleOnAndStartsInsideTheItem() throws {
        let store = try TestStore()
        let content = library(root: store.root)
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
            try LibraryPlayback.play("album|gone", shuffled: nil, content: library(root: store.root), root: store.root, player: player)
        }
        #expect(throws: LibraryIntentError.empty) {
            try LibraryPlayback.play([], shuffled: true, root: store.root, player: player)
        }
        #expect(player.currentTrack == nil && !player.isShuffling)
    }
}
