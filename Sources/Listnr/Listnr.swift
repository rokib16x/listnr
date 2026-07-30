import ArgumentParser
import Foundation

/// Bumped as part of cutting a release; keep in step with CHANGELOG.md.
let listnrVersion = "0.1.1-beta"

@main
struct Listnr: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listnr",
        abstract: "Local meeting listener. Mic + speakers → multi-speaker transcript on Apple Silicon.",
        version: listnrVersion,
        subcommands: [Shell.self, Start.self, Doctor.self, Setup.self, Models.self],
        defaultSubcommand: Shell.self
    )
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "One-shot session (non-interactive). Prefer `listnr` shell + /live for meetings."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Option(name: .long, help: "Capture for N seconds. Omit to run until Ctrl+C.")
    var seconds: Double?

    @Flag(name: .long, help: "Write listnr-mic.wav and listnr-sys.wav to ~/Documents/Listnr/debug.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable Whisper transcription (capture only).")
    var noTranscribe: Bool = false

    @Flag(name: .long, help: "Skip SpeakerKit diarization (keep a single Others label).")
    var noDiarize: Bool = false

    @Option(name: .long, help: "Hint for remote speaker count on Lane B.")
    var speakers: Int?

    @Option(name: .long, help: "Model id. Defaults from --language.")
    var model: String?

    @Option(name: .long, help: "Language: en|auto|bn|hi|es|fr|de|ja|zh")
    var language: String = "en"

    func run() throws {
        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above, run `listnr setup`, or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        var options = SessionOptions()
        let config = Config.load()
        options.remoteSpeakers = speakers ?? config.remoteSpeakerHint
        options.dumpWav = dumpWav || config.dumpWav
        options.transcribe = !noTranscribe
        options.diarize = !noDiarize
        options.seconds = seconds
        options.modelID = model

        if let mode = LanguageMode.parse(language) {
            options.language = mode
            if model == nil {
                options.modelID = mode.preferredModelID(current: nil)
            }
        } else {
            FileHandle.standardError.write(Data("unknown --language \(language)\n".utf8))
            throw ExitCode(1)
        }

        options.controlsHint = "Ctrl+C to finish · Ctrl+C twice to force quit"
        let runner = LiveSessionRunner(options: options)
        let interrupts = InterruptCounter()

        // SIG_IGN before the source exists, so no Ctrl+C slips through with the
        // default disposition and kills the process mid-session.
        signal(SIGINT, SIG_IGN)
        let signalQueue = DispatchQueue(label: "listnr.signal")
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigint.setEventHandler {
            if interrupts.bump() >= 2 {
                FileHandle.standardError.write(Data("\n⌃C again: force quit\n".utf8))
                Darwin.exit(130)
            }
            // First Ctrl+C stops gracefully: this is the only way to end an
            // untimed `listnr start`, and it must produce the transcript.
            FileHandle.standardError.write(Data("\n⌃C, stopping...  press Ctrl+C again to force quit\n".utf8))
            runner.requestStop()
        }
        sigint.resume()

        do {
            _ = try runner.runBlocking()
        } catch LiveSessionError.cancelled {
            FileHandle.standardError.write(Data("cancelled\n".utf8))
            throw ExitCode(130)
        } catch {
            FileHandle.standardError.write(Data("start failed: \(error.localizedDescription)\n".utf8))
            throw ExitCode(1)
        }
    }
}

/// Ctrl+C tally, shared with a signal handler on its own queue.
final class InterruptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = m.languages.joined(separator: ",")
                print("\(star) \(id) \(String(format: "%5d MB", m.sizeMB))  [\(langs)]  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)
            let sem = DispatchSemaphore(value: 0)
            var err: Error?
            Task {
                do { try await t.warmUp() } catch { err = error }
                sem.signal()
            }
            while sem.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if let err { throw err }
        }
    }
}
