# Listnr — Complete Product & Build Plan

**Listnr** is a privacy-first macOS meeting listener: capture **your mic** and **speaker/system audio**, live-transcribe **everyone** in the call (typically you + 2–3 teammates), and produce a clean multi-speaker transcript — without depending on Discord, Zoom, or any other app API.

Anything that plays through the Mac’s speakers (or headphones) is captured. Discord is just one of many possible sources.

**References in this workspace**

| Path | Role |
|------|------|
| `listnr/` | Product |
| `../parrot/` | Reference — mic/STT/doctor patterns adapted |
| `../meetily/` | Reference — dual-lane meeting *ideas* only (no mix-ASR code) |

Plan lives at `listnr/docs/plan.md`.

---

## 1. Product definition

### What Listnr is

- Local macOS accessory / menubar app (Apple Silicon, macOS 14+)
- Start a **listening session** → hear **you + everyone on the speakers** → live multi-speaker transcript
- End session → saved transcript (Markdown / text) with speaker labels
- Optional later: summary, dictation mode (Wispr/Parrot-style push-to-talk)

### What Listnr is not

- Not Discord-specific (or Zoom/Meet-specific)
- Not a cloud STT product
- Not “mix everything then hope Whisper sorts it out” (Meetily’s failure mode)

### Target meeting shape (your case)

| Role | How audio arrives | How Listnr treats them |
|------|-------------------|------------------------|
| **You** | Microphone | Always labeled **You** (lane A) |
| **Teammate 1** | Through speakers / headphones (system audio) | Diarized as **Speaker 1** (lane B) |
| **Teammate 2** | Same system audio mix | Diarized as **Speaker 2** (lane B) |
| **Teammate 3** (optional) | Same system audio mix | Diarized as **Speaker 3** (lane B) |

Typical session: **3–4 people total**. System audio carries **multiple remote voices on one wire** — that is why Listnr needs **speaker diarization**, not only “You vs Others.”

---

## 2. Why dual capture alone is not enough

```
Mic  ─────────────────────────────► only YOUR voice     ✅ easy identity
Speaker / system output ──────────► ALL remotes mixed   ⚠️ one waveform, many people
```

| Approach | You | 2–3 teammates | Overlap quality |
|----------|-----|---------------|-----------------|
| Meetily-style **mix then ASR** | Often OK | Garbled / invented text | Poor |
| Dual STT only (**You** / **Others**) | Excellent | All remotes as one “Others” blob | Better, but not multi-person |
| **Listnr: dual lanes + diarization** | Excellent | Speaker 1 / 2 / 3 | Best practical path on Mac |

**Listnr = mic lane + speaker lane + multi-speaker diarization on the speaker (and optionally full session).**

---

## 3. Architecture (best path)

### High-level

```
┌──────────────────────────────────────────────────────────────────┐
│                         Listnr (Swift)                           │
├──────────────────────────────────────────────────────────────────┤
│  Capture                                                         │
│    Lane A: Mic          (AVAudioEngine)                          │
│    Lane B: System/spk   (Core Audio process tap / SCK)           │
│    (Borrow tap patterns from meetily; do NOT mix before STT)     │
├──────────────────────────────────────────────────────────────────┤
│  Live path                                                       │
│    Lane A → VAD → WhisperKit → segments labeled "You"            │
│    Lane B → VAD → WhisperKit → text chunks                       │
│             └→ SpeakerKit (rolling) → Speaker 1..N               │
│    Merge by wall-clock time → Live Transcript UI                 │
├──────────────────────────────────────────────────────────────────┤
│  End-of-meeting polish (higher accuracy)                         │
│    Full Lane B (or mixed archive) → SpeakerKit diarize           │
│    Align diarization spans ↔ Whisper timestamps                  │
│    Emit final transcript: You / Alex / Sam / …                   │
├──────────────────────────────────────────────────────────────────┤
│  Storage                                                         │
│    Session audio (optional WAV) + transcript JSON + Markdown     │
└──────────────────────────────────────────────────────────────────┘
```

### Critical design rules

1. **Never mix Lane A + Lane B before live ASR.** Mixing is optional only for a single playback file.
2. **You are always Lane A** — do not rely on diarization to find yourself.
3. **Remote people live on Lane B** — diarize Lane B to get Speaker 1..N (expect **2–3 remote speakers**).
4. **Headset strongly recommended** — open speakers leak remotes into the mic and poison Lane A.
5. **App-agnostic** — capture speaker output, not a specific meeting app.
6. **On-device** — WhisperKit + SpeakerKit (Argmax / Core ML / ANE). No cloud required for STT or diarization.

