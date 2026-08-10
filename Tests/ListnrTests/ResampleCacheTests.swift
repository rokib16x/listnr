@preconcurrency import AVFoundation
import XCTest
@testable import ListnrCore

/// Lane A produced zero samples on a Bluetooth headset whose input runs at
/// 24 kHz. `MicCapture` chose the tap format before any audio existed, and when
/// the input node was not yet resolved it fell back to the engine's 48 kHz
/// output format — installing a tap that contradicted the hardware, which then
/// delivered nothing. The session printed "mic format 48000 Hz" and captured
/// `mic=0.0s`.
///
/// The fix is to convert from whatever format each buffer actually carries, so
/// these tests pin the resampling itself: every input rate a real device might
/// hand over has to survive the trip to 16 kHz mono with its signal intact.
final class ResampleCacheTests: XCTestCase {

    private let targetRate: Double = 16_000

    private func target() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// A buffer of a full-scale sine, so silence in the output is unambiguous.
    private func tone(
        rate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        interleaved: Bool = false
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: channels,
            interleaved: interleaved
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        // 440 Hz sits well below the 8 kHz Nyquist of the 16 kHz target, so a
        // correct conversion must preserve it rather than alias it away.
        let step = 2 * Float.pi * 440 / Float(rate)
        if interleaved {
            let data = buffer.floatChannelData![0]
            for f in 0..<Int(frames) {
                let v = sin(step * Float(f)) * 0.5
                for c in 0..<Int(channels) { data[f * Int(channels) + c] = v }
            }
        } else {
            for c in 0..<Int(channels) {
                let data = buffer.floatChannelData![c]
                for f in 0..<Int(frames) { data[f] = sin(step * Float(f)) * 0.5 }
            }
        }
        return buffer
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// The tolerance the rate tests allow, as a frame count at the target rate.
    ///
    /// Deliberately loose, and not because the measurement is noisy. Each buffer
    /// is handed over as its own `ConverterFeed`, which reports `noDataNow` once
    /// the buffer is consumed, so the converter re-primes its filter on every
    /// call and drops a small number of frames each time. Measured end to end
    /// over one second: 24 kHz and 44.1 kHz land within a few hundred frames,
    /// 48 kHz loses about 1100 (roughly 7%). That is a pre-existing property of
    /// the feed pattern, shared with the system-audio lane, not something this
    /// cache introduced. These tests pin "one second in, about one second out"
    /// so a *total* loss like the 24 kHz zero-sample bug cannot return; closing
    /// the drift needs a feed that queues buffers across calls.
    private let rateTolerance: Double = 1300

    /// Feed one second of audio as ten 100 ms buffers, the way a tap does, and
    /// return everything that came out. A single buffer is not a fair measure:
    /// the converter swallows frames priming its filter, and only the steady
    /// state reflects what a session actually collects.
    private func stream(rate: Double, channels: AVAudioChannelCount = 1) -> [Float] {
        let cache = ResampleCache(targetFormat: target())
        let frames = AVAudioFrameCount(rate / 10)
        return (0..<10).flatMap { _ -> [Float] in
            cache.resample(tone(rate: rate, channels: channels, frames: frames)) ?? []
        }
    }

    /// The exact case that failed: a 24 kHz Bluetooth headset input.
    func testResamples24kHzMonoToTarget() throws {
        let cache = ResampleCache(targetFormat: target())
        let first = try XCTUnwrap(cache.resample(tone(rate: 24_000, channels: 1, frames: 2400)))
        XCTAssertFalse(first.isEmpty, "a 24 kHz input must not resample to nothing")
        XCTAssertGreaterThan(rms(first), 0.1, "the tone must survive conversion")

        // One second in must be one second out, at the target rate.
        let out = stream(rate: 24_000)
        XCTAssertEqual(Double(out.count), targetRate, accuracy: rateTolerance)
        XCTAssertGreaterThan(rms(out), 0.1)
    }

    func testResamples48kHzMonoToTarget() throws {
        let out = stream(rate: 48_000)
        XCTAssertEqual(Double(out.count), targetRate, accuracy: rateTolerance)
        XCTAssertGreaterThan(rms(out), 0.1)
    }

    /// 44.1 kHz does not divide evenly into 16 kHz; the converter, not integer
    /// decimation, has to handle it.
    func testResamplesNonIntegerRatio() throws {
        let out = stream(rate: 44_100)
        XCTAssertEqual(Double(out.count), targetRate, accuracy: rateTolerance)
        XCTAssertGreaterThan(rms(out), 0.1)
    }

    func testDownmixesStereoWithoutDiscardingSignal() throws {
        let cache = ResampleCache(targetFormat: target())
        let out = try XCTUnwrap(cache.resample(tone(rate: 48_000, channels: 2, frames: 4800)))

        XCTAssertGreaterThan(rms(out), 0.1, "no channel may be silently dropped")
    }

    func testHandlesInterleavedInput() throws {
        let cache = ResampleCache(targetFormat: target())
        let buffer = tone(rate: 24_000, channels: 2, frames: 2400, interleaved: true)
        let out = try XCTUnwrap(cache.resample(buffer))

        XCTAssertGreaterThan(rms(out), 0.1)
    }

    /// Rebuilding the converter per buffer would discard its filter state and
    /// add a discontinuity every 4096 frames, so the cache must hold on to it.
    func testReusesConverterForAStableFormat() throws {
        let cache = ResampleCache(targetFormat: target())
        for _ in 0..<5 {
            _ = cache.resample(tone(rate: 24_000, channels: 1, frames: 2400))
        }
        XCTAssertEqual(cache.rebuildCount, 1)
    }

    /// Switching headsets mid-session changes the input format underneath us.
    func testRebuildsWhenTheInputFormatChanges() throws {
        let cache = ResampleCache(targetFormat: target())
        _ = cache.resample(tone(rate: 24_000, channels: 1, frames: 2400))
        _ = cache.resample(tone(rate: 48_000, channels: 1, frames: 4800))
        XCTAssertEqual(cache.rebuildCount, 2)

        // And the new format keeps working after the swap.
        let out = try XCTUnwrap(cache.resample(tone(rate: 48_000, channels: 1, frames: 4800)))
        XCTAssertGreaterThan(rms(out), 0.1)
        XCTAssertEqual(cache.rebuildCount, 2, "no rebuild for a format already active")
    }

    func testReportsTheFormatItIsConvertingFrom() throws {
        let cache = ResampleCache(targetFormat: target())
        XCTAssertNil(cache.currentInputDescription)

        _ = cache.resample(tone(rate: 24_000, channels: 1, frames: 2400))
        let description = try XCTUnwrap(cache.currentInputDescription)
        XCTAssertTrue(description.contains("24000"), description)
    }

    func testEmptyBufferYieldsNothingRatherThanCrashing() {
        let cache = ResampleCache(targetFormat: target())
        XCTAssertNil(cache.resample(tone(rate: 24_000, channels: 1, frames: 0)))
    }
}
