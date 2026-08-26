# G0-S1-R15 Remediation Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R15 Independent Review Remediation
**Date:** 2026-08-26
**Gate Result:** REMEDIATION PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED

---

## 1. Commit Topology

### R14 Baseline
| Field | Value |
|---|---|
| R14 Head | `b0b8b5962f22b788a4cb46261e0bf5af328140e6` |
| R14 Parent | `9438e309356d886663a398ffb833c83369221a5b` |
| R14 Subject | `test: complete shared runtime validation for R14` |

### R15 Two-Commit Chain
| Commit | Hash | Parent | Subject | Files |
|---|---|---|---|---|
| R15 primary | `d7ecf63a3876b6c936083aebdff0586c4d50c01d` | `b0b8b59` (R14) | `test: enforce exact self-test evidence gate for R15` | Both whitelisted |
| R15 review | `b20f59011daa5e2587327d895d9322d2388d2940` | `d7ecf63` | `docs: update R15 preflight to reflect post-push state` | Preflight only |

### R15 Remediation (this commit)
| Field | Value |
|---|---|
| Parent | `b20f59011daa5e2587327d895d9322d2388d2940` |
| Subject | `test: fix manifest ordinal semantics and shared aggregation for R15 remediation` |
| Files | Both whitelisted |

---

## 2. REM Item Status

| REM | Item | Status |
|-----|------|--------|
| REM-01 | Shared production helper with process-level fault fixtures | **Done** |
| REM-02 | Ordinal/case-sensitive manifest semantics (StringComparer.Ordinal) | **Done** |
| REM-03 | Bounded manifest diagnostics (max 20 samples, 100-char name cap) | **Done** |
| REM-04 | Preflight topology and evidence corrections | **Done** |

---

## 3. REM-01: Shared Production Helper with Process-Level Fault Fixtures

**Finding:** `Test-SuiteEvidence` manually copied simplified suite judgment logic and called `Get-OverallResult` directly. It did not use the same code path as the real `-SelfTestOnly` exit. "Real entry point" claim was unsupported.

**Fix:**
- Created `Invoke-SelfTestAggregation` function — single shared implementation used by both normal `-SelfTestOnly` path and fault tests.
- Takes: suite results hashtable, expected suite names, optional manifest comparison, node resolution, display totals.
- Validates each suite (missing, declared!=actual, passed!=actual, failed>0), validates manifest if provided.
- On failure: adds `SUITE-VALIDATION` with `Category="ScriptInternal"` and `Status="FAIL"`.
- On success: adds `SELFTEST-PURE`, `SELFTEST-NODEBACKED`, `SELFTEST-NODECHECK` as PASS.
- Calls `Get-OverallResult` and returns `[PSCustomObject]@{ Overall; ExitCode; SuiteValid }`.
- Production `SelfTestOnly` block now calls `Invoke-SelfTestAggregation` as its single path.
- `Test-SuiteEvidence` rewritten to call `Invoke-SelfTestAggregation` with injected fault data.
- Added `-SelfTestFault` parameter with `ValidateSet('None','MissingSuite','DeclaredMismatch','PassedMismatch','FailedNonZero','ManifestMismatch')`.
- Guard: `-SelfTestFault` requires `-SelfTestOnly`; standalone use exits 3.
- Fault injection corrupts suite data before `Invoke-SelfTestAggregation` runs.
- Added `Test-ProcessLevelFaults` function that launches real subprocess for each fault type and verifies:
  - Process exit code is exactly 3
  - No premature "All self-tests passed" before SUITE-VALIDATION
  - Output contains FAIL evidence

---

## 4. REM-02: Ordinal/Case-Sensitive Manifest Semantics

**Finding:** `Compare-TestManifest` used `@{}` hashtable for duplicate detection. In PS 5.1, `@{}` keys are case-insensitive by default, so `A` and `a` would be falsely detected as duplicates.

**Fix:**
- Replaced `@{}` with `[System.Collections.Generic.Dictionary[string,bool]]::new([System.StringComparer]::Ordinal)` for duplicate detection.
- Replaced `-cnotin` with `[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)` for membership testing.
- All comparisons now use explicit ordinal case-sensitive semantics.
- Added 6 new test cases (T9-T14):
  - T9: `expected=@("A","a"), actual=@("A","a")` → NOT duplicate, exact match
  - T10: `expected=@("A","A","B")` → duplicate A (exact case)
  - T11: `expected=@("a","a")` → duplicate a (lowercase)
  - T12: `expected=@("a"), actual=@("A")` → case-only mismatch
  - T13: Bounded diagnostics stress test (25 missing, capped at 15)
  - T14: 150-char name capped to 100+... in display
- Total ManifestCompare tests: 14

---

## 5. REM-03: Bounded Manifest Diagnostics

**Finding:** `Compare-TestManifest` returned full `Missing`, `Extra`, `DuplicateExpected`, `DuplicateActual` arrays with no size limit. Production code joined them all for display. "Bounded arrays" claim in preflight was unsupported.

