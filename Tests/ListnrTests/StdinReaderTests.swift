import XCTest
@testable import listnr

/// One thread owns stdin for the whole process; these cover the buffering and
/// hand-off rules that let the prompt and a live session share it without
/// either swallowing the other's line.
final class StdinReaderTests: XCTestCase {

    /// A line source that hands out `lines` and then reports end of input.
    private func source(_ lines: [String]) -> @Sendable () -> String? {
        let remaining = Remaining(lines)
        return { remaining.next() }
    }

    private final class Remaining: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String]
        init(_ items: [String]) { self.items = items }
        func next() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return items.isEmpty ? nil : items.removeFirst()
        }
    }

    func testLinesArriveInOrder() {
        let reader = StdinReader(source: source(["one", "two", "three"]))
        reader.start()
        XCTAssertEqual(reader.nextLine(), "one")
        XCTAssertEqual(reader.nextLine(), "two")
        XCTAssertEqual(reader.nextLine(), "three")
        XCTAssertNil(reader.nextLine(), "end of input")
    }

    func testNilAtEndOfInputIsSticky() {
        let reader = StdinReader(source: source([]))
        reader.start()
        XCTAssertNil(reader.nextLine())
        XCTAssertNil(reader.nextLine())
    }

    func testLiveHandlerConsumesLines() {
        let seen = Collected()
        let reader = StdinReader(source: source(["/stop", "after"]))
        reader.setLiveHandler { line in
            // Consume only the stop command, exactly as the shell does.
            guard Shell.isStopCommand(line) else { return false }
            seen.append(line)
            return true
        }
        reader.start()

        // "/stop" was consumed by the handler, so the prompt sees only "after".
        XCTAssertEqual(reader.nextLine(), "after")
        XCTAssertEqual(seen.values, ["/stop"])
    }

    func testUnconsumedLinesAreBufferedForThePrompt() {
        // Typing ahead during a live session must not lose input.
        let reader = StdinReader(source: source(["notes for later", "q"]))
        let seen = Collected()
        reader.setLiveHandler { line in
            guard Shell.isStopCommand(line) else { return false }
            seen.append(line)
            return true
        }
        reader.start()

        XCTAssertEqual(reader.nextLine(), "notes for later")
        XCTAssertEqual(seen.values, ["q"])
    }

    func testClearingTheHandlerReturnsLinesToThePrompt() {
        let reader = StdinReader(source: source(["first"]))
        reader.setLiveHandler { _ in true }
        reader.setLiveHandler(nil)
        reader.start()
        XCTAssertEqual(reader.nextLine(), "first")
    }

    func testDoubleStartDoesNotDuplicateLines() {
        let reader = StdinReader(source: source(["only"]))
        reader.start()
        reader.start()
        XCTAssertEqual(reader.nextLine(), "only")
        XCTAssertNil(reader.nextLine(), "a second reader thread would have raced here")
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ s: String) {
            lock.lock()
            items.append(s)
            lock.unlock()
        }
        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }
}
