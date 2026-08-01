# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, the CLI surface may change in any minor release.

## [Unreleased]

### Fixed

- **Non-English transcription dropped correct speech and reported nothing.** The
  per-segment confidence gate was calibrated on English and applied to every
  language, but Whisper's confidence signals are not comparable across writing
  systems. `avgLogProb` averages over tokens, and Whisper's BPE spends several
  times more tokens per word on Bengali and Devanagari, so correct Bangla scores
  around −1.2 against a −0.9 floor. `compressionRatio` is inherently higher for
  Indic and Han text, which is three bytes per character from a small repertoire,
  so an ordinary sentence lands near 3.0 against a 2.6 ceiling. Segments that
  failed both were discarded, `transcribe` returned an empty string, and the lane
  pipeline skipped it with no log line anywhere — the language looked like it
  simply did not work. Thresholds are now keyed on script class
  (`DecodeTuning`), and a dropped-segment count is reported instead of hidden.
- **`/lang auto` re-detected the language on every clip.** Detection ran per
  segment, so consecutive utterances from one continuous conversation could be
  decoded as different languages — the mechanism behind auto mode's gibberish.
  Detection now runs once, locks for the session, and retunes the thresholds to
  the detected script.
- **`--language` and `--model` no longer contradict each other in silence.** An
  English-only model with a non-English language transcribed foreign speech
  *into English words*, which reads as a bad transcript rather than as a
  misconfiguration. Both the shell and `listnr start` now warn.
- The `models download` subcommand mutated a captured `var` from inside a
  `Task`, the one remaining strict-concurrency diagnostic in `Sources/Listnr`
  and an error under the Swift 6 language mode.
- **Every utterance no longer starts with a duplicated 30 ms of audio.** When
  the segmenter triggered, the pre-roll ring already contained the triggering
  frame, and that frame was then appended a second time. The onset stuttered in
  the audio handed to Whisper, and the buffer was one frame longer than the
  span its timestamp claimed, so each segment's start was reported 30 ms early.
  A test now asserts the invariant directly: a segment must be byte-identical
  to the source audio at the position it says it starts at.

### Added

- **`/translate` and `--translate`: speak any supported language, get an English
  transcript.** This is Whisper's own `translate` task, so it costs no second
  model and no extra decode pass. Whisper only translates *into* English; there
  is no other target, and English input is a no-op that Listnr now points out.
  Each line is English only — the native wording is not kept, so leave it off if
  the original is the record you need.
  - Models now carry a `supportsTranslation` capability, because the pairing that
    matters fails silently. OpenAI fine-tuned the `large-v3-turbo` builds for
    transcription only, and they "return the original language even if
    `--task translate` is specified" — and one of those builds is Listnr's
    transcription default for `bn`/`hi`/`ja`/`zh`. Toggling translation now
    re-derives the model instead of leaving one that ignores the request, naming
    an incapable model explicitly is refused before the session starts rather
    than discovered at the end of it, and `listnr models list` marks the capable
    ones with `→en`.
  - The confidence gate splits its two signals apart when translating. The
    compression ratio is measured on the *output*, which is English, so it
    reverts to the Latin ceiling — keeping the relaxed Indic one would have
    admitted exactly the repetition loops it was widened past. The
    log-probability floor describes how hard the *input* was and stays where the
    source script put it.
- **Six more models**, so non-English is a ladder rather than a single 1.5 GB
  option: `whisper-tiny`, `whisper-base`, `whisper-small` and `whisper-medium`
  multilingual builds, `whisper-large-v2` as the accuracy pick for Bangla and
  Hindi, and `whisper-large-v3-turbo-fast` as a quantized build of the model that
  used to be the only choice. Sizes in the registry are now the measured on-disk
  totals.
- A script-independent repetition guard. Relaxing the non-Latin confidence gates
  buys back real speech but would also admit more degenerate output, so
  `TranscriptText.isRepetitionLoop` rejects decoder loops by the shape of the
  text — a word four times over, or a phrase three times back to back — with a
  character-level pass for Han, Kana, and Hangul, which are not word-spaced.
