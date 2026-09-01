# G0-S1 R13 Follow-up Round 2 Preflight Report

**Date:** 2026-09-01
**Branch:** research/g0-s1-windows-poc
**PR:** #1 (OPEN, Draft, base master, merged=null)
**Script:** `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`
**Preflight:** `docs/verification/G0-S1-R2-preflight.md`

---

## Commit Topology

| Commit | Full Hash | Parent | Subject | Files |
|--------|-----------|--------|---------|-------|
| R12 code | `d5ba1f6a68a3aeaafc17ed0be5832259ed442fa7` | `32382427c6453187cf858506431d2b6ec069d0e9` (R11 docs) | `test: R12 remediation - ExpectedManifest gate integration, real marker deletion, mandatory evidence checks, shared collector exit mapper, Stop-Wait-VerifyOwnedProcess, manifest mismatch meta-tests` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R12 docs (corrected) | `fba863b08e95cff0a4ce1cc7b8e03c575e400776` | `d5ba1f6a68a3aeaafc17ed0be5832259ed442fa7` (R12 code) | `docs: R12 preflight report - 31 PLF fixtures, 212/212 PASS, frozen ExpectedManifest lifecycle` | `docs/verification/G0-S1-R2-preflight.md` |
| R13 code | `0d631ebca398c6edccf4eb06d9333703c6fd17af` | `fba863b08e95cff0a4ce1cc7b8e03c575e400776` (R12 docs) | `test: R13 remediation - Get-OverallExitResult shared mapper, PID-reuse-safe Stop-Wait-VerifyOwnedProcess, CleanupIdentityMatch/Mismatch fixtures, fail-closed banner/totals permissions` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R13 docs | `9393f343b6cf5322f5d9a102901c5863397dec6a` | `0d631ebca398c6edccf4eb06d9333703c6fd17af` (R13 code) | `docs: R13 preflight report - shared exit mapper, PID-reuse-safe cleanup, 33 PLF, 214/214 PASS` | `docs/verification/G0-S1-R2-preflight.md` |
| R14 code | `b4a4fcd83ccd7c51f624b5a66e6b33a17653416e` | `9393f343b6cf5322f5d9a102901c5863397dec6a` (R13 docs) | `test: R14 follow-up - handle-based Stop-Wait-VerifyOwnedProcess, pre-acquired cleanup handles for all native API and cleanup identity fixtures` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R14 docs | `b1ab9af745fdb3194986bbd9811535f48c65d0a8` | R14 code | `docs: R14 follow-up preflight - handle-based cleanup, non-self-referential hashes` | `docs/verification/G0-S1-R2-preflight.md` |
| R13-FU2 code | *(this commit)* | `b1ab9af745fdb3194986bbd9811535f48c65d0a8` (R14 docs) | `fix(harness): R13 FU2 - bounded wait in TerminateAndVerify failure branch + Success in finally` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

