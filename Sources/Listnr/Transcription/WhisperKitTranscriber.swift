import Foundation
// @preconcurrency: WhisperKit's pipeline type is not Sendable-annotated, and
// older Swift toolchains (like CI's) flag it crossing into this actor.
@preconcurrency import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?
    private var language: String?
    /// When true (auto mode), Whisper detects the language. Prefer locking via `/lang bn` etc.
    private var detectLanguage: Bool
    /// Which thresholds to decode and judge with, derived from `language`.
    private var script: ScriptClass
    /// Run the `translate` task, so output is English whatever was spoken.
    private let translate: Bool
    /// Segments the confidence gate threw away, tallied so the loss is reportable
    /// instead of invisible.
    private var rejectedSegments = 0
    private var rejectionNotices = 0

    init(
        model: TranscriptionModel,
        language: String? = "en",
        detectLanguage: Bool = false,
        translate: Bool = false
    ) {
        self.modelID = model.id
        self.model = model
        self.language = language
        self.detectLanguage = detectLanguage
        self.script = ScriptClass(languageCode: language)
        self.translate = translate
    }

    func setLanguage(_ code: String?, detect: Bool = false) {
        language = code
        detectLanguage = detect
        script = ScriptClass(languageCode: code)
    }

    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }

        FileHandle.standardError.write(Data("preparing \(model.id)...\n".utf8))

        let printer = DownloadProgressPrinter(label: model.id, expectedMB: model.sizeMB)
        let folder: URL
        do {
            folder = try await WhisperKit.download(variant: whisperKitID) { progress in
                printer.update(progress)
            }
        } catch is CancellationError {
            FileHandle.standardError.write(Data("\n○ download cancelled\n".utf8))
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                FileHandle.standardError.write(Data("\n○ download cancelled\n".utf8))
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        printer.finish(note: "\(model.id) on disk")

        FileHandle.standardError.write(Data("loading \(model.id) into memory (ANE)...\n".utf8))
        let config = WhisperKitConfig(
            model: whisperKitID,
            modelFolder: folder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        pipeline = try await WhisperKit(config)
        try Task.checkCancellation()
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    /// Transcribe one clip. Too short to be speech is rejected here; deciding
    /// whether a clip is *loud enough* is the caller's job.
    ///
    /// This deliberately does **not** apply its own RMS floor. It used to reject
    /// anything below 0.018, which silently overrode callers that had already
    /// made a considered decision: diarized spans admitted at 0.005 were
    /// dropped here and returned as empty text, so quiet remote speakers simply
    /// vanished from the transcript with nothing logged.
    func transcribe(_ audio: [Float]) async throws -> String {
        guard audio.count >= Int(16_000 * 0.35) else { return "" }

        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        // Thresholds are per-script, because Whisper's confidence signals are not
        // comparable across writing systems. See `DecodeTuning`.
        let thresholds = DecodeTuning.decoding(for: script, translating: translate)
        var options = DecodingOptions(
            verbose: false,
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            temperatureIncrementOnFallback: thresholds.temperatureIncrementOnFallback,
            temperatureFallbackCount: thresholds.temperatureFallbackCount,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: detectLanguage && language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: thresholds.compressionRatioThreshold,
            logProbThreshold: thresholds.logProbThreshold,
            firstTokenLogProbThreshold: thresholds.firstTokenLogProbThreshold,
            noSpeechThreshold: thresholds.noSpeechThreshold
        )
        if model.languages == ["en"] {
            options.language = "en"
            options.detectLanguage = false
            // An English-only model has no translation head; asking for one
            // yields nonsense. `SessionOptions.resolveModel` refuses this pairing
            // up front, so this is belt-and-braces.
            options.task = .transcribe
        }

        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        lockDetectedLanguage(from: results)

        // Filter on Whisper's own per-segment confidence rather than on the
        // words it produced. This is the check a string comparison cannot make:
        // when the decoder is guessing at silence it says so here, via a high
        // no-speech probability and a poor average log-probability, whether the
        // guess comes out as "Thank you" or as anything else.
        //
        // The gate is per-script. With the English numbers applied to every
        // language, correct Bangla and Hindi scored as hallucinations and were
        // discarded here, which is why those languages appeared to transcribe
        // nothing at all.
        let gate = DecodeTuning.confidence(for: script, translating: translate)
        let segments = results.flatMap(\.segments)
        let kept = segments.filter { gate.accepts($0) }.map(\.text)

        // No segment metadata at all: fall back to the joined text rather than
        // discarding a real transcription.
        let raw = results.allSatisfy(\.segments.isEmpty)
            ? results.map(\.text).joined(separator: " ")
            : kept.joined(separator: " ")

        reportRejections(total: segments.count, kept: kept.count)

        let cleaned = TranscriptText.clean(raw)
        return TranscriptText.isNonSpeech(cleaned) ? "" : cleaned
    }

    /// In auto mode, take the language Whisper reported and stop re-detecting.
    ///
    /// Per-clip detection is the worst case for both accuracy and speed: it runs
    /// on every segment, and on a one-second utterance it is close to a guess, so
    /// consecutive clips of one continuous conversation get decoded as different
    /// languages. That is the mechanism behind auto mode's gibberish — not a weak
    /// model, a language that changes mid-sentence. One detection per session,
    /// then locked, and the script-specific thresholds follow it.
    private func lockDetectedLanguage(from results: [TranscriptionResult]) {
        guard detectLanguage, language == nil else { return }
        guard let detected = results.first?.language, !detected.isEmpty else { return }

        language = detected
        detectLanguage = false
        script = ScriptClass(languageCode: detected)
        FileHandle.standardError.write(Data(
            "  detected language: \(detected) (locked for this session; /lang \(detected) to set it directly)\n".utf8
        ))
    }

    /// Say so when the gate drops everything.
    ///
    /// Previously this path returned empty text and the lane pipeline skipped it
    /// with `guard !text.isEmpty`, so a mis-calibrated threshold deleted real
    /// speech and left no trace anywhere. Whatever the thresholds are, the loss
    /// should be visible. Capped so a genuinely silent lane cannot flood stderr.
    private func reportRejections(total: Int, kept: Int) {
        guard total > 0, kept == 0 else { return }
        rejectedSegments += total
        guard rejectionNotices < 3 else { return }
        rejectionNotices += 1

        let languageNote = language ?? "auto"
        let note = "! dropped \(total) low-confidence segment(s) [lang=\(languageNote), script=\(script)]. "
            + "If speech is missing, try /model whisper-large-v2\n"
        FileHandle.standardError.write(Data(note.utf8))
    }

    /// Retained as the public name for the acceptance gate; the thresholds now
    /// live in `DecodeTuning` so they can vary per script.
    typealias Confidence = SegmentConfidence
}

extension SegmentConfidence {
    func accepts(_ segment: TranscriptionSegment) -> Bool {
        accepts(
            noSpeechProb: segment.noSpeechProb,
            avgLogProb: segment.avgLogprob,
            compressionRatio: segment.compressionRatio
        )
    }
}
