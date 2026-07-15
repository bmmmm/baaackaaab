#!/usr/bin/env bash
#
# Stable code-signing for baaackaaab.
#
# An ad-hoc-signed binary's code identity (cdhash) changes on every rebuild,
# which invalidates the Keychain ACL grants and resets the Photos (TCC)
# permission — so every rebuild brings back the "always allow?" prompts. Signing
# with a stable identity gives the binary a fixed designated requirement, so a
# one-time "Always Allow" (Keychain) and a one-time Photos grant (TCC) persist
# across rebuilds, as long as you re-sign after each build (`make` does that).
#
# Identity resolution (signing), in order:
#   1. $SIGN_IDENTITY                       — explicit override (name or SHA-1)
#   2. the first valid code-signing identity — e.g. an Apple Development cert
#      from Xcode; trusted + stable, the ideal choice. Used by its SHA-1 so no
#      personal name is baked into the repo.
#   3. the self-signed fallback cert         — created by `--init` on a Mac that
#      has no code-signing identity at all.
#
# Usage:
#   ./scripts/sign.sh            # sign the built debug + release binaries
#   ./scripts/sign.sh --init     # create a self-signed cert (only if you have none)
#
set -euo pipefail

SELF_IDENTITY="baaackaaab-codesign"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# SHA-1 of the first valid code-signing identity, or empty if there is none.
first_valid_hash() {
  security find-identity -v -p codesigning 2>/dev/null | grep -Eo '[0-9A-F]{40}' | head -1
}

# Resolve the identity to sign with (see header). Prints it, or returns 1.
resolve_identity() {
  if [ -n "${SIGN_IDENTITY:-}" ]; then printf '%s' "$SIGN_IDENTITY"; return 0; fi
  local hash; hash="$(first_valid_hash)"
  if [ -n "$hash" ]; then printf '%s' "$hash"; return 0; fi
  if security find-certificate -c "$SELF_IDENTITY" >/dev/null 2>&1; then
    printf '%s' "$SELF_IDENTITY"; return 0
  fi
  return 1
}

create_cert() {
  if [ -n "$(first_valid_hash)" ]; then
    echo "a valid code-signing identity already exists — no need for --init."
    echo "it will be used automatically; run 'make release' (or './scripts/sign.sh')."
    security find-identity -v -p codesigning | sed 's/^/  /'
    return 0
  fi
  echo "no code-signing identity found — creating a self-signed certificate '$SELF_IDENTITY' …"

  local tmp; tmp="$(mktemp -d)"
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
  # transport password. OpenSSL 3.x also defaults to PBE algorithms the Security
  # framework rejects, so force its legacy provider; LibreSSL needs no flag.
  local p12pw legacy=""
  p12pw="$(openssl rand -hex 16)"
  if openssl version | grep -q '^OpenSSL 3'; then legacy="-legacy"; fi

  openssl pkcs12 -export $legacy \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$SELF_IDENTITY" -out "$tmp/bundle.p12" -passout "pass:$p12pw"

  if ! security import "$tmp/bundle.p12" -k "$LOGIN_KEYCHAIN" -P "$p12pw" -T /usr/bin/codesign; then
    echo "error: 'security import' failed — the signing identity was NOT installed." >&2
    echo "       Unlock the login keychain (security unlock-keychain) and re-run;" >&2
    echo "       a half-imported identity later surfaces as 'no identity found'." >&2
    exit 1
  fi

  # A self-signed cert is not trusted for code signing by default, so it would
  # not show up under `find-identity -p codesigning`. Add user-domain code-signing
  # trust (one login-password prompt, no sudo) so resolve_identity can pick it.
  if ! security add-trusted-cert -p codeSign -k "$LOGIN_KEYCHAIN" "$tmp/cert.pem" 2>/dev/null; then
    echo "note: could not add code-signing trust automatically — the cert is imported," >&2
    echo "      but you may need to trust it for code signing in Keychain Access." >&2
  fi
  echo "done. The first sign may ask once to allow codesign to use the key — click Always Allow."
}

sign_one() {
  local bin="$1" id="$2"
  [ -f "$bin" ] || return 0
  codesign --force --sign "$id" "$bin"
  codesign --verify --verbose=2 "$bin" 2>&1 | sed 's/^/  /'
  echo "signed: $bin"
}

case "${1:-}" in
  --init)
    create_cert
    ;;
  "")
    id="$(resolve_identity)" || {
      echo "no code-signing identity found." >&2
      echo "  - with Xcode installed, an Apple Development cert is picked automatically;" >&2
      echo "    check: security find-identity -v -p codesigning" >&2
      echo "  - otherwise create a self-signed one: ./scripts/sign.sh --init" >&2
      echo "  - or pin one explicitly: SIGN_IDENTITY=<name-or-sha1> ./scripts/sign.sh" >&2
      exit 1
    }
    echo "signing with identity: $id"
    sign_one "$REPO_ROOT/.build/debug/baaackaaab" "$id"
    sign_one "$REPO_ROOT/.build/release/baaackaaab" "$id"
    ;;
  *)
    echo "usage: $0 [--init]" >&2
    exit 2
    ;;
esac
