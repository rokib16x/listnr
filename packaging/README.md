# Packaging and release

How a Listnr release is cut, and how the Homebrew tap is set up.

## Cutting a release

1. **Bump the version** in [`Sources/ListnrCore/Version.swift`](../Sources/ListnrCore/Version.swift). This is the single source of truth.
2. **Move the `[Unreleased]` notes** in [`CHANGELOG.md`](../CHANGELOG.md) under a `## [x.y.z] - YYYY-MM-DD` heading.
3. **Check consistency locally** before tagging anything:

   ```sh
   swift build -c release
   ./scripts/check-version.sh v0.1.2
   ```

   This fails if the tag, the source constant, the built binary, and the CHANGELOG heading disagree. It runs again in CI on every push, and again inside the release workflow before anything is packaged.

4. **Tag and push:**

   ```sh
   git tag v0.1.2 && git push origin v0.1.2
   ```

   [`.github/workflows/release.yml`](../.github/workflows/release.yml) then builds, tests, generates completions and the man page, tars everything, verifies the packaged binary actually runs, and publishes the GitHub release.

5. **Update the tap** with the source checksum printed in the workflow summary. See below.

To rehearse without publishing, run the workflow manually from the Actions tab and pass a tag — it builds and verifies everything but skips the release step.

### What ships in the tarball

`listnr-<version>-macos-arm64.tar.gz`, containing the binary, `completions/` for bash/zsh/fish, `man/listnr.1`, plus README, LICENSE, and CHANGELOG. Around 3 MB. Model weights are **not** bundled — they download on first use.

Apple Silicon only, so there is one artefact and no universal binary. Listnr cannot run on Intel regardless of how it is built.

## Homebrew tap

**This repository is its own tap.** Homebrew reads formulae from `Formula/` at
the root of any tapped git repository, so [`Formula/listnr.rb`](../Formula/listnr.rb)
is all that is needed — there is no separate `homebrew-listnr` repo to create or
keep in sync.

Users install with:

```sh
brew tap rokib16x/listnr https://github.com/rokib16x/listnr
brew trust --tap rokib16x/listnr
brew install listnr
```

### Why three commands instead of one

- **The explicit URL is required.** `brew tap user/name` on its own assumes the
  repo is called `homebrew-<name>`; this one is called `listnr`. The
  two-argument form makes no such assumption. That also means
  `brew install rokib16x/listnr/listnr` cannot auto-tap on a clean machine — it
  works only after the tap exists.
- **`brew trust` is a Homebrew 6 requirement** for every third-party tap, not
  something specific to this one. Without it, loading the formula fails with
  "Refusing to load formula ... from untrusted tap".

A separate `rokib16x/homebrew-tap` repo would collapse this to a single
`brew install rokib16x/tap/listnr` (the trust step still applies). The trade is
a second repository, a second release step, and a cross-repo token if the
formula bump is ever automated. One repo was judged the better trade; the
decision is reversible by moving `Formula/listnr.rb` into a new tap repo.

### Per release

Update two lines in [`Formula/listnr.rb`](../Formula/listnr.rb):

```ruby
url "https://github.com/rokib16x/listnr/archive/refs/tags/vX.Y.Z.tar.gz"
sha256 "..."   # the "Source SHA-256" from the release workflow summary
```

That is the checksum of GitHub's generated **source** tarball, not the binary
attached to the release — the formula builds from source. To compute it by hand:

```sh
curl -sL https://github.com/rokib16x/listnr/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
```

Verify before pushing, from a clone of this repo:

```sh
brew untap rokib16x/listnr 2>/dev/null
brew tap rokib16x/listnr https://github.com/rokib16x/listnr
brew trust --tap rokib16x/listnr
brew audit --strict --formula rokib16x/listnr/listnr
brew install rokib16x/listnr/listnr
brew test rokib16x/listnr/listnr
```

`brew audit --strict` is worth running every time; it caught three style
violations and the `depends_on` ordering rule on the first pass.

### Two things that only fail inside Homebrew's sandbox

Both are fixed in the formula and commented there, but they are the kind of
thing that will bite again if the man-page step is ever rewritten:

- SwiftPM compiles the package manifest under `sandbox-exec`, which cannot nest
  inside the sandbox Homebrew already applies. Without `--disable-sandbox` the
  step dies with `sandbox_apply: Operation not permitted`. It still needs
  `--allow-writing-to-directory` as well, and the two bind to different
  subcommands, so placement matters.
- `generate-manual` does not create its own output directory and exits 64 if it
  is missing.

### Why build from source

No code signing or notarization is needed, because Homebrew does not apply the quarantine attribute to formula downloads. The cost is build time: the dependency tree includes WhisperKit, swift-transformers, and swift-crypto, so a clean install takes several minutes. If that becomes a complaint, the fix is bottles built by GitHub Actions in the tap repo, not signing.

### On code signing

Signing the CLI is **not** required and would not improve the permission story. macOS attaches microphone and Screen Recording grants to the *terminal application*, not to the `listnr` binary, so its signature is not what TCC keys on. Neither Homebrew nor `curl` sets the quarantine attribute.

The one path that needs it is a browser download from the releases page, which does get quarantined — hence "developer cannot be verified", cleared with:

```sh
xattr -dr com.apple.quarantine listnr
```

Signing and notarization become genuinely necessary for the menubar `.app` on the roadmap, where TCC does key on the bundle's signature.

## Not doing yet

- **homebrew-core.** Requires notability and stability that a `0.x` beta with one maintainer will not clear. Revisit after `1.0`.
- **A `curl | sh` installer.** Straightforward once releases exist; it needs to hard-check `uname -m` is `arm64` and `sw_vers` is 14+ and fail with a clear message, since Listnr treats both as fatal anyway.
- **Mint.** Works today with no extra files (`mint install rokib16x/listnr`), it just needs a tag to exist.
