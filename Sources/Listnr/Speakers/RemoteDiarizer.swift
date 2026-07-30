import Foundation
import SpeakerKit
import ArgmaxCore

/// Wraps SpeakerKit for Lane B (remote speakers on system audio).
actor RemoteDiarizer {
    private var kit: SpeakerKit?
    private let speakerHint: Int?

    init(speakerHint: Int? = 2) {
        self.speakerHint = speakerHint
    }

    func warmUp() async throws {
        if kit != nil { return }
        FileHandle.standardError.write(Data("preparing SpeakerKit (diarization)…\n".utf8))
        let config = PyannoteConfig(download: false, load: false, verbose: false)
        let speakerKit = try await SpeakerKit(config)

        let printer = DownloadProgressPrinter(label: "SpeakerKit", expectedMB: 150)
        if let manager = speakerKit.diarizer as? ModelManager {
            try await manager.downloadModels { progress in
                printer.update(progress)
            }
            try await manager.loadModels()
        } else {
            try await speakerKit.ensureModelsLoaded()
        }
        printer.finish(note: "SpeakerKit ready")
        kit = speakerKit
    }

    /// Diarize system-audio PCM @ 16 kHz. Returns time ranges labeled Speaker 1..N.
    func diarize(_ audio: [Float]) async throws -> [DiarizedSpan] {
        if kit == nil { try await warmUp() }
        guard let kit else { return [] }

        guard audio.count > Int(16_000 * 0.5) else { return [] }

        let options = PyannoteDiarizationOptions(numberOfSpeakers: speakerHint)
        let result = try await kit.diarize(audioArray: audio, options: options)

        var spans: [DiarizedSpan] = []
        for segment in result.segments {
            let duration = segment.endTime - segment.startTime
            guard duration >= 0.35 else { continue }
            let rawId = segment.speaker.speakerId ?? 0
            // Map 0-based ids to Speaker 1..N for humans.
            let label = "Speaker \(rawId + 1)"
            spans.append(
                DiarizedSpan(
                    label: label,
                    startSeconds: Double(segment.startTime),
                    endSeconds: Double(segment.endTime)
                )
            )
        }
        return spans.sorted { $0.startSeconds < $1.startSeconds }
    }
}

struct DiarizedSpan: Sendable {
    let label: String
    let startSeconds: Double
    let endSeconds: Double
}

enum SpeakerMap {
    /// Stable display names; user can rename later.
    static func displayName(for label: String, renames: [String: String] = [:]) -> String {
        renames[label] ?? label
    }
}

enum DiarizedTranscriber {
    /// Cut Lane B audio by diarization spans and transcribe each → multi-speaker lines.
    /// Pads each span slightly so diarization boundaries do not clip the first word.
    static func transcribeSpans(
        audio: [Float],
        sampleRate: Double = 16_000,
        spans: [DiarizedSpan],
        transcriber: WhisperKitTranscriber,
        padBeforeSeconds: Double = 0.35,
        padAfterSeconds: Double = 0.20
    ) async -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        let padBefore = Int(padBeforeSeconds * sampleRate)
        let padAfter = Int(padAfterSeconds * sampleRate)

        for span in spans {
            let rawStart = Int(span.startSeconds * sampleRate)
            let rawEnd = Int(span.endSeconds * sampleRate)
            let start = max(0, rawStart - padBefore)
            let end = min(audio.count, rawEnd + padAfter)
            guard end > start else { continue }
            let slice = Array(audio[start..<end])
            guard AudioMath.rms(slice) >= 0.005 else { continue }
            do {
                let text = try await transcriber.transcribe(slice)
                guard !text.isEmpty else { continue }
                let line = TranscriptLine(speaker: span.label, startSeconds: span.startSeconds, text: text)
                lines.append(line)
                let stamp = String(format: "%02d:%02d", Int(span.startSeconds) / 60, Int(span.startSeconds) % 60)
                FileHandle.standardError.write(Data("[\(stamp)] \(span.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(text)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("diarized STT error: \(error.localizedDescription)\n".utf8))
            }
        }
        return lines
    }
}
