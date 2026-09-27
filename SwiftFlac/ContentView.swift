import SwiftUI

enum BrowseMode: String, CaseIterable, Identifiable {
    case albums, artists, folders, allTracks

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .albums: "Albums"
        case .artists: "Artists"
        case .folders: "Folders"
        case .allTracks: "All Tracks"
        }
    }

    var icon: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .folders: "folder"
        case .allTracks: "music.note.list"
        }
    }
}

enum LibraryDestination: Hashable {
    case playlist(Playlist)
    case album(Album)
    case artist(Artist)
    case nowPlaying
}

/// Lets deeply nested views (e.g. the now-playing screen) push a library
/// destination onto the detail stack. Pushing is a main-actor action, and the
/// environment carries the closure across isolation boundaries, so it is
/// declared with both.
typealias LibraryNavigate = @MainActor @Sendable (LibraryDestination) -> Void

/// Always equal, like SwiftUI's own actions: the closure only writes ContentView's
/// @State, so a fresh copy per update must not invalidate every reader.
struct LibraryNavigateAction: Equatable, Sendable {
    let navigate: LibraryNavigate

    @MainActor func callAsFunction(_ destination: LibraryDestination) {
        navigate(destination)
    }

    static func == (_: Self, _: Self) -> Bool {
        true
    }
}

extension EnvironmentValues {
    @Entry var libraryNavigate = LibraryNavigateAction { _ in }
}

#if os(iOS)
    /// Hosting view that reports when it lands in a window, so the installer
    /// below can attach its window-level gesture recognizers.
    private final class WindowHookView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }

    /// Installs the app's window-level gesture recognizers.
    private struct WindowGestureInstaller: UIViewRepresentable {
        let isEnabled: () -> Bool
        /// Window-space region, such as the mini player's scrubber, that keeps its own drags.
        let excludedRect: () -> CGRect
        let onForward: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> WindowHookView {
            let view = WindowHookView()
            view.isUserInteractionEnabled = false
            let coordinator = context.coordinator
            view.onWindow = { window in
                guard coordinator.recognizers.isEmpty else { return }
                let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
                pan.delegate = coordinator
                pan.maximumNumberOfTouches = 1
                let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap))
                tap.cancelsTouchesInView = false
                tap.delegate = coordinator
                coordinator.recognizers = [pan, tap]
                coordinator.recognizers.forEach(window.addGestureRecognizer)
            }
            return view
        }

        func updateUIView(_: WindowHookView, context: Context) {
            context.coordinator.isEnabled = isEnabled
            context.coordinator.excludedRect = excludedRect
            context.coordinator.onForward = onForward
        }

        static func dismantleUIView(_: WindowHookView, coordinator: Coordinator) {
            for recognizer in coordinator.recognizers {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var isEnabled: () -> Bool = { false }
            var excludedRect: () -> CGRect = { .null }
            var onForward: () -> Void = {}
            var recognizers: [UIGestureRecognizer] = []

            @objc func handlePan(_ pan: UIPanGestureRecognizer) {
                guard pan.state == .ended, let view = pan.view else { return }
                let translation = pan.translation(in: view)
                if translation.x < -60, abs(translation.y) < 80 {
                    onForward()
                }
            }

            @objc func handleTap() {
                hideKeyboard()
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                      let view = pan.view else { return true }
                guard isEnabled() else { return false }
                let velocity = pan.velocity(in: view)
                return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.5
            }

            /// Taps inside a text field keep their caret placement instead of
            /// bouncing the keyboard down and back up.
            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
                // A leftward scrub must not also navigate forward.
                if gestureRecognizer is UIPanGestureRecognizer {
                    return !excludedRect().contains(touch.location(in: nil))
                }
                guard gestureRecognizer is UITapGestureRecognizer else { return true }
                var view = touch.view
                while let current = view {
                    if current is UITextField || current is UITextView {
                        return false
                    }
                    view = current.superview
                }
                return true
            }

            func gestureRecognizer(
                _: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
            ) -> Bool {
                true
            }
        }
    }
#endif

