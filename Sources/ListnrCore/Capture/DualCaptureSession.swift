import Foundation

/// Runs Lane A (mic) and Lane B (system/speakers) in parallel.
/// Lanes are never mixed. That is intentional for multi-speaker STT later.
final class DualCaptureSession {
    struct Result {
        let mic: [Float]
        let system: [Float]
        let durationSeconds: Double
        /// Host-clock time of each lane's first sample, when known. The lanes
        /// start milliseconds apart, so their sample-count timestamps are not
        /// directly comparable; these anchor both onto one session timeline.
        let micFirstSampleTime: Double?
        let systemFirstSampleTime: Double?

        /// Seconds to add to each lane's timestamps to place them on a shared
        /// clock whose zero is whichever lane started first.
        /// Returns `(0, 0)` when the measurement is missing or implausible.
        var laneOffsets: (mic: Double, system: Double) {
            guard let m = micFirstSampleTime, let s = systemFirstSampleTime else { return (0, 0) }
            let skew = abs(m - s)
            // A real start gap is tens to hundreds of milliseconds. Anything
            // larger means the two clocks are not comparable on this system, and
            // shifting by a bogus amount is worse than not shifting at all.
            guard skew <= 5 else {
                FileHandle.standardError.write(Data(
                    String(format: "! lane clock skew %.1fs looks wrong, merging without an offset\n", skew).utf8
                ))
                return (0, 0)
            }
            let origin = min(m, s)
            return (m - origin, s - origin)
        }
    }

    enum SessionError: Error, LocalizedError {
        case alreadyRunning
        case mic(Error)
        case system(Error)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "capture session already running"
            case .mic(let e): return "mic: \(e.localizedDescription)"
            case .system(let e): return "system audio: \(e.localizedDescription)"
            }
        }
    }

    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var startedAt: Date?
    private var running = false

    var onMicLevel: ((Float) -> Void)? {
        get { mic.onLevel }
        set { mic.onLevel = newValue }
    }

    var onSystemLevel: ((Float) -> Void)? {
        get { system.onLevel }
        set { system.onLevel = newValue }
    }

    var onMicSamples: (([Float]) -> Void)? {
        get { mic.onSamples }
        set { mic.onSamples = newValue }
    }

    var onSystemSamples: (([Float]) -> Void)? {
        get { system.onSamples }
        set { system.onSamples = newValue }
    }

    var isRunning: Bool { running }

    func start() async throws {
        guard !running else { throw SessionError.alreadyRunning }

        do {
            try mic.start()
        } catch {
            throw SessionError.mic(error)
        }

        do {
            try await system.start()
        } catch {
            _ = mic.stop()
            throw SessionError.system(error)
        }

        startedAt = Date()
        running = true
    }

    /// Preferred after heavy model load: attach ScreenCaptureKit first, then mic.
    func startSystemThenMic() async throws {
        guard !running else { throw SessionError.alreadyRunning }

        do {
            try await system.start()
        } catch {
            throw SessionError.system(error)
        }

        do {
            try mic.start()
        } catch {
            _ = await system.stop()
            throw SessionError.mic(error)
        }

        startedAt = Date()
        running = true
    }

    func stop() async -> Result {
        // Read the anchors before stopping, since `stop()` clears per-run state.
        let micAnchor = mic.firstSampleTime
        let systemAnchor = system.firstSampleTime
        let micSamples = mic.stop()
        let systemSamples = await system.stop()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        running = false
        return Result(
            mic: micSamples,
            system: systemSamples,
            durationSeconds: duration,
            micFirstSampleTime: micAnchor,
            systemFirstSampleTime: systemAnchor
        )
    }
}
