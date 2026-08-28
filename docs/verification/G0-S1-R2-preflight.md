# G0-S1 R9 Preflight Report

**Date**: 2026-08-28
**Script**: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

## Code Commit

| Field | Value |
|---|---|
| Hash | `167d29f` |
| Parent | `55ea44a90605117f4963c7285971a43f96484aa3` |
| Subject | `test: R9 remediation — fail-closed registration, phased cleanup, common process gate, native API fault injection, live marker deletion, structured collector gate` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob | `66c8eca63cf1e551172d85cce092d37775e05711` |
| SHA-256 | `c97c54217a7775acff51a27abfaba2dad9ef093e1d5eae983f559a42f7c72443` |

SHA-256 computed on raw git blob bytes (`git cat-file -p <blob> | sha256sum`), not on CRLF-converted working-tree content.

## Static Analysis

| Tool | Result |
|---|---|
| PowerShell Parser | **0 errors** |
| PSScriptAnalyzer Severity Error | **unavailable** |

## Test Runs

Two consecutive `-SelfTestOnly` runs on the exact code commit:

| Run | Exit | Tests | PASS | FAIL | stderr |
|---|---|---|---|---|---|
| Run 1 | 0 | 204 | 204 | 0 | empty |
| Run 2 | 0 | 204 | 204 | 0 | empty |

Suite inventory (both runs identical):

| Suite | Declared | Actual | Passed | Failed |
|---|---|---|---|---|
| Aggregation | 11 | 11 | 11 | 0 |
| NativeJudgment | 24 | 24 | 24 | 0 |
| ParentPath | 4 | 4 | 4 | 0 |
| GateSummary | 15 | 15 | 15 | 0 |
| LockfileReader | 102 | 102 | 102 | 0 |
| ManifestCompare | 14 | 14 | 14 | 0 |
| SuiteEvidence | 11 | 11 | 11 | 0 |
| ProcessLevelFaults | 23 | 23 | 23 | 0 |
| **Total** | **204** | **204** | **204** | **0** |

## R9 Remediation Evidence

### R9-REM-01: Registration Errors Fail-Closed

- Removed "Registration errors are diagnostic" comment from `Invoke-HandleCleanup`
- Registration errors now enter `$errors` array and set `Success=$false`
- `Register-DescendantHandles` duplicate PID handling made idempotent (Observed++, not error)
- `ParentHandleRegFailure` fixture calls real `Test-HandleOrphans(ExpectedParentCount=1)` → `IncompleteRegistrations` (not VerifiedClean)
- `DescendantHandleRegFailure` fixture calls real `Test-HandleOrphans(ExpectedDescendantCount=1)` → `IncompleteRegistrations`

| Fixture | Low-level | Gate Result | VerifiedClean? |
|---|---|---|---|
| ParentHandleRegFailure | Success=False Error=OpenProcess failed | IncompleteRegistrations | No |
| DescendantHandleRegFailure | obs=1 reg=0 err=1 | IncompleteRegistrations | No |

### R9-REM-02: Expected Registration Counts

- `$expParentCount` computed per fixture: 1 for launchChild, 0 for pure fixtures
- `$expDescendantCount`: 1 for Timeout/CleanupFailure, 0 for others
- All `Invoke-HandleCleanup` calls pass `-ExpectedParentCount $expParentCount -ExpectedDescendantCount $expDescendantCount`
- Default 0 never used for any launched-child fixture

### R9-REM-03: Phased Cleanup

`Invoke-HandleCleanup` refactored into 5 phases:

1. **Job terminate**: if assigned, terminate job processes
2. **Register descendants**: `Register-DescendantHandles` — errors are failures
3. **Terminate/wait**: `$Registry.IsProcessExited($i)` (not stale copy) → `TerminateProcessByIndex` — entry evidence frozen to `$entrySnapshot` before any state changes
4. **Verify activeBeforeClose**: `ActiveCount` checked BEFORE `CloseAll()` — prevents active=0 illusion
5. **CloseAll**: only after verification. Return includes `EntrySnapshot`, `EntryCount`, `ActiveBeforeClose`

