#!/bin/bash
#
# Replay a saved Listnr transcript at reading pace, for the demo recording.
#
#   ./demo/replay-transcript.sh demo/sample-session.md
#
# This is a REPLAY, not a capture. It reads a transcript Listnr already wrote and
# prints it back. It does not record audio and does not run Listnr.
#
# Why this exists: the live session cannot be recorded unattended. macOS attaches
# the Microphone and Screen Recording grants to the terminal *application*, so a
# recorder that spawns its own headless terminal captures silence on both lanes —
# and a real capture needs two people talking. See demo/README.md.
#
# The output format is copied from what Listnr actually prints, at
# Sources/ListnrCore/Transcription/LaneTranscriber.swift:
#
#     print("[\(stamp)] \(line.speaker): \(line.text)")
#
# Plain text, no colour, because that is what Listnr emits. Do not add ANSI
# colour here: a demo that shows styling the tool does not produce is a lie about
# the product, however small.

set -euo pipefail

FILE="${1:-}"
[ -n "$FILE" ] || { echo "usage: $0 <transcript.md>" >&2; exit 1; }
[ -f "$FILE" ] || { echo "no such transcript: $FILE" >&2; exit 1; }

# Seconds between lines. The real thing is paced by how fast people talk; this is
# paced to be readable in a GIF.
DELAY="${DELAY:-0.85}"

# `- **[00:01] You:** text`  ->  `[00:01] You: text`
# Anchored on the list marker so the heading, the italic date and the HTML
# comment are all skipped without needing to know how many lines they take.
sed -n 's/^- \*\*\(\[[0-9][0-9]:[0-9][0-9]\]\) \(.*\):\*\* \(.*\)$/\1 \2: \3/p' "$FILE" \
| while IFS= read -r line; do
    printf '%s\n' "$line"
    sleep "$DELAY"
  done
