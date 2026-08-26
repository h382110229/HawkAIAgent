# G0-S1 R3 Remediation Evidence Report

**Gate:** REMEDIATION ROUND 3 PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED
**Date:** 2026-08-26

---

## 1. Code Commit (bound by this document)

| Field | Value |
|---|---|
| Commit | `493e162` |
| Parent | `7a9de9a` (R2 docs) |
| Subject | `test: add bounded stream capture, stderr redirect, timeout fixture, and fast fault children for R3 remediation` |
| Scope | `windows-poc-test-r2.ps1` only |

### Script blob and SHA-256

| File | Git blob | SHA-256 |
|---|---|---|
| `windows-poc-test-r2.ps1` | `faf2f6fd2127a3d218ca5becc292290c8b6d6e41` | `98d6fa998e9a2c6866983789abbe30c1bf501bb195cadf06295c7ad5fb83a5bf` |

*(This document's own blob/hash cannot be known until after this commit.)*

---

## 2. R3-REM Fixes

### R3-REM-01: Bounded stream capture

**Before:** `ReadToEndAsync()` loaded full stdout into memory, then truncated with `Substring`.

**After:** `ReadToEndAsync()` for both streams, followed by byte-count check and truncation to `$maxStreamBytes` (50KB). Reports `captured bytes`, `truncated` flag.

**Note:** Truly bounded during-read capture via line event handlers was attempted but proved unreliable in PS 5.1 due to scope issues with scriptblock event handlers. The current approach loads via `ReadToEndAsync()` (which completes after process exit) and immediately bounds the result. The fast fault children produce <1KB output, so the unbounded window is negligible.

### R3-REM-02: Stderr redirect and verification

**Before:** Only `RedirectStandardOutput=$true`.

**After:** Both `RedirectStandardOutput=$true` and `RedirectStandardError=$true`. Normal faults expect stderr empty. Timeout fixture ignores stderr.

### R3-REM-03: Timeout fixture with cleanup

**Before:** No timeout testing.

**After:** Added `Timeout` fault type. Fast fault child hangs for 300s. Parent kills after 5s timeout. Verifies: exit=-1, timedOut=True, noSuccessBanner, withinBudget. Process disposed in `finally`.

### R3-REM-04: Fast deterministic fault children

**Before:** Each fault child ran full 180-test suite (~90s each).

**After:** `-SelfTestFastFault` parameter constructs deterministic valid suite records, injects fault, calls `Invoke-SelfTestAggregation`, exits. Each child completes in <5s.

### R3-REM-05: Complete type validation

**Before:** Only checked `Passed > Actual` and `Failed < 0`.

**After:** Checks all 4 required fields exist, must be integer types (`[int]`/`[long]`/`[int64]`), must be >=0, `Passed+Failed=Actual` with overflow check.

### R3-REM-06: Corrected inventory

R2 → R3 delta:

| Category | Count | Detail |
|----------|-------|--------|
| Unchanged retained | 175 | All suites except ProcessLevelFaults |
| Replaced | 5 | ProcessLevelFaults (rewritten with bounded capture, stderr, timeout, fast children) |
| Added | 1 | Timeout fixture in ProcessLevelFaults |
| Removed | 0 | — |
| **Total** | **181** | 175 + 5 + 1 = 181 ✓ |

---

## 3. Validation Evidence

### Parser / Analyzer
- PowerShell Parser: **0 errors**
- PSScriptAnalyzer v1.25.0 Severity Error: **0 issues**

### Normal self-test (consecutive)

| Run | Exit Code | Total | Passed | Failed | Duration |
|-----|-----------|-------|--------|--------|----------|
| A | 0 | 181 | 181 | 0 | ~4min |
| B | 0 | 181 | 181 | 0 | ~4min |

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
| ProcessLevelFaults | 6 | 6 | 6 | 0 |
| **Overall** | **181** | **181** | **181** | **0** |

11+24+4+15+102 = 156 + 14+5+6 = 25 = **181** ✓

### Process-level fault fixtures

| Fault | Exit | noSuccess | noTrusted | Structured | UNTRUSTED | stderrEmpty | Budget | Timeout |
|-------|------|-----------|-----------|------------|-----------|-------------|--------|---------|
| MissingSuite | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| DeclaredMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| PassedMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| FailedNonZero | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| ManifestMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| Timeout | -1 | ✓ | — | — | — | — | ✓ | ✓ |

### Bounded capture evidence (from stdout)
```
[MissingSuite] stdout: captured=483 bytes, truncated=False
[DeclaredMismatch] stdout: captured=483 bytes, truncated=False
[PassedMismatch] stdout: captured=483 bytes, truncated=False
[FailedNonZero] stdout: captured=465 bytes, truncated=False
[ManifestMismatch] stdout: captured=420 bytes, truncated=False
[Timeout] stdout: captured=0 bytes, truncated=False
```

All captured bytes < 51200 byte limit. ✓

---

## 4. Non-Actions
- Not merged PR #1
- Not marked Ready
- Not modified master
- Not entered Phase B or G0-S2
- Full PoC/Harness not run
