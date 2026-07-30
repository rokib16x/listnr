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

    /// Prefer multilingual turbo for non-English / auto; English models for `en`.
    func preferredModelID(current: String?) -> String {
        switch self {
        case .en:
            if let current, current.hasSuffix(".en") { return current }
            return "whisper-base.en"
        case .auto, .bn, .hi, .es, .fr, .de, .ja, .zh:
            return "whisper-large-v3-turbo"
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
    /// nil = run until stop
    var seconds: Double? = nil

    mutating func applyLanguage(_ mode: LanguageMode) {
        language = mode
        modelID = mode.preferredModelID(current: modelID)
    }

    func resolveModel() throws -> TranscriptionModel {
        if let id = modelID {
            guard let m = ModelRegistry.find(id) else {
                throw SessionOptionsError.unknownModel(id)
            }
            return m
        }
        if language == .en {
            return ModelRegistry.recommended() ?? ModelRegistry.shared[0]
        }
        guard let turbo = ModelRegistry.find("whisper-large-v3-turbo") else {
            return ModelRegistry.recommended() ?? ModelRegistry.shared[0]
        }
        return turbo
    }
}

enum SessionOptionsError: Error, LocalizedError {
    case unknownModel(String)
    var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "unknown model: \(id)"
        }
    }
}
