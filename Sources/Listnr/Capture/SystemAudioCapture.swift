import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Lane B — speaker / system audio via ScreenCaptureKit (app-agnostic).
/// Anything playing through the Mac’s output (Discord, Zoom, browser, …) lands here.
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

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "listnr.system-audio", qos: .userInitiated)
    private var samples: [Float] = []
    private var isRecording = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    var onLevel: ((Float) -> Void)?
    var onSamples: (([Float]) -> Void)?

    var isRunning: Bool { isRecording }

    func start() async throws {
        guard !isRecording else { return }

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
        }

        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.startFailed(error)
        }

        self.stream = stream
        isRecording = true
    }

    @discardableResult
    func stop() async -> [Float] {
        guard isRecording else { return [] }
        isRecording = false

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        converter = nil
        targetFormat = nil

        return sampleQueue.sync {
            let captured = samples
            samples.removeAll(keepingCapacity: true)
            return captured
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording else { return }
        guard let chunk = Self.floatMono16k(from: sampleBuffer, converter: &converter, targetFormat: &targetFormat),
              !chunk.isEmpty
        else { return }

        // Already on sampleQueue.
        samples.append(contentsOf: chunk)
        onLevel?(AudioMath.rms(chunk))
        onSamples?(chunk)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("system audio stream stopped: \(error.localizedDescription)\n".utf8))
        isRecording = false
    }

    // MARK: - PCM extract + resample

    private static func floatMono16k(
        from sampleBuffer: CMSampleBuffer,
        converter: inout AVAudioConverter?,
        targetFormat: inout AVAudioFormat?
    ) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        let asbd = asbdPtr.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate
        guard channels > 0, sampleRate > 0 else { return nil }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, length > 0
        else { return nil }

        // ScreenCaptureKit typically delivers non-interleaved Float32 or interleaved Float32.
        let frameCount: Int
        let mono: [Float]

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatCount = length / MemoryLayout<Float>.size
            let floats = UnsafeBufferPointer(
                start: UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: floatCount),
                count: floatCount
            )
            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                frameCount = floatCount / channels
                // First channel plane.
                mono = Array(floats.prefix(frameCount))
            } else {
                frameCount = floatCount / channels
                var out = [Float]()
                out.reserveCapacity(frameCount)
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channels {
                        sum += floats[i * channels + ch]
                    }
                    out.append(sum / Float(channels))
                }
                mono = out
            }
        } else {
            // 16-bit PCM interleaved fallback.
            let shortCount = length / MemoryLayout<Int16>.size
            let shorts = UnsafeBufferPointer(
                start: UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: shortCount),
                count: shortCount
            )
            frameCount = shortCount / max(channels, 1)
            var out = [Float]()
            out.reserveCapacity(frameCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += Float(shorts[i * channels + ch]) / 32768.0
                }
                out.append(sum / Float(channels))
            }
            mono = out
        }

        if abs(sampleRate - targetSampleRate) < 1 {
            return mono
        }

        return AudioMath.resampleLinear(mono, from: sampleRate, to: targetSampleRate)
    }
}
