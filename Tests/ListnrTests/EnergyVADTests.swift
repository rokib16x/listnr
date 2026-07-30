import XCTest
@testable import listnr

/// Synthetic-audio checks for the energy VAD, including the two floors that
/// exist because the pre-roll and hangover padding defeat a plain duration
/// floor: `minVoicedSeconds` (total time above threshold) and
/// `minVoicedRunSeconds` (longest contiguous voiced stretch).
final class EnergyVADTests: XCTestCase {
    private let sampleRate = 16_000.0

    /// Alternating-sign samples of the given amplitude, so RMS == amplitude.
    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Push audio through a fresh default VAD in capture-sized chunks.
    private func segments(
        for audio: [Float],
        flush: Bool = true,
        vad: EnergyVAD = EnergyVAD()
    ) -> [EnergyVAD.Segment] {
        var vad = vad
        var out: [EnergyVAD.Segment] = []
        var index = 0
        while index < audio.count {
            let end = min(index + 1024, audio.count)
            out.append(contentsOf: vad.push(Array(audio[index..<end])))
            index = end
        }
        if flush {
            out.append(contentsOf: vad.flush())
        }
        return out
    }

    func testSilenceProducesNothing() {
        XCTAssertTrue(segments(for: silence(seconds: 3)).isEmpty)
    }

    func testQuietAudioBelowThresholdIgnored() {
        let audio = silence(seconds: 1) + tone(seconds: 1, amplitude: 0.005) + silence(seconds: 1)
        XCTAssertTrue(segments(for: audio).isEmpty)
    }

    func testSingleWordDetected() {
        let audio = silence(seconds: 1) + tone(seconds: 0.5, amplitude: 0.1) + silence(seconds: 1.5)
        XCTAssertEqual(segments(for: audio).count, 1)
    }

    func testTinyBlipRejected() {
        // One 30 ms frame over threshold. Pre-roll + hangover pad the buffer to
        // ~1 s, which used to pass the duration floor on its own.
        let audio = silence(seconds: 1) + tone(seconds: 0.03, amplitude: 0.1) + silence(seconds: 1.5)
        XCTAssertTrue(segments(for: audio).isEmpty)
    }

    func testClickTrainRejected() {
        // Six 30 ms clicks inside one hangover window: 180 ms of total voiced
        // time, which passes the voiced-duration floor, but no contiguous run
        // longer than a click. Speech has a continuous syllable; typing does not.
        var audio = silence(seconds: 1)
        for _ in 0..<6 {
            audio += tone(seconds: 0.03, amplitude: 0.1)
            audio += silence(seconds: 0.06)
        }
        audio += silence(seconds: 1.5)
        XCTAssertTrue(segments(for: audio).isEmpty)
    }

    func testShortVoicedBelowFloorRejected() {
        // 100 ms voiced: run floor (90 ms) passes, voiced floor (150 ms) fails.
        let audio = silence(seconds: 1) + tone(seconds: 0.10, amplitude: 0.1) + silence(seconds: 1.5)
        XCTAssertTrue(segments(for: audio).isEmpty)
    }

    func testShortWordAccepted() {
        // 250 ms clears both voiced floors.
        let audio = silence(seconds: 1) + tone(seconds: 0.25, amplitude: 0.1) + silence(seconds: 1.5)
        XCTAssertEqual(segments(for: audio).count, 1)
    }

    func testTwoUtterancesSeparatedByPause() {
        let audio = silence(seconds: 1)
            + tone(seconds: 0.5, amplitude: 0.1)
            + silence(seconds: 2)
            + tone(seconds: 0.5, amplitude: 0.1)
            + silence(seconds: 1.5)
        let segs = segments(for: audio)
        XCTAssertEqual(segs.count, 2)
        XCTAssertLessThan(segs[0].startSeconds, segs[1].startSeconds)
    }

    func testPrerollIncludedInSegment() {
        let audio = silence(seconds: 1) + tone(seconds: 0.5, amplitude: 0.1) + silence(seconds: 1.5)
        guard let seg = segments(for: audio).first else {
            return XCTFail("expected a segment")
        }
        // The segment carries lookback audio from before the trigger frame,
        // so it must be longer than the voiced part alone.
        let voicedSeconds = 0.5
        XCTAssertGreaterThan(Double(seg.samples.count) / sampleRate, voicedSeconds + 0.3)
        // And its start is credited before the audible onset at t=1.0.
        XCTAssertLessThan(seg.startSeconds, 1.0)
        XCTAssertGreaterThan(seg.startSeconds, 0.4)
    }

    func testLongUtteranceSplitAtMaxLength() {
        let audio = silence(seconds: 1) + tone(seconds: 30, amplitude: 0.1) + silence(seconds: 1.5)
        let segs = segments(for: audio)
        XCTAssertGreaterThanOrEqual(segs.count, 2)
        for seg in segs {
            XCTAssertLessThanOrEqual(Double(seg.samples.count) / sampleRate, 12.1)
        }
    }

    func testFlushEmitsTrailingUtterance() {
        // Speech running right up to the end of the stream, with no trailing
        // silence to trigger the hangover: only flush() can emit it.
        let audio = silence(seconds: 1) + tone(seconds: 0.5, amplitude: 0.1)
        let withoutFlush = segments(for: audio, flush: false)
        XCTAssertTrue(withoutFlush.isEmpty)
        let withFlush = segments(for: audio, flush: true)
        XCTAssertEqual(withFlush.count, 1)
    }
}
