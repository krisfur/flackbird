import Foundation
@testable import SwiftFlac
import Testing

struct SpectrumTests {
    private func sine(_ frequency: Double, amplitude: Float, sampleRate: Double = 44100) -> [Float] {
        (0 ..< SpectrumAnalyzer.size).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
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
        #expect(analyzer.levels(of: [Float](repeating: 0, count: SpectrumAnalyzer.size), sampleRate: 44100, bands: 32).allSatisfy { $0 == 0 })
        #expect(analyzer.levels(of: [0, 1], sampleRate: 44100, bands: 8) == [Float](repeating: 0, count: 8))
        #expect(analyzer.levels(of: sine(1000, amplitude: 0.5), sampleRate: 0, bands: 4) == [0, 0, 0, 0])
    }

    @Test func quieterTonesReadLower() throws {
        let analyzer = try #require(SpectrumAnalyzer())
        let loud = analyzer.levels(of: sine(1000, amplitude: 0.5), sampleRate: 44100, bands: 32).max() ?? 0
        let quiet = analyzer.levels(of: sine(1000, amplitude: 0.005), sampleRate: 44100, bands: 32).max() ?? 0
        #expect(quiet < loud && quiet > 0)
    }

    @Test @MainActor func monitorFallsBackWhenPausedAndStartsEmpty() {
        let monitor = SpectrumMonitor()
        #expect(monitor.buffer.latest(SpectrumAnalyzer.size) == nil)
        #expect(monitor.update(isPlaying: true).allSatisfy { $0 == 0 })
        #expect(monitor.buffer.makeTap() != nil)
    }
}
