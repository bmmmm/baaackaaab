#!/bin/bash
# Repeatable TTY merge-gate for the command-center TUI: runs the expect/pty
# smoke (scripts/tui-smoke.exp) against an ISOLATED throwaway store, so it
# never touches the operator's real config, credentials, or run history.
#
# Usage: scripts/tui-smoke.sh [path-to-baaackaaab-binary]
# Without an argument the debug binary is built (swift build) and used.
# Hard-fails when expect or a pty is unavailable — a smoke gate that can skip
# itself silently is worse than none.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v expect >/dev/null || { echo "FAIL: expect not found (ships with macOS)"; exit 1; }

bin="${1:-}"
if [[ -z "$bin" ]]; then
    swift build >/dev/null
    bin="$(swift build --show-bin-path)/baaackaaab"
fi
[[ -x "$bin" ]] || { echo "FAIL: binary not executable: $bin"; exit 1; }

# Isolated store: no destinations -> the restore screen path stays offline.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/baaackaaab-tui-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export BAAACKAAAB_SUPPORT_DIR="$tmp/support"
export TERM="${TERM:-xterm-256color}"
config="$tmp/backup-set.json"

expect "$repo_root/scripts/tui-smoke.exp" "$bin" "$config"
