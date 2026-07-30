# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, the CLI surface may change in any minor release.

## [Unreleased]

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
