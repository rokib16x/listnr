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

   [`.github/workflows/release.yml`](../.github/workflows/release.yml) then builds, tests, generates completions and the man page, **signs the binary, builds and signs a `.pkg`, notarizes and staples it**, verifies the packaged binary runs, publishes the GitHub release, and commits the formula bump to `main`.

That is the whole process. There is **no manual step 5** — see [Code signing](#code-signing) for why the formula bump is automated.

To rehearse without publishing, run the workflow manually from the Actions tab and pass a tag. It builds, signs and notarizes everything, uploads the artefacts for inspection, and skips both the release and the formula bump.

### What ships in a release

| Artefact | What it is |
|---|---|
| `listnr-<version>-macos-arm64.tar.gz` | The binary, `completions/` for bash/zsh/fish, `man/listnr.1`, plus README, LICENSE and CHANGELOG. Around 3 MB. What the formula installs. |
| `listnr-<version>-macos-arm64.tar.gz.sha256` | Checksum of the above. |
| `listnr-<version>.pkg` | Signed, notarized and **stapled** installer. The artefact for people who download in a browser. |

Model weights are **not** bundled — they download on first use.

Apple Silicon only, so there is one artefact and no universal binary. Listnr cannot run on Intel regardless of how it is built.

## Code signing

Releases are signed with a Developer ID and notarized. Four things about this are easy to get wrong:

- **The hardened runtime is mandatory for notarization, and it blocks the microphone.** A hardened binary cannot open an input device unless it carries `com.apple.security.device.audio-input`, which is why [`Signing/listnr.entitlements`](../Signing/listnr.entitlements) exists. Without it Lane A is silently dead in a signed build — it starts fine and simply never hears you. The workflow asserts the entitlement is embedded rather than trusting that it was.
- **A notarization ticket cannot be stapled to a bare binary or a tarball**, only to a `.pkg`, `.dmg` or `.app`. That is the entire reason a `.pkg` is built. The tarball's binary is notarized too, which makes Gatekeeper's *online* check pass, but it cannot be stapled — so an offline user who downloaded the tarball in a browser can still see a warning.
- **Homebrew never trips Gatekeeper**, because it fetches over curl and curl does not set the quarantine attribute. The signing work matters for the browser-download path, not the `brew` path.
- **The Developer ID G2 intermediate CA is not preinstalled on GitHub runners.** Without importing it, `codesign` fails with "unable to build chain to self-signed root" and produces no signature at all. Keychain Access installs it silently when you double-click a `.cer` locally, so this only ever breaks in CI. Its SHA-256 is pinned in the workflow.

The formula bump is automated for a related reason: the formula now pins an exact release URL and checksum, and hand-copying a checksum is precisely where a release goes wrong.

### Signing material

[`Signing/setup-signing.sh`](../Signing/setup-signing.sh) generates the CSRs, pairs the downloaded certificates with the right private keys, builds the `.p12` bundles, and pushes every secret to the repository. Everything it writes lands in `Signing/private/`, which is gitignored.

Eight repository secrets drive it: `MACOS_APP_CERT_P12`, `MACOS_INSTALLER_CERT_P12`, `MACOS_CERT_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `APPLE_TEAM_ID`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`.

Both certificates expire **2031-08-05**. Renewing them means reissuing at developer.apple.com and re-running `./Signing/setup-signing.sh`.


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

Nothing to do by hand. The release workflow's final step rewrites `url`,
`sha256` and `version` in [`Formula/listnr.rb`](../Formula/listnr.rb) and commits
that to `main`. The checksum it uses is the **binary** tarball attached to the
release, since that is what the formula installs.

If you ever need to reproduce it manually:

```sh
V=0.1.3-beta
curl -sL "https://github.com/rokib16x/listnr/releases/download/v$V/listnr-$V-macos-arm64.tar.gz" | shasum -a 256
```

Verify a release after the fact, from a clone of this repo:

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

### Why the formula installs a binary rather than building

A source build took several minutes, because the dependency tree includes
WhisperKit, swift-transformers and swift-crypto. It also discarded the signature:
a locally compiled binary is unsigned no matter what the release ships. Installing
the released artefact is seconds instead of minutes, and it is the same signed,
notarized binary that was actually tested.

The trade is that `brew install --HEAD` no longer works — a source build would
need a second, separate install path in the formula. There is no `head` spec for
that reason.

### The man page still builds from source in CI

The formula no longer compiles anything, but the **release workflow** does, and
two SwiftPM sandbox quirks still apply there:

- SwiftPM compiles the package manifest under `sandbox-exec`, which cannot nest
  inside another sandbox. `--disable-sandbox` and
  `--allow-writing-to-directory` bind to different subcommands, so placement
  matters.
- `generate-manual` does not create its own output directory and exits 64 if it
  is missing.

One ordering rule matters more than either: **the manual plugin builds the
executable target**, so it has to run *before* the binary is signed. Signing
first and generating the man page second silently overwrites the signature and
ships an unsigned binary that still looks fine locally.

### What signing does and does not fix

It does **not** improve the permission story. macOS attaches microphone and
Screen Recording grants to the *terminal application*, not to the `listnr`
binary, so its signature is not what TCC keys on. And neither Homebrew nor
`curl` sets the quarantine attribute, so neither ever showed a warning.

What it fixes is the browser download from the releases page, which *is*
quarantined. That used to mean "developer cannot be verified" and a manual
`xattr -dr com.apple.quarantine listnr`. The stapled `.pkg` removes it outright.

Signing also becomes unavoidable for the menubar `.app` on the roadmap, where TCC
*does* key on the bundle's signature.

## Not doing yet

- **homebrew-core.** Requires notability and stability that a `0.x` beta with one maintainer will not clear. Revisit after `1.0`.
- **A `curl | sh` installer.** Straightforward once releases exist; it needs to hard-check `uname -m` is `arm64` and `sw_vers` is 14+ and fail with a clear message, since Listnr treats both as fatal anyway.
- **Mint.** Works today with no extra files (`mint install rokib16x/listnr`), it just needs a tag to exist.
