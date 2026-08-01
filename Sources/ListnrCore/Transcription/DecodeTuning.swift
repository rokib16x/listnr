import Foundation

/// The writing system a language uses, as far as Whisper's confidence signals
/// are concerned.
///
/// This exists because those signals are **not comparable across scripts**, and
/// treating them as if they were is what made `/lang bn` and `/lang hi` look
/// broken while `/lang en` looked perfect:
///
/// - `avgLogProb` is an average over *tokens*. Whisper's BPE vocabulary is
///   English-centric, so Bengali and Devanagari fall back to byte-level pieces
///   and cost several times more tokens per word, each individually less
///   confident. Correct Bangla routinely averages around −1.2, which is well
///   below the −0.9 that means "probably a hallucination" in English.
/// - `compressionRatio` is the text's length over its compressed length. Indic
///   and Han text is three bytes per character drawn from a small repertoire, so
///   it compresses far better than English *before* any repetition exists. An
///   ordinary Bangla sentence lands near 3.0, past the 2.6 that flags a
///   degenerate loop in English.
///
/// So the same numbers that correctly reject English silence-hallucinations
/// reject real speech in every other script. The thresholds are keyed on script
/// instead.
enum ScriptClass: Sendable, Equatable {
    case latin
    /// Indic abugidas: Bengali, Devanagari, Tamil, Telugu, and relatives.
    case indic
    /// Han, Kana, and Hangul: no word spacing, few characters per word.
    case cjk
    /// Not yet known (`/lang auto` before its first detection) or not one of the
    /// families above. Takes the widest gate, because the failure mode of
    /// guessing narrow is silently dropping a whole language.
    case unknown

    private static let latinCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "no", "nb", "nn",
        "fi", "pl", "cs", "sk", "sl", "hr", "hu", "ro", "tr", "id", "ms", "vi",
        "ca", "gl", "af", "sw", "tl", "et", "lv", "lt", "cy", "is", "eu", "la",
    ]

    private static let indicCodes: Set<String> = [
        "bn", "hi", "ta", "te", "mr", "gu", "pa", "ne", "kn", "ml", "si",
        "as", "or", "sa", "mai", "bh",
    ]

    private static let cjkCodes: Set<String> = ["ja", "zh", "ko", "yue"]

    /// Classify a Whisper language code. Accepts the tagged forms that come back
    /// from language detection too (`zh-Hans`, `en_US`).
    init(languageCode: String?) {
        guard let languageCode else {
            self = .unknown
            return
        }
        let base = languageCode
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""

        if Self.latinCodes.contains(base) { self = .latin }
        else if Self.indicCodes.contains(base) { self = .indic }
        else if Self.cjkCodes.contains(base) { self = .cjk }
        else { self = .unknown }
    }
}

/// The decoder-side fallback triggers for one script.
///
/// These are WhisperKit's own thresholds, which decide when it re-decodes a
/// window at a higher temperature instead of keeping what it has. Kept as plain
/// `Float`s in a WhisperKit-free type so the relationship between them and the
/// acceptance gate can be tested directly.
struct DecodeThresholds: Sendable {
    var compressionRatioThreshold: Float
    var logProbThreshold: Float
    var firstTokenLogProbThreshold: Float
    var noSpeechThreshold: Float
    /// How many times to re-decode at a raised temperature before giving up.
    ///
    /// This is the *only* mechanism that turns a hallucinated window into a real
    /// one, so scripts that trip the checks more often need more of them. It is
    /// also not free: each fallback is another full decode. Raising the
    /// thresholds above and the retry count together is deliberate — the
    /// relaxed thresholds mean fewer windows fail at all, which buys back the
    /// time the extra retries cost.
    var temperatureFallbackCount: Int
    var temperatureIncrementOnFallback: Float
}

/// Per-script decoding and acceptance settings.
///
/// The invariant worth stating, because it is easy to break: the decoder's
/// thresholds must be **at least as permissive** as the acceptance gate. If the
/// decoder discards a candidate the gate would have accepted, relaxing the gate
/// cannot recover it — the text is already gone. `DecodeTuningTests` enforces it.
enum DecodeTuning {

