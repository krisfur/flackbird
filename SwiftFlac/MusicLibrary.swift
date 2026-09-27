import Foundation
import Observation

struct LibraryContent {
    var playlists: [Playlist] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var allTracks: [Track] = []
}

/// Snapshot of the scanned playlists, persisted with root-relative paths
/// so launches can show the library (and restore the session) instantly
/// while the real scan refreshes in the background.
private struct LibraryCache: Codable {
    struct CachedTrack: Codable {
        var relativePath: String
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var trackNumber: Int?
        var discNumber: Int?

        init(track: Track, root: URL) {
            relativePath = NavigationPersistence.relativePath(track.url, root: root)
            title = track.title
            artist = track.artist
            album = track.album
            albumArtist = track.albumArtist
            trackNumber = track.trackNumber
            discNumber = track.discNumber
        }

        func track(root: URL) -> Track {
            Track(
                url: URL(fileURLWithPath: root.path + relativePath),
                title: title,
                artist: artist,
                album: album,
                albumArtist: albumArtist,
                trackNumber: trackNumber,
                discNumber: discNumber
            )
        }
    }

    struct CachedPlaylist: Codable {
        var name: String
        var relativeFolder: String
        var tracks: [CachedTrack]
    }

    var playlists: [CachedPlaylist]
}

@MainActor
@Observable
final class MusicLibrary {
    private(set) var playlists: [Playlist] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var allTracks: [Track] = []
    private(set) var isScanning = false
    private(set) var rootURL: URL?
    /// Bumped whenever content lands (cache or scan) so restoration can react.
    private(set) var contentVersion = 0

    private var scanGeneration = 0
    private var lastScanFinished = Date.distantPast
    private var lastFingerprint: Int?
    /// The security-scoped URL access is currently held on, so switching
    /// root folders releases the old one. Scopes are a limited resource and
    /// every start needs its matching stop.
    private var accessedURL: URL?

    private static let bookmarkKey = "libraryFolderBookmark"

