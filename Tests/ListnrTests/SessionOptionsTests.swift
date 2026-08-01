import XCTest
@testable import listnr

final class SessionOptionsTests: XCTestCase {

    // MARK: - LanguageMode.parse

    func testParsesKnownCodes() {
        XCTAssertEqual(LanguageMode.parse("en"), .en)
        XCTAssertEqual(LanguageMode.parse("bn"), .bn)
        XCTAssertEqual(LanguageMode.parse("hi"), .hi)
        XCTAssertEqual(LanguageMode.parse("auto"), .auto)
    }

    func testParseIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(LanguageMode.parse("  EN  "), .en)
        XCTAssertEqual(LanguageMode.parse("Auto"), .auto)
    }

    func testMultiIsAnAliasForAuto() {
        XCTAssertEqual(LanguageMode.parse("multi"), .auto)
    }

    func testUnknownCodeIsRejected() {
        XCTAssertNil(LanguageMode.parse("klingon"))
        XCTAssertNil(LanguageMode.parse(""))
    }

    func testWhisperLanguageIsNilOnlyForAuto() {
        XCTAssertNil(LanguageMode.auto.whisperLanguage)
        XCTAssertEqual(LanguageMode.en.whisperLanguage, "en")
        XCTAssertEqual(LanguageMode.bn.whisperLanguage, "bn")
    }

    // MARK: - preferredModelID

    func testEnglishKeepsAnEnglishModelAlreadyChosen() {
        XCTAssertEqual(LanguageMode.en.preferredModelID(current: "whisper-small.en"), "whisper-small.en")
    }

    func testEnglishFallsBackToBaseFromAMultilingualModel() {
        XCTAssertEqual(LanguageMode.en.preferredModelID(current: "whisper-large-v3-turbo"), "whisper-base.en")
        XCTAssertEqual(LanguageMode.en.preferredModelID(current: nil), "whisper-base.en")
    }

    func testNonEnglishNeverKeepsAnEnglishOnlyModel() {
        for mode in [LanguageMode.auto, .bn, .hi, .es, .fr, .de, .ja, .zh] {
            let id = mode.preferredModelID(current: "whisper-base.en")
            let model = ModelRegistry.find(id)
            XCTAssertNotNil(model, "\(mode.rawValue) chose an unregistered model: \(id)")
            XCTAssertNotEqual(
                model?.languages, ["en"],
                "\(mode.rawValue) needs a multilingual model, got \(id)"
            )
        }
    }

    /// The old default sent every non-English language to the full-precision
    /// 1.5 GB turbo, which could not keep up with a live conversation. Nothing
    /// should default to a model that large again.
    func testNonEnglishDefaultsStayWithinARealTimeBudget() {
        for mode in [LanguageMode.auto, .bn, .hi, .es, .fr, .de, .ja, .zh] {
            let id = mode.preferredModelID(current: nil)
            let size = ModelRegistry.find(id)?.sizeMB ?? .max
            XCTAssertLessThanOrEqual(size, 1_500, "\(mode.rawValue) defaults to \(id) at \(size) MB")
        }
    }

    func testIndicDefaultsToTheQuantizedTurbo() {
        for mode in [LanguageMode.bn, .hi] {
            XCTAssertEqual(mode.preferredModelID(current: nil), "whisper-large-v3-turbo-fast")
        }
    }

    func testApplyLanguageUpdatesBothFields() {
        var options = SessionOptions()
        options.applyLanguage(.bn)
        XCTAssertEqual(options.language, .bn)
        XCTAssertEqual(options.modelID, "whisper-large-v3-turbo-fast")
    }

    // MARK: - compatibilityWarning

    func testEnglishOnlyModelWithANonEnglishLanguageWarns() {
        var options = SessionOptions()
        options.language = .bn
        options.modelID = "whisper-base.en"
        let warning = options.compatibilityWarning
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("English-only") == true, "got: \(warning ?? "nil")")
    }

    func testMultilingualModelWithEnglishSuggestsTheEnglishModel() {
        var options = SessionOptions()
        options.language = .en
        options.modelID = "whisper-large-v2"
        XCTAssertTrue(options.compatibilityWarning?.contains("whisper-base.en") == true)
    }

    func testMatchingPairsDoNotWarn() {
        var english = SessionOptions()
        english.language = .en
        english.modelID = "whisper-base.en"
        XCTAssertNil(english.compatibilityWarning)

        var bangla = SessionOptions()
        bangla.language = .bn
        bangla.modelID = "whisper-large-v2"
        XCTAssertNil(bangla.compatibilityWarning)
    }

    func testNoModelChosenDoesNotWarn() {
        var options = SessionOptions()
        options.language = .bn
        options.modelID = nil
        XCTAssertNil(options.compatibilityWarning)
    }

    // MARK: - resolveModel

    func testResolvesAnExplicitModel() throws {
        var options = SessionOptions()
        options.modelID = "whisper-small.en"
        XCTAssertEqual(try options.resolveModel().id, "whisper-small.en")
    }

    func testUnknownModelThrows() {
        var options = SessionOptions()
        options.modelID = "whisper-nonexistent"
        XCTAssertThrowsError(try options.resolveModel()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("whisper-nonexistent"),
                "the message should name the bad id: \(error.localizedDescription)"
            )
        }
    }

    func testEnglishWithNoModelUsesTheRecommendedOne() throws {
        var options = SessionOptions()
        options.language = .en
        options.modelID = nil
        XCTAssertEqual(try options.resolveModel().id, "whisper-base.en")
    }

    func testNonEnglishWithNoModelUsesTheLanguageDefault() throws {
        var options = SessionOptions()
        options.language = .bn
        options.modelID = nil
        XCTAssertEqual(try options.resolveModel().id, LanguageMode.bn.preferredModelID(current: nil))
    }

    func testResolveMatchesPreferredForEveryLanguage() throws {
        // `resolveModel` delegates to `preferredModelID`; if the two ever drift,
        // the model shown in the session header is not the one that runs.
        for mode in LanguageMode.allCases {
            var options = SessionOptions()
            options.language = mode
            options.modelID = nil
            XCTAssertEqual(
                try options.resolveModel().id,
                mode.preferredModelID(current: nil),
                "\(mode.rawValue) drifted"
            )
        }
    }

    // MARK: - registry

    func testRegistryIdsAreUniqueAndResolvable() {
        let ids = ModelRegistry.shared.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate model ids")
        for id in ids {
            XCTAssertNotNil(ModelRegistry.find(id))
            XCTAssertNotNil(ModelRegistry.find(id)?.whisperKitID, "\(id) needs an engine id")
        }
        XCTAssertNotNil(ModelRegistry.recommended())
    }
}
