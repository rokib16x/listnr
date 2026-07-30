import XCTest
@testable import listnr

/// Drives the per-lane pipeline (audio → VAD → ASR → lines) with a fake
/// transcriber, so the ordering and teardown guarantees are tested without
/// models or hardware.
actor FakeTranscriber: Transcriber {
    let modelID = "fake"
    private(set) var calls = 0
    private let texts: [String]

    /// Returns `texts[n]` for the n-th call, repeating the last entry.
    init(texts: [String] = ["hello"]) {
        self.texts = texts
    }

    func warmUp() async throws {}

    func transcribe(_ audio: [Float]) async throws -> String {
        let text = texts[min(calls, texts.count - 1)]
        calls += 1
        return text
    }
}

final class LaneTranscriberTests: XCTestCase {
    private let sampleRate = 16_000.0

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    private func push(_ audio: [Float], into lane: LaneTranscriber) {
        var index = 0
        while index < audio.count {
            let end = min(index + 1024, audio.count)
            lane.push(Array(audio[index..<end]))
            index = end
        }
    }

    func testUtteranceFlowsThroughPipeline() async {
        let lane = LaneTranscriber(
            speakerLabel: "You",
            transcriber: FakeTranscriber(),
            speechThreshold: 0.01,
            minSegmentRMS: 0.01
        )
        push(silence(seconds: 1) + tone(seconds: 0.5, amplitude: 0.1) + silence(seconds: 1.5), into: lane)
        let lines = await lane.finish()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].speaker, "You")
        XCTAssertEqual(lines[0].text, "hello")
    }

    func testLinesKeepCaptureOrder() async {
        let lane = LaneTranscriber(
            speakerLabel: "Others",
            transcriber: FakeTranscriber(texts: ["first", "second"]),
            speechThreshold: 0.01,
            minSegmentRMS: 0.01
        )
        push(
            silence(seconds: 1)
                + tone(seconds: 0.5, amplitude: 0.1)
                + silence(seconds: 2)
                + tone(seconds: 0.5, amplitude: 0.1)
                + silence(seconds: 1.5),
            into: lane
        )
        let lines = await lane.finish()
        XCTAssertEqual(lines.map(\.text), ["first", "second"], "FIFO through both stages")
        XCTAssertLessThan(lines[0].startSeconds, lines[1].startSeconds)
    }

    func testEmptyTranscriptionProducesNoLine() async {
        let lane = LaneTranscriber(
            speakerLabel: "You",
            transcriber: FakeTranscriber(texts: [""]),
            speechThreshold: 0.01,
            minSegmentRMS: 0.01
        )
        push(silence(seconds: 1) + tone(seconds: 0.5, amplitude: 0.1) + silence(seconds: 1.5), into: lane)
        let lines = await lane.finish()
        XCTAssertTrue(lines.isEmpty)
    }

    func testQuietSegmentGatedByRMSFloor() async {
        let fake = FakeTranscriber()
        let lane = LaneTranscriber(
            speakerLabel: "You",
            transcriber: fake,
            speechThreshold: 0.01,
            minSegmentRMS: 0.5   // impossibly high: nothing may reach ASR
        )
        push(silence(seconds: 1) + tone(seconds: 0.5, amplitude: 0.1) + silence(seconds: 1.5), into: lane)
        let lines = await lane.finish()
        XCTAssertTrue(lines.isEmpty)
        let calls = await fake.calls
        XCTAssertEqual(calls, 0, "segment must be dropped before the transcriber")
    }

    func testAbandonTearsDownWithoutHanging() async {
        let lane = LaneTranscriber(
            speakerLabel: "You",
            transcriber: FakeTranscriber(),
            speechThreshold: 0.01,
            minSegmentRMS: 0.01
        )
        push(silence(seconds: 1) + tone(seconds: 0.5, amplitude: 0.1), into: lane)
        lane.abandon()
        // After abandon, finish() must return promptly instead of awaiting a
        // stream that never ends. Double-teardown must also be safe.
        _ = await lane.finish()
        lane.abandon()
    }

    func testStopCommandParsing() {
        for accepted in ["q", "/q", "/stop", "stop", "  Q  ", "STOP"] {
            XCTAssertTrue(Shell.isStopCommand(accepted), accepted)
        }
        for rejected in ["quit", "exit", "hello", "/live", ""] {
            XCTAssertFalse(Shell.isStopCommand(rejected), rejected)
        }
    }
}
