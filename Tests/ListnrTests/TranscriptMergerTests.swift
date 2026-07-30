import XCTest
@testable import listnr

final class TranscriptMergerTests: XCTestCase {
    private func line(_ speaker: String, _ t: Double, _ text: String = "x") -> TranscriptLine {
        TranscriptLine(speaker: speaker, startSeconds: t, text: text)
    }

    // MARK: - shift / merge

    func testShiftByZeroIsIdentity() {
        let lines = [line("You", 1.0), line("You", 2.0)]
        let shifted = TranscriptMerger.shift(lines, by: 0)
        XCTAssertEqual(shifted.map(\.startSeconds), [1.0, 2.0])
    }

    func testShiftMovesTimestamps() {
        let shifted = TranscriptMerger.shift([line("Others", 1.5)], by: 0.25)
        XCTAssertEqual(shifted[0].startSeconds, 1.75, accuracy: 1e-9)
    }

    func testShiftClampsAtZero() {
        let shifted = TranscriptMerger.shift([line("Others", 0.1)], by: -0.5)
        XCTAssertEqual(shifted[0].startSeconds, 0)
    }

    func testMergeInterleavesLanesByTime() {
        let you = [line("You", 0.5), line("You", 4.0)]
        let others = [line("Speaker 1", 2.0), line("Speaker 2", 3.0)]
        let merged = TranscriptMerger.merge([you, others])
        XCTAssertEqual(merged.map(\.speaker), ["You", "Speaker 1", "Speaker 2", "You"])
    }

    // MARK: - laneOffsets

    private func result(mic: Double?, system: Double?) -> DualCaptureSession.Result {
        DualCaptureSession.Result(
            mic: [], system: [], durationSeconds: 0,
            micFirstSampleTime: mic, systemFirstSampleTime: system
        )
    }

    func testMissingAnchorsMeanNoShift() {
        let o = result(mic: nil, system: 100).laneOffsets
        XCTAssertEqual(o.mic, 0)
        XCTAssertEqual(o.system, 0)
    }

    func testImplausibleSkewMeansNoShift() {
        // Clocks that disagree by more than 5 s are not comparable; shifting by
        // a bogus amount is worse than not shifting.
        let o = result(mic: 100, system: 107).laneOffsets
        XCTAssertEqual(o.mic, 0)
        XCTAssertEqual(o.system, 0)
    }

    func testEarlierLaneBecomesOrigin() {
        // Mic started first: mic lines stay, system lines move forward by the gap.
        let o = result(mic: 100.0, system: 100.2).laneOffsets
        XCTAssertEqual(o.mic, 0, accuracy: 1e-9)
        XCTAssertEqual(o.system, 0.2, accuracy: 1e-9)

        let r = result(mic: 100.25, system: 100.0).laneOffsets
        XCTAssertEqual(r.mic, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.system, 0, accuracy: 1e-9)
    }
}
