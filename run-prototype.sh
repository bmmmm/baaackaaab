#!/usr/bin/env bash
set -euo pipefail

# baaackaaab prototype runner.
#
# 1) build the CLI
# 2) drive backup: materialize + verify each Drive folder in place, then restic
#    reads the source tree directly (no full-size staging copy)
# 3) photos backup: export the album in byte-budgeted batches; each batch is
#    backed up and then deleted, so peak extra disk is ~one batch
#
# The CLI now calls restic itself (one snapshot per Drive set + one per photo
# batch, all sharing a run-<timestamp> tag). The local restic repo here is a
# stand-in for the append-only server; the client flow is identical.
#
# IMPORTANT: run this from a REAL terminal, not an automated/sandboxed shell,
# so the Photos permission prompt can be answered and iCloud downloads proceed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# Repeatable: pass several Drive folders. Defaults to one small test folder.
DRIVE_FOLDERS=("${DRIVE_FOLDER:-$HOME/Documents/misc/Anleitungen}")
PHOTO_ALBUM="${PHOTO_ALBUM:-baaackaaab-test}"
STAGING="${STAGING:-$REPO_ROOT/tmp/staging}"
# Small batch budget for the test so the batching actually triggers (50 MB).
PHOTO_BATCH_BYTES="${PHOTO_BATCH_BYTES:-50000000}"
# Pin the restic host: ProcessInfo.hostName drifts (mDNS name flaps between
# "macbook" and "macb-xxxx.local"), which breaks parent-snapshot detection and
# `--host` filtering. A stable host is part of the backup client's identity.
BACKUP_HOST="${BACKUP_HOST:-macbook}"

# restic reads the repo location + password from the environment.
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-$REPO_ROOT/tmp/restic-repo}"
# Prototype-only throwaway password for a local test repo. NOT a secret and not
# for real use — the real repo password will come from the Keychain.
export RESTIC_PASSWORD="${RESTIC_PASSWORD:-baaackaaab-prototype-throwaway}"

echo "== build =="
swift build -c release

echo "== backup (drive in place + photos in batches) =="
rm -rf "$STAGING"
drive_args=()
for f in "${DRIVE_FOLDERS[@]}"; do drive_args+=(--drive-folder "$f"); done
.build/release/baaackaaab \
  "${drive_args[@]}" \
  --photo-album "$PHOTO_ALBUM" \
  --staging "$STAGING" \
  --photo-batch-bytes "$PHOTO_BATCH_BYTES" \
  --host "$BACKUP_HOST"

echo "== restic snapshots =="
restic snapshots

echo "== done — repo at $RESTIC_REPOSITORY =="
