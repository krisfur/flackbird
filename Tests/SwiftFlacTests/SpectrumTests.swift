import Foundation
@testable import SwiftFlac
import Testing

struct SpectrumTests {
    private func sine(_ frequency: Double, amplitude: Float, sampleRate: Double = 44100) -> [Float] {
        (0 ..< SpectrumAnalyzer.windowLength).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    @Test(arguments: [80.0, 100.0, 1000.0, 8000.0]) func toneLightsTheBandContainingIt(frequency: Double) throws {
        let analyzer = try #require(SpectrumAnalyzer())
        let levels = analyzer.levels(of: sine(frequency, amplitude: 0.5), sampleRate: 44100, bands: 32)
        let peak = try #require(levels.indices.max { levels[$0] < levels[$1] })
        let span = SpectrumAnalyzer.highestFrequency / SpectrumAnalyzer.lowestFrequency
        let expected = Int(32 * log(frequency / SpectrumAnalyzer.lowestFrequency) / log(span))
        #expect(abs(peak - expected) <= 1)
        #expect(levels[peak] > 0.8)
    }

    @Test func silenceAndBadInputStayFlat() throws {
        let analyzer = try #require(SpectrumAnalyzer())
        #expect(analyzer.levels(of: [Float](repeating: 0, count: SpectrumAnalyzer.windowLength), sampleRate: 44100, bands: 32).allSatisfy { $0 == 0 })
        #expect(analyzer.levels(of: [0, 1], sampleRate: 44100, bands: 8) == [Float](repeating: 0, count: 8))
        #expect(analyzer.levels(of: sine(1000, amplitude: 0.5), sampleRate: 0, bands: 4) == [0, 0, 0, 0])
    }

    @Test func quieterTonesReadLower() throws {
        let analyzer = try #require(SpectrumAnalyzer())
        let loud = analyzer.levels(of: sine(1000, amplitude: 0.5), sampleRate: 44100, bands: 32).max() ?? 0
        let quiet = analyzer.levels(of: sine(1000, amplitude: 0.005), sampleRate: 44100, bands: 32).max() ?? 0
        #expect(quiet < loud && quiet > 0)
    }

    @Test func bufferReturnsDelayedWindowsAndForgetsOnReset() throws {
        let buffer = SpectrumBuffer()
        #expect(buffer.latest(4) == nil)
        buffer.append((0 ..< 10).map(Float.init), sampleRate: 10)
        #expect(try #require(buffer.latest(4)).samples == [6, 7, 8, 9])
        // 0.3 s at 10 Hz is 3 samples back; a delay beyond the buffer clamps to the oldest window.
        #expect(try #require(buffer.latest(4, delay: 0.3)).samples == [3, 4, 5, 6])
        #expect(try #require(buffer.latest(4, delay: 5)).samples == [0, 1, 2, 3])
        let sequence = try #require(buffer.latest(4)).sequence
        buffer.reset()
        #expect(buffer.latest(4) == nil)
        buffer.append([1, 2, 3, 4], sampleRate: 10)
        #expect(try #require(buffer.latest(4)).sequence == sequence + 4)
        #expect(buffer.makeTap() != nil)
    }

    @Test @MainActor func monitorShowsFreshAudioDropsOnGapsAndHidesOnlyAfterLongSilence() {
        let monitor = SpectrumMonitor()
        var now = Date()
        func frame(_ seconds: TimeInterval = 1.0 / 60) -> [Float] {
            now += seconds
            return monitor.update(at: now)
        }
        #expect(frame().allSatisfy { $0 == 0 } && monitor.hasSignal)
        monitor.buffer.append(sine(1000, amplitude: 0.5), sampleRate: 44100)
        #expect((frame().max() ?? 0) > 0.8)
        // Two views on the same frame see the same levels without decaying twice.
        #expect(monitor.update(at: now) == monitor.update(at: now))
        // A short gap, like a track change: bars fall away but stay shown at their minimum.
        for _ in 0 ..< 20 {
            _ = frame()
        }
        #expect((frame().max() ?? 1) < 0.02 && monitor.hasSignal)
        // No audio for over 1.5 s while playing, as over AirPlay: hide.
        for _ in 0 ..< 90 {
            _ = frame()
        }
        #expect(!monitor.hasSignal)
        // After a pause, earlier silence no longer counts.
        _ = frame(2)
        #expect(monitor.hasSignal)
        monitor.reset()
        #expect(monitor.buffer.latest(SpectrumAnalyzer.windowLength) == nil)
    }

    @Test @MainActor func playerReadsTheVisualiserSetting() throws {
        let store = try TestStore()
        #expect(testPlayer(store).visualizerEnabled)
        store.defaults.set(false, forKey: PlayerController.visualizerKey)
        #expect(!testPlayer(store).visualizerEnabled)
    }
}
