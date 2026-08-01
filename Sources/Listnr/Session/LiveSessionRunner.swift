import Foundation

/// Carries the session task's result across the semaphore hand-off in
/// `runBlocking`. Captured `var`s would race under older strict-concurrency
/// checkers; the lock makes the ordering explicit.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOutcome: LiveSessionRunner.Outcome?
    private var storedError: Error?

    func store(outcome: LiveSessionRunner.Outcome?, error: Error?) {
        lock.lock()
        storedOutcome = outcome
        storedError = error
        lock.unlock()
    }

    var value: (outcome: LiveSessionRunner.Outcome?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (storedOutcome, storedError)
    }
}

/// Runs one dual-lane listening session (timed or until `requestStop()` / Task cancel).
///
/// `@unchecked Sendable` is sound here: the stop flags and `runningTask` are
/// only touched under `stopLock`, `options` is immutable, and everything else
/// is owned by the single session task created in `runBlocking`.
final class LiveSessionRunner: @unchecked Sendable {
    struct Outcome {
        let lines: [TranscriptLine]
        let result: DualCaptureSession.Result
        let savedPath: String?
    }

    private let options: SessionOptions
    /// Stop-versus-cancel rule; see `SessionStopState` for why it lives there.
    private let stopState = SessionStopState()
    private let stopLock = NSLock()
    private var runningTask: Task<Void, Never>?

    init(options: SessionOptions) {
        self.options = options
    }

    /// Finish the session gracefully: capture stops and the transcript is
    /// finalized. Before capture has begun (model download / load) there is
    /// nothing to finalize, so stopping there cancels the task to abort the
    /// download instead of letting it run to completion.
    func requestStop() {
        if stopState.requestStop() {
            currentTask()?.cancel()
        }
    }

    /// Abort the session: capture stops and the transcript is discarded.
    func requestCancel() {
        stopState.requestCancel()
        currentTask()?.cancel()
    }

    private func currentTask() -> Task<Void, Never>? {
        stopLock.lock()
        defer { stopLock.unlock() }
        return runningTask
    }

    private var shouldStop: Bool {
        stopState.shouldFinish || Task.isCancelled
    }

    /// True only for an abort (Ctrl+C or Task cancel), never for a graceful /stop.
    private var wasCancelled: Bool {
        stopState.isCancel || Task.isCancelled
    }

    private func markCaptureStarted() {
        stopState.markCaptureStarted()
    }

    /// Pump the main run loop while the async session runs (needed for SCK / AVAudio).
    func runBlocking() throws -> Outcome {
        let sem = DispatchSemaphore(value: 0)
        let box = OutcomeBox()

        let task = Task {
            do {
                try Task.checkCancellation()
                box.store(outcome: try await run(), error: nil)
            } catch is CancellationError {
                box.store(outcome: nil, error: CancellationError())
                FileHandle.standardError.write(Data("\n○ cancelled\n".utf8))
            } catch let caught {
                // Map to "cancelled" only on a real abort. A graceful /stop must
                // not swallow a genuine failure that happened after the keypress.
                if wasCancelled {
                    box.store(outcome: nil, error: CancellationError())
                    FileHandle.standardError.write(Data("\n○ cancelled\n".utf8))
                } else {
                    box.store(outcome: nil, error: caught)
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

        let (outcome, error) = box.value
        if let error {
            if error is CancellationError {
                throw LiveSessionError.cancelled
            }
            throw error
        }
        guard let outcome else {
            throw wasCancelled ? LiveSessionError.cancelled : LiveSessionError.noResult
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
                detectLanguage: options.language == .auto,
                translate: options.translate
            )
            sharedTranscriber = t
            try await t.warmUp()
            try Task.checkCancellation()
            if shouldStop { throw CancellationError() }
            // Stricter thresholds on the system lane; silence there was hallucinating “Thank you”.
            youLane = LaneTranscriber(speakerLabel: "You", transcriber: t, speechThreshold: 0.014, minSegmentRMS: 0.018)
            othersLane = LaneTranscriber(speakerLabel: "Others", transcriber: t, speechThreshold: 0.022, minSegmentRMS: 0.025)
        }

        // Whatever path leaves this function, the lane pipelines must be torn
        // down, or every failed / cancelled session leaks two detached tasks
        // and their buffered audio for the life of the shell. `abandon()` is
        // idempotent, so this is safe after a normal `finish()` too.
        defer {
            youLane?.abandon()
            othersLane?.abandon()
        }

        let durationLabel = options.seconds.map { String(format: "%.0fs", $0) } ?? "until stop"
        let langNote: String = {
            switch options.language {
            case .auto: return "auto-detect (for Bangla/Hindi prefer /lang bn or /lang hi)"
            default: return options.language.rawValue
            }
        }()
        let taskNote = options.translate ? " · translating → English" : ""
        FileHandle.standardError.write(Data(
            "● live · \(durationLabel) · model=\(model.id) · lang=\(langNote)\(taskNote) · speakers≈\(options.remoteSpeakers)\n".utf8
        ))
        // The stop/cancel key hints differ per mode (shell vs one-shot), so the
        // caller supplies them.
        if let hint = options.controlsHint {
            FileHandle.standardError.write(Data("  \(hint)\n\n".utf8))
        }

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

        // Hand buffers straight to the lane pipeline. Deliberately *not*
        // `Task { await lane.push(chunk) }`: unstructured tasks have no ordering
        // guarantee, so audio would reach the VAD shuffled. `push` is
        // synchronous, non-blocking, and preserves capture order.
        if let youLane {
            session.onMicSamples = { chunk in youLane.push(chunk) }
        }
        if let othersLane {
            session.onSystemSamples = { chunk in othersLane.push(chunk) }
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
                    "\n! mic still silent. Check System Settings → Sound → Input, and speak louder\n".utf8
                ))
            }
        }
        meter.resume()

