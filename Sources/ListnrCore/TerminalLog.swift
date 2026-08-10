import Foundation

/// Writes a line to stderr without leaving the level meter's debris behind it.
///
/// The meter repaints in place — carriage return, erase to end of line, no
/// newline — so anything else written while it is on screen lands in the middle
/// of whatever it last painted. A live transcript line arriving mid-tick came out
/// as `[00:01] You      do both=0.000`, with the tail of `sys=0.000` still there.
/// The saved transcript was correct, which made it look cosmetic until you try to
/// read a meeting off the screen.
///
/// Erasing to end of line first is all that is needed: the meter repaints itself
/// on its next tick, below whatever was written.
enum TerminalLog {
    /// The escape sequence that puts the cursor at the start of the current line
    /// and clears it.
    static let clearLine = "\r\u{001B}[K"

    /// The bytes `line(_:)` writes, exposed so the behaviour can be asserted
    /// without capturing a file descriptor.
    static func clearing(_ text: String) -> String {
        "\(clearLine)\(text)\n"
    }

    /// Write one message, clearing the meter first. Pass text without a trailing
    /// newline; multi-line messages are fine.
    static func line(_ text: String) {
        FileHandle.standardError.write(Data(clearing(text).utf8))
    }
}