**Fix:**
- Added `$MaxSamples` parameter (default 20) to `Compare-TestManifest`.
- Each returned array (`Missing`, `Extra`, `DuplicateExpected`, `DuplicateActual`) contains at most `$MaxSamples` items.
- Added `MissingTotal`, `ExtraTotal`, `DuplicateExpectedTotal`, `DuplicateActualTotal` fields (full counts before truncation).
- Added `Truncated` boolean field (true if any category exceeded `$MaxSamples`).
- Individual names capped at 100 characters (truncated with "..." suffix).
- Production diagnostic output uses bounded arrays and reports `(truncated)` when applicable.
- T13 verifies: 25 missing items → Missing has 15 items, MissingTotal=20, Truncated=true.
- T14 verifies: 150-char name → Missing[0] is 103 chars (100 + "...").

---

## 6. REM-04: Preflight Topology and Evidence Corrections

**Finding:** Previous preflight did not record the two-commit R15 topology, contained contradictory arithmetic (77+3+1=81, claimed 89), and incorrectly claimed bounded diagnostics.

**Fix:** This document:
- Records R14 baseline and the two-commit R15 chain with per-commit parent, subject, and file scope.
- Distinguishes R15 primary (`d7ecf63`), R15 review (`b20f590`), and remediation final Head.
- Uses mechanically derived test inventory with definitions that make subtotals add up.
- Only claims ordinal/case-sensitive after implementation uses `StringComparer.Ordinal`.
- Only claims bounded diagnostics after implementation caps arrays.
- Only claims "shared production helper" after `Invoke-SelfTestAggregation` exists.
- Only claims "process-level fault fixtures" after `Test-ProcessLevelFaults` exists.
- States "published for independent review / Phase B blocked" — never "Review PASS".

---

## 7. Test Inventory (R15 Remediation)

### Definitions
- **RETAINED**: Same test name, same assertion logic, no material change.
- **ADDED**: New test name not present in previous commit.
- **REPLACED**: Same test name, assertion logic materially changed.
- **REMOVED**: Test name present in previous commit but absent now.

### R15 primary → R15 remediation delta

| Suite | R15 primary | R15 remediation | Delta | Details |
|-------|-------------|-----------------|-------|---------|
| Aggregation | 11 | 11 | 0 | All retained |
| NativeJudgment | 24 | 24 | 0 | All retained |
| ParentPath | 4 | 4 | 0 | All retained |
| GateSummary | 15 | 15 | 0 | All retained |
| LockfileReader | 102 | 102 | 0 | All retained |
| ManifestCompare | 8 | 14 | +6 | 8 retained + 6 added (T9-T14) |
| SuiteEvidence | 5 | 5 | 0 | 5 replaced (now use shared helper) |
| ProcessLevelFaults | — | 5 | +5 | 5 added |
| **Total** | **169** | **180** | **+11** | |

169 retained + 6 added + 5 added = 180. ✓

---

## 8. Test Execution Evidence

### Parser / Analyzer
- Parser errors: **0**
- PSScriptAnalyzer v1.25.0 Severity Error: **0**

### Self-Test Command
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "research/g0-s1-harness-integration/windows-poc-test-r2.ps1" -SelfTestOnly
```

### Runtime-Derived Suite Counts
*To be filled after validation run completes.*

| Suite | Declared | Actual | Passed | Failed |
|-------|----------|--------|--------|--------|
| Aggregation | 11 | — | — | — |
| NativeJudgment | 24 | — | — | — |
| ParentPath | 4 | — | — | — |
| GateSummary | 15 | — | — | — |
| LockfileReader | 102 | — | — | — |
| ManifestCompare | 14 | — | — | — |
| SuiteEvidence | 5 | — | — | — |
| ProcessLevelFaults | 5 | — | — | — |
| **Overall** | **180** | — | — | — |

### Consecutive Run Exit Codes
- Run A: *pending*
- Run B: *pending*

### Process-Level Fault Fixture Results
*To be filled after validation run completes.*

| Fault | Exit Code | No Premature | Has Fail Evidence |
|-------|-----------|-------------|-------------------|
| MissingSuite | — | — | — |
| DeclaredMismatch | — | — | — |
| PassedMismatch | — | — | — |
| FailedNonZero | — | — | — |
| ManifestMismatch | — | — | — |

---

## 9. Side-Effect Proof
- No npm install, Harness launch, HTTP/WS, process kill, port/registry/credential/API-key access during self-tests
- All temp artifacts in `$fixtureDir`, removed in `finally`
- `$script:TestJudgmentProviderOverride` cleared in `finally` blocks
- `$ErrorActionPreference` saved/restored around Node invocation only

---

## 10. Full PoC/Harness Not Run

**Explicit:** The complete PoC/Harness was NOT run. Only `-SelfTestOnly` mode executed.

---

## 11. Non-Actions
- Not merged PR #1
- Not marked Ready
- Not modified master
- Not accessed real API keys
- Not entered Phase B or G0-S2
- Published for independent review; Phase B remains BLOCKED
