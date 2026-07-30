# Security Policy

Listnr records microphone and system audio and writes transcripts to disk. A
bug in this project can expose the contents of a private conversation, so
security reports are taken seriously.

## Supported versions

Listnr is pre-1.0. Only the latest release on `main` receives security fixes.

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅        |
| < 0.1   | ❌        |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report privately through GitHub:

1. Go to the [Security tab](https://github.com/rokib16x/listnr/security/advisories/new)
   of this repository.
2. Choose **Report a vulnerability** to open a private advisory.

If that is unavailable to you, email **rokib16x@gmail.com** with `LISTNR
SECURITY` in the subject line.

Please include:

- What the issue is and why it is a security problem.
- Steps to reproduce, or a proof of concept.
- Your macOS version, chip, and the Listnr version or commit.
- Any suggested fix, if you have one.

**Do not include real meeting audio or real transcripts** in a report. Reproduce
the problem with synthetic audio or your own voice only. Sending a recording of
other people to report a bug creates a second privacy problem.

### What to expect

- Acknowledgement within **5 days**.
- An assessment and a rough timeline within **14 days**.
- Credit in the release notes and advisory, unless you prefer to stay anonymous.

Listnr is a spare-time project with a single maintainer, so please treat these
as good-faith targets rather than guarantees.

## Scope

In scope:

- Captured audio or transcripts being written to a location other users on the
  machine can read.
- Audio, transcripts, or filenames leaving the machine over the network.
- Predictable output paths that allow another local user to pre-create,
  redirect, or clobber a file Listnr writes.
- Memory-safety bugs in audio buffer handling reachable from ordinary use
  (the `Capture/` code does raw pointer work on `CMBlockBuffer` data).
- Anything that causes Listnr to record when the user believes it is stopped.

Out of scope:

- Vulnerabilities in dependencies. Report those to
  [WhisperKit](https://github.com/argmaxinc/WhisperKit) or the relevant project
  directly. Tell us too, so we can bump the pin.
- Transcription inaccuracy, hallucinated text, or wrong speaker labels. Those
  are quality bugs; please file them as normal issues.
- The fact that macOS Screen Recording permission is required for system audio
  capture. That is how the platform works.
- Anything requiring the attacker to already have root or full-disk access.

## Known privacy characteristics

These are documented, intended behaviours, not vulnerabilities:

- **Transcripts are written unencrypted** to `~/Documents/Listnr/`. They are
  protected by your user account's file permissions and nothing more. There is
  no automatic retention limit, so delete them yourself.
- **`/dump` writes raw session audio** to `~/Documents/Listnr/debug/` with
  owner-only permissions (0600). Earlier builds wrote to world-readable fixed
  paths in `/tmp`; if you ever used `/dump` before 0.1.1-beta, delete
  `/tmp/listnr-mic.wav` and `/tmp/listnr-sys.wav` if they still exist.
- **Model weights are downloaded from Hugging Face on first run.** That network
  request is the only outbound traffic Listnr makes. No audio, transcript, or
  telemetry is ever transmitted. See the README for details and how to run fully
  offline.