    /// Decoder-side thresholds, matching `confidence(for:translating:)`: the
    /// compression trigger follows the output text, everything else the input.
    static func decoding(for script: ScriptClass, translating: Bool = false) -> DecodeThresholds {
        var thresholds = baseDecoding(for: script)
        if translating {
            thresholds.compressionRatioThreshold = baseDecoding(for: .latin).compressionRatioThreshold
        }
        return thresholds
    }

    /// Latin numbers are the shipped ones, unchanged on purpose: English works
    /// today, and this change must not move it.
    private static func baseDecoding(for script: ScriptClass) -> DecodeThresholds {
        switch script {
        case .latin:
            return DecodeThresholds(
                compressionRatioThreshold: 2.2,
                logProbThreshold: -0.8,
                firstTokenLogProbThreshold: -1.2,
                noSpeechThreshold: 0.45,
                temperatureFallbackCount: 1,
                temperatureIncrementOnFallback: 0.2
            )
        case .cjk:
            return DecodeThresholds(
                compressionRatioThreshold: 3.4,
                logProbThreshold: -1.2,
                firstTokenLogProbThreshold: -1.8,
                noSpeechThreshold: 0.6,
                temperatureFallbackCount: 3,
                temperatureIncrementOnFallback: 0.2
            )
        case .indic, .unknown:
            return DecodeThresholds(
                compressionRatioThreshold: 4.0,
                logProbThreshold: -1.5,
                firstTokenLogProbThreshold: -2.0,
                noSpeechThreshold: 0.6,
                temperatureFallbackCount: 3,
                temperatureIncrementOnFallback: 0.2
            )
        }
    }

    /// The acceptance gate for one script, optionally translating to English.
    ///
    /// Translation splits the two signals apart, because they measure different
    /// things:
    ///
    /// - `compressionRatio` is measured on the **output** text, which in
    ///   translate mode is English. The relaxed Indic and CJK ceilings exist
    ///   because those *scripts* compress well; English output does not, so
    ///   keeping a relaxed ceiling here would admit repetition loops for free.
    ///   It reverts to the Latin ceiling.
    /// - `avgLogProb` and `noSpeechProb` describe how hard the **input** audio
    ///   and task were, and translating out of a low-resource language is if
    ///   anything harder than transcribing it. Those keep the input script's
    ///   floors.
    static func confidence(for script: ScriptClass, translating: Bool = false) -> SegmentConfidence {
        var gate = baseConfidence(for: script)
        if translating {
            gate.maxCompressionRatio = baseConfidence(for: .latin).maxCompressionRatio
        }
        return gate
    }

    private static func baseConfidence(for script: ScriptClass) -> SegmentConfidence {
        switch script {
        case .latin:
            return SegmentConfidence(
                maxNoSpeechProb: 0.7,
                minAvgLogProb: -0.9,
                maxCompressionRatio: 2.6
            )
        case .cjk:
            return SegmentConfidence(
                maxNoSpeechProb: 0.8,
                minAvgLogProb: -1.3,
                maxCompressionRatio: 3.6
            )
        case .indic, .unknown:
            return SegmentConfidence(
                maxNoSpeechProb: 0.8,
                minAvgLogProb: -1.6,
                maxCompressionRatio: 4.2
            )
        }
    }
}

/// Thresholds for accepting one decoded segment.
///
/// The no-speech and log-probability tests are combined with AND, matching the
/// reference Whisper implementation: either signal alone fires often enough on
/// quiet or accented speech that OR would cut real content. Degenerate
/// repetition is an independent signal, so the compression ratio stands on its
/// own — and it stays bounded on every script, because the relaxed non-Latin
/// gates would otherwise trade missing text for gibberish.
struct SegmentConfidence: Sendable {
    var maxNoSpeechProb: Float = 0.7
    var minAvgLogProb: Float = -0.9
    var maxCompressionRatio: Float = 2.6

    func accepts(noSpeechProb: Float, avgLogProb: Float, compressionRatio: Float) -> Bool {
        if compressionRatio > maxCompressionRatio { return false }
        if noSpeechProb > maxNoSpeechProb && avgLogProb < minAvgLogProb { return false }
        return true
    }
}
