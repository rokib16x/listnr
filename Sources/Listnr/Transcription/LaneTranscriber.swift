import Foundation

struct TranscriptLine: Sendable {
    let speaker: String
    let startSeconds: Double
    let text: String
}

/// `mm:ss` for transcript display.
func formatClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// Collects finished lines for one lane.
actor TranscriptStore {
    private var lines: [TranscriptLine] = []

    func append(_ line: TranscriptLine) {
        lines.append(line)
    }

    var sorted: [TranscriptLine] {
        lines.sorted { $0.startSeconds < $1.startSeconds }
    }
}

/// Counts buffers/segments discarded under overload. Reported once at finish so
/// a struggling machine says so instead of silently losing speech.
private final class DropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Per-lane pipeline: captured audio → VAD → Whisper → transcript lines.
/// Lanes stay separate (You vs Others) — see the "never mix before ASR" rule.
///
/// Two properties this type exists to guarantee:
///
/// 1. **Order.** Audio is segmented in capture order. Spawning a task per
///    buffer does *not* give that — unstructured tasks reach an actor in
///    arbitrary order, which shuffles the VAD's input and corrupts utterances.
///    A single `for await` loop per stage is what makes it FIFO.
/// 2. **No head-of-line blocking.** Whisper takes hundreds of milliseconds to
///    seconds per segment. Running it inline with segmentation would stall the
///    VAD and let audio pile up without bound, so ASR is a separate stage
///    behind a bounded queue that drops oldest under sustained overload.
final class LaneTranscriber {
    let speakerLabel: String

    private let store = TranscriptStore()
    private let audio: AsyncStream<[Float]>.Continuation
    private let vadTask: Task<Void, Never>
    private let asrTask: Task<Void, Never>
    private let audioDrops = DropCounter()
    private let segmentDrops = DropCounter()

    init(
        speakerLabel: String,
        transcriber: WhisperKitTranscriber,
        speechThreshold: Float = 0.015,
        minSegmentRMS: Float = 0.020
    ) {
        self.speakerLabel = speakerLabel

        // Buffers arrive roughly every 85 ms, so this is ~17 s of slack. The VAD
        // stage is cheap and should never fall this far behind; dropping oldest
        // is a safety valve, not an expected path.
        let (audioStream, audioContinuation) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingNewest(200)
        )
        // Each segment holds at most `maxSpeechSeconds` of audio, so bounding the
        // count bounds the worst-case memory while Whisper catches up.
        let (segmentStream, segmentContinuation) = AsyncStream<EnergyVAD.Segment>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )

        self.audio = audioContinuation

        let segmentDrops = self.segmentDrops
        let vad = Task.detached(priority: .userInitiated) {
            // Owned solely by this task — that is why EnergyVAD is a struct.
            var segmenter = EnergyVAD(
                speechThreshold: speechThreshold,
                minSpeechSeconds: 0.45,
                hangoverSeconds: 0.60,
                prerollSeconds: 0.45
            )
            for await chunk in audioStream {
                for segment in segmenter.push(chunk) {
                    if case .dropped = segmentContinuation.yield(segment) { segmentDrops.bump() }
                }
            }
            // Stream finished: emit whatever the tail of the session left buffered.
            for segment in segmenter.flush() {
                if case .dropped = segmentContinuation.yield(segment) { segmentDrops.bump() }
            }
            segmentContinuation.finish()
        }
        vadTask = vad

        let store = self.store
        let asr = Task.detached(priority: .userInitiated) {
            for await segment in segmentStream {
                guard AudioMath.rms(segment.samples) >= minSegmentRMS else { continue }
                do {
                    let text = try await transcriber.transcribe(segment.samples)
                    guard !text.isEmpty else { continue }
                    await store.append(
                        TranscriptLine(
                            speaker: speakerLabel,
                            startSeconds: segment.startSeconds,
                            text: text
                        )
                    )
                    let stamp = formatClock(segment.startSeconds)
                    let label = speakerLabel.padding(toLength: 8, withPad: " ", startingAt: 0)
                    FileHandle.standardError.write(Data("[\(stamp)] \(label) \(text)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data(
                        "transcription error (\(speakerLabel)): \(error.localizedDescription)\n".utf8
                    ))
                }
            }
        }
        asrTask = asr
    }

    /// Hand audio to the pipeline. Safe to call from the capture callback:
    /// returns immediately and never blocks on segmentation or ASR.
    func push(_ chunk: [Float]) {
        if case .dropped = audio.yield(chunk) { audioDrops.bump() }
    }

    /// Close the pipeline and drain both stages. Returns the lane's lines in
    /// timestamp order.
    func finish() async -> [TranscriptLine] {
        audio.finish()
        await vadTask.value
        await asrTask.value
        reportDrops()
        return await store.sorted
    }

    private func reportDrops() {
        let audioLost = audioDrops.count
        let segmentsLost = segmentDrops.count
        guard audioLost > 0 || segmentsLost > 0 else { return }
        var note = "! \(speakerLabel): dropped"
        if audioLost > 0 { note += " \(audioLost) audio buffer(s)" }
        if audioLost > 0 && segmentsLost > 0 { note += " and" }
        if segmentsLost > 0 { note += " \(segmentsLost) speech segment(s)" }
        note += " — transcription could not keep up. Try a smaller model.\n"
        FileHandle.standardError.write(Data(note.utf8))
    }
}

enum TranscriptMerger {
    static func merge(_ lanes: [[TranscriptLine]]) -> [TranscriptLine] {
        lanes.flatMap { $0 }.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// Shift a lane's timestamps onto the shared session clock.
    static func shift(_ lines: [TranscriptLine], by offset: Double) -> [TranscriptLine] {
        guard offset != 0 else { return lines }
        return lines.map {
            TranscriptLine(
                speaker: $0.speaker,
                startSeconds: max(0, $0.startSeconds + offset),
                text: $0.text
            )
        }
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
