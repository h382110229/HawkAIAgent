# G0-S1 R12 Preflight Report

**Date:** 2026-08-30
**Branch:** research/g0-s1-windows-poc
**PR:** #1 (OPEN, Draft, base master, merged=null)
**Script:** `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

---

## Code Commit

| Field | Value |
|---|---|
| Hash | `d5ba1f6a68a3aeaafc17ed0be5832259ed442fa7` |
| Parent | `32382427c6453187cf858506431d2b6ec069d0e9` (R11 docs) |
| Subject | `test: R12 remediation - ExpectedManifest gate integration, real marker deletion, mandatory evidence checks, shared collector exit mapper, Stop-Wait-VerifyOwnedProcess, manifest mismatch meta-tests` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob (SHA-1) | `681e3c9a7d4dc9b6e0097a830108282fc3f9b490` |
| SHA-256 of raw Git blob bytes | `9ff81125e7068c03096dcd458d49942df36afecc1231033d3ff3d092633506f0` |
| SHA-256 of checked-out Windows file | `a1bcaca9ded6d5fa400d9320d8f97e16a17166d59ece97de5829eaa2fd8bab88` |

SHA-256 of raw Git blob bytes computed via `git cat-file blob <blob> | sha256sum`.
SHA-256 of checked-out file computed via `sha256sum <file>`.
CRLF conversion can cause these to differ.

## Static Analysis

| Tool | Result |
|---|---|
| PowerShell Parser | **0 errors** |
| PSScriptAnalyzer Severity Error | **unavailable** (independent environment not available) |

## Prerequisites

| Prerequisite | Value |
|---|---|
| Node executable | `C:\nvm4w\nodejs\node.exe` |
| Node PATH | `PATH` includes nvm4w path |
| PowerShell | 5.1+ (Windows PowerShell) |

---

## Fixture Inventory

Total: **31** fixtures (dynamic `$faults.Count`)

| Category | Count | Names |
|----------|-------|-------|
| structural | 6 | MissingSuite, DeclaredMismatch, PassedMismatch, FailedNonZero, ManifestMismatch, JobAssignFailure |
| timeout | 1 | Timeout |
| oversize | 4 | StdoutOversize, StderrOversize, DualStreamOversize, LongLine |
| boundary | 2 | BoundaryExact, BoundaryOver |
| cleanup | 1 | CleanupFailure |
| handleReg | 2 | ParentHandleRegFailure, DescendantHandleRegFailure |
| collectorFault | 2 | CollectorReadFailure, CollectorDrainTimeout |
| markerLifecycle | 2 | MarkerDeletionWhileLive, MarkerDeletionFailure |
| nativeApiFault | 3 | GetProcessTimesFailure, WaitFailure, CloseHandleFailure |
| manifestMeta | 8 | MetaRoleMismatch, MetaTokenMismatch, MetaExtraEntry, MetaExtraMarker, MetaNullEvidence, MetaEmptyManifest, MetaDuplicateExpectedPID, MetaDuplicateActualPID |

**Formula:** 6+1+4+2+1+2+2+2+3+8 = 31

---

## R15 Helper Total

```
ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(31) = 56
```

Full total: 54 (pure) + 102 (node) + 56 (R15) = 212

---

## Two Consecutive Final Runs

### Run 1

| Field | Value |
|---|---|
| Exit code | **0** |
| Stderr bytes | **0** |
| Total tests | **212** |
| Passed | **212/212** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **31/31 PASS** |

### Run 2

| Field | Value |
|---|---|
| Exit code | **0** |
| Stderr bytes | **0** |
| Total tests | **212** |
| Passed | **212/212** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **31/31 PASS** |

---

## 5-Second Settling Hygiene

| Check | Run 1 Pre | Run 1 Post | Run 1 Delta | Run 2 Pre | Run 2 Post | Run 2 Delta |
|-------|-----------|------------|-------------|-----------|------------|-------------|
| PowerShell processes | 1 | 1 | 0 | 1 | 1 | 0 |
| Marker files (desc-*.txt) | 0 | 0 | 0 | 0 | 0 | 0 |
| Held handles | 0 | 0 | 0 | 0 | 0 | 0 |
| Unfinished tasks | 0 | 0 | 0 | 0 | 0 | 0 |

---

## ExpectedManifest / Marker Matrix

### Launched-Child Fixtures (14 fixtures)

| Fixture | ExpectedManifest | EntrySnapshot | Match |
|---------|-----------------|---------------|-------|
| MissingSuite | 1 (parent) | 1 (parent) | ✓ |
| DeclaredMismatch | 1 (parent) | 1 (parent) | ✓ |
| PassedMismatch | 1 (parent) | 1 (parent) | ✓ |
| FailedNonZero | 1 (parent) | 1 (parent) | ✓ |
| ManifestMismatch | 1 (parent) | 1 (parent) | ✓ |
| Timeout | 2 (parent + timeout-descendant) | 2 (parent + timeout-descendant) | ✓ |
| StdoutOversize | 1 (parent) | 1 (parent) | ✓ |
| StderrOversize | 1 (parent) | 1 (parent) | ✓ |
| DualStreamOversize | 1 (parent) | 1 (parent) | ✓ |
| LongLine | 1 (parent) | 1 (parent) | ✓ |
| BoundaryExact | 1 (parent) | 1 (parent) | ✓ |
| BoundaryOver | 1 (parent) | 1 (parent) | ✓ |
| CleanupFailure | 2 (parent + cleanup-descendant) | 2 (parent + cleanup-descendant) | ✓ |
| JobAssignFailure | 1 (parent) | 1 (parent) | ✓ |

### Meta Negative Tests (8 fixtures)

| Test | Expected | Actual | Gate |
|------|----------|--------|------|
| MetaRoleMismatch | FAIL Role mismatch | FAIL (err=1) | ✓ |
| MetaTokenMismatch | FAIL Token mismatch | FAIL (err=1) | ✓ |
| MetaExtraEntry | FAIL Missing entry | FAIL (err=1) | ✓ |
| MetaExtraMarker | FAIL extra+wrong-role | FAIL (err=2,2) | ✓ |
| MetaNullEvidence | FAIL mandatory null | FAIL (err=3) | ✓ |
| MetaEmptyManifest | FAIL empty manifest | FAIL (err=3) | ✓ |
| MetaDuplicateExpectedPID | FAIL dup expected PID | FAIL (err=3) | ✓ |
| MetaDuplicateActualPID | FAIL dup actual PID | FAIL (err=2) | ✓ |

---

## Key Fixes in R12

1. **ExpectedManifest from known facts** — built from parent registration + descendant registration, NOT from EntrySnapshot/registry reverse-copy
2. **Pre-fixed descendant roles** — timeout-descendant, cleanup-descendant (not from marker content)
3. **Frozen before CloseAll** — ExpectedManifest frozen before Invoke-HandleCleanup (which clears registry via CloseAll)
4. **Gate uses frozen evidence** — orphan check uses EntrySnapshot comparison when ExpectedManifest provided, not live registry
5. **Marker ownership verification** — validates PID/role/token/count before deletion, rejects unexpected markers
6. **Duplicate PID detection** — in both ExpectedManifest and EntrySnapshot maps
7. **IsLaunchedChild guard** — gate rejects empty ExpectedManifest for launched-child fixtures
8. **4 new meta tests** — MetaEmptyManifest, MetaDuplicateExpectedPID, MetaDuplicateActualPID, enhanced MetaExtraMarker

---

## Docs Commit

The docs commit hash is the commit containing this file. Since updating this
document changes the commit hash, the actual hash is verified post-commit
with: `git log --oneline -1 -- docs/verification/G0-S1-R2-preflight.md`

## R11-R12 Delta Summary

| REM | Description | Status |
|---|---|---|
| R12-REM-01 | ExpectedManifest from known facts (not registry reverse-copy) | DONE |
| R12-REM-02 | Pre-fixed descendant roles | DONE |
| R12-REM-03 | Frozen before CloseAll | DONE |
| R12-REM-04 | Gate uses frozen evidence | DONE |
| R12-REM-05 | Marker ownership verification | DONE |
| R12-REM-06 | Duplicate PID detection | DONE |
| R12-REM-07 | IsLaunchedChild guard | DONE |
| R12-REM-08 | 4 new meta tests | DONE |
| R12-REM-09 | Preflight with mechanical evidence | DONE |

## Working Tree Status

- Clean (no untracked files, no modifications)
