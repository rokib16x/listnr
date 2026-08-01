#!/usr/bin/env bash
#
# Verify that Listnr's version is consistent everywhere it appears.
#
# A git tag that disagrees with what `listnr --version` prints is the kind of
# mistake nobody catches until a bug report cites a release that never existed.
# Once tags drive the Homebrew formula and the release tarballs, the same
# mismatch also ships a binary whose checksum belongs to a different version.
#
# Usage:
#   scripts/check-version.sh              # consistency only (every CI run)
#   scripts/check-version.sh v0.1.2       # also require the tag to match (releases)
#
# Environment:
#   LISTNR_BIN   binary to interrogate; defaults to the release then debug build
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version_file="Sources/ListnrCore/Version.swift"
changelog="CHANGELOG.md"
expected_tag="${1:-}"

fail() {
    echo "✗ $*" >&2
    exit 1
}

# ---------------------------------------------------------------- source
[ -f "$version_file" ] || fail "missing $version_file"

source_version="$(sed -n 's/^public let listnrVersion = "\(.*\)"$/\1/p' "$version_file")"
[ -n "$source_version" ] || fail "could not parse listnrVersion out of $version_file"

# Semver with an optional pre-release suffix, which is what 0.1.1-beta is.
if ! printf '%s' "$source_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    fail "listnrVersion '$source_version' is not a semantic version"
fi
echo "✓ source version: $source_version"

# ---------------------------------------------------------------- binary
# Proves the built artefact actually carries the version, rather than trusting
# that whatever is in .build was compiled from the current source.
binary="${LISTNR_BIN:-}"
if [ -z "$binary" ]; then
    for candidate in .build/release/listnr .build/debug/listnr; do
        if [ -x "$candidate" ]; then
            binary="$candidate"
            break
        fi
    done
fi

if [ -n "$binary" ] && [ -x "$binary" ]; then
    binary_version="$("$binary" --version)"
    if [ "$binary_version" != "$source_version" ]; then
        fail "binary reports '$binary_version' but $version_file says '$source_version' (stale build?)"
    fi
    echo "✓ binary agrees: $binary ($binary_version)"
else
    echo "· no built binary to check; skipping"
fi

# ---------------------------------------------------------------- tag
# Only enforced on releases. On ordinary pushes the CHANGELOG legitimately has
# the current version under [Unreleased] and no heading of its own yet.
if [ -z "$expected_tag" ]; then
    echo "✓ no tag supplied; consistency checks passed"
    exit 0
fi

tag_version="${expected_tag#v}"
if [ "$tag_version" != "$source_version" ]; then
    fail "tag '$expected_tag' does not match listnrVersion '$source_version' — bump $version_file or retag"
fi
echo "✓ tag matches: $expected_tag"

# ---------------------------------------------------------------- changelog
[ -f "$changelog" ] || fail "missing $changelog"

if ! grep -qF "## [$source_version]" "$changelog"; then
    fail "$changelog has no '## [$source_version]' heading — move the [Unreleased] notes under it before tagging"
fi
echo "✓ changelog has a section for $source_version"

echo "✓ version $source_version is consistent across source, binary, tag, and changelog"
