import AVFAudio
@testable import SwiftFlac
import Testing

@MainActor
struct EngineTransportTests {
    private func transport() -> (AudioEngineTransport, () -> [PlaybackEvent]) {
        let transport = AudioEngineTransport()
        transport.outputVolume = 0
        var events: [PlaybackEvent] = []
        transport.onEvent = { events.append($0) }
        return (transport, { events })
    }

    @Test func loadsExactDurationAndSeeksWhilePaused() async throws {
        let (transport, events) = transport()
        transport.load(try fixture("sample.flac"), at: 1)
        try await eventually { !events().isEmpty }
        // 238140 frames at 44.1 kHz, from STREAMINFO.
        #expect(events() == [.loaded(duration: 238_140.0 / 44100)])
        #expect(transport.currentTime == 1)
        transport.seek(to: 2.5)
        #expect(transport.currentTime == 2.5)
        transport.seek(to: 99)
        #expect(transport.currentTime == 238_140.0 / 44100)
    }

    @Test func playsToTheEndFromASeek() async throws {
        let (transport, events) = transport()
        // The visualiser's tap runs on the engine's thread while playing.
        let spectrum = SpectrumBuffer()
        transport.spectrum = spectrum
        transport.load(try fixture("tagged.flac"), at: 0)
        try await eventually { events().count == 1 }
        transport.seek(to: 1.5)
        transport.play()
        try await eventually { transport.currentTime > 1.6 }
        try await eventually { spectrum.latest(64) != nil }
        try await eventually { events().last == .finished }
        #expect(transport.currentTime == 2)
        transport.pause()
        #expect(events().count == 2)
    }

    @Test func unreadableFilesFail() async throws {
        let (transport, events) = transport()
        let store = try TestStore()
        transport.load(try store.file("bad.flac", data: Data("not audio".utf8)), at: 0)
        try await eventually { events() == [.failed] }
    }
}
