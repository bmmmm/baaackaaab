# PoC — bit-rot detection (rotating read-data check)

**Claim under test:** the [rotating integrity check](health.md#rotating-integrity-check)
re-hashes stored pack bytes and catches on-disk corruption — "the thing a
restore drill (which only samples) cannot", and the thing the structural check
alone cannot see.

**Result: confirmed, including the discriminating half.** One flipped byte in
the middle of a data pack:

- the **structural** check (`restic check`, no `--read-data`) stays **clean** —
  size, index, and layout are untouched, so nothing structural notices;
- the **read-data** check (the exact `checkRepo(readDataSubset:)` path the
  check timer drives, subset from the production `RotatingCheck.subsetSpec`
  builder) **fails** with concrete, surfaceable error lines — restic reports
  `ciphertext verification failed` for the affected blobs and the changed pack
  id.

That second bullet is the alarm the timer banners on; the first bullet is the
measured proof of *why* the read-data rotation exists at all.

## Method

`Tests/baaackaaabTests/BitRotPoCTests.swift`, runs in every `swift test`:

1. 4 MiB of incompressible random bytes are backed up into a throwaway local
   repository (incompressible so the pack on disk carries those bytes and a
   mid-file flip cannot land in compressible slack).
2. Negative control: the full read-data check (`--read-data-subset=1/1`) is
   clean on the intact repo.
3. One byte in the middle of the largest data pack is XOR-flipped — same size,
   same name. restic writes packs read-only; the mode bit is lifted first,
   which is part of the simulation, not a cheat: real bit-rot happens below
   the permission layer.
4. Assertions: structural check still clean; read-data check not clean, not
   misclassified as a lock conflict, and carrying non-empty error lines.

## What this does not prove

- **Rotation coverage over time, not per run.** The PoC reads the full pack
  set (`1/1`); production reads 1/8 per scheduled run, so a freshly rotten
  pack is *guaranteed* caught only within a full 8-run cycle. The slice
  arithmetic is pinned by its own unit tests.
- **Detection, not repair.** The Mac has no delete/prune right; a damaged repo
  is repaired server-side (typically from a second destination or the
  server's own redundancy). The check's job ends at the loud, early alarm.
- **Local-path backend.** Reading via a `rest:` server exercises the same
  restic verification against bytes served over HTTP; the hashing is
  identical, the transport is not.
