# PoC — recovery-kit disaster drill

**Claim under test:** the [emergency recovery kit](recovery.md#emergency-recovery-kit)'s
sheet contains everything needed to recover the data with **stock restic on any
machine** — no baaackaaab binary, no Mac, no credential files.

**Result: confirmed.** The sheet's own recovery commands, executed verbatim in a
clean environment, restore the data byte-identically.

## Method

The test (`Tests/baaackaaabTests/RecoveryKitPoCTests.swift`, runs in every
`swift test`) deliberately does **not** re-derive the recovery procedure — that
would prove the test author knows how to use restic, not that the sheet works:

1. Known bytes are backed up through the real backend into a throwaway local
   repository.
2. The real sheet is composed from the real entry builder (the same
   `Destination` accessors the CLI export reads).
3. The fenced `sh` block under the destination's heading — exactly what a
   disaster victim would copy-paste — is extracted and executed **verbatim**
   via `/bin/sh -e` in a fresh working directory with a minimal environment:
   `PATH`, an empty `HOME`, an isolated restic cache. No `RESTIC_*` variables
   leak in; the script must be self-sufficient.
4. The restored file (the sheet's own `restic restore latest --target
   ./recovered --verify`) is compared byte-for-byte against the source.

Because the executed commands come out of the sheet at test time, any future
drift in the sheet — a renamed field, a wrong URL form, a command stock restic
does not accept — fails the suite, permanently.

## What this does not prove

- **The destination here is a local path.** A `rest:` destination embeds the
  htpasswd credential in the repo URL; that derivation and extraction is
  covered by the credential unit tests, not by this end-to-end run (it would
  need a live rest-server). The sheet's command shape is identical either way.
- **The encryption wrapper is exercised separately.** The kit's
  openssl-encrypted variant (`--export-recovery-kit`) wraps this same
  plaintext; passphrase validation and the openssl invocation are covered by
  the recovery-kit unit tests. The PoC proves the *content* recovers data.
- **Human factors stay human.** The kit only works if it was exported, moved
  off the Mac, and is findable in a disaster — the tool warns, but cannot
  verify that.
