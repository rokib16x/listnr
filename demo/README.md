# Demo recordings

Three GIFs, recorded two different ways, for three different reasons.

| GIF | Shows | Recorded with | Who can record it |
|---|---|---|---|
| `listnr-session.gif` | `You` vs `Speaker 1` vs `Speaker 2`, replayed from a real transcript | `vhs demo/session-replay.tape` | Anyone |
| `listnr-install.gif` | `brew tap` → `trust` → `install`, then it runs | `vhs demo/install.tape` | Anyone |
| `listnr-cli.gif` | `--version`, `models list`, `--help` | `vhs demo/cli-tour.tape` | Anyone |

The session GIF is the one that matters: the whole pitch is that the transcript is
correct about who said what, and neither an install log nor `--help` output
demonstrates that.

## The session GIF is a replay, and says so

`listnr-session.gif` does **not** capture a live call. It replays
`demo/sample-session.md` — a verbatim excerpt of a transcript Listnr actually
wrote during a real two-person session — through `demo/replay-transcript.sh`.

Three rules held while building it, and they should hold for any replacement:

- **The wording is untouched.** `"It's more faster and cleaner"` and the
  `"compare--"` false start are what Whisper produced. Tidying them would make the
  demo an advertisement for accuracy the tool does not have.
- **No colour, no invented chrome.** The replay prints exactly the format
  `LaneTranscriber.swift` prints: `[MM:SS] Speaker: text`, plain. Styling Listnr
  does not emit would be a lie about the product, however small.
- **The replay command stays visible in the frame.** GIFs get shared detached from
  the README — on Hacker News, in a tweet — and one that looked like a live
  capture would misrepresent what happened.

`sample-session.md` is safe to publish because the two people in it are discussing
Listnr itself: no names, no client, nothing private. Any replacement excerpt needs
the same check.

## Why the live capture cannot be automated

macOS attaches the Microphone and Screen & System Audio Recording grants to the
**terminal application**, not to the `listnr` binary. Recorders like `vhs` and
`terminalizer` spawn their own headless terminal, which holds neither grant and
cannot prompt for them — so a session captured that way records a tool that hears
silence on both lanes and produces an empty transcript.

`asciinema` records inside the terminal you are already sitting in and inherits
both grants, which is why `record-session.sh` uses it. It still needs a human to
talk into the microphone, so it cannot run unattended. A genuine live capture is
strictly better than the replay — record one when you have a willing second voice
and swap the GIF.

## Re-recording the install GIF

It performs a real install, so the previous one has to be undone first or the GIF
shows Homebrew declining to do anything:

```sh
brew uninstall listnr
brew untap rokib16x/listnr
vhs demo/install.tape
```

Trust is recorded in `~/.homebrew/trust.json` and **survives untapping**. Leave it
and the GIF says "Already trusted tap" instead of "Trusted tap"; remove only the
`rokib16x/listnr` entries — that file holds trust for every other third-party tap
on the machine too.

Three things about `vhs` that cost an afternoon:

- **Every `Set` must precede every other directive**, `Env` included. Put `Env`
  first and `vhs` ignores all your `Set` lines and renders at default size in the
  default shell. It warns, but still produces a GIF.
- **`HOMEBREW_NO_AUTO_UPDATE` is mandatory.** Otherwise `brew tap` silently runs
  `brew update` first, prints nothing for minutes, and every `Wait` times out
  against a screen holding only the command line.
- **Do not `Wait` on the shell prompt.** The echoed command line starts with the
  prompt too, so the regex matches instantly and waits for nothing. Wait on
  distinctive output instead — `/(?i)tapped/`, `/Summary/`.

An unquoted path beginning with `/` is parsed as a regex, so `Output` needs
quotes for absolute paths.

## Recording a genuine live session

```sh
brew install asciinema agg
./demo/record-session.sh 60
```

The script refuses to start until `listnr doctor` is green, so a missing Screen
Recording grant fails before it can waste a take rather than after. Remember that
the grant needs the System Settings toggle **and** a terminal relaunch.

Read the checklist the script prints. The two that ruin a take:

- **Wear a closed headset.** Open speakers leak the remote voice back into the
  microphone, which puts one person on both lanes and destroys the speaker split
  the demo exists to show.
- **Leave gaps between turns.** Overlapping speech is the hardest case for
  diarization and the worst thing to put in a first impression.

## Before committing a recording

- **Never a real call.** Use a podcast or a willing volunteer on a throwaway
  topic. Everything in the frame is public forever.
- **No names, no clients, nothing private.** Including in the window title and
  the shell prompt.
- **Under about 4 MB.** GitHub renders larger GIFs slowly, and a demo nobody
  waits for is not a demo. Drop `--font-size` or raise `--idle-time-limit` in the
  script if it runs over.
- **Check the labels are visible.** If diarization folded two speakers into one,
  the recording argues against the product. Record again.

The `.cast` files are kept alongside the GIFs: they are text, they diff, and they
can be re-rendered at a different size or speed without another call.
