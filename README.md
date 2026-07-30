# Listnr

**A local meeting listener for macOS.** It captures **your microphone** and **your speaker / system audio** as two separate lanes, transcribes both on-device, and labels **You** plus remote **Speaker 1...N**. No Discord, Zoom, or Meet integration required, and nothing is sent anywhere.

Anything that plays through the Mac's output is Lane B. Your audio never leaves your machine.

[![CI](https://github.com/rokib16x/listnr/actions/workflows/ci.yml/badge.svg)](https://github.com/rokib16x/listnr/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B%20·%20Apple%20Silicon-lightgrey)

**Requires:** macOS 14 or later on Apple Silicon (M1 or newer). Intel Macs are not supported.

---

## Why I built this

My team runs on calls. Two or three of us, a few times a day, deciding things that then have to get done. Every single time, one of two things happened: either somebody took notes and stopped participating properly, or nobody took notes and we rebuilt the decision from memory two days later, badly.

So I went looking for a tool. Everything I found wanted one of three things I was not willing to give it.

**A bot in the call.** Most meeting tools join as a participant. That means it only works on the platforms they support, it shows up in the invite, and everyone can see it sitting there. We move between Discord, Meet, and a plain phone call on speaker depending on who is around. I wanted something that does not care what app the sound comes out of.

**My conversations on somebody's server.** These calls are about unreleased work, salaries, people, and things I have not thought through yet. Uploading all of that to a company whose retention policy I have not read, so I can get a summary back, was never a trade I wanted to make. On an M-series Mac the Neural Engine will happily run Whisper locally, so there is no reason the audio has to leave the room.

**A subscription per seat, forever, for a transcript.** Fine for some teams. Not for this.

The last thing that pushed me into writing it: I tried the mix-everything-together approach first, and it does not work. If you take your microphone and the call audio, add them into one waveform, and hand that to Whisper, you get plausible text with the speakers scrambled. When two people talk at once you get an invented sentence. And the transcript is confidently wrong, which is worse than having no transcript at all, because you cannot tell which lines to trust.

That failure is what the whole design is built around. **Your microphone is one lane. The speaker output is another lane. They never get mixed before transcription.** Your voice is identified by which wire it arrived on, so it is never wrong. The remote voices share one wire, so they get run through speaker diarization to split them apart. It is more work than mixing, and it is the only way I found to get a transcript I actually believe.

What I use it for now:

- Standups, so I can be in the conversation instead of typing during it.
- Design and debugging calls, where the useful part is usually a throwaway sentence somebody said twenty minutes in.
- Client and interview calls, with everyone's agreement, so I can go back to exact wording instead of my recollection of it.
- Calls in Bangla and Hindi mixed with English, which most tools handle poorly.

It is a CLI because that is what I needed first and it was quick to build. A menubar app is on the roadmap.

If any of that sounds like your problem too, it should work for you. If you make it better, [send a PR](CONTRIBUTING.md).

---

## Status: beta

Listnr is at **`0.1.0-beta`**. The core pipeline works and produces transcripts I rely on, but this is early software with one maintainer, and the CLI may change in any `0.x` release.

Please read these before filing an issue, they are all known:

| Limitation | Detail |
|---|---|
| **Diarization runs after the session, not live** | While a session is running, all remote audio is labeled `Others`. The `Speaker 1...N` split is computed once you stop. Live per-speaker labels are planned. |
| **Memory grows with session length** | Whole-session audio is kept in RAM, roughly **460 MB per hour** across both lanes. Long sessions are memory-hungry. Spilling to disk is planned. |
| **Voice detection thresholds are fixed** | Speech detection uses absolute RMS values. A very quiet or very hot microphone may need the numbers changed in code. |
| **Settings do not persist** | `/lang`, `/model`, `/speakers`, and `/dump` all reset when you quit. |
| **No test suite yet** | See [CONTRIBUTING.md](CONTRIBUTING.md). This is the most useful place to help. |
| **No GUI** | CLI only for now. |

Found something that is not on this list? [Open an issue](https://github.com/rokib16x/listnr/issues/new/choose).

---

## Before you record other people

Listnr records the voice of everyone on your call. **In a lot of places, doing that without their consent is illegal.**

- **All-party consent jurisdictions**, which include California, Illinois, Florida, Pennsylvania, Washington, and much of the EU under GDPR, require consent from *every* participant, not just you.
- The rules vary by state, by country, and by whether the call is business or personal. They apply to the act of *recording*, not only to sharing what you recorded.

**Complying with the law where you and every participant are located is your responsibility.** Tell people you are recording, get their agreement, and accept no for an answer. This software is provided as-is with no liability for how it gets used, see the [LICENSE](LICENSE).

The polite version is also the easy version. Say "I'm running a local transcriber, any objections?" at the top of the call and get on with it.

---

## Privacy: what stays local and what does not

**Your audio and your transcripts never leave your machine.** There is no cloud transcription, no telemetry, no analytics, no crash reporting, and no account.

There is exactly one outbound network request Listnr ever makes, and it is worth being upfront about:

> **On first run it downloads model weights from Hugging Face** (`huggingface.co`), specifically `argmaxinc/whisperkit-coreml` for transcription and `argmaxinc/speakerkit-coreml` for diarization. That is between 145 MB and 1.6 GB depending on which model you pick. No audio, no text, and nothing identifying is sent. It is a plain file download and it happens once per model.

Once the models are cached, Listnr runs fully offline. If you want to confirm that, fetch a model and then pull your network connection:

```sh
listnr models download whisper-base.en
```

What gets written to disk:

| What | Where | Notes |
|---|---|---|
| Transcripts | `~/Documents/Listnr/listnr_*.md` | **Not encrypted.** Nothing deletes them for you. |
| Models | WhisperKit's model cache | Reused across sessions. |
| Config | `~/Library/Application Support/listnr/config.json` | Read, but currently never written. |
| `/dump` audio | `/tmp/listnr-mic.wav`, `/tmp/listnr-sys.wav` | See the warning below. |

> **Known privacy defect:** `/dump` writes raw meeting audio to `/tmp` at predictable filenames, and `/tmp` is world-readable on macOS. On a shared Mac, other local users can read it. Treat `/dump` as a single-user debugging tool until this is fixed. It is on the list for the next release.

---

## Install

Source-only for now, so no Homebrew tap and no signed binary yet. You need Xcode 15 or later (Swift 5.9+).

```sh
git clone https://github.com/rokib16x/listnr.git
cd listnr
swift build -c release
```

Grant the permissions once, then check them:

```sh
.build/release/listnr setup     # mic + Screen & System Audio Recording
.build/release/listnr doctor    # verify permissions
```

Put it somewhere on your `PATH` so you can just type `listnr`:

```sh
sudo cp .build/release/listnr /usr/local/bin/listnr
```

### About the permissions

Listnr needs two, and macOS attaches both to your **terminal application** rather than to the `listnr` binary itself:

| Permission | Why |
|---|---|
| **Microphone** | Lane A, your voice |
| **Screen & System Audio Recording** | Lane B, the speaker output, which is everyone else |

Two things follow from that. Switching from Terminal to iTerm means granting them again, and macOS usually needs the Settings toggle plus a relaunch before it takes effect. `listnr doctor` will tell you which one is missing.

The Screen Recording permission is how macOS gates system audio capture through ScreenCaptureKit. Listnr asks for a 2x2 pixel video stream that it never reads, purely because the API insists on one. **No screen content is captured, stored, or transmitted.** You can check that yourself in [`Sources/Listnr/Capture/SystemAudioCapture.swift`](Sources/Listnr/Capture/SystemAudioCapture.swift).

---

## How to use it

1. Put on a **headset**. This matters more than anything else on this page. Open speakers leak the remote voices back into your microphone, which puts the same person on both lanes and ruins the speaker separation.
2. Join a call, or just play audio through the speakers.
3. Start it:

```sh
listnr
```

4. At the prompt:

```text
listnr> /live              # listen until you stop it
listnr> /live 30           # 30 seconds, then report
listnr> /live 300          # 5 minutes, then report
```

5. To finish, type `q` or `/stop` and press Enter, or press **Ctrl+C**.
6. You get the transcript on screen, and a Markdown copy in `~/Documents/Listnr/`.

### Language

```text
listnr> /lang en           # English (whisper-base.en by default)
listnr> /lang auto         # multilingual (whisper-large-v3-turbo)
listnr> /lang bn           # Bangla hint plus the multilingual model
```

Set the language explicitly rather than using `auto`. Auto-detection is slower and it guesses wrong a lot on short clips. Any non-English language pulls the 1.6 GB turbo model the first time.

### Other commands

```text
listnr> /speakers 2        # how many remote people to expect (1-6)
listnr> /model whisper-small.en
listnr> /dump              # toggle WAV dumps to /tmp (read the privacy note first)
listnr> /diarize           # toggle SpeakerKit
listnr> /status
listnr> /help
listnr> quit
```

### One-shot, no shell

```sh
listnr start --seconds 60 --speakers 2
listnr start --language auto --seconds 120
listnr start                 # until Ctrl+C
listnr models list
```

The finished transcript goes to **stdout**. Progress, level meters, and diagnostics go to **stderr**, so you can redirect just the transcript. Structured `--json` output is planned.

> Known gap: `--language` and `--model` can silently contradict each other. If you pick an English-only model together with a non-English language, the language gets ignored without warning. Set one or the other for now.

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

1. **Lane A and Lane B are never mixed before transcription.** This is the core invariant. Once two voices share one waveform, no amount of post-processing recovers who said what, and Whisper will invent text rather than admit it.
2. **You are always Lane A.** Your identity comes from which wire the audio arrived on, so it cannot be misattributed.
3. **Remote people live on Lane B**, where several voices arrive on a single wire. That is exactly why diarization is needed instead of a simple "You versus Others" split.

[docs/plan.md](docs/plan.md) has the full architecture and the milestone history. Be aware that the plan predates some of the implementation, and describes a couple of choices (TOML config, a Core Audio process tap) that the code does not currently use.

---

## Stack

- **Swift**, a single SPM executable
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** for on-device speech recognition (Core ML and the Apple Neural Engine)
- **SpeakerKit** for on-device diarization (Pyannote via Core ML), which ships inside the WhisperKit package
- **AVAudioEngine** for the microphone (Lane A)
- **ScreenCaptureKit** for system and speaker audio (Lane B)

---

## Contributing

Bug reports and small, focused PRs are both very welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the build instructions, a list of good first issues, and the concurrency rules for the audio path. Security problems go through [SECURITY.md](SECURITY.md) rather than the public issue tracker. Everyone taking part is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Acknowledgments

Listnr is original code, but it learned from other people's work:

| Project | What it gave Listnr |
|---|---|
| **[parrot](https://github.com/digimata/parrot)** by [digimata](https://github.com/digimata) | Patterns I adapted rather than forked: `AVAudioEngine` microphone into 16 kHz Float32, the WhisperKit warm-up and transcribe wrapper, the doctor and setup permission flow, and the WAV dump helper. The meeting loop itself is different. |
| **[meetily](https://github.com/Zackriya-Solutions/meetily)** by [Zackriya-Solutions](https://github.com/Zackriya-Solutions) | Ideas only: separate microphone and system audio lanes, not mixing before transcription, and the general shape of a session-and-notes product. No Meetily code ships here, and Lane B is ScreenCaptureKit in Swift rather than Meetily's Rust and Core Audio tap. |
| **[WhisperKit](https://github.com/argmaxinc/WhisperKit) and SpeakerKit** by [Argmax](https://www.argmaxinc.com) | Direct dependencies for on-device transcription and diarization. |

## License

[MIT](LICENSE), Copyright (c) 2026 Rokibul Hasan.

Dependencies are MIT (WhisperKit, SpeakerKit, yyjson) or Apache-2.0 (swift-argument-parser, swift-transformers, and the other Apple and Hugging Face packages). Model weights get downloaded at runtime from Hugging Face and carry their own licenses from whoever published them.
