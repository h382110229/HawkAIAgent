# G0-S1 R14 Follow-up Preflight Report

**Date:** 2026-08-31
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
| R14 code | `b4a4fcd` (abbreviated; full hash verified post-push) | `9393f343b6cf5322f5d9a102901c5863397dec6a` (R13 docs) | `test: R14 follow-up - handle-based Stop-Wait-VerifyOwnedProcess, pre-acquired cleanup handles for all native API and cleanup identity fixtures` | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |
| R14 docs | *(this commit)* | R14 code | `docs: R14 follow-up preflight - handle-based cleanup, non-self-referential hashes` | `docs/verification/G0-S1-R2-preflight.md` |

Parent chain: R11 docs → R12 code → R12 docs (corrected) → R13 code → R13 docs → R14 code → R14 docs (this)

---

## File Hashes

### Script: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

The R14 docs-only commit does not change the script. Final script hashes are:

| Field | Value |
|-------|-------|
| Git blob object ID | *(verified post-push via `git ls-tree HEAD -- research/g0-s1-harness-integration/windows-poc-test-r2.ps1`)* |
| SHA-256 of raw Git blob bytes | *(verified post-push via `git cat-file blob <blob> \| sha256sum`)* |
| SHA-256 of checked-out Windows file | *(verified post-push via `sha256sum research/g0-s1-harness-integration/windows-poc-test-r2.ps1`)* |

SHA-256 of raw Git blob bytes computed via: `git cat-file blob <blob> > tmp.bin && sha256sum tmp.bin`.
SHA-256 of checked-out file computed via: `sha256sum <file>`.
CRLF conversion causes these to differ.

### Preflight: `docs/verification/G0-S1-R2-preflight.md`

The preflight's own blob and hash values CANNOT be reliably embedded in the same document — editing the values changes the blob, creating a self-referential cycle. This was the R13 error (stale values `4403a23c...` / `7bdd6138...` / `508931b9...` were committed as "final" but became stale when the document was amended).

**Strategy:** Final docs commit/blob/raw-hash/checkout-hash are recorded in the external post-push publication report, NOT in this document. The post-push report is generated after the docs commit exists and contains the actual final values.

**Supersedes:** The R13 preflight's claim "These preflight blob hashes are from the final R13 docs commit" was incorrect — the embedded values were stale. The actual final R13 values are:

| Field | Value |
|-------|-------|
| R13 docs commit | `9393f343b6cf5322f5d9a102901c5863397dec6a` |
| R13 preflight blob | `3ddd1a9870914be1ddfb7025c7531bca032cf198` |
| R13 preflight raw SHA-256 | `98b949ceb7cb4d8176cfb4e91453a6818301dbce36a5f129537bdff3e4a695b3` |
| R13 preflight checkout SHA-256 | `bf139b80299208110602ebbbec575c5d9c09abfb0e7a2dc888c4b3b0b1883ce5` |

**Reproducible post-commit verification commands:**
```bash
# Docs commit hash (run after docs commit exists)
git log --oneline -1 -- docs/verification/G0-S1-R2-preflight.md

# Preflight blob object ID
git ls-tree HEAD -- docs/verification/G0-S1-R2-preflight.md

# Raw Git-blob SHA-256
git cat-file blob <BLOB_ID> | sha256sum

# Checkout SHA-256
sha256sum docs/verification/G0-S1-R2-preflight.md
```

---

## Static Analysis

| Tool | Version | Result |
|------|---------|--------|
| PowerShell Parser | (built-in) | **0 errors**, 46572 tokens |
| PSScriptAnalyzer Severity Error | **v1.25.0** | **0 findings** |

---

## Fixture Inventory

Total: **33** fixtures (runtime-derived `ProcessLevelFaults` fixture count)

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

**Formula:** 6+1+4+2+1+2+2+2+3+8+2 = **33**

---

## R15 Helper Total

```
ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(33) = 58
```

Full total: 54 (pure) + 102 (node) + 58 (R15) = **214**

---

## Two Consecutive Final Runs

### Run 1

| Field | Value |
|-------|-------|
| Exit code | **0** |
| Stderr bytes | **0** |
| Total tests | **214** |
| Passed | **214/214** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **33/33 PASS** |

