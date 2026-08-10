// @preconcurrency: see ConverterFeed.swift; the import must be consistent
// across the files sharing its AVFoundation-typed API.
@preconcurrency import AVFoundation
import Foundation

/// Lane A, the microphone. Captures 16 kHz mono Float32 while running.
///
/// `@unchecked Sendable` because macOS delivers the engine's configuration-change
/// notification on an arbitrary thread, so this type has to be safe to touch from
/// one. Two locks keep that sound, and they are never held at the same time:
/// `engineLock` covers the engine and its tap, `lock` covers the captured
/// samples. Taking them in one order only would still deadlock here, because
/// `removeTap` blocks until in-flight tap callbacks return and those callbacks
/// take `lock` — so a rebuild must never hold `lock`.
final class MicCapture: @unchecked Sendable {
    enum CaptureError: Error, LocalizedError {
        case engineStartFailed(Error)
        case converterCreationFailed
        case noInputDevice
        case invalidInputFormat

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e.localizedDescription)"
            case .converterCreationFailed: return "mic converter creation failed"
            case .noInputDevice: return "no microphone found. This Mac has no built-in mic, or the one you were using disconnected. Connect a mic and check System Settings → Sound → Input"
            case .invalidInputFormat: return "mic input format invalid (0 channels / rate). Check System Settings → Sound → Input"
            }
        }
    }

    static let targetSampleRate: Double = 16_000

    /// How many times the engine may be rebuilt in one session before giving up.
    ///
    /// A device that flaps between profiles would otherwise rebuild forever. Four
    /// is well above the one rebuild a Bluetooth headset needs, while still
    /// terminating.
    private static let maxRebuilds = 4

    private let engineLock = NSLock()
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var rebuilds = 0
    private var isRecording = false

    private let lock = NSLock()
    private var resampler: ResampleCache?
    private var samples: [Float] = []
    private var firstSampleHostSeconds: Double?
    /// Whether the input format has been reported. Reset on rebuild, so a device
    /// that changes format mid-session says so.
    private var announcedFormat = false

    var onLevel: ((Float) -> Void)?
    var onSamples: (([Float]) -> Void)?

    var isRunning: Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return isRecording
    }

    /// Host-clock time of the first captured sample, or nil if nothing arrived.
    /// Used to place this lane on the shared session timeline.
    var firstSampleTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return firstSampleHostSeconds
    }

    func start() throws {
        engineLock.lock()
        let alreadyRunning = isRecording
        engineLock.unlock()
        guard !alreadyRunning else { return }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: MicCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CaptureError.converterCreationFailed
        }

        // One cache for the whole session, including across rebuilds: it derives
        // the input format from each buffer, so a device that switches from
        // 48 kHz to 24 kHz mid-session is handled without losing the lane.
        let resampler = ResampleCache(targetFormat: targetFormat)

        lock.lock()
        self.resampler = resampler
        samples.removeAll(keepingCapacity: true)
        firstSampleHostSeconds = nil
        announcedFormat = false
        lock.unlock()

        engineLock.lock()
        rebuilds = 0
        engineLock.unlock()

        try buildEngine(resampler: resampler)

        engineLock.lock()
        isRecording = true
        engineLock.unlock()
    }

    @discardableResult
    func stop() -> [Float] {
        engineLock.lock()
        guard isRecording else {
            engineLock.unlock()
            return []
        }
        isRecording = false
        // Detached before tearing the engine down, so the stop itself cannot
        // trigger a rebuild.
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engineLock.unlock()

        lock.lock()
        resampler = nil
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return captured
    }

    // MARK: - Engine lifecycle

    /// Stand up a fresh engine with a tap on the input node.
    ///
    /// Always a new `AVAudioEngine`. Reusing one across a device format change
    /// does not work: the engine keeps reporting the pre-change format and its
    /// tap never delivers another buffer, even if the tap is reinstalled.
    private func buildEngine(resampler: ResampleCache) throws {
        engineLock.lock()
        defer { engineLock.unlock() }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()

        let input = engine.inputNode
        engine.prepare()

        // Advisory only, and never used as the tap format: a Bluetooth headset
        // sitting in its output-only profile reports a stale rate here (48 kHz
        // for a device that will run at 24 kHz once the input opens), and a tap
        // installed against a format the hardware disagrees with delivers nothing
        // at all, silently. That produced whole sessions of `mic=0.0s`.
        //
        // What it *is* good for is refusing to continue when there is no input
        // device, which on a Mac with no built-in microphone is what happens the
        // moment a headset disconnects. Both installing a tap and starting the
        // engine raise Objective-C exceptions in that state, and those cannot be
        // caught from Swift — the process dies with SIGABRT and a CoreAudio
        // message instead of saying which cable to plug in.
        let advertised = input.inputFormat(forBus: 0)
        if ProcessInfo.processInfo.environment["LISTNR_DEBUG_MIC"] != nil {
            let fallback = input.outputFormat(forBus: 0)
            FileHandle.standardError.write(Data(String(
                format: "  [debug] inputFormat %.0f Hz %d ch · outputFormat %.0f Hz %d ch\n",
                advertised.sampleRate, advertised.channelCount,
                fallback.sampleRate, fallback.channelCount
            ).utf8))
        }
        // Deliberately not falling back to the node's *output* format when the
        // input one is empty. That fallback is what let this reach the crash: with
        // no microphone attached the input side reads 0 Hz / 0 ch while the output
        // side still reads a plausible 44.1 kHz stereo, so the guard passed on a
        // number that had nothing to do with any input hardware.
        guard AudioDevices.hasInputDevice() else {
            throw CaptureError.noInputDevice
        }
        guard advertised.channelCount > 0, advertised.sampleRate >= 1000 else {
            throw CaptureError.invalidInputFormat
        }

        // nil means "whatever this bus actually produces", the only value that
        // cannot contradict the hardware.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            self?.process(buffer: buffer, when: when, resampler: resampler)
        }

        // Opening the input is what makes a Bluetooth headset switch profile, and
        // the switch invalidates this engine. The notification is how macOS says
        // so, and rebuilding is the only way back to a working tap.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange(resampler: resampler)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }
    }

    private func handleConfigurationChange(resampler: ResampleCache) {
        engineLock.lock()
        let recording = isRecording
        let attempt = rebuilds
        if recording, attempt < Self.maxRebuilds { rebuilds += 1 }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engineLock.unlock()

        guard recording else { return }
        guard attempt < Self.maxRebuilds else {
            FileHandle.standardError.write(Data(
                ("\r\u{001B}[K! mic device kept changing format; giving up after "
                    + "\(Self.maxRebuilds) attempts. Try a wired or USB microphone.\n").utf8
            ))
            return
        }

        // The new device may have a different format, so let it be reported.
        lock.lock()
        announcedFormat = false
        lock.unlock()

        do {
            try buildEngine(resampler: resampler)
        } catch {
            FileHandle.standardError.write(Data(
                "\r\u{001B}[K! mic restart after device change failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    // MARK: - Sample handling

    private func process(
        buffer: AVAudioPCMBuffer,
        when: AVAudioTime,
        resampler: ResampleCache
    ) {
        guard let chunk = resampler.resample(buffer), !chunk.isEmpty else { return }

        lock.lock()
        let announce = !announcedFormat
        if announce { announcedFormat = true }
        if firstSampleHostSeconds == nil, when.isHostTimeValid {
            // Timestamp of the *start* of this buffer, on the host clock. That
            // is the same clock ScreenCaptureKit stamps Lane B with, so the two
            // lanes can share a timeline.
            firstSampleHostSeconds = HostClock.seconds(fromHostTime: when.hostTime)
        }
        samples.append(contentsOf: chunk)
        lock.unlock()

        // Reported from the first buffer that actually arrived, so the number on
        // screen is the format being converted rather than one predicted before
        // any audio existed. By then the level meter is redrawing itself in
        // place, so the line is cleared first (\r plus erase-to-end) or the meter
        // overwrites it on its next tick.
        if announce, let description = resampler.currentInputDescription {
            FileHandle.standardError.write(Data("\r\u{001B}[K  mic format \(description)\n".utf8))
        }

        onLevel?(AudioMath.rms(chunk))
        onSamples?(chunk)
    }
}
