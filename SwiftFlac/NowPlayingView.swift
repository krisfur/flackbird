import AVKit
import SwiftUI
#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

func artworkImage(from data: Data?) -> Image? {
    guard let data else { return nil }
    #if canImport(UIKit)
        return UIImage(data: data).map(Image.init(uiImage:))
    #else
        return NSImage(data: data).map(Image.init(nsImage:))
    #endif
}

struct NowPlayingBar: View {
    @Environment(PlayerController.self) private var player
    @Environment(\.displayScale) private var displayScale
    @State private var artwork: Image?
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProgressLine(progress: player.duration > 0 ? player.currentTime / player.duration : 0)
            HStack(spacing: 14) {
                // Only this leading region opens the full player, so the
                // transport buttons never race against the tap gesture.
                HStack(spacing: 14) {
                    ArtworkView(image: artwork, size: 40, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.displayTitle)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let artist = player.nowPlaying.artist {
                            Text(artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                ShuffleButton(compact: true)
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.body)
                }
                .accessibilityLabel("Previous Track")
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 24)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                }
                .accessibilityLabel("Next Track")
                RepeatButton(compact: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        // The bar redraws twice a second as the progress line advances, so
        // the thumbnail is resolved once per track instead of in body.
        .task(id: player.currentTrack?.url) {
            let loaded = await ArtworkStore.shared.thumbnail(
                for: player.currentTrack,
                maxPixelSize: Int(40 * displayScale)
            )
            guard !Task.isCancelled else { return }
            artwork = loaded
        }
    }
}

struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.quaternary)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

struct ShuffleButton: View {
    @Environment(PlayerController.self) private var player
    var compact = false

    var body: some View {
        Button {
            player.toggleShuffle()
        } label: {
            ToggleIcon(systemName: "shuffle", active: player.isShuffling, compact: compact)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle")
        .accessibilityValue(player.isShuffling ? "On" : "Off")
    }
}

struct RepeatButton: View {
    @Environment(PlayerController.self) private var player
    var compact = false

