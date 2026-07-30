import Foundation
// @preconcurrency: WhisperKit's pipeline type is not Sendable-annotated, and
// older Swift toolchains (like CI's) flag it crossing into this actor.
@preconcurrency import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?
    private var language: String?
    /// When true (auto mode), Whisper detects language per clip. Prefer locking via `/lang bn` etc.
    private var detectLanguage: Bool

    init(model: TranscriptionModel, language: String? = "en", detectLanguage: Bool = false) {
        self.modelID = model.id
        self.model = model
        self.language = language
        self.detectLanguage = detectLanguage
    }

    func setLanguage(_ code: String?, detect: Bool = false) {
        language = code
        detectLanguage = detect
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

        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: detectLanguage && language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.2,
            logProbThreshold: -0.8,
            firstTokenLogProbThreshold: -1.2,
            noSpeechThreshold: 0.45
        )
        if model.languages == ["en"] {
            options.language = "en"
            options.detectLanguage = false
        }

        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)

        // Filter on Whisper's own per-segment confidence rather than on the
        // words it produced. This is the check a string comparison cannot make:
        // when the decoder is guessing at silence it says so here, via a high
        // no-speech probability and a poor average log-probability, whether the
        // guess comes out as "Thank you" or as anything else.
        let kept = results
            .flatMap(\.segments)
            .filter { Self.confidence.accepts($0) }
            .map(\.text)

        // No segment metadata at all: fall back to the joined text rather than
        // discarding a real transcription.
        let raw = results.allSatisfy(\.segments.isEmpty)
            ? results.map(\.text).joined(separator: " ")
            : kept.joined(separator: " ")

        let cleaned = TranscriptText.clean(raw)
        return TranscriptText.isNonSpeech(cleaned) ? "" : cleaned
    }

    /// Thresholds for accepting a decoded segment.
    ///
    /// The no-speech and log-probability tests are combined with AND, matching
    /// the reference Whisper implementation: either signal alone fires often
    /// enough on quiet or accented speech that OR would cut real content.
    /// Degenerate repetition is an independent signal, so the compression ratio
    /// stands on its own.
    struct Confidence {
        var maxNoSpeechProb: Float = 0.7
        var minAvgLogProb: Float = -0.9
        var maxCompressionRatio: Float = 2.6

        func accepts(noSpeechProb: Float, avgLogProb: Float, compressionRatio: Float) -> Bool {
            if compressionRatio > maxCompressionRatio { return false }
            if noSpeechProb > maxNoSpeechProb && avgLogProb < minAvgLogProb { return false }
            return true
        }

        func accepts(_ segment: TranscriptionSegment) -> Bool {
            accepts(
                noSpeechProb: segment.noSpeechProb,
                avgLogProb: segment.avgLogprob,
                compressionRatio: segment.compressionRatio
            )
        }
    }

    static let confidence = Confidence()
}
