import ArgumentParser
import Foundation

/// Shell state shared with the signal handler, which runs on its own queue.
private final class ShellState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRunner: LiveSessionRunner?
    private var interrupts = 0

    var runner: LiveSessionRunner? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return activeRunner
        }
        set {
            lock.lock()
            activeRunner = newValue
            lock.unlock()
        }
    }

    func bumpInterrupt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        interrupts += 1
        return interrupts
    }

    func resetInterrupts() {
        lock.lock()
        interrupts = 0
        lock.unlock()
    }
}

/// Interactive shell: `listnr` → `/live`, `/lang`, ...
struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Interactive Listnr prompt (/live, /lang, /stop, ...). Default when you run `listnr`."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

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
        options.remoteSpeakers = config.remoteSpeakerHint
        options.dumpWav = config.dumpWav

        print("listnr  ·  type /help  ·  Ctrl+C exits when idle")
        printStatus(options)

        let state = ShellState()
        let stdin = StdinReader()
        stdin.start()

        // Ignore the default disposition *before* the dispatch source exists, so
        // there is no window where a Ctrl+C would kill the process outright.
        signal(SIGINT, SIG_IGN)

        // A dedicated queue, not `.main`. The main thread spends its time blocked
        // in the prompt or pumping a session's run loop, and a handler queued on
        // `.main` does not run while it is blocked, so Ctrl+C at an idle prompt
        // did nothing, then fired later and cancelled the *next* /live session.
        let signalQueue = DispatchQueue(label: "listnr.signal")
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigint.setEventHandler {
            guard let runner = state.runner else {
                FileHandle.standardError.write(Data("\nbye\n".utf8))
                Darwin.exit(0)
            }
            if state.bumpInterrupt() >= 2 {
                FileHandle.standardError.write(Data("\n⌃C again: force quit\n".utf8))
                Darwin.exit(130)
            }
            FileHandle.standardError.write(Data("\n⌃C, cancelling (download/live)...  press Ctrl+C again to force quit\n".utf8))
            runner.requestCancel()
        }
        sigint.resume()

        while true {
            fputs("listnr> ", stdout)
            fflush(stdout)
            guard let line = stdin.nextLine() else {
                print("bye")
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let cmd = parts.first?.lowercased() else { continue }
            let args = Array(parts.dropFirst())

            switch cmd {
            case "/help", "help", "?":
                printHelp()

            case "/status", "status":
                printStatus(options)

            case "/lang", "lang":
                guard let raw = args.first, let mode = LanguageMode.parse(raw) else {
                    print("usage: /lang en|auto|bn|hi|es|fr|de|ja|zh")
                    continue
                }
                options.applyLanguage(mode)
                print("lang → \(mode.rawValue)  (model \(options.modelID ?? "auto"))")
                switch mode {
                case .auto:
                    print("  tip: detection now runs once per session and then locks,")
                    print("       but naming the language outright is still better:")
                    print("       `/lang bn` for Bangla · `/lang hi` for Hindi")
                case .bn, .hi:
                    print("  tip: if words are missing or garbled, `/model whisper-large-v2`")
                    print("       is slower but the most accurate option for Bangla/Hindi.")
                case .en:
                    break
                default:
                    break
                }

            case "/speakers", "speakers":
                guard let raw = args.first, let n = Int(raw), n >= 1, n <= 6 else {
                    print("usage: /speakers <1-6>")
                    continue
                }
                options.remoteSpeakers = n
                print("remote speakers hint → \(n)")

            case "/model", "model":
                guard let id = args.first else {
                    print("usage: /model <id>   (see: listnr models list)")
                    continue
                }
                guard ModelRegistry.find(id) != nil else {
                    print("unknown model: \(id)")
                    continue
                }
                options.modelID = id
                print("model → \(id)")
                if let warning = options.compatibilityWarning {
                    print("  ! \(warning)")
                }

            case "/dump", "dump":
                options.dumpWav.toggle()
                print("dump-wav → \(options.dumpWav ? "on" : "off")")

            case "/diarize", "diarize":
                options.diarize.toggle()
                print("diarize → \(options.diarize ? "on" : "off")")

            case "/translate", "translate":
                options.applyTranslate(!options.translate)
                print("translate → \(options.translate ? "on (output in English)" : "off")")
                // The model changes with the flag, so say which one will run.
                if let model = try? options.resolveModel() {
                    print("  model → \(model.id) (\(model.sizeMB) MB)")
                }
                if options.translate {
                    print("  Whisper only translates into English; the original wording is not kept.")
                    print("  lighter option: /model whisper-small (207 MB, rougher)")
                }
                if let warning = options.compatibilityWarning {
                    print("  ! \(warning)")
                }

            case "/live", "live":
                if state.runner != nil {
                    print("already live. Ctrl+C or wait")
                    continue
                }

                var liveOpts = options
                if let raw = args.first {
                    let cleaned = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
                    guard let secs = Double(cleaned), secs > 0 else {
                        print("usage: /live [seconds]   e.g. /live 30  or  /live 300")
                        continue
                    }
                    liveOpts.seconds = secs
                } else {
                    liveOpts.seconds = nil
                }

                liveOpts.controlsHint = "/stop or q + Enter to finish · Ctrl+C cancels"
                let runner = LiveSessionRunner(options: liveOpts)
                state.runner = runner

                stdin.setLiveHandler { line in
                    guard Self.isStopCommand(line) else { return false }
                    runner.requestStop()
                    return true
                }

                do {
                    _ = try runner.runBlocking()
                } catch LiveSessionError.cancelled {
                    FileHandle.standardError.write(Data("returned to prompt. partial download kept; resume with /live\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("live failed: \(error.localizedDescription)\n".utf8))
                }

                stdin.setLiveHandler(nil)
                state.runner = nil
                state.resetInterrupts()

            case "/stop", "stop":
                if let runner = state.runner {
                    runner.requestStop()
                    print("stopping...")
                } else {
                    print("not live, nothing to stop")
                }

            case "q", "/q", "quit", "exit", "/quit", "/exit":
                if let runner = state.runner {
                    runner.requestStop()
                    print("stopping...")
                } else {
                    print("bye")
                    return
                }

            default:
                print("unknown: \(cmd)  ·  try /help")
            }
        }
    }

    /// While live, `q` or `/stop` + Enter finishes the session.
    /// Internal (not private) so the test target can exercise it.
    static func isStopCommand(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t == "q" || t == "/q" || t == "/stop" || t == "stop"
    }

    private func printHelp() {
        print(
            """
            commands:
              /live              start listening until q, /stop, or Ctrl+C
              /live 30           listen for 30 seconds then report
              /live 300          listen for 300 seconds then report
              /stop | q          stop a live session (type while live + Enter)
              /lang en|auto|bn|hi   language. naming it beats auto-detect
              /speakers N        remote speaker hint (1-6)
              /model <id>        see `listnr models list`. English: whisper-base.en
                                 Other languages, fastest → most accurate:
                                   whisper-small (207 MB)
                                   whisper-large-v3-turbo-fast (615 MB, default)
                                   whisper-large-v2 (908 MB, best for bn/hi)
              /dump              toggle WAV dump to ~/Documents/Listnr/debug
              /diarize           toggle SpeakerKit on Lane B
              /translate         speak any language, transcript comes out English
              /status            show current options
              /help              this help
              quit | exit        leave the shell (when not live)
            """
        )
    }

    private func printStatus(_ options: SessionOptions) {
        let model = options.modelID ?? "(from /lang)"
        print(
            """
            status:
              lang=\(options.language.rawValue)  model=\(model)  speakers=\(options.remoteSpeakers)
              diarize=\(options.diarize)  dump-wav=\(options.dumpWav)  translate=\(options.translate)
            """
        )
    }
}