    let defaults: UserDefaults
    private let cacheURL: URL
    private let scan: @Sendable (URL) async -> LibraryContent
    private let fingerprint: @Sendable (URL) -> Int
    private let now: () -> Date
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var cacheWriteTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        cacheURL: URL? = nil,
        rootURL: URL? = nil,
        startsAutomatically: Bool = true,
        scan: @escaping @Sendable (URL) async -> LibraryContent = LibraryScanner.scan,
        fingerprint: @escaping @Sendable (URL) -> Int = LibraryScanner.fingerprint,
        now: @escaping () -> Date = Date.init,
        startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.defaults = defaults
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibraryCache.json")
        self.rootURL = rootURL
        self.scan = scan
        self.fingerprint = fingerprint
        self.now = now
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        if let rootURL {
            beginAccess(to: rootURL)
        }
        if startsAutomatically {
            if rootURL == nil {
                restoreRoot()
            }
            loadCache()
            rescan()
        }
    }

    /// Also allows callers to await a rescan before consuming a snapshot.
    func waitForPendingWork() async {
        await refreshTask?.value
        await scanTask?.value
        await cacheWriteTask?.value
    }

    /// Points the library at a new root folder and persists access to it.
    func setRootFolder(_ url: URL) {
        beginAccess(to: url)
        #if os(macOS)
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
            let bookmark = try? url.bookmarkData()
        #endif
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        rootURL = url
        rescan()
    }

    /// Music can arrive while the app is backgrounded - dropped in through the
    /// Files app or Finder file sharing, or AirDropped - so coming back to the
    /// foreground picks it up instead of waiting for a relaunch.
    ///
    /// A full scan reads the tag header out of every file, which is far too
    /// much work to repeat on every app switch, so the tree is fingerprinted
    /// first and the scan only runs when that changed. Throttled as well, so
    /// flicking between apps doesn't walk the tree repeatedly.
    func refreshIfNeeded() {
        guard !isScanning,
              now().timeIntervalSince(lastScanFinished) > 2,
              let rootURL else { return }
        let generation = scanGeneration
        let fingerprint = fingerprint
        refreshTask = Task.detached(priority: .utility) {
            let fingerprint = fingerprint(rootURL)
            await MainActor.run {
                guard generation == self.scanGeneration, !self.isScanning else { return }
                guard fingerprint != self.lastFingerprint else { return }
                self.rescan()
            }
        }
    }

    func rescan() {
        scanGeneration += 1
        let generation = scanGeneration
        guard let rootURL else {
            apply(LibraryContent())
            return
        }
        isScanning = true
        let scan = scan
        let fingerprint = fingerprint
        scanTask = Task.detached(priority: .userInitiated) {
            let content = await scan(rootURL)
            let fingerprint = fingerprint(rootURL)
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.lastFingerprint = fingerprint
                self.apply(content)
            }
        }
    }

    private func apply(_ content: LibraryContent) {
        applyContent(content)
        isScanning = false
        lastScanFinished = now()
        saveCache(content.playlists)
    }

    private func applyContent(_ content: LibraryContent) {
        playlists = content.playlists
        albums = content.albums
        artists = content.artists
        allTracks = content.allTracks
        contentVersion += 1
    }

    private func loadCache() {
        guard let rootURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(LibraryCache.self, from: data),
              !cache.playlists.isEmpty else { return }
        let cachedPlaylists = cache.playlists.map { cached in
            Playlist(
                name: cached.name,
                folderURL: URL(fileURLWithPath: rootURL.path + cached.relativeFolder),
                tracks: cached.tracks.map { $0.track(root: rootURL) }
            )
        }
        applyContent(LibraryScanner.content(from: cachedPlaylists))
    }

    private func saveCache(_ playlists: [Playlist]) {
        guard let rootURL else { return }
        let previousWrite = cacheWriteTask
        let cacheURL = cacheURL
        cacheWriteTask = Task.detached(priority: .utility) {
            let cache = LibraryCache(playlists: playlists.map { playlist in
                LibraryCache.CachedPlaylist(
                    name: playlist.name,
                    relativeFolder: NavigationPersistence.relativePath(playlist.folderURL, root: rootURL),
                    tracks: playlist.tracks.map { LibraryCache.CachedTrack(track: $0, root: rootURL) }
                )
            })
            await previousWrite?.value
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// Takes security-scoped access to `url`, releasing whatever was held
    /// before. Only a successful start is recorded, since stopping a scope
    /// that never started is itself a bug.
    private func beginAccess(to url: URL) {
        guard accessedURL != url else { return }
        if let accessedURL {
            stopAccess(accessedURL)
        }
        accessedURL = startAccess(url) ? url : nil
    }

    private func restoreRoot() {
        if let data = defaults.data(forKey: Self.bookmarkKey) {
            var stale = false
            #if os(macOS)
                let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
                let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
            #endif
            if let url {
                beginAccess(to: url)
                rootURL = url
                return
            }
        }
        #if os(iOS)
            // Default to the app's Documents folder so music can be dropped in
            // via Finder/Files file sharing without any setup.
            rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif
    }
}

/// Filesystem walking and tag grouping, kept off the main actor since it
/// reads the header of every audio file in the library.
enum LibraryScanner {
    private static let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "aac", "wav", "aiff", "aif"]

    static func scan(root: URL) async -> LibraryContent {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var playlists: [Playlist] = []

        // Loose tracks sitting directly in the root form their own playlist.
        let looseTracks = await tracks(from: contents.filter(isAudioFile))
        if !looseTracks.isEmpty {
            playlists.append(Playlist(name: root.lastPathComponent, folderURL: root, tracks: looseTracks))
        }

        let folders = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for folder in folders {
            let folderTracks = await tracks(from: audioFiles(under: folder))
            if !folderTracks.isEmpty {
                playlists.append(Playlist(name: folder.lastPathComponent, folderURL: folder, tracks: folderTracks))
            }
        }

        return content(from: playlists)
    }

    /// A cheap signature of the library tree: the path and size of every audio
    /// file under the root. Enumerating costs a fraction of a scan, which opens
    /// every file to read its tags, so this is what a foreground refresh checks
    /// before deciding to do the real work.
    ///
    /// Sizes catch a file being replaced in place; file dates are deliberately
    /// not used, since reading them would drag a required-reason API (and its
    /// privacy manifest entry) in for no real gain. Editing tags without any
    /// size change still needs a manual rescan.
    static func fingerprint(root: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var entries: [String] = []
        for case let url as URL in enumerator where isAudioFile(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            entries.append("\(url.path)|\(size)")
        }
        // Enumeration order is not guaranteed, so sort before hashing.
        entries.sort()
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry)
        }
        return hasher.finalize()
    }

    /// Builds the grouped views over a set of playlists; shared between a
    /// fresh scan and the launch-time cache.
    static func content(from playlists: [Playlist]) -> LibraryContent {
        let all = playlists.flatMap(\.tracks)
        // Albums, artist pages, and All Tracks collapse copies of the same
        // song living in different folders; folders show every file.
        let unique = deduplicated(all)
        return LibraryContent(
            playlists: playlists,
            albums: albums(from: unique),
            artists: artists(from: unique),
            allTracks: unique.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        )
    }

    /// Collapses tracks sharing the same title, artist, and album tags.
    /// Untagged files are never merged, and the FLAC copy wins when the
    /// same song exists in several formats.
    private static func deduplicated(_ tracks: [Track]) -> [Track] {
        var indexForKey: [String: Int] = [:]
        var result: [Track] = []
        for track in tracks {
            guard let title = track.title else {
                result.append(track)
                continue
            }
            let key = "\(title)|\(track.artist ?? "")|\(track.album ?? "")".lowercased()
            if let index = indexForKey[key] {
                if track.url.pathExtension.lowercased() == "flac",
                   result[index].url.pathExtension.lowercased() != "flac"
                {
                    result[index] = track
                }
            } else {
                indexForKey[key] = result.count
                result.append(track)
            }
        }
        return result
    }

    /// Collects audio files anywhere below the folder, so nested album folders still play.
    private static func audioFiles(under folder: URL) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        if let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where isAudioFile(url) {
                files.append(url)
            }
        }
        return files
    }

    private static func tracks(from urls: [URL]) async -> [Track] {
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var tracks: [Track] = []
        for url in sorted {
            // FLAC gets the fast header parser; other formats go through
            // AVFoundation, which understands their ID3/iTunes tags.
            let tags: TrackMetadata = if url.pathExtension.lowercased() == "flac" {
                FlacMetadata.read(from: url, readArtwork: false)
            } else {
                await loadMetadata(from: url, includeArtwork: false)
            }
            tracks.append(Track(
                url: url,
                title: tags.title,
                artist: tags.artist,
                album: tags.album,
                albumArtist: tags.albumArtist,
                trackNumber: tags.trackNumber,
                discNumber: tags.discNumber
            ))
        }
        return tracks
    }

    private static func albums(from tracks: [Track]) -> [Album] {
        let groups = Dictionary(grouping: tracks, by: \.albumKey)
        return groups.values.map { group in
            let artists = Set(group.compactMap(\.artist))
            let artist = group[0].albumArtist
                ?? (artists.count == 1 ? artists.first : (artists.isEmpty ? nil : "Various Artists"))
            // Disc then track number, falling back to filename order for
            // untagged files.
            let sorted = group.sorted { lhs, rhs in
                let left = (lhs.discNumber ?? 1, lhs.trackNumber ?? Int.max)
                let right = (rhs.discNumber ?? 1, rhs.trackNumber ?? Int.max)
                if left != right {
                    return left < right
                }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            return Album(name: group[0].album ?? "Unknown Album", artist: artist, tracks: sorted)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func artists(from tracks: [Track]) -> [Artist] {
        Dictionary(grouping: tracks, by: \.artistName)
            .map { name, group in
                Artist(name: name, tracks: group.sorted {
                    $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
                })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        guard audioExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        // Links are rare, so resolving them costs little; broken ones and links to folders drop out.
        guard values.isSymbolicLink == true else { return values.isRegularFile == true }
        return (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
