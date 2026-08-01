import Foundation

/// Prints download progress with live %, estimated MB, file counts, speed, and ETA.
///
/// Hugging Face Hub nests per-file Progress under a parent. **`completedUnitCount`
/// only jumps when a whole file finishes**. **`fractionCompleted` updates during
/// the current file**, so always prefer that for % / MB / ETA.
///
/// Near the end, speed often drops (large LFS weight file / disk flush). ETA can
/// temporarily rise. That means the link slowed, not that progress went backwards.
final class DownloadProgressPrinter: @unchecked Sendable {
    private let label: String
    private let expectedMB: Int?
    private let startedAt = Date()
    private var lastPrintAt = Date.distantPast
    private var lastShownFraction: Double = -1
    private var smoothedRemaining: TimeInterval?
    private var lastMBShown: Double = 0
    private let lock = NSLock()

    init(label: String, expectedMB: Int? = nil) {
        self.label = label
        self.expectedMB = expectedMB
        var msg = "↓ downloading \(label)"
        if let expectedMB {
            msg += " (~\(expectedMB) MB total)"
        }
        msg += "...\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    func update(_ progress: Progress) {
        let completedFiles = progress.completedUnitCount
        let totalFiles = progress.totalUnitCount
        let looksLikeFileCount = totalFiles > 0 && totalFiles < 10_000

        let fraction = min(1, max(0, progress.fractionCompleted))
        let speedBps = progress.userInfo[.throughputKey] as? Double

        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let jumped = abs(fraction - lastShownFraction) >= 0.002
        let timed = now.timeIntervalSince(lastPrintAt) >= 0.35
        guard jumped || timed || fraction >= 0.999 else { return }
        lastPrintAt = now
        lastShownFraction = fraction

        let displayPct = fraction >= 0.999 ? 100 : min(99, Int((fraction * 100).rounded(.down)))

        var sizeText = ""
        if let expectedMB, expectedMB > 0 {
            var done = Double(expectedMB) * fraction
            // Never show MB going backwards on screen.
            done = max(done, lastMBShown)
            lastMBShown = done
            sizeText = String(format: "  %.0f/%d MB", done, expectedMB)
        }

        var filesText = ""
        if looksLikeFileCount {
            let remaining = max(0, totalFiles - completedFiles)
            if remaining <= 2, fraction < 0.999 {
                filesText = "  files \(completedFiles)/\(totalFiles) (last large file...)"
            } else if fraction < 0.999, completedFiles < totalFiles {
                filesText = "  files \(completedFiles)/\(totalFiles) (fetching...)"
            } else {
                filesText = "  files \(completedFiles)/\(totalFiles)"
            }
        }

        var speedText = ""
        if let speedBps, speedBps > 0 {
            let mbps = speedBps / 1_048_576
            if mbps >= 0.1 {
                speedText = String(format: "  %.1f MB/s", mbps)
            } else {
                speedText = String(format: "  %.0f KB/s", speedBps / 1024)
            }
        }

        var etaText = "..."
        let elapsed = now.timeIntervalSince(startedAt)
        var rawRemaining: TimeInterval?
        if let speedBps, speedBps > 0, let expectedMB, expectedMB > 0, fraction < 0.999 {
            let remainingBytes = Double(expectedMB) * 1_048_576 * (1.0 - fraction)
            rawRemaining = remainingBytes / speedBps
        } else if fraction > 0.03, elapsed > 1.0, fraction < 0.999 {
            rawRemaining = elapsed * (1.0 - fraction) / fraction
        }

        if fraction >= 0.999 {
            etaText = "finishing"
            smoothedRemaining = nil
        } else if let raw = rawRemaining {
            if let prev = smoothedRemaining {
                // Prefer falling ETA; allow only slow rises when speed tanks on last file.
                if raw <= prev {
                    smoothedRemaining = prev * 0.3 + raw * 0.7
                } else {
                    smoothedRemaining = prev * 0.92 + raw * 0.08
                }
            } else {
                smoothedRemaining = raw
            }
            if let rem = smoothedRemaining {
                if remainingFilesNearEnd(completedFiles, totalFiles), rem > 90 {
                    etaText = "finishing large file (~" + Self.formatDuration(rem) + ")"
                } else {
                    etaText = "~" + Self.formatDuration(rem) + " left"
                }
            }
        }

        // \r + clear-to-end so lines don't smear in the terminal.
        let body = String(
            format: "  %3d%%%@%@%@  %@",
            displayPct, sizeText, filesText, speedText, etaText
        )
        let line = "\r\(body)\u{001B}[K"
        FileHandle.standardError.write(Data(line.utf8))

        if fraction >= 0.999 {
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    func finish(note: String = "download complete") {
        FileHandle.standardError.write(Data("✓ \(note)\n".utf8))
    }

    private func remainingFilesNearEnd(_ completed: Int64, _ total: Int64) -> Bool {
        total > 0 && (total - completed) <= 2
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return String(format: "%dm %02ds", m, r) }
        let h = m / 60
        return String(format: "%dh %02dm", h, m % 60)
    }
}
