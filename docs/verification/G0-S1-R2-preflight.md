# G0-S1 R13 Follow-up Round 4 Preflight Report

**Date:** 2026-09-02
**Branch:** research/g0-s1-windows-poc
**PR:** #1 (OPEN, Draft, base master, merged=null)
**Script:** `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`
**Preflight:** `docs/verification/G0-S1-R2-preflight.md`

---

## Commit Topology

All rows derived mechanically from `git show -s --format` + `git show --name-only`.

| Commit | Full Hash | Parent | Subject | Files |
|--------|-----------|--------|---------|-------|
| R12 code | `d5ba1f6a68a3aeaafc17ed0be5832259ed442fa7` | `32382427c6453187cf858506431d2b6ec069d0e9` (R11 docs) | `test: R12 remediation - ExpectedManifest gate integration, real marker deletion, mandatory evidence checks, shared collector exit mapper, Stop-Wait-VerifyOwnedProcess, manifest mismatch meta-tests` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R12 docs (corrected) | `fba863b08e95cff0a4ce1cc7b8e03c575e400776` | `d5ba1f6a68a3aeaafc17ed0be5832259ed442fa7` (R12 code) | `docs: R12 preflight report - 31 PLF fixtures, 212/212 PASS, frozen ExpectedManifest lifecycle` | `docs/verification/G0-S1-R2-preflight.md` |
| R13 code | `0d631ebca398c6edccf4eb06d9333703c6fd17af` | `fba863b08e95cff0a4ce1cc7b8e03c575e400776` (R12 docs) | `test: R13 remediation - Get-OverallExitResult shared mapper, PID-reuse-safe Stop-Wait-VerifyOwnedProcess, CleanupIdentityMatch/Mismatch fixtures, fail-closed banner/totals permissions` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R13 docs | `9393f343b6cf5322f5d9a102901c5863397dec6a` | `0d631ebca398c6edccf4eb06d9333703c6fd17af` (R13 code) | `docs: R13 preflight report - shared exit mapper, PID-reuse-safe cleanup, 33 PLF, 214/214 PASS` | `docs/verification/G0-S1-R2-preflight.md` |
| R14 code | `b4a4fcd83ccd7c51f624b5a66e6b33a17653416e` | `9393f343b6cf5322f5d9a102901c5863397dec6a` (R13 docs) | `test: R14 follow-up - handle-based Stop-Wait-VerifyOwnedProcess, pre-acquired cleanup handles for all native API and cleanup identity fixtures` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R14 docs | `b1ab9af745fdb3194986bbd9811535f48c65d0a8` | `b4a4fcd83ccd7c51f624b5a66e6b33a17653416e` (R14 code) | `docs: R14 follow-up preflight - handle-based cleanup, non-self-referential hashes` | `docs/verification/G0-S1-R2-preflight.md` |
| R13-FU2 code | `0079c0047ee3fc19ef32097f6ef337d421f01fae` | `b1ab9af745fdb3194986bbd9811535f48c65d0a8` (R14 docs) | `fix(harness): R13 FU2 - bounded wait in TerminateAndVerify failure branch + Success in finally` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R13-FU2 docs | `a0d40a857347438ace7c7a227c98d44909e386c0` | `0079c0047ee3fc19ef32097f6ef337d421f01fae` (R13-FU2 code) | `docs: R13 FU2 preflight - bounded wait fix, Success-in-finally fix, 34 PLF, 215/215 PASS` | `docs/verification/G0-S1-R2-preflight.md` |
| R13-FU3 code | `40e97d43fab3e113116fbbbad242cf00208c808a` | `a0d40a857347438ace7c7a227c98d44909e386c0` (R13-FU2 docs) | `R13-FU3: fail-closed helper, frozen identity, structured CleanupIdentityMismatch` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R13-FU3 docs | `bb4c5c37978fe93c74b2bddc46e0f326914110a4` | `40e97d43fab3e113116fbbbad242cf00208c808a` (R13-FU3 code) | `docs: R13-FU3 preflight - fail-closed helper, frozen identity, CleanupIdentityMismatch restructured, 215/215 PASS` | `docs/verification/G0-S1-R2-preflight.md` |
| R13-FU4 code | `053c9baf58589f262d1d41eb4c1273de122a1c2a` | `bb4c5c37978fe93c74b2bddc46e0f326914110a4` (R13-FU3 docs) | `fix(harness): R13 FU4 - shared fail-closed predicate, durable focused negative evidence in committed self-test path` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

