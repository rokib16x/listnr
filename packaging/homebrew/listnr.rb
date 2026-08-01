# Homebrew formula for Listnr.
#
# This file is the source of truth; the copy Homebrew actually reads lives in
# the tap repository at github.com/rokib16x/homebrew-tap as `Formula/listnr.rb`.
# See packaging/README.md for how to bootstrap that repo and what to update at
# release time.
#
#   brew install rokib16x/tap/listnr
#
class Listnr < Formula
  desc "Local meeting listener: mic + system audio to a multi-speaker transcript"
  homepage "https://github.com/rokib16x/listnr"
  url "https://github.com/rokib16x/listnr/archive/refs/tags/v0.1.1-beta.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/rokib16x/listnr.git", branch: "main"

  # Both are hard requirements, not preferences. Listnr runs Whisper on the
  # Neural Engine and captures system audio through ScreenCaptureKit, so an
  # Intel Mac or an older macOS cannot run it at all — `listnr doctor` refuses to
  # start. Declaring them here turns that into an install-time refusal with a
  # clear message rather than a confusing runtime one.
  depends_on arch: :arm64
  depends_on macos: :sonoma
  depends_on xcode: ["15.0", :build]

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
    generate_completions_from_executable(
      bin/"listnr", "--generate-completion-script",
      shells: [:bash, :zsh, :fish],
    )

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
