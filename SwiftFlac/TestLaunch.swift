#if DEBUG
    import Foundation

    @MainActor
    struct TestLaunch {
        let library: MusicLibrary
        let player: PlayerController

        static func make() -> TestLaunch? {
            let environment = ProcessInfo.processInfo.environment
            guard environment["SWIFTFLAC_TEST_MODE"] == "unit" || environment["XCTestConfigurationFilePath"] != nil else { return nil }
            // Fixed names, wiped per launch, so test runs don't accumulate preference files.
            let suite = "SwiftFlacTests.host"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try? FileManager.default.removeItem(at: base)
            return TestLaunch(
                library: MusicLibrary(defaults: defaults, cacheURL: base.appendingPathComponent("cache.json"), startsAutomatically: false),
                player: PlayerController(defaults: defaults, systemIntegration: false)
            )
        }
    }
#endif

#if DEBUG
    import Foundation
    #if os(iOS)
        import UIKit
    #endif

    /// Launch-time scene setup for automated screenshots (see take_screenshots.sh), driven by
    /// SWIFTFLAC_SCREEN, SWIFTFLAC_APPEARANCE, SWIFTFLAC_LANDSCAPE, and SWIFTFLAC_LIBRARY.
    /// Uses its own wiped preferences and cache, so it never touches the real library or session.
    struct ScreenshotMode {
        enum Screen: String {
            case library, albums, folder, nowPlaying = "nowplaying", search
        }

        static let album = "Blue Hour"
        static let folder = "Evening"
        static let searchQuery = "mira"
        static let startTime: TimeInterval = 84

        let screen: Screen
        let landscape: Bool

        static let current: ScreenshotMode? = {
            let environment = ProcessInfo.processInfo.environment
            guard let screen = environment["SWIFTFLAC_SCREEN"].flatMap(Screen.init(rawValue:)) else { return nil }
            return ScreenshotMode(screen: screen, landscape: environment["SWIFTFLAC_LANDSCAPE"] == "1")
        }()

        @MainActor
        static func makeLaunch() -> TestLaunch? {
            guard current != nil else { return nil }
            let environment = ProcessInfo.processInfo.environment
            let suite = "SwiftFlacScreenshots"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(environment["SWIFTFLAC_APPEARANCE"] ?? "light", forKey: "appearance")
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
            try? FileManager.default.removeItem(at: cache)
            let root = environment["SWIFTFLAC_LIBRARY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            return TestLaunch(
                library: MusicLibrary(defaults: defaults, cacheURL: cache, rootURL: root),
                player: PlayerController(defaults: defaults)
            )
        }

        #if os(iOS)
            @MainActor
            func rotateIfNeeded() {
                guard landscape, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
        #endif
    }
#endif