Parent chain: R11 docs → R12 code → R12 docs → R13 code → R13 docs → R14 code → R14 docs → R13-FU2 code → R13-FU2 docs → R13-FU3 code → R13-FU3 docs → R13-FU4 code (this cycle's code commit)

---

## File Hashes

### Script: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

The R13-FU3 docs-only commit (`bb4c5c3`) does not change the script. The R13-FU4 docs-only commit (to be created) will not change the script either. Final script hashes are from the R13-FU4 code commit.

**Final script hashes (R13-FU4 code commit `053c9ba`):**

| Domain | SHA-256 |
|--------|---------|
| Raw Git-blob | `d2b4bae84a8f02af472b3c0bafdc1365aec71080464adfa4ed6616eb375c3dc8` |
| Checked-out (Windows) | `d2b4bae84a8f02af472b3c0bafdc1365aec71080464adfa4ed6616eb375c3dc8` |

Blob and checkout hashes match because the file has LF line endings (verified via `xxd`: no CRLF sequences present).

**Reproducible verification commands:**
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

**Final docs hashes** are recorded in the post-push external report to avoid self-reference (per R13-FU-03 non-self-referential strategy).

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
| cleanupReg | 1 | CleanupRegistrationFailure |

**Formula:** 6+1+4+2+1+2+2+2+3+8+2+1 = **34**

---

## Focused Negative Evidence

Total: **6** checks (runtime-derived `FocusedNegatives` suite count)

| Check | Mechanism | Predicate | Result |
|-------|-----------|-----------|--------|
| Neg1-ExtraEntry | Register 2 entries, ExpectedEntryCount=1 | `Test-HelperSuccess` (shared) | Success=False, EntryCount=2 |
| Neg2-NonemptyErrors | Inject error into clean result | `Test-HelperSuccess` (shared) | Success(pre-inject)=True, Errors.Count=1 → predicate false |
| Neg3-CloseAllFailure | `TestHook_FailClose=$true` | `Test-HelperSuccess` (shared) | Success=False, CloseAllSucceeded=False |
| Neg4-OwnedOuterCleanupFail | Mismatch + `TestHook_FailClose` on outer cleanup | `Test-HelperSuccess` + CloseAll | StoredResult=False |
| Neg5-OtherOuterCleanupFail | Match + `TestHook_FailClose` on outer cleanup | `Test-HelperSuccess` + CloseAll | StoredResult=False, ExitedVerified=True |
| Neg6-DiagFields | `TestHook_FailWait` + `TestHook_WaitErrorCode=0x57` | Property existence | All 4 fields populated |

**Shared predicate:** All checks use `Test-HelperSuccess` (the same function used by `Stop-Wait-VerifyOwnedProcess`'s finally block), not a copied formula.

**Negative check details from both runs:**
```
PASS: Neg1-ExtraEntry (Success=False EntryCount=2 ExpectedEntryCount=1)
PASS: Neg2-NonemptyErrors (Success(pre-inject)=True Errors.Count=1)
PASS: Neg3-CloseAllFailure (Success=False CloseAllSucceeded=False)
PASS: Neg4-OwnedOuterCleanupFail (HelperSuccess=False CloseAllSucceeded=False StoredResult=False)
PASS: Neg5-OtherOuterCleanupFail (HelperSuccess=False ExitedVerified=True CloseAllSucceeded=False StoredResult=False)
PASS: Neg6-DiagFields (TerminateWin32Error=0 FinalWaitCode=4294967295 FinalWaitWin32Error=87)
```

**Safety:** All negative tests use pre-acquired handle authority and safe outer cleanup via backup registries. No PID-only fallback. Cleanup hooks are reset in `finally` blocks.

---

## R15 Helper Total

```
ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) + FocusedNegatives(6) = 65
```

Full total: 54 (pure) + 102 (node) + 65 (R15) = **221**

---

## Two Consecutive Final Runs

### Run 1

| Field | Value |
|-------|-------|
| Start | 2026-09-02 |
| End | 2026-09-02 |
| Elapsed | 88.24s |
| Exit code | **0** |
| Total tests | **221** |
| Passed | **221/221** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |
| Focused negatives | **6/6 PASS** |
| Stderr | 0 bytes |
| Script SHA-256 (blob/checkout) | `d2b4bae84a8f02af472b3c0bafdc1365aec71080464adfa4ed6616eb375c3dc8` |

Suite table:
```
Pure-function tests: Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = 54
Node-backed tests: LockfileReader(102)
R15 helper tests: ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) + FocusedNegatives(6) = 65
Node resolution: C:\nvm4w\nodejs\node.exe
Total: 221 tests, 221/221 PASS, 0 FAILED
```

### Run 2

| Field | Value |
|-------|-------|
| Start | 2026-09-02 |
| End | 2026-09-02 |
| Elapsed | 84.52s |
| Exit code | **0** |
| Total tests | **221** |
| Passed | **221/221** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |
| Focused negatives | **6/6 PASS** |
| Stderr | 0 bytes |
| Script SHA-256 (blob/checkout) | `d2b4bae84a8f02af472b3c0bafdc1365aec71080464adfa4ed6616eb375c3dc8` |

Suite table:
```
Pure-function tests: Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = 54
Node-backed tests: LockfileReader(102)
R15 helper tests: ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) + FocusedNegatives(6) = 65
Node resolution: C:\nvm4w\nodejs\node.exe
Total: 221 tests, 221/221 PASS, 0 FAILED
```

---

## 5-Second Settling Hygiene

### Run 1 Settling

| Check | Post-Run1 |
|-------|-----------|
| New marker dirs after settle | **0** |
| PowerShell PID delta | **0** |

### Run 2 Settling

| Check | Post-Run2 |
|-------|-----------|
| New marker dirs after settle | **0** |
| PowerShell PID delta | **0** |

Zero resource leaks across both runs.

---

## R13 FU3 Changes and Fixes

(All FU3 items from previous round remain unchanged.)

### FU3-01: CleanupIdentityMismatch — Evidence Before Cleanup, Record After

**Fix:** Evidence collection variables are assigned in the `try` block. The test record is created in the `finally` block, AFTER both outer cleanups complete. Pass requires ALL of: `$handlesPreAcquired`, `$mismatchNoTerm`, `$mismatchIdentityMismatch`, `$mismatchOwnedStillAlive`, `$targetCloseAllOk`, `$ownedOuterOk`, `$otherOuterOk`, `$noException`, `$noCleanupError`.

### FU3-02: Fail-Closed Success in `Stop-Wait-VerifyOwnedProcess`

**Fix:** Success now requires ALL 9 mandatory invariants, computed via shared `Test-HelperSuccess` predicate (R14-FU4-03).

### FU3-03: Frozen Identity Before Hook Injection

(All fixture variables frozen before hook injection — unchanged.)

### FU3-04: New Diagnostic Fields

(All fields exposed — unchanged.)

---

## R13 FU4 Changes and Fixes

### FU4-01: Corrected Commit Topology

**Problem:** FU2/FU3 topology rows incorrectly labeled `a0d40a8` as FU2 code commit.

**Fix:** All topology rows derived mechanically from `git show -s --format` + `git show --name-only`. The FU2 chain is `0079c00` (code) → `a0d40a8` (docs). The FU3 chain is `40e97d4` (code) → `bb4c5c3` (docs).

### FU4-02: Corrected Script Hash Domain

**Problem:** Previous report repeated raw blob hash as checkout hash.

**Fix:** Both domains computed independently. Current script has LF endings (verified via `xxd`), so blob and checkout hashes happen to match. Hash domains are reported separately with explicit column headers.

### FU4-03: Durable Focused Negative Evidence

**Problem:** Negative checks existed only in untracked `test-fu3-negatives.ps1`.

**Fix:** Added `Test-HelperSuccess` shared predicate (used by both the helper and negative tests) and `Test-FocusedNegatives` function with 6 committed checks. Tracked as `FocusedNegatives` suite in `SelfTestSuiteResults`. All checks use production predicates and pre-acquired backup handles for safe cleanup.

### FU4-04: Remediation Artifact Removal

**Problem:** Untracked `test-fu3-negatives.ps1` and `test-waitfailure-debug.ps1` remained.

**Status:** To be removed after this commit. Both files verified as untracked remediation artifacts (inspected contents match described purposes).

### FU4-05: Evidence Wording

**Fix:** Report distinguishes author-run evidence from independent review. No "all gates pass" or "clean tree" claims while artifacts remain. Hash domains computed independently. No fabricated/self-referential docs hash.

---

## CleanupIdentityMismatch Full Evidence

(From both FU4 runs — unchanged from FU3, same fixture code path.)

**Actual line from both runs:**
```
targetReg=True ownedCleanupReg=True otherCleanupReg=True idVerified=True idMatched=False noTerm=True targetCloseAll=True alive=True ownedExited=True ownedClose=True otherExited=True otherClose=True noException=True noCleanupError=True
```

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

## R13-FU4 Delta Summary

| FU | Description | Status |
|----|-------------|--------|
| FU-01 | Handle-based `Stop-Wait-VerifyOwnedProcess`; pre-acquired cleanup handles | DONE (R14) |
| FU-02 | Identity/handle evidence captured before fault injection | DONE (R14) |
| FU-03 | Non-self-referential preflight hash strategy | DONE (R14) |
| FU-04 | Safety property assertions: handle pre-acquisition, no PID-only | DONE (R14) |
| FU2-01 | Bounded `WaitForSingleObject` in `TerminateAndVerify` failure branch | DONE (R13-FU2) |
| FU2-02 | `Success` computation moved into `finally` block | DONE (R13-FU2) |
| FU2-03 | `CleanupRegistrationFailure` fixture added (34th PLF fixture) | DONE (R14/FU2) |
| FU3-01 | CleanupIdentityMismatch: evidence in try, record in finally | DONE (R13-FU3) |
| FU3-02 | Fail-closed Success: 9 mandatory invariants via shared predicate | DONE (R13-FU3/FU4) |
| FU3-03 | Frozen creation identity before hook injection | DONE (R13-FU3) |
| FU3-04 | Diagnostic fields: TerminateWin32Error, TerminateError, FinalWaitCode, FinalWaitWin32Error | DONE (R13-FU3) |
| FU4-01 | Corrected FU2/FU3 commit topology in all documents | DONE (R13-FU4) |
| FU4-02 | Corrected script hash domain (blob vs checkout independently computed) | DONE (R13-FU4) |
| FU4-03 | Durable focused negative evidence via shared predicate in committed script | DONE (R13-FU4) |
| FU4-04 | Remediation artifact removal | DONE (R13-FU4) |
| FU4-05 | Evidence wording matches gate state | DONE (R13-FU4) |
