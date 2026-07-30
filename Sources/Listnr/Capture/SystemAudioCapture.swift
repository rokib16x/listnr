import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Lane B — speaker / system audio via ScreenCaptureKit (app-agnostic).
/// Anything playing through the Mac's output (Discord, Zoom, browser, …) lands here.
/// Samples are converted to 16 kHz mono Float32 — never mixed with the mic lane.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: Error, LocalizedError {
        case noDisplay
        case streamCreateFailed
        case startFailed(Error)
        case notRunning

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "no display available for system audio capture"
            case .streamCreateFailed: return "failed to create SCStream"
            case .startFailed(let e): return "system audio start failed: \(e.localizedDescription)"
            case .notRunning: return "system audio capture is not running"
            }
        }
    }

    static let nativeSampleRate = 48_000
    static let targetSampleRate: Double = 16_000

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SystemAudioCapture.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "listnr.system-audio", qos: .userInitiated)
    private var samples: [Float] = []
    private let stateLock = NSLock()
    private var recording = false
    /// Touched only on `sampleQueue`.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var firstSampleHostSeconds: Double?

    var onLevel: ((Float) -> Void)?
    var onSamples: (([Float]) -> Void)?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recording
    }

    /// Host-clock time of the first captured sample, or nil if nothing arrived.
    /// Used to place this lane on the shared session timeline.
    var firstSampleTime: Double? {
        sampleQueue.sync { firstSampleHostSeconds }
    }

    private func setRecording(_ value: Bool) {
        stateLock.lock()
        recording = value
        stateLock.unlock()
    }

    func start() async throws {
        guard !isRunning else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.nativeSampleRate
        config.channelCount = 2
        // Minimal video footprint — we only consume .audio output.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        sampleQueue.sync {
            samples.removeAll(keepingCapacity: true)
            converter = nil
            converterInputFormat = nil
            firstSampleHostSeconds = nil
        }

        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.startFailed(error)
        }

        self.stream = stream
        setRecording(true)
    }

    @discardableResult
    func stop() async -> [Float] {
        guard isRunning else { return [] }
        setRecording(false)

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        return sampleQueue.sync {
            converter = nil
            converterInputFormat = nil
            let captured = samples
            samples.removeAll(keepingCapacity: true)
            return captured
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning else { return }

        // Already on sampleQueue — converter state is single-threaded here.
        if firstSampleHostSeconds == nil {
            // SCK presentation timestamps are on the host clock, the same clock
            // AVAudioTime.hostTime uses, so the two lanes are directly comparable.
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid, !pts.isIndefinite {
                firstSampleHostSeconds = CMTimeGetSeconds(pts)
            }
        }

        guard let chunk = mono16k(from: sampleBuffer), !chunk.isEmpty else { return }

        samples.append(contentsOf: chunk)
        onLevel?(AudioMath.rms(chunk))
        onSamples?(chunk)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("system audio stream stopped: \(error.localizedDescription)\n".utf8))
        setRecording(false)
    }

    // MARK: - PCM extract + resample

    /// Convert one ScreenCaptureKit audio buffer to 16 kHz mono Float32.
    ///
    /// Uses `AVAudioConverter` rather than hand-rolled interpolation. That
    /// matters: decimating 48 kHz → 16 kHz is a 3:1 ratio, and without a
    /// lowpass everything above 8 kHz folds back into the speech band as
    /// aliasing distortion — degrading both Whisper's transcription and
    /// SpeakerKit's embeddings, on the lane that carries every remote voice.
    /// The converter also handles the stereo → mono downmix, so no channel is
    /// silently discarded.
    ///
    /// Must run on `sampleQueue`.
    private func mono16k(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        var asbd = asbdPtr.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
            converterInputFormat = inputFormat
            if converter == nil {
                FileHandle.standardError.write(Data(
                    "system audio: cannot convert \(inputFormat) to 16 kHz mono\n".utf8
                ))
                return nil
            }
        }
        guard let converter else { return nil }

        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return nil }
        inBuffer.frameLength = AVAudioFrameCount(frames)

        // Point the PCM buffer's AudioBufferList at the sample buffer's data
        // instead of copying. `blockBuffer` owns that memory, so it has to stay
        // alive for as long as `inBuffer` is read — hence withExtendedLifetime
        // around the conversion below.
        let audioBufferList = inBuffer.mutableAudioBufferList
        guard audioBufferList.pointee.mNumberBuffers > 0 else { return nil }
        let listSize = MemoryLayout<AudioBufferList>.size
            + Int(audioBufferList.pointee.mNumberBuffers - 1) * MemoryLayout<AudioBuffer>.size

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        return withExtendedLifetime(blockBuffer) { () -> [Float]? in
            let ratio = Self.targetSampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.targetFormat,
                frameCapacity: capacity
            ) else { return nil }

            let feed = ConverterFeed(inBuffer)
            var error: NSError?
            let result = converter.convert(to: outBuffer, error: &error, withInputFrom: feed.inputBlock)
            guard result != .error, let channelData = outBuffer.floatChannelData else {
                if let error {
                    FileHandle.standardError.write(Data(
                        "system audio convert failed: \(error.localizedDescription)\n".utf8
                    ))
                }
                return nil
            }

            let count = Int(outBuffer.frameLength)
            guard count > 0 else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: count))
        }
    }
}