- `Locked<T>`, one audited generic replacing the lock-plus-`@unchecked Sendable`
  shape that had been hand-written five times.
- `scripts/check-version.sh`, run by CI, asserting that the version in
  `Sources/ListnrCore/Version.swift`, the version the built binary reports, the
  git tag, and the CHANGELOG heading all agree. A tag that disagrees with
  `listnr --version` is invisible until someone files a bug against a release
  that never existed — and once tags drive release tarballs and a Homebrew
  formula, the same mismatch ships a checksum belonging to another version.
- Tests for the stop-versus-cancel rule (extracted to `SessionStopState`), the
  stdin reader's buffering and live hand-off, and `LanguageMode` /
  `SessionOptions` / `ModelRegistry`. With the script-tuning, repetition-guard,
  and model-compatibility tests the suite is now 115 tests.

### Changed

- **The package is split into a `ListnrCore` library and a one-line `listnr`
  executable.** The tests used to `@testable import` an executable target, which
  works but is not what executable targets are for, and it left no way for
  anything else to depend on the logic — including the menubar app on the
  roadmap, which needs the session pipeline and cannot import an executable.
  `Sources/Listnr/` became `Sources/ListnrCore/`; `Sources/listnr/main.swift` is
  now the whole executable. The library's public API is deliberately one symbol,
  the `Listnr` root command: everything else stays `internal`, which `@testable`
  still reaches, so nothing had to be made `public` to keep the tests working.
- **Non-English defaults no longer point at the full-precision 1.5 GB turbo.**
  Every non-English language used to resolve to the largest and slowest model in
  the registry, which could not keep pace with a live conversation — and the lane
  pipeline's bounded queue drops what it cannot transcribe in time, so the cost
  was whole missing utterances. `bn`/`hi`/`ja`/`zh`/`auto` now default to the
  quantized turbo at 615 MB, and `es`/`fr`/`de` to `whisper-medium`.
  `whisper-large-v2` remains available via `/model` for accuracy over speed.
- `resolveModel()` delegates to `LanguageMode.preferredModelID` instead of
  repeating the mapping, so the model named in the session header is always the
  one that runs.
- The stop/cancel decision moved out of `LiveSessionRunner` into
  `SessionStopState` so the rule that broke in `0.1.0-beta` is covered by
  tests; behaviour is unchanged.
- `StdinReader` takes an injectable line source, so its buffering rules can be
  tested without swapping the process's real stdin.

## [0.1.1-beta] - 2026-07-31

### Added

- `listnr --version`.
- A test target (`Tests/ListnrTests`, 45 tests) covering the energy VAD's
  transient rejection and floors, the transcript text rules (including CJK,
  Bangla, Hindi and Russian short replies), the per-segment confidence gate,
  the merger and lane-offset logic, the WAV writer, and the full lane
  pipeline driven by a fake transcriber. CI runs it on every push.

### Fixed

- **`/stop` and `q` now finish the session and produce the transcript.** The
  stop request cancelled the underlying task, the same mechanism Ctrl+C uses,
  so a graceful stop was indistinguishable from an abort: the wait loop threw
  from its sleep, finalization was skipped, and the captured meeting was
  discarded with a "cancelled" message. Stop and cancel are now separate
  requests. The same defect made an untimed `listnr start` unable to ever
  produce a transcript, since Ctrl+C was its only exit; the first Ctrl+C in
  one-shot mode now finishes gracefully and a second force-quits.
- **Failed or cancelled sessions no longer leak the transcription pipelines.**
  Each lane's VAD and ASR tasks were only shut down on the success path, so
  every session that errored or was cancelled left two detached tasks and
  their buffered audio alive for the life of the shell. Teardown now runs on
  every exit path.
