# vhs tape for the install GIF: tap, trust, install, run.
#
#   brew uninstall listnr && brew untap rokib16x/listnr   # so it is a real
#   vhs demo/install.tape                                 # first-time install
#
# This performs a genuine install. Re-recording without uninstalling first gives
# a GIF of Homebrew saying it is already installed, which demonstrates nothing.
#
# No `Require listnr` here, unlike cli-tour.tape: the whole point is that listnr
# is absent when the recording starts.

Output demo/listnr-install.gif

# Every `Set` must come before any other directive, `Env` included. Putting Env
# first makes vhs silently ignore all of these and fall back to its defaults —
# it warns, but still produces a differently sized GIF in the wrong shell.
Set Shell "bash"
Set FontSize 16
Set Width 1280
Set Height 720
Set Padding 20
Set TypingSpeed 45ms
Set Theme "Builtin Dark"

# Homebrew's post-install hints ("Disable this behaviour by setting ...") are
# noise that pushes the useful caveats off screen.
Env HOMEBREW_NO_ENV_HINTS "1"
Env HOMEBREW_NO_INSTALL_CLEANUP "1"
# Without this, `brew tap` silently runs `brew update` first and prints nothing
# for minutes, so every Wait times out against a screen holding only the command
# line. It also keeps the GIF about listnr rather than about updating Homebrew.
Env HOMEBREW_NO_AUTO_UPDATE "1"

Hide
Type "clear" Enter
Show

Sleep 700ms

# Wait on distinctive output rather than a fixed Sleep: network time varies, and
# a Sleep that is too short truncates the command mid-flight. Waiting on the
# prompt does not work — the echoed command line starts with the prompt too, so
# the regex matches immediately.
Type "brew tap rokib16x/listnr https://github.com/rokib16x/listnr"
Enter
# Case-insensitive so a re-record over an existing tap ("already tapped") does
# not hang for two minutes against a screen holding only the command line.
# Untap first anyway — see the header — or the GIF shows nothing being installed.
Wait+Screen@180s /(?i)tapped/
Sleep 1200ms

# Homebrew 6 refuses to load a formula from an untrusted third-party tap.
#
# Case-insensitive because trust is recorded in ~/.homebrew/trust.json and
# untapping does not clear it: a re-record prints "Already trusted tap" rather
# than "Trusted tap". Delete the listnr entries from that file if you want the
# GIF to show what a new user actually sees.
Type "brew trust --tap rokib16x/listnr"
Enter
Wait+Screen@60s /(?i)trusted tap/
Sleep 1200ms

Type "brew install listnr"
Enter
Wait+Screen@300s /Summary/
# Long enough to read the caveats about the two macOS permissions.
Sleep 4s

# Deliberately no `clear` here. Clearing left the final frame almost empty, which
# reads as unfinished in a looping GIF; appending keeps the install summary and
# the working binary in the same frame.
Type "listnr --version"
Enter
Wait+Screen@30s /0\.1\.3/
Sleep 2s
