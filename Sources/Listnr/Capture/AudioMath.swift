import Foundation

enum AudioMath {
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s * s) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// Simple linear resampler (good enough for STT preprocess).
    static func resampleLinear(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard !input.isEmpty, from > 0, to > 0 else { return input }
        if abs(from - to) < 0.5 { return input }

        let ratio = to / from
        let outCount = max(1, Int((Double(input.count) * ratio).rounded()))
        var output = [Float](repeating: 0, count: outCount)
        let last = input.count - 1

        for i in 0..<outCount {
            let src = Double(i) / ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, last)
            let t = Float(src - Double(i0))
            output[i] = input[i0] * (1 - t) + input[i1] * t
        }
        return output
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
