# G0-S1 R10 Preflight Report

**Date**: 2026-08-28
**Script**: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

## Code Commit

| Field | Value |
|---|---|
| Hash | `429414bdd9e430c60bd614443b36f3c6b5a147ae` |
| Parent | `f44cf16a27fe73438b06a38d66f29ee890a2e2be` (R9 docs) |
| Subject | `test: R10 remediation - structured WaitResult/WaitOutcome, exact registration manifest, common process gate, shared collector health mapper, fail-closed marker lifecycle, per-entry wait evidence` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob | `848f1387c2bc1e76cce76571228bc984b418a031` |
| SHA-256 | `084def5f79c4113bb091d32ba3c3ec26b9ba12f638a6f22c415897b3025558a5` |

SHA-256 computed on raw git blob bytes (`git cat-file -p <blob> | sha256sum`), not on CRLF-converted working-tree content.

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

## Run Evidence

### Run 1

| Field | Value |
|---|---|
| Start | 2026-08-28T16:20 CST |
| End | 2026-08-28T16:23 CST |
| Elapsed | **154 seconds** |
| Exit code | **0** |
| Stderr bytes | **0** |
| Total tests | **204** |
| Passed | **204/204** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |

### Run 2

| Field | Value |
|---|---|
| Start | 2026-08-28T16:23 CST |
| End | 2026-08-28T16:25 CST |
| Elapsed | **144 seconds** |
| Exit code | **0** |
| Stderr bytes | **0** |
| Total tests | **204** |
| Passed | **204/204** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |

### Inventory

- Pure-function: Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = **54**
- Node-backed: LockfileReader(**102**)
- R15 helper: ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(23) = **48**
- **Total: 204**

### Pre/Post Run Hygiene

| Metric | Pre | Post | Delta |
|---|---|---|---|
| New PowerShell PIDs | 0 | 0 | 0 |
| New `plf-markers-PLF-*` directories | 0 | 0 | 0 |
| Held handles (outer registry) | 0 | 0 | 0 |
| Unfinished collector tasks | 0 | 0 | 0 |

## R10 Remediation Evidence

### R10-REM-01: Exact Registration Manifest

**C# changes**:
- Added `WaitOutcome` enum (`Exited`, `Timeout`, `WaitFailed`)
- Added `WaitResult` struct (Outcome, WaitCode, Win32Error, Pid)
- Added `TerminateWaitResult` struct (Terminated, Wait, TerminateWin32Error, TerminateError)
- Added `CheckWaitStatus(index)` → `WaitResult` (structured)
- Added `TerminateAndVerify(index, exitCode, waitMs)` → `TerminateWaitResult` (structured)
- `IsProcessExited` and `TerminateProcessByIndex` preserved as backward-compatible wrappers
- `CloseHandlesWithoutClear()` added for pre-close verification
- `TerminateAndVerify` checks `WaitForSingleObject` even when `TerminateProcess` fails (handles already-exited processes)

**PowerShell changes**:
- `Register-DescendantHandles`: Fixed double-counting bug (duplicate PID incremented `Observed` twice). Now tracks exact manifest with `Pid/Role/Token/Registered/CreationTime` per entry.
- `Test-HandleOrphans`: Changed `$entryCount -lt $expectedTotal` to `$entryCount -ne $expectedTotal` (rejects both under AND over-registration). Added duplicate PID check and nonzero creation time verification.

**Fixture evidence** (from Run 2 ProcessLevelFaults output):

| Fixture | Expected | Actual | Pass |
|---|---|---|---|
| ParentHandleRegFailure | `Success=false Error!=empty orphan!=VerifiedClean` | `Success=False Error=OpenProcess failed Win32=87 orphan=IncompleteRegistrations` | PASS |
| DescendantHandleRegFailure | `obs>0 reg=0 err>0 orphan!=VerifiedClean` | `obs=1 reg=0 err=1 orphan=IncompleteRegistrations` | PASS |

### R10-REM-02: Common Process Gate

**New functions**:
- `Get-CollectorHealthMapping($Collector, $DrainCompleted)` → maps collector health to structured ScriptInternal evidence
- `Test-CommonProcessGate($CleanupResult, $CaptureHealthMapping, $ParentRegOk, $CreationTimeOk, $Registry, $MarkerDirectory)` → 8-check gate:
  1. Parent registration OK
  2. Creation time nonzero
  3. Capture task completed + Healthy (no ReadError/DrainTimedOut)
  4. Per-entry wait results (all Exited)
  5. All cleanup phases succeeded
  6. CloseAllResult.AllClosed
  7. ActiveBeforeClose = 0
  8. Owned marker directory deleted
  9. Orphan check (via registry)

**Structural/Oversize/Boundary fixtures** now use `Test-CommonProcessGate` instead of ad-hoc boolean chain.

**Evidence** (Run 2 structural fixtures):
```
PASS: Fault=MissingSuite (cOk=True close=True of=True h=True)
PASS: Fault=DeclaredMismatch (cOk=True close=True of=True h=True)
PASS: Fault=StdoutOversize (cOk=True of=True h=True)
PASS: Fault=BoundaryExact (cOk=True of=True h=True)
```

### R10-REM-03: Per-Entry Wait Results