Suite table:
```
Pure-function tests: Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = 54
Node-backed tests: LockfileReader(102)
R15 helper tests: ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(33) = 58
```

### Run 2

| Field | Value |
|-------|-------|
| Exit code | **0** |
| Stderr bytes | **0** |
| Total tests | **214** |
| Passed | **214/214** |
| Failed | **0** |
| Overall | **PASS** |
| Suite validation | **PASS** |
| PLF | **33/33 PASS** |

Suite table:
```
Pure-function tests: Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = 54
Node-backed tests: LockfileReader(102)
R15 helper tests: ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(33) = 58
```

---

## 5-Second Settling Hygiene

| Check | Run 1 Post (5s) | Run 2 Post (5s) |
|-------|-----------------|-----------------|
| Marker directories | **0** | **0** |
| Marker files | **0** | **0** |

No residual PIDs, markers, held handles, or unfinished collectors after either run.

---

## CleanupIdentityMatch Evidence

**Fixture:** `CleanupIdentityMatch`

| Field | Value |
|-------|-------|
| Test result | PASS |
| IdentityMatched | True |
| IdentityVerified | True |
| TerminateRequested | True |
| Exited | True |
| FinalAbsent | True |
| Handle pre-acquired | True |

**Mechanism (R14):** Starts a real `powershell -Command "Start-Sleep 5"` process. Pre-registers a cleanup handle via `$matchCleanupReg.RegisterProcess()` BEFORE calling `Stop-Wait-VerifyOwnedProcess`. The function acquires its own temporary handle via `ProcessHandleRegistry.RegisterProcess`, converts .NET DateTime ticks to FILETIME ticks for comparison with `GetProcessTimes`, verifies identity match, terminates and waits through the held handle, closes with structured success. The pre-registered cleanup handle provides an independent safety net in the outer finally.

**FU-04 safety property:** Test asserts `$matchCleanupRegOk` (handle pre-acquired) as part of the PASS condition.

---

## CleanupIdentityMismatch Evidence

**Fixture:** `CleanupIdentityMismatch`

| Field | Value |
|-------|-------|
| Test result | PASS |
| IdentityMismatch | True |
| IdentityVerified | True |
| TerminateRequested | False |
| Exited | False |
| Owned process still alive | True |
| Both handles pre-acquired | True |

**Mechanism (R14):** Starts TWO real processes. Pre-registers cleanup handles for BOTH via `$ownedCleanupReg.RegisterProcess()` and `$otherCleanupReg.RegisterProcess()` BEFORE the test. Calls `Stop-Wait-VerifyOwnedProcess` with the FIRST process's PID but the SECOND process's creation time. The function's temporary handle reads the first process's FILETIME creation time, compares to the converted second process's time, finds a mismatch, and **refuses to terminate**. The first process remains alive (verified via `$ownedCleanupReg.CheckWaitStatus(0).Exited` — held-handle check, not PID lookup). Outer-finally cleans both processes through their own pre-acquired handles.

**Key safety guarantees:**
- Identity mismatch → no termination requested → target process survives
- Alive check uses held handle (`CheckWaitStatus`), not PID lookup (`Get-Process -Id`)
- Outer finally uses pre-acquired handles, not `Stop-Process -Id`

---

## Suite-Evidence: Shared Mapper Fail-Closed Verification

The `Get-OverallExitResult` function is the single source of truth for exit codes and banner/totals permissions. It is defined BEFORE `Invoke-SelfTestAggregation` and called directly by production aggregation.

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

**Field names and meaning:**
- `SuccessBannerPrinted`: the final computed field from `Invoke-SelfTestAggregation` return object. `False` means the success banner was suppressed. Computed as `$successBannerPrinted -and $exitResult.SuccessBannerAllowed` — both the local condition AND the shared mapper must allow.
- `TrustedTotalsPrinted`: the final computed field from `Invoke-SelfTestAggregation` return object. `False` means trusted totals were suppressed. Computed as `$trustedTotalsPrinted -and $exitResult.TrustedTotalsAllowed`.
- `SuccessBannerAllowed`: field from `Get-OverallExitResult` — `False` when Overall ≠ PASS.
- `TrustedTotalsAllowed`: field from `Get-OverallExitResult` — `False` when Overall ≠ PASS.

