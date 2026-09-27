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
