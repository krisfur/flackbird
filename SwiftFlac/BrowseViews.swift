import ImageIO
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

#if os(iOS)
    @MainActor
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
#endif

extension String {
    /// Typographic punctuation the keyboards substitute for its ASCII
    /// equivalent. Tags are written either way, so both sides of a search
    /// are folded before comparing.
    private static let punctuationFolds: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{02BC}": "'", "\u{2032}": "'", "\u{00B4}": "'", "`": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{2033}": "\"",
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-", "\u{2013}": "-", "\u{2014}": "-", "\u{2015}": "-",
    ]

    private var foldedPunctuation: String {
        guard contains(where: { Self.punctuationFolds[$0] != nil }) else { return self }
        return String(map { Self.punctuationFolds[$0] ?? $0 })
    }

    /// Case-, diacritic- and punctuation-insensitive substring match.
    /// `localizedStandardContains` alone treats a curly apostrophe as a
    /// different character from a straight one.
    func matchesSearch(_ query: String) -> Bool {
        foldedPunctuation.localizedStandardContains(query.foldedPunctuation)
    }
}

extension View {
    /// Hides the on-screen keyboard as soon as the user scrolls the
    /// content below the search field.
    @ViewBuilder
    func dismissesSearchKeyboard() -> some View {
        #if os(iOS)
            scrollDismissesKeyboard(.immediately)
        #else
            self
        #endif
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            #endif
            if !text.isEmpty {
                Button {
                    text = ""
                    #if os(iOS)
                        hideKeyboard()
                    #endif
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.bottom, 6)
        #if os(macOS)
            // Breathing room below the window toolbar.
            .padding(.top, 10)
        #endif
    }
}

struct FoldersView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var searchText = ""

    private var filteredPlaylists: [Playlist] {
        guard !searchText.isEmpty else { return library.playlists }
        return library.playlists.filter { $0.name.matchesSearch(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, prompt: "Folder")
            List(filteredPlaylists) { playlist in
                NavigationLink(value: LibraryDestination.playlist(playlist)) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                            Text("\(playlist.tracks.count) tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder.fill")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if filteredPlaylists.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .dismissesSearchKeyboard()
            .miniBarClearance()
        }
        .background(AppBackground())
        .navigationTitle("Folders")
        .optionsToolbar()
    }
}

struct ArtistsView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var searchText = ""

    private var filteredArtists: [Artist] {
        guard !searchText.isEmpty else { return library.artists }
        return library.artists.filter { $0.name.matchesSearch(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, prompt: "Artist")
            List(filteredArtists) { artist in
                NavigationLink(value: LibraryDestination.artist(artist)) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(artist.name)
                            Text("\(artist.tracks.count) tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "music.mic")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if filteredArtists.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .dismissesSearchKeyboard()
            .miniBarClearance()
        }
        .background(AppBackground())
        .navigationTitle("Artists")
        .optionsToolbar()
    }
}

struct AlbumsView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)]

    /// Album names first; if nothing matches, fall back to the artist so
    /// an artist's name pulls up their albums.
    private var filteredAlbums: [Album] {
        guard !searchText.isEmpty else { return library.albums }
        let byName = library.albums.filter { $0.name.matchesSearch(searchText) }
        if !byName.isEmpty {
            return byName
        }
        return library.albums.filter { $0.artist?.matchesSearch(searchText) == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, prompt: "Album or Artist")
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: LibraryDestination.album(album)) {
                            AlbumCell(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .overlay {
                if filteredAlbums.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .dismissesSearchKeyboard()
            .miniBarClearance()
        }
        .background(AppBackground())
        .navigationTitle("Albums")
        .optionsToolbar()
    }
}

struct AlbumCell: View {
    let album: Album
    @Environment(\.displayScale) private var displayScale
    @State private var artwork: Image?

    /// The widest a cell gets is the grid's 200pt maximum.
    private static let drawnSize: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let artwork {
                        artwork
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle()
                                .fill(.quaternary)
                            Image(systemName: "music.note")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(album.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(album.artist ?? "Unknown Artist")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: album.id) {
            let loaded = await ArtworkStore.shared.thumbnail(
                for: album.tracks.first,
                maxPixelSize: Int(Self.drawnSize * displayScale)
            )
            guard !Task.isCancelled else { return }
            artwork = loaded
        }
    }
}

/// Boxes a decoded thumbnail: NSCache needs a class, and the decode happens
/// off the main actor. Immutable, so handing it across is safe.
final class Thumbnail: @unchecked Sendable {
    let image: CGImage
    let cost: Int

    init(_ image: CGImage) {
        self.image = image
        cost = image.bytesPerRow * image.height
    }
}

/// Decodes straight to a thumbnail no larger than `maxPixelSize`, so a 1400px
/// cover never becomes a full-size bitmap to fill a 40pt row.
func downsampled(_ data: Data, maxPixelSize: Int) -> Thumbnail? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map(Thumbnail.init)
}

/// Caches embedded artwork so grid cells and rows don't re-read files while
/// scrolling. Only the downsampled thumbnail is kept - the full cover is
/// discarded once decoded - and the cache is capped by total pixel cost, so
/// scrolling a large library cannot grow it without bound.
@MainActor
final class ArtworkStore {
    static let shared = ArtworkStore()

    private let cache = NSCache<NSString, Thumbnail>()
    /// Tracks with no embedded artwork, so they are not reopened on every
    /// scroll past. Capped too: a cache is pointless if the list of things
    /// that missed it is what grows instead.
    private var misses: Set<URL> = []

    private static let costLimit = 32 * 1024 * 1024
    private static let missLimit = 4096

    private let loadArtwork: @Sendable (URL) async -> Data?

    init(loadArtwork: @escaping @Sendable (URL) async -> Data? = {
        await loadMetadata(from: $0, includeArtwork: true).artworkData
    }) {
        self.loadArtwork = loadArtwork
        cache.totalCostLimit = Self.costLimit
    }

    /// A thumbnail for `track`, decoded to at most `maxPixelSize` on its
    /// longest side. Callers pass the pixel size they actually draw at.
    func thumbnail(for track: Track?, maxPixelSize: Int) async -> Image? {
        guard let url = track?.url else { return nil }
        let key = "\(url.path)|\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return Image(decorative: cached.image, scale: 1)
        }
        if misses.contains(url) {
            return nil
        }
        let loadArtwork = loadArtwork
        let thumbnail = await Task.detached(priority: .utility) { () -> Thumbnail? in
            guard let data = await loadArtwork(url) else { return nil }
            return downsampled(data, maxPixelSize: maxPixelSize)
        }.value
        guard let thumbnail else {
            if misses.count < Self.missLimit {
                misses.insert(url)
            }
            return nil
        }
        cache.setObject(thumbnail, forKey: key, cost: thumbnail.cost)
        // Keep the decode for the next appearance, but don't hand it to a canceled view.
        guard !Task.isCancelled else { return nil }
        return Image(decorative: thumbnail.image, scale: 1)
    }
}
