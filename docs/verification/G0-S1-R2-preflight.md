# G0-S1 R13 Follow-up Round 3 Preflight Report

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
| R13-FU2 code | `a0d40a857347438ace7c7a227c98d44909e386c0` | `b1ab9af745fdb3194986bbd9811535f48c65d0a8` (R14 docs) | `fix(harness): R13 FU2 - bounded wait in TerminateAndVerify failure branch + Success in finally` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R13-FU3 code | `40e97d43fab3e113116fbbbad242cf00208c808a` | `a0d40a857347438ace7c7a227c98d44909e386c0` (R13-FU2 code) | `R13-FU3: fail-closed helper, frozen identity, structured CleanupIdentityMismatch` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

Parent chain: R11 docs → R12 code → R12 docs (corrected) → R13 code → R13 docs → R14 code → R14 docs → R13-FU2 code → R13-FU3 code (this cycle's code commit)

---

## File Hashes

### Script: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

The R13-FU3 docs-only commit does not change the script. Final script hashes are in the code commit above.

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
| Start | 2026-09-01 17:59:42.661 |
| End | 2026-09-01 18:00:25.384 |
| Elapsed | 42.72s |
| Exit code | **0** |
| Total tests | **215** |
| Passed | **215/215** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |
| Stdout | 25701 bytes |
| Stderr | 0 bytes |
| Script SHA-256 (checkout) | `4B55C07C2EC69275499112BE7CEF958C19E08B1687B3139594FBD3A01F180ED3` |

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
| Start | 2026-09-01 18:00:56.478 |
| End | 2026-09-01 18:02:12.209 |
| Elapsed | 75.73s |
| Exit code | **0** |
| Total tests | **215** |
| Passed | **215/215** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |
| Stdout | 25700 bytes |
| Stderr | 0 bytes |
| Script SHA-256 (checkout) | `4B55C07C2EC69275499112BE7CEF958C19E08B1687B3139594FBD3A01F180ED3` |

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

### Run 1 Settling

| Check | Pre-Run1 | Post-Run1 |
|-------|----------|-----------|
| New PIDs after settle | — | **0** |
| New marker dirs after settle | — | **0** |
| Held-handle delta | 0 | 0 |
| Unfinished collector tasks | 0 | 0 |

### Run 2 Settling

| Check | Pre-Run2 | Post-Run2 |
|-------|----------|-----------|
| New PIDs after settle | — | **0** |
| New marker dirs after settle | — | **0** |
| Held-handle delta | 0 | 0 |
| Unfinished collector tasks | 0 | 0 |

Zero resource leaks across both runs.

---

## R13 FU3 Changes and Fixes

### FU3-01: CleanupIdentityMismatch — Evidence Before Cleanup, Record After

**Problem:** The `CleanupIdentityMismatch` fixture created its test record inside the `try` block, before the outer cleanup ran. If the outer cleanup failed, the test record would already be stamped PASS, masking the cleanup failure.

**Fix:** Evidence collection variables (`$mismatchResult`, `$mismatchNoTerm`, `$mismatchIdentityMismatch`, `$mismatchOwnedStillAlive`, `$mismatchException`) are assigned in the `try` block. The test record is created in the `finally` block, AFTER both outer cleanups (`$ownedCleanupResult`, `$otherCleanupResult`) complete. Pass requires ALL of:

- `$handlesPreAcquired` (all three registries registered)
- `$mismatchNoTerm` (helper did not terminate the owned process)
- `$mismatchIdentityMismatch` (identity verified but not matched)
- `$mismatchOwnedStillAlive` (owned process still alive via cleanup handle)
- `$targetCloseAllOk` (target registry CloseAll succeeded)
- `$ownedOuterOk` (owned cleanup via shared helper: Success + Exited + CloseAll)
- `$otherOuterOk` (other cleanup via shared helper: Success + Exited + CloseAll)
- `$noException` (no exception in try block)
- `$noCleanupError` (both cleanup results have zero errors)

**Outer cleanup mechanism:** Both `$ownedCleanupResult` and `$otherCleanupResult` use `Stop-Wait-VerifyOwnedProcess` with frozen creation time, replacing the prior ad-hoc `TerminateAndVerify` + `CloseAll` sequences.

### FU3-02: Fail-Closed Success in `Stop-Wait-VerifyOwnedProcess`

**Problem:** FU2's Success computation (`IdentityMatched AND ExitedVerified AND CloseAllSucceeded`) did not verify registration succeeded, entry count matched, or that errors were empty. A helper could return `Success=True` with registration failures or accumulated errors.

**Fix:** Success now requires ALL mandatory invariants:

```powershell
$result.Success = $result.RegistrationSucceeded -and
    ($result.EntryCount -eq $result.ExpectedEntryCount) -and
    $result.IdentityVerified -and
    $result.IdentityMatched -and
    $result.ExitedVerified -and
    $result.CloseAttempted -and
    $result.CloseAllSucceeded -and
    ($result.CloseFailedCount -eq 0) -and
    ($result.Errors.Count -eq 0)
```

### FU3-03: Frozen Identity Before Hook Injection

**Problem:** Several fixtures accessed `$proc.StartTime.Ticks` in the `finally` block for cleanup, but the process might have exited by then, making `StartTime` unreliable or throwing. The `WaitFailure` fixture used `$waitCreationTime` for both the frozen .NET ticks and the registry FILETIME, overwriting the frozen value.

**Fix:** Creation time is frozen into a local variable immediately after `Start-Process`, before any hook injection or registry registration:

| Fixture | Frozen Variable | Used In |
|---------|----------------|---------|
| GetProcessTimesFailure | `$gptCreationTime` | Cleanup via `$gptCleanupResult` |
| WaitFailure | `$waitCreationTime` | Cleanup via `$waitCleanupResult`; separate `$waitRegCreationTime` for registry FILETIME |
| CloseHandleFailure | `$closeCreationTime` | Cleanup via `$closeCleanupResult` |
| CleanupRegistrationFailure | `$crgCreationTime` | Backup cleanup via `$crgBackupResult` |
| CleanupIdentityMismatch | `$ownedCreationTime`, `$otherCreationTime` | Both outer cleanups |

**WaitFailure specific:** Uses separate variables — `$waitCreationTime` (frozen before hook, used for cleanup) and `$waitRegCreationTime` (from `$waitReg.CreationTime`, used for semantic validation). The frozen value is never overwritten.

### FU3-04: New Diagnostic Fields

`Stop-Wait-VerifyOwnedProcess` now exposes additional structured fields:

| Field | Type | Source |
|-------|------|--------|
| `TerminateWin32Error` | int | `$twr.TerminateWin32Error` |
| `TerminateError` | string | `$twr.TerminateError` (empty if null) |
| `FinalWaitCode` | uint32 | `$twr.Wait.WaitCode` |
| `FinalWaitWin32Error` | int | `$twr.Wait.Win32Error` |
| `ExpectedEntryCount` | int | Parameter (default 1) |

---

## CleanupIdentityMismatch Full Evidence

**Actual line from both runs:**
```
targetReg=True ownedCleanupReg=True otherCleanupReg=True idVerified=True idMatched=False noTerm=True targetCloseAll=True alive=True ownedExited=True ownedClose=True otherExited=True otherClose=True noException=True noCleanupError=True
```

**Interpretation:**
- All three handle registries registered successfully
- Identity verified but did not match (expected behavior for mismatch test)
- Helper did NOT terminate the owned process (correct)
- Target registry CloseAll succeeded (target handle consumed by helper)
- Owned process still alive after helper returned (verified via cleanup handle)
- Owned outer cleanup: Exited=True, CloseAll=True (via shared helper)
- Other outer cleanup: Exited=True, CloseAll=True (via shared helper)
- No exceptions in try block
- Zero errors in both cleanup results

---

## Focused Negative Evidence

The following focused negative checks were verified during development (not counted as full-run evidence — the interrupted bash/tee attempt was not counted as a test run):

| Check | Mechanism | Result |
|-------|-----------|--------|
| Extra registry entry → helper Success false | Register 2 entries, ExpectedEntryCount=1 | `Success=False`, `EntryCount=2` |
| Nonempty Errors → helper Success false | Inject error into Errors array | `Success=False`, `Errors.Count>0` |
| CloseAll failure → helper Success false | Mock CloseAll to fail | `Success=False`, `CloseAllSucceeded=False` |
| Diagnostic fields exposed | Inspect TerminateWin32Error, FinalWaitCode, etc. | All fields populated |

---

## Interrupted Bash/Tee Attempt

The previous session attempted to run tests via bash `tee` pipelines. That attempt was interrupted by shell escaping issues and was NOT counted as a test run. All run evidence in this report comes from the two PowerShell-only runs executed in this session.

---

## Untracked Diagnostic File Removal

The five diagnostic artifacts from prior runs were confirmed untracked, inspected, and removed:

| File | Size | Date | Removal |
|------|------|------|---------|
| `run-stderr.txt` | 0 bytes | 2026-08-31 11:11 | `Remove-Item -LiteralPath` |
| `run1-output.txt` | 25285 bytes | 2026-08-31 16:14 | `Remove-Item -LiteralPath` |
| `run1-stderr.txt` | 0 bytes | 2026-09-01 12:03 | `Remove-Item -LiteralPath` |
| `run2-output.txt` | 25287 bytes | 2026-08-31 16:16 | `Remove-Item -LiteralPath` |
| `run2-stderr.txt` | 0 bytes | 2026-08-31 17:59 | `Remove-Item -LiteralPath` |

Post-removal `git status --short`: two additional untracked test helper scripts (`test-fu3-negatives.ps1`, `test-waitfailure-debug.ps1`) remain — these are development artifacts, not diagnostic run outputs, and were not deleted per the instruction "do not delete any other untracked/user file."

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
- Interrupted bash/tee attempt not counted as a run

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

## R13-FU3 Delta Summary

| FU | Description | Status |
|----|-------------|--------|
| FU-01 | Handle-based `Stop-Wait-VerifyOwnedProcess`; pre-acquired cleanup handles for all 5 fixtures; no `Stop-Process -Id` in cleanup paths | DONE (R14) |
| FU-02 | Identity/handle evidence captured before fault injection via pre-registration | DONE (R14) |
| FU-03 | Non-self-referential preflight hash strategy; stale R13 self-hash corrected | DONE (R14) |
| FU-04 | Safety property assertions: handle pre-acquisition, held-handle alive check, no PID-only termination | DONE (R14) |
| FU2-01 | Bounded `WaitForSingleObject` in `TerminateAndVerify` failure branch (zero-duration → bounded `waitMs`) | DONE (R13-FU2) |
| FU2-02 | `Success` computation moved into `finally` block in `Stop-Wait-VerifyOwnedProcess` | DONE (R13-FU2) |
| FU2-03 | `CleanupRegistrationFailure` fixture added (34th PLF fixture) | DONE (R14/FU2) |
| FU3-01 | CleanupIdentityMismatch: evidence in try, record in finally after outer cleanup via shared helper | DONE (R13-FU3) |
| FU3-02 | Fail-closed Success: all 9 mandatory invariants in `Stop-Wait-VerifyOwnedProcess` | DONE (R13-FU3) |
| FU3-03 | Frozen creation identity before hook injection for GetProcessTimes/Wait/CloseHandle/CleanupRegistration; WaitFailure separate .NET/FILETIME variables | DONE (R13-FU3) |
| FU3-04 | New diagnostic fields: TerminateWin32Error, TerminateError, FinalWaitCode, FinalWaitWin32Error, ExpectedEntryCount | DONE (R13-FU3) |
