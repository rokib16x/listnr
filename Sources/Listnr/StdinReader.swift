import Foundation

/// Single owner of standard input for the whole process.
///
/// The shell needs to read commands at the prompt *and* watch for `q` / `/stop`
/// while a session is live and the main thread is busy pumping the run loop.
/// Doing that with a blocking `readLine()` on the main thread plus a
/// `FileHandle.readabilityHandler` means two readers on one descriptor: the
/// handler calls `availableData` and can swallow a line the prompt was about to
/// read, and there is no way to put it back.
///
/// So exactly one thread reads stdin, forever. Lines go to the live handler when
/// one is installed, and are buffered for the prompt otherwise. A line the live
/// handler does not consume is buffered too, so typing ahead during a session is
/// not lost.
final class StdinReader: @unchecked Sendable {
    /// Return `true` if the line was consumed; `false` to leave it for the prompt.
    typealias LiveHandler = (String) -> Bool

    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var buffered: [String] = []
    private var liveHandler: LiveHandler?
    private var reachedEOF = false
    private var started = false

    func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "listnr.stdin"
        thread.start()
    }

    private func loop() {
        while let line = readLine(strippingNewline: true) {
            lock.lock()
            let handler = liveHandler
            lock.unlock()

            if let handler, handler(line) { continue }

            lock.lock()
            buffered.append(line)
            lock.unlock()
            ready.signal()
        }

        lock.lock()
        reachedEOF = true
        lock.unlock()
        ready.signal()
    }

    /// Block until a line is available. Returns nil at end of input.
    func nextLine() -> String? {
        while true {
            lock.lock()
            if let line = buffered.first {
                buffered.removeFirst()
                lock.unlock()
                return line
            }
            let done = reachedEOF
            lock.unlock()
            if done { return nil }
            ready.wait()
        }
    }

    /// Route incoming lines to `handler` until it is cleared.
    func setLiveHandler(_ handler: LiveHandler?) {
        lock.lock()
        liveHandler = handler
        lock.unlock()
    }
}
