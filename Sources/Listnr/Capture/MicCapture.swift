import AVFoundation
import Foundation

/// Lane A, the microphone. Captures 16 kHz mono Float32 while running.
final class MicCapture {
    enum CaptureError: Error, LocalizedError {
        case engineStartFailed(Error)
        case converterCreationFailed
        case invalidInputFormat

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e.localizedDescription)"
            case .converterCreationFailed: return "mic converter creation failed"
            case .invalidInputFormat: return "mic input format invalid (0 channels / rate). Check System Settings → Sound → Input"
            }
        }
    }

    static let targetSampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var isRecording = false
    private var firstSampleHostSeconds: Double?
    private let lock = NSLock()

    var onLevel: ((Float) -> Void)?
    var onSamples: (([Float]) -> Void)?

    var isRunning: Bool { isRecording }

    /// Host-clock time of the first captured sample, or nil if nothing arrived.
    /// Used to place this lane on the shared session timeline.
    var firstSampleTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return firstSampleHostSeconds
    }

    func start() throws {
        guard !isRecording else { return }

        // Fresh engine after long model loads / prior sessions.
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = AVAudioEngine()

        let input = engine.inputNode
        // Prefer hardware input format after graph exists.
        engine.prepare()
        var inputFormat = input.inputFormat(forBus: 0)
        if inputFormat.channelCount == 0 || inputFormat.sampleRate < 1000 {
            inputFormat = input.outputFormat(forBus: 0)
        }
        guard inputFormat.channelCount > 0, inputFormat.sampleRate >= 1000 else {
            throw CaptureError.invalidInputFormat
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: MicCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = converter

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        firstSampleHostSeconds = nil
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            self?.process(buffer: buffer, when: when, converter: converter, targetFormat: targetFormat)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        isRecording = true
        FileHandle.standardError.write(Data(
            String(format: "  mic format %.0f Hz · %d ch\n", inputFormat.sampleRate, inputFormat.channelCount).utf8
        ))
    }

    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return captured
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        when: AVAudioTime,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return
        }

        // A box rather than a captured `var`: the input block is @Sendable, so
        // mutating captured state in it is a race under Swift 6.
        let feed = ConverterFeed(buffer)

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: feed.inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        guard count > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: count))

        lock.lock()
        if firstSampleHostSeconds == nil, when.isHostTimeValid {
            // Timestamp of the *start* of this buffer, on the host clock. That
            // is the same clock ScreenCaptureKit stamps Lane B with, so the two
            // lanes can share a timeline.
            firstSampleHostSeconds = HostClock.seconds(fromHostTime: when.hostTime)
        }
        samples.append(contentsOf: chunk)
        lock.unlock()

        onLevel?(AudioMath.rms(chunk))
        onSamples?(chunk)
    }
}
