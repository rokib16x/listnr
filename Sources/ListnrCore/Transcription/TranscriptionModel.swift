import Foundation

enum Engine: String, Codable {
    case whisperKit
}

struct TranscriptionModel: Codable {
    let id: String
    let displayName: String
    let engine: Engine
    let whisperKitID: String?
    let sizeMB: Int
    let languages: [String]
    let recommended: Bool
    /// Whether this model can run Whisper's `translate` task (any language →
    /// English).
    ///
    /// Not a formality. The `large-v3-turbo` builds were fine-tuned for
    /// transcription only, and OpenAI is explicit that they "return the original
    /// language even if `--task translate` is specified" — no error, just the
    /// wrong language. English-only models cannot translate either. Recording the
    /// capability lets the mismatch be refused up front instead of discovered at
    /// the end of a meeting.
    let supportsTranslation: Bool
}

/// The models Listnr can run, all from `argmaxinc/whisperkit-coreml`.
///
/// Sizes are the measured on-disk totals of each variant's folder, not the
/// nominal parameter count, because that is what `DownloadProgressPrinter`
/// reports and what the user waits for.
///
/// Two things shape this list. First, **English is a solved problem here and the
/// rest are not**: `whisper-base.en` is small, fast, and accurate, so the
/// English entries are a short ladder. Non-English needs a real range, because
/// the right point on the speed/accuracy curve depends on the language and on
/// the machine.
///
/// Second, **several of these are quantized**, and for real-time meeting
/// transcription that is close to free. A quantized large model that keeps up
/// with the conversation beats an unquantized one whose segments get dropped by
/// the lane pipeline's bounded queue; a transcript missing every third utterance
/// is worse than a slightly less precise complete one.
enum ModelRegistry {
    static let shared: [TranscriptionModel] = [
        // MARK: English-only

        TranscriptionModel(
            id: "whisper-base.en",
            displayName: "Whisper Base (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base.en",
            sizeMB: 139,
            languages: ["en"],
            recommended: true,
            supportsTranslation: false
        ),
        TranscriptionModel(
            id: "whisper-small.en",
            displayName: "Whisper Small (English)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small.en",
            sizeMB: 463,
            languages: ["en"],
            recommended: false,
            supportsTranslation: false
        ),

        // MARK: Multilingual

        TranscriptionModel(
            id: "whisper-tiny",
            displayName: "Whisper Tiny (multilingual, fastest)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-tiny",
            sizeMB: 73,
            languages: ["multi"],
            recommended: false,
            supportsTranslation: true
        ),
        TranscriptionModel(
            id: "whisper-base",
            displayName: "Whisper Base (multilingual)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-base",
            sizeMB: 139,
            languages: ["multi"],
            recommended: false,
            supportsTranslation: true
        ),
        TranscriptionModel(
            id: "whisper-small",
            displayName: "Whisper Small (multilingual, quantized)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-small_216MB",
            sizeMB: 207,
            languages: ["multi"],
            recommended: false,
            supportsTranslation: true
        ),
        TranscriptionModel(
            id: "whisper-medium",
            displayName: "Whisper Medium (multilingual)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-medium",
            sizeMB: 1458,
            languages: ["multi"],
            recommended: false,
            supportsTranslation: true
        ),
        // Large v2 rather than v3 on purpose. v3-turbo is distilled down to four
        // decoder layers from thirty-two, and that loss falls hardest on the
        // languages with the least training data behind them. For Bangla and
        // Hindi in particular, v2 is the more reliable of the two.
        TranscriptionModel(
            id: "whisper-large-v2",
            displayName: "Whisper Large v2 (multilingual, quantized, most accurate)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v2_949MB",
            sizeMB: 908,
            languages: ["multi"],
            recommended: false,
            supportsTranslation: true
        ),
        // Same weights as `whisper-large-v3-turbo`, quantized. Roughly a third
        // of the download and materially faster to load and decode, which is why
        // this is what the non-English defaults point at.
        TranscriptionModel(
            id: "whisper-large-v3-turbo-fast",
            displayName: "Whisper Large v3 Turbo (quantized)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo_632MB",
            sizeMB: 615,
            languages: ["multi"],
            recommended: false,
            supportsTranslation: false
        ),
        TranscriptionModel(
            id: "whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo (full precision)",
            engine: .whisperKit,
            whisperKitID: "openai_whisper-large-v3-v20240930_turbo",
            sizeMB: 1562,
            languages: ["multi"],
            recommended: false,
            supportsTranslation: false
        ),
    ]

    static func find(_ id: String) -> TranscriptionModel? {
        shared.first { $0.id == id }
    }

    static func recommended() -> TranscriptionModel? {
        shared.first { $0.recommended } ?? shared.first
    }

    /// Models that can transcribe something other than English.
    static func multilingual() -> [TranscriptionModel] {
        shared.filter { $0.languages != ["en"] }
    }

    /// Models that can translate into English, cheapest first.
    static func translationCapable() -> [TranscriptionModel] {
        shared.filter(\.supportsTranslation).sorted { $0.sizeMB < $1.sizeMB }
    }

    /// The default when translating.
    ///
    /// Quality over size on purpose, unlike the transcription defaults.
    /// Translation is a harder task than transcription and degrades faster as
    /// models shrink, so a small model here produces output too rough to act on
    /// — and `whisper-large-v2` is still *lighter* than `whisper-medium` while
    /// being better at it. `whisper-small` remains available for anyone who needs
    /// the 207 MB footprint more than the accuracy.
    static let defaultTranslationModelID = "whisper-large-v2"
}
