# Listnr

**A local meeting listener for macOS.** It captures **your microphone** and **your speaker / system audio** as two separate lanes, transcribes both on-device, and labels **You** plus remote **Speaker 1...N**. No Discord, Zoom, or Meet integration required, and nothing is sent anywhere.

Anything that plays through the Mac's output is Lane B. Your audio never leaves your machine.

Speak English, Bangla, Hindi, Spanish, French, German, Japanese, or Chinese — and optionally have any of them [translated to English](#translating-to-english) as it is transcribed.

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

Listnr is at **`0.1.1-beta`**. The core pipeline works and produces transcripts I rely on, but this is early software with one maintainer, and the CLI may change in any `0.x` release.

Please read these before filing an issue, they are all known:

| Limitation | Detail |
|---|---|
| **Diarization runs after the session, not live** | While a session is running, all remote audio is labeled `Others`. The `Speaker 1...N` split is computed once you stop. Live per-speaker labels are planned. |
| **Memory grows with session length** | Whole-session audio is kept in RAM, roughly **460 MB per hour** across both lanes. Long sessions are memory-hungry. Spilling to disk is planned. |
| **Voice detection thresholds are fixed** | Speech detection uses absolute RMS values. A very quiet or very hot microphone may need the numbers changed in code. |
| **Non-English is much weaker than English** | Whisper itself is far better at English than at Bangla, Hindi, or Tamil, at every model size. Listnr tunes its thresholds per writing system so it does not make this worse (see [Language](#language)), but it cannot close the gap. English will feel polished and Bangla will not. |
| **Translation is English-only and one-way** | `/translate` uses Whisper's own task, which only targets English. There is no Bangla → Hindi, and no way to keep the original wording alongside the translation. |
| **Settings do not persist** | `/lang`, `/model`, `/speakers`, `/diarize`, `/translate`, and `/dump` all reset when you quit. |
| **The capture layer has no automated tests** | 136 unit tests cover the VAD, text filters, confidence gates, script tuning, repetition guard, model registry, merger, and lane pipeline. Everything that touches real hardware (mic, ScreenCaptureKit, models) is verified manually. |
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

> **On first run it downloads model weights from Hugging Face** (`huggingface.co`), specifically `argmaxinc/whisperkit-coreml` for transcription and `argmaxinc/speakerkit-coreml` for diarization. That is between 73 MB and 1.5 GB depending on which model you pick, plus about 150 MB for diarization. No audio, no text, and nothing identifying is sent. It is a plain file download and it happens once per model.

Once the models are cached, Listnr runs fully offline. If you want to confirm that, fetch a model and then pull your network connection:

```sh
listnr models download whisper-base.en
```

What gets written to disk:

| What | Where | Notes |
|---|---|---|
| Transcripts | `~/Documents/Listnr/listnr_*.md` | **Not encrypted.** Nothing deletes them for you. |
| Models | `~/Documents/huggingface/models/argmaxinc/` | WhisperKit's default cache; reused across sessions, safe to delete to reclaim disk. |
| Config | `~/Library/Application Support/listnr/config.json` | Read, but currently never written. |
| `/dump` audio | `~/Documents/Listnr/debug/listnr-*.wav` | Raw session audio, written with owner-only permissions (0600). Delete after debugging. |

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

Both permissions are required to start: there is no microphone-only mode today, because a meeting transcript without the other side is not one. If you only want to test your own voice, grant both anyway; Lane B simply stays silent.

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

5. To finish, type `q` or `/stop` and press Enter. (**Ctrl+C** cancels without a transcript.)
6. You get the transcript on screen, and a Markdown copy in `~/Documents/Listnr/`.

### What the output looks like

A short (fictional) standup, one teammate on the call:

```text
[00:02] You: Morning. Quick one today, I want to close out the export bug.
[00:09] Speaker 1: Sounds good. I reproduced it, it only happens when the file name has a colon.
[00:17] You: That matches what I saw. I'll strip reserved characters and add a test.
[00:26] Speaker 1: Ship it behind the flag first, the installer folks asked us not to change file names silently.
[00:38] You: Fair. Flag first, default on next release. Anything else?
[00:44] Speaker 1: Nothing from me.
```

Your microphone is always `You`. Remote voices become `Speaker 1...N` after the
session ends, when diarization runs. The same content is saved as Markdown with
a timestamped filename.

### Language

```text
listnr> /lang en           # English
listnr> /lang bn           # Bangla · also hi, es, fr, de, ja, zh
listnr> /lang auto         # detect once at the start of the session, then lock
```

Each language picks a sensible default model, so `/lang` is usually the only thing you touch. `/model` overrides it.

**Name the language rather than using `auto`.** Detection runs once per session and then locks, which is a large improvement over detecting per clip — that was the cause of auto mode's worst behaviour, because consecutive sentences of one conversation could be decoded as different languages and the output read as gibberish. It still has to make that one call on a second or two of speech, and naming the language costs you nothing.

#### Why non-English used to look broken

Worth knowing, because it explains what changed and what the warnings mean. Whisper reports a confidence score per segment, and Listnr uses it to throw away hallucinated text. Those scores are **not comparable across writing systems**:

- Whisper's tokenizer is English-centric, so Bengali and Devanagari cost several times more tokens per word, each individually less confident. Correct Bangla averages around −1.2 on a scale where English speech sits above −0.9.
- Compression ratio flags repetition loops, but Indic and Han text is three bytes per character from a small repertoire, so an *ordinary* sentence compresses like a degenerate one.

Listnr used to apply the English numbers to every language. Correct Bangla scored as a hallucination, got discarded, and nothing was logged — the language looked like it simply did not work. Thresholds are now keyed on writing system, and when segments *are* dropped you get a line saying so:

```text
! dropped 3 low-confidence segment(s) [lang=bn, script=indic]. If speech is missing, try /model whisper-large-v2
```

#### Models

`listnr models list` prints this at any time. `★` is the English default, `→en` means the model can translate.

| Model | Size | Languages | Translates | Role |
|---|---|---|---|---|
| `whisper-base.en` | 139 MB | English | — | **★ Default for `/lang en`.** Fast and accurate |
| `whisper-small.en` | 463 MB | English | — | English, more accurate, slower |
| `whisper-tiny` | 73 MB | all | ✓ | Too weak to rely on; useful for A/B tests |
| `whisper-base` | 139 MB | all | ✓ | Multilingual sibling of the English default |
| `whisper-small` | 207 MB | all | ✓ | Lightest usable multilingual. OK for es/fr/de, weak on Bangla |
| `whisper-medium` | 1.4 GB | all | ✓ | **Default for `es`/`fr`/`de`** |
| `whisper-large-v2` | 908 MB | all | ✓ | **Most accurate for Bangla and Hindi. Default when translating** |
| `whisper-large-v3-turbo-fast` | 615 MB | all | ✗ | **Default for `bn`/`hi`/`ja`/`zh`/`auto`.** Quantized |
| `whisper-large-v3-turbo` | 1.5 GB | all | ✗ | Full precision. Slower for no real accuracy gain |

Three things about this table are not obvious:

**The non-English defaults are not the most accurate option, on purpose.** They aim to keep pace with a live conversation, because a model that cannot is worse than a smaller one — the lane pipeline drops audio it cannot transcribe in time, so you lose whole utterances rather than getting slightly rougher text. Move up with `/model whisper-large-v2` when accuracy matters more than latency.

**`whisper-large-v2` is smaller than `whisper-medium` *and* better.** It is a quantized build, so medium is never the right choice for Bangla or Hindi. Pick large-v2 or, if 908 MB is too much, `whisper-small`.

**large-v2 rather than a v3 for the accuracy pick is deliberate.** `large-v3-turbo` is distilled from thirty-two decoder layers down to four, and that loss lands hardest on the languages with the least training data behind them — exactly Bangla and Hindi.

Be realistic about the ceiling. Whisper is much weaker on Bangla than on English at every size. English feeling polished while Bangla feels rough is partly the models, not only the configuration.

### Translating to English

Speak Bangla, Hindi, or anything else Whisper supports, and get an English transcript:

```text
listnr> /translate                              # toggle; transcript comes out English
```

```sh
listnr start --language bn --translate --seconds 60
```

This is Whisper's own `translate` task, so there is no second model, no extra pass, and no added latency beyond the model itself. Four things to know:

**It only goes into English.** Whisper cannot target any other language. There is no Bangla → Hindi. English in with `/translate` on is a no-op, and Listnr tells you so.

**The original wording is not kept.** Every line is English. If the native transcript is the record you need, leave `/translate` off.

**The turbo models cannot do it — silently.** OpenAI fine-tuned `large-v3-turbo` for transcription only; it "will return the original language even if `--task translate` is specified." No error, just the wrong language for the length of your meeting. Since the turbo build is Listnr's *transcription* default for `bn`/`hi`/`ja`/`zh`, Listnr handles this for you:

- Turning on `/translate` re-picks the model (→ `whisper-large-v2`) instead of leaving one that ignores the request.
- Naming an incapable model explicitly is **refused before the session starts**, with the capable ones listed.
- `listnr models list` marks capable models with `→en`.

**The default here favours quality over size**, unlike the transcription defaults, because translation is a harder task and degrades faster as models shrink:

| `/model` | Size | Translation quality |
|---|---|---|
| `whisper-small` | 207 MB | Lightest usable. Rough, but intelligible for Hindi |
| `whisper-large-v2` | 908 MB | **Default.** Best available |
| `whisper-medium` | 1.4 GB | Good, but larger than large-v2 and worse — no reason to pick it |
| `whisper-tiny`, `whisper-base` | 73 / 139 MB | Not worth running |

There is no 200 MB model that turns Bangla speech into clean English. `whisper-small` translating Bangla will be noticeably rougher than `whisper-base.en` transcribing English.

### Other commands

```text
listnr> /speakers 2        # how many remote people to expect (1-6)
listnr> /model whisper-small.en
listnr> /dump              # toggle WAV dumps to ~/Documents/Listnr/debug
listnr> /diarize           # toggle SpeakerKit
listnr> /translate         # speak any language, transcript comes out English
listnr> /status
listnr> /help
listnr> quit
```

### One-shot, no shell

```sh
listnr start --seconds 60 --speakers 2
listnr start --language bn --seconds 120                  # Bangla transcript
listnr start --language bn --translate --seconds 120      # English transcript
listnr start --language hi --model whisper-large-v2       # accuracy over speed
listnr start                                             # until Ctrl+C
listnr models list
listnr models download whisper-large-v2                   # pre-fetch before a call
```

The finished transcript goes to **stdout**. Progress, level meters, and diagnostics go to **stderr**, so you can redirect just the transcript. Structured `--json` output is planned.

If `--language` and `--model` contradict each other — an English-only model with a non-English language, or a turbo model with `--translate` — Listnr says so before the session starts instead of quietly producing the wrong thing.

---

## Troubleshooting

Everything below writes to **stderr**, so you will see it even when you redirect the transcript.

### Nothing appears for a non-English language

Look for this line:

```text
! dropped 3 low-confidence segment(s) [lang=bn, script=indic]
```

Whisper heard you and the confidence gate rejected the result. If it fires on speech you know was clear, the thresholds are still too tight for your audio — [open an issue](https://github.com/rokib16x/listnr/issues/new/choose) with the line, the language, and the model. `/model whisper-large-v2` usually clears it, because a better model scores higher.

If there is no such line and the level meter shows `mic=0.000`, it is the microphone, not the transcription. Check System Settings → Sound → Input, and run `listnr doctor`.

### Words go missing in the middle of a conversation

```text
! You: dropped 12 audio buffer(s) and 4 speech segment(s), transcription could not keep up. Try a smaller model.
```

The model cannot transcribe in real time on your machine, so the pipeline discarded audio rather than growing without bound. Move **down** the model table: `whisper-large-v2` → `whisper-large-v3-turbo-fast` → `whisper-small`. This is why the non-English defaults are not the largest models.

### The transcript is gibberish, or repeats itself

Usually one of three things:

1. **`/lang auto` guessed wrong.** It commits to one language per session, so a bad guess affects everything after it. Check the `detected language:` line, and name the language instead.
2. **The model is too small for the language.** `whisper-tiny` and `whisper-base` produce confident nonsense on Indic languages. Move up the table.
3. **A decoder loop.** Whisper sometimes repeats a phrase indefinitely. Listnr detects and drops these, but a line that repeats a phrase two or three times can still get through.

If output is in the *wrong language* while `/translate` is on, you are on a turbo model. Listnr should have prevented that — please report it.

### It is slow to start

The first `/live` for a given model downloads and compiles it for the Neural Engine. That is once per model, and the progress bar shows it. Pre-fetch before a call:

```sh
listnr models download whisper-large-v2
```

### `/lang bn` wants a 908 MB download

That is `/translate` being on, which switches to `whisper-large-v2`. Turn it off for a native-language transcript, or use `/model whisper-small` for a 207 MB translation model.

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
