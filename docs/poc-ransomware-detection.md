# PoC — ransomware detection (churn anomaly tripwire)

**Claim under test:** the [anomaly warning](health.md#anomaly-warning-source-side-tripwire)
detects a ransomware-shaped mass rewrite of the source — the next backup after a
mass encryption raises a **SPIKE** verdict, and a mass source loss raises a
**SHRINK** verdict — with the *unmodified production thresholds* (spike: data
added > 10× baseline median **and** > 1 GiB; shrink: bytes processed < 50% of
baseline median; silent below 3 baseline runs).

**Result: confirmed.** Both verdicts fire through the real pipeline, with wide
margin (attack landed at ~492× the baseline median). Scope limits below.

## Method

The PoC drives the **real pipeline** the tripwire depends on, not a re-mock of
it: real `restic` backs up a real source tree into a local repository, the
parsed `ResticSummary` is folded into `ChurnMetrics` exactly as `BackupRun`
does per destination, and the verdict comes from `ChurnAnomaly.evaluate`.

1. **Source:** 64 media-like files × 20 MiB of unique random bytes (1.25 GiB).
   Random because photo/video-heavy iCloud data is incompressible — the
   conservative case: compressible text would make the attack's `dataAdded`
   delta *larger*, never smaller.
2. **Baseline life:** one initial full upload, then three organic runs each
   adding one ~2.5 MiB file — the shape of normal incremental use.
3. **Arming check:** with fewer than 3 baseline runs the verdict must be
   `insufficientBaseline` (silent), and an organic run against the armed
   baseline must be `clean` — the discriminating negative controls.
4. **Attack:** every original file's content is replaced with *fresh* random
   bytes — same size, same name, new content. This is the shape an in-place
   file encryptor produces; to restic every block is new, so the next backup
   re-uploads the whole source.
5. **Outage:** 7/8 of the files are deleted (the signed-out-iCloud /
   folder-no-longer-resolves failure mode), then one more backup runs.

## Measurements

Full-scale run, 2026-07-17 · restic 0.19.0 (go1.26.4, darwin/arm64) ·
macOS 26.5.2, Apple silicon · total test wall time 16.1 s.

| Run | data added | bytes processed | Verdict |
|---|---:|---:|---|
| baseline 1 (initial full) | 1280.1 MiB | 1280.0 MiB | — |
| baseline 2 (organic) | 2.6 MiB | 1282.5 MiB | `insufficientBaseline` (arming) |
| baseline 3 (organic) | 2.6 MiB | 1285.0 MiB | — |
| baseline 4 (organic) | 2.6 MiB | 1287.5 MiB | **`clean`** (negative control) |
| **attack** (all 64 files rewritten) | **1280.1 MiB** | 1287.5 MiB | **`SPIKE`** |
| **outage** (7/8 of files gone) | 0.0 MiB | **167.5 MiB** | **`SHRINK`** |

Threshold margins, production values:

- **Spike:** 1280.1 MiB added vs. a 2.6 MiB baseline median → **~492×** the
  10× factor threshold, and 1.25× the 1 GiB absolute floor. Note the floor is
  the binding constraint for small sources: a full rewrite of a source *under*
  1 GiB deliberately does not alarm.
- **Shrink:** 167.5 MiB processed vs. a ~1285 MiB baseline median → **13%**,
  well under the 50% threshold.

## Repeatability

The PoC is a permanent integration test
(`Tests/baaackaaabTests/RansomwarePoCTests.swift`) that runs in the normal
suite at a proportionally scaled size (~6 MiB source, floor scaled 1 GiB →
4 MiB) so every `swift test` re-proves the pipeline without gigabyte I/O. The
production threshold *values* stay pinned separately by `ChurnAnomalyTests`.
The full-scale evidence run above:

```sh
BAAACKAAAB_POC_FULL=1 swift test --filter RansomwarePoCTests
```

It needs `restic` on `PATH`, ~4 GiB of temp disk, and prints a `POC:`
measurement block; everything runs against a throwaway local repository.

## What this does not prove

Honest scope — the PoC turns the *detection claim* from thesis into evidence,
not the whole alerting chain:

- **The surfacing wiring is not covered.** The console warning / macOS banner /
  ntfy push in `BackupRun` is process-exiting code, verified on real hardware
  like the rest of the run-finalizer paths — the PoC stops at the verdict.
- **Detection is after the fact.** The tripwire fires on the *next* backup,
  after the source was rewritten. It limits how long the store keeps ingesting
  encrypted copies; it does not prevent the damage. The old snapshots are
  protected by the append-only store, not by this detector.
- **A slow-roll attacker can stay under it.** Encryption paced below 10× the
  baseline median per run (or under 1 GiB per run) does not trip the spike.
- **A compromised Mac can silence its own warnings.** The banner and push
  channels run on the machine the attacker controls; the tripwire is a
  best-effort early warning against commodity ransomware and accidental mass
  rewrites, not a tamper-proof alarm. The tamper-proof property in this design
  remains the append-only store itself (see the
  [`--doctor` DELETE probe](health.md#maintenance--diagnostics)).