    var body: some View {
        Button {
            player.cycleRepeatMode()
        } label: {
            ToggleIcon(
                systemName: player.repeatMode == .one ? "repeat.1" : "repeat",
                active: player.repeatMode != .off,
                compact: compact
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Repeat")
        .accessibilityValue(repeatValue)
    }

    private var repeatValue: String {
        switch player.repeatMode {
        case .off: "Off"
        case .all: "All Tracks"
        case .one: "This Track"
        }
    }
}

/// Active state gets an accent chip behind the icon so on/off is
/// obvious in both light and dark mode.
struct ToggleIcon: View {
    let systemName: String
    let active: Bool
    var compact = false

    var body: some View {
        Image(systemName: systemName)
            .font(compact ? .footnote : .title3)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .padding(compact ? 4 : 6)
            .background(
                active ? Color.accentColor.opacity(0.22) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}

struct NowPlayingView: View {
    @Environment(PlayerController.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.libraryNavigate) private var libraryNavigate
    @State private var dragFraction: Double?
    @State private var artwork: Image?
    @State private var artworkMenu = GoToMenuController()
    @State private var infoMenu = GoToMenuController()

    /// Matched on tags, the same way the library groups them: the playing
    /// track is not necessarily one of the deduplicated copies the album and
    /// artist lists were built from, so it can be absent from their tracks.
    private var currentAlbum: Album? {
        guard let track = player.currentTrack else { return nil }
        return library.albums.first { $0.tracks.first?.albumKey == track.albumKey }
    }

    private var currentArtist: Artist? {
        guard let track = player.currentTrack else { return nil }
        return library.artists.first { $0.name == track.artistName }
    }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                // Landscape: artwork beside the controls instead of above them.
                HStack(spacing: 40) {
                    artwork(fitting: geo.size, landscape: true)
                    VStack(spacing: 28) {
                        info
                        scrubber
                        transport
                    }
                    .frame(maxWidth: 440)
                }
                .padding(32)
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                VStack(spacing: 24) {
                    Spacer(minLength: 0)
                    artwork(fitting: geo.size, landscape: false)
                    info
                    scrubber
                    transport
                    Spacer(minLength: 0)
                }
                .padding(32)
                // Pin to the container size: the iOS 26 Slider reports more
                // width than proposed, which would otherwise inflate the
                // stack and hang the overflow off the trailing edge.
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(AppBackground())
        // Full resolution here - this is the one place artwork is shown big -
        // but decoded once per track, not on every tick of the scrubber.
        .task(id: player.nowPlaying.artworkData) {
            artwork = artworkImage(from: player.nowPlaying.artworkData)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 540)
        .overlay(alignment: .topTrailing) {
            AirPlayButton(player: player.routePickerPlayer)
                .frame(width: 24, height: 24)
                .padding(12)
        }
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AirPlayButton(player: player.routePickerPlayer)
                    .frame(width: 28, height: 28)
            }
        }
        #endif
    }

    private func artwork(fitting size: CGSize, landscape: Bool) -> some View {
        // Reserve room for the controls: beside the artwork in landscape,
        // below it (~280pt) in portrait.
        let side = landscape
            ? min(size.height - 64, size.width * 0.45, 320)
            : min(size.width - 64, size.height - 280, 320)
        return goToTarget(artworkMenu) {
            ArtworkView(image: artwork, size: max(side, 120), cornerRadius: 12)
                .shadow(radius: 10)
        }
    }

    private var info: some View {
        goToTarget(infoMenu) {
            VStack(spacing: 4) {
                Text(player.displayTitle)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    /// The album/artist jumps, opened by tapping anywhere on the label.
    @ViewBuilder
    private func goToTarget(_ controller: GoToMenuController, @ViewBuilder label: () -> some View) -> some View {
        #if os(macOS)
            Menu {
                ForEach(goToItems, id: \.id) { item in
                    Button(item.title, systemImage: item.systemImage, action: item.action)
                }
            } label: {
                label()
            }
            .buttonStyle(.plain)
        #else
            label().goToMenu(controller, items: goToItems)
        #endif
    }

    private var goToItems: [GoToItem] {
        var items: [GoToItem] = []
        if let album = currentAlbum {
            items.append(GoToItem(id: "album|\(album.id)", title: "Go to Album", systemImage: "square.stack") {
                libraryNavigate(.album(album))
            })
        }
        if let artist = currentArtist {
            items.append(GoToItem(id: "artist|\(artist.name)", title: "Go to Artist", systemImage: "music.mic") {
                libraryNavigate(.artist(artist))
            })
        }
        // Alphabetical by title, so the two places this menu opens from agree.
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Custom scrubber instead of Slider: the iOS 26 system slider opens
    /// phantom editing sessions and echoes stale values through its binding
    /// around track changes, which repeatedly froze this view.
    private var scrubber: some View {
        let playbackFraction = player.duration > 0 ? player.currentTime / player.duration : 0
        return VStack(spacing: 4) {
            ScrubberBar(fraction: dragFraction ?? playbackFraction) { fraction, ended in
                if ended {
                    dragFraction = nil
                    player.seek(to: fraction * player.duration)
                } else {
                    dragFraction = fraction
                }
            }
            HStack {
                Text(formatted((dragFraction ?? playbackFraction) * player.duration))
                Spacer()
                Text(formatted(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var transport: some View {
        HStack(spacing: 36) {
            ShuffleButton()
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            .accessibilityLabel("Previous Track")
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .frame(width: 52)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
            .accessibilityLabel("Next Track")
            RepeatButton()
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        [player.nowPlaying.artist, player.nowPlaying.album]
            .compactMap(\.self)
            .joined(separator: " - ")
    }

    private func formatted(_ time: TimeInterval) -> String {
        Duration.seconds(time).formatted(.time(pattern: .minuteSecond))
    }
}

#if os(iOS)
    struct AirPlayButton: UIViewRepresentable {
        let player: AVPlayer?

        func makeUIView(context _: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.backgroundColor = .clear
            picker.tintColor = .secondaryLabel
            picker.activeTintColor = .label
            return picker
        }

        func updateUIView(_: AVRoutePickerView, context _: Context) {}
    }
#else
    struct AirPlayButton: NSViewRepresentable {
        let player: AVPlayer?

        func makeNSView(context _: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.player = player
            picker.isRoutePickerButtonBordered = false
            return picker
        }

        func updateNSView(_: AVRoutePickerView, context _: Context) {}
    }
#endif

/// A capsule progress bar with drag-to-seek. `onScrub` is called with the
/// dragged fraction and whether the touch has ended.
struct ScrubberBar: View {
    let fraction: Double
    let onScrub: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), 8))
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(min(max(value.location.x / geo.size.width, 0), 1), false)
                    }
                    .onEnded { value in
                        onScrub(min(max(value.location.x / geo.size.width, 0), 1), true)
                    }
            )
        }
        .frame(height: 28)
    }
}

/// One entry in the go-to menu. `id` identifies the destination, not the
/// row, so the menu can tell a genuine change from a redraw.
struct GoToItem {
    let id: String
    let title: String
    let systemImage: String
    let action: () -> Void
}

/// Opens the menu owned by a `GoToMenuAnchor`. Unused on macOS, which can use
/// a plain SwiftUI Menu.
@MainActor
final class GoToMenuController {
    #if os(iOS)
        weak var button: UIButton?

        func open() {
            if #available(iOS 17.4, *) {
                button?.performPrimaryAction()
            }
        }
    #endif
}

#if os(iOS)
    /// A hidden UIButton that exists purely to be the menu's anchor rect.
    ///
    /// SwiftUI's Menu offers no control over where its popup lands: it centres
    /// on the label and pins to the label's top edge, so making a 320pt album
    /// cover the label drops the menu inside the cover's own top corner. UIKit
    /// anchors to the button's frame, so a small button positioned where the
    /// menu belongs places it exactly, while the cover stays fully tappable
    /// through a separate transparent tap area.
    private struct GoToMenuAnchor: UIViewRepresentable {
        let controller: GoToMenuController
        let items: [GoToItem]

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context _: Context) -> UIButton {
            let button = UIButton(type: .custom)
            button.showsMenuAsPrimaryAction = true
            // A menu with no room below it opens upward, and UIKit reverses
            // the rows so the first sits nearest the anchor - which flipped
            // this menu depending on which of the two targets opened it.
            button.preferredMenuElementOrder = .fixed
            controller.button = button
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            controller.button = button
            // The now-playing body re-runs twice a second as the scrubber
            // advances. Replacing a live UIMenu that often makes an open
            // popup pulse, so it is rebuilt only when the destinations
            // themselves change.
            let ids = items.map(\.id)
            guard ids != context.coordinator.menuIDs else { return }
            context.coordinator.menuIDs = ids
            button.menu = UIMenu(children: items.map { item in
                UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in
                    item.action()
                }
            })
        }

        final class Coordinator {
            var menuIDs: [String] = []
        }
    }

