#!/bin/bash
# Signing setup helper for the release workflow.
#
# Everything here is local. The two steps that need your Apple ID — uploading
# the CSRs and generating the App Store Connect key — are not automatable and
# are printed as instructions at the right moment.
#
#   ./Signing/setup-signing.sh csr        1. make the keys + CSRs
#   ./Signing/setup-signing.sh bundle     2. after downloading the .cer files
#   ./Signing/setup-signing.sh secrets    3. push everything to GitHub
#
# Secrets live in Signing/private/, which is gitignored. Keep that directory:
# losing the private keys means revoking the certificates and starting over.

set -euo pipefail

# LibreSSL on purpose. OpenSSL 3 writes PKCS#12 files with PBES2/AES that
# `security import` on the GitHub runner cannot read; LibreSSL's default output
# is compatible. $PATH here often has a Homebrew/conda OpenSSL 3 in front.
OPENSSL=/usr/bin/openssl

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVATE="$DIR/private"
REPO="rokib16x/listnr"

# Shown in the certificate's common name. Anything is fine; Apple overwrites it.
CN="${CN:-Rokibul Hasan}"
EMAIL="${EMAIL:-rokib@aibac.us}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Public-key fingerprint of a private key, for pairing it with a certificate.
key_fp()  { "$OPENSSL" rsa -in "$1" -pubout 2>/dev/null | "$OPENSSL" sha256 | awk '{print $NF}'; }

# Same fingerprint, read out of a certificate. Apple ships DER; handle both.
cert_fp() {
  { "$OPENSSL" x509 -inform DER -in "$1" -noout -pubkey 2>/dev/null \
    || "$OPENSSL" x509 -in "$1" -noout -pubkey 2>/dev/null; } \
    | "$OPENSSL" sha256 | awk '{print $NF}'
}

# csr [application|installer]
#
# With no argument, generates both. Naming one regenerates just that pair with a
# brand-new key, which is what you need after Apple rejects a CSR as already
# used: a fresh key guarantees a CSR Apple has never seen.
cmd_csr() {
  mkdir -p "$PRIVATE"
  chmod 700 "$PRIVATE"

  local kinds=(application installer) forced=0
  if [[ -n "${1:-}" ]]; then
    [[ "$1" == application || "$1" == installer ]] \
      || die "csr takes 'application' or 'installer'"
    kinds=("$1"); forced=1
  fi

  for kind in "${kinds[@]}"; do
    local key="$PRIVATE/$kind.key" csr="$PRIVATE/$kind.csr"
    if [[ -f "$key" && $forced -eq 0 ]]; then
      warn "$key exists, keeping it (name the kind to force a new key)"
    else
      [[ -f "$key" ]] && mv "$key" "$key.superseded.$(date +%s)"
      "$OPENSSL" genrsa -out "$key" 2048 2>/dev/null
      chmod 600 "$key"
    fi
    # The OU differs per kind so the two CSRs never share a subject DN — Apple
    # rejects a re-used CSR, and identical subjects invite that collision.
    "$OPENSSL" req -new -key "$key" -out "$csr" \
      -subj "/emailAddress=$EMAIL/CN=$CN/OU=listnr-$kind/C=US"
    local fp; fp="$(key_fp "$key")"
    bold "  $kind.csr  (key ${fp:0:16})"
  done

  step "CSRs ready in Signing/private/"

  cat <<'INSTRUCTIONS'

Now the part only you can do:

  1. Open https://developer.apple.com/account/resources/certificates/add

  2. Choose "Developer ID Application"
       -> upload  Signing/private/application.csr
       -> download the .cer, save it as  Signing/private/application.cer

  3. Repeat, choosing "Developer ID Installer"
       -> upload  Signing/private/installer.csr
       -> download the .cer, save it as  Signing/private/installer.cer

  4. While you are there, note your Team ID from
     https://developer.apple.com/account  (top right, 10 characters)

  5. Then generate the notarization key at
     https://appstoreconnect.apple.com/access/integrations/api
       -> Team Keys -> "+" -> role: Developer
       -> download AuthKey_XXXXXXXXXX.p8  (ONE download only, it is gone after)
       -> save it as  Signing/private/notary.p8
       -> note the Key ID and the Issuer ID shown on that page

Then run:  ./Signing/setup-signing.sh bundle
INSTRUCTIONS
}

