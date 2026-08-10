// @preconcurrency: AVFAudio predates Sendable annotations, and older Swift
// toolchains (like CI's) flag its types crossing isolation without it.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Lane B, the speaker / system audio, via ScreenCaptureKit (app-agnostic).
/// Anything playing through the Mac's output (Discord, Zoom, browser, ...) lands here.
/// Samples are converted to 16 kHz mono Float32 and never mixed with the mic lane.
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

    // An instance property, not a static: AVAudioFormat's Sendable status
    // differs across SDK versions, and a shared static trips strict
    // concurrency on the older ones.
    private let targetFormat = AVAudioFormat(
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
    /// Touched only on `sampleQueue`, which ScreenCaptureKit serialises.
    private lazy var resampler = ResampleCache(targetFormat: targetFormat)
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
        // Minimal video footprint; we only consume .audio output.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        sampleQueue.sync {
            samples.removeAll(keepingCapacity: true)
            resampler = ResampleCache(targetFormat: targetFormat)
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
            let captured = samples
            samples.removeAll(keepingCapacity: true)
            return captured
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning else { return }

        // Already on sampleQueue, so converter state is single-threaded here.
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
    /// Resampling goes through `AVAudioConverter` rather than hand-rolled
    /// interpolation. That matters: decimating 48 kHz to 16 kHz is a 3:1 ratio,
    /// and without a lowpass everything above 8 kHz folds back into the speech
    /// band as aliasing, degrading both Whisper's transcription and SpeakerKit's
    /// embeddings on the lane that carries every remote voice. The converter also
    /// handles the stereo to mono downmix, so no channel is discarded.
    ///
    /// Must run on `sampleQueue`.
    private func mono16k(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        var asbd = asbdPtr.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return nil }

        // Ask how large the buffer list has to be before filling it. The stream is
        // non-interleaved, so stereo arrives as two AudioBuffers, and a list sized
        // for one makes the call fail outright rather than truncate.
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        ) == noErr, listSize > 0 else { return nil }

        let storage = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { storage.deallocate() }
        let listPtr = storage.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        // `blockBuffer` owns the samples, so it has to outlive every read of the
        // wrapper below.
        return withExtendedLifetime(blockBuffer) { () -> [Float]? in
            // Wrap the filled list. This must not be an AVAudioPCMBuffer created
            // with `frameCapacity:` whose `mutableAudioBufferList` is then pointed
            // at the block buffer: rewriting those `mData` pointers does not change
            // what `floatChannelData` returns, and `floatChannelData` is what
            // AVAudioConverter reads. That combination converted the buffer's own
            // untouched allocation on every call, so Lane B produced digital
            // silence — full duration, no error, no remote speaker ever
            // transcribed. `bufferListNoCopy:` is the initialiser meant for this.
            guard let inBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: listPtr
            ) else { return nil }

            return resampler.resample(inBuffer)
        }
    }
}
