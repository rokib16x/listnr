import Foundation

/// Energy-based speech segmenter.
///
/// Keeps a short **pre-roll** ring so the first syllable after a pause is not
/// clipped (VAD only fires once energy crosses the threshold — by then the
/// onset consonant is often already gone).
///
/// A `struct` on purpose: the segmenter is owned by exactly one consumer task
/// in `LaneTranscriber`, so there is nothing shared across threads and nothing
/// to reason about w.r.t. `Sendable`.
struct EnergyVAD {
    struct Segment: Sendable {
        let startSeconds: Double
        let samples: [Float]
    }

    private let sampleRate: Double
    private let speechThreshold: Float
    private let minSpeechSeconds: Double
    private let maxSpeechSeconds: Double
    private let hangoverSeconds: Double
    private let prerollSeconds: Double
    private let minVoicedSamples: Int
    private let minVoicedRunSamples: Int
    private let frameSamples: Int
    private let prerollSamples: Int

    private var absoluteFrame = 0
    private var inSpeech = false
    private var speechStartFrame = 0
    private var hangoverLeft = 0
    private var utterance: [Float] = []
    /// Frames that were actually above threshold, as opposed to pre-roll and
    /// hangover padding. See `minVoicedSeconds`.
    private var voicedSamples = 0
    /// Longest *contiguous* voiced stretch — what separates a syllable from a click.
    private var longestVoicedRun = 0
    private var currentVoicedRun = 0
    private var carry: [Float] = []
    /// Rolling silence/speech history used as lookback when speech starts.
    private var preroll: [Float] = []

    init(
        sampleRate: Double = 16_000,
        speechThreshold: Float = 0.010,
        minSpeechSeconds: Double = 0.35,
        maxSpeechSeconds: Double = 12,
        hangoverSeconds: Double = 0.55,
        prerollSeconds: Double = 0.45,
        minVoicedSeconds: Double = 0.15,
        minVoicedRunSeconds: Double = 0.09
    ) {
        self.sampleRate = sampleRate
        self.speechThreshold = speechThreshold
        self.minSpeechSeconds = minSpeechSeconds
        self.maxSpeechSeconds = maxSpeechSeconds
        self.hangoverSeconds = hangoverSeconds
        self.prerollSeconds = prerollSeconds
        self.frameSamples = max(1, Int(sampleRate * 0.03))
        self.minVoicedSamples = Int(sampleRate * minVoicedSeconds)
        self.minVoicedRunSamples = Int(sampleRate * minVoicedRunSeconds)
        self.prerollSamples = max(frameSamples, Int(sampleRate * prerollSeconds))
    }

    mutating func push(_ chunk: [Float]) -> [Segment] {
        carry.append(contentsOf: chunk)
        var out: [Segment] = []

        while carry.count >= frameSamples {
            let frame = Array(carry.prefix(frameSamples))
            carry.removeFirst(frameSamples)
            if let seg = processFrame(frame) {
                out.append(seg)
            }
            absoluteFrame += frameSamples
        }
        return out
    }

    mutating func flush() -> [Segment] {
        var out: [Segment] = []
        if inSpeech, let seg = finishUtterance() {
            out.append(seg)
        }
        resetUtteranceState()
        carry.removeAll(keepingCapacity: true)
        // Keep preroll across flush within a session? Clear — flush = end of stream.
        preroll.removeAll(keepingCapacity: true)
        return out
    }

    private var hangoverFrames: Int {
        max(1, Int(hangoverSeconds * sampleRate / Double(frameSamples)))
    }

    private mutating func processFrame(_ frame: [Float]) -> Segment? {
        let speaking = AudioMath.rms(frame) >= speechThreshold

        if !inSpeech {
            appendPreroll(frame)
            if speaking {
                inSpeech = true
                // Credit the lookback so timestamps and audio include the onset.
                let lookback = preroll
                let lookbackFrames = lookback.count
                speechStartFrame = max(0, absoluteFrame - lookbackFrames)
                hangoverLeft = hangoverFrames
                utterance = lookback
                utterance.append(contentsOf: frame)
                voicedSamples = frame.count
                currentVoicedRun = frame.count
                longestVoicedRun = frame.count
                preroll.removeAll(keepingCapacity: true)
            }
            return nil
        }

        utterance.append(contentsOf: frame)
        if speaking {
            voicedSamples += frame.count
            currentVoicedRun += frame.count
            longestVoicedRun = max(longestVoicedRun, currentVoicedRun)
            hangoverLeft = hangoverFrames
        } else {
            currentVoicedRun = 0
            hangoverLeft -= 1
        }

        let duration = Double(utterance.count) / sampleRate
        if hangoverLeft <= 0 || duration >= maxSpeechSeconds {
            return finishUtterance()
        }
        return nil
    }

    private mutating func appendPreroll(_ frame: [Float]) {
        preroll.append(contentsOf: frame)
        if preroll.count > prerollSamples {
            preroll.removeFirst(preroll.count - prerollSamples)
        }
    }

    private mutating func finishUtterance() -> Segment? {
        defer { resetUtteranceState() }
        guard !utterance.isEmpty else { return nil }

        // Three floors, each rejecting something the others cannot.
        //
        // `minSpeechSeconds` bounds the *buffer* — Whisper needs some context.
        //
        // `minVoicedSeconds` bounds how much of that buffer was above threshold.
        // Without it the pre-roll defeats the buffer floor entirely: one frame
        // over threshold yields preroll + frame + hangover ≈ 1 s, so a keyboard
        // clack always passed as speech and Whisper duly hallucinated words.
        //
        // `minVoicedRunSeconds` bounds the longest *contiguous* voiced stretch,
        // because total duration alone cannot tell one syllable from a burst of
        // typing: six 30 ms key clicks inside the hangover window sum to the same
        // 180 ms as a short word. Speech has a continuous syllable; clicks do not.
        let duration = Double(utterance.count) / sampleRate
        guard duration >= minSpeechSeconds,
              voicedSamples >= minVoicedSamples,
              longestVoicedRun >= minVoicedRunSamples
        else { return nil }
        return Segment(startSeconds: Double(speechStartFrame) / sampleRate, samples: utterance)
    }

    private mutating func resetUtteranceState() {
        inSpeech = false
        hangoverLeft = 0
        voicedSamples = 0
        longestVoicedRun = 0
        currentVoicedRun = 0
        utterance.removeAll(keepingCapacity: true)
    }
}
