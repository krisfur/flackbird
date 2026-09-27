import Foundation

/// Stable navigation tokens survive rescans and app-container relocation.
enum NavigationPersistence {
    static func relativePath(_ url: URL, root: URL?) -> String {
        let path = normalizedPath(url)
        guard let root else { return path }
        let rootPath = normalizedPath(root)
        if rootPath == "/" {
            return path
        }
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count))
    }

    /// Enumeration can report /var and /tmp through their /private targets. Folded as
    /// a string op: resolving symlinks would hit the disk for every track.
    private static func normalizedPath(_ url: URL) -> String {
        let path = url.canonicalFileURL.path
        for alias in ["/private/var", "/private/tmp"] where path == alias || path.hasPrefix(alias + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    static func token(for destination: LibraryDestination, root: URL?) -> String {
        switch destination {
        case let .playlist(playlist): "playlist|\(relativePath(playlist.folderURL, root: root))"
        case let .album(album): "album|\(album.id)"
        case let .artist(artist): "artist|\(artist.name)"
        case .nowPlaying: "nowPlaying"
        }
    }

    static func resolve(_ token: String, content: LibraryContent, root: URL?) -> LibraryDestination? {
        let parts = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let kind = parts.first else { return nil }
        let value = parts.count > 1 ? String(parts[1]) : ""
        switch kind {
        case "playlist": return content.playlists.first { relativePath($0.folderURL, root: root) == value }.map(LibraryDestination.playlist)
        case "album": return content.albums.first { $0.id == value }.map(LibraryDestination.album)
        case "artist": return content.artists.first { $0.name == value }.map(LibraryDestination.artist)
        case "nowPlaying": return .nowPlaying
        default: return nil
        }
    }

    static func restoredPath(_ tokens: [String], resolve: (String) -> LibraryDestination?) -> [LibraryDestination] {
        var path: [LibraryDestination] = []
        for token in tokens {
            guard let destination = resolve(token) else { break }
            path.append(destination)
        }
        return path
    }

    static func deferNowPlaying(path: inout [LibraryDestination], forward: inout [LibraryDestination], hasTrack: Bool) {
        if path.last == .nowPlaying {
            path.removeLast()
            if hasTrack {
                forward.append(.nowPlaying)
            }
        }
        if !hasTrack {
            forward.removeAll { $0 == .nowPlaying }
        }
    }
}

enum TrackSearch {
    static func filter(_ tracks: [Track], query: String) -> [Track] {
        guard !query.isEmpty else { return tracks }
        let titles = tracks.filter { $0.displayTitle.matchesSearch(query) }
        return titles.isEmpty ? tracks.filter { $0.artist?.matchesSearch(query) == true } : titles
    }
}