For all ERROR cases: `SuccessBannerAllowed=False`, `TrustedTotalsAllowed=False`, so even if the local `successBannerPrinted` were `True`, the final `SuccessBannerPrinted` is `False`. This is the fail-closed behavior.

---

## Key Fixes in R14 Follow-up

### FU-01 — Handle-based `Stop-Wait-VerifyOwnedProcess`

The R13 `Stop-Wait-VerifyOwnedProcess` used PID-based `Get-Process -Id` / `Stop-Process -Id` with check-then-act patterns vulnerable to PID reuse. R14 replaces this with:

1. Acquires a native handle via `ProcessHandleRegistry.RegisterProcess` (atomic `OpenProcess` + `GetProcessTimes`)
2. Converts .NET `DateTime.Ticks` (epoch 0001-01-01) to Windows `FILETIME` ticks (epoch 1601-01-01) for comparison with `GetProcessTimes` output
3. Verifies identity through the held handle's creation time
4. Terminates and waits through the held handle (`TerminateAndVerify`)
5. Closes handle with structured success verification (`CloseAll`)
6. Never calls `Stop-Process -Id` or `Get-Process -Id` for termination

### FU-01/02 — Pre-acquired cleanup handles for native API fixtures

All five native API and cleanup identity fixtures now pre-register cleanup handles BEFORE fault injection:

- **GetProcessTimesFailure:** Cleanup handle registered via `$gptCleanupReg.RegisterProcess()` before `TestHook_FailGetProcessTimes = $true`. The intentionally failing registration in `$fixtureRegistry` remains independently tested.
- **WaitFailure:** Cleanup handle registered via `$waitCleanupReg.RegisterProcess()` before `TestHook_FailWait = $true`. Hooks reset before using cleanup handle in finally.
- **CloseHandleFailure:** Cleanup handle registered via `$closeCleanupReg.RegisterProcess()` before `TestHook_FailClose = $true`. Hooks reset before using cleanup handle in finally.
- **CleanupIdentityMatch:** Cleanup handle pre-registered; test asserts `$matchCleanupRegOk` as PASS condition.
- **CleanupIdentityMismatch:** Both cleanup handles pre-registered; alive check uses held handle `CheckWaitStatus(0)`, not PID lookup.

### FU-04 — Safety property assertions

- `CleanupIdentityMatch` asserts handle pre-acquisition (`$handlePreAcquired`) as part of PASS condition
- `CleanupIdentityMismatch` asserts both handles pre-acquired AND alive via held handle (not PID lookup)
- All finally blocks use handle-based cleanup (registry `TerminateAndVerify` + `CloseAll`), not PID-based `Stop-Process -Id`
- Fixture count remains 33; totals runtime-derived

### Tick Epoch Conversion

`Stop-Wait-VerifyOwnedProcess` receives `.NET DateTime.Ticks` (epoch 0001-01-01, local time) from callers. `ProcessHandleRegistry.RegisterProcess` returns FILETIME ticks (epoch 1601-01-01, UTC) from `GetProcessTimes`. The function converts via:
```powershell
$fileTimeTicks = [System.TimeZoneInfo]::ConvertTimeToUtc(
    [DateTime]::new($CreationTime, [DateTimeKind]::Local)
).ToFileTimeUtc()
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

## Docs Commit

The docs commit hash is the commit containing this file. Since updating this
document changes the commit hash, the actual hash is verified post-commit
with: `git log --oneline -1 -- docs/verification/G0-S1-R2-preflight.md`

---

## R13-R14 Delta Summary

| FU | Description | Status |
|----|-------------|--------|
| FU-01 | Handle-based `Stop-Wait-VerifyOwnedProcess`; pre-acquired cleanup handles for all 5 fixtures; no `Stop-Process -Id` in cleanup paths | DONE |
| FU-02 | Identity/handle evidence captured before fault injection via pre-registration | DONE |
| FU-03 | Non-self-referential preflight hash strategy; stale R13 self-hash corrected | DONE |
| FU-04 | Safety property assertions: handle pre-acquisition, held-handle alive check, no PID-only termination | DONE |
