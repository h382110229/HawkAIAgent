# G0-S1 R2 Remediation Evidence Report

**Gate:** REMEDIATION ROUND 2 PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED
**Date:** 2026-08-26

---

## 1. Code Commit (bound by this document)

| Field | Value |
|---|---|
| Commit | `3ec02d2` |
| Parent | `75ffd2c` (R15 remediation) |
| Subject | `test: fix fault subprocess evidence integrity and process-level timeout for R2 remediation` |
| Scope | `windows-poc-test-r2.ps1` only |

### Script blob and SHA-256

| File | Git blob | SHA-256 |
|---|---|---|
| `windows-poc-test-r2.ps1` | `50595e01fef1e9342884ab4c7b23d8e72909a477` | `b66620f2994a1129e1143ab048d4f266cbf44e16d7580edf63ae0438ef0484f0` |

*(This document's own blob/hash cannot be known until after this commit; the post-push report will record them.)*

---

## 2. R2-REM Fixes

### R2-REM-01: Skipped process tests not faked as PASS

**Before:** Fault subprocesses recorded `ProcessLevelFaults = @{ Declared=5; Actual=5; Passed=5; Failed=0 }` for skipped tests.

**After:** Fault subprocesses do NOT record ProcessLevelFaults at all. The suite list is built dynamically — only includes suites that are actually recorded. Fault output shows `ProcessLevelFaults(0)` in the R15 formula.

**Evidence:** Fault `MissingSuite` output shows:
```
Process-Level Fault self-test SKIPPED (inside fault subprocess)
R15 helper tests: ManifestCompare(14) + SuiteEvidence(5) + ProcessLevelFaults(0) = 19
```

### R2-REM-02: Structural corruption prints UNTRUSTED, not trusted totals

**Before:** Helper printed `N/N PASS` even when suite validation failed.

**After:** When `$suiteValid` is false, prints `UNTRUSTED / STRUCTURAL ERROR: N tests reported, N claimed PASS, N FAILED — NOT RELIABLE`. Also fail-closed on `Passed > Actual` and `Failed < 0`.

**Evidence:** All 5 fault outputs show `UNTRUSTED / STRUCTURAL ERROR` and no `N/N PASS` pattern.

### R2-REM-03: R15 subtotal formula includes ProcessLevelFaults

**Before:** `ManifestCompare(14) + SuiteEvidence(5) = 24` (missing ProcessLevelFaults).

**After:** `ManifestCompare(14) + SuiteEvidence(5) + ProcessLevelFaults(5) = 24` (complete formula).

### R2-REM-04: Process harness has timeout, bounded output, strong assertions

**Before:** No timeout, unbounded stdout, weak regex assertions.

**After:**
- 120s timeout per child (kills on timeout, reports FAIL)
- 50KB bounded stdout capture
- try/finally with `$proc.Dispose()`
- 7 assertion checks: exit=3, no "All self-tests passed", no `N/N PASS`, no skipped-as-passed, structured SUITE-VALIDATION+ScriptInternal+FAIL, UNTRUSTED present, within timeout

---

## 3. Validation Evidence

### Parser / Analyzer
- PowerShell Parser: **0 errors**
- PSScriptAnalyzer v1.25.0 Severity Error: **0 issues**

### Normal self-test (consecutive)

| Run | Exit Code | Total | Passed | Failed |
|-----|-----------|-------|--------|--------|
| A | 0 | 180 | 180 | 0 |
| B | 0 | 180 | 180 | 0 |

### Runtime-derived suite inventory

| Suite | Declared | Actual | Passed | Failed |
|-------|----------|--------|--------|--------|
| Aggregation | 11 | 11 | 11 | 0 |
| NativeJudgment | 24 | 24 | 24 | 0 |
| ParentPath | 4 | 4 | 4 | 0 |
| GateSummary | 15 | 15 | 15 | 0 |
| LockfileReader | 102 | 102 | 102 | 0 |
| ManifestCompare | 14 | 14 | 14 | 0 |
| SuiteEvidence | 5 | 5 | 5 | 0 |
| ProcessLevelFaults | 5 | 5 | 5 | 0 |
| **Overall** | **180** | **180** | **180** | **0** |

Subtotal check: 11+24+4+15+102 = 156 (pure+node) + 14+5+5 = 24 (R15) = 180. ✓

### Inventory classification (75ffd2c → 3ec02d2)

| Category | Count | Detail |
|----------|-------|--------|
| Unchanged retained | 175 | All existing tests except SuiteEvidence(5) |
| Replaced | 5 | SuiteEvidence (rewritten to use shared helper) |
| Added | 0 | — |
| Removed | 0 | — |
| **Total** | **180** | 175 + 5 = 180 ✓ |

### Process-level fault fixtures

| Fault | Exit | noSuccess | noTrusted | Structured | UNTRUSTED | Timeout |
|-------|------|-----------|-----------|------------|-----------|---------|
| MissingSuite | 3 | ✓ | ✓ | ✓ | ✓ | ✓ |
| DeclaredMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ |
| PassedMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ |
| FailedNonZero | 3 | ✓ | ✓ | ✓ | ✓ | ✓ |
| ManifestMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ |

### Fault subprocess output constraints (verified)
- No "All self-tests passed" banner
- No `N/N PASS` trusted totals
- No skipped-as-passed (ProcessLevelFaults not recorded)
- Has `SUITE-VALIDATION / ScriptInternal / FAIL`
- Has `UNTRUSTED / STRUCTURAL ERROR`
- Completed within 120s timeout

---

## 4. Side-Effect Proof
- No npm install, Harness, HTTP/WS, ports, credentials, or API keys
- All temp artifacts cleaned in `finally` blocks
- Process objects disposed in `finally`

---

## 5. Non-Actions
- Not merged PR #1
- Not marked Ready
- Not modified master
- Not entered Phase B or G0-S2
- Full PoC/Harness not run
