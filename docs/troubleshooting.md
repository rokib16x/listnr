# Troubleshooting

Everything below writes to **stderr**, so you will see it even when you redirect
the transcript to a file.

## Nothing appears for a non-English language

Look for this line:

```text
! dropped 3 low-confidence segment(s) [lang=bn, script=indic]
```

Whisper heard you and the confidence gate rejected the result. If it fires on speech you know was clear, the thresholds are still too tight for your audio — [open an issue](https://github.com/rokib16x/listnr/issues/new/choose) with the line, the language, and the model. `/model whisper-large-v2` usually clears it, because a better model scores higher.

If there is no such line and the level meter shows `mic=0.000`, it is the microphone, not the transcription. Check System Settings → Sound → Input, and run `listnr doctor`.

## Nothing from you at all (`mic=0.0s`)

Different from a quiet microphone, and worth telling apart:

```text
○ captured  wall=64.8s  mic=0.0s  sys=65.6s
```

`mic=0.0s` is **zero samples**, not quiet ones. No sensitivity setting can help,
because there is no audio to threshold. If the mic were merely quiet you would
see a real duration with low levels, like `mic=64.7s` at `0.017`.

On a Bluetooth headset this used to be a Listnr bug, fixed in the version after
0.1.3-beta. AirPods idle in an output-only profile at 48 kHz and only switch to
their 24 kHz hands-free profile once something opens the input — which is the act
of starting a session. Listnr installed its tap at the old rate and never
received a buffer. It now rebuilds the audio engine when the device changes
format, and reports the rate it is actually converting:

```text
  mic format 24000 Hz · 1 ch
```

If you still see `mic=0.0s` on a current build:

1. Check the microphone grant belongs to **the terminal you launch from**, not a
   different one: `listnr doctor`.
2. Confirm the device works outside Listnr — System Settings → Sound → Input and
   watch the **Input level** meter while you speak. If those bars stay flat, the
   problem is the device or macOS, not Listnr.
3. Try a wired or USB microphone. Bluetooth headsets are the fragile case.

## The transcript has gaps — minutes of speech missing

Look at the level meter while you talk:

```text
  levels  mic=0.017  sys=0.000
```

Speech has to reach **0.018** at `normal` sensitivity before a finished segment
is kept. A built-in MacBook microphone at default input volume often peaks around
0.017, which is under the bar — so audio is captured, never transcribed, and the
transcript simply has holes in it. Listnr now says so ~20 s in:

```text
! mic peaked at 0.017 but speech needs 0.018 — most of your voice is being discarded.
```

Two fixes, either works:

1. **Raise the input volume** — System Settings → Sound → Input, drag the slider up.
2. **Lower the bar** — `/sensitivity high` halves every threshold, or
   `listnr start --sensitivity high`.

Use `low` for the opposite problem: a hot microphone where keyboard noise and
fans get transcribed as words.

## Nobody else is in the transcript (`sys=0.000`)

Lane B is the speaker output — everyone who is not you. If the level meter shows
`sys=0.000` while someone is talking on the call, none of them is being captured.

```text
  levels  mic=0.062  sys=0.000
! no system audio yet — remote voices will be missing.
```

**Confirm it is the capture, not the call.** Play music or a YouTube video out
loud and run:

```sh
listnr start --seconds 15 --no-transcribe
```

- `sys=` moves → capture works. The problem is call-specific: check the meeting
  is playing through this Mac's output and is not muted.
- `sys=0.000` with audio clearly playing → the capture is broken. Continue below.

**The usual cause is the Screen Recording permission**, and it fails in a way
that looks like success. ScreenCaptureKit returns *silent buffers* rather than an
error when the grant has lapsed, so the session starts, runs, and reports
`sys=243.9s` of captured audio that happens to be pure silence.

1. Run `listnr doctor` **in the terminal you actually launch Listnr from**. The
   permission attaches to the terminal application, not to the `listnr` binary,
   so checking from a different terminal tells you nothing.
2. System Settings → Privacy & Security → **Screen & System Audio Recording** →
   enable your terminal.
3. **Quit and reopen that terminal.** macOS does not apply the change to an
   already-running process.
4. macOS re-asks for this permission periodically. If you dismissed that prompt,
   the grant lapses silently — re-enable and restart the terminal again.

If you switched terminals (Terminal → iTerm, or started using Ghostty for the
Bangla rendering), the new one needs its own grant.

**If the grant is definitely in place, check what you are listening through.**
`listnr doctor` names it:

```text
! system audio output: FiascoPods is Bluetooth
```

Bluetooth output has been observed handing ScreenCaptureKit silent buffers — the
stream starts, reports a duration, and every sample is zero. Aggregate and
virtual devices, the kind loopback tools install, can route speaker audio away
from the tap in the same way. Set System Settings → Sound → Output to a built-in,
wired, or USB device and run the 15-second test again. If `sys=` moves, that was
it, and you will need non-Bluetooth output for meetings you want transcribed.

## Words go missing in the middle of a conversation

```text
! You: dropped 12 audio buffer(s) and 4 speech segment(s), transcription could not keep up. Try a smaller model.
```

The model cannot transcribe in real time on your machine, so the pipeline discarded audio rather than growing without bound. Move **down** the [model table](models.md#models): `whisper-large-v2` → `whisper-large-v3-turbo-fast` → `whisper-small`. This is why the non-English defaults are not the largest models.

## Bangla, Hindi, or Tamil looks mangled in the terminal

Almost always a rendering problem, not a transcription one. Check the saved file
before assuming the text is wrong:

```sh
open ~/Documents/Listnr/listnr_*.md
```

If it reads correctly there, the transcript is fine and your terminal is the
problem. Indic scripts need two things a terminal grid cannot do:

- **Conjunct ligatures.** `ড` + `্` + `য` is three codepoints that must fuse into
  one glyph, `ড্য`.
- **Vowel reordering.** `ে` is stored *after* its consonant but must be drawn
  *before* it.

Terminal.app does neither — it paints one codepoint per fixed-width cell, in
storage order. Nothing Listnr can do about that; the bytes it writes are correct
UTF-8.

Options, best first:

1. **Read the saved Markdown.** Any app with real text layout renders it
   properly — TextEdit, VS Code, a browser, Preview. This is what the `.md`
   export is for.
2. **Use a terminal that shapes text**, such as Ghostty or WezTerm, which run
   glyphs through a real shaping engine. Better, though still imperfect for
   Indic.
3. **Set a font with Bengali coverage** if your terminal lets you: macOS ships
   Kohinoor Bangla, Bangla MN, and Bangla Sangam MN. Terminal fonts like SF Mono
   and Menlo have no Bengali glyphs at all, so macOS silently falls back per
   character, which makes the shaping worse.

If the saved file is *also* wrong, that is a real transcription problem — see
the sections above.

## The transcript is gibberish, or repeats itself

Usually one of three things:

1. **`/lang auto` guessed wrong.** It commits to one language per session, so a bad guess affects everything after it. Check the `detected language:` line, and name the language instead.
2. **The model is too small for the language.** `whisper-tiny` and `whisper-base` produce confident nonsense on Indic languages. Move up the [model table](models.md#models).
3. **A decoder loop.** Whisper sometimes repeats a phrase indefinitely. Listnr detects and drops these, but a line that repeats a phrase two or three times can still get through.

If output is in the *wrong language* while `/translate` is on, you are on a turbo model. Listnr should have prevented that — please report it.

## It is slow to start

The first `/live` for a given model downloads and compiles it for the Neural Engine. That is once per model, and the progress bar shows it. Pre-fetch before a call:

```sh
listnr models download whisper-large-v2
```

## `/lang bn` wants a 908 MB download

That is `/translate` being on, which switches to `whisper-large-v2`. Turn it off for a native-language transcript, or use `/model whisper-small` for a 207 MB translation model.
