import Foundation

/// How loud speech has to be before Listnr treats it as speech.
///
/// The detection thresholds are absolute RMS values, and microphone levels vary
/// by more than an order of magnitude across hardware and gain settings. A
/// built-in MacBook microphone at default input volume can peak around 0.017
/// while someone is speaking normally — below the 0.018 floor that decides
/// whether a segment is worth transcribing at all. The result is a transcript
/// with minutes missing from the middle and no obvious cause, because the audio
/// never reached Whisper.
///
/// Scaling every threshold by one factor keeps their relationship to each other
/// intact — the system lane stays stricter than the microphone lane, and the
/// segment floor stays above the speech threshold — while moving the whole set
/// to where a given microphone actually sits.
enum MicSensitivity: String, CaseIterable, Sendable {
    /// Quiet microphone, soft speaker, or a mic placed far away.
    case high
    case normal
    /// Hot microphone or a noisy room, where `normal` picks up keyboard and fans.
    case low

    /// Multiplier applied to every threshold. Lower means more is heard.
    var multiplier: Float {
        switch self {
        case .high: return 0.5
        case .normal: return 1.0
        case .low: return 1.6
        }
    }

    var summary: String {
        switch self {
        case .high: return "high (quiet mic, hears more)"
        case .normal: return "normal"
        case .low: return "low (hot mic or noisy room, hears less)"
        }
    }

    static func parse(_ raw: String) -> MicSensitivity? {
        MicSensitivity(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// The speech-detection thresholds for one lane.
struct LaneThresholds: Sendable {
    /// Frame RMS above which the segmenter considers a frame voiced.
    let speechThreshold: Float
    /// Whole-segment RMS below which a finished utterance is discarded.
    let minSegmentRMS: Float
}

/// Base thresholds at `.normal`, and how they scale.
///
/// The system lane is stricter than the microphone lane on purpose: silence
/// there was making Whisper hallucinate "Thank you".
enum LaneTuning {
    static let youBase = LaneThresholds(speechThreshold: 0.014, minSegmentRMS: 0.018)
    static let othersBase = LaneThresholds(speechThreshold: 0.022, minSegmentRMS: 0.025)

    static func you(_ sensitivity: MicSensitivity) -> LaneThresholds {
        scale(youBase, by: sensitivity)
    }

    static func others(_ sensitivity: MicSensitivity) -> LaneThresholds {
        scale(othersBase, by: sensitivity)
    }

    private static func scale(_ base: LaneThresholds, by sensitivity: MicSensitivity) -> LaneThresholds {
        LaneThresholds(
            speechThreshold: base.speechThreshold * sensitivity.multiplier,
            minSegmentRMS: base.minSegmentRMS * sensitivity.multiplier
        )
    }
}
