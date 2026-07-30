import Foundation

struct TranscriptLine: Sendable {
    let speaker: String
    let startSeconds: Double
    let text: String
}

/// Per-lane VAD → Whisper. Lanes stay separate (You vs Others).
actor LaneTranscriber {
    let speakerLabel: String
    private let vad: EnergyVAD
    private let transcriber: WhisperKitTranscriber
    private let minSegmentRMS: Float
    private var lines: [TranscriptLine] = []

    init(
        speakerLabel: String,
        transcriber: WhisperKitTranscriber,
        speechThreshold: Float = 0.015,
        minSegmentRMS: Float = 0.020
    ) {
        self.speakerLabel = speakerLabel
        self.transcriber = transcriber
        self.minSegmentRMS = minSegmentRMS
        self.vad = EnergyVAD(
            speechThreshold: speechThreshold,
            minSpeechSeconds: 0.45,
            hangoverSeconds: 0.60,
            prerollSeconds: 0.45
        )
    }

    func push(_ chunk: [Float]) async {
        let segments = vad.push(chunk)
        for seg in segments {
            await emit(seg)
        }
    }

    func finish() async -> [TranscriptLine] {
        for seg in vad.flush() {
            await emit(seg)
        }
        return lines.sorted { $0.startSeconds < $1.startSeconds }
    }

    var snapshot: [TranscriptLine] { lines }

    private func emit(_ seg: EnergyVAD.Segment) async {
        let rms = AudioMath.rms(seg.samples)
        guard rms >= minSegmentRMS else { return }

        do {
            let text = try await transcriber.transcribe(seg.samples)
            guard !text.isEmpty else { return }
            let line = TranscriptLine(speaker: speakerLabel, startSeconds: seg.startSeconds, text: text)
            lines.append(line)
            let stamp = formatTime(seg.startSeconds)
            FileHandle.standardError.write(Data("[\(stamp)] \(speakerLabel.padding(toLength: 8, withPad: " ", startingAt: 0)) \(text)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("transcription error (\(speakerLabel)): \(error.localizedDescription)\n".utf8))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

enum TranscriptMerger {
    static func merge(_ lanes: [[TranscriptLine]]) -> [TranscriptLine] {
        lanes.flatMap { $0 }.sorted { $0.startSeconds < $1.startSeconds }
    }

    static func printAll(_ lines: [TranscriptLine]) {
        FileHandle.standardError.write(Data("\n—— transcript ——\n".utf8))
        for line in lines {
            let stamp = String(format: "%02d:%02d", Int(line.startSeconds) / 60, Int(line.startSeconds) % 60)
            print("[\(stamp)] \(line.speaker): \(line.text)")
        }
        FileHandle.standardError.write(Data("———————\n".utf8))
    }
}
