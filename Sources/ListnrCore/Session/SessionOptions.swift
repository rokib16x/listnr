import Foundation

enum LanguageMode: String, Codable, CaseIterable {
    case en
    case auto
    case bn
    case hi
    case es
    case fr
    case de
    case ja
    case zh

    var whisperLanguage: String? {
        switch self {
        case .auto: return nil
        default: return rawValue
        }
    }

    /// Which script family this language writes in. Drives the decoding and
    /// acceptance thresholds; see `DecodeTuning` for why they cannot be shared.
    var scriptClass: ScriptClass {
        ScriptClass(languageCode: whisperLanguage)
    }

    /// The default model for this language.
    ///
    /// Every non-English case used to land on the full-precision
    /// `whisper-large-v3-turbo`: 1.5 GB, the slowest option in the registry, and
    /// the one whose distillation cost the most accuracy on exactly the
    /// low-resource languages it was being chosen for. Close to the worst
    /// available pick.
    ///
    /// The defaults below aim at *keeping up with a live conversation*, since a
    /// model too slow for real time has its segments dropped by the lane
    /// pipeline's bounded queue and simply loses speech. Anyone who would rather
    /// spend the time can move up the ladder with `/model whisper-large-v2`.
    func preferredModelID(current: String?, translating: Bool = false) -> String {
        if translating {
            // None of the per-language fast defaults apply: they are turbo builds,
            // which return the original language instead of translating. Keep an
            // already-capable choice, otherwise take the translation default.
            if let current, ModelRegistry.find(current)?.supportsTranslation == true {
                return current
            }
            return ModelRegistry.defaultTranslationModelID
        }
        switch self {
        case .en:
            if let current, current.hasSuffix(".en") { return current }
            return "whisper-base.en"
        case .es, .fr, .de:
            // Well-resourced Latin-script languages; medium is plenty and is
            // several times faster than any large variant.
            return "whisper-medium"
        case .bn, .hi, .ja, .zh, .auto:
            // Quantized turbo: same weights as the old default at ~40% of the
            // size, so it loads faster and decodes fast enough to stay live.
            return "whisper-large-v3-turbo-fast"
        }
    }

    static func parse(_ raw: String) -> LanguageMode? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "multi" { return .auto }
        return LanguageMode(rawValue: s)
    }
}

struct SessionOptions {
    var language: LanguageMode = .en
    var remoteSpeakers: Int = 2
    var modelID: String?
    var dumpWav: Bool = false
    var transcribe: Bool = true
    var diarize: Bool = true
    /// Run Whisper's `translate` task instead of `transcribe`, so speech in any
    /// supported language comes out as English. Whisper only translates *into*
    /// English; there is no other target.
    var translate: Bool = false
    /// How loud speech must be before it is treated as speech. Raise this when
    /// a quiet microphone leaves gaps in the transcript.
    var sensitivity: MicSensitivity = .normal
    /// nil = run until stop
    var seconds: Double? = nil
    /// One line of key hints shown when the session goes live; set by the
    /// caller because shell and one-shot mode stop differently.
    var controlsHint: String?

    mutating func applyLanguage(_ mode: LanguageMode) {
        language = mode
        modelID = mode.preferredModelID(current: modelID, translating: translate)
    }

    /// Turn translation on or off, re-deriving the model.
    ///
    /// Re-deriving is not optional. The transcription defaults for most languages
    /// are turbo builds that cannot translate, so flipping the flag alone would
    /// leave a model that silently ignores the request.
    mutating func applyTranslate(_ enabled: Bool) {
        translate = enabled
        modelID = language.preferredModelID(current: modelID, translating: enabled)
    }

    func resolveModel() throws -> TranscriptionModel {
        if let id = modelID {
            guard let model = ModelRegistry.find(id) else {
                throw SessionOptionsError.unknownModel(id)
            }
            // Refuse rather than warn. A model that cannot translate does not
            // fail when asked to — it returns the original language, so the
            // session would run to completion and hand back an hour of Bangla
            // when English was asked for. There is no recovering that.
            guard !translate || model.supportsTranslation else {
                throw SessionOptionsError.cannotTranslate(id)
            }
            return model
        }

        // Delegate rather than repeat the mapping: `preferredModelID` is the one
        // place the language → model decision is made.
        let preferredID = language.preferredModelID(current: nil)
        if translate, ModelRegistry.find(preferredID)?.supportsTranslation != true {
            // The transcription default for this language cannot translate, so
            // fall to the translation default instead of silently transcribing.
            if let translator = ModelRegistry.find(ModelRegistry.defaultTranslationModelID) {
                return translator
            }
        }
        if let preferred = ModelRegistry.find(preferredID) {
            return preferred
        }
        return ModelRegistry.recommended() ?? ModelRegistry.shared[0]
    }

    /// A warning to show the user when the chosen model cannot serve the chosen
    /// language, or nil when the pair is fine.
    ///
    /// This combination used to fail in silence, and in the most confusing way
    /// available: an English-only model with `/lang bn` set does not error, it
    /// transcribes Bangla speech *into English words*, because the transcriber
    /// pins `language = "en"` for those models. The output looks like a bad
    /// transcript rather than a misconfiguration.
    var compatibilityWarning: String? {
        // Translating English into English is a no-op, and costs a much larger
        // model to achieve nothing.
        if translate, language == .en {
            return "translation is pointless with /lang en — Whisper only translates into English. "
                + "Set the language you actually speak, or turn /translate off."
        }

        guard let id = modelID, let model = ModelRegistry.find(id) else { return nil }
        let englishOnly = model.languages == ["en"]

        if translate, !model.supportsTranslation {
            return "\(id) cannot translate; it returns the original language instead. "
                + "Use /model \(ModelRegistry.defaultTranslationModelID) (or whisper-small for a lighter one)."
        }
        if englishOnly, language != .en {
            return "\(id) is English-only, so /lang \(language.rawValue) will be transcribed as English. "
                + "Use /model whisper-large-v3-turbo-fast (or whisper-large-v2) instead."
        }
        if !englishOnly, language == .en {
            return "\(id) is multilingual; for English, whisper-base.en is smaller, faster, and more accurate."
        }
        return nil
    }
}

enum SessionOptionsError: Error, LocalizedError {
    case unknownModel(String)
    case cannotTranslate(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let id):
            return "unknown model: \(id)"
        case .cannotTranslate(let id):
            let alternatives = ModelRegistry.translationCapable()
                .map { "\($0.id) (\($0.sizeMB) MB)" }
                .joined(separator: ", ")
            return "\(id) cannot translate to English — it returns the original language instead. "
                + "Translation-capable models: \(alternatives)"
        }
    }
}
