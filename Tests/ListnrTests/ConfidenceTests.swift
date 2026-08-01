import XCTest
@testable import ListnrCore

/// The per-segment acceptance gate. The no-speech and log-probability tests
/// combine with AND (matching the reference Whisper implementation); the
/// compression ratio stands alone as a degenerate-repetition signal.
final class ConfidenceTests: XCTestCase {
    private let gate = WhisperKitTranscriber.Confidence()

    func testConfidentSpeechAccepted() {
        XCTAssertTrue(gate.accepts(noSpeechProb: 0.1, avgLogProb: -0.3, compressionRatio: 1.4))
    }

    func testBothSignalsBadRejected() {
        XCTAssertFalse(gate.accepts(noSpeechProb: 0.9, avgLogProb: -1.5, compressionRatio: 1.4))
    }

    func testHighNoSpeechAloneIsNotEnough() {
        // AND semantics: quiet-but-real speech often trips one signal.
        XCTAssertTrue(gate.accepts(noSpeechProb: 0.9, avgLogProb: -0.3, compressionRatio: 1.4))
    }

    func testPoorLogProbAloneIsNotEnough() {
        // Accented or mumbled speech has poor logprob but low no-speech prob.
        XCTAssertTrue(gate.accepts(noSpeechProb: 0.2, avgLogProb: -2.0, compressionRatio: 1.4))
    }

    func testDegenerateRepetitionRejectedIndependently() {
        XCTAssertFalse(gate.accepts(noSpeechProb: 0.1, avgLogProb: -0.2, compressionRatio: 3.5))
    }

    func testBoundariesAreExclusive() {
        // Exactly at the thresholds must pass: the comparisons are strict.
        XCTAssertTrue(gate.accepts(noSpeechProb: 0.7, avgLogProb: -0.9, compressionRatio: 2.6))
    }
}
