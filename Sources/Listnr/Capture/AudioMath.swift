import Foundation

enum AudioMath {
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s * s) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// Peak absolute sample value. Cheap clipping check.
    static func peak(_ samples: [Float]) -> Float {
        var m: Float = 0
        for s in samples { m = max(m, abs(s)) }
        return m
    }
}

/// Converts mach absolute times to seconds on the host clock.
///
/// Both capture lanes report the timestamp of their first sample on this clock —
/// `AVAudioTime.hostTime` for the mic and the presentation timestamp for
/// ScreenCaptureKit — which is what lets their transcripts share one timeline.
enum HostClock {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(fromHostTime hostTime: UInt64) -> Double {
        Double(hostTime) * scale
    }

    static func now() -> Double {
        seconds(fromHostTime: mach_absolute_time())
    }
}

enum WAVWriter {
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))
        data.append(uint16LE(1))
        data.append(uint16LE(1))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))
        data.append(uint16LE(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}
