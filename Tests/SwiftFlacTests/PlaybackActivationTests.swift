import Foundation
@testable import SwiftFlac
import Testing

@MainActor
struct PlaybackActivationTests {
    @Test func pauseDuringActivationDoesNotStartAudio() async throws {
        let store = try TestStore()
        let gate = AsyncGate<Void>()
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport, activate: { await gate.wait() })
        let tracks = testTracks(root: store.root)
        player.play(tracks[0], in: tracks)
        await gate.waitUntilEntered()
        #expect(player.isPlaying && transport.plays == 0)
        player.togglePlayPause()
        await gate.finish(())
        // A following request waits for the canceled activation to finish.
        player.togglePlayPause()
        await gate.waitUntilEntered()
        #expect(transport.plays == 0)
        await gate.finish(())
        try await eventually { transport.plays == 1 }
    }

    @Test func replacingTrackSerializesActivationAndSuppressesOldSuccess() async throws {
        let store = try TestStore()
        let gate = AsyncGate<Void>()
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport, activate: { await gate.wait() })
        let tracks = testTracks(root: store.root)
        player.play(tracks[0], in: tracks)
        await gate.waitUntilEntered()
        player.next()
        #expect(transport.plays == 0)
        await gate.finish(())
        await gate.waitUntilEntered()
        #expect(transport.plays == 0 && player.currentTrack == tracks[1])
        await gate.finish(())
        try await eventually { transport.plays == 1 }
    }

    @Test func activationFailurePausesAndCanRetry() async throws {
        enum Failure: Error { case declined }
        let store = try TestStore()
        let gate = AsyncGate<Bool>()
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport, activate: {
            if await !gate.wait() {
                throw Failure.declined
            }
        })
        let tracks = testTracks(root: store.root)
        player.play(tracks[0], in: tracks)
        await gate.waitUntilEntered()
        await gate.finish(false)
        try await eventually { !player.isPlaying }
        #expect(transport.plays == 0)
        player.togglePlayPause()
        await gate.waitUntilEntered()
        await gate.finish(true)
        try await eventually { transport.plays == 1 }
        #expect(player.isPlaying)
    }
}
