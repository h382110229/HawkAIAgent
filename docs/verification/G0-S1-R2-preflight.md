# G0-S1 R7 Preflight Report

**Date**: 2026-08-28
**Script**: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

## Code Commit

| Field | Value |
|---|---|
| Hash | `0f67b81` |
| Parent | `8256961a05728d55a0573b75260454b0e020f3b5` |
| Subject | `test: R7 remediation — handle-based process registry, fail-closed collector, marker-after-verification` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob | `7c9c90bf0d970ffdb09a23ef096133c0ea4a22e3` |
| SHA-256 | `66c59e8463919818e9cca25cd9ae2d53e790056643c9c0caebec4ff54cf5a769` |

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
| Run 1 | 0 | 195 | 195 | 0 | empty |
| Run 2 | 0 | 195 | 195 | 0 | empty |

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
| ProcessLevelFaults | 14 | 14 | 14 | 0 |
| **Total** | **195** | **195** | **195** | **0** |

## R7 Remediation Evidence

### R7-REM-01: Job Assignment Tracked, Handle Registry Primary

- `$assignedToJob` tracked per-fixture (not just WARNING)
- Empty Job (assignment failed) NOT treated as authoritative clean
- `Test-HandleOrphans` uses handle `ActiveCount` as primary; Job only when `$assignedToJob=$true`
- `JobAssignFailure` fixture (14th) proves structural faults work with handle-based cleanup

### R7-REM-02: ProcessHandleRegistry (C# Inline)

- `OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION|PROCESS_TERMINATE)` — no admin required
- `GetProcessTimes` for creation time (PID-reuse safe)
- `WaitForSingleObject` for exit detection (non-blocking)
- `TerminateProcessByIndex` via held handle (PID-reuse safe)
- `CloseAll()` in finally block

### R7-REM-03: Handle-Based Orphan Verification

- `Test-HandleOrphans` returns `VerifiedClean`/`OrphansFound`
- Primary: `$handleRegistry.ActiveCount == 0`
- Supplementary: Job Object only when `$assignedToJob=$true`
- CIM removed from critical path

### R7-REM-04: Timeout/CleanupFailure Full State Matrix

**Timeout fixture evidence:**

| Field | Value |
|---|---|
| descendantObserved | True |
| parentExited | True |
| descendantExited | True |
| treeCleanup | True |
| orphanFree | True |
| captureHealthy | True |
| verificationSource | Handles |

**CleanupFailure fixture evidence:**

| Field | Value |
|---|---|
| cleanupFailureInjected | True |
| primaryCleanupFailed | True |
| failureReported | True |
| emergencyCleanupDone | True |
| parentExited | True |
| descendantExited | True |
| descendantObserved | True |
| verifiedClean | True |
| captureHealthy | True |
| verificationSource | Handles |

### R7-REM-05: Marker Lifecycle After Handle Verification

- Markers preserved during fixture processing
- `handleRegistry.CloseAll()` called before marker deletion
- `Remove-Item -ErrorAction Stop` + `Test-Path` re-check
- R5/R6 historical orphan directory preserved (not deleted per policy)

### R7-REM-06: Collector Fail-Closed

- `catch { break; }` → `catch (Exception ex) { r.ReadError = ex.Message; break; }`
- `Healthy` property: `!StdoutFaulted && !StderrFaulted && !DrainTimedOut`
- `$collectTask.Wait()` return value checked
- `captureHealthy` in ALL fixture PASS predicates
- Task fault status (`IsFaulted`) checked before accessing results

### Post-Run Evidence

- No orphan PowerShell descendants from this run
- R5/R6 historical marker directory preserved (empty, not deleted)
- R7 marker directory: empty (files deleted, directory persists — acceptable)

## Non-action Checklist

- [x] No npm install / Harness / HTTP/WS / port operations
- [x] No real credentials or API keys
- [x] No process-name-wide kill (all kills are handle-based or token-verified)
- [x] PR remains OPEN + Draft, base=master, merged=null
- [x] No merge, no Ready, no master modification
- [x] No Phase B / G0-S2 entry
- [x] No Full PoC / Harness run
