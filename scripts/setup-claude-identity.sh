#!/usr/bin/env bash
# Configure this repository so commits land under the canonical identity and
# push works via HTTPS-with-token. Forgejo push is HTTP-with-token because the
# sandbox blocks all outgoing SSH on the TCP layer (even to allow-listed hosts).
#
# Run manually once per repo. Claude itself cannot run `git config` (that class
# of subcommand is sandbox-blocked).
#
# This is the COPY-INTO-REPO variant bundled with the new-mirrored-repo skill:
# it is self-contained (no scripts/lib/ dependency) so it keeps working after
# `cp … scripts/` into a fresh project. The shared resolver lives in
# ~/ops/scripts/lib/identity.sh; this file inlines the same logic.
#
# Identity is NOT hardcoded — it is read from an untracked local config so no
# real name/email ever lands in tracked source (privacy pattern):
#   $CLAUDE_IDENTITY_CONF            (explicit override, e.g. for CI), else
#   ~/.config/claudii/identity.conf  (KEY="value": GIT_NAME, GIT_EMAIL)
# Bootstrap it from ~/ops/scripts/identity.conf.example if missing.
#
# What this script sets, scoped to this repo only:
#   - user.name, user.email   → $GIT_NAME / $GIT_EMAIL from the identity config
#   - remote.origin.url       → https://$FORGEJO_HOST/<owner>/<repo>.git
#   - credential.helper       → store --file=~/.config/claudii/git-credentials
#                               (created if missing, mode 600, token from tea)
#
# The Forgejo host comes from $FORGEJO_HOST (see ~/.env); falls back to the
# placeholder forgejo.example.com if unset, so tracked source stays clean.
#
# After this runs, `git push` works without sandbox bypass.
set -euo pipefail

# --- load env (real FORGEJO_HOST lives in ~/.env, chmod 600, never tracked) ---
[[ -f "$HOME/.env" ]] && { set -a; source "$HOME/.env"; set +a; }
FORGEJO_HOST="${FORGEJO_HOST:-forgejo.example.com}"

# --- resolve commit identity (GIT_NAME / GIT_EMAIL) from untracked config -----
IDENTITY_CONF="${CLAUDE_IDENTITY_CONF:-$HOME/.config/claudii/identity.conf}"
# shellcheck source=/dev/null
[[ -f "$IDENTITY_CONF" ]] && source "$IDENTITY_CONF"
if [[ -z "${GIT_NAME:-}" || -z "${GIT_EMAIL:-}" ]]; then
  {
    echo "Commit identity not configured."
    echo "Expected GIT_NAME and GIT_EMAIL in: $IDENTITY_CONF"
    echo "Bootstrap it:"
    echo "  mkdir -p \"$(dirname "$IDENTITY_CONF")\""
    echo "  cp ~/ops/scripts/identity.conf.example \"$IDENTITY_CONF\""
    echo "  # then edit GIT_NAME / GIT_EMAIL inside it"
  } >&2
  exit 1
fi

# --- target repo: $PWD if already a git repo (wrapper), else script-relative --
if [[ ! -d "$PWD/.git" ]]; then
  cd "$(dirname "$0")/.."
fi
REPO_NAME=$(basename "$PWD")
TEA_CONFIG="$HOME/Library/Application Support/tea/config.yml"
CRED_FILE="$HOME/.config/claudii/git-credentials"

if [[ ! -f "$TEA_CONFIG" ]]; then
  echo "Missing tea config at $TEA_CONFIG — install + login tea first." >&2
  exit 1
fi

# Determine the repo owner FIRST: from the existing remote, else $FORGEJO_OWNER
# (~/.env). The push credential must belong to whoever owns the repo.
CURRENT_URL=$(git remote get-url origin 2>/dev/null || true)
if [[ "$CURRENT_URL" =~ /([^/]+)/([^/]+)\.git$ ]] || [[ "$CURRENT_URL" =~ /([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO_FROM_URL="${BASH_REMATCH[2]%.git}"
else
  OWNER="${FORGEJO_OWNER:-}"
  REPO_FROM_URL="$REPO_NAME"
fi
if [[ -z "$OWNER" ]]; then
  echo "Cannot determine repo owner — set origin or FORGEJO_OWNER in ~/.env." >&2
  exit 1
fi

# Resolve the token for the login whose user matches the owner — never the first
# token in the file: config.yml can carry several logins (owner + automation
# bot), and the first is order-dependent. Match by user; push then shows up as
# this account.
TOKEN=$(awk -v want="$OWNER" '
  /^[[:space:]]*-[[:space:]]*name:/ { if (u==want && length(t)) {print t; exit} t=""; u="" }
  /^[[:space:]]*token:/ { t=$NF }
  /^[[:space:]]*user:/  { u=$NF }
  END { if (u==want && length(t)) print t }
' "$TEA_CONFIG")
if [[ -z "$TOKEN" ]]; then
  echo "No tea login with user '$OWNER' in $TEA_CONFIG — add it: tea login add" >&2
  exit 1
fi
TEA_USER="$OWNER"

mkdir -p "$(dirname "$CRED_FILE")"
chmod 700 "$(dirname "$CRED_FILE")"
# Always write the current token — ensures rotation takes effect immediately.
# Other hosts in the file are preserved; only the Forgejo line is replaced.
CRED_LINE="https://${TEA_USER}:${TOKEN}@${FORGEJO_HOST}"
if [[ -f "$CRED_FILE" ]]; then
  grep -v "@${FORGEJO_HOST}" "$CRED_FILE" > "${CRED_FILE}.tmp" || true
  echo "$CRED_LINE" >> "${CRED_FILE}.tmp"
  mv "${CRED_FILE}.tmp" "$CRED_FILE"
else
  echo "$CRED_LINE" > "$CRED_FILE"
fi
chmod 600 "$CRED_FILE"

git config --local user.name "$GIT_NAME"
git config --local user.email "$GIT_EMAIL"
# Reset the inherited helper chain (system osxkeychain + global `store`) with an
# empty-string helper so ONLY the off-screen claudii store runs. Without the
# reset, git also invokes the global `store` on write-back, which locks
# ~/.git-credentials — outside the sandbox's writable paths → a "credential
# storage lock: Operation not permitted" on every push (and would cache the
# token in plaintext there).
git config --local --unset-all credential.helper 2>/dev/null || true
git config --local --add credential.helper ""
git config --local --add credential.helper "store --file=${CRED_FILE}"
git config --local --unset core.sshCommand 2>/dev/null || true

NEW_URL="https://${FORGEJO_HOST}/${OWNER}/${REPO_FROM_URL}.git"
if [[ "$CURRENT_URL" != "$NEW_URL" ]]; then
  git remote set-url origin "$NEW_URL"
  echo "  remote: $CURRENT_URL"
  echo "       → $NEW_URL"
fi

echo
echo "Configured ${REPO_NAME}:"
git config --local --get user.name
git config --local --get user.email
echo "  credential file: $CRED_FILE (mode 600, off-screen)"
echo "  remote: $(git remote get-url origin)"
echo
echo "If this is a brand-new repo, also add a Forgejo deploy key for browsing:"
echo "  https://${FORGEJO_HOST}/${OWNER}/${REPO_FROM_URL}/settings/keys"