# Reports which private key each downloaded certificate belongs to, and fixes
# the filenames when they were crossed. Apple names both files the same thing on
# download, and re-using one CSR for two certificates crosses the pairing, so
# assuming installer.cer goes with installer.key is not safe.
cmd_match() {
  local certs=() found=0
  for c in "$PRIVATE"/*.cer; do [[ -f "$c" ]] && certs+=("$c"); done
  (( ${#certs[@]} > 0 )) || die "no .cer files in Signing/private/ yet"

  for cert in "${certs[@]}"; do
    local cfp type
    cfp="$(cert_fp "$cert")"
    type="$({ "$OPENSSL" x509 -inform DER -in "$cert" -noout -subject 2>/dev/null \
           || "$OPENSSL" x509 -in "$cert" -noout -subject; } | grep -o 'Developer ID [A-Za-z]*' | head -1)"
    [[ -n "$type" ]] || type="(unknown type)"

    local matched=""
    for key in "$PRIVATE"/*.key; do
      [[ -f "$key" ]] || continue
      if [[ "$(key_fp "$key")" == "$cfp" ]]; then matched="$(basename "$key")"; break; fi
    done

    if [[ -n "$matched" ]]; then
      bold "  $(basename "$cert")  =  $type  ->  private key: $matched"
      found=1
    else
      warn "$(basename "$cert") ($type) matches NONE of the local keys."
      warn "  Its private key is lost. Revoke that certificate and reissue it."
    fi
  done

  (( found == 1 )) || die "no certificate paired with a local key"
  step "Pairing checked."
  echo "If a .cer is paired with the other kind's key, that is fine —"
  echo "'bundle' reads the pairing from these fingerprints, not from the filenames."
}

cmd_bundle() {
  local missing=0
  for f in application.key application.cer installer.key installer.cer; do
    [[ -f "$PRIVATE/$f" ]] || { warn "missing Signing/private/$f"; missing=1; }
  done
  (( missing == 0 )) || die "run the 'csr' step and download the .cer files first"

  # A password is required: `security import` rejects passwordless p12 files.
  # Generated rather than prompted so it never lands in a shell history file.
  local pw
  if [[ -f "$PRIVATE/p12.password" ]]; then
    pw="$(cat "$PRIVATE/p12.password")"
  else
    pw="$("$OPENSSL" rand -base64 24)"
    printf '%s' "$pw" > "$PRIVATE/p12.password"
    chmod 600 "$PRIVATE/p12.password"
  fi

  for kind in application installer; do
    # Apple hands back DER; PKCS#12 export wants PEM.
    "$OPENSSL" x509 -inform DER -in "$PRIVATE/$kind.cer" \
      -out "$PRIVATE/$kind.pem" 2>/dev/null \
      || cp "$PRIVATE/$kind.cer" "$PRIVATE/$kind.pem"   # already PEM

    "$OPENSSL" pkcs12 -export \
      -inkey "$PRIVATE/$kind.key" \
      -in "$PRIVATE/$kind.pem" \
      -name "Developer ID $kind" \
      -passout "pass:$pw" \
      -out "$PRIVATE/$kind.p12"
    chmod 600 "$PRIVATE/$kind.p12"

    # Fail loudly here rather than 4 minutes into a release run.
    "$OPENSSL" pkcs12 -in "$PRIVATE/$kind.p12" -passin "pass:$pw" -noout \
      || die "$kind.p12 did not verify"

    bold "  built $kind.p12  ($("$OPENSSL" x509 -in "$PRIVATE/$kind.pem" -noout -subject | sed 's/^subject= *//'))"
  done

  step "Both .p12 bundles verified."
  echo "Next:  ./Signing/setup-signing.sh secrets"
}

cmd_secrets() {
  command -v gh >/dev/null || die "gh is not installed"

  for f in application.p12 installer.p12 p12.password notary.p8; do
    [[ -f "$PRIVATE/$f" ]] || die "missing Signing/private/$f — run 'bundle' first"
  done

  # Only the notarization identifiers are left: everything else is either on
  # disk or already known. Team ID is pre-filled; press return to accept it.
  local team_id notary_key_id notary_issuer_id
  read -r -p "Apple Team ID [D4VCS2H64C]: " team_id
  team_id="${team_id:-D4VCS2H64C}"
  read -r -p "Notary Key ID (10 chars, from the .p8 filename): " notary_key_id
  read -r -p "Notary Issuer ID (UUID): " notary_issuer_id

  [[ -n "$notary_key_id" && -n "$notary_issuer_id" ]] \
    || die "the notary Key ID and Issuer ID are both required"

  step "Setting secrets on $REPO"

  set_secret() { gh secret set "$1" --repo "$REPO" --body "$2" && echo "  set $1"; }

  set_secret MACOS_APP_CERT_P12       "$(base64 < "$PRIVATE/application.p12")"
  set_secret MACOS_INSTALLER_CERT_P12 "$(base64 < "$PRIVATE/installer.p12")"
  set_secret MACOS_CERT_PASSWORD      "$(cat "$PRIVATE/p12.password")"
  set_secret MACOS_KEYCHAIN_PASSWORD  "$("$OPENSSL" rand -base64 24)"
  set_secret NOTARY_KEY_P8            "$(base64 < "$PRIVATE/notary.p8")"
  set_secret NOTARY_KEY_ID            "$notary_key_id"
  set_secret NOTARY_ISSUER_ID         "$notary_issuer_id"
  set_secret APPLE_TEAM_ID            "$team_id"

  step "All secrets set."
  cat <<'NEXT'

Remaining, in this order:

  1. Rehearse the whole pipeline. Passing a tag makes the run a dry run: it
     builds, signs and notarizes, then publishes nothing.

     The workflow checks out the branch you dispatch from, not the tag, but
     scripts/check-version.sh still insists the tag agrees with
     Sources/ListnrCore/Version.swift. So pass the version currently in the
     source, not the one you are about to release:
       gh workflow run Release -f tag=v0.1.2-beta
       gh run watch

  2. When that is green, cut the real release (see packaging/README.md for the
     version bump and CHANGELOG steps that come first):
       git tag v0.1.3-beta && git push origin v0.1.3-beta

  3. Verify from a BROWSER download — curl and brew do not set the quarantine
     attribute, so neither can reproduce the Gatekeeper warning:
       spctl --assess --type install --verbose=4 ~/Downloads/listnr-0.1.3-beta.pkg
     You want:  source=Notarized Developer ID

  4. Confirm the tap works end to end. This repo is its own tap, so the
     two-argument form and the trust step are both required:
       brew tap rokib16x/listnr https://github.com/rokib16x/listnr
       brew trust --tap rokib16x/listnr
       brew install listnr
NEXT
}

sub="${1:-}"; shift || true
case "$sub" in
  csr)     cmd_csr "$@" ;;
  match)   cmd_match ;;
  bundle)  cmd_bundle ;;
  secrets) cmd_secrets ;;
  *)       die "usage: $0 {csr [application|installer]|match|bundle|secrets}" ;;
esac
