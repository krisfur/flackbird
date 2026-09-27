import AppIntents
import Foundation

/// A folder, album, or artist that Siri and Shortcuts can play. The id is the
/// navigation token, so it survives rescans the same way restored screens do.
struct LibraryItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static let defaultQuery = LibraryItemQuery()

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    static func all(in content: LibraryContent, root: URL?) -> [LibraryItemEntity] {
        func item(_ destination: LibraryDestination, _ name: String, _ detail: String) -> LibraryItemEntity {
            LibraryItemEntity(id: NavigationPersistence.token(for: destination, root: root), name: name, detail: detail)
        }
        return content.playlists.map { item(.playlist($0), $0.name, "Folder") }
            + content.albums.map { item(.album($0), $0.name, $0.artist.map { "Album by \($0)" } ?? "Album") }
            + content.artists.map { item(.artist($0), $0.name, "Artist") }
    }
}

struct LibraryItemQuery: EntityStringQuery {
    @Dependency private var library: MusicLibrary

    @MainActor
    func entities(for identifiers: [String]) async throws -> [LibraryItemEntity] {
        let items = LibraryItemEntity.all(in: library.content, root: library.rootURL)
        return identifiers.compactMap { id in items.first { $0.id == id } }
    }

    /// Siri hands over what it heard; the app's search folding absorbs accents and punctuation.
    @MainActor
    func entities(matching string: String) async throws -> [LibraryItemEntity] {
        LibraryItemEntity.all(in: library.content, root: library.rootURL).filter { $0.name.matchesSearch(string) }
    }

    /// Also what Siri learns names from, via updateAppShortcutParameters.
    @MainActor
    func suggestedEntities() async throws -> [LibraryItemEntity] {
        LibraryItemEntity.all(in: library.content, root: library.rootURL)
    }
}

enum LibraryIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notFound, empty

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound: "That isn't in your SwiftFlac library."
        case .empty: "There's nothing to play in your SwiftFlac library yet."
        }
    }
}

enum LibraryPlayback {
    @MainActor
    static func play(_ token: String, shuffled: Bool?, content: LibraryContent, root: URL?,
                     player: PlayerController) throws
    {
        guard let destination = NavigationPersistence.resolve(token, content: content, root: root) else {
            throw LibraryIntentError.notFound
        }
        try play(tracks(for: destination), shuffled: shuffled, root: root, player: player)
    }

    /// `shuffled` nil keeps the current mode. Shuffled playback starts on a random track.
    @MainActor
    static func play(_ tracks: [Track], shuffled: Bool?, root: URL?, player: PlayerController) throws {
        guard let first = tracks.first else { throw LibraryIntentError.empty }
        // A background launch has no UI to set this before the session is saved.
        player.libraryRoot = root
        if let shuffled {
            player.setShuffle(shuffled)
        }
        player.play(player.isShuffling ? tracks.randomElement() ?? first : first, in: tracks)
    }

    static func tracks(for destination: LibraryDestination) -> [Track] {
        switch destination {
        case let .playlist(playlist): playlist.tracks
        case let .album(album): album.tracks
        case let .artist(artist): artist.tracks
        case .nowPlaying: []
        }
    }
}

struct PlayLibraryItemIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays a folder, album, or artist from your library.")

    @Parameter(title: "Music")
    var item: LibraryItemEntity

    @Dependency private var library: MusicLibrary
    @Dependency private var player: PlayerController

    @MainActor
    func perform() async throws -> some IntentResult {
        try LibraryPlayback.play(item.id, shuffled: nil, content: library.content, root: library.rootURL, player: player)
        return .result()
    }
}

struct ShuffleLibraryItemIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Music"
    static let description = IntentDescription("Shuffles a folder, album, or artist from your library.")

    @Parameter(title: "Music")
    var item: LibraryItemEntity

    @Dependency private var library: MusicLibrary
    @Dependency private var player: PlayerController

    @MainActor
    func perform() async throws -> some IntentResult {
        try LibraryPlayback.play(item.id, shuffled: true, content: library.content, root: library.rootURL, player: player)
        return .result()
    }
}

struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Shuffles every track in your library.")

    @Dependency private var library: MusicLibrary
    @Dependency private var player: PlayerController

    @MainActor
    func perform() async throws -> some IntentResult {
        try LibraryPlayback.play(library.allTracks, shuffled: true, root: library.rootURL, player: player)
        return .result()
    }
}

struct SwiftFlacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayLibraryItemIntent(), phrases: [
            "Play \(\.$item) in \(.applicationName)",
            "Play \(\.$item) with \(.applicationName)",
            "Play \(\.$item) on \(.applicationName)",
            "Play music in \(.applicationName)",
        ], shortTitle: "Play Music", systemImageName: "play.fill")
        AppShortcut(intent: ShuffleLibraryItemIntent(), phrases: [
            "Shuffle \(\.$item) in \(.applicationName)",
            "Shuffle \(\.$item) with \(.applicationName)",
            "Shuffle \(\.$item) on \(.applicationName)",
        ], shortTitle: "Shuffle Music", systemImageName: "shuffle")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: [
            "Shuffle my library in \(.applicationName)",
            "Shuffle everything in \(.applicationName)",
            "Shuffle \(.applicationName)",
        ], shortTitle: "Shuffle Library", systemImageName: "shuffle.circle")
    }
}
