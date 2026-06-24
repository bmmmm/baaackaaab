#!/usr/bin/env bash
#
# Stable code-signing for baaackaaab.
#
# An ad-hoc-signed binary's code identity (cdhash) changes on every rebuild,
# which invalidates the Keychain ACL grants and resets the Photos (TCC)
# permission — so every rebuild brings back the "always allow?" prompts. Signing
# with a stable, self-signed code-signing certificate gives the binary a fixed
# designated requirement, so a one-time "Always Allow" (Keychain) and a one-time
# Photos grant (TCC) persist across rebuilds, as long as you re-sign after each
# build (which `make` / `make release` does for you).
#
# No Apple Developer account required — this is a purely local, self-signed
# identity. Locally built binaries are not quarantined, so Gatekeeper never
# assesses them on exec; `codesign --verify` (signature integrity) is all we need.
#
# Usage:
#   ./scripts/sign.sh --init     # create the self-signed certificate once
#   ./scripts/sign.sh            # sign the built debug + release binaries
#
set -euo pipefail

IDENTITY="baaackaaab-codesign"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"
}

create_cert() {
  if have_identity; then
    echo "code-signing identity '$IDENTITY' already exists — nothing to do"
    return 0
  fi
  echo "creating self-signed code-signing certificate '$IDENTITY' …"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/req.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = baaackaaab-codesign
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 3650 -config "$tmp/req.cnf" >/dev/null 2>&1

  # macOS `security import` cannot verify the MAC of a PKCS#12 protected with an
  # EMPTY password (it reports "wrong password?"), so use a random throwaway
  # transport password — it only guards the temp bundle for the duration of the
  # import. OpenSSL 3.x also defaults to PBE algorithms the Security framework
  # rejects, so force the legacy provider there; LibreSSL (the macOS default)
  # already emits compatible SHA1/3DES and has no `-legacy` flag.
  local p12pw legacy=""
  p12pw="$(openssl rand -hex 16)"
  if openssl version | grep -q '^OpenSSL 3'; then legacy="-legacy"; fi

  openssl pkcs12 -export $legacy \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$IDENTITY" -out "$tmp/bundle.p12" -passout "pass:$p12pw"

  # Import the cert + key into the login keychain and grant /usr/bin/codesign
  # access to the private key, so signing does not prompt on every run.
  security import "$tmp/bundle.p12" -k "$LOGIN_KEYCHAIN" -P "$p12pw" -T /usr/bin/codesign

  if have_identity; then
    echo "done. The first sign may ask once to allow codesign to use the key — click Always Allow."
  else
    echo "import finished but the identity is not listed for code signing — check 'security find-identity -v -p codesigning'." >&2
    exit 1
  fi
}

sign_one() {
  local bin="$1"
  [ -f "$bin" ] || return 0
  codesign --force --sign "$IDENTITY" "$bin"
  codesign --verify --verbose=2 "$bin" 2>&1 | sed 's/^/  /'
  echo "signed: $bin"
}

case "${1:-}" in
  --init)
    create_cert
    ;;
  "")
    if ! have_identity; then
      echo "no code-signing identity '$IDENTITY' — run './scripts/sign.sh --init' once first." >&2
      exit 1
    fi
    sign_one "$REPO_ROOT/.build/debug/baaackaaab"
    sign_one "$REPO_ROOT/.build/release/baaackaaab"
    ;;
  *)
    echo "usage: $0 [--init]" >&2
    exit 2
    ;;
esac
