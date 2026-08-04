# vhs tape for the CLI tour: version, models, help.
#
#   vhs demo/cli-tour.tape
#
# Nothing here needs the microphone or Screen Recording, which is exactly why it
# can run under vhs. vhs renders in its own headless terminal, and macOS attaches
# TCC grants to the terminal application — so a real capture session recorded this
# way would hear silence on both lanes. Use demo/record-session.sh for that.
#
# This is the supporting GIF, not the headline one. It shows the tool is real and
# the models are local; it does not show the thing that makes Listnr worth using.

Output demo/listnr-cli.gif

Require listnr

Set Shell "bash"
Set FontSize 16
# 1280px gives ~112 columns, which is exactly the widest line `models list`
# emits. At 1100 the large-v2 row wrapped mid-word ("most ac / curate"), which
# looks like a rendering bug in a marketing GIF.
Set Width 1280
Set Height 580
Set Padding 20
Set TypingSpeed 45ms
Set Theme "Builtin Dark"

# Clear the prompt noise before the first frame.
Hide
Type "clear" Enter
Show

Sleep 800ms
Type "listnr --version"
Enter
Sleep 1200ms

Type "listnr models list"
Enter
# Long enough to read the table without padding the GIF.
Sleep 4500ms

# `--help` is 20 lines. Without clearing, it pushes the model table off the top
# and the last third of the GIF is a half-scrolled screen.
Hide
Type "clear" Enter
Show

Type "listnr --help"
Enter
Sleep 5s

Sleep 800ms
