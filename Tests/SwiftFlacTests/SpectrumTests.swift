import AVFAudio
import Foundation
@testable import SwiftFlac
import Testing

struct SpectrumTests {
    private func sine(_ frequency: Double, amplitude: Float, sampleRate: Double = 44100, count: Int = SpectrumAnalyzer.windowLength) -> [Float] {
        (0 ..< count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
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

    @Test func bufferReadsWindowsByPlaybackTimeAndForgetsOnReset() throws {
        let buffer = SpectrumBuffer()
        #expect(buffer.window(4, endingAt: 1) == nil)
        buffer.append((0 ..< 10).map(Float.init), sampleRate: 10)
        // At 10 Hz, 0.7 s ends after sample 6.
        #expect(try #require(buffer.window(4, endingAt: 0.7)).samples == [3, 4, 5, 6])
        #expect(try #require(buffer.window(4, endingAt: 1)).samples == [6, 7, 8, 9])
        // Not yet fed, or before the start: nothing to show.
        #expect(buffer.window(4, endingAt: 1.1) == nil)
        #expect(buffer.window(4, endingAt: 0.3) == nil)
        // Writes that continue where the last ended extend it; a jump starts over.
        buffer.append([10, 11], sampleRate: 10, at: 10)
        #expect(try #require(buffer.window(4, endingAt: 1.2)).samples == [8, 9, 10, 11])
        buffer.append([50, 51, 52, 53], sampleRate: 10, at: 50)
        #expect(buffer.window(4, endingAt: 1.2) == nil)
        #expect(try #require(buffer.window(4, endingAt: 5.4)).samples == [50, 51, 52, 53])
        buffer.reset()
        #expect(buffer.window(4, endingAt: 5.4) == nil)
    }

    @Test func bufferKeepsTheFirstChannelAndThinsHiRes() throws {
        let buffer = SpectrumBuffer()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 192_000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        pcm.frameLength = 16
        for index in 0 ..< 16 {
            pcm.floatChannelData?[0][index] = Float(index)
            pcm.floatChannelData?[1][index] = -1
        }
        // Starting at frame 2, every 4th frame from 4 is kept, at 48 kHz: stored as 1, 2, 3, 4.
        buffer.write(pcm, at: 2)
        let window = try #require(buffer.window(3, endingAt: 4.5 / 48000))
        #expect(window.samples == [2, 6, 10] && window.sampleRate == 48000)
    }

    @Test @MainActor func monitorFollowsThePositionAndHidesOnlyAfterLongSilence() {
        let monitor = SpectrumMonitor()
        var now = Date()
        var position: TimeInterval? = 0.5
        monitor.playbackPosition = { position }
        func frame(_ seconds: TimeInterval = 1.0 / 60, advance: Bool = true) -> [Float] {
            now += seconds
            if advance, let current = position {
                position = current + seconds
            }
            return monitor.update(at: now)
        }
        #expect(frame().allSatisfy { $0 == 0 } && monitor.hasSignal)
        monitor.buffer.append(sine(1000, amplitude: 0.5, count: 44100), sampleRate: 44100)
        #expect((frame().max() ?? 0) > 0.8)
        // Two views on the same frame see the same levels without decaying twice.
        #expect(monitor.update(at: now) == monitor.update(at: now))
        // A stalled position, like a buffer underrun: bars fall away but stay shown.
        for _ in 0 ..< 20 {
            _ = frame(advance: false)
        }
        #expect((frame(advance: false).max() ?? 1) < 0.02 && monitor.hasSignal)
        // Nothing to show for over 1.5 s while playing: hide.
        for _ in 0 ..< 90 {
            _ = frame(advance: false)
        }
        #expect(!monitor.hasSignal)
        // After a pause, earlier silence no longer counts.
        _ = frame(2)
        #expect(monitor.hasSignal)
        position = nil
        #expect((frame().max() ?? 1) < 1)
    }

    @Test @MainActor func playerReadsTheVisualiserSetting() throws {
        let store = try TestStore()
        #expect(testPlayer(store).visualizerEnabled)
        store.defaults.set(false, forKey: PlayerController.visualizerKey)
        #expect(!testPlayer(store).visualizerEnabled)
    }
}
