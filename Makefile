# baaackaaab — build + stable code-signing.
#
# `swift build` produces an ad-hoc-signed binary whose code identity changes on
# every build, which resets the Keychain ACL and Photos (TCC) grants. Signing
# with a stable self-signed identity after each build keeps those grants alive,
# so the unattended timer run never blocks on a permission prompt.
#
# One-time setup:  make sign-init   (creates the self-signed certificate)
# Then:            make             (debug build + sign)
#                  make release     (release build + sign)

.PHONY: build release test sign sign-init clean install-hooks

build:
	swift build
	./scripts/sign.sh

# Pure-logic unit tests (headless: argument parsing, backup-set model, restore
# path-safety, secret redaction, the destination + run-history stores). They run
# against a throwaway store via BAAACKAAAB_SUPPORT_DIR and never touch the TTY
# TUI, live restic, Photos/TCC or launchd — those stay operator-verified.
test:
	swift test

release:
	swift build -c release
	./scripts/sign.sh

# Sign already-built binaries without rebuilding.
sign:
	./scripts/sign.sh

# One-time: create the self-signed code-signing certificate.
sign-init:
	./scripts/sign.sh --init

clean:
	swift package clean

# One-time: point git at the tracked .githooks/ dir, so pre-push runs
# `swift build` + `swift test` before every push (no macOS CI runner exists —
# the dev Mac gates itself; see issue #4). Bypass once with `git push --no-verify`.
install-hooks:
	git config core.hooksPath .githooks
	@echo "hooks installed: pre-push now builds + tests (bypass once: git push --no-verify)"