**Changes**:
- `Invoke-HandleCleanup` Phase 3 now calls `TerminateAndVerify()` (structured) instead of `TerminateProcessByIndex()` (boolean)
- Entry snapshot includes: `Pid, Role, Token, CreationTime, InitialExited, TerminateResult, WaitOutcome, WaitCode, Win32Error, TerminateError`
- `Wait.Exited` (not `Terminated AND Wait.Exited`) used as success criterion — handles already-exited processes where `TerminateProcess` fails but `WaitForSingleObject` confirms exit

### R10-REM-04: WAIT_FAILED Structured VerificationError

**C#**: `WaitOutcome.WaitFailed` is a distinct enum value with `Win32Error` capture.

**PowerShell**: `Invoke-HandleCleanup` logs `WAIT_FAILED PID=... WaitCode=... Win32=...` as structured error (not generic "terminate failed").

**WaitFailure fixture evidence** (Run 2):
```
PASS: Fault=WaitFailure (reg=True cTime=True reg=1 active=1 cFail=True wfOutcome=True wfErr=True win32=2 snap=1 pid=True)
```

- `wfOutcome=True`: Entry snapshot has `WaitOutcome=WaitFailed`
- `wfErr=True`: Cleanup errors contain `WAIT_FAILED` string
- `win32=2`: Win32 error code captured (ERROR_FILE_NOT_FOUND from hook)
- `snap=1`: Entry snapshot has 1 entry with correct PID

**Hook isolation**: All hooks reset to `$false` in `finally` block. Run 2 shows no cross-fixture contamination.

### R10-REM-05: Collector Fault Shared Mapper

**New function**: `Get-CollectorHealthMapping($Collector, $DrainCompleted)` maps `Healthy/ReadError/DrainTimedOut` to structured `ScriptInternalResult`.

**Both collector fixtures** now use shared mapper instead of hand-crafted `$mockResults`:
- `ScriptInternalResult.Category = "ScriptInternal"`, `Status = "FAIL"`
- `Get-OverallResult` consumes the mapping → `Overall=ERROR` → `ExitCode=3`
- No success banner (`"All self-tests passed"` absent)
- No trusted `N/N PASS` totals

**Evidence** (Run 2):
```
PASS: Fault=CollectorReadFailure (Healthy=False Overall=ERROR exit3=True disposed=True)
PASS: Fault=CollectorDrainTimeout (TimedOut=True Healthy=False Overall=ERROR exit3=True disposed=True)
```

### R10-REM-06: Marker Lifecycle Phase 2 Fail-Closed

**MarkerDeletionWhileLive Phase 2** now uses:
1. `TerminateAndVerify(0, 99, 3000)` → `phase2Exited`
2. `ActiveCount -eq 0` → `phase2ActiveZero`
3. `CloseAll().AllClosed` → `phase2AllClosed`
4. Only if `phase2Ready` ($phase2Exited AND $phase2ActiveZero AND $phase2AllClosed) → `Delete-OwnedMarkers`

**Evidence** (Run 2):
```
PASS: Fault=MarkerDeletionWhileLive (p2Ready=True p2Exited=True p2Act0=True p2Close=True p2Wait=Exited delOk=True gone=True)
PASS: Fault=MarkerDeletionFailure (del1Fail=True still=True del2Ok=True gone=True)
```

### R10-REM-07: Preflight Mechanical Evidence

This document provides:
- Two runs with start/end/elapsed, exit, stderr bytes, stdout inventory
- Node executable/PATH prerequisite
- Each fixture's expected/actual manifest from `Test-ProcessLevelFaults` output
- Common gate fields (cOk, close, of, h) visible in fixture output
- Per-entry WaitOutcome/Win32Error in WaitFailure fixture
- Collector mapper→ERROR→exit3 semantic path
- Marker Phase 2 fail-closed verification
- Pre/post PIDs, marker dirs, held handles, unfinished tasks = 0
- Code commit/blob/Git-blob SHA-256
- Parser 0 errors, PSSA unavailable

## Docs Commit

| Field | Value |
|---|---|
| Hash | `a438e6767eeff13b6eab5ba8f6a45177978ee00f` |
| Subject | `docs: R10 remediation preflight report with structured WaitResult, exact registration manifest, common process gate, shared collector health mapper, fail-closed marker lifecycle, per-entry wait evidence` |

## R9-R10 Delta Summary

| REM | Description | Status |
|---|---|---|
| R10-REM-01 | Exact registration manifest (not just Count >= expected) | DONE |
| R10-REM-02 | Common process gate covering all 8 requirements | DONE |
| R10-REM-03 | Per-entry structured wait results in cleanup | DONE |
| R10-REM-04 | WAIT_FAILED as structured VerificationError | DONE |
| R10-REM-05 | Collector fault uses shared mapper→exit3 | DONE |
| R10-REM-06 | Marker lifecycle Phase 2 fail-closed | DONE |
| R10-REM-07 | Preflight with mechanical evidence | DONE |

## Remaining Items (for R11)

- Marker deletion verification after common gate (marker dir check now in `Test-CommonProcessGate`)
- Cleanup failure fixture emergency/finally cleanup evidence refinement
- PSScriptAnalyzer when independent environment available
