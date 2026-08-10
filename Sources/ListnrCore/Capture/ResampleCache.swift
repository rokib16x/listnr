// @preconcurrency: see ConverterFeed.swift; the import must be consistent
// across the files sharing its AVFoundation-typed API.
@preconcurrency import AVFoundation
import Foundation

/// Converts capture buffers to one target format, deciding the input format
/// from the buffers themselves rather than from the device beforehand.
///
/// That distinction is the whole point. Asking a node for its format before any
/// audio has flowed is unreliable: on a Bluetooth headset the input node can
/// still be unresolved, and code that guesses a format there installs a tap the
/// hardware disagrees with, which then delivers nothing at all. Every buffer
/// carries its own format, so using that is both simpler and always right.
///
/// The converter is kept between buffers on purpose. It holds resampling filter
/// state, and rebuilding it per buffer would stitch a discontinuity into the
/// signal every few thousand frames, right in the band Whisper cares about.
///
/// `@unchecked Sendable` because an instance is confined to a single capture
/// callback thread, which AVFoundation invokes serially. Do not share one
/// across lanes.
final class ResampleCache: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    /// How many times a converter has been built. A stable device builds one.
    private(set) var rebuildCount = 0

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    /// The format currently being converted from, for logging what actually
    /// arrived instead of what was predicted.
    var currentInputDescription: String? {
        guard let inputFormat else { return nil }
        return String(
            format: "%.0f Hz · %d ch",
            inputFormat.sampleRate,
            inputFormat.channelCount
        )
    }

    /// Convert one buffer to the target format, or nil if it carries no frames
    /// or cannot be converted.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0 else { return nil }

        guard let converter = converter(for: buffer.format) else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        // The slack absorbs the converter's priming, which can emit slightly
        // more than the ratio predicts on the first buffer.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let feed = ConverterFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: feed.inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else {
            if let error {
                FileHandle.standardError.write(Data(
                    "audio convert failed: \(error.localizedDescription)\n".utf8
                ))
            }
            return nil
        }

        let count = Int(outBuffer.frameLength)
        guard count > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        if let converter, inputFormat == format { return converter }

        guard let fresh = AVAudioConverter(from: format, to: targetFormat) else {
            FileHandle.standardError.write(Data(
                "audio: cannot convert \(format) to \(targetFormat)\n".utf8
            ))
            return nil
        }
        converter = fresh
        inputFormat = format
        rebuildCount += 1
        return fresh
    }
}