struct ContentView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerController.self) private var player
    // iPhone starts on the Library list itself; macOS needs a selection
    // because its detail pane is always visible.
    #if os(macOS)
        @State private var mode: BrowseMode? = .folders
    #else
        @State private var mode: BrowseMode?
    #endif
    @State private var path: [LibraryDestination] = []
    @State private var savedPaths: [BrowseMode: [LibraryDestination]] = [:]
    @State private var forwardStack: [LibraryDestination] = []
    @State private var isRestoringPath = false
    @State private var lastForwardPush = Date.distantPast
    // Set by the navigation gestures so their mode changes keep the forward
    // history; picking a category by hand clears it.
    @State private var preserveForwardStack = false
    @State private var hasRestoredNavigation = false

    private static let navModeKey = "navMode"
    private static let navPathKey = "navPath"
    private static let navForwardKey = "navForward"
    private static let navOriginModeKey = "navOriginMode"
    private static let navOriginPathKey = "navOriginPath"
    @State private var showingFolderPicker = false
    @State private var showingNowPlaying = false
    @State private var miniScrubberFrame = CGRect.null
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @State private var forwardMode: BrowseMode?
        /// Where the current song was played from, so the now-playing screen
        /// can always swipe back to that list.
        @State private var playbackOrigin: (mode: BrowseMode?, path: [LibraryDestination])?
    #endif

    var body: some View {
        NavigationSplitView {
            List(BrowseMode.allCases, selection: $mode) { mode in
                Label(mode.title, systemImage: mode.icon)
                    .tag(mode)
            }
            .navigationTitle("Library")
            #if os(iOS)
                .scrollContentBackground(.hidden)
                .background(AppBackground())
                // Swipe left on the Library list to return to the category
                // you swiped back out of.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 25)
                        .onEnded { value in
                            if value.translation.width < -70, abs(value.translation.height) < 50,
                               let forwardMode
                            {
                                preserveForwardStack = true
                                mode = forwardMode
                            }
                        }
                )
            #endif
                .miniBarClearance()
                .optionsToolbar()
        } detail: {
            NavigationStack(path: $path) {
                detailRoot
                    .navigationDestination(for: LibraryDestination.self) { destination in
                        switch destination {
                        case let .playlist(playlist):
                            TrackListView(title: playlist.name, tracks: playlist.tracks, onPlay: playFromList)
                        case let .album(album):
                            TrackListView(title: album.name, tracks: album.tracks, onPlay: playFromList)
                        case let .artist(artist):
                            TrackListView(title: artist.name, tracks: artist.tracks, showsArtist: false, onPlay: playFromList)
                        case .nowPlaying:
                            NowPlayingView()
                        }
                    }
            }
            #if os(iOS)
            // Swipe right at a category root to go all the way back to the
            // Library list; leftward (forward) swipes are handled by the
            // window-level recognizer, which sees every screen.
            .simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .onEnded { value in
                        guard abs(value.translation.height) < 50 else { return }
                        if value.translation.width > 70, path.isEmpty,
                           horizontalSizeClass == .compact
                        {
                            // onChange(of: mode) records the forward history.
                            mode = nil
                        }
                    }
            )
            #endif
        }
        #if os(iOS)
        .background(
            WindowGestureInstaller(
                // mode == nil means the Library list is showing, where its
                // own gesture handles the forward swipe.
                isEnabled: { mode != nil && !forwardStack.isEmpty && path.last != .nowPlaying },
                excludedRect: { miniScrubberFrame },
                onForward: goForward
            )
        )
        #endif
        .onChange(of: mode) { oldMode, newMode in
            #if os(iOS)
                if newMode == nil {
                    // Landing back on the Library list keeps the forward history
                    // so a left swipe can retrace it.
                    forwardMode = oldMode
                    preserveForwardStack = true
                } else {
                    forwardMode = nil
                }
            #endif
            if let oldMode {
                savedPaths[oldMode] = path
            }
            let restored = newMode.flatMap { savedPaths[$0] } ?? []
            if preserveForwardStack {
                preserveForwardStack = false
            } else {
                forwardStack = []
            }
            if restored != path {
                isRestoringPath = true
                path = restored
            }
            saveNavigation()
        }
        .onChange(of: path) { oldPath, newPath in
            if isRestoringPath {
                isRestoringPath = false
                return
            }
            if newPath.count < oldPath.count {
                forwardStack.append(contentsOf: oldPath[newPath.count...].reversed())
            } else if newPath.count > oldPath.count {
                forwardStack = []
            }
            saveNavigation()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentTrack != nil, path.last != .nowPlaying {
                nowPlayingBar
            }
        }
        #if os(macOS)
        // The sidebar toolbar is too narrow and pushes items into the »
        // overflow menu, so the settings button lives in the window toolbar.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsButton()
            }
        }
        // Swallow the popover-dismissing click so it can't hit a track
        // row or a transport button underneath.
        .overlay {
            if showingNowPlaying {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showingNowPlaying = false }
            }
        }
        #endif
        .environment(\.libraryNavigate, LibraryNavigateAction { destination in
            #if os(macOS)
                showingNowPlaying = false
            #endif
            path.append(destination)
        })
        // Pick up where the last session left off, paused, as soon as any
        // content is available - the launch-time cache makes this nearly
        // instant; a fresh scan (first launch) arrives seconds later.
        .onChange(of: library.contentVersion) {
            attemptRestore()
        }
        .onAppear {
            attemptRestore()
        }
        .preferredColorScheme(Appearance(rawValue: appearanceRaw)?.colorScheme)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                library.setRootFolder(url)
            }
        }
    }

    /// Paths persist relative to the library root: the app's container
    /// path (and any absolute path in it) changes across app updates.
    private func persistenceToken(for destination: LibraryDestination) -> String {
        NavigationPersistence.token(for: destination, root: library.rootURL)
    }

    private func saveNavigation() {
        let defaults = library.defaults
        defaults.set(mode?.rawValue, forKey: Self.navModeKey)
        defaults.set(path.map(persistenceToken(for:)), forKey: Self.navPathKey)
        defaults.set(forwardStack.map(persistenceToken(for:)), forKey: Self.navForwardKey)
        #if os(iOS)
            if let playbackOrigin {
                defaults.set(playbackOrigin.mode?.rawValue, forKey: Self.navOriginModeKey)
                defaults.set(playbackOrigin.path.map(persistenceToken(for:)), forKey: Self.navOriginPathKey)
            } else {
                defaults.removeObject(forKey: Self.navOriginModeKey)
                defaults.removeObject(forKey: Self.navOriginPathKey)
            }
        #endif
    }

    private func resolveDestination(_ token: String) -> LibraryDestination? {
        NavigationPersistence.resolve(token, content: library.content, root: library.rootURL)
    }

    private func attemptRestore() {
        guard !library.playlists.isEmpty else { return }
        player.restoreSession(from: library.playlists.flatMap(\.tracks))
        restoreNavigationIfNeeded()
    }

    /// Rebuilds the last visited screen from persisted tokens, truncating
    /// at the first one the rescanned library can no longer resolve.
    private func restoreNavigationIfNeeded() {
        #if os(iOS)
            guard !hasRestoredNavigation else { return }
            hasRestoredNavigation = true
            let defaults = library.defaults
            guard let modeRaw = defaults.string(forKey: Self.navModeKey),
                  let savedMode = BrowseMode(rawValue: modeRaw) else { return }

            var restoredPath = NavigationPersistence.restoredPath(
                defaults.stringArray(forKey: Self.navPathKey) ?? [], resolve: resolveDestination
            )
            var restoredForward = (defaults.stringArray(forKey: Self.navForwardKey) ?? [])
                .compactMap(resolveDestination)
            // Launch-time pushes of the now-playing screen are unreliable on
            // device, so it is never auto-pushed: it moves to the top of the
            // forward stack instead, one bar tap or forward swipe away.
            NavigationPersistence.deferNowPlaying(
                path: &restoredPath, forward: &restoredForward, hasTrack: player.currentTrack != nil
            )
            if player.currentTrack != nil,
               let originModeRaw = defaults.string(forKey: Self.navOriginModeKey)
            {
                let originPath = NavigationPersistence.restoredPath(
                    defaults.stringArray(forKey: Self.navOriginPathKey) ?? [], resolve: resolveDestination
                )
                playbackOrigin = (BrowseMode(rawValue: originModeRaw), originPath)
            }

            savedPaths[savedMode] = []
            mode = savedMode
            guard !restoredPath.isEmpty || !restoredForward.isEmpty else { return }
            // The whole path lands in a single animation-free assignment.
            Task { @MainActor in
                // Path writes made before the app is active are discarded outright, so
                // wait for activity first, then retry the atomic assignment
                // until the stack stops writing truncations back.
                for _ in 0 ..< 50 where UIApplication.shared.applicationState != .active {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                for attempt in 0 ..< 2 {
                    try? await Task.sleep(for: .milliseconds(attempt == 0 ? 150 : 600))
                    guard mode == savedMode,
                          path == Array(restoredPath.prefix(path.count))
                    else {
                        return
                    }
                    guard path.count < restoredPath.count else { break }
                    isRestoringPath = true
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        path = restoredPath
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard mode == savedMode else { return }
                var forward = restoredForward
                if path.count < restoredPath.count {
                    forward.append(contentsOf: restoredPath[path.count...].reversed())
                }
                if !forward.isEmpty {
                    forwardStack = forward
                    saveNavigation()
                }
            }
        #endif
    }

    private func goForward() {
        // NavigationStack silently drops path changes made while a push or
        // pop transition is still running; space consecutive pushes out.
        guard Date().timeIntervalSince(lastForwardPush) > 0.6 else { return }
        guard let next = forwardStack.last else { return }
        lastForwardPush = Date()
        forwardStack.removeLast()
        isRestoringPath = true
        path.append(next)
    }

    /// Called when a track is picked from a list: remembers that list as
    /// the playback origin, then shows the now-playing screen.
    private func playFromList() {
        #if os(iOS)
            playbackOrigin = (mode, path)
            saveNavigation()
        #endif
        openNowPlaying()
    }

    /// On iOS this navigates to the dedicated now-playing screen, restoring
    /// the list the song was played from underneath it so a back swipe
    /// returns there; macOS keeps its popover instead.
    private func openNowPlaying() {
        #if os(iOS)
            guard path.last != .nowPlaying else { return }
            let origin = playbackOrigin ?? (mode ?? .allTracks, [])
            if mode != origin.mode {
                mode = origin.mode
            }
            // Defer the push one cycle so a mode change's path restoration
            // (onChange) cannot overwrite it.
            Task { @MainActor in
                guard path.last != .nowPlaying else { return }
                isRestoringPath = true
                path = origin.path + [.nowPlaying]
            }
        #endif
    }

    @ViewBuilder
    private var detailRoot: some View {
        if library.allTracks.isEmpty {
            if library.isScanning {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Music", systemImage: "music.note.list")
                } description: {
                    #if os(iOS)
                        // The Files route comes first: it needs no picker, and
                        // it is how music usually gets onto the device.
                        Text("Copy music into the SwiftFlac folder in the Files app, or choose a folder below. Each subfolder becomes a playlist.")
                    #else
                        Text("Choose a folder with music in it. Each subfolder becomes a playlist.")
                    #endif
                } actions: {
                    Button("Choose Folder") { showingFolderPicker = true }
                }
            }
        } else {
            switch mode {
            case .albums:
                AlbumsView()
            case .artists:
                ArtistsView()
            case .folders:
                FoldersView()
            case .allTracks:
                TrackListView(title: "All Tracks", tracks: library.allTracks, onPlay: playFromList)
            case nil:
                ContentUnavailableView("Select a Category", systemImage: "music.note")
            }
        }
    }

    /// On macOS a popover dismisses when clicking anywhere else,
    /// iOS keeps the swipeable sheet.
    @ViewBuilder
    private var nowPlayingBar: some View {
        #if os(macOS)
            NowPlayingBar { showingNowPlaying = true }
                .popover(isPresented: $showingNowPlaying, arrowEdge: .bottom) {
                    NowPlayingView()
                }
        #else
            NowPlayingBar(onScrubberFrame: { miniScrubberFrame = $0 }) { openNowPlaying() }
        #endif
    }
}