- **With diarization off or failed, Lane B keeps its per-utterance
  timestamps.** The lines the live lane had already transcribed were always
  discarded, and the whole system buffer was re-transcribed as a single block
  timestamped 00:00, which both doubled the work and interleaved wrongly with
  the mic lane. The merged transcript now prefers diarized spans, then the
  live lane's timestamped lines, and falls back to a whole-buffer pass only
  when both are empty.
- **Whole-buffer fallback lines are placed on the shared session clock.** The
  mic fallback line was created after the lane shift and so missed its
  offset. Both lanes now stay in lane time until a single shift at the merge.
- **A failure after a stop request is reported as that failure**, not
  silently rewritten as "cancelled". Only a real abort maps to the cancel
  message.
- The "Recorded" header and filename of an exported transcript now use the
  session's start time; they previously stamped the moment the session ended.
- A transcript export failure now prints the reason instead of failing
  silently.
- **Audio is no longer processed out of order.** Each lane spawned an
  unstructured `Task` per captured buffer to hand it to the VAD. Unstructured
  tasks have no ordering guarantee, so under load (exactly when Whisper is busy)
  buffers reached the segmenter shuffled, corrupting utterances and
  timestamps. Each lane now has one `AsyncStream` and one consumer, so
  segmentation is FIFO.
- **Speech recognition no longer blocks segmentation.** Whisper ran inline with
  the VAD, stalling it for as long as a decode took and letting audio queue up
  without bound. VAD and ASR are now separate stages behind bounded queues, and
  a lane reports how much it dropped instead of losing it silently.
- **Transient noise no longer reaches Whisper as speech.** The `minSpeechSeconds`
  floor was measured on the whole utterance buffer, which the ~450 ms pre-roll
  and ~550 ms hangover padded past the threshold on their own, so a single
  frame over the energy threshold (a key click, a door) always passed as
  speech and Whisper hallucinated words for it. Segments now also require a
  minimum *voiced* duration and a minimum *contiguous* voiced run, which
  separates a syllable from a burst of typing.
- **Lane B audio is anti-aliased before resampling.** System audio was decimated
  48 kHz → 16 kHz by linear interpolation with no lowpass, folding everything
  above 8 kHz back into the speech band. It now goes through `AVAudioConverter`,
  which also performs a proper stereo → mono downmix instead of discarding one
  channel, and no longer assumes the `CMBlockBuffer` is contiguous.
- **The two lanes now share one clock.** Lane A and Lane B start milliseconds
  apart and each timestamped from its own zero, so the merged transcript
  interleaved wrongly. Both lanes now record the host-clock time of their first
  sample and are shifted onto a common origin, with a sanity check that declines
  to shift on an implausible measurement.
- **Quiet remote speakers are no longer dropped silently.** `transcribe()`
  enforced a hidden RMS floor of 0.018 that overrode callers, so diarized spans
  admitted at 0.005 came back as empty text. The floor is now the caller's
  decision, and span loudness is measured on the span SpeakerKit found rather
  than on the padded slice. Padding used to drag a real utterance under the
  threshold precisely because it had been widened.
- **Real speech is no longer deleted by the hallucination filter.** The filter
  rejected `okay`, `ok`, `thanks`, `thank you`, `bye`, `you`, `the`, `a`, `uh`,
  `um`, and `hmm` outright, every one of them an ordinary thing to say in a
  meeting. It also rejected any output of two characters or fewer, counted in
  `Character`s, so Chinese 好的 ("okay"), Japanese はい ("yes") and Russian да
  were discarded: the most common replies in languages `/lang` advertises could
  never appear. Whether a clip contains speech is now decided by Whisper's own
  per-segment `noSpeechProb`, `avgLogprob`, and `compressionRatio`, which is a
  judgement the text cannot make. What remains text-based is limited to output
  that is not speech in any language: decoder tokens, bracketed stage
  directions, and caption artifacts such as "thanks for watching".
