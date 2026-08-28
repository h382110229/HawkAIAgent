# G0-S1 R6 Preflight Report

**Date**: 2026-08-28
**Script**: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

## Code Commit

| Field | Value |
|---|---|
| Hash | `d30ecbea894f2e1919dadb5971b6951c9b5d3dc4` |
| Parent | `66476f791b77b8346fa63c595900de55f5e2524f` |
| Subject | `test: R6 remediation — bounded async dual-stream collector, Job Object, descendant timeout, fail-closed cleanup` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob | `200285bcc26cad4af650e9505932f69fc3adc7b3` |
| SHA-256 | `13c2d34e53b93bf42de4411c0ab5a9b0fd1a782971b07f1fc23652e7465f1d1a` |

SHA-256 computed on raw git blob bytes (`git cat-file -p <blob> | sha256sum`), not on CRLF-converted working-tree content.

## Static Analysis

| Tool | Result |
|---|---|
| PowerShell Parser | **0 errors** |
| PSScriptAnalyzer Severity Error | **0** (tool available and invoked) |

## Test Runs

Two consecutive `-SelfTestOnly` runs on the exact code commit:

| Run | Start (CST) | Exit | Tests | PASS | FAIL | stderr |
|---|---|---|---|---|---|---|
| Run 1 | 2026-08-28 ~09:22 | 0 | 194 | 194 | 0 | empty |
| Run 2 | 2026-08-28 ~09:24 | 0 | 194 | 194 | 0 | empty |

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
| ProcessLevelFaults | 13 | 13 | 13 | 0 |
| **Total** | **194** | **194** | **194** | **0** |

## R6 Remediation Evidence

### R6-REM-01: Bounded Dual-Stream Collector

- **Implementation**: Inline C# `BoundedStreamCollector` class using `BaseStream.ReadAsync` on both stdout/stderr concurrently. Fixed 51200-byte retained buffer per stream. Overflow bytes drained/discarded. `Int64` total byte counter.
- **ReadToEndAsync removed**: No `ReadToEndAsync()` or `rawStdout`/`rawStderr` strings remain in the capture path.
- **Deadlock prevention**: Async `Task.WhenAll` on both streams with `CancellationTokenSource` and bounded drain deadline.
- **Byte-level capture**: `capturedBytes` = actual retained bytes from `Buffer.BlockCopy`; `totalBytes` = sum of `ReadAsync` return values. Text decoded from retained bytes only (`UTF8.GetString`), not from full output.
- **Truncation**: `$collector.StdoutTruncated` = true iff `totalBytes > 51200` (same byte-level metric).

Fixture evidence (R6 run):

| Fixture | stdout total | captured | truncated | stderr total | captured | truncated |
|---|---|---|---|---|---|---|
| StdoutOversize | 61500 | 51200 | True | 0 | 0 | False |
| StderrOversize | 0 | 0 | False | 61500 | 51200 | True |
| DualStreamOversize | 61500 | 51200 | True | 61500 | 51200 | True |
| LongLine | 61441 | 51200 | True | 0 | 0 | False |
| BoundaryExact | 51200 | 51200 | False | 0 | 0 | False |
| BoundaryOver | 51201 | 51200 | True | 0 | 0 | False |

All: `captured ≤ 51200`, `captured ≤ total`, `truncated ⟺ total > 51200`. Buffer capacity = 51200 bytes retained max per stream.

### R6-REM-02: Timeout with Descendant

- **Timeout child**: Creates real descendant via `Start-Process powershell` with token+role in command line and marker file (`token|pid|timeout-descendant`).
- **Parent verification**: Marker files checked inside try block (before finally deletes them). `$descendantObserved` = marker file exists with matching token.
- **Assertion fields**: `descendantObserved`, `parentExited`, `descendantExited`, `treeCleanupSucceeded`, `orphanFree` — all required, any missing = FAIL.

Fixture evidence:

| Field | Value |
|---|---|
| Exit | -1 |
| timedOut | True |
| descendantObserved | True |
| parentExited | True |
| descendantExited | True |
| treeCleanupSucceeded | True |
| orphanFree | True |

### R6-REM-03: CIM Fail-Closed + Job Object

