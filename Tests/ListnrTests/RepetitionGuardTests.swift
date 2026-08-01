import XCTest
@testable import ListnrCore

/// Relaxing the confidence gate for non-Latin scripts (see `DecodeTuningTests`)
/// buys back real speech, but it also lets more degenerate output through. This
/// guard is the counterweight, and it works on the shape of the text rather than
/// on a keyword list, so it applies to every language equally.
final class RepetitionGuardTests: XCTestCase {

    // MARK: - Loops that must be caught

    func testSameWordRepeatedManyTimes() {
        XCTAssertTrue(TranscriptText.isRepetitionLoop("okay okay okay okay okay"))
    }

    func testRepeatedPhrase() {
        XCTAssertTrue(TranscriptText.isRepetitionLoop("I think I think I think"))
    }

    func testRepeatedLongerPhrase() {
        XCTAssertTrue(TranscriptText.isRepetitionLoop(
            "we need to ship we need to ship we need to ship"
        ))
    }

    func testRepetitionIsCaseAndPunctuationInsensitive() {
        XCTAssertTrue(TranscriptText.isRepetitionLoop("Yes. yes, YES! yes"))
    }

    func testRepetitionInNonLatinScript() {
        // The exact failure mode the relaxed Indic gate would otherwise admit.
        XCTAssertTrue(TranscriptText.isRepetitionLoop("আচ্ছা আচ্ছা আচ্ছা আচ্ছা"))
    }

    func testRepetitionInSpacelessScript() {
        // Han text arrives as one whitespace-delimited token, so the word-level
        // pass cannot see the loop and the character pass has to.
        XCTAssertTrue(TranscriptText.isRepetitionLoop("好的好的好的好的好的好的"))
    }

    func testLoopBuriedAfterRealSpeech() {
        XCTAssertTrue(TranscriptText.isRepetitionLoop(
            "so the plan is to ship on friday friday friday friday friday"
        ))
    }

    // MARK: - Real speech that must survive

    func testOrdinarySentenceSurvives() {
        XCTAssertFalse(TranscriptText.isRepetitionLoop(
            "let us ship the beta on friday and write the changelog after"
        ))
    }

    func testEmphaticDoublingSurvives() {
        // "very very good" is ordinary speech in most languages, and doubling
        // for emphasis is grammatical in Bangla and Hindi.
        XCTAssertFalse(TranscriptText.isRepetitionLoop("that is very very good"))
        XCTAssertFalse(TranscriptText.isRepetitionLoop("খুব খুব ভালো"))
    }

    func testTripledWordSurvives() {
        // Three is still plausibly a human being emphatic; four is a decoder loop.
        XCTAssertFalse(TranscriptText.isRepetitionLoop("no no no"))
    }

    func testRepeatedPhrasePairSurvives() {
        // Two occurrences of a phrase is a callback, not a loop.
        XCTAssertFalse(TranscriptText.isRepetitionLoop("I think I think we agree"))
    }

    func testShortTextSurvives() {
        XCTAssertFalse(TranscriptText.isRepetitionLoop("okay"))
        XCTAssertFalse(TranscriptText.isRepetitionLoop(""))
        XCTAssertFalse(TranscriptText.isRepetitionLoop("hello there"))
    }

    func testShortNonLatinReplySurvives() {
        // The bug this codebase already fixed once: two-character replies are
        // the most common thing said in these languages.
        XCTAssertFalse(TranscriptText.isRepetitionLoop("好的"))
        XCTAssertFalse(TranscriptText.isRepetitionLoop("はい"))
        XCTAssertFalse(TranscriptText.isRepetitionLoop("আচ্ছা"))
    }

    func testNaturallyRepetitiveCountingSurvives() {
        XCTAssertFalse(TranscriptText.isRepetitionLoop("one two three four five six"))
    }

    // MARK: - Wiring

    func testRepetitionLoopCountsAsNonSpeech() {
        XCTAssertTrue(TranscriptText.isNonSpeech("okay okay okay okay okay"))
    }

    func testNonSpeechStillAcceptsOrdinarySpeech() {
        XCTAssertFalse(TranscriptText.isNonSpeech("we should ship on friday"))
    }
}