#if os(iOS)
    /// Every screen carries its own settings button so it stays reachable
    /// anywhere in the navigation stack.
    private struct OptionsToolbarModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .toolbar {
                    ToolbarItem {
                        SettingsButton()
                    }
                }
        }
    }
#endif

#if os(iOS)
    /// The mini bar overlays the window bottom without insetting scroll views
    /// inside the split view's columns, so lists reserve its height themselves.
    private struct MiniBarClearanceModifier: ViewModifier {
        @Environment(PlayerController.self) private var player

        func body(content: Content) -> some View {
            content.contentMargins(.bottom, player.currentTrack != nil ? 62 : 0, for: .scrollContent)
        }
    }
#endif

extension View {
    @ViewBuilder
    func optionsToolbar() -> some View {
        #if os(iOS)
            modifier(OptionsToolbarModifier())
        #else
            self
        #endif
    }

    @ViewBuilder
    func miniBarClearance() -> some View {
        #if os(iOS)
            modifier(MiniBarClearanceModifier())
        #else
            self
        #endif
    }
}

struct TrackListView: View {
    @Environment(PlayerController.self) private var player
    let title: String
    let tracks: [Track]
    var showsArtist = true
    var onPlay: () -> Void = {}
    @State private var searchText = ""

    private var filteredTracks: [Track] {
        LibrarySearch.filter(tracks, query: searchText, name: \.displayTitle, artist: \.artist)
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $searchText, prompt: "Title or Artist")
            List(filteredTracks) { track in
                // A tap gesture (not a Button): buttons fire on release even
                // after a long horizontal swipe across the row, which turned
                // the forward-swipe into an accidental track change.
                TrackRow(track: track, isPlaying: player.currentTrack == track, showsArtist: showsArtist)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Queue the whole list, not just the search matches,
                        // so playback continues past the filtered subset.
                        player.play(track, in: tracks)
                        onPlay()
                    }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if filteredTracks.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .dismissesSearchKeyboard()
            .miniBarClearance()
        }
        .background(AppBackground())
        .navigationTitle(title)
        .optionsToolbar()
    }
}

struct TrackRow: View {
    let track: Track
    let isPlaying: Bool
    let showsArtist: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var artwork: Image?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: artwork, size: 40, cornerRadius: 6)
                .overlay {
                    if isPlaying {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.black.opacity(0.45))
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                }
                .accessibilityHidden(!isPlaying)
                .accessibilityLabel("Now Playing")
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                if showsArtist, let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .task(id: track.url) {
            let loaded = await ArtworkStore.shared.thumbnail(for: track, maxPixelSize: Int(40 * displayScale))
            guard !Task.isCancelled else { return }
            artwork = loaded
        }
    }
}
