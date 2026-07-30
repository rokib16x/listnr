import XCTest
@testable import listnr

/// The text rules live in one dependency-free place so they can be pinned
/// down exactly. The guiding principle: text alone cannot tell you whether
/// Whisper heard something, so nothing here may reject ordinary speech.
final class TranscriptTextTests: XCTestCase {

    // MARK: - clean()

    func testDecoderTokensStripped() {
        XCTAssertEqual(TranscriptText.clean("<|startoftranscript|> Hello <|endoftext|>"), "Hello")
        XCTAssertEqual(TranscriptText.clean("<|nospeech|>"), "")
    }

    func testBracketAnnotationsRemoved() {
        XCTAssertEqual(TranscriptText.clean("[MUSIC]"), "")
        XCTAssertEqual(TranscriptText.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptText.clean("[music] hello [applause]"), "hello")
    }

    func testUppercaseMarkerOnlyInsideBrackets() {
        // Whisper writes markers in caps inside square brackets.
        XCTAssertEqual(TranscriptText.clean("[NOISE MARKER] hi"), "hi")
        // A parenthesised acronym is real speech and must survive.
        XCTAssertEqual(TranscriptText.clean("we call the (API) directly"), "we call the (API) directly")
    }

    func testParenAndAsteriskAnnotationsRemovedOnlyWhenAnnotations() {
        XCTAssertEqual(TranscriptText.clean("(laughs) I agree"), "I agree")
        XCTAssertEqual(TranscriptText.clean("*sighs* fine"), "fine")
        // Content that is not an annotation keeps its delimiters.
        XCTAssertEqual(TranscriptText.clean("the API (v2) ships"), "the API (v2) ships")
        XCTAssertEqual(TranscriptText.clean("I *really* mean it"), "I *really* mean it")
    }

    func testTrailingDigitArtifactCleanedButDecimalsSurvive() {
        XCTAssertEqual(TranscriptText.clean("Thank you.000"), "Thank you")
        XCTAssertEqual(TranscriptText.clean("version 3.14"), "version 3.14")
        XCTAssertEqual(TranscriptText.clean("that costs $19.99"), "that costs $19.99")
        XCTAssertEqual(TranscriptText.clean("19.99"), "19.99")
    }

    func testWhitespaceNormalised() {
        XCTAssertEqual(TranscriptText.clean("  a   b  "), "a b")
        XCTAssertEqual(TranscriptText.clean("(laughs)   and (background noise) then"), "and then")
    }

    // MARK: - isNonSpeech(): what must be rejected

    func testEmptyAndPunctuationOnlyAreNonSpeech() {
        XCTAssertTrue(TranscriptText.isNonSpeech(""))
        XCTAssertTrue(TranscriptText.isNonSpeech("   "))
        XCTAssertTrue(TranscriptText.isNonSpeech("..."))
        XCTAssertTrue(TranscriptText.isNonSpeech("!!!"))
        XCTAssertTrue(TranscriptText.isNonSpeech("?!."))
    }

    func testCaptionArtifactsAreNonSpeech() {
        XCTAssertTrue(TranscriptText.isNonSpeech("thanks for watching"))
        XCTAssertTrue(TranscriptText.isNonSpeech("Thanks for watching!"))
        XCTAssertTrue(TranscriptText.isNonSpeech("Please subscribe"))
        XCTAssertTrue(TranscriptText.isNonSpeech("Subtitles by the Amara.org community"))
        XCTAssertTrue(TranscriptText.isNonSpeech("see you in the next video"))
    }

    func testBareAnnotationKeywordIsNonSpeech() {
        // A whole segment that is only a stage direction, brackets already gone.
        XCTAssertTrue(TranscriptText.isNonSpeech("music"))
        XCTAssertTrue(TranscriptText.isNonSpeech("laughter"))
    }

    // MARK: - isNonSpeech(): what must survive

    func testOrdinaryShortRepliesSurvive() {
        // Every one of these was wrongly rejected by the old text blocklist.
        for phrase in ["okay", "ok", "thanks", "thank you", "bye", "you", "uh", "um", "hmm", "the", "a"] {
            XCTAssertFalse(TranscriptText.isNonSpeech(phrase), "\(phrase) is real speech")
        }
    }

    func testShortNonLatinRepliesSurvive() {
        // The old two-character length rule deleted the most common replies in
        // languages /lang advertises.
        XCTAssertFalse(TranscriptText.isNonSpeech("好的"))   // Chinese "okay"
        XCTAssertFalse(TranscriptText.isNonSpeech("はい"))   // Japanese "yes"
        XCTAssertFalse(TranscriptText.isNonSpeech("да"))     // Russian "yes"
        XCTAssertFalse(TranscriptText.isNonSpeech("হ্যাঁ"))    // Bangla "yes"
        XCTAssertFalse(TranscriptText.isNonSpeech("हाँ"))     // Hindi "yes"
    }

    func testBareNumberSurvives() {
        XCTAssertFalse(TranscriptText.isNonSpeech("42"))
    }

    func testOrdinarySentencesSurvive() {
        XCTAssertFalse(TranscriptText.isNonSpeech("hello world"))
        XCTAssertFalse(TranscriptText.isNonSpeech("let's ship the API v2 on Friday"))
        XCTAssertFalse(TranscriptText.isNonSpeech("thanks, that helps a lot"))
    }

    func testCleanThenDetectPipeline() {
        // The two functions as WhisperKitTranscriber composes them.
        let cleaned = TranscriptText.clean("[MUSIC] (laughs) ")
        XCTAssertTrue(TranscriptText.isNonSpeech(cleaned))

        let kept = TranscriptText.clean("<|startoftranscript|> okay, sounds good <|endoftext|>")
        XCTAssertFalse(TranscriptText.isNonSpeech(kept))
        XCTAssertEqual(kept, "okay, sounds good")
    }
}
