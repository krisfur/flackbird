import SwiftUI

@main
struct SwiftFlacApp: App {
    @State private var library: MusicLibrary
    @State private var player: PlayerController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
            if let launch = TestLaunch.make() {
                _library = State(initialValue: launch.library)
                _player = State(initialValue: launch.player)
                return
            }
        #endif
        _library = State(initialValue: MusicLibrary())
        _player = State(initialValue: PlayerController())
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
