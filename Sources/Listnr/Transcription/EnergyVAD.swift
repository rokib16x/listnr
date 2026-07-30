import Foundation

/// Energy-based speech segmenter.
///
/// Keeps a short **pre-roll** ring so the first syllable after a pause is not
/// clipped (VAD only fires once energy crosses the threshold — by then the
/// onset consonant is often already gone).
final class EnergyVAD {
    struct Segment {
        let startSeconds: Double
        let samples: [Float]
    }

    private let sampleRate: Double
    private let speechThreshold: Float
    private let minSpeechSeconds: Double
    private let maxSpeechSeconds: Double
    private let hangoverSeconds: Double
    private let prerollSeconds: Double
    private let frameSamples: Int
    private let prerollSamples: Int

    private var absoluteFrame = 0
    private var inSpeech = false
    private var speechStartFrame = 0
    private var hangoverLeft = 0
    private var utterance: [Float] = []
    private var carry: [Float] = []
    /// Rolling silence/speech history used as lookback when speech starts.
    private var preroll: [Float] = []

    init(
        sampleRate: Double = 16_000,
        speechThreshold: Float = 0.010,
        minSpeechSeconds: Double = 0.35,
        maxSpeechSeconds: Double = 12,
        hangoverSeconds: Double = 0.55,
        prerollSeconds: Double = 0.45
    ) {
        self.sampleRate = sampleRate
        self.speechThreshold = speechThreshold
        self.minSpeechSeconds = minSpeechSeconds
        self.maxSpeechSeconds = maxSpeechSeconds
        self.hangoverSeconds = hangoverSeconds
        self.prerollSeconds = prerollSeconds
        self.frameSamples = max(1, Int(sampleRate * 0.03))
        self.prerollSamples = max(frameSamples, Int(sampleRate * prerollSeconds))
    }

    func push(_ chunk: [Float]) -> [Segment] {
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

    func flush() -> [Segment] {
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

    private func processFrame(_ frame: [Float]) -> Segment? {
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
                preroll.removeAll(keepingCapacity: true)
            }
            return nil
        }

        utterance.append(contentsOf: frame)
        if speaking {
            hangoverLeft = hangoverFrames
        } else {
            hangoverLeft -= 1
        }

        let duration = Double(utterance.count) / sampleRate
        if hangoverLeft <= 0 || duration >= maxSpeechSeconds {
            return finishUtterance()
        }
        return nil
    }

    private func appendPreroll(_ frame: [Float]) {
        preroll.append(contentsOf: frame)
        if preroll.count > prerollSamples {
            preroll.removeFirst(preroll.count - prerollSamples)
        }
    }

    private func finishUtterance() -> Segment? {
        defer { resetUtteranceState() }
        let duration = Double(utterance.count) / sampleRate
        guard duration >= minSpeechSeconds, !utterance.isEmpty else { return nil }
        return Segment(startSeconds: Double(speechStartFrame) / sampleRate, samples: utterance)
    }

    private func resetUtteranceState() {
        inSpeech = false
        hangoverLeft = 0
        utterance.removeAll(keepingCapacity: true)
    }
}
