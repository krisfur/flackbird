import AVFAudio
@testable import SwiftFlac
import Testing

@MainActor
struct RendererTransportTests {
    private func transport() -> (AudioRendererTransport, () -> [PlaybackEvent]) {
        let transport = AudioRendererTransport()
        transport.outputVolume = 0
        var events: [PlaybackEvent] = []
        transport.onEvent = { events.append($0) }
        return (transport, { events })
    }

    @Test func loadsExactDurationAndSeeksWhilePaused() async throws {
        let (transport, events) = transport()
        try transport.load(fixture("sample.flac"), at: 1)
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
        // The visualiser gets audio as it's fed in, read back at the playback time.
        let spectrum = SpectrumBuffer()
        transport.spectrum = spectrum
        try transport.load(fixture("tagged.flac"), at: 0)
        try await eventually { events().count == 1 }
        transport.seek(to: 1.5)
        transport.play()
        try await eventually { transport.currentTime > 1.6 }
        try await eventually { spectrum.window(64, endingAt: transport.currentTime) != nil }
        try await eventually { events().last == .finished }
        #expect(transport.currentTime == 2)
        transport.pause()
        #expect(events().count == 2)
    }

    @Test(arguments: ["tagged.mp3", "lossless.m4a"])
    func otherFormatsPlayToTheEnd(name: String) async throws {
        let (transport, events) = transport()
        try transport.load(fixture(name), at: 1.5)
        try await eventually { events().count == 1 }
        transport.play()
        try await eventually { events().last == .finished }
    }

    @Test func unreadableFilesFail() async throws {
        let (transport, events) = transport()
        let store = try TestStore()
        try transport.load(store.file("bad.flac", data: Data("not audio".utf8)), at: 0)
        try await eventually { events() == [.failed] }
    }
}
