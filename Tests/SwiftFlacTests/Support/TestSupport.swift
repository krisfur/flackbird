import AVFoundation
import Foundation
@testable import SwiftFlac
import Testing

final class TestStore: @unchecked Sendable {
    let root: URL
    /// An absolute suite path keeps the plist inside `root`, so cleanup removes it.
    let suite: String
    var defaults: UserDefaults {
        UserDefaults(suiteName: suite)!
    }

    var cache: URL {
        root.appendingPathComponent("cache.json")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = root.appendingPathComponent("defaults").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ name: String, data: Data = Data()) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}

private final class FixtureBundle {}
func fixture(_ name: String) throws -> URL {
    try #require(Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

@MainActor
func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        await Task.yield()
    }
    try #require(condition(), sourceLocation: sourceLocation)
}

actor AsyncGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var entered: [CheckedContinuation<Void, Never>] = []

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.forEach { $0.resume() }
            entered.removeAll()
        }
    }

    func waitUntilEntered() async {
        if continuation != nil {
            return
        }
        await withCheckedContinuation { entered.append($0) }
    }

    func finish(_ value: Value) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

@MainActor
final class FakeTransport: PlaybackTransport {
    var currentItem: AVPlayerItem?
    var avPlayer: AVPlayer? {
        nil
    }

    var time: Double = 0
    var plays = 0
    var pauses = 0
    var seeks: [(Double, @Sendable (Bool) -> Void)] = []
    func currentTime() -> CMTime {
        CMTime(seconds: time, preferredTimescale: 600)
    }

    func replaceCurrentItem(with item: AVPlayerItem?) {
        currentItem = item; time = 0
    }

    func play() {
        plays += 1
    }

    func pause() {
        pauses += 1
    }

    func seek(to time: CMTime, toleranceBefore _: CMTime, toleranceAfter _: CMTime,
              completionHandler: @escaping @Sendable (Bool) -> Void)
    {
        seeks.append((time.seconds, completionHandler))
    }

    func completeSeek(at index: Int = 0) {
        let seek = seeks.remove(at: index)
        time = seek.0
        seek.1(true)
    }
}

@MainActor
func testPlayer(_ store: TestStore, transport: FakeTransport = FakeTransport(),
                activate: @escaping @Sendable () async throws -> Void = {}) -> PlayerController
{
    PlayerController(transport: transport, defaults: store.defaults, systemIntegration: false,
                     activate: activate, metadataLoader: { TrackMetadata(title: $0.title, artist: $0.artist, album: $0.album) },
                     durationLoader: { _ in 120 })
}

func testTracks(root: URL, count: Int = 3) -> [Track] {
    (1 ... count).map { Track(url: root.appendingPathComponent("\($0).flac"), title: "Song \($0)", artist: "Artist", album: "Album", trackNumber: $0) }
}