        // Start system audio first, then mic (more reliable after SCK permission / ANE load).
        do {
            do {
                try await session.startSystemThenMic()
            } catch {
                // Fallback to original order.
                try await session.start()
            }
        } catch {
            meter.cancel()
            throw error
        }
        markCaptureStarted()
        let sessionStartedAt = Date()

        let deadline: Date? = options.seconds.map { Date().addingTimeInterval($0) }
        while !shouldStop {
            if let deadline, Date() >= deadline { break }
            // Not `try`: a graceful /stop cancels nothing, but a Ctrl+C does,
            // and a throw here would discard the session instead of letting the
            // cancel path below decide what to keep.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        meter.cancel()
        FileHandle.standardError.write(Data("\n".utf8))

        let result = await session.stop()

        // Aborted before any useful audio existed, so bail without a report.
        if wasCancelled, result.durationSeconds < 0.5, result.mic.count < 8_000 {
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
            // Not /tmp: that is world-readable at predictable paths, so raw
            // meeting audio was exposed to every local user on a shared Mac.
            let dir = MeetingSession.defaultMeetingsDir().appendingPathComponent("debug", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let micURL = dir.appendingPathComponent("listnr-mic.wav")
                let sysURL = dir.appendingPathComponent("listnr-sys.wav")
                try WAVWriter.write(samples: result.mic, sampleRate: 16_000, to: micURL.path)
                try WAVWriter.write(samples: result.system, sampleRate: 16_000, to: sysURL.path)
                for url in [micURL, sysURL] {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: url.path
                    )
                }
                FileHandle.standardError.write(Data("  wrote \(micURL.path) + \(sysURL.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
            }
        }

        var allLines: [TranscriptLine] = []
        if options.transcribe, let youLane, let othersLane, let sharedTranscriber, !wasCancelled {
            allLines = await finalizeTranscript(
                youLane: youLane,
                othersLane: othersLane,
                transcriber: sharedTranscriber,
                result: result
            )
            TranscriptMerger.printAll(allLines)
            MeetingSession.shared.replace(lines: allLines, startedAt: sessionStartedAt)
        }

        var saved: String?
        if !allLines.isEmpty {
            do {
                let path = try MeetingSession.shared.exportMarkdown()
                FileHandle.standardError.write(Data("  saved \(path)\n".utf8))
                saved = path
            } catch {
                FileHandle.standardError.write(Data(
                    "! could not save transcript: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        return Outcome(lines: allLines, result: result, savedPath: saved)
    }

    private func finalizeTranscript(
        youLane: LaneTranscriber,
        othersLane: LaneTranscriber,
        transcriber: WhisperKitTranscriber,
        result: DualCaptureSession.Result
    ) async -> [TranscriptLine] {
        // Lane A and Lane B start milliseconds apart, so each lane's
        // sample-count timestamps sit on its own zero. Everything below stays
        // in lane time; both lanes are shifted onto the shared session clock
        // exactly once, at the merge.
        let offsets = result.laneOffsets

        var you = await youLane.finish()
        if you.isEmpty, AudioMath.rms(result.mic) >= 0.008 {
            if let text = try? await transcriber.transcribe(result.mic), !text.isEmpty {
                you = [TranscriptLine(speaker: "You", startSeconds: 0, text: text)]
            }
        }

        // Lane B, in order of preference: diarized per-span lines, then the
        // timestamped lines the live lane already transcribed, and only as a
        // last resort one whole-buffer blob at 00:00.
        let liveOthers = await othersLane.finish()
        let systemRMS = AudioMath.rms(result.system)

        var remote: [TranscriptLine] = []
        if options.diarize, systemRMS >= 0.008 {
            FileHandle.standardError.write(Data("\ndiarizing Lane B (remote speakers)...\n".utf8))
            let diarizer = RemoteDiarizer(speakerHint: options.remoteSpeakers)
            do {
                try await diarizer.warmUp()
                let spans = try await diarizer.diarize(result.system)
                FileHandle.standardError.write(Data("  found \(spans.count) remote speech span(s)\n".utf8))
                if !spans.isEmpty {
                    remote = await DiarizedTranscriber.transcribeSpans(
                        audio: result.system,
                        spans: spans,
                        transcriber: transcriber
                    )
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "diarization failed: \(error.localizedDescription), keeping the live Others lines\n".utf8
                ))
            }
        }
        if remote.isEmpty {
            remote = liveOthers
        }
        if remote.isEmpty, systemRMS >= 0.008 {
            if let text = try? await transcriber.transcribe(result.system), !text.isEmpty {
                remote = [TranscriptLine(speaker: "Others", startSeconds: 0, text: text)]
            }
        }

        return TranscriptMerger.merge([
            TranscriptMerger.shift(you, by: offsets.mic),
            TranscriptMerger.shift(remote, by: offsets.system),
        ])
    }
}

enum LiveSessionError: Error, LocalizedError {
    case noResult
    case alreadyLive
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noResult: return "session returned no result"
        case .alreadyLive: return "already listening, /stop first"
        case .cancelled: return "cancelled"
        }
    }
}
