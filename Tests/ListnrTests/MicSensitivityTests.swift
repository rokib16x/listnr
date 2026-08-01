import XCTest
@testable import ListnrCore

/// The thresholds that decide whether audio is speech are absolute RMS values,
/// and microphone levels vary by more than an order of magnitude across
/// hardware. A real session on a built-in MacBook microphone peaked at 0.017
/// while the user spoke Bangla continuously — under the 0.018 floor that decides
/// whether a finished segment is worth transcribing. Minutes of speech never
/// reached Whisper, and the transcript had gaps with no stated cause.
final class MicSensitivityTests: XCTestCase {

    func testParsesEveryLevel() {
        XCTAssertEqual(MicSensitivity.parse("high"), .high)
        XCTAssertEqual(MicSensitivity.parse("normal"), .normal)
        XCTAssertEqual(MicSensitivity.parse("low"), .low)
    }

    func testParseIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(MicSensitivity.parse("  HIGH "), .high)
        XCTAssertEqual(MicSensitivity.parse("Normal"), .normal)
    }

    func testUnknownLevelIsRejected() {
        XCTAssertNil(MicSensitivity.parse("loud"))
        XCTAssertNil(MicSensitivity.parse(""))
    }

    func testNormalIsUnity() {
        // Existing behaviour must not move for anyone who does not opt in.
        XCTAssertEqual(MicSensitivity.normal.multiplier, 1.0)
        XCTAssertEqual(LaneTuning.you(.normal).speechThreshold, LaneTuning.youBase.speechThreshold)
        XCTAssertEqual(LaneTuning.you(.normal).minSegmentRMS, LaneTuning.youBase.minSegmentRMS)
        XCTAssertEqual(LaneTuning.others(.normal).speechThreshold, LaneTuning.othersBase.speechThreshold)
        XCTAssertEqual(LaneTuning.others(.normal).minSegmentRMS, LaneTuning.othersBase.minSegmentRMS)
    }

    func testHigherSensitivityHearsMore() {
        XCTAssertLessThan(MicSensitivity.high.multiplier, MicSensitivity.normal.multiplier)
        XCTAssertGreaterThan(MicSensitivity.low.multiplier, MicSensitivity.normal.multiplier)
    }

    func testThresholdsAreOrderedAcrossLevels() {
        for lane in [LaneTuning.you, LaneTuning.others] {
            XCTAssertLessThan(lane(.high).speechThreshold, lane(.normal).speechThreshold)
            XCTAssertLessThan(lane(.normal).speechThreshold, lane(.low).speechThreshold)
            XCTAssertLessThan(lane(.high).minSegmentRMS, lane(.normal).minSegmentRMS)
            XCTAssertLessThan(lane(.normal).minSegmentRMS, lane(.low).minSegmentRMS)
        }
    }

    /// Scaling must not invert the relationships the thresholds encode: the
    /// segment floor sits above the per-frame speech threshold, so a lane cannot
    /// start an utterance it would then always discard.
    func testSegmentFloorStaysAboveTheSpeechThresholdAtEveryLevel() {
        for level in MicSensitivity.allCases {
            for lane in [LaneTuning.you, LaneTuning.others] {
                XCTAssertGreaterThan(
                    lane(level).minSegmentRMS, lane(level).speechThreshold,
                    "\(level)"
                )
            }
        }
    }

    /// The system lane is deliberately stricter than the microphone lane,
    /// because silence there made Whisper hallucinate. Scaling must preserve it.
    func testSystemLaneStaysStricterThanTheMicLane() {
        for level in MicSensitivity.allCases {
            XCTAssertGreaterThan(
                LaneTuning.others(level).speechThreshold,
                LaneTuning.you(level).speechThreshold,
                "\(level)"
            )
            XCTAssertGreaterThan(
                LaneTuning.others(level).minSegmentRMS,
                LaneTuning.you(level).minSegmentRMS,
                "\(level)"
            )
        }
    }

    /// The case that prompted all of this: a microphone peaking at 0.017.
    func testHighSensitivityAdmitsAQuietMicThatNormalRejects() {
        let observedPeak: Float = 0.017
        XCTAssertLessThan(observedPeak, LaneTuning.you(.normal).minSegmentRMS,
                          "the reported peak should be below the normal floor")
        XCTAssertGreaterThan(observedPeak, LaneTuning.you(.high).minSegmentRMS,
                             "high sensitivity must actually admit it")
    }

    func testDefaultSessionIsUnchanged() {
        XCTAssertEqual(SessionOptions().sensitivity, .normal)
    }

    func testEveryLevelHasAHumanSummary() {
        for level in MicSensitivity.allCases {
            XCTAssertFalse(level.summary.isEmpty)
        }
    }
}
