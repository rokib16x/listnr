import Foundation

/// Runs Lane A (mic) and Lane B (system/speakers) in parallel.
/// Lanes are never mixed — that is intentional for multi-speaker STT later.
final class DualCaptureSession {
    struct Result {
        let mic: [Float]
        let system: [Float]
        let durationSeconds: Double
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
        let micSamples = mic.stop()
        let systemSamples = await system.stop()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        running = false
        return Result(mic: micSamples, system: systemSamples, durationSeconds: duration)
    }

    /// Capture for a fixed duration (M1 verification helper).
    func capture(seconds: Double) async throws -> Result {
        try await start()
        let ns = UInt64(max(seconds, 0.1) * 1_000_000_000)
        try await Task.sleep(nanoseconds: ns)
        return await stop()
    }
}
