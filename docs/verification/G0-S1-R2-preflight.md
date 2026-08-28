# G0-S1 R8 Preflight Report

**Date**: 2026-08-28
**Script**: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

## Code Commit

| Field | Value |
|---|---|
| Hash | `9e186f9` |
| Parent | `1b8a0e2d55820baf1572f63f13bdd9c6109970d0` |
| Subject | `test: R8 remediation — fail-closed handle registration, collector faults, marker lifecycle, per-fixture registry` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob | `ffdc8d7efcb46a5c92bd945abf2822198cecda1f` |
| SHA-256 | `93f91222289d93a48247ec274456f4a48773c4da219a57635440be17a3a7c287` |

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
| Run 1 | 0 | 201 | 201 | 0 | empty |
| Run 2 | 0 | 201 | 201 | 0 | empty |

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
| ProcessLevelFaults | 20 | 20 | 20 | 0 |
| **Total** | **201** | **201** | **201** | **0** |

## R8 Remediation Evidence

### R8-REM-01: Handle Registration Fail-Closed

**C# ProcessHandleRegistry changes:**

- `RegistrationResult` struct: `{ Success, Handle, CreationTime, Win32Error, Error }`
- `RegisterProcess()` returns `RegistrationResult` instead of `bool`
- `GetProcessTimes` return value checked; failure closes handle and returns structured error
- `CreationTime` required non-zero; zero returns error with closed handle
- `CloseAllResult` struct: `{ Attempted, Succeeded, Failed, FailedPids, AllClosed }`
- `CloseAll()` returns `CloseAllResult`; tracks each `CloseHandle` result

**Register-DescendantHandles rewrite:**

- Returns structured result: `{ Observed, Registered, Errors, Entries }`
- Empty `catch {}` eliminated; all errors captured in `Errors` array
- Token mismatch, PID parse failure, role empty, duplicate PID all fail closed
- Registration failure (OpenProcess/GetProcessTimes) logged in Errors

**Test-HandleOrphans enhancement:**

- Added `ExpectedParentCount` / `ExpectedDescendantCount` parameters
- Returns `IncompleteRegistrations` if registered count < expected total
- Only returns `VerifiedClean` when all expected registrations complete and active=0

**Per-fixture registry isolation:**

- Each fixture creates `$fixtureRegistry = New-Object ProcessHandleRegistry`
- No cross-fixture PID contamination possible
- Outer `$handleRegistry` used only for final orphan check

**New fixtures:**

| Fixture | Expected | Actual | Result |
|---|---|---|---|
| ParentHandleRegFailure | Success=false Error!=empty | Success=False Error=OpenProcess failed Win32=87 | PASS |
| DescendantHandleRegFailure | obs>0 reg=0 err>0 | obs=3 reg=0 err=3 | PASS |

### R8-REM-02: Creation-Time & Native API Verification

- `RegisterProcess` checks `GetProcessTimes` bool return; failure → close handle, return error
- `CreationTime` required non-zero; zero treated as error (handle closed)
- `RegistrationResult.Win32Error` captures `Marshal.GetLastWin32Error()` at failure point
- `CloseAll()` returns per-handle success/failure with `FailedPids` array
- Timeout fixture `pReg=True` confirms parent handle registered with valid creation time

### R8-REM-03: JobAssignFailure Deterministic Injection

- Controller-side: after job assignment attempt, `$assignedToJob` forced to `$false` for `JobAssignFailure` fixture
- Child outputs `JOB-ASSIGN-FAILURE-INJECTED: <token>` marker
- Fixture PASS requires: exit=3, struct, untrusted, stderr=0, budget, healthy
- Handle-based cleanup verified without job object assistance

### R8-REM-04: Collector Failure Fixtures

**CollectorReadFailure:**

- Creates `MemoryStream`, writes 3 bytes, disposes it (ReadAsync will throw)
- `BoundedStreamCollector.CollectAsync` called with disposed stream
- Verified: `StdoutFaulted=True`, `Healthy=False`
- Fail-closed: fault detected, resources released

**CollectorDrainTimeout:**

- Creates `AnonymousPipeServerStream` (never writes, ReadAsync blocks)
- Collector called with 100ms deadline
- Verified: `DrainTimedOut=True`, `Healthy=False`
- CTS cancelled, pipe streams disposed, no hang

### R8-REM-05: Marker Deletion Lifecycle

**MarkerDeletionWhileLive:**

- Creates marker file, verifies existence
- Deletes with no active handles → succeeds
- Verified: exists=True, gone=True

**MarkerDeletionFailure:**

- Opens marker file with exclusive lock (File.Open with None share)
- Attempts Remove-Item → fails (file in use on Windows)
- Error caught, fail-closed verified
- Lock released, cleanup succeeds
- Verified: exists=True, del=caught-error

### R8-REM-06: Cleanup Results Not Ignored

- `$primaryCleanupResult` and `$finallyCleanupResult` saved (not piped to `Out-Null`)
- Cleanup `Success`, `ActiveAfter`, `CloseResult` checked in pass predicates
- Timeout fixture: `parentRegOk` required in pass predicate
- CleanupFailure fixture: `cleanupOk` required in pass predicate
- Final orphan check: `CloseAllResult.AllClosed` checked; failure → `$allPassed = $false`
- `Invoke-HandleCleanup`: registration errors treated as diagnostic (not cleanup failures)

### R8-REM-07: Preflight Accuracy

- Two runs recorded with exact exit codes, test counts, stderr state
- Suite inventory: 8 suites, 201 total (was 195 in R7)
- ProcessLevelFaults: 20 fixtures (was 14), all PASS
- New fault matrix: ParentHandleRegFailure, DescendantHandleRegFailure, CollectorReadFailure, CollectorDrainTimeout, MarkerDeletionWhileLive, MarkerDeletionFailure
- Each fault fixture records expected/actual in structured evidence
- Process/marker/handle/task leak verification: no new PowerShell PIDs, no new marker directories

## Non-action Checklist

- [x] No npm install / Harness / HTTP/WS / port operations
- [x] No real credentials or API keys
- [x] No process-name-wide kill (all kills are handle-based or token-verified)
- [x] PR remains OPEN + Draft, base=master, merged=null
- [x] No merge, no Ready, no master modification
- [x] No Phase B / G0-S2 entry
- [x] No Full PoC / Harness run
