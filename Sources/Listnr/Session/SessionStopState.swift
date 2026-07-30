import Foundation

/// The stop-versus-cancel decision for one session.
///
/// This lives apart from `LiveSessionRunner` because the distinction it encodes
/// is the one that broke in `0.1.0-beta`, and the runner itself cannot be
/// exercised without a microphone. Keeping the rule here makes it testable.
///
/// The rule: a **graceful stop** ends capture and keeps the transcript, while a
/// **cancel** throws the session away. The only exception is a stop that
/// arrives before capture has begun, where there is no transcript to keep and
/// the only thing running is a model download, so the task is aborted instead.
final class SessionStopState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var cancelRequested = false
    private var captureStarted = false

    /// Request a graceful finish.
    ///
    /// Returns `true` when the caller should also cancel the underlying task,
    /// which is the case only before capture started. Cancelling after that
    /// point is what discarded finished meetings.
    @discardableResult
    func requestStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stopRequested = true
        return !captureStarted
    }

    /// Request an abort. The transcript is discarded.
    func requestCancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    /// Called once capture is live, after which a graceful stop must not cancel.
    func markCaptureStarted() {
        lock.lock()
        captureStarted = true
        lock.unlock()
    }

    /// True when the capture loop should exit, for either reason.
    var shouldFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested || cancelRequested
    }

    /// True only for an abort. A graceful stop never sets this, which is what
    /// lets finalization run.
    var isCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    var captureHasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureStarted
    }
}
