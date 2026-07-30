import ArgumentParser
import Foundation

/// Interactive shell: `listnr` → `/live`, `/lang`, …
struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Interactive Listnr prompt (/live, /lang, /stop, …). Default when you run `listnr`."
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

        var activeRunner: LiveSessionRunner?
        let runnerLock = NSLock()
        var sigintCount = 0

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            runnerLock.lock()
            let runner = activeRunner
            runnerLock.unlock()
            if let runner {
                sigintCount += 1
                if sigintCount >= 2 {
                    FileHandle.standardError.write(Data("\n⌃C again — force quit\n".utf8))
                    Darwin.exit(130)
                }
                FileHandle.standardError.write(Data("\n⌃C — cancelling (download/live)…  press Ctrl+C again to force quit\n".utf8))
                runner.requestStop()
            } else {
                FileHandle.standardError.write(Data("\nbye\n".utf8))
                Darwin.exit(0)
            }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        while true {
            fputs("listnr> ", stdout)
            fflush(stdout)
            guard let line = readLine(strippingNewline: true) else {
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
                    print("  tip: auto-detect is slower/less reliable on short clips.")
                    print("       for Bangla use `/lang bn` · for Hindi `/lang hi`")
                case .bn, .hi:
                    print("  tip: speak clearly; first /live may already have turbo cached")
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

            case "/dump", "dump":
                options.dumpWav.toggle()
                print("dump-wav → \(options.dumpWav ? "on" : "off")")

            case "/diarize", "diarize":
                options.diarize.toggle()
                print("diarize → \(options.diarize ? "on" : "off")")

            case "/live", "live":
                runnerLock.lock()
                if activeRunner != nil {
                    runnerLock.unlock()
                    print("already live — Ctrl+C or wait")
                    continue
                }
                runnerLock.unlock()

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

                let runner = LiveSessionRunner(options: liveOpts)
                runnerLock.lock()
                activeRunner = runner
                runnerLock.unlock()

                installLiveStdinHandler(runner: runner)

                do {
                    _ = try runner.runBlocking()
                } catch LiveSessionError.cancelled {
                    FileHandle.standardError.write(Data("returned to prompt — partial download kept; resume with /live\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("live failed: \(error.localizedDescription)\n".utf8))
                }

                removeLiveStdinHandler()
                runnerLock.lock()
                activeRunner = nil
                sigintCount = 0
                runnerLock.unlock()

            case "/stop", "stop":
                runnerLock.lock()
                let runner = activeRunner
                runnerLock.unlock()
                if let runner {
                    runner.requestStop()
                    print("stopping…")
                } else {
                    print("not live — nothing to stop")
                }

            case "q", "/q", "quit", "exit", "/quit", "/exit":
                runnerLock.lock()
                let runner = activeRunner
                runnerLock.unlock()
                if let runner {
                    runner.requestStop()
                    print("stopping…")
                } else {
                    print("bye")
                    return
                }

            default:
                print("unknown: \(cmd)  ·  try /help")
            }
        }
    }

    /// While live, type `q` or `/stop` + Enter (non-blocking vs the prompt).
    private func installLiveStdinHandler(runner: LiveSessionRunner) {
        let handle = FileHandle.standardInput
        handle.readabilityHandler = { file in
            let data = file.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: \.isNewline) {
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if t == "q" || t == "/q" || t == "/stop" || t == "stop" {
                    runner.requestStop()
                }
            }
        }
    }

    private func removeLiveStdinHandler() {
        FileHandle.standardInput.readabilityHandler = nil
    }

    private func printHelp() {
        print(
            """
            commands:
              /live              start listening until q, /stop, or Ctrl+C
              /live 30           listen for 30 seconds then report
              /live 300          listen for 300 seconds then report
              /stop | q          stop a live session (type while live + Enter)
              /lang en|auto|bn|hi…  language — use bn/hi explicitly for Bangla/Hindi
                                    (auto is slower and often mis-detects short speech)
              /speakers N        remote speaker hint (1–6)
              /model <id>        whisper-base.en | whisper-small.en | whisper-large-v3-turbo
              /dump              toggle WAV dump to /tmp
              /diarize           toggle SpeakerKit on Lane B
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
              diarize=\(options.diarize)  dump-wav=\(options.dumpWav)
            """
        )
    }
}
