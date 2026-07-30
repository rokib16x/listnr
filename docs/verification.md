# Real-hardware verification checklist

The unit tests cover everything pure. Everything that touches real hardware
(the microphone, ScreenCaptureKit, the models, and the lane clocks) can only
be proven on a real machine and, for Lane B, a real call. Run this checklist
before cutting a release that changes the audio path.

Setup: `swift build -c release`, grant permissions with `listnr setup`, and
confirm with `listnr doctor` (all green). Use a real Discord / Meet / Zoom
call with one consenting participant.

## 1. Stop semantics (the ways a session can end)

- [ ] `/live`, speak a sentence, end with **`/stop` + Enter**: the transcript
      prints and a file is saved to `~/Documents/Listnr/`.
- [ ] Repeat ending with **`q` + Enter**: same result.
- [ ] Repeat ending with **Ctrl+C**: session cancels, returns to the prompt,
      and the *next* `/live` works normally.
- [ ] `listnr start` (no `--seconds`), speak, press **Ctrl+C once**: the
      transcript prints and saves, exit code 0.
- [ ] `/live 15` and let it hit the deadline: transcript prints and saves.
- [ ] Ctrl+C during a model download: download aborts promptly; re-running
      resumes it.

## 2. Dual-lane correctness

- [ ] With a headset on, alternate numbered phrases with the remote person
      ("one", "two", "three", ...). In the merged transcript the numbers
      appear in true order, yours labeled `You`, theirs `Speaker 1`.
- [ ] Watch stderr for `! lane clock skew`: it should **not** appear, and the
      transcript ordering should not need it. Note the offsets if printed.
- [ ] `/diarize` off, one exchange: `Others` lines keep per-utterance
      timestamps (not one block at `00:00`).
- [ ] Two remote speakers (`/speakers 2`): the split is plausible, and no
      remote speech is attributed to `You`.

## 3. Audio-quality paths

- [ ] Bluetooth headset (AirPods) session: capture still works after the
      input format drops to the call-mode rate; check the `mic format` line.
- [ ] Quiet remote speaker (volume ~25%): their speech still appears rather
      than being silently dropped.
- [ ] One `/lang bn` (or mixed Bangla/English) session on turbo: output is in
      the right script.
- [ ] Silence for 60 s mid-call with nobody talking: no hallucinated lines
      ("Thank you", "thanks for watching", etc.).
- [ ] `/dump` a session, then listen to the start of a few utterances in
      `listnr-mic.wav`: no stuttered or repeated onset syllable.

## 4. Resources and long sessions

- [ ] One 30+ minute session: memory in Activity Monitor stays in the
      ballpark of ~460 MB/hour combined; no `dropped ... buffer(s)` warning.
- [ ] `/dump` once: both WAVs land in `~/Documents/Listnr/debug/` with `0600`
      permissions (`ls -l` shows `-rw-------`), and they play.

## 5. Cleanliness

- [ ] After several sessions and one Ctrl+C, quit the shell: no stuck
      process, no runaway memory between sessions.
- [ ] `listnr_*.md` exports carry the session *start* time in the header.

Anything that fails goes back into the tracker before tagging.