### Multi-speaker labeling strategy

| Phase | Labels | Behavior |
|-------|--------|----------|
| **Live (v1)** | `You`, `Speaker 1`, `Speaker 2`, `Speaker 3` | Stable cluster IDs for the session |
| **After stop (v1.1)** | Same IDs, refined boundaries | Full-session SpeakerKit pass |
| **Rename (v1.1)** | `You`, `Priya`, `Dan`, … | User renames speakers once per session (or saves voice profiles later) |
| **Enrollment (v2)** | Named people automatically | Short voice samples → match embeddings |

`SpeakerKit` (`PyannoteDiarizationOptions`) supports `numberOfSpeakers` — for your meetings default hint **`numberOfSpeakers: 2…3` on Lane B** (remotes only), or auto-detect with a max of 4.

---

## 4. Stack

| Layer | Choice | Source of ideas |
|-------|--------|-----------------|
| Language | Swift 5.9+, SPM | Parrot |
| STT | WhisperKit (Core ML / ANE) | Parrot → upgrade to `argmax-oss-swift` |
| Diarization | SpeakerKit (Pyannote v4 Core ML) | Argmax OSS — **required for 3–4 people** |
| Mic | `AVAudioEngine` | Parrot `AudioCapture` |
| Speaker / system | Core Audio process tap (primary), ScreenCaptureKit fallback | Meetily `core_audio.rs` concepts → Swift |
| VAD | Per-lane (Silero or WhisperKit VAD) | Meetily VAD ideas |
| UI | SwiftUI window + menubar | Parrot overlay + new transcript view |
| Config | TOML / defaults | Parrot planned config |
| Dictation mode (optional) | Fn hold → inject at cursor | Parrot loop as `listnr dictate` |

**Not chosen for core STT:** Meetily’s mix-then-Whisper Rust path (quality issues under overlap).

---

## 5. End-to-end user flow

1. Grant **Microphone** + **Screen Recording** (or system-audio related) permissions once (`listnr setup` / doctor).
2. Put on headset; join any call (Discord / Meet / Zoom / etc.).
3. `listnr start` or menubar **Start listening**.
4. Live pane scrolls:

   ```
   [00:01:02] You         Let's ship the API today.
   [00:01:08] Speaker 1   I can take the auth work.
   [00:01:15] Speaker 2   I'll handle the frontend.
   [00:01:22] You         Perfect — sync at 4.
   ```

5. When two remotes talk in turn, Speaker 1 vs 2 stay distinct. When someone overlaps you, both lanes still produce text (no single mixed Whisper pass).
6. **Stop** → polish diarization → optional rename speakers → export Markdown.

---

## 6. Milestones

### M0 — Project skeleton (`listnr`) ✅

- New SPM package `listnr/` with CLI: `listnr`, `listnr doctor`, `listnr setup`
- Config defaults for remote speaker hints (2–3)
- Vendor/reference: keep `parrot/` and `meetily/` as read-only inspiration

**Done when:** `swift run listnr --help` works. — **DONE**

### M1 — Dual capture (app-agnostic) ✅ (implemented; grant Screen Recording to verify Lane B)

- Lane A: mic @ 16 kHz mono Float32 (`MicCapture`)
- Lane B: system/speaker via ScreenCaptureKit (`SystemAudioCapture`)
- Parallel level meters; `listnr start --seconds 8 --dump-wav`
- **No mixing for STT**

**Done when:** Play any YouTube/Discord audio → Lane B records it; your speech → Lane A only (with headset).

### M2 — Dual live transcription (You / Others) ✅

- Continuous energy-VAD + WhisperKit per lane
- Live stderr lines; post-capture fallback for energetic buffers
- CLI: `listnr start --seconds 20`

**Done when:** readable You + Others without mix-then-ASR. — **DONE**

### M3 — Multi-speaker diarization (3–4 people) ✅

- SpeakerKit on Lane B → `Speaker 1..N`
- You stays Lane A
- `--speakers N` hint; `--no-diarize` fallback to Others
- Markdown export after session

**Done when:** remote spans labeled separately and exported. — **DONE** (validate on a real 3–4 person call)

### M4 — Session store + export ✅ (v1)

- `~/Documents/Listnr/listnr_*.md` Markdown export
- In-memory `MeetingSession`

**Done when:** Stop → file on disk. — **DONE**

### M4.5 — Onset / pause refinement ✅

**Bug:** After a pause (or at the start of an utterance), the first word — sometimes the second — was missing from the live transcript.

**Cause:** Energy VAD only starts the utterance once RMS crosses the threshold. Soft onsets (“hi”, “okay”, “the…”) sit below that line for 1–2 frames and never enter the buffer Whisper sees.