Parent chain: R11 docs → R12 code → R12 docs (corrected) → R13 code → R13 docs → R14 code → R14 docs → R13-FU2 code (this cycle's code commit)

---

## File Hashes

### Script: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

The R13-FU2 docs-only commit does not change the script. Final script hashes are in the code commit above.

**Strategy:** Final docs commit/blob/raw-hash/checkout-hash are recorded in the external post-push publication report, NOT in this document (non-self-referential strategy per R13-FU-03).

**Reproducible post-commit verification commands:**
```bash
# Code commit hash
git log --oneline -1 -- research/g0-s1-harness-integration/windows-poc-test-r2.ps1

# Script blob object ID
git ls-tree HEAD -- research/g0-s1-harness-integration/windows-poc-test-r2.ps1

# Raw Git-blob SHA-256
git cat-file blob <BLOB_ID> | sha256sum

# Checkout SHA-256
sha256sum research/g0-s1-harness-integration/windows-poc-test-r2.ps1
```

---

## Static Analysis

| Tool | Version | Result |
|------|---------|--------|
| PowerShell Parser | (built-in) | **0 errors** |
| PSScriptAnalyzer Severity Error | **v1.25.0** | **0 findings** |

---

## Fixture Inventory

Total: **34** fixtures (runtime-derived `ProcessLevelFaults` fixture count)

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
| cleanupIdentity | 2 | CleanupIdentityMatch, CleanupIdentityMismatch |
| cleanupRegistration | 1 | CleanupRegistrationFailure |

**Formula:** 6+1+4+2+1+2+2+2+3+8+2+1 = **34**

---

## R15 Helper Total

```
ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) = 59
```

Full total: 54 (pure) + 102 (node) + 59 (R15) = **215**

---

## Two Consecutive Final Runs

### Run 1

| Field | Value |
|-------|-------|
| Exit code | **0** |
| Total tests | **215** |
| Passed | **215/215** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |

Suite table:
```
Pure-function tests: Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = 54
Node-backed tests: LockfileReader(102)
R15 helper tests: ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) = 59
Node resolution: C:\nvm4w\nodejs\node.exe
Total: 215 tests, 215/215 PASS, 0 FAILED
```

### Run 2

| Field | Value |
|-------|-------|
| Exit code | **0** |
| Total tests | **215** |
| Passed | **215/215** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |

Suite table:
```
Pure-function tests: Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = 54
Node-backed tests: LockfileReader(102)
R15 helper tests: ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) = 59
Node resolution: C:\nvm4w\nodejs\node.exe
Total: 215 tests, 215/215 PASS, 0 FAILED
```

---

## 5-Second Settling Hygiene

| Check | Pre-Run2 | Post-Run2 |
|-------|----------|-----------|
| PowerShell processes | 2 | 2 |
| Marker directories | 0 | 0 |
| Marker files | 0 | 0 |
| Held-handle delta | 0 | 0 |
| Unfinished collector tasks | 0 | 0 |

Zero resource leaks across both runs.

---

## R13 FU2 Root Cause Analysis and Fixes

### Fix 1: Bounded Wait in `TerminateAndVerify` Failure Branch (WaitFailure)

**Root cause:** C# `ProcessHandleRegistry.TerminateAndVerify` (line 536) used `WaitForSingleObject(entry.Handle, 0)` — a zero-duration probe — in the failure branch when `TerminateProcess` returns false. When another handle had already called `TerminateProcess` on the same process (e.g., during `Invoke-HandleCleanup` with a wait hook active), the process was in a transient "terminating" state. The zero-duration probe returned `WAIT_TIMEOUT`, causing the cleanup to incorrectly report failure.

**Diagnostic evidence (pre-fix):**
```
[WaitFailure-DEBUG-Pre] cleanupReg.Count=1 ws.Exited=False ws.Outcome=Timeout ws.WaitCode=258
[WaitFailure-DEBUG-Pre] proc alive=True
IdentityMatched=True ExitedVerified=False TerminateAttempted=True TerminateSucceeded=False FinalWaitOutcome=Timeout
```

Process was alive but already terminating (first TerminateProcess succeeded via fixtureRegistry, but wait was injected as WAIT_FAILED). Second TerminateProcess on cleanup handle returned false. Zero-duration wait got WAIT_TIMEOUT (258).

**Fix:** Changed `WaitForSingleObject(entry.Handle, 0)` to `WaitForSingleObject(entry.Handle, (uint)waitMs)` — bounded wait gives the already-terminating process time to fully exit.

**Post-fix behavior:**
- `TerminateProcess` returns false (preserving `TerminateWin32Error`)
- Bounded `WaitForSingleObject(handle, 3000)` reaches `WAIT_OBJECT_0`
- `WaitOutcome = Exited`, `entry.Exited = true`, `Terminated = false`
- Cleanup succeeds: exit was independently verified even though this call did not initiate termination
- `WAIT_TIMEOUT` on bounded wait remains a structured failure
- `WAIT_FAILED` (injected by hook) remains a structured failure with deterministic error code

### Fix 2: Success Computed in `finally` Block (CloseHandleFailure)

**Root cause:** `Stop-Wait-VerifyOwnedProcess` computed `$result.Success` AFTER the try/catch/finally block (line 2701). When `CheckWaitStatus` showed the process already exited, the code returned from inside the `try` block (line 2661). The `finally` block ran `CloseAll()` successfully, but the `Success` computation line never executed — `Success` stayed at its initial `$false`.

**Diagnostic evidence (pre-fix):**
```
[CloseHandleFailure-DEBUG-Pre] cleanupReg.Count=1 ws.Exited=True ws.Outcome=Exited ws.WaitCode=0
IdentityMatched=True ExitedVerified=True CloseAllSucceeded=True Success=False
```

All three Success inputs were True, yet Success was False because the computation line was unreachable.

**Fix:** Moved `$result.Success = $result.IdentityMatched -and $result.ExitedVerified -and $result.CloseAllSucceeded` into the `finally` block, after `CloseAll()` completes. The `finally` block executes on every path (early returns, exceptions, normal completion), ensuring `Success` is always computed.

### Corrected Cleanup Semantics

`Stop-Wait-VerifyOwnedProcess` now returns correct `Success` on all paths:

| Path | IdentityMatched | ExitedVerified | CloseAllSucceeded | Success |
|------|----------------|----------------|-------------------|---------|
| Already exited (early return) | ✓ (checked before) | ✓ (CheckWaitStatus) | ✓ (finally) | **True** |
| TerminateProcess succeeds, wait confirms exit | ✓ | ✓ | ✓ | **True** |
| TerminateProcess fails, bounded wait confirms exit | ✓ | ✓ (exit independently verified) | ✓ | **True** |
| TerminateProcess fails, bounded wait times out | ✓ | ✗ | ✓ | **False** |
| Identity mismatch (early return) | ✗ | — | ✓ | **False** |
| Registration validation fails | — | — | ✓ | **False** |

---

## CleanupRegistrationFailure Evidence

**Fixture:** `CleanupRegistrationFailure`

| Field | Value |
|-------|-------|
| Test result | PASS |
| Registration failed | True |
| Has error | True |
| No entries | True |
| Backup registry ok | True |
| Backup cleanup success | True |
| Backup exited | True |
| Backup close | True |

**Mechanism:** Validates that when `RegisterProcess` fails (e.g., `GetProcessTimes` failure), the cleanup path correctly handles the failure without crashing, and a backup registry can still clean up the process.

---

## Suite-Evidence: Shared Mapper Fail-Closed Verification

The `Get-OverallExitResult` function is the single source of truth for exit codes and banner/totals permissions.

| Test | Overall | ExitCode | SuccessBannerPrinted | TrustedTotalsPrinted | Gate |
|------|---------|----------|---------------------|---------------------|------|
| T1: missing suite | ERROR | 3 | False | False | ✓ |
| T2: declared!=actual | ERROR | 3 | False | False | ✓ |
| T3: passed!=actual | ERROR | 3 | False | False | ✓ |
| T4: failed>0 | ERROR | 3 | False | False | ✓ |
| T5: manifest mismatch | ERROR | 3 | False | False | ✓ |
| T6: missing field | ERROR | 3 | False | False | ✓ |
| T7: string value | ERROR | 3 | False | False | ✓ |
| T8: float value | ERROR | 3 | False | False | ✓ |
| T9: negative value | ERROR | 3 | False | False | ✓ |
| T10: overflow value | ERROR | 3 | False | False | ✓ |
| T11: passed+failed!=actual | ERROR | 3 | False | False | ✓ |

---

## Non-Actions

- Phase B not entered (blocked per gate)
- No merge performed
- PR not marked Ready
- `master` not modified
- No dependencies installed
- No credentials accessed
- No process-name-wide kills performed
- No PID-only cleanup in scoped paths

---

## PR Status

| Field | Value |
|-------|-------|
| Number | #1 |
| State | OPEN |
| Draft | true |
| Base | master |
| Head | research/g0-s1-windows-poc |
| Merged | null |

---

## R13-FU2 Delta Summary

| FU | Description | Status |
|----|-------------|--------|
| FU-01 | Handle-based `Stop-Wait-VerifyOwnedProcess`; pre-acquired cleanup handles for all 5 fixtures; no `Stop-Process -Id` in cleanup paths | DONE (R14) |
| FU-02 | Identity/handle evidence captured before fault injection via pre-registration | DONE (R14) |
| FU-03 | Non-self-referential preflight hash strategy; stale R13 self-hash corrected | DONE (R14) |
| FU-04 | Safety property assertions: handle pre-acquisition, held-handle alive check, no PID-only termination | DONE (R14) |
| FU2-01 | Bounded `WaitForSingleObject` in `TerminateAndVerify` failure branch (zero-duration → bounded `waitMs`) | DONE (R13-FU2) |
| FU2-02 | `Success` computation moved into `finally` block in `Stop-Wait-VerifyOwnedProcess` | DONE (R13-FU2) |
| FU2-03 | `CleanupRegistrationFailure` fixture added (34th PLF fixture) | DONE (R14/FU2) |