- **Job Object**: `CreateKillOnCloseJob()` with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Active process count via `JOBOBJECT_BASIC_ACCOUNTING_INFORMATION`.
- **Job assignment**: `AssignProcess()` via `OpenProcess(PROCESS_SET_QUOTA|PROCESS_TERMINATE)` + `AssignProcessToJobObject`. **Note**: Assignment fails on this environment (child processes already in parent's Job — Windows single-Job limitation). Tests pass via CIM fallback.
- **Test-NoOrphans**: Returns three-state object `{Status, Detail, JobVerified}`:
  - `VerifiedClean`: Job=0 or (Job=unavailable AND CIM=0 matching)
  - `OrphansFound`: Job>0 or CIM>0 matching
  - `VerificationError`: Job query failed AND CIM=null/Access Denied
- **CIM Access Denied**: Returns `VerificationError`, NOT `VerifiedClean`. When Job confirms clean, CIM failure is tolerated (Job is authoritative).
- **Kill-TestProcessTree**: CIM sweep notes null result as error. CIM-only path used when Job unavailable.

### R6-REM-04: Emergency Cleanup Identity Verification

- **Job-first**: `Invoke-EmergencyCleanup` checks Job active count, calls `TerminateAll` if >0.
- **PID fallback**: Reads 3-field marker (`token|pid|role`), verifies CIM CommandLine contains both token AND role before kill.
- **Identity unconfirmed**: Does NOT kill, records error.
- **No silent failures**: All errors collected in `$cleanupErrors` array, returned as `$ecResult.Errors`.

### R6-REM-05: CleanupFailure State Matrix

PASS predicate requires ALL of:
- `$cleanupFailureInjected` (fixture type = CleanupFailure)
- `$primaryCleanupFailed` (descendant was alive when checked)
- `$failureReported` (emergency cleanup was invoked due to live descendant)
- `$emergencyCleanupDone` (emergency cleanup succeeded)
- `$parentExited` (fault child exited with code 3)
- `$descendantExited` (descendant dead after emergency cleanup, verified via re-check)
- `$descendantObserved` (marker file existed with matching token)
- `$verifiedClean` (post-cleanup orphan check = VerifiedClean)

Missing any = FAIL. Evidence:

| Field | Value |
|---|---|
| Exit | 3 |
| cleanupFailureInjected | True |
| primaryCleanupFailed | True |
| failureReported | True |
| emergencyCleanupDone | True |
| parentExited | True |
| descendantExited | True |
| descendantObserved | True |
| verifiedClean | True |
| orphanFree | True |

### R6-REM-06: Marker Directory Cleanup

- **Unique path**: `plf-markers-PLF-<GUID>` per invocation.
- **Verified deletion**: `Remove-Item -ErrorAction Stop` followed by `Test-Path` re-check. Failure → `$allPassed = $false` + `$script:CleanupErrors`.
- **Job handle closed**: `CloseHandle()` after `GetActiveProcessCount` check.

Post-run evidence:
- **R5 orphan** (pre-existing): `plf-markers-PLF-467a11a98f9644758b39f4105dd049f7` (Aug 27) — NOT deleted per R6-REM-06 ("不要删除或归因其他历史 plf-* 路径"). This is the R5 bug that R6 fixes.
- **R6 run 1**: No new orphan directories.
- **R6 run 2**: No new orphan directories.

### Known Limitation: Job Object Assignment

On this environment, `AssignProcessToJobObject` fails for all child processes. Root cause: Windows allows a process to be in only one Job Object at a time. The child PowerShell processes inherit Job membership from the parent process and cannot be reassigned to the test's Job Object.

Impact: Job Object is used as supplementary verification only. CIM-based cleanup and orphan detection serve as the primary mechanism. The three-state `Test-NoOrphans` correctly handles Job unavailability by falling back to CIM with proper error semantics.

## Non-action Checklist

- [x] No npm install / Harness / HTTP/WS / port operations
- [x] No real credentials or API keys
- [x] No process-name-wide kill (all kills are token+role-verified or PID-specific)
- [x] PR remains OPEN + Draft, base=master, merged=null
- [x] No merge, no Ready, no master modification
- [x] No Phase B / G0-S2 entry
- [x] No Full PoC / Harness run
