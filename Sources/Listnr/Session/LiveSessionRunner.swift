import Foundation

/// Runs one dual-lane listening session (timed or until `requestStop()` / Task cancel).
final class LiveSessionRunner {
    struct Outcome {
        let lines: [TranscriptLine]
        let result: DualCaptureSession.Result
        let savedPath: String?
    }

    private let options: SessionOptions
    private var stopRequested = false
    private let stopLock = NSLock()
    private var runningTask: Task<Void, Never>?

    init(options: SessionOptions) {
        self.options = options
    }

    /// Stop capture loop **and** cancel in-flight model download / load.
    func requestStop() {
        stopLock.lock()
        stopRequested = true
        let task = runningTask
        stopLock.unlock()
        task?.cancel()
    }

    private var shouldStop: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested || Task.isCancelled
    }

    /// Pump the main run loop while the async session runs (needed for SCK / AVAudio).
    func runBlocking() throws -> Outcome {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Outcome?
        var error: Error?

        let task = Task {
            do {
                try Task.checkCancellation()
                outcome = try await run()
            } catch is CancellationError {
                error = CancellationError()
                FileHandle.standardError.write(Data("\n○ cancelled\n".utf8))
            } catch let caught {
                if shouldStop || Task.isCancelled {
                    error = CancellationError()
                    FileHandle.standardError.write(Data("\n○ cancelled\n".utf8))
                } else {
                    error = caught
                }
            }
            sem.signal()
        }

        stopLock.lock()
        runningTask = task
        stopLock.unlock()

        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        stopLock.lock()
        runningTask = nil
        stopLock.unlock()

        if let error {
            if error is CancellationError {
                throw LiveSessionError.cancelled
            }
            throw error
        }
        guard let outcome else {
            throw shouldStop ? LiveSessionError.cancelled : LiveSessionError.noResult
        }
        return outcome
    }

    func run() async throws -> Outcome {
        try Task.checkCancellation()
        if shouldStop { throw CancellationError() }

        let model = try options.resolveModel()
        let langCode = options.language.whisperLanguage

        var youLane: LaneTranscriber?
        var othersLane: LaneTranscriber?
        var sharedTranscriber: WhisperKitTranscriber?

        if options.transcribe {
            let t = WhisperKitTranscriber(
                model: model,
                language: langCode,
                detectLanguage: options.language == .auto
            )
            sharedTranscriber = t
            try await t.warmUp()
            try Task.checkCancellation()
            if shouldStop { throw CancellationError() }
            // Stricter thresholds on system lane — silence there was hallucinating “Thank you”.
            youLane = LaneTranscriber(speakerLabel: "You", transcriber: t, speechThreshold: 0.014, minSegmentRMS: 0.018)
            othersLane = LaneTranscriber(speakerLabel: "Others", transcriber: t, speechThreshold: 0.022, minSegmentRMS: 0.025)
        }

        let durationLabel = options.seconds.map { String(format: "%.0fs", $0) } ?? "until stop"
        let langNote: String = {
            switch options.language {
            case .auto: return "auto-detect (for Bangla/Hindi prefer /lang bn or /lang hi)"
            default: return options.language.rawValue
            }
        }()
        FileHandle.standardError.write(Data(
            "● live · \(durationLabel) · model=\(model.id) · lang=\(langNote) · speakers≈\(options.remoteSpeakers)\n".utf8
        ))
        FileHandle.standardError.write(Data(
            "  /stop or q + Enter to finish · Ctrl+C cancels\n\n".utf8
        ))

        // Small pause so Core Audio settles after heavy ANE model load.
        try await Task.sleep(nanoseconds: 300_000_000)

        let session = DualCaptureSession()
        var lastMic: Float = 0
        var lastSys: Float = 0
        var micSeen = false
        session.onMicLevel = { level in
            lastMic = level
            if level > 0.001 { micSeen = true }
        }
        session.onSystemLevel = { lastSys = $0 }

        if let youLane {
            session.onMicSamples = { chunk in
                Task { await youLane.push(chunk) }
            }
        }
        if let othersLane {
            session.onSystemSamples = { chunk in
                Task { await othersLane.push(chunk) }
            }
        }

        let meter = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        var meterTicks = 0
        meter.schedule(deadline: .now() + 0.5, repeating: 0.5)
        meter.setEventHandler {
            meterTicks += 1
            let line = String(format: "  levels  mic=%.3f  sys=%.3f\u{001B}[K\r", lastMic, lastSys)
            FileHandle.standardError.write(Data(line.utf8))
            if meterTicks == 6, !micSeen {
                FileHandle.standardError.write(Data(
                    "\n! mic still silent — check System Settings → Sound → Input, and speak louder\n".utf8
                ))
            }
        }
        meter.resume()

        // Start system audio first, then mic (more reliable after SCK permission / ANE load).
        do {
            try await session.startSystemThenMic()
        } catch {
            // Fallback to original order.
            try await session.start()
        }

        let deadline: Date? = options.seconds.map { Date().addingTimeInterval($0) }
        while !shouldStop {
            try Task.checkCancellation()
            if let deadline, Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        meter.cancel()
        FileHandle.standardError.write(Data("\n".utf8))

        if Task.isCancelled && options.seconds == nil {
            // Still finalize whatever we have if user stopped mid-session after capture started.
        }

        let result = await session.stop()

        // Cancelled during download/warmup before useful audio — bail without report.
        if Task.isCancelled, result.durationSeconds < 0.5, result.mic.count < 8_000 {
            throw CancellationError()
        }

        let micSec = Double(result.mic.count) / MicCapture.targetSampleRate
        let sysSec = Double(result.system.count) / SystemAudioCapture.targetSampleRate
        FileHandle.standardError.write(Data(
            String(
                format: "○ captured  wall=%.1fs  mic=%.1fs  sys=%.1fs\n",
                result.durationSeconds, micSec, sysSec
            ).utf8
        ))

        if options.dumpWav {
            do {
                try WAVWriter.write(samples: result.mic, sampleRate: 16_000, to: "/tmp/listnr-mic.wav")
                try WAVWriter.write(samples: result.system, sampleRate: 16_000, to: "/tmp/listnr-sys.wav")
                FileHandle.standardError.write(Data("  wrote /tmp/listnr-mic.wav + /tmp/listnr-sys.wav\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
            }
        }

        var allLines: [TranscriptLine] = []
        if options.transcribe, let youLane, let othersLane, let sharedTranscriber, !Task.isCancelled {
            allLines = await finalizeTranscript(
                youLane: youLane,
                othersLane: othersLane,
                transcriber: sharedTranscriber,
                result: result
            )
            TranscriptMerger.printAll(allLines)
            MeetingSession.shared.replace(lines: allLines)
        }

        var saved: String?
        if !allLines.isEmpty, let path = try? MeetingSession.shared.exportMarkdown() {
            FileHandle.standardError.write(Data("  saved \(path)\n".utf8))
            saved = path
        }

        return Outcome(lines: allLines, result: result, savedPath: saved)
    }

    private func finalizeTranscript(
        youLane: LaneTranscriber,
        othersLane: LaneTranscriber,
        transcriber: WhisperKitTranscriber,
        result: DualCaptureSession.Result
    ) async -> [TranscriptLine] {
        var you = await youLane.finish()
        _ = await othersLane.finish()

        if you.isEmpty, AudioMath.rms(result.mic) >= 0.008 {
            if let text = try? await transcriber.transcribe(result.mic), !text.isEmpty {
                you = [TranscriptLine(speaker: "You", startSeconds: 0, text: text)]
            }
        }

        var remote: [TranscriptLine] = []
        if options.diarize, AudioMath.rms(result.system) >= 0.008 {
            FileHandle.standardError.write(Data("\ndiarizing Lane B (remote speakers)…\n".utf8))
            let diarizer = RemoteDiarizer(speakerHint: options.remoteSpeakers)
            do {
                try await diarizer.warmUp()
                let spans = try await diarizer.diarize(result.system)
                FileHandle.standardError.write(Data("  found \(spans.count) remote speech span(s)\n".utf8))
                if spans.isEmpty {
                    if let text = try? await transcriber.transcribe(result.system), !text.isEmpty {
                        remote = [TranscriptLine(speaker: "Others", startSeconds: 0, text: text)]
                    }
                } else {
                    remote = await DiarizedTranscriber.transcribeSpans(
                        audio: result.system,
                        spans: spans,
                        transcriber: transcriber
                    )
                }
            } catch {
                FileHandle.standardError.write(Data("diarization failed: \(error.localizedDescription) — falling back to Others\n".utf8))
                if let text = try? await transcriber.transcribe(result.system), !text.isEmpty {
                    remote = [TranscriptLine(speaker: "Others", startSeconds: 0, text: text)]
                }
            }
        } else if AudioMath.rms(result.system) >= 0.008 {
            if let text = try? await transcriber.transcribe(result.system), !text.isEmpty {
                remote = [TranscriptLine(speaker: "Others", startSeconds: 0, text: text)]
            }
        }

        return TranscriptMerger.merge([you, remote])
    }
}

enum LiveSessionError: Error, LocalizedError {
    case noResult
    case alreadyLive
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noResult: return "session returned no result"
        case .alreadyLive: return "already listening — /stop first"
        case .cancelled: return "cancelled"
        }
    }
}
