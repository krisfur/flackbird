import Foundation
@testable import SwiftFlac
import Testing

struct LibraryTests {
    @Test func scansRootAndNestedFoldersButNotHiddenOrUnrelatedFiles() async throws {
        let store = try TestStore()
        let data = try Data(contentsOf: fixture("tagged.flac"))
        _ = try store.file("root.FLAC", data: data)
        _ = try store.file("Collection/Nested/song.flac", data: data)
        _ = try store.file(".hidden/secret.flac", data: data)
        _ = try store.file("Collection/notes.txt")
        try FileManager.default.createDirectory(at: store.root.appendingPathComponent("fake.flac"), withIntermediateDirectories: true)
        let content = await LibraryScanner.scan(root: store.root)
        #expect(content.playlists.count == 2)
        #expect(content.playlists.flatMap(\.tracks).count == 2)
        #expect(content.allTracks.count == 1)
        #expect(content.playlists.contains { $0.name == "Collection" })
    }

    @Test func missingOrEmptyRootProducesEmptyLibrary() async throws {
        let store = try TestStore()
        #expect(await LibraryScanner.scan(root: store.root).allTracks.isEmpty)
        #expect(await LibraryScanner.scan(root: store.root.appendingPathComponent("missing")).playlists.isEmpty)
    }

    @Test func duplicateSongsPreferFlacAndUntaggedFilesRemainDistinct() {
        let root = URL(fileURLWithPath: "/library")
        let tracks = [
            Track(url: root.appendingPathComponent("copy.mp3"), title: "Song", artist: "Artist", album: "Album"),
            Track(url: root.appendingPathComponent("original.flac"), title: "song", artist: "artist", album: "album"),
            Track(url: root.appendingPathComponent("untagged.wav")),
            Track(url: root.appendingPathComponent("other/untagged.wav")),
        ]
        let content = LibraryScanner.content(from: [Playlist(name: "Folder", folderURL: root, tracks: tracks)])
        #expect(content.playlists[0].tracks.count == 4)
        #expect(content.allTracks.count == 3)
        #expect(content.allTracks.contains { $0.url.lastPathComponent == "original.flac" })
        #expect(!content.allTracks.contains { $0.url.lastPathComponent == "copy.mp3" })
    }

    @Test func albumsUseAlbumArtistAndDiscOrder() throws {
        let root = URL(fileURLWithPath: "/library")
        let tracks = [
            Track(url: root.appendingPathComponent("a.flac"), title: "A", artist: "Guest", album: "Shared", albumArtist: "Band", trackNumber: 1, discNumber: 2),
            Track(url: root.appendingPathComponent("b.flac"), title: "B", artist: "Singer", album: "Shared", albumArtist: "Band", trackNumber: 2, discNumber: 1),
            Track(url: root.appendingPathComponent("c.flac"), title: "C", artist: "Singer", album: "Shared", albumArtist: "Band", trackNumber: 1, discNumber: 1),
            Track(url: root.appendingPathComponent("d.flac"), title: "D", artist: "Other", album: "Shared"),
        ]
        let content = LibraryScanner.content(from: [Playlist(name: "Folder", folderURL: root, tracks: tracks)])
        #expect(content.albums.count == 2)
        let album = try #require(content.albums.first { $0.artist == "Band" })
        #expect(album.tracks.map(\.title) == ["C", "B", "A"])
        #expect(content.artists.map(\.name) == ["Guest", "Other", "Singer"])
    }

    @Test func fileChangesInvalidateFingerprint() throws {
        let store = try TestStore()
        let a = try store.file("one.wav", data: Data([1]))
        let original = LibraryScanner.fingerprint(root: store.root)
        #expect(LibraryScanner.fingerprint(root: store.root) == original)
        _ = try store.file("notes.txt", data: Data([3]))
        #expect(LibraryScanner.fingerprint(root: store.root) == original)
        try Data([1, 2]).write(to: a)
        let resized = LibraryScanner.fingerprint(root: store.root)
        #expect(resized != original)
        try FileManager.default.moveItem(at: a, to: store.root.appendingPathComponent("renamed.wav"))
        #expect(LibraryScanner.fingerprint(root: store.root) != resized)
        let renamed = LibraryScanner.fingerprint(root: store.root)
        _ = try store.file("second.wav")
        #expect(LibraryScanner.fingerprint(root: store.root) != renamed)
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("second.wav"))
        #expect(LibraryScanner.fingerprint(root: store.root) == renamed)
    }

    @Test func unicodeNormalizationPreservesFileIdentity() {
        let first = Track(url: URL(fileURLWithPath: "/music/Caf\u{e9}.flac"))
        let second = Track(url: URL(fileURLWithPath: "/music/Cafe\u{301}.flac"))
        #expect(first.id == second.id)
        #expect(Set([first, second]).count == 1)
    }

    @Test @MainActor func obsoleteScanCannotReplaceNewRoot() async throws {
        let store = try TestStore()
        let oldGate = AsyncGate<LibraryContent>()
        let newGate = AsyncGate<LibraryContent>()
        let oldRoot = store.root.appendingPathComponent("old")
        let newRoot = store.root.appendingPathComponent("new")
        let library = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, startsAutomatically: false,
                                   scan: { $0 == oldRoot ? await oldGate.wait() : await newGate.wait() }, fingerprint: { _ in 0 })
        library.setRootFolder(oldRoot)
        await oldGate.waitUntilEntered()
        let oldScan = library.scanTask
        library.setRootFolder(newRoot)
        await newGate.waitUntilEntered()
        let newest = LibraryContent(allTracks: testTracks(root: newRoot))
        await newGate.finish(newest)
        await library.waitForPendingWork()
        await oldGate.finish(LibraryContent(allTracks: testTracks(root: oldRoot)))
        await oldScan?.value
        #expect(library.rootURL == newRoot)
        #expect(library.allTracks == newest.allTracks)
    }

    @Test @MainActor func unchangedRefreshDoesNotRescanAndManualRescanWorks() async throws {
        let store = try TestStore()
        var time = Date()
        let library = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, rootURL: store.root, now: { time })
        await library.waitForPendingWork()
        let initial = library.contentVersion
        time += 3
        library.refreshIfNeeded()
        await library.waitForPendingWork()
        #expect(library.contentVersion == initial)
        _ = try store.file("new.flac", data: Data(contentsOf: fixture("tagged.flac")))
        time += 3
        library.refreshIfNeeded()
        await library.waitForPendingWork()
        #expect(library.allTracks.count == 1)
        let refreshed = library.contentVersion
        library.rescan()
        await library.waitForPendingWork()
        #expect(library.contentVersion == refreshed + 1)
    }

    @Test @MainActor func rootChangesBalanceSuccessfulSecurityScopes() async throws {
        let store = try TestStore()
        var acquired: [URL] = []
        var released: [URL] = []
        let rejected = store.root.appendingPathComponent("rejected")
        let library = MusicLibrary(defaults: store.defaults, cacheURL: store.cache, startsAutomatically: false,
                                   scan: { _ in LibraryContent() }, startAccess: { acquired.append($0); return $0 != rejected },
                                   stopAccess: { released.append($0) })
        library.setRootFolder(store.root)
        library.setRootFolder(store.root)
        library.setRootFolder(rejected)
        library.setRootFolder(store.root)
        await library.waitForPendingWork()
        #expect(acquired == [store.root, rejected, store.root])
        #expect(released == [store.root])
    }
}
