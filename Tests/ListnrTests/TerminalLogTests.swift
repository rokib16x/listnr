import XCTest
@testable import ListnrCore

/// The level meter repaints in place, so anything written while it is on screen
/// lands in the middle of its last paint. A live transcript line arriving
/// mid-tick came out as `[00:01] You      do both=0.000`, with the tail of
/// `sys=0.000` still attached — the transcript on screen was corrupted while the
/// saved file was fine, which is what made it look harmless.
final class TerminalLogTests: XCTestCase {

    func testClearsTheMeterBeforeWriting() {
        let out = TerminalLog.clearing("[00:01] You      hello")
        XCTAssertTrue(out.hasPrefix("\r\u{001B}[K"), "must return to column 0 and erase")
        XCTAssertTrue(out.contains("[00:01] You      hello"))
    }

    /// The erase has to come after the carriage return, or it clears the wrong
    /// part of the line and leaves the meter's tail in place.
    func testCarriageReturnPrecedesTheErase() {
        let out = TerminalLog.clearing("x")
        let cr = try? XCTUnwrap(out.firstIndex(of: "\r"))
        let esc = try? XCTUnwrap(out.firstIndex(of: "\u{001B}"))
        XCTAssertNotNil(cr)
        XCTAssertNotNil(esc)
        XCTAssertLessThan(cr!, esc!)
    }

    func testEndsWithExactlyOneNewline() {
        let out = TerminalLog.clearing("hello")
        XCTAssertTrue(out.hasSuffix("hello\n"))
        XCTAssertFalse(out.hasSuffix("\n\n"))
    }

    /// Callers pass multi-line warnings; only the first line shares the row with
    /// the meter, so only it needs clearing.
    func testMultiLineMessagesAreClearedOnceAtTheStart() {
        let out = TerminalLog.clearing("first\n  second\n  third")
        XCTAssertEqual(out.components(separatedBy: TerminalLog.clearLine).count - 1, 1)
        XCTAssertTrue(out.hasSuffix("third\n"))
    }

    func testEmptyMessageStillClearsTheLine() {
        XCTAssertEqual(TerminalLog.clearing(""), "\(TerminalLog.clearLine)\n")
    }

    /// A caller that already ended its text with a newline would otherwise
    /// produce a blank line in the middle of a session.
    func testDoesNotDoubleUpOnACallerSuppliedNewline() {
        let out = TerminalLog.clearing("hello")
        XCTAssertEqual(out.filter { $0 == "\n" }.count, 1)
    }
}
