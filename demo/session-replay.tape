# vhs tape for the session GIF: You vs Speaker 1 vs Speaker 2.
#
#   vhs demo/session-replay.tape
#
# This replays a real transcript rather than capturing a live call, because a live
# capture cannot be automated — see demo/README.md. The replay command is left
# visible in the frame on purpose: GIFs get shared detached from the README, and
# one that looked like a live capture would misrepresent what happened.
#
# Use demo/record-session.sh for a genuine live capture. It needs a human.

Output demo/listnr-session.gif

# All Set directives first — Env or anything else before them makes vhs ignore
# every one of them and silently fall back to defaults.
Set Shell "bash"
Set FontSize 18
# The longest line is 71 characters ("[00:05] Speaker 2: So it runs on the
# terminal and it's much more clean."). 940px leaves margin without shrinking the
# text; wrapping mid-sentence would read as a bug.
Set Width 940
# 11 rendered rows (command + 9 transcript lines + trailing prompt) at font 18.
# 420 left a third of the frame empty, which reads as a cropping mistake.
Set Height 320
Set Padding 22
Set TypingSpeed 45ms
Set Theme "Builtin Dark"

Hide
Type "clear" Enter
Show

Sleep 600ms

Type "./demo/replay-transcript.sh demo/sample-session.md"
Enter

# Wait on the final line rather than a fixed Sleep: the replay is paced by DELAY
# in the script, so a hard-coded Sleep here would silently truncate the last lines
# if that pacing ever changes.
Wait+Screen@60s /definitely faster/
Sleep 2500ms
