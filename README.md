# Listnr

**A local meeting listener for macOS.** It captures **your microphone** and **your speaker / system audio** as two separate lanes, transcribes both on-device, and labels **You** plus remote **Speaker 1...N**. No bot in the call, no cloud, no account.

Speak English, Bangla, Hindi, Spanish, French, German, Japanese, or Chinese — and optionally have any of them translated to English as it is transcribed.

[![CI](https://github.com/rokib16x/listnr/actions/workflows/ci.yml/badge.svg)](https://github.com/rokib16x/listnr/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)

**Requires:** macOS 14 or later on Apple Silicon (M1 or newer). Intel Macs are not supported.

```sh
brew install rokib16x/tap/listnr
listnr setup && listnr
```

---

## Why I built this

My team decides things on calls. Every one of them ended the same way: either somebody took notes and stopped participating, or nobody took notes and we rebuilt the decision from memory two days later, badly.

Every tool I found wanted one of three things I was not willing to give it. **A bot in the call** — it only works on the platforms they support, and it shows up in the invite; we move between Discord, Meet, and a phone on speaker depending on who is around. **My conversations on somebody's server** — these calls are about unreleased work, salaries, and things I have not thought through yet, and an M-series Mac will run Whisper locally, so there is no reason the audio has to leave the room. **A subscription per seat, forever, for a transcript.**

The design comes from what failed first. I tried mixing the microphone and the call audio into one waveform and handing that to Whisper. You get plausible text with the speakers scrambled, invented sentences whenever two people talk at once, and a transcript that is confidently wrong — which is worse than no transcript, because you cannot tell which lines to trust.

So **the two lanes never get mixed before transcription.** Your voice is identified by which wire it arrived on, so it can never be misattributed. The remote voices share one wire, so they go through speaker diarization to be split apart. More work than mixing, and the only way I found to get a transcript I actually believe.

I use it for standups, design and debugging calls, and client calls with everyone's agreement — including calls in Bangla and Hindi mixed with English, which most tools handle poorly.

It is a CLI because that is what I needed first. A menubar app is on the roadmap. If you make it better, [send a PR](CONTRIBUTING.md).

---

## Status: beta

Listnr is at **`0.1.1-beta`**. The core pipeline works and produces transcripts I rely on, but this is early software with one maintainer, and the CLI may change in any `0.x` release.

These are all known — please read before filing an issue:

| Limitation | Detail |
|---|---|
| **Diarization runs after the session** | While a session runs, remote audio is labeled `Others`. The `Speaker 1...N` split is computed when you stop. Live labels are planned. |
| **Memory grows with session length** | Whole-session audio is kept in RAM, roughly **460 MB per hour** across both lanes. Spilling to disk is planned. |
| **Non-English is much weaker than English** | Whisper itself is far better at English than at Bangla or Hindi, at every model size. Listnr tunes its thresholds per writing system so it does not make this worse ([details](docs/models.md)), but it cannot close the gap. |
| **Translation is English-only and one-way** | `/translate` uses Whisper's own task, which only targets English. No Bangla → Hindi, and the original wording is not kept alongside it. |
| **Voice detection thresholds are fixed** | Speech detection uses absolute RMS. A very quiet or very hot microphone may need the numbers changed in code. |
| **Settings do not persist** | `/lang`, `/model`, `/speakers`, `/diarize`, `/translate`, and `/dump` all reset when you quit. |
| **The capture layer has no automated tests** | 136 unit tests cover the pure logic. Anything touching real hardware is verified manually. |
| **No GUI** | CLI only for now. |

Found something not on this list? [Open an issue](https://github.com/rokib16x/listnr/issues/new/choose).

---

## Before you record other people

Listnr records the voice of everyone on your call. **In a lot of places, doing that without their consent is illegal.**

- **All-party consent jurisdictions** — including California, Illinois, Florida, Pennsylvania, Washington, and much of the EU under GDPR — require consent from *every* participant, not just you.
- The rules vary by state, by country, and by whether the call is business or personal. They apply to the act of *recording*, not only to sharing it.

**Complying with the law where you and every participant are located is your responsibility.** Tell people you are recording, get their agreement, and accept no for an answer. This software is provided as-is with no liability for how it gets used; see the [LICENSE](LICENSE).

The polite version is also the easy version. Say "I'm running a local transcriber, any objections?" at the top of the call and get on with it.

---

## Privacy

**Your audio and your transcripts never leave your machine.** No cloud transcription, no telemetry, no analytics, no crash reporting, no account.

There is exactly one outbound request Listnr ever makes:

> **On first run it downloads model weights from Hugging Face** (`argmaxinc/whisperkit-coreml` for transcription, `argmaxinc/speakerkit-coreml` for diarization) — between 73 MB and 1.5 GB depending on the model, plus about 150 MB for diarization. No audio, no text, nothing identifying is sent. A plain file download, once per model.

After that it runs fully offline. To confirm, fetch a model and pull your network connection:

```sh
listnr models download whisper-base.en
```

What gets written to disk:

| What | Where | Notes |
|---|---|---|
| Transcripts | `~/Documents/Listnr/listnr_*.md` | **Not encrypted.** Nothing deletes them for you. |
| Models | `~/Documents/huggingface/models/argmaxinc/` | WhisperKit's cache; safe to delete to reclaim disk. |
| Config | `~/Library/Application Support/listnr/config.json` | Read, but currently never written. |
| `/dump` audio | `~/Documents/Listnr/debug/listnr-*.wav` | Raw session audio, owner-only (0600). Delete after debugging. |

---

## Install

### Homebrew

```sh
brew install rokib16x/tap/listnr
```

> Not live yet — the tap is being set up. Use a pre-built binary or build from source until then.

### Pre-built binary

Apple Silicon only. Each [release](https://github.com/rokib16x/listnr/releases) ships the binary, shell completions, and a man page.

```sh
V=0.1.2-beta
curl -LO "https://github.com/rokib16x/listnr/releases/download/v$V/listnr-$V-macos-arm64.tar.gz"
tar -xzf "listnr-$V-macos-arm64.tar.gz"
sudo cp "listnr-$V-macos-arm64/listnr" /usr/local/bin/listnr
```

While Listnr is a `0.x` prerelease, the URL needs the explicit tag — GitHub's `/releases/latest/` excludes prereleases and will 404.

If you download it through a browser instead of `curl`, macOS quarantines it and refuses to run it. Clear that with `xattr -dr com.apple.quarantine listnr`.

### From source

Needs Xcode 15 or later (Swift 5.9+). Homebrew builds from source too, so either way the first install takes a few minutes.

```sh
git clone https://github.com/rokib16x/listnr.git
cd listnr
swift build -c release
sudo cp .build/release/listnr /usr/local/bin/listnr
```

### Grant the permissions

```sh
listnr setup     # mic + Screen & System Audio Recording
listnr doctor    # verify
```

Listnr needs two permissions, and macOS attaches both to your **terminal application** rather than to the `listnr` binary:

| Permission | Why |
|---|---|
| **Microphone** | Lane A, your voice |
| **Screen & System Audio Recording** | Lane B, the speaker output, which is everyone else |

Two things follow. Switching from Terminal to iTerm means granting them again, and macOS usually needs the Settings toggle plus a relaunch. `brew upgrade` will *not* re-prompt. `listnr doctor` tells you which one is missing.

Both are required to start; there is no microphone-only mode, because a meeting transcript without the other side is not one.

The Screen Recording permission is how macOS gates system audio through ScreenCaptureKit. Listnr asks for a 2x2 pixel video stream it never reads, purely because the API insists on one. **No screen content is captured, stored, or transmitted** — see [`SystemAudioCapture.swift`](Sources/ListnrCore/Capture/SystemAudioCapture.swift).

---

## Usage

1. Put on a **headset**. This matters more than anything else on this page — open speakers leak the remote voices back into your microphone, which puts the same person on both lanes and ruins the speaker separation.
2. Join a call, or just play audio through the speakers.
3. Run `listnr`, then:

```text
listnr> /live              # listen until you stop it
listnr> /live 30           # 30 seconds, then report
```

4. Type `q` or `/stop` and press Enter to finish. **Ctrl+C** cancels without a transcript.
5. The transcript prints, and a Markdown copy lands in `~/Documents/Listnr/`.

```text
[00:02] You: Morning. Quick one today, I want to close out the export bug.
[00:09] Speaker 1: Sounds good. I reproduced it, it only happens when the file name has a colon.
[00:17] You: That matches what I saw. I'll strip reserved characters and add a test.
[00:26] Speaker 1: Ship it behind the flag first, the installer folks asked us not to change file names silently.
```

Your microphone is always `You`. Remote voices become `Speaker 1...N` after the session ends, when diarization runs.

### Language and translation

```text
listnr> /lang en           # English (whisper-base.en, 139 MB)
listnr> /lang bn           # Bangla · also hi, es, fr, de, ja, zh
listnr> /lang auto         # detect once at the start, then lock
listnr> /translate         # speak any language, transcript comes out English
```

Each language picks a sensible default model, so `/lang` is usually all you touch. Name the language rather than using `auto` — detection runs once per session and locks, but it still has to make that call on a second or two of speech.

Two things are worth knowing before you tune anything:

- **The non-English defaults are not the most accurate models, on purpose.** They aim to keep pace with a live conversation, because a model that cannot has its audio dropped by the pipeline — you lose whole utterances rather than getting rougher text. Reach for `/model whisper-large-v2` when accuracy matters more than latency.
- **`/translate` switches models automatically.** The turbo builds cannot translate at all — they silently return the original language — so turning it on moves you to `whisper-large-v2`.

Full model table, the reasoning behind each default, and why non-English used to look broken: **[docs/models.md](docs/models.md)**.

### Other commands

```text
listnr> /speakers 2        # how many remote people to expect (1-6)
listnr> /model <id>        # see `listnr models list`
listnr> /diarize           # toggle SpeakerKit
listnr> /dump              # toggle WAV dumps to ~/Documents/Listnr/debug
listnr> /status            # show current options
listnr> /help
```

### One-shot, no shell

```sh
listnr start --seconds 60 --speakers 2
listnr start --language bn --seconds 120                # Bangla transcript
listnr start --language bn --translate --seconds 120    # English transcript
listnr start                                            # until Ctrl+C
listnr models list
listnr models download whisper-large-v2                 # pre-fetch before a call
```

The transcript goes to **stdout**; progress, level meters, and diagnostics go to **stderr**, so you can redirect just the transcript. Structured `--json` output is planned.

Contradictory options — an English-only model with a non-English language, or a turbo model with `--translate` — are reported before the session starts rather than quietly producing the wrong thing.

### Something wrong?

Missing text, gibberish, or dropped words each print a specific line to stderr that says which it is. **[docs/troubleshooting.md](docs/troubleshooting.md)** maps each one to a fix.

---

## How it works

```
Mic       ──► Lane A ──► VAD ──► Whisper ────────────────► You
Speakers  ──► Lane B ──► VAD ──► Whisper ───────────────► Others   (live)
                     └─► SpeakerKit ──► Speaker 1..N ──► Whisper per span
                                                         (after you stop)
                          (A and B are never mixed before transcription)
```

Three rules hold the whole thing together:

1. **Lane A and Lane B are never mixed before transcription.** Once two voices share one waveform, no post-processing recovers who said what, and Whisper will invent text rather than admit it.
2. **You are always Lane A.** Your identity comes from which wire the audio arrived on, so it cannot be misattributed.
3. **Remote people live on Lane B**, where several voices arrive on a single wire — which is exactly why diarization is needed instead of a simple "You versus Others" split.

[docs/plan.md](docs/plan.md) has the full architecture and milestone history. It predates some of the implementation and describes a couple of choices (TOML config, a Core Audio process tap) the code does not use.

## Stack

- **Swift**, one SPM package: a `ListnrCore` library plus a one-line executable
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** for on-device speech recognition (Core ML + Apple Neural Engine)
- **SpeakerKit** for on-device diarization (Pyannote via Core ML), shipped inside WhisperKit
- **AVAudioEngine** for the microphone (Lane A), **ScreenCaptureKit** for system audio (Lane B)

## Contributing

Bug reports and small, focused PRs are both very welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has build instructions, good first issues, and the concurrency rules for the audio path. Security problems go through [SECURITY.md](SECURITY.md) rather than the public tracker. Everyone taking part is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).

Cutting a release or setting up the Homebrew tap: [packaging/README.md](packaging/README.md).

## Acknowledgments

Listnr is original code, but it learned from other people's work:

| Project | What it gave Listnr |
|---|---|
| **[parrot](https://github.com/digimata/parrot)** by [digimata](https://github.com/digimata) | Patterns I adapted rather than forked: `AVAudioEngine` microphone into 16 kHz Float32, the WhisperKit warm-up and transcribe wrapper, the doctor and setup permission flow, and the WAV dump helper. The meeting loop itself is different. |
| **[meetily](https://github.com/Zackriya-Solutions/meetily)** by [Zackriya-Solutions](https://github.com/Zackriya-Solutions) | Ideas only: separate microphone and system audio lanes, not mixing before transcription, and the general shape of a session-and-notes product. No Meetily code ships here, and Lane B is ScreenCaptureKit in Swift rather than Meetily's Rust and Core Audio tap. |
| **[WhisperKit](https://github.com/argmaxinc/WhisperKit) and SpeakerKit** by [Argmax](https://www.argmaxinc.com) | Direct dependencies for on-device transcription and diarization. |

## License

[MIT](LICENSE), Copyright (c) 2026 Rokibul Hasan.

Dependencies are MIT (WhisperKit, SpeakerKit, yyjson) or Apache-2.0 (swift-argument-parser, swift-transformers, and the other Apple and Hugging Face packages). Model weights download at runtime from Hugging Face and carry their own licenses.
