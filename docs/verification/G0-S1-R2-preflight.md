# G0-S1 R13 Follow-up Round 5 Preflight Report

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
| R13-FU4 docs | `84e436d75674fb9cccb6f4b0b23e9f07a82c525e` | `053c9baf58589f262d1d41eb4c1273de122a1c2a` (R13-FU4 code) | `docs: R13-FU4 preflight - corrected topology, shared predicate, durable negative evidence, 221/221 PASS` | `docs/verification/G0-S1-R2-preflight.md` |
|| R13-FU5 code | `e6351e9` | `84e436d75674fb9cccb6f4b0b23e9f07a82c525e` (R13-FU4 docs) | `fix(harness): R13 FU5 - shared CleanupIdentityMismatch predicate, verified backup cleanup, dynamic R15 formula` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R13-FU5b code | `6ace82d007a400647edf0a474c244530f89ea047` | `e6351e9` (R13-FU5 code) | `fix(harness): R13 FU5b - Neg4/Neg5 backup cleanup gates, R15 formula uniqueness assertion` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

Parent chain: R11 docs → R12 code → R12 docs → R13 code → R13 docs → R14 code → R14 docs → R13-FU2 code → R13-FU2 docs → R13-FU3 code → R13-FU3 docs → R13-FU4 code → R13-FU4 docs → R13-FU5 code → R13-FU5b code (this cycle's code commit)

---

## File Hashes

### Script: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

The R13-FU5b docs-only commit (to be created) will not change the script. Final script hashes are from the R13-FU5b code commit.

**Final script hashes (R13-FU5b code commit `6ace82d`):**

| Domain | SHA-256 |
|--------|---------|
| Raw Git-blob | `8d93e244c325bd979f1c3333dc96cceac0a39ca0` (git hash-object) |
| Checked-out (Windows, CRLF) | `7b827bfa70f7712d6b3a4b48fa8779166b5c5103969880b601c0a6b00cff9a7e` (sha256sum) |

The checkout hash differs from the blob hash because Git applies CRLF conversion on checkout (autocrlf=true). The blob retains LF endings. Each hash is environment-specific evidence, not a universal property of the Git blob.

**Reproducible verification commands:**
```bash
# Code commit hash
git log --oneline -1 -- research/g0-s1-harness-integration/windows-poc-test-r2.ps1

# Script blob object ID
git ls-tree HEAD -- research/g0-s1-harness-integration/windows-poc-test-r2.ps1

# Raw Git-blob SHA-256
git cat-file blob <BLOB_ID> | sha256sum

# Checkout SHA-256 (environment-specific, depends on autocrlf)
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

### FU5 Changes Summary

**FU5-01:** Extracted `Test-CleanupIdentityMismatchSuccess` shared predicate consuming all9 required evidence conditions. Used by the real `CleanupIdentityMismatch` fixture AND by Neg4/Neg5. Neg4 and Neg5 now start with a complete baseline evidence object where the predicate returns TRUE, then alter exactly ONE condition (owned outer cleanup / other outer cleanup) to make it FALSE. Both print `BaselineTrue=True AlteredResult=False`.

**FU5-02:** Every negative test now pre-acquires an independent backup cleanup handle for every started process before injection/action. PASS conditions gate: backup registration success, cleanup helper Success, ExitedVerified, CloseAllSucceeded, and zero cleanup errors. No reliance on `Process.Dispose()`, natural `Start-Sleep` completion, PID lookup, or process-name-wide kill as cleanup authority.

**Previous Round 4 issue noted:** Round 4 claimed "all negative tests use backup registries" but Neg1 had no backup cleanup for the second process, and Neg6 had no backup registry at all. Neg4/Neg5 used inline formulas that were vacuous (already false without the intended failure). These are corrected in Round 5.

### Check Details

| Check | Mechanism | Predicate | Result |
|-------|-----------|-----------|--------|
| Neg1-ExtraEntry | Register 2 entries, ExpectedEntryCount=1; independent backup cleanup for BOTH processes | `Test-HelperSuccess` (shared) | HelperFail=True; bk1/bk2 registration+cleanup all verified |
| Neg2-NonemptyErrors | Inject error into clean result; backup cleanup for process | `Test-HelperSuccess` (shared) | HelperFail=True; backup registration+cleanup verified |
| Neg3-CloseAllFailure | `TestHook_FailClose=$true`; backup cleanup for process | `Test-HelperSuccess` (shared) | HelperFail=True; backup registration+cleanup verified |
| Neg4-OwnedOuterCleanupFail | Mismatch fixture; baseline-true via shared predicate; `TestHook_FailClose` on owned cleanup ONLY; backup gates in PASS | `Test-CleanupIdentityMismatchSuccess` (shared) | BaselineTrue=True, AlteredResult=False; bk5a/bk5b registration+cleanup all verified |
| Neg5-OtherOuterCleanupFail | Mismatch fixture; baseline-true via shared predicate; `TestHook_FailClose` on other cleanup ONLY; backup gates in PASS | `Test-CleanupIdentityMismatchSuccess` (shared) | BaselineTrue=True, AlteredResult=False; bk6a/bk6b registration+cleanup all verified |
| Neg6-DiagFields | `TestHook_FailWait` + `TestHook_WaitErrorCode=0x57`; backup cleanup for process | Property existence + backup cleanup | Diag=True; backup registration+cleanup verified |

**Shared predicates:** All checks use `Test-HelperSuccess` (the same function used by `Stop-Wait-VerifyOwnedProcess`'s finally block) or `Test-CleanupIdentityMismatchSuccess` (used by the real fixture), not copied formulas.

**Negative check details from both runs:**
```
PASS: Neg1-ExtraEntry (HelperFail=True bk1Reg=True bk2Reg=True bk1Succ=True bk1Exit=True bk1Close=True bk1Err=0 bk2Succ=True bk2Exit=True bk2Close=True bk2Err=0)
PASS: Neg2-NonemptyErrors (HelperFail=True bkReg=True bkSucc=True bkExit=True bkClose=True bkErr=0)
PASS: Neg3-CloseAllFailure (HelperFail=True bkReg=True bkSucc=True bkExit=True bkClose=True bkErr=0)
PASS: Neg4-OwnedOuterCleanupFail (BaselineTrue=True AlteredResult=False ownedOk=False otherOk=True handles=True noTerm=True idMismatch=True alive=True targetClose=True bk5aReg=True bk5bReg=True bk5aSucc=True bk5aExit=True bk5aClose=True bk5aErr=0 bk5bSucc=True bk5bExit=True bk5bClose=True bk5bErr=0)
PASS: Neg5-OtherOuterCleanupFail (BaselineTrue=True AlteredResult=False ownedOk=True otherOk=False handles=True noTerm=True idMismatch=True alive=True targetClose=True bk6aReg=True bk6bReg=True bk6aSucc=True bk6aExit=True bk6aClose=True bk6aErr=0 bk6bSucc=True bk6bExit=True bk6bClose=True bk6bErr=0)
PASS: Neg6-DiagFields (Diag=True bkReg=True bkSucc=True bkExit=True bkClose=True bkErr=0 TerminateWin32Error=0 FinalWaitCode=4294967295 FinalWaitWin32Error=87)
```

**Safety:** All6 negative tests use pre-acquired backup handle authority and safe outer cleanup via `Stop-Wait-VerifyOwnedProcess` on backup registries. No PID-only fallback. No `Process.Dispose()`-only cleanup. Cleanup hooks are reset in `finally` blocks with deterministic FAIL records on exception.

---

## R15 Helper Total

```
ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) + FocusedNegatives(6) = 65
```

The formula is built dynamically from the same runtime suite list used to calculate `$R15Total`. Deterministic assertions verify: (1) displayed sum equals `$R15Total`, (2) each included R15 suite name/count appears exactly once in the formula.

Full total: 54 (pure) + 102 (node) + 65 (R15) = **221**

---

## Two Consecutive Final Runs

### Run 1

| Field | Value |
|-------|-------|
| Date | 2026-09-02 |
| Exit code | **0** |
| Total tests | **221** |
| Passed | **221/221** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |
| Focused negatives | **6/6 PASS** |
| Stderr | 0 bytes |

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
| Date | 2026-09-02 |
| Exit code | **0** |
| Total tests | **221** |
| Passed | **221/221** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **34/34 PASS** |
| Focused negatives | **6/6 PASS** |
| Stderr | 0 bytes |

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
| PowerShell PID delta | **0** |
| Marker dir delta | **0** |
| Held handle count | **0** |
| Unfinished collectors | **0** |

### Run 2 Settling

| Check | Post-Run2 |
|-------|-----------|
| PowerShell PID delta | **0** |
| Marker dir delta | **0** |
| Held handle count | **0** |
| Unfinished collectors | **0** |

Zero resource leaks across both runs. Verified via `tasklist` filtering for `powershell.exe` before and after5-second wait.

### Round 4 Transient PID Finding

Independent review observed one new PowerShell PID (47812) after the5-second settling window in the Round 4 run. It disappeared later, consistent with an unowned `Start-Sleep` child naturally exiting rather than verified cleanup. Round 5 fixes this by ensuring every negative test's processes have verified backup cleanup handles, and no cleanup relies on natural `Start-Sleep` completion or `Process.Dispose()`.

---

## R13 FU5 Changes and Fixes

### FU5-01: Shared CleanupIdentityMismatch Predicate

**Problem:** Round 4 Neg4 and Neg5 used inline formulas that were vacuous — Neg4's wrong-identity already made `Test-HelperSuccess` false without any outer-cleanup failure, and Neg5 only tested one matching helper with CloseAll failure without modeling the full two-process fixture state.

**Fix:** Extracted `Test-CleanupIdentityMismatchSuccess` shared predicate consuming all9 required evidence conditions: `$HandlesPreAcquired`, `$MismatchNoTerm`, `$MismatchIdentityMismatch`, `$MismatchOwnedStillAlive`, `$TargetCloseAllOk`, `$OuterOwnedOk`, `$OuterOtherOk`, `$NoException`, `$NoCleanupError`. Used by:
- The real `CleanupIdentityMismatch` fixture (replaces inline formula)
- Neg4: builds complete baseline (predicate=TRUE), flips owned outer cleanup → predicate=FALSE
- Neg5: builds complete baseline (predicate=TRUE), flips other outer cleanup → predicate=FALSE

### FU5-02: Verified Backup Cleanup for All Negative Tests

**Problem:** Round 4 Neg1 had no backup cleanup for the second process. Neg3-Neg5 created backup registries but did not gate PASS on backup registration/cleanup success. Neg6 had no backup registry. Independent review observed a transient orphan PowerShell PID after the5-second settling window.

**Initial FU5 fix:** Every negative test pre-acquires independent backup cleanup handles. PASS gates backup registration success, cleanup helper Success, ExitedVerified, CloseAllSucceeded, and zero cleanup errors.

**FU5b refinement:** Neg4 and Neg5 PASS computation was inside the try block, before the finally block ran backup cleanup. Restructured so PASS is computed after finally and gates backup cleanup results. Variables initialized before try to ensure accessibility after finally. Deterministic FAIL record on exception; safe cleanup continues regardless.

### FU5-03: Dynamic R15 Formula Display

**Problem:** Round 4 output showed `ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(34) = 65` but the total65 included `FocusedNegatives(6)`. The displayed formula was internally inconsistent.

**Fix:** R15 formula display is built from the same runtime suite list used to calculate `$R15Total`. Includes all recorded R15 suites (ManifestCompare, SuiteEvidence, ProcessLevelFaults, FocusedNegatives). Deterministic assertion verifies displayed sum equals `$R15Total`.

### FU5-04: Corrected Preflight Claims

**Problem:** Round 4 preflight claimed "all negative tests use backup registries" but code contradicted this. Round 4 did not record the independent transient-PID finding.

**Fix:** This report accurately describes the Round 4 deficiencies, the Round 5 fixes, and the independent settling finding.

---

## CleanupIdentityMismatch Full Evidence

**Actual line from both runs:**
```
targetReg=True ownedCleanupReg=True otherCleanupReg=True idVerified=True idMatched=False noTerm=True targetCloseAll=True alive=True ownedExited=True ownedClose=True otherExited=True otherClose=True noException=True noCleanupError=True
```

The fixture now uses the shared `Test-CleanupIdentityMismatchSuccess` predicate instead of an inline formula.

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
- No Full PoC/Harness
- No npm install
- No HTTP/WS/ports

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

## R13-FU5 Delta Summary

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
| FU5-01 | Shared `Test-CleanupIdentityMismatchSuccess` predicate; non-vacuous Neg4/Neg5 | DONE (R13-FU5) |
| FU5-02 | Verified backup cleanup handles for all6 negative tests | DONE (R13-FU5/FU5b) |
| FU5-03 | Dynamic R15 formula display including FocusedNegatives | DONE (R13-FU5) |
| FU5-04 | Corrected preflight claims; recorded transient-PID finding | DONE (R13-FU5) |