**Fix applied:**
1. **Pre-roll ring (~450 ms)** — when speech is detected, prepend recent audio so the onset is included.
2. **Slightly gentler thresholds** — speech start / hangover tuned for natural pauses.
3. **Diarization span padding** — ~350 ms before / ~200 ms after each SpeakerKit cut before STT.

**Done when:** pause → talk again keeps the first word. — **DONE** (re-test in a real call)

### M5 — Interactive shell + reliability ✅

- REPL is the default: `listnr` → prompt
- `/live` unlimited until `q` / `/stop` / Ctrl+C
- `/live 30` / `/live 300` timed sessions
- `/lang en|auto|bn|…` switches language + preferred model
- `/speakers`, `/model`, `/dump`, `/diarize`, `/status`, `/help`
- `listnr start` remains as one-shot CLI

**Done when:** type `listnr`, `/live`, stop, get report. — **DONE**

### M6 — UI

- Menubar Start/Stop
- Live transcript window (You / Speaker 1..N)
- Language picker in UI (same backend as `/lang`)

### M7 — Optional extras

- Local summary (Ollama)
- Speaker rename / voice enrollment
- `listnr dictate` push-to-talk (optional; would lean on Parrot patterns if built)

---

## Credits & provenance

Listnr is original code for dual-lane meeting capture + STT + diarization wiring.

| Project | What we actually used |
|---------|------------------------|
| **[parrot](https://github.com/digimata/parrot)** ([digimata](https://github.com/digimata)) | Patterns adapted into Listnr: `AVAudioEngine` mic → 16 kHz Float32, WhisperKit warm-up/transcribe wrapper, doctor/setup permission UX, WAV dump helper. Not a fork; meeting loop is different. |
| **[meetily](https://github.com/Zackriya-Solutions/meetily)** ([Zackriya-Solutions](https://github.com/Zackriya-Solutions)) | **Ideas only** — dual mic + system-audio lanes, “don’t mix before ASR” for identity, session/notes product shape. Listnr’s Lane B is **ScreenCaptureKit in Swift**, not Meetily’s Rust/Core Audio tap code. |
| **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** / SpeakerKit (Argmax) | Direct dependencies for on-device STT + diarization. |

Sibling folders `../parrot` and `../meetily` in this workspace are reference checkouts for development — not shipped inside the Listnr binary.

---

## 7. Module layout

```
listnr/
  Package.swift
  README.md
  Sources/Listnr/
    Listnr.swift
    Doctor.swift
    Setup.swift
    Config.swift
    Capture/
    Transcription/
    Speakers/
    Session/
  docs/
    plan.md                 # this file
```

---

## 8. Permissions & hardware guidance

| Permission | Why |
|------------|-----|
| Microphone | Lane A |
| Screen Recording / system audio related | Lane B (macOS system capture) |
| Accessibility | Only if dictation inject mode is enabled |

**Hardware:** closed headset or earbuds with boom mic. Open laptop speakers will make remotes appear on both lanes and hurt multi-speaker accuracy.

**Bluetooth:** prefer avoiding HFP “phone call” mode when possible; warn if sample rate collapses to 8/16 kHz.

---

## 9. Success metrics

| Metric | Target |
|--------|--------|
| People supported | You + 2–3 remotes (3–4 total) |
| Live latency | Partial lines within ~1–3s of speech end |
| Attribution (turn-taking) | Majority of turns correctly labeled after polish |
| Overlap (you vs one remote) | Both sides still intelligible text |
| Onset after pause | First word retained (pre-roll) |
| Privacy | Audio/transcript never leave machine by default |
| App coupling | Zero — works for any app using speakers |

---

## 10. Explicit non-goals (v1)

- Perfect attribution when **three people shout at once** on the same speaker mix
- Cloud STT / cloud diarization
- Automatic calendar join bots
- Windows/Linux (macOS Apple Silicon first)
- Shipping Meetily’s mix-first pipeline

---

## 11. Decision log

| Decision | Choice |
|----------|--------|
| Product name | **Listnr** |
| Capture model | Mic + speaker/system (app-agnostic) |
| Multi-person | Dual lanes + **SpeakerKit** diarization on remotes |
| STT | WhisperKit / ANE |
| Inspiration | Parrot (mic/STT patterns), Meetily (dual-lane idea only) |
| Onset fix | VAD pre-roll + diarization pad |
| Next UX | REPL `/live` then menubar UI |

---

## 12. Immediate next step

**M6 UI** — menubar Start/Stop + live transcript window (same engine as `/live`).
