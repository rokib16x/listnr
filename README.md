# Listnr

**Local meeting listener for macOS.** Captures **your microphone** and **speaker / system audio** as two separate lanes, transcribes on-device, and labels **You** plus remote **Speaker 1…N** — without tying to Discord, Zoom, or any other app API.

Anything that plays through the Mac's output is Lane B. Privacy-first: your audio never leaves your machine.

[![CI](https://github.com/rokib16x/listnr/actions/workflows/ci.yml/badge.svg)](https://github.com/rokib16x/listnr/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Intel Macs are not supported.

---

## Status — beta

Listnr is **`0.1.0-beta`**. The core pipeline works and produces useful transcripts, but this is early software with one maintainer. The CLI surface may change in any `0.x` release.

Please read these limitations before filing an issue — they are known:

| Limitation | Detail |
|---|---|
| **Diarization is post-session, not live** | While a session runs, all remote audio is labeled `Others`. The `Speaker 1…N` split is computed **after** you stop. Live per-speaker labels are planned, not shipped. |
| **Memory grows with session length** | Whole-session audio is held in RAM — roughly **460 MB per hour** across both lanes. Multi-hour sessions are memory-hungry; spill-to-disk is planned. |
| **Short utterances may be dropped** | The hallucination filter discards very short output, which can swallow legitimate one- or two-character replies — particularly in Chinese, Japanese, and other non-Latin scripts. |
| **Fixed voice-detection thresholds** | Speech detection uses absolute RMS thresholds. A very quiet or very hot microphone may need code changes to work well. |
| **Settings do not persist** | `/lang`, `/model`, `/speakers`, and `/dump` changes are lost when you quit. |
| **No test suite yet** | See [CONTRIBUTING.md](CONTRIBUTING.md) — this is the most valuable place to help. |
| **No GUI** | CLI only. A menubar app is on the roadmap. |

Found something not on this list? [Open an issue](https://github.com/rokib16x/listnr/issues/new/choose).

---

## ⚠️ Recording other people — read this first

Listnr records the voices of everyone on your call. **In many places, doing that without their consent is illegal.**

- **All-party consent jurisdictions** — including California, Illinois, Florida, Pennsylvania, Washington, and much of the EU under GDPR — require the consent of *every* participant, not just yours.
- Rules differ by state, country, and whether the call is business or personal, and they apply to *recording*, not just to sharing.

**You are solely responsible for complying with the law where you and every participant are located.** Tell people you are recording, get their agreement, and honor a refusal. Listnr's authors provide this tool as-is and accept no liability for how it is used — see the [LICENSE](LICENSE).

The polite version is also the practical one: say "I'm running a local transcriber, any objections?" at the top of the call.

---

## Privacy — what stays local, what doesn't

**Your audio and transcripts never leave your machine.** There is no cloud STT, no telemetry, no analytics, no crash reporting, and no account.

There is exactly **one** outbound network request Listnr makes, and it is worth stating plainly:

> **On first run, model weights are downloaded from Hugging Face** (`huggingface.co`) — from `argmaxinc/whisperkit-coreml` for transcription and `argmaxinc/speakerkit-coreml` for diarization. That is 145 MB–1.6 GB depending on the model. No audio, text, or identifying information is sent — it is a plain model download, and it happens once per model.

After the models are cached, **Listnr runs fully offline.** To verify, pre-fetch and then disconnect:

```sh
listnr models download whisper-base.en
```

Where things are written on disk:

| What | Where | Notes |
|---|---|---|
| Transcripts | `~/Documents/Listnr/listnr_*.md` | **Unencrypted.** No automatic retention limit — delete them yourself. |
| Models | WhisperKit's model cache | Reusable across sessions. |
| Config | `~/Library/Application Support/listnr/config.json` | Currently read but never written. |
| `/dump` audio | `/tmp/listnr-mic.wav`, `/tmp/listnr-sys.wav` | ⚠️ **`/tmp` is world-readable.** On a shared Mac, other local users can read your meeting audio. Debugging aid only — see below. |

> **Known privacy defect:** `/dump` writes raw meeting audio to world-readable `/tmp` at predictable paths. Treat it as a single-user debugging tool until this is fixed. Tracked for the next release.

---

## Install

Listnr is source-only for now — no Homebrew tap or signed binary yet. You need Xcode 15+ (Swift 5.9+).

```sh
git clone https://github.com/rokib16x/listnr.git
cd listnr
swift build -c release
```

Grant permissions once, then verify:

```sh
.build/release/listnr setup     # mic + Screen & System Audio Recording
.build/release/listnr doctor    # verify permissions
```

Put it on your `PATH` so you can just type `listnr`:

```sh
sudo cp .build/release/listnr /usr/local/bin/listnr
```

### About the permissions

Listnr needs two, and macOS attaches both to your **terminal application** — not to the `listnr` binary:

| Permission | Why |
|---|---|
| **Microphone** | Lane A — your voice |
| **Screen & System Audio Recording** | Lane B — speaker output, i.e. everyone else |

Two consequences worth knowing: switching from Terminal to iTerm means granting again, and macOS often needs the Settings toggle plus a relaunch before the change takes effect. `listnr doctor` will tell you which one is missing.

The Screen Recording permission is how macOS gates system-audio capture via ScreenCaptureKit. Listnr requests a 2×2-pixel video stream it never reads, purely because the API requires one — **no screen content is captured, stored, or transmitted.** You can verify that in [`Sources/Listnr/Capture/SystemAudioCapture.swift`](Sources/Listnr/Capture/SystemAudioCapture.swift).

---

## How to use

1. Put on a **headset**. This matters more than anything else below — open speakers leak remote voices into your mic, which puts the same person on both lanes and wrecks speaker separation.
2. Join any call, or play audio through the speakers.
3. Open Listnr:

```sh
listnr
```

4. At the prompt:

```text
listnr> /live              # listen until you stop (see the memory note in Status)
listnr> /live 30           # 30 seconds then report
listnr> /live 300          # 5 minutes then report
```

5. To finish: type `q` or `/stop` and press Enter, or press **Ctrl+C**.
6. You get a transcript on screen; Markdown is saved to `~/Documents/Listnr/`.

### Language

```text
listnr> /lang en           # English (whisper-base.en by default)
listnr> /lang auto         # multilingual (whisper-large-v3-turbo)
listnr> /lang bn           # Bangla hint + multilingual model
```

Prefer an explicit language code over `auto`. Auto-detection is slower and frequently guesses wrong on short clips. Non-English languages pull the 1.6 GB turbo model on first use.

### Other commands

```text
listnr> /speakers 2        # remote speaker hint (1–6)
listnr> /model whisper-small.en
listnr> /dump              # toggle /tmp WAV dumps (see the privacy warning above)
listnr> /diarize           # toggle SpeakerKit
listnr> /status
listnr> /help
listnr> quit
```

### One-shot (no shell)

```sh
listnr start --seconds 60 --speakers 2
listnr start --language auto --seconds 120
listnr start                 # until Ctrl+C
listnr models list
```

The final transcript goes to **stdout**; progress, level meters, and diagnostics go to **stderr** — so you can redirect just the transcript. A structured `--json` output is planned.

> Known gap: passing `--language` and `--model` together can silently conflict. If you pick an English-only model with a non-English language, the language is ignored without warning. Set one or the other until this is fixed.

---

## How it works

```
Mic  ──► Lane A ──► VAD ──► Whisper ──────────────────► You
Speakers ──► Lane B ──► VAD ──► Whisper ─────────────► Others   (live)
                    └─► SpeakerKit ──► Speaker 1..N ──► Whisper per span
                                                        (after you stop)
                         (never mix A+B before ASR)
```

Three design rules carry the whole product:

1. **Never mix Lane A and Lane B before speech recognition.** Mixing is what makes other tools produce garbled text under overlap — once two voices share a waveform, the transcript cannot recover who said what. This is the core invariant.
2. **You are always Lane A.** Your identity comes from the wire, never from diarization, so it is never wrong.
3. **Remote people live on Lane B**, where system audio carries several voices on one wire — which is exactly why diarization is needed rather than a simple "You vs Others" split.

See [docs/plan.md](docs/plan.md) for the full architecture and milestone history. Note that the plan predates parts of the implementation and describes some choices (TOML config, a Core Audio process tap) that the code does not currently use.

---

## Stack

- **Swift** — single SPM executable
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** — on-device STT (Core ML / Apple Neural Engine)
- **SpeakerKit** — on-device diarization (Pyannote / Core ML), shipped in the WhisperKit package
- **AVAudioEngine** — microphone (Lane A)
- **ScreenCaptureKit** — system / speaker audio (Lane B)

---

## Contributing

Bug reports and small focused PRs are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md), which lists good first issues and the concurrency rules for the audio path. Security problems go through [SECURITY.md](SECURITY.md), not the public issue tracker. Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Acknowledgments

Listnr is original code, but it learned from several projects:

| Project | What was used |
|---|---|
| **[parrot](https://github.com/digimata/parrot)** by [digimata](https://github.com/digimata) | Patterns adapted, not forked: `AVAudioEngine` mic → 16 kHz Float32, the WhisperKit warm-up/transcribe wrapper, doctor/setup permission UX, WAV dump helper. The meeting loop is different. |
| **[meetily](https://github.com/Zackriya-Solutions/meetily)** by [Zackriya-Solutions](https://github.com/Zackriya-Solutions) | **Ideas only** — dual mic + system-audio lanes, "don't mix before ASR" for identity, the session/notes product shape. Listnr ships **no** Meetily code; Lane B is ScreenCaptureKit in Swift, not Meetily's Rust/Core Audio tap. |
| **[WhisperKit](https://github.com/argmaxinc/WhisperKit) / SpeakerKit** by [Argmax](https://www.argmaxinc.com) | Direct dependencies for on-device transcription and diarization. |

## License

[MIT](LICENSE) © 2026 Rokibul Hasan

Dependencies are MIT (WhisperKit, SpeakerKit, yyjson) or Apache-2.0 (swift-argument-parser, swift-transformers, and other Apple/Hugging Face packages). Model weights are downloaded at runtime from Hugging Face and carry their own licenses from their respective publishers.
