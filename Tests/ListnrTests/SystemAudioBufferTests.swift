@preconcurrency import AVFoundation
import XCTest
@testable import ListnrCore

/// Lane B — the speaker lane, the reason this tool exists — captured digital
/// silence for its entire history. Sessions reported minutes of system audio,
/// ScreenCaptureKit raised no error, the dumped WAV measured -91 dB, and no
/// remote speaker was ever transcribed.
///
/// The cause was how the captured samples reached `AVAudioConverter`.
/// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` fills an
/// `AudioBufferList` with pointers into a `CMBlockBuffer`. The old code created an
/// `AVAudioPCMBuffer` with `frameCapacity:` and passed that buffer's
/// `mutableAudioBufferList` in to be filled — but rewriting those `mData`
/// pointers does not change what `floatChannelData` returns, and
/// `floatChannelData` is what the converter reads. So every conversion read the
/// buffer's own untouched, zeroed allocation.
///
/// These tests pin both halves: that the initialiser meant for this preserves the
/// signal, and that the pattern which failed really does read zeros.
final class SystemAudioBufferTests: XCTestCase {

    private let inputRate: Double = 48_000
    private let channels = 2
    private let frames = 960   // one ScreenCaptureKit buffer

    /// ScreenCaptureKit delivers non-interleaved float, so stereo arrives as two
    /// separate buffers. Anything that assumes one silently misses the second.
    private func nonInterleavedFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!
    }

    private func targetFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    /// Build a buffer list holding a tone, laid out the way ScreenCaptureKit does:
    /// one `AudioBuffer` per channel, pointing at memory we own.
    private func makeToneBufferList() -> (
        list: UnsafeMutablePointer<AudioBufferList>,
        free: () -> Void
    ) {
        let listSize = MemoryLayout<AudioBufferList>.size
            + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let listStorage = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        let listPtr = listStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        listPtr.pointee.mNumberBuffers = UInt32(channels)

        var channelStorage: [UnsafeMutablePointer<Float>] = []
        let byteCount = frames * MemoryLayout<Float>.size
        let step = 2 * Float.pi * 440 / Float(inputRate)

        let list = UnsafeMutableAudioBufferListPointer(listPtr)
        for c in 0..<channels {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for f in 0..<frames { data[f] = sin(step * Float(f)) * 0.5 }
            channelStorage.append(data)
            list[c] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteCount),
                mData: UnsafeMutableRawPointer(data)
            )
        }

        return (listPtr, {
            for p in channelStorage { p.deallocate() }
            listStorage.deallocate()
        })
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// The fix: wrap the filled list, do not alias a buffer's private storage.
    func testWrappingTheBufferListPreservesTheSignal() throws {
        let (listPtr, free) = makeToneBufferList()
        defer { free() }

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: nonInterleavedFormat(),
            bufferListNoCopy: listPtr
        ))

        XCTAssertEqual(Int(buffer.frameLength), frames)

        // Read back through floatChannelData, which is what the converter uses.
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        var peak: Float = 0
        for c in 0..<channels {
            for f in 0..<frames { peak = max(peak, abs(channelData[c][f])) }
        }
        XCTAssertGreaterThan(peak, 0.4, "the wrapper must see the samples the list points at")
    }

    /// The bug, pinned. If this ever starts passing with a non-zero peak, Apple
    /// changed the semantics and the comment in SystemAudioCapture is stale — but
    /// until then, this is why Lane B was silent.
    func testAliasingAnAllocatedBufferReadsZeros() throws {
        let (listPtr, free) = makeToneBufferList()
        defer { free() }

        let format = nonInterleavedFormat()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ))
        buffer.frameLength = AVAudioFrameCount(frames)

        // Exactly what the old code did: point the buffer's own list at the
        // captured samples.
        let ownList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let source = UnsafeMutableAudioBufferListPointer(listPtr)
        for c in 0..<channels { ownList[c] = source[c] }

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        var peak: Float = 0
        for c in 0..<channels {
            for f in 0..<frames { peak = max(peak, abs(channelData[c][f])) }
        }
        XCTAssertEqual(peak, 0, "rewriting mData does not change floatChannelData")
    }

    /// The end-to-end shape of what Lane B does per buffer: wrap, then resample to
    /// 16 kHz mono. Silence out of this is the failure the whole file is about.
    func testCapturedBufferResamplesToAudibleMono() throws {
        let (listPtr, free) = makeToneBufferList()
        defer { free() }

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: nonInterleavedFormat(),
            bufferListNoCopy: listPtr
        ))

        let cache = ResampleCache(targetFormat: targetFormat())
        let out = try XCTUnwrap(cache.resample(buffer))

        XCTAssertFalse(out.isEmpty)
        XCTAssertGreaterThan(rms(out), 0.1, "Lane B must not resample a tone into silence")
    }

    /// A list sized for one AudioBuffer cannot describe non-interleaved stereo,
    /// which is why the size has to be requested rather than assumed.
    func testStereoNeedsMoreThanOneAudioBuffer() {
        let oneBuffer = MemoryLayout<AudioBufferList>.size
        let twoBuffers = oneBuffer + MemoryLayout<AudioBuffer>.size
        XCTAssertGreaterThan(twoBuffers, oneBuffer)
    }
}
