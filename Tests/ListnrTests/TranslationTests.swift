import XCTest
@testable import listnr

/// Whisper's `translate` task turns any supported language into English. The
/// hazard it brings is specific and quiet: the `large-v3-turbo` builds were
/// fine-tuned for transcription only, and OpenAI documents that they "return the
/// original language even if `--task translate` is specified". No error, no
/// warning, just the wrong language for the length of a meeting. Most of these
/// tests exist to make sure that pairing can never happen by accident.
final class TranslationTests: XCTestCase {

    // MARK: - Capability metadata

    func testTurboBuildsAreMarkedAsUnableToTranslate() {
        for id in ["whisper-large-v3-turbo", "whisper-large-v3-turbo-fast"] {
            XCTAssertEqual(
                ModelRegistry.find(id)?.supportsTranslation, false,
                "\(id) must not claim translation support"
            )
        }
    }

    func testEnglishOnlyModelsCannotTranslate() {
        for model in ModelRegistry.shared where model.languages == ["en"] {
            XCTAssertFalse(model.supportsTranslation, "\(model.id) is English-only")
        }
    }

    func testTheMultilingualLadderCanTranslate() {
        for id in ["whisper-tiny", "whisper-base", "whisper-small", "whisper-medium", "whisper-large-v2"] {
            XCTAssertEqual(
                ModelRegistry.find(id)?.supportsTranslation, true,
                "\(id) should support translation"
            )
        }
    }

