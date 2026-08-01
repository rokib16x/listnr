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

### Naming

The tap repo must be called `homebrew-<something>`; the prefix disappears in commands. Using **`homebrew-tap`** gives:

```sh
brew install rokib16x/tap/listnr
```

Three components are required — `brew install rokib16x/listnr` is not valid syntax, Homebrew drops the first component and hunts for a formula named by the last. The alternative, naming the repo `homebrew-listnr`, works but produces the awkward `rokib16x/listnr/listnr` and leaves nowhere to put a cask for the menubar app later.

### One-time setup

1. Create a public repo `rokib16x/homebrew-tap`.
2. Copy [`homebrew/listnr.rb`](homebrew/listnr.rb) to `Formula/listnr.rb` in it.
3. Fill in `url` and `sha256` from the release.

### Per release

Update two lines in `Formula/listnr.rb`:

```ruby
url "https://github.com/rokib16x/listnr/archive/refs/tags/vX.Y.Z.tar.gz"
sha256 "..."   # the "Source SHA-256" from the release workflow summary
```

That is the checksum of GitHub's generated **source** tarball, not the binary one attached to the release — the formula builds from source.

Verify before pushing:

```sh
brew install --build-from-source ./Formula/listnr.rb
brew test listnr
brew audit --strict --new listnr
```

Keep [`homebrew/listnr.rb`](homebrew/listnr.rb) in this repo in sync; it is the reviewable copy.

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