- **Cleanup no longer corrupts legitimate text.** Three rules were rewriting
  real transcripts: `\(...\)` deleted parenthesised speech, so "the API (v2)
  ships" lost its version; `\*...\*` did the same between asterisks; and
  `\.\d{2,}` stripped the decimal part of every number, turning "version 3.14"
  into "version 3" and "$19.99" into "$19". Bracket, paren, and asterisk
  contents are now removed only when the content is actually a non-speech
  annotation, and the trailing-digit rule requires a letter before the period
  and end of string, so "Thank you.000" is cleaned while decimals survive.
- Text cleanup and non-speech detection moved into `TranscriptText`, which has
  no WhisperKit dependency, so the rules are readable and directly testable.
- **Ctrl+C at the idle prompt works, and no longer kills the next session.** The
  signal handler was queued on the main queue, which is blocked while the prompt
  waits for input, so Ctrl+C did nothing, then fired later and cancelled the
  next `/live`. It now runs on its own queue, and `SIGINT` is ignored before the
  handler is installed rather than after.
- **Typed-ahead input is no longer swallowed.** A blocking `readLine()` on the
  main thread and a `readabilityHandler` on the same descriptor could each
  consume the other's line. A single reader thread now owns stdin and buffers
  anything the live session does not consume.

### Security

- **`/dump` no longer writes meeting audio to `/tmp`.** The WAV dumps were at
  fixed, world-readable paths that any local user on a shared Mac could read.
  They now go to `~/Documents/Listnr/debug/` with owner-only permissions
  (0600). If you used `/dump` with an earlier build, delete
  `/tmp/listnr-mic.wav` and `/tmp/listnr-sys.wav` if present.

### Changed

- WhisperKit is pinned to `0.18.x` (`.upToNextMinor`) instead of any version
  from 0.9 up, since the code compiles against 0.18 APIs and WhisperKit does
  not promise stability across 0.x minors.
- Removed the unused fixed-duration capture helper left over from early
  milestone verification.
- Strict-concurrency diagnostics in `Sources/Listnr` are down from 4 to
  **zero**, and the CI job that tracked them now fails on any new one.

## [0.1.0-beta] - 2026-07-31

First public beta. Everything below is new.

### Added

- Dual-lane audio capture that never mixes lanes before speech recognition:
  - **Lane A**: microphone via `AVAudioEngine`, 16 kHz mono Float32, always labeled `You`.
  - **Lane B**: system and speaker output via ScreenCaptureKit, app-agnostic.
- On-device transcription with [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Core ML / Apple Neural Engine). No audio leaves the machine.
- Post-session speaker diarization of Lane B with SpeakerKit, producing
  `Speaker 1...N` labels for remote participants.
- Energy-based voice activity detection with a ~450 ms pre-roll ring, so the
  first syllable after a pause is not clipped.
- Interactive shell (the default when you run `listnr`) with `/live`, `/lang`,
  `/speakers`, `/model`, `/diarize`, `/dump`, `/status`, `/help`.
- One-shot non-interactive mode: `listnr start [--seconds N] [--language xx]`.
- `listnr setup` and `listnr doctor` for permission onboarding and diagnosis.
- `listnr models list` / `listnr models download <id>` with live download
  progress, throughput, and ETA.
- Model registry covering `whisper-base.en`, `whisper-small.en`, and
  `whisper-large-v3-turbo` (multilingual).
- Markdown transcript export to `~/Documents/Listnr/`.

### Known limitations

See the "Status" section of the [README](README.md#status--beta) for the
current list. The significant ones in this release:

- Diarization runs **after** the session ends. Live output labels all remote
  audio as a single `Others`.
- Whole-session audio is held in memory (~460 MB/hour across both lanes), so
  very long sessions are memory-hungry.
- Voice activity thresholds are fixed absolute values and may need tuning for
  unusually quiet or hot microphones.
- Settings changed in the shell do not persist across runs.
- No automated test suite yet.

[Unreleased]: https://github.com/rokib16x/listnr/compare/v0.1.1-beta...HEAD
[0.1.1-beta]: https://github.com/rokib16x/listnr/compare/v0.1.0-beta...v0.1.1-beta
[0.1.0-beta]: https://github.com/rokib16x/listnr/releases/tag/v0.1.0-beta
