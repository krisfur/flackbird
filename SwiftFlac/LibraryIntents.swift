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

    static func entity(for destination: LibraryDestination, root: URL?) -> LibraryItemEntity? {
        let id = NavigationPersistence.token(for: destination, root: root)
        switch destination {
        case let .playlist(playlist): return LibraryItemEntity(id: id, name: playlist.name, detail: "Folder")
        case let .album(album):
            return LibraryItemEntity(id: id, name: album.name, detail: album.artist.map { "Album by \($0)" } ?? "Album")
        case let .artist(artist): return LibraryItemEntity(id: id, name: artist.name, detail: "Artist")
        case .nowPlaying: return nil
        }
    }

    static func all(in content: LibraryContent, root: URL?) -> [LibraryItemEntity] {
        let destinations = content.playlists.map(LibraryDestination.playlist)
            + content.albums.map(LibraryDestination.album)
            + content.artists.map(LibraryDestination.artist)
        return destinations.compactMap { entity(for: $0, root: root) }
    }

    /// Exact names win, so "Blue" doesn't also offer everything containing it.
    static func matching(_ query: String, in content: LibraryContent, root: URL?) -> [LibraryItemEntity] {
        let matches = all(in: content, root: root).filter { $0.name.matchesSearch(query) }
        let exact = matches.filter { $0.name.matchesSearchExactly(query) }
        return exact.isEmpty ? matches : exact
    }
}

extension MusicLibrary {
    /// Intents can arrive on a cold launch or mid-scan; wait rather than report missing music.
    func settledContent() async -> LibraryContent {
        if isScanning || allTracks.isEmpty {
            await waitForPendingWork()
        }
        return content
    }
}

struct LibraryItemQuery: EntityStringQuery {
    @Dependency private var library: MusicLibrary

    @MainActor
    func entities(for identifiers: [String]) async throws -> [LibraryItemEntity] {
        let content = await library.settledContent()
        return identifiers.compactMap { id in
            NavigationPersistence.resolve(id, content: content, root: library.rootURL)
                .flatMap { LibraryItemEntity.entity(for: $0, root: library.rootURL) }
        }
    }

    /// Siri hands over what it heard; the app's search folding absorbs accents and punctuation.
    @MainActor
    func entities(matching string: String) async throws -> [LibraryItemEntity] {
        await LibraryItemEntity.matching(string, in: library.settledContent(), root: library.rootURL)
    }

    /// Also what Siri learns names from, via updateAppShortcutParameters.
    @MainActor
    func suggestedEntities() async throws -> [LibraryItemEntity] {
        await LibraryItemEntity.all(in: library.settledContent(), root: library.rootURL)
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
        try play(tracks(for: destination), shuffled: shuffled, player: player)
    }

    /// `shuffled` nil keeps the current mode. Shuffled playback starts on a random track.
    @MainActor
    static func play(_ tracks: [Track], shuffled: Bool?, player: PlayerController) throws {
        guard let first = tracks.first else { throw LibraryIntentError.empty }
        let shuffling = shuffled ?? player.isShuffling
        player.play(shuffling ? tracks.randomElement() ?? first : first, in: tracks, shuffled: shuffling)
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
        try await LibraryPlayback.play(item.id, shuffled: nil, content: library.settledContent(), root: library.rootURL, player: player)
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
        try await LibraryPlayback.play(item.id, shuffled: true, content: library.settledContent(), root: library.rootURL, player: player)
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
        try await LibraryPlayback.play(library.settledContent().allTracks, shuffled: true, player: player)
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
