import XCTest
@testable import ListnrCore

final class WAVWriterTests: XCTestCase {
    private func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    private func readLE16(_ data: Data, _ offset: Int) -> UInt16 {
        data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    func testHeaderAndSampleRoundtrip() throws {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listnr-wavtest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.write(samples: samples, sampleRate: 16_000, to: url.path)
        let data = try Data(contentsOf: url)

        // RIFF/WAVE header.
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(readLE16(data, 22), 1, "mono")
        XCTAssertEqual(readLE32(data, 24), 16_000, "sample rate")
        XCTAssertEqual(readLE16(data, 34), 16, "bits per sample")
        XCTAssertEqual(readLE32(data, 40), UInt32(samples.count * 2), "data chunk size")
        XCTAssertEqual(data.count, 44 + samples.count * 2, "total file size")

        // Sample values, including clamping of out-of-range input.
        var read: [Int16] = []
        for i in 0..<samples.count {
            read.append(Int16(bitPattern: readLE16(data, 44 + i * 2)))
        }
        XCTAssertEqual(read[0], 0)
        XCTAssertEqual(read[1], Int16(0.5 * 32767.0))
        XCTAssertEqual(read[2], Int16(-0.5 * 32767.0))
        XCTAssertEqual(read[3], 32767)
        XCTAssertEqual(read[4], -32767)
        XCTAssertEqual(read[5], 32767, "clamped high")
        XCTAssertEqual(read[6], -32767, "clamped low")
    }
}