### R9-REM-04: Unified Common Process Gate

All launchChild fixtures (structural, oversize, boundary, timeout, cleanup) require:

| Check | Variable | Description |
|---|---|---|
| Parent registration | `$parentRegOk` | `parentRegistered.Success` |
| Creation time | `$creationTimeOk` | `parentRegistered.CreationTime -ne 0` |
| Capture healthy | `$captureHealthy` | `collector.Healthy -and drainCompleted` |
| Cleanup success | `$cleanupOk` | `effectiveCleanup.Success` |
| Close result | `$closeResultOk` | `effectiveCleanup.CloseResult.AllClosed` |
| Active before close | `$activeBeforeCloseZero` | `effectiveCleanup.ActiveBeforeClose -eq 0` |
| Orphan free | `$orphanFree` | `Test-HandleOrphans.Status -eq 'VerifiedClean'` |

Fixture-specific assertions (ScriptInternal, stream evidence, etc.) are added ON TOP of common gate, never substituting.

Per-fixture common gate results (all PASS):

| Fixture | pReg | cTime | cOk | close | of | h |
|---|---|---|---|---|---|---|
| MissingSuite | True | True | True | True | True | True |
| DeclaredMismatch | True | True | True | True | True | True |
| PassedMismatch | True | True | True | True | True | True |
| FailedNonZero | True | True | True | True | True | True |
| ManifestMismatch | True | True | True | True | True | True |
| Timeout | True | True | True | True | True | True |
| StdoutOversize | True | True | True | True | True | True |
| StderrOversize | True | True | True | True | True | True |
| DualStreamOversize | True | True | True | True | True | True |
| LongLine | True | True | True | True | True | True |
| BoundaryExact | True | True | True | True | True | True |
| BoundaryOver | True | True | True | True | True | True |
| CleanupFailure | True | True | True | True | True | True |
| JobAssignFailure | True | True | True | True | True | True |

### R9-REM-05: JobAssignFailure Real Fallback

- Injection point moved BEFORE real `AssignProcessToJobObject` OS call
- `$fault -eq 'JobAssignFailure'` → skip OS call entirely, set `$assignedToJob = $false`
- Process is NOT assigned to Job Object (pure Handles fallback proven)
- Gate requires: `assignmentFailureInjected`, `assignedToJob=false`, full common gate, child structural evidence (exit3/UNTRUSTED/ScriptInternal)

| Check | Value |
|---|---|
| assignmentFailureInjected | True (stdout: JOB-ASSIGN-FAILURE-INJECTED) |
| assignedToJob | False (deterministic skip, not post-hoc override) |
| parentRegistered | True |
| creationTime | Nonzero |
| verificationSource | Handles |
| cleanupSuccess | True |
| closeResult.AllClosed | True |
| orphanFree | True |
| captureHealthy | True |
| child exit | 3 |
| ScriptInternal | True |
| UNTRUSTED | True |

### R9-REM-06: MarkerDeletionWhileLive — Two-Phase

**Phase 1 (live handle):**
- Start sleeping child, register held handle (`RegisterProcess` → Success)
- Create marker file, verify exists
- Call `Delete-OwnedMarkers` → `BlockedLiveHandles` (activeCount > 0)
- Marker still exists after rejected deletion

**Phase 2 (after close):**
- Terminate child, close handle via `CloseAll()`
- Call `Delete-OwnedMarkers` → Success
- Directory no longer exists

| Phase | Operation | Result | Marker State |
|---|---|---|---|
| 1 | Delete while live | BlockedLiveHandles | Still exists |
| 2 | Delete after close | Success | Gone |

### R9-REM-07: MarkerDeletionFailure — No Fallback

- Lock setup failure → fixture FAIL (no `$pass = $markerExists` fallback)
- First `Delete-OwnedMarkers` → structured error (file in use, Windows error)
- Marker still exists after failed deletion
- Release lock, second `Delete-OwnedMarkers` → Success
- Directory no longer exists

