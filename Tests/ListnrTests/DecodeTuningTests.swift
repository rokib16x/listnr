import XCTest
@testable import listnr

/// Whisper's confidence signals are not comparable across writing systems, so
/// the acceptance gate is keyed on script. These tests pin the two facts that
/// motivate that: Bengali/Devanagari output has a systematically *lower*
/// average log-probability and a systematically *higher* compression ratio than
/// English saying the same thing, and the English thresholds therefore reject
/// perfectly good non-Latin speech.
final class DecodeTuningTests: XCTestCase {

    // MARK: - Script classification

    func testLatinLanguages() {
        for code in ["en", "es", "fr", "de", "it", "pt", "nl"] {
            XCTAssertEqual(ScriptClass(languageCode: code), .latin, "expected \(code) to be latin")
        }
    }

    func testIndicLanguages() {
        for code in ["bn", "hi", "ta", "te", "mr", "gu", "pa", "ne"] {
            XCTAssertEqual(ScriptClass(languageCode: code), .indic, "expected \(code) to be indic")
        }
    }

    func testCJKLanguages() {
        for code in ["ja", "zh", "ko", "yue"] {
            XCTAssertEqual(ScriptClass(languageCode: code), .cjk, "expected \(code) to be cjk")
        }
    }

    func testNilLanguageIsUnknown() {
        // `/lang auto` before the first detection lands here.
        XCTAssertEqual(ScriptClass(languageCode: nil), .unknown)
    }

    func testUnrecognisedCodeIsUnknown() {
        XCTAssertEqual(ScriptClass(languageCode: "xx"), .unknown)
    }

    func testCodeIsCaseAndRegionInsensitive() {
        XCTAssertEqual(ScriptClass(languageCode: "BN"), .indic)
        XCTAssertEqual(ScriptClass(languageCode: "zh-Hans"), .cjk)
        XCTAssertEqual(ScriptClass(languageCode: "en_US"), .latin)
    }

    func testLanguageModeMapsToScript() {
        XCTAssertEqual(LanguageMode.en.scriptClass, .latin)
        XCTAssertEqual(LanguageMode.bn.scriptClass, .indic)
        XCTAssertEqual(LanguageMode.hi.scriptClass, .indic)
        XCTAssertEqual(LanguageMode.ja.scriptClass, .cjk)
        XCTAssertEqual(LanguageMode.zh.scriptClass, .cjk)
        XCTAssertEqual(LanguageMode.auto.scriptClass, .unknown)
    }

    // MARK: - The English gate is what was rejecting non-Latin speech

    /// The regression this whole change exists for: real Bangla, decoded
    /// correctly, scored the way Bengali always scores, was thrown away by the
    /// English thresholds and returned as empty text with nothing logged.
    func testEnglishGateRejectsTypicalHealthyBanglaScores() {
        let english = DecodeTuning.confidence(for: .latin)
        XCTAssertFalse(english.accepts(noSpeechProb: 0.3, avgLogProb: -1.25, compressionRatio: 3.1))
    }

    func testIndicGateAcceptsTheSameScores() {
        let indic = DecodeTuning.confidence(for: .indic)
        XCTAssertTrue(indic.accepts(noSpeechProb: 0.3, avgLogProb: -1.25, compressionRatio: 3.1))
    }

    func testLatinGateIsUnchangedFromTheShippedDefaults() {
        // English works today. This change must not move it.
        let latin = DecodeTuning.confidence(for: .latin)
        let shipped = WhisperKitTranscriber.Confidence()
        XCTAssertEqual(latin.maxNoSpeechProb, shipped.maxNoSpeechProb)
        XCTAssertEqual(latin.minAvgLogProb, shipped.minAvgLogProb)
        XCTAssertEqual(latin.maxCompressionRatio, shipped.maxCompressionRatio)
    }

    func testNonLatinGatesAreStrictlyMorePermissive() {
        let latin = DecodeTuning.confidence(for: .latin)
        for script in [ScriptClass.indic, .cjk, .unknown] {
            let gate = DecodeTuning.confidence(for: script)
            XCTAssertGreaterThan(gate.maxCompressionRatio, latin.maxCompressionRatio, "\(script)")
            XCTAssertLessThan(gate.minAvgLogProb, latin.minAvgLogProb, "\(script)")
        }
    }

    /// Permissive is not unbounded. Degenerate repetition must still be caught
    /// by the compression ratio on every script, or relaxing the gate would
    /// simply trade missing text for gibberish.
    func testEveryGateStillRejectsSevereRepetition() {
        for script in [ScriptClass.latin, .indic, .cjk, .unknown] {
            let gate = DecodeTuning.confidence(for: script)
            XCTAssertFalse(
                gate.accepts(noSpeechProb: 0.1, avgLogProb: -0.2, compressionRatio: 8.0),
                "\(script) accepted an obvious repetition loop"
            )
        }
    }

    func testUnknownScriptIsAsPermissiveAsTheWidestKnownScript() {
        // Auto mode cannot know the script yet, so it must not be the path that
        // silently drops text; it takes the widest gate.
        let unknown = DecodeTuning.confidence(for: .unknown)
        let indic = DecodeTuning.confidence(for: .indic)
        XCTAssertGreaterThanOrEqual(unknown.maxCompressionRatio, indic.maxCompressionRatio)
        XCTAssertLessThanOrEqual(unknown.minAvgLogProb, indic.minAvgLogProb)
    }

    // MARK: - Decoder thresholds

    func testDecodeThresholdsTrackTheAcceptanceGate() {
        // The decoder's own fallback triggers must be at least as permissive as
        // the gate, otherwise the decoder discards a candidate the gate would
        // have accepted and no amount of gate-relaxing can recover it.
        for script in [ScriptClass.latin, .indic, .cjk, .unknown] {
            let decode = DecodeTuning.decoding(for: script)
            let gate = DecodeTuning.confidence(for: script)
            XCTAssertLessThanOrEqual(decode.compressionRatioThreshold, gate.maxCompressionRatio, "\(script)")
            XCTAssertGreaterThanOrEqual(decode.logProbThreshold, gate.minAvgLogProb, "\(script)")
        }
    }

    func testNonLatinGetsMoreTemperatureFallbacks() {
        // Re-decoding at a higher temperature is the only mechanism that turns a
        // hallucinated window into a real one. Non-Latin trips the checks more
        // often, so it needs more than the single retry English gets.
        let latin = DecodeTuning.decoding(for: .latin)
        for script in [ScriptClass.indic, .cjk, .unknown] {
            XCTAssertGreaterThan(
                DecodeTuning.decoding(for: script).temperatureFallbackCount,
                latin.temperatureFallbackCount,
                "\(script)"
            )
        }
    }

    func testLatinDecodeThresholdsAreUnchanged() {
        let latin = DecodeTuning.decoding(for: .latin)
        XCTAssertEqual(latin.compressionRatioThreshold, 2.2)
        XCTAssertEqual(latin.logProbThreshold, -0.8)
        XCTAssertEqual(latin.firstTokenLogProbThreshold, -1.2)
        XCTAssertEqual(latin.noSpeechThreshold, 0.45)
        XCTAssertEqual(latin.temperatureFallbackCount, 1)
    }
}