    func testTranslationDefaultExistsAndCanTranslate() {
        let model = ModelRegistry.find(ModelRegistry.defaultTranslationModelID)
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.supportsTranslation, true)
    }

    func testTranslationCapableListIsSortedBySize() {
        let sizes = ModelRegistry.translationCapable().map(\.sizeMB)
        XCTAssertEqual(sizes, sizes.sorted(), "cheapest-first is the documented order")
        XCTAssertFalse(sizes.isEmpty)
    }

    /// The non-obvious result worth locking in: the quantized large-v2 build is
    /// both smaller than medium and better at translation, so medium is never the
    /// right recommendation for this task.
    func testTheAccuracyPickIsLighterThanMedium() {
        let large = ModelRegistry.find("whisper-large-v2")?.sizeMB ?? .max
        let medium = ModelRegistry.find("whisper-medium")?.sizeMB ?? 0
        XCTAssertLessThan(large, medium)
    }

    // MARK: - Model resolution

    func testTranslatingSubstitutesAModelThatCanActuallyTranslate() throws {
        for mode in [LanguageMode.bn, .hi, .ja, .zh, .auto] {
            var options = SessionOptions()
            options.language = mode
            options.translate = true
            options.modelID = nil
            let model = try options.resolveModel()
            XCTAssertTrue(
                model.supportsTranslation,
                "\(mode.rawValue) resolved to \(model.id), which cannot translate"
            )
        }
    }

    func testExplicitlyChoosingAModelThatCannotTranslateIsRefused() {
        var options = SessionOptions()
        options.language = .bn
        options.translate = true
        options.modelID = "whisper-large-v3-turbo-fast"

        XCTAssertThrowsError(try options.resolveModel()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("cannot translate"), "got: \(message)")
            // The message has to name a way forward, not just refuse.
            XCTAssertTrue(message.contains("whisper-large-v2"), "got: \(message)")
        }
    }

    func testAnExplicitCapableModelIsHonoured() throws {
        var options = SessionOptions()
        options.language = .bn
        options.translate = true
        options.modelID = "whisper-small"
        XCTAssertEqual(try options.resolveModel().id, "whisper-small")
    }

    func testTranscribingIsUnaffectedByTheTranslationRules() throws {
        for mode in LanguageMode.allCases {
            var options = SessionOptions()
            options.language = mode
            options.translate = false
            options.modelID = nil
            XCTAssertEqual(try options.resolveModel().id, mode.preferredModelID(current: nil))
        }
    }

    // MARK: - Toggling

    func testTurningTranslationOnReplacesATurboModel() {
        var options = SessionOptions()
        options.applyLanguage(.bn)
        XCTAssertEqual(options.modelID, "whisper-large-v3-turbo-fast")

        options.applyTranslate(true)
        XCTAssertEqual(options.modelID, ModelRegistry.defaultTranslationModelID)
        XCTAssertNoThrow(try options.resolveModel())
    }

    func testTurningTranslationOffRestoresTheFastModel() {
        var options = SessionOptions()
        options.applyLanguage(.bn)
        options.applyTranslate(true)
        options.applyTranslate(false)
        XCTAssertEqual(options.modelID, "whisper-large-v3-turbo-fast")
    }

    func testTurningTranslationOnKeepsAnAlreadyCapableModel() {
        var options = SessionOptions()
        options.language = .hi
        options.modelID = "whisper-small"
        options.applyTranslate(true)
        XCTAssertEqual(options.modelID, "whisper-small", "no need to upgrade a capable choice")
    }

    func testChangingLanguageWhileTranslatingKeepsACapableModel() {
        var options = SessionOptions()
        options.applyTranslate(true)
        options.applyLanguage(.hi)
        XCTAssertEqual(ModelRegistry.find(options.modelID ?? "")?.supportsTranslation, true)
    }

    // MARK: - Warnings

    func testTranslatingEnglishIntoEnglishWarns() {
        var options = SessionOptions()
        options.language = .en
        options.translate = true
        XCTAssertNotNil(options.compatibilityWarning)
    }

    func testTranslatingANonEnglishLanguageDoesNotWarn() {
        var options = SessionOptions()
        options.language = .bn
        options.applyTranslate(true)
        XCTAssertNil(options.compatibilityWarning)
    }

    // MARK: - Threshold handover

    /// In translate mode the output text is English, so its compression ratio is
    /// English-shaped. Keeping the relaxed Indic ceiling would admit exactly the
    /// repetition loops that ceiling was widened past.
    func testTranslatingJudgesCompressionByTheLatinCeiling() {
        let latin = DecodeTuning.confidence(for: .latin)
        for script in [ScriptClass.indic, .cjk, .unknown] {
            let translating = DecodeTuning.confidence(for: script, translating: true)
            XCTAssertEqual(
                translating.maxCompressionRatio, latin.maxCompressionRatio,
                "\(script) kept a relaxed ceiling while translating"
            )
        }
    }

    /// The log-probability floor describes how hard the audio was, not what the
    /// output looks like, and translating out of a low-resource language is at
    /// least as hard as transcribing it. That floor stays where the input script
    /// put it.
    func testTranslatingKeepsTheInputScriptsLogProbFloor() {
        for script in [ScriptClass.indic, .cjk, .unknown] {
            XCTAssertEqual(
                DecodeTuning.confidence(for: script, translating: true).minAvgLogProb,
                DecodeTuning.confidence(for: script).minAvgLogProb,
                "\(script)"
            )
        }
    }

    func testTranslatingKeepsTheExtraTemperatureFallbacks() {
        for script in [ScriptClass.indic, .cjk, .unknown] {
            XCTAssertEqual(
                DecodeTuning.decoding(for: script, translating: true).temperatureFallbackCount,
                DecodeTuning.decoding(for: script).temperatureFallbackCount,
                "\(script)"
            )
        }
    }

    func testDecodeStillTracksTheGateWhileTranslating() {
        for script in [ScriptClass.latin, .indic, .cjk, .unknown] {
            let decode = DecodeTuning.decoding(for: script, translating: true)
            let gate = DecodeTuning.confidence(for: script, translating: true)
            XCTAssertLessThanOrEqual(decode.compressionRatioThreshold, gate.maxCompressionRatio, "\(script)")
            XCTAssertGreaterThanOrEqual(decode.logProbThreshold, gate.minAvgLogProb, "\(script)")
        }
    }

    func testTranscriptionThresholdsAreUnchangedByTheNewParameter() {
        for script in [ScriptClass.latin, .indic, .cjk, .unknown] {
            XCTAssertEqual(
                DecodeTuning.confidence(for: script, translating: false).maxCompressionRatio,
                DecodeTuning.confidence(for: script).maxCompressionRatio,
                "\(script)"
            )
        }
    }
}