| Phase | Operation | Result | Marker State |
|---|---|---|---|
| 1 | Delete with lock | Fail (file in use) | Still exists |
| 2 | Delete after release | Success | Gone |

### R9-REM-08: Native API Failure Injection

**C# Test Hooks** (static fields on `ProcessHandleRegistry`):

| Hook | Effect | Handle Safety |
|---|---|---|
| `TestHook_FailGetProcessTimes` | `RegisterProcess` returns `Success=false Error="GetProcessTimes failed"`, closes handle | Real handle closed in error path |
| `TestHook_FailWait` | `IsProcessExited` returns false (WAIT_FAILED), `TerminateProcessByIndex` fails | Real handle closed in finally |
| `TestHook_FailClose` | `GetCloseResult` reports failure, but still calls real `CloseHandle` | Real handle closed (leak-safe) |

**Hook Isolation:**
- All hooks reset to `$false` at start of each fixture iteration
- `nativeApiFault` section asserts all hooks clean before test execution
- Each fixture resets its hook in `finally` block
- Cross-fixture contamination prevented

**Fixture Results:**

| Fixture | Registration | Cleanup/Gate | Leak-free |
|---|---|---|---|
| GetProcessTimesFailure | Success=False Error="GetProcessTimes failed" | orphan=IncompleteRegistrations | Yes (Stop-Process + Dispose) |
| WaitFailure | Success=True, reg=1, cTime nonzero | cleanupFail, termErr=True, snap=1 | Yes (Stop-Process + CloseAll + Dispose) |
| CloseHandleFailure | Success=True | allClosed=False, failed=1/1 | Yes (hook closes real handle) |

WaitFailure entry snapshot (frozen before CloseAll):

| Field | Value |
|---|---|
| EntryCount | 1 |
| Pid | matches child PID |
| Role | "wait-test" |
| CreationTime | nonzero |

### R9-REM-09: Collector Fault Structured Gate

Both collector fault fixtures call the REAL `Get-OverallResult` function with mock `ScriptInternal` results, proving the production aggregation path produces `Overall=ERROR` (exit 3).

| Fixture | Low-level | Get-OverallResult | Stream/CTS Released |
|---|---|---|---|
| CollectorReadFailure | StdoutFaulted=True Healthy=False | ERROR | MemoryStream disposed, task completed |
| CollectorDrainTimeout | DrainTimedOut=True Healthy=False | ERROR | Pipe streams disposed, CTS cancelled |

### R9-REM-10: Preflight Accuracy

- No contradictory claims (registration fail-closed AND registration diagnostic)
- Per-fixture commonProcessGate fields recorded
- Expected/actual parent/descendant handle counts, creation time, exit, close recorded
- JobAssignFailure fallback matrix recorded (injection before OS call)
- Live-marker two-phase, delete-failure two-phase recorded
- GetProcessTimes/Wait/Close failure injection recorded with hook isolation
- Collector inner ScriptInternal/ERROR via real Get-OverallResult recorded
- Entry snapshot frozen before CloseAll

## Process/Marker/Handle/Task Leak Verification

| Check | Pre-run | Post-run | Delta |
|---|---|---|---|
| PowerShell PIDs | 0 new | 0 new | 0 |
| `plf-markers-PLF-*` directories | 0 | 0 | 0 |
| Open handles (fixtureRegistry) | N/A | 0 (all CloseAll) | 0 |
| Unfinished collector tasks | N/A | 0 (all drained) | 0 |

## Non-action Checklist

- [x] No npm install / Harness / HTTP/WS / port operations
- [x] No real credentials or API keys
- [x] No process-name-wide kill (all kills are handle-based or token-verified)
- [x] PR remains OPEN + Draft, base=master, merged=null
- [x] No merge, no Ready, no master modification
- [x] No Phase B / G0-S2 entry
- [x] No Full PoC / Harness run
