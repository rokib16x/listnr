# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, the CLI surface may change in any minor release.

## [Unreleased]

## [0.1.0-beta] - 2026-07-31

First public beta. Everything below is new.

### Added

- Dual-lane audio capture that never mixes lanes before speech recognition:
  - **Lane A** — microphone via `AVAudioEngine`, 16 kHz mono Float32, always labeled `You`.
  - **Lane B** — system / speaker output via ScreenCaptureKit, app-agnostic.
- On-device transcription with [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Core ML / Apple Neural Engine). No audio leaves the machine.
- Post-session speaker diarization of Lane B with SpeakerKit, producing
  `Speaker 1…N` labels for remote participants.
- Energy-based voice activity detection with a ~450 ms pre-roll ring, so the
  first syllable after a pause is not clipped.
- Interactive shell (the default when you run `listnr`) with `/live`, `/lang`,
  `/speakers`, `/model`, `/diarize`, `/dump`, `/status`, `/help`.
- One-shot non-interactive mode: `listnr start [--seconds N] [--language …]`.
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
- Lane A and Lane B timestamps are derived per-lane, so the merged timeline can
  be skewed by a few hundred milliseconds.
- Lane B is resampled 48 kHz → 16 kHz without an anti-aliasing filter, which
  costs some transcription accuracy on remote voices.
- Voice activity thresholds are fixed absolute values and may need tuning for
  unusually quiet or hot microphones.
- No automated test suite yet.

[Unreleased]: https://github.com/rokib16x/listnr/compare/v0.1.0-beta...HEAD
[0.1.0-beta]: https://github.com/rokib16x/listnr/releases/tag/v0.1.0-beta