    /// UIKit hangs a button's menu down and to the left of the button's
    /// top-trailing corner, with a small gap. Sizing the menu the way UIKit
    /// does lets the anchor be offset by half of it, which lands the menu
    /// itself dead centre on whatever it is attached to.
    private enum MenuMetrics {
        static let rowHeight: CGFloat = 42
        /// Icon column plus the leading/trailing margins around a row's title.
        static let rowChrome: CGFloat = 128
        static let gap: CGFloat = 10

        static func size(of items: [GoToItem]) -> CGSize {
            let font = UIFont.preferredFont(forTextStyle: .body)
            let titleWidth = items
                .map { ($0.title as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            return CGSize(
                width: titleWidth + rowChrome,
                height: CGFloat(items.count) * rowHeight
            )
        }
    }

    extension View {
        /// Makes the whole of this view open `items` as a system menu, centred
        /// on the view.
        ///
        /// Opening the menu programmatically needs iOS 17.4; below that it
        /// falls back to a plain Menu and UIKit's own placement.
        @ViewBuilder
        func goToMenu(_ controller: GoToMenuController, items: [GoToItem]) -> some View {
            let menu = MenuMetrics.size(of: items)
            if #available(iOS 17.4, *) {
                overlay(alignment: .center) {
                    GoToMenuAnchor(controller: controller, items: items)
                        .frame(width: menu.width, height: menu.height)
                }
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { controller.open() }
                }
            } else {
                overlay {
                    Menu {
                        ForEach(items, id: \.id) { item in
                            Button(item.title, systemImage: item.systemImage, action: item.action)
                        }
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                }
            }
        }
    }
#endif

struct ArtworkView: View {
    let image: Image?
    let size: CGFloat
    let cornerRadius: CGFloat

    init(image: Image?, size: CGFloat, cornerRadius: CGFloat) {
        self.image = image
        self.size = size
        self.cornerRadius = cornerRadius
    }

    /// Full-resolution path, for artwork already decoded by the caller.
    init(data: Data?, size: CGFloat, cornerRadius: CGFloat) {
        self.init(image: artworkImage(from: data), size: size, cornerRadius: cornerRadius)
    }

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle()
                        .fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
