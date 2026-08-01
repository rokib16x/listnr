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
