# Contributing to Listnr

Thanks for your interest. Listnr is early: pre-1.0, one maintainer, and plenty
of low-hanging fruit. Bug reports and small focused pull requests are
both very welcome.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Requirements

Listnr is macOS and Apple Silicon only, and that is unlikely to change. It
depends on Core ML and the Apple Neural Engine, `AVAudioEngine`, and
ScreenCaptureKit.

| | |
|---|---|
| **Hardware** | Apple Silicon (M1 or newer). Intel Macs are not supported. |
| **OS** | macOS 14 (Sonoma) or later |
| **Toolchain** | Swift 5.9+ (Xcode 15+). Developed on Swift 6.3. |
| **Disk** | ~2 GB free if you test the multilingual model |

Verify your setup:

```bash
swift --version
```

## Build and run

```bash
git clone https://github.com/rokib16x/listnr.git
cd listnr
swift build
```

Then grant permissions once and check them:

```bash
.build/debug/listnr setup
.build/debug/listnr doctor
```

`doctor` must show microphone and screen-recording access before Lane B
(system/speaker audio) will produce anything. Both permissions attach to your
**terminal application**, not to the `listnr` binary, so if you switch from
Terminal to iTerm you will be prompted again.

Run it:

```bash
.build/debug/listnr                      # interactive shell
.build/debug/listnr start --seconds 20   # one-shot
```

For anything performance or latency related, always measure a release build.
Debug Swift is far slower and will mislead you:

```bash
swift build -c release
```

## Tests

There is **no test suite yet**. Adding one is one of the most valuable
contributions available right now, and it does not require any audio hardware.

The pure, easily testable pieces are:

| Component | What to assert |
|---|---|
| `EnergyVAD` | Onset retention across a pause; transient rejection (clicks vs short words); segment boundaries; `maxSpeechSeconds` splitting; stability across buffer sizes |
| `WAVWriter` | Byte-exact header; round-trip through `AVAudioFile` |
| `TranscriptText.clean` / `isNonSpeech` | Table-driven cases: CJK and Bangla replies, decimals, parenthesised acronyms, `[MUSIC]` markers |
| `WhisperKitTranscriber.Confidence` | Accept/reject at each threshold boundary |
| `TranscriptMerger.merge` | Ordering, and stability across equal timestamps |
| `LanguageMode.parse`, `SessionOptions.resolveModel` | Valid, invalid, and conflicting inputs |

Once a `Tests/ListnrTests/` target exists, CI runs it automatically:

```bash
swift test
```

If you are testing the capture or session layer, please introduce a protocol
seam (a `CaptureSource` that `DualCaptureSession` depends on) and a WAV-backed
fake, rather than mocking hardware. That makes the whole pipeline testable in CI
where there is no microphone, no ANE, and no permissions.

## Concurrency: please read this before touching the audio path

Listnr had **known data races**, and they were the source of most of its real
bugs. Four strict-concurrency diagnostics remain (see below). Do not add more.

Check your work before opening a PR:

```bash
swift build -Xswiftc -strict-concurrency=complete
```

As of the latest commit this reports **4** remaining warnings, all in
`MeetingSession`, `LiveSessionRunner`, `Listnr.swift`, and
`WhisperKitTranscriber`. **Do not add new ones**, and
please do not "fix" them with `@unchecked Sendable` or `nonisolated(unsafe)`
unless you can explain in the PR why the access is genuinely safe.

Three rules specific to this codebase:

1. **Never spawn a `Task {}` per audio buffer.** Unstructured tasks have no
   ordering guarantee, so audio arrives at the VAD shuffled. Use a single
   `AsyncStream` per lane with one consumer.
2. **The audio render callback is a realtime thread.** No locks, no allocation,
   no queue hops, no `print`. Copy into a preallocated buffer and hand off.
3. **Never mix Lane A and Lane B before speech recognition.** This is the core
   design invariant of the project. Mixing destroys speaker identity, which is
   the whole reason Listnr exists. Mixing is acceptable only for producing a
   single playback archive file.

## Style

Match the surrounding code. There is no automated formatter configured yet
(adding a `.swiftformat` config would be a welcome PR).

Conventions in use:

- 4-space indentation, no tabs.
- `// MARK: -` to separate protocol conformances in larger types.
- Comments explain **why**, not what. The existing comments in `EnergyVAD` and
  `DownloadProgressPrinter` are the standard to aim for. If you work out a
  non-obvious reason for a threshold or an ordering, write it down.
- User-facing progress, levels, and diagnostics go to **stderr**. Only the final
  transcript goes to **stdout**, so it stays pipeable.
- Errors conform to `LocalizedError` with an actionable `errorDescription`.

## Pull requests

**Scope one PR to one concern.** A PR that fixes the audio ordering bug *and*
reworks the CLI flags *and* reformats three files is very hard to review and
will sit for a long time. Small and focused gets merged.

Before you start:

- **Open an issue first** for anything non-trivial, such as a new dependency, a
  change to the CLI surface, a new capture backend, or a change to the lane
  architecture. This saves you from building something that then gets declined.
- **Typo fixes, docs, and small bug fixes need no prior discussion.** Just send
  them.

Then:

1. Branch from `main`: `git checkout -b fix/audio-chunk-ordering`
2. Make the change. Add a test if the thing you touched is testable.
3. Confirm `swift build` is clean and no new concurrency warnings appear.
4. Add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
5. Open the PR. Describe **what changed, why, and how you verified it.** For
   anything touching audio or transcription, say what you actually tested with:
   how many speakers, which language, which model, how long a session.

Commit messages use [Conventional Commits](https://www.conventionalcommits.org/):

```
fix: preserve audio chunk order in the mic lane
feat: add --json transcript output
docs: correct the live diarization claim in the README
test: cover EnergyVAD onset retention
refactor: extract the RunLoop pumping helper
```

`main` should always build. Changes land through PRs, including the
maintainer's.

## Good first issues

If you want somewhere to start, in rough order of value:

1. **A test target** covering any of the pure functions listed above.
2. **`isatty(2)` guards** on progress output and the level meter, so piped and
   CI output is readable.
3. **`--version`**. Right now `listnr --version` prints a confusing
   `Usage: listnr shell`. Needs `version:` in `CommandConfiguration`.
4. **`--json` and `--output <path>`** for machine-readable transcripts.
5. **Adaptive VAD thresholds.** They are fixed absolute RMS values today
   (0.014, 0.018, 0.022, 0.025 and so on, scattered across four files). Mic gain
   varies by more than 20 dB across hardware. Consolidate them into one struct
   and derive from a rolling noise floor.
6. **Wire up `Config.save()`.** It exists and is never called, so every `/lang`,
   `/model`, and `/speakers` change is lost on exit.
7. **Spill session audio to disk.** Both lanes are held in RAM for the whole
   session (~460 MB/hour combined), which is what stops "hours OK" from being
   true. Needs chunked diarization too.
8. **Retire `MeetingSession.shared`.** The singleton makes concurrent sessions
   impossible and export untestable, and it stamps the export with the meeting's
   *end* time.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml). For audio
and transcription problems, `listnr doctor` output plus your macOS version, chip,
and model choice are genuinely necessary. Without them a report usually cannot
be acted on.

**Never attach real meeting audio or a real transcript.** Reproduce with your own
voice or synthetic audio. If a bug only shows up with particular audio, describe
the characteristics (number of speakers, language, overlap, background noise)
rather than sending a recording of other people.

## Security

Do not file security problems as public issues. See
[SECURITY.md](SECURITY.md).

## Licensing

Listnr is [MIT licensed](LICENSE). Contributions are accepted under the same
license. There is no CLA.
