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

.PHONY: build release test sign sign-init clean

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
