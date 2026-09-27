import AVFoundation
import MediaPlayer
@testable import SwiftFlac
import Testing

@MainActor
struct PlaybackTests {
    @Test func queueBoundariesAndPreviousRestart() async throws {
        let store = try TestStore()
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport)
        let tracks = testTracks(root: store.root)
        player.play(tracks[1], in: tracks)
        try await eventually { player.duration == 120 && transport.plays == 1 }
        #expect(player.queue == tracks)
        player.updatePlaybackTime(4)
        player.previous()
        #expect(player.currentTrack == tracks[1])
        #expect(transport.seeks.last?.0 == 0)
        transport.completeSeek()
        try await eventually { player.currentTime == 0 }
        player.previous()
        #expect(player.currentTrack == tracks[0])
        player.previous()
        #expect(!player.isPlaying && player.currentTrack == tracks[0])
        player.play(tracks[2], in: tracks)
        player.trackFinished()
        #expect(!player.isPlaying && player.currentTrack == tracks[2])
        player.play(Track(url: store.root.appendingPathComponent("absent.flac")), in: tracks)
        #expect(player.currentTrack == tracks[2])
    }

    @Test func repeatAndShufflePreserveTheSelectedTrack() throws {
        let store = try TestStore()
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport)
        let tracks = testTracks(root: store.root)
        player.play(tracks[2], in: tracks)
        player.cycleRepeatMode()
        player.next()
        #expect(player.currentTrack == tracks[0])
        player.previous()
        #expect(player.currentTrack == tracks[2])
        player.cycleRepeatMode()
        player.trackFinished()
        #expect(player.currentTrack == tracks[2] && player.isPlaying)
        #expect(transport.seeks.last?.0 == 0)
        transport.completeSeek()
        player.toggleShuffle()
        #expect(player.currentTrack == tracks[2])
        #expect(Set(player.queue) == Set(tracks))
        #expect(player.queue.count == tracks.count)
        player.toggleShuffle()
        #expect(player.queue == tracks && player.currentTrack == tracks[2])
        player.cycleRepeatMode()
        #expect(player.repeatMode == .off)
    }

    @Test func seekClampsAndIgnoresObsoleteCompletions() async throws {
        let store = try TestStore()
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport)
        let tracks = testTracks(root: store.root)
        player.play(tracks[0], in: tracks)
        try await eventually { player.duration == 120 }
        player.seek(to: -.infinity)
        #expect(transport.seeks.isEmpty)
        player.seek(to: -5)
        #expect(transport.seeks.last?.0 == 0)
        player.seek(to: 40)
        transport.completeSeek(at: 1)
        try await eventually { player.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 40 }
        transport.completeSeek()
        player.next()
        try await eventually { player.duration == 120 }
        player.updatePlaybackTime(12)
        #expect(player.currentTime == 12)
        player.seek(to: 119)
        #expect(player.currentTrack == tracks[2])
        player.seek(to: 20)
        player.play(tracks[0], in: tracks)
        transport.completeSeek()
        try await eventually { player.displayTitle == "Song 1" }
        #expect(player.currentTime == 0)
    }

    @Test func scrubToEndOfLastTrackKeepsTimeUpdating() async throws {
        let store = try TestStore()
        let transport = FakeTransport()
        let player = testPlayer(store, transport: transport)
        let tracks = testTracks(root: store.root)
        player.play(tracks[2], in: tracks)
        try await eventually { player.duration == 120 }
        player.seek(to: 50)
        player.seek(to: 119.5)
        transport.completeSeek()
        #expect(!player.isPlaying && player.currentTrack == tracks[2])
        player.updatePlaybackTime(30)
        #expect(player.currentTime == 30)
    }

    @Test(arguments: [false, true]) func failedQueueTerminatesEvenWithRepeat(repeatOne: Bool) throws {
        let store = try TestStore()
        let player = testPlayer(store)
        let tracks = testTracks(root: store.root)
        player.cycleRepeatMode()
        if repeatOne {
            player.cycleRepeatMode()
        }
        player.play(tracks[0], in: tracks)
        player.currentTrackFailed()
        #expect(player.currentTrack == tracks[1])
        player.currentTrackFailed()
        #expect(player.currentTrack == tracks[2])
        player.currentTrackFailed()
        #expect(!player.isPlaying)
        player.play(tracks[0], in: tracks)
        #expect(player.isPlaying)
    }

    @Test func interruptionsRespectResumePermissionAndPriorState() throws {
        let store = try TestStore()
        let player = testPlayer(store)
        let tracks = testTracks(root: store.root)
        player.play(tracks[0], in: tracks)
        player.handleInterruption(began: true, shouldResume: false)
        #expect(!player.isPlaying)
        player.handleInterruption(began: false, shouldResume: false)
        #expect(!player.isPlaying)
        player.handleInterruption(began: true, shouldResume: false)
        player.handleInterruption(began: false, shouldResume: true)
        #expect(!player.isPlaying)
        player.togglePlayPause()
        player.handleInterruption(began: true, shouldResume: false)
        player.handleInterruption(began: false, shouldResume: true)
        #expect(player.isPlaying)
    }

    @Test func metadataFromPreviousItemCannotReplaceCurrentPayload() async throws {
        let store = try TestStore()
        let gate = AsyncGate<TrackMetadata>()
        let tracks = testTracks(root: store.root)
        let player = PlayerController(transport: FakeTransport(), defaults: store.defaults, systemIntegration: false,
                                      activate: {}, metadataLoader: { track in
                                          if track == tracks[0] {
                                              return await gate.wait()
                                          }
                                          return TrackMetadata(title: "Current", artist: "Artist", album: "Album")
                                      }, durationLoader: { _ in 120 })
        player.play(tracks[0], in: tracks)
        await gate.waitUntilEntered()
        let oldMetadata = player.metadataTask
        player.next()
        try await eventually { player.nowPlaying.title == "Current" }
        await gate.finish(TrackMetadata(title: "Obsolete"))
        await oldMetadata?.value
        player.togglePlayPause()
        #expect(player.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Current")
        #expect(player.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        let metadata = player.externalMetadata(for: tracks[1])
        #expect(try await metadata.first { $0.identifier == .commonIdentifierTitle }?.load(.stringValue) == "Current")
        #expect(try await metadata.first { $0.identifier == .commonIdentifierAlbumName }?.load(.stringValue) == "Album")
    }
}
