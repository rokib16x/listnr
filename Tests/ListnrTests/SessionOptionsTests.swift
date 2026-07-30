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

    func testNonEnglishAlwaysWantsTurbo() {
        for mode in [LanguageMode.auto, .bn, .hi, .es, .fr, .de, .ja, .zh] {
            XCTAssertEqual(
                mode.preferredModelID(current: "whisper-base.en"),
                "whisper-large-v3-turbo",
                "\(mode.rawValue) needs the multilingual model"
            )
        }
    }

    func testApplyLanguageUpdatesBothFields() {
        var options = SessionOptions()
        options.applyLanguage(.bn)
        XCTAssertEqual(options.language, .bn)
        XCTAssertEqual(options.modelID, "whisper-large-v3-turbo")
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

    func testNonEnglishWithNoModelUsesTurbo() throws {
        var options = SessionOptions()
        options.language = .bn
        options.modelID = nil
        XCTAssertEqual(try options.resolveModel().id, "whisper-large-v3-turbo")
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
