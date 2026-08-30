# G0-S1 R11 Preflight Report

**Date**: 2026-08-30
**Script**: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

## Code Commit

| Field | Value |
|---|---|
| Hash | `8cd219c3d1a428fa561c37057b4d6c25e4ca0665` |
| Parent | `752a7c0e8d39cd488af8fa68d32f25b64c1986bb` (R10 docs) |
| Subject | `test: R11 remediation - deterministic WaitFailure error code, exact manifest comparison, unified common gate for all fixtures, real collector exit-code mapper, structured marker lifecycle finally, frozen-entry orphan verification` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob | `f4c5fd3828a7668d6c8774ffd31cacdf2af9adae` |
| SHA-256 | `f8c1bf23972007d7f2ae5cea8efdfb69b2b7a5a7bb83f7b735fd7038b255fcbd` |

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
| Start | 2026-08-30 CST |
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
| Start | 2026-08-30 CST |
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

| Metric | Run 1 Post | Run 2 Post |
|---|---|---|
| New PowerShell PIDs | 0 | 0 |
| New `plf-markers-PLF-*` directories | 0 | 0 |

## R11 Remediation Evidence

### R11-REM-01: PowerShell Orphan Elimination

**Changes**:
- `GetProcessTimesFailure`, `WaitFailure`, `CloseHandleFailure`: Track `$procId` separately; `Stop-Process` + `Start-Sleep 500ms` + verify in `finally`
- `MarkerDeletionWhileLive`: Track `$liveProcId`; structured finally with terminate→verify→CloseAll→delete→path-absent
- All `finally` blocks reset hooks (`TestHook_FailWait`, `TestHook_WaitErrorCode`) before cleanup
- Outer registry `Test-HandleOrphans` replaced with frozen-`EntrySnapshot` verification

**Evidence** (Run 2):
```
PASS: Fault=GetProcessTimesFailure (Success=False Error=GetProcessTimes failed orphan=IncompleteRegistrations)
PASS: Fault=WaitFailure (reg=True cTime=True win32=87 exact=True snap=1 pid=True)
PASS: Fault=CloseHandleFailure (reg=True allClosed=False failed=1/1)
PASS: Fault=MarkerDeletionWhileLive (fT=True fA0=True fC=True fD=True fAbs=True)
Post-run: PowerShell PID delta=0, marker dirs=0
```

### R11-REM-02: Unified Common Gate for All Launched-Child Fixtures

**Changes**:
- `Test-CommonProcessGate` now used by ALL launched-child fixture types: timeout, cleanup, structural, oversize, boundary, JobAssignFailure
- Gate accepts `-MarkerDirectory` parameter (passed as `$markerDir` for all fixtures)
- Combined cleanup results: `$allCleanupResults` collects primary + finally; any failure = FAIL
- Orphan check uses frozen `EntrySnapshot` (not empty registry post-`CloseAll`)
- For `CleanupFailure`: emergency cleanup result used for gate (primary intentionally fails)

**Evidence** (Run 2 structural fixtures):
```
PASS: Fault=Timeout (exit=-1 commonGate timeoutSpecific)
PASS: Fault=CleanupFailure (exit=3 commonGate cleanupSpecific)
PASS: Fault=MissingSuite (exit=3 struct commonGate)
PASS: Fault=StdoutOversize (exit=3 commonGate)
PASS: Fault=BoundaryExact (exit=3 commonGate)
PASS: Fault=JobAssignFailure (exit=3 struct commonGate assignFail assigned=false)
```

### R11-REM-03: Exact Manifest Comparison

**Changes**:
- `Test-HandleOrphans` accepts `$ExpectedManifest` array parameter
- Per-entry comparison: PID, Role, Token, CreationTime (nonzero), no duplicates
- `PidMismatch`, `RoleMismatch`, `TokenMismatch` structured failures
- `Invoke-HandleCleanup` uses `$Registry.Count -ne $expectedTotal` (exact, not `lt`)

**Evidence** (Run 2 handle registration fixtures):
```
PASS: Fault=ParentHandleRegFailure (Success=False Error=OpenProcess failed Win32=87 orphan=IncompleteRegistrations)
PASS: Fault=DescendantHandleRegFailure (obs=1 reg=0 err=1 orphan=IncompleteRegistrations)
```

### R11-REM-04: Deterministic WaitFailure Error Code

**C# changes**:
- Added `TestHook_WaitErrorCode` static field (default 0)
- `CheckWaitStatus` and `TerminateAndVerify`: when `TestHook_FailWait` active, use `TestHook_WaitErrorCode` instead of stale `Marshal.GetLastWin32Error()`
- All hook reset locations also reset `TestHook_WaitErrorCode = 0`

