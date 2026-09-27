import AppIntents
import SwiftUI

@main
struct SwiftFlacApp: App {
    @State private var library: MusicLibrary
    @State private var player: PlayerController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        var library: MusicLibrary?
        var player: PlayerController?
        #if DEBUG
            if let launch = TestLaunch.make() {
                library = launch.library
                player = launch.player
            }
        #endif
        let resolvedPlayer = player ?? PlayerController()
        // Runs for cache and scan content alike, including background launches with no window.
        let resolvedLibrary = library ?? MusicLibrary(onContentChange: { library in
            resolvedPlayer.libraryRoot = library.rootURL
            SwiftFlacShortcuts.updateAppShortcutParameters()
        })
        _library = State(initialValue: resolvedLibrary)
        _player = State(initialValue: resolvedPlayer)
        // Siri and Shortcuts intents can launch the app in the background, before any view exists.
        AppDependencyManager.shared.add(dependency: resolvedLibrary)
        AppDependencyManager.shared.add(dependency: resolvedPlayer)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .defaultAppStorage(library.defaults)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshIfNeeded()
            }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.currentTrack == nil)
                Button("Next Track") {
                    player.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player.currentTrack == nil)
                Button("Previous Track") {
                    player.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player.currentTrack == nil)
            }
        }
        #endif
    }
}
