import XCTest
@testable import ListnrCore

/// Regression tests for the defect that made `0.1.0-beta` unusable: a graceful
/// `/stop` was routed through the same cancel mechanism as Ctrl+C, so the
/// finished meeting was discarded instead of transcribed.
final class SessionStopStateTests: XCTestCase {

    func testStopAfterCaptureStartedDoesNotCancel() {
        let state = SessionStopState()
        state.markCaptureStarted()

        // The critical assertion: the task must NOT be cancelled, because
        // cancelling here is what threw the transcript away.
        XCTAssertFalse(state.requestStop(), "a stop during capture must not cancel the task")
        XCTAssertTrue(state.shouldFinish, "the capture loop should still exit")
        XCTAssertFalse(state.isCancel, "finalization must run, so this is not a cancel")
    }

    func testStopBeforeCaptureAbortsTheDownload() {
        let state = SessionStopState()
        // Nothing has been captured, so there is no transcript to keep and the
        // only thing running is a model download worth aborting.
        XCTAssertTrue(state.requestStop(), "a stop before capture should cancel the task")
        XCTAssertTrue(state.shouldFinish)
        XCTAssertFalse(state.isCancel, "aborting a download is still not a user cancel")
    }

    func testCancelIsACancel() {
        let state = SessionStopState()
        state.markCaptureStarted()
        state.requestCancel()
        XCTAssertTrue(state.shouldFinish)
        XCTAssertTrue(state.isCancel)
    }

    func testCancelAfterStopWins() {
        // Typing /stop and then losing patience and hitting Ctrl+C must abort.
        let state = SessionStopState()
        state.markCaptureStarted()
        state.requestStop()
        state.requestCancel()
        XCTAssertTrue(state.isCancel)
    }

    func testStopAfterCancelDoesNotRescueTheSession() {
        let state = SessionStopState()
        state.markCaptureStarted()
        state.requestCancel()
        state.requestStop()
        XCTAssertTrue(state.isCancel, "a cancel is not undone by a later stop")
    }

    func testCleanStateFinishesNothing() {
        let state = SessionStopState()
        XCTAssertFalse(state.shouldFinish)
        XCTAssertFalse(state.isCancel)
        XCTAssertFalse(state.captureHasStarted)
    }

    func testRepeatedStopsAreIdempotent() {
        let state = SessionStopState()
        state.markCaptureStarted()
        XCTAssertFalse(state.requestStop())
        XCTAssertFalse(state.requestStop())
        XCTAssertFalse(state.isCancel)
    }

    func testMarkCaptureStartedChangesStopBehaviour() {
        let before = SessionStopState()
        XCTAssertTrue(before.requestStop())

        let after = SessionStopState()
        after.markCaptureStarted()
        XCTAssertFalse(after.requestStop())
    }

    func testConcurrentRequestsAreSafe() {
        let state = SessionStopState()
        state.markCaptureStarted()
        let group = DispatchGroup()
        for i in 0..<200 {
            DispatchQueue.global().async(group: group) {
                if i % 2 == 0 {
                    _ = state.requestStop()
                } else {
                    _ = state.shouldFinish
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(state.shouldFinish)
        XCTAssertFalse(state.isCancel)
    }
}
