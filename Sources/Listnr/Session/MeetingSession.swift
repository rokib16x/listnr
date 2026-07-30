import Foundation

/// In-memory meeting transcript + Markdown export (M4 foundation; used from M2+).
final class MeetingSession {
    static let shared = MeetingSession()

    private(set) var lines: [TranscriptLine] = []
    private(set) var startedAt = Date()
    private let lock = NSLock()

    func replace(lines: [TranscriptLine]) {
        lock.lock()
        self.lines = lines
        self.startedAt = Date()
        lock.unlock()
    }

    func append(_ line: TranscriptLine) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func exportMarkdown(to directory: URL? = nil) throws -> String {
        lock.lock()
        let snapshot = lines
        let when = startedAt
        lock.unlock()

        let dir = directory ?? Self.defaultMeetingsDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "listnr_\(formatter.string(from: when)).md"
        let url = dir.appendingPathComponent(name)

        var md = "# Listnr meeting\n\n"
        md += "_Recorded \(when.formatted())_\n\n"
        for line in snapshot {
            let stamp = String(format: "%02d:%02d", Int(line.startSeconds) / 60, Int(line.startSeconds) % 60)
            md += "- **[\(stamp)] \(line.speaker):** \(line.text)\n"
        }

        try md.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    static func defaultMeetingsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Listnr", isDirectory: true)
    }
}
