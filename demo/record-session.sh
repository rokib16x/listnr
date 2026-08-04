#!/bin/bash
#
# Record the live-session demo: a real call, transcribed, with You vs Speaker N.
#
#   ./demo/record-session.sh            # 60 s session
#   ./demo/record-session.sh 90         # 90 s session
#
# This has to run in YOUR terminal, not under vhs. macOS attaches the microphone
# and Screen Recording grants to the terminal *application*, so a recorder that
# spawns its own headless terminal (vhs, ttyd) captures a session that can hear
# nothing. asciinema records inside the terminal you are already sitting in and
# inherits both grants.
#
# Before you start:
#   - listnr doctor must be all-green. Screen Recording needs the toggle in
#     System Settings AND a terminal relaunch before it takes effect.
#   - Wear a closed headset. Open speakers leak the remote voice into the mic,
#     which puts one person on both lanes and ruins the speaker split.
#   - Have someone on a call, or play a recording of a voice through the speakers.
#     Lane B is whatever comes out of the Mac's output, so a podcast works.
#   - Say something in the first few seconds so Lane A is not silent.

set -euo pipefail

SECONDS_ARG="${1:-60}"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAST="$OUT_DIR/listnr-session.cast"
GIF="$OUT_DIR/listnr-session.gif"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

command -v asciinema >/dev/null || die "asciinema not installed: brew install asciinema"
command -v agg >/dev/null        || die "agg not installed: brew install agg"
command -v listnr >/dev/null     || die "listnr not on PATH"

# Fail before recording rather than after, so a missing grant does not waste a
# take. `listnr doctor` exits non-zero when a required permission is missing.
note "Checking permissions"
if ! listnr doctor; then
  die "listnr doctor is not happy — fix the above, relaunch this terminal, retry"
fi

cat <<EOF

$(note "Ready to record a ${SECONDS_ARG}s session")

  1. Start your call, or start playing a voice through the speakers.
  2. Press Enter here.
  3. Talk. Let the other side talk. Leave gaps — overlapping speech is the
     hardest case and not what you want in a first demo.
  4. The session stops itself after ${SECONDS_ARG}s and prints the transcript.
  5. Type 'q' then Enter to leave the prompt and end the recording.

EOF
read -r -p "Enter to begin: " _

rm -f "$CAST"
# --cols/--rows keep the frame a sane shape for a README. Wider than ~100 and the
# GIF gets illegible when GitHub scales it down.
asciinema rec "$CAST" \
  --cols 100 --rows 28 \
  --title "listnr — a real session, transcribed on-device" \
  --command "listnr start --seconds ${SECONDS_ARG} --speakers 2"

[ -s "$CAST" ] || die "no recording was produced"

note "Converting to GIF"
# idle-time-limit collapses the dead air while Whisper works, which is most of
# the wall clock and none of the interest.
agg "$CAST" "$GIF" \
  --font-size 16 \
  --idle-time-limit 1.5 \
  --speed 1.4 \
  --theme asciinema

note "Done"
printf '  cast: %s\n  gif:  %s (%s)\n' "$CAST" "$GIF" "$(du -h "$GIF" | cut -f1)"
cat <<'EOF'

Before committing it, watch it once and check:

  - No real names, no client names, nothing from an actual private call.
  - Under about 4 MB, or GitHub will be slow to render it inline.
  - The You / Speaker 1 labels are visible. That is the entire point of the
    demo; if diarization did not split them, record again with cleaner turns.
EOF
