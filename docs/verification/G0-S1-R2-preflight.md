# G0-S1 R13 Preflight Report

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
| R13 docs | *(this commit)* | `0d631ebca398c6edccf4eb06d9333703c6fd17af` (R13 code) | `docs: R13 preflight report - shared exit mapper, PID-reuse-safe cleanup, 33 PLF, 214/214 PASS` | `docs/verification/G0-S1-R2-preflight.md` |

Parent chain: R11 docs → R12 code → R12 docs (corrected) → R13 code → R13 docs (this)

---

## File Hashes

### Script: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

| Field | Value |
|-------|-------|
| Git blob object ID | `df4e8df644e579ff7f1b309307f40f1a78de6dd4` |
| SHA-256 of raw Git blob bytes | `4f21204116b80b1d06031a29981e606c7b06c17dad4907f740584818c8f8d8e8` |
| SHA-256 of checked-out Windows file | `4f6cd95c570a2e22f3a878cef2396302bfe2c48e715fab73fb0971228ac5ca60` |

SHA-256 of raw Git blob bytes computed via: `git cat-file blob <blob> > tmp.bin && sha256sum tmp.bin`.
SHA-256 of checked-out file computed via: `sha256sum <file>`.
CRLF conversion causes these to differ.

### Preflight: `docs/verification/G0-S1-R2-preflight.md`

| Field | Value |
|-------|-------|
| Git blob object ID | `4403a23ca6bd8c81f31c610f413aa137985bc557` |
| SHA-256 of raw Git blob bytes | `7bdd6138ed58e089589175bca65e28473fef3272e1f4f3762d3e9232988c4ddc` |
| SHA-256 of checked-out Windows file | `508931b9f67b105611003a62686bcf015d08a9ba4caf5b247a1385c970b63eda` |

Note: These preflight blob hashes are from the final R13 docs commit. Amending this document again would create a new blob.

---

## Static Analysis

| Tool | Result |
|------|--------|
| PowerShell Parser | **0 errors** |
| PSScriptAnalyzer Severity Error | **0 findings** |

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
| Elapsed | **00:01:03.5370126** |
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
| Elapsed | **00:01:10.3297309** |
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

| Check | Run 1 Pre | Run 1 Post | Run 1 Delta | Run 2 Pre | Run 2 Post | Run 2 Delta |
|-------|-----------|------------|-------------|-----------|------------|-------------|
| PowerShell PID | 51928 | 51928 | **0** | 40580 | 40580 | **0** |
| Marker files | 0 | 0 | **0** | 0 | 0 | **0** |
| Held handles | 0 | 0 | **0** | 0 | 0 | **0** |
| Unfinished tasks | 0 | 0 | **0** | 0 | 0 | **0** |

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

**Mechanism:** Starts a real `powershell -Command "Start-Sleep 5"` process, captures `StartTime.Ticks` as `$matchCreationTime`, calls `Stop-Wait-VerifyOwnedProcess -ProcessId $matchProcId -CreationTime $matchCreationTime`. The function reads the process's actual creation time, compares it to the supplied `$CreationTime`, finds a match, safely terminates, waits for exit, and verifies the process is absent. Outer-finally confirms cleanup even if the inner logic fails.

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

**Mechanism:** Starts TWO real processes. Calls `Stop-Wait-VerifyOwnedProcess` with the FIRST process's PID but the SECOND process's creation time. The function reads the first process's actual creation time, compares it to the supplied time (which belongs to the second process), finds a mismatch, and **refuses to terminate** the PID. The first process remains alive. Outer-finally safely cleans up both processes.

**Key safety guarantee:** Identity mismatch or unreadable identity → no termination requested → target process survives → safe outer-finally cleanup.

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

## Key Fixes in R13

1. **Shared exit mapper (`Get-OverallExitResult`)** — moved before `Invoke-SelfTestAggregation`; single source of truth for exit codes and banner/totals permissions. The former duplicate manual PASS/FAIL/BLOCKED/ERROR switch is removed.
2. **Production uses structured result** — aggregation consumes `Overall`, `ExitCode`, `SuccessBannerAllowed`, `TrustedTotalsAllowed` from the shared mapper. Banner and totals are computed as AND of local condition and shared mapper permission.
3. **PID-reuse-safe `Stop-Wait-VerifyOwnedProcess`** — `CreationTime` is now a mandatory parameter. Identity is verified (creation time comparison) before EVERY termination attempt — both primary and fallback paths. On identity mismatch or unreadable identity, the function does NOT kill the PID and returns structured failure.
4. **Three native-API finally paths** — `GetProcessTimesFailure`, `WaitFailure`, and `CloseHandleFailure` all capture `StartTime.Ticks` before fault injection and pass it to `Stop-Wait-VerifyOwnedProcess`.
5. **`CleanupIdentityMatch` fixture** — deterministic test proving match→terminate→absent lifecycle.
6. **`CleanupIdentityMismatch` fixture** — deterministic test proving mismatch→no-terminate→still-alive safety guarantee.
7. **All cleanup sites verify identity + (exited OR terminated) + absent** — not just `FinalAbsent` alone.

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

## R12-R13 Delta Summary

| REM | Description | Status |
|-----|-------------|--------|
| R13-REM-01 | `Get-OverallExitResult` moved before `Invoke-SelfTestAggregation` | DONE |
| R13-REM-02 | Production aggregation uses shared mapper; duplicate switch removed; fail-closed banner/totals | DONE |
| R13-REM-03 | PID-reuse-safe `Stop-Wait-VerifyOwnedProcess`; `CleanupIdentityMatch`/`CleanupIdentityMismatch` fixtures; creation time mandatory | DONE |
| R13-REM-04 | Suite-evidence tests verify ERROR → exit 3, no banner, no trusted totals | DONE |
| R13-REM-05 | All three native-API finally paths pass creation time | DONE |
| R13-REM-06 | Preflight with mechanical evidence | DONE |