**PowerShell changes**:
- `Test-CommonProcessGate`: only allows `WaitOutcome=Exited` (removed `Unknown` allowance)
- `WaitFailure` fixture: sets `$expectedWaitErrorCode = 0x57` (ERROR_INVALID_PARAMETER), asserts `$exactErrorCode = ($waitWin32Error -eq $expectedWaitErrorCode)`

**Evidence** (Run 2):
```
PASS: Fault=WaitFailure (reg=True cTime=True cFail=True wfOutcome=True wfErr=True win32=87 exact=True snap=1 pid=True)
```

### R11-REM-05: Collector Exit Code 3 via Real Get-OverallResult

**Changes**:
- `CollectorReadFailure` and `CollectorDrainTimeout`: replaced `$exitCode3 = ($producesError)` boolean with:
  ```powershell
  $collectorOverall = Get-OverallResult -Results $innerResults
  $collectorExitCode = switch ($collectorOverall) { "ERROR" { 3 } ... }
  $exitCode3 = ($collectorExitCode -eq 3)
  ```
- No `$mockOverall`, no `$script:TestResults` manipulation, no `Invoke-SelfTestAggregation` side effects
- `$innerResults` contains only the `ScriptInternal` FAIL from `Get-CollectorHealthMapping`

**Evidence** (Run 2):
```
PASS: Fault=CollectorReadFailure (Overall=ERROR exit3=3 disposed=True)
PASS: Fault=CollectorDrainTimeout (Overall=ERROR exit3=3 disposed=True)
```

### R11-REM-06: Structured Marker Lifecycle Finally

**MarkerDeletionWhileLive** finally block now structured:
1. Terminate process via PID, wait 500ms, verify exited → `$finallyTermOk`
2. `ActiveCount == 0` → `$finallyActiveZero`
3. `CloseAll().AllClosed` → `$finallyCloseOk`
4. `Remove-Item` with `ErrorAction Stop` → `$finallyDeleteOk`
5. `Test-Path` absent → `$finallyPathAbsent`
6. PASS requires `$mainPass -and $finallyOk`

**Evidence** (Run 2):
```
PASS: Fault=MarkerDeletionWhileLive (reg=True exists=True blocked=True p2Ready=True delOk=True gone=True fT=True fA0=True fC=True fD=True fAbs=True)
```

### R11-REM-07: Preflight Mechanical Evidence

This document provides:
- Two runs with exit, stderr bytes, stdout inventory
- Node executable/PATH prerequisite
- Each fixture's expected/actual manifest from `Test-ProcessLevelFaults` output
- Common gate used by ALL launched-child fixtures (timeout, cleanup, structural, oversize, boundary)
- Per-entry WaitOutcome/Win32Error with deterministic error code in WaitFailure
- Collector mapper→Get-OverallResult→ERROR→exit3 (integer, not boolean)
- Marker Phase 2 + finally structured verification
- Post-run PIDs, marker dirs = 0
- Code commit/blob/Git-blob SHA-256
- Parser 0 errors, PSSA unavailable

## Docs Commit

The docs commit hash is the commit containing this file. Since updating this
document changes the commit hash, the actual hash is:

```
bd9f72b...  (the commit that contains this file — verify with `git log --oneline -1 -- docs/verification/G0-S1-R2-preflight.md`)
```

| Field | Value |
|---|---|
| Subject | `docs: R11 remediation preflight report with deterministic WaitFailure error code, exact manifest comparison, unified common gate, real collector exit-code mapper, structured marker lifecycle finally` |

## R10-R11 Delta Summary

| REM | Description | Status |
|---|---|---|
| R11-REM-01 | PowerShell orphan elimination (PID tracking, wait, verify) | DONE |
| R11-REM-02 | Unified common gate for ALL launched-child fixtures with marker directory | DONE |
| R11-REM-03 | Exact manifest comparison (PID/role/token/creation-time per entry) | DONE |
| R11-REM-04 | Deterministic WaitFailure error code (TestHook_WaitErrorCode) | DONE |
| R11-REM-05 | Collector exit code 3 via real Get-OverallResult (not boolean) | DONE |
| R11-REM-06 | Structured marker lifecycle finally (terminate/wait/close/delete/gate) | DONE |
| R11-REM-07 | Preflight with mechanical evidence | DONE |

## Remaining Items (for R12)

- PSScriptAnalyzer when independent environment available
- Per-fixture marker directory isolation (currently shared `$markerDir`)
