import Foundation
@testable import SwiftFlac
import Testing

struct NavigationAndSearchTests {
    @Test(arguments: [("Beyoncé", "beyonce"), ("Don’t Stop", "don't stop"), ("A\u{2014}B", "a-b"), ("“Hello”", "\"hello\"")])
    func searchFoldsKeyboardAndTagDifferences(_ pair: (String, String)) {
        #expect(pair.0.matchesSearch(pair.1))
        #expect(pair.1.matchesSearch(pair.0.lowercased()))
    }

    @Test func titleSearchTakesPrecedenceOverArtistFallback() {
        let tracks = [Track(url: URL(fileURLWithPath: "/a.flac"), title: "Blue", artist: "Other"),
                      Track(url: URL(fileURLWithPath: "/b.flac"), title: "Red", artist: "Blue Artist")]
        #expect(TrackSearch.filter(tracks, query: "Blue") == [tracks[0]])
        #expect(TrackSearch.filter(tracks, query: "Blue Artist") == [tracks[1]])
        #expect(TrackSearch.filter(tracks, query: "").count == 2)
        #expect(TrackSearch.filter(tracks, query: "absent").isEmpty)
    }

    @Test func navigationSurvivesContainerRelocationAndMissingDestinations() {
        let oldRoot = URL(fileURLWithPath: "/old/Music")
        let root = URL(fileURLWithPath: "/new/Music")
        let old = Playlist(name: "Folder", folderURL: oldRoot.appendingPathComponent("Folder"), tracks: [])
        let current = Playlist(name: "Folder", folderURL: root.appendingPathComponent("Folder"), tracks: [])
        let content = LibraryContent(playlists: [current])
        let token = NavigationPersistence.token(for: .playlist(old), root: oldRoot)
        #expect(NavigationPersistence.resolve(token, content: content, root: root) == .playlist(current))
        let path = NavigationPersistence.restoredPath([token, "album|deleted", "nowPlaying"]) {
            NavigationPersistence.resolve($0, content: content, root: root)
        }
        #expect(path == [.playlist(current)])
        #expect(NavigationPersistence.relativePath(URL(fileURLWithPath: "/new/MusicOther/song"), root: root) == "/new/MusicOther/song")
        let aliased = URL(fileURLWithPath: "/private/var/Music/A/song.flac")
        #expect(NavigationPersistence.relativePath(aliased, root: URL(fileURLWithPath: "/var/Music")) == "/A/song.flac")
    }

    @Test func artistAndAlbumWithSameNameHaveDistinctDestinations() {
        let artist = Artist(name: "Shared", tracks: [])
        let album = Album(name: "Shared", artist: "Shared", tracks: [])
        let content = LibraryContent(albums: [album], artists: [artist])
        for destination in [LibraryDestination.artist(artist), .album(album)] {
            let token = NavigationPersistence.token(for: destination, root: nil)
            #expect(NavigationPersistence.resolve(token, content: content, root: nil) == destination)
        }
    }

    @Test(arguments: [true, false]) func nowPlayingIsDeferredOnRestore(hasTrack: Bool) {
        var path: [LibraryDestination] = [.nowPlaying]
        var forward: [LibraryDestination] = []
        NavigationPersistence.deferNowPlaying(path: &path, forward: &forward, hasTrack: hasTrack)
        #expect(path.isEmpty)
        #expect(forward == (hasTrack ? [.nowPlaying] : []))
        guard !hasTrack else { return }
        forward = [.nowPlaying]
        NavigationPersistence.deferNowPlaying(path: &path, forward: &forward, hasTrack: false)
        #expect(forward.isEmpty)
    }
}
