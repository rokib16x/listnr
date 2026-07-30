import Foundation
import WhisperKit

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

        FileHandle.standardError.write(Data("preparing \(model.id)…\n".utf8))

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

        FileHandle.standardError.write(Data("loading \(model.id) into memory (ANE)…\n".utf8))
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

    func transcribe(_ audio: [Float]) async throws -> String {
        // Reject near-silence before Whisper (stops “Thank you” hallucinations).
        let rms = AudioMath.rms(audio)
        guard rms >= 0.018, audio.count >= Int(16_000 * 0.35) else { return "" }

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
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,
            #"\([^)]*\)"#,
            #"<\|[^|]*\|>"#,
            #"\*[^*]*\*"#,
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        // Strip stray numeric junk like "Thank you.000"
        out = out.replacingOccurrences(of: #"\.\d{2,}"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        if isHallucination(out) { return "" }
        return out
    }

    /// Common Whisper silence / junk outputs.
    static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,…"))
        let banned: Set<String> = [
            "thank you",
            "thanks",
            "thanks for watching",
            "thank you for watching",
            "please subscribe",
            "subscribe",
            "you",
            "the",
            "a",
            "uh",
            "um",
            "hmm",
            "okay",
            "ok",
            "bye",
            "goodbye",
            "music",
            "applause",
            "silence",
            "blank audio",
            ".",
            "",
        ]
        if banned.contains(t) { return true }
        // Very short English-only stubs when we expect speech
        if t.count <= 2 { return true }
        return false
    }
}
