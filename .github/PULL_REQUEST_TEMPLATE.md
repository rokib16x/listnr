<!-- One PR, one concern. Small and focused gets merged. -->

## What changed and why

<!-- A sentence or two. Link the issue if there is one. -->

## How you verified it

<!-- `swift test` output, plus, for anything touching audio or transcription:
     what you actually tested with. How many speakers, which language, which
     model, how long a session, what hardware (built-in mic / AirPods / ...). -->

## Checklist

- [ ] `swift build` and `swift test` pass.
- [ ] `swift build -Xswiftc -strict-concurrency=complete` adds **no** new warnings.
- [ ] Added a CHANGELOG entry under `## [Unreleased]` (skip for pure docs/typo fixes).
- [ ] No real meeting audio or transcripts anywhere in this PR.
