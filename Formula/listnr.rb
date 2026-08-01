# Homebrew formula for Listnr.
#
# This repository doubles as its own Homebrew tap, so there is no separate
# `homebrew-listnr` repo to keep in sync. Homebrew reads formulae from `Formula/`
# at the root of a tapped repository, which is exactly where this lives.
#
#   brew tap rokib16x/listnr https://github.com/rokib16x/listnr
#   brew install listnr
#
# The two-argument form of `brew tap` is required: the one-argument shorthand
# assumes a repo named `homebrew-<name>`, and this one is named `listnr`.
#
# See packaging/README.md for what to update at release time.
#
class Listnr < Formula
  desc "Local meeting listener: mic + system audio to a multi-speaker transcript"
  homepage "https://github.com/rokib16x/listnr"
  url "https://github.com/rokib16x/listnr/archive/refs/tags/v0.1.2-beta.tar.gz"
  sha256 "e545dd7257a91785758cf893f064a2c248bc98eac8e998d2a75c6214472b425d"
  license "MIT"
  head "https://github.com/rokib16x/listnr.git", branch: "main"

  # Both are hard requirements, not preferences. Listnr runs Whisper on the
  # Neural Engine and captures system audio through ScreenCaptureKit, so an
  # Intel Mac or an older macOS cannot run it at all — `listnr doctor` refuses to
  # start. Declaring them here turns that into an install-time refusal with a
  # clear message rather than a confusing runtime one.
  depends_on arch: :arm64
  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    # --disable-sandbox: SwiftPM resolves dependencies over the network, which
    # Homebrew's build sandbox blocks.
    system "swift", "build",
           "--configuration", "release",
           "--arch", "arm64",
           "--disable-sandbox"

    bin.install ".build/release/listnr"

    # No shell_parameter_format: swift-argument-parser wants the shell as a bare
    # argument (`listnr --generate-completion-script zsh`). The `:arg` form sends
    # `--shell=zsh`, which ArgumentParser silently ignores before falling back to
    # auto-detecting the invoking shell — so all three files would end up holding
    # completions for whatever shell the builder happened to be running.
    generate_completions_from_executable(bin/"listnr", "--generate-completion-script")

    # `--allow-writing-to-directory` rather than `--disable-sandbox`: the flag
    # belongs to the `plugin` subcommand, and putting `--disable-sandbox` ahead
    # of `plugin` makes the plugin print usage instead of running. The tool name
    # is deliberately omitted — generate-manual auto-detects the executable and
    # passing it explicitly also fails.
    system "swift", "package", "plugin",
           "--allow-writing-to-directory", buildpath/"manual",
           "generate-manual", "--output-directory", buildpath/"manual"
    man1.install Dir["manual/*.1"]
  end

  def caveats
    <<~EOS
      Listnr needs two macOS permissions before it can capture anything:

        listnr setup      grant Microphone + Screen & System Audio Recording
        listnr doctor     verify them

      macOS attaches both permissions to your *terminal application*, not to the
      listnr binary. `brew upgrade` will not re-prompt, but switching from
      Terminal to iTerm (or any other terminal) means granting them again.

      Speech models download on first use, not during this install. They land in
      ~/Documents/huggingface and range from 139 MB (English) to about 1.5 GB.
      To fetch one ahead of a call:

        listnr models download whisper-base.en

      Recording other people without their consent is illegal in many places.
      Read the README before using this on a call.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/listnr --version")

    # The model registry is the only meaningful thing testable in a sandbox: no
    # audio hardware, no TCC permissions, no network.
    assert_match "whisper-base.en", shell_output("#{bin}/listnr models list")

    # An unknown model must fail loudly rather than fall back to another one.
    assert_match "unknown model", shell_output("#{bin}/listnr models download nope 2>&1", 1)

    assert_match "#compdef listnr",
                 shell_output("#{bin}/listnr --generate-completion-script zsh")
  end
end
