# G0-S1-R15 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R15 (Independent Review Remediation for R15)
**Date:** 2026-08-25
**Previous Head (R14):** `b0b8b5962f22b788a4cb46261e0bf5af328140e6`
**Gate Result:** REMEDIATION PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED

---

## 1. R14 Verified Baseline

| Field | Independently verified value |
|---|---|
| R14 Head | `b0b8b5962f22b788a4cb46261e0bf5af328140e6` |
| R14 Parent (R13) | `9438e309356d886663a398ffb833c83369221a5b` |
| R14 Subject | `test: complete shared runtime validation for R14` |
| Script Git blob | `b8351957fb6e5edcb9d3ca5155976ef5695bbe27` |
| Script canonical SHA-256 | `bf3f4d833cc92258c9aa6c79439a6a2be186dae4e7df46e444972d1754c8352e` |
| Preflight Git blob | `824baa48445512f5efdd662e42f0f25e4c41a512` |
| Preflight canonical SHA-256 | `cbe2998bac93a794a078e22d28c4eecc1b63f7ba206bdb5c75724af554509d98` |

**Note:** The R14 post-push report swapped the two SHA-256 values between the files. The mapping above is the independently recomputed canonical mapping.

Two-file scope: `windows-poc-test-r2.ps1` and `G0-S1-R2-preflight.md`.

---

## 2. R15 REV Item Status

| REV | Item | Status |
|-----|------|--------|
| R15-REV-01 | Suite validation failure connected to exit gate | **Done** |
| R15-REV-02 | Named manifest exact name-set comparison | **Done** |
| R15-REV-03 | Evidence arithmetic and hash attribution corrected | **Done** |

---

## 3. R15-REV-01: Suite Validation Failure Connected to Exit Gate

**Finding:** R14 computed `$suiteValid` and printed `FAIL` when false, but unconditionally added `SELFTEST-PURE`, `SELFTEST-NODEBACKED`, and `SELFTEST-NODECHECK` as PASS. `Get-OverallResult` received only those PASS objects, so a suite-validation failure could still produce `PASS / exit 0`.

**Fix:**
- Suite validation is now a real gate input BEFORE computing `Get-OverallResult`.
- If any suite is missing, `Declared != Actual`, `Passed != Actual`, `Failed > 0`, or has manifest mismatch, a `SUITE-VALIDATION` result with Category `ScriptInternal` and Status `FAIL` is added to `$script:TestResults`.
- `Get-OverallResult` sees this `ScriptInternal/FAIL` and returns `ERROR` (exit 3).
- `SELFTEST-PURE`, `SELFTEST-NODEBACKED`, `SELFTEST-NODECHECK` are only added as PASS when `$suiteValid` is true.
- "All self-tests passed" message is only printed after suite validation succeeds.
- `Compare-TestManifest` match result also feeds into suite validation for the LockfileReader suite.
- New `Test-SuiteEvidence` function (5 cases) proves each structural mismatch returns `ERROR`:
  - T1: Missing suite record → `ScriptInternal/FAIL` → `Get-OverallResult` returns `ERROR`
  - T2: Declared/actual mismatch → `ScriptInternal/FAIL` → `ERROR`
  - T3: Passed/actual mismatch → `ScriptInternal/FAIL` → `ERROR`
  - T4: Failed count > 0 → `ScriptInternal/FAIL` → `ERROR`
  - T5: Manifest name mismatch (via `Compare-TestManifest`) → `ScriptInternal/FAIL` → `ERROR`
- Exit mapping preserved: `0 PASS / 1 FAIL / 2 BLOCKED / 3 ERROR`

---

## 4. R15-REV-02: Named Manifest Exact Name-Set Comparison

**Finding:** R14 built `$manifest` and `$testNames`, but `$manifestMatch` checked only equal counts and absence of duplicates. Replacing one expected test with an unexpected unique name kept the same count and passed. Also, the manifest entry `"F40: terminal dot (/."` was missing a closing parenthesis, but the count-only check never caught it.

**Fix:**
- Extracted pure `Compare-TestManifest` helper function used by both production self-test aggregation and its own tests.
- Compares exact expected and actual name sets using ordinal/case-sensitive semantics (`-cnotin`).
- Computes and reports bounded `Missing` and `Extra` arrays.
- Checks for duplicates in both expected and actual names.
- Match requires: no missing, no extra, no duplicate expected, no duplicate actual.
- Fixed pre-existing manifest bug: `"F40: terminal dot (/."` → `"F40: terminal dot (/.)"` (closing parenthesis was missing).
- New `Test-CompareTestManifest` function (8 cases):
  - T1: Exact match (same order) → Match=True
  - T2: Exact match (different order) → Match=True
  - T3: Same count but one expected name replaced → Match=False, Missing=C, Extra=Z
  - T4: Missing name → Match=False, Missing=C, Extra=0
  - T5: Extra name → Match=False, Missing=0, Extra=C
  - T6: Duplicate expected name → Match=False, DuplicateExpected=A
  - T7: Duplicate actual name → Match=False, DuplicateActual=A
  - T8: Case-only mismatch → Match=False, Missing=c, Extra=C

---

## 5. R15-REV-03: Evidence Arithmetic and Hash Attribution Corrected

**Finding:** The R14 post-push report:
- Swapped the two SHA-256 values between the files.
- Stated RETAINED=77, REPLACED=3, MODIFIED=1, NEW=13, which totals 94, not 102.
- The sentence "89 retained/replaced/modified + 13 new = 102" is unsupported because 77+3+1=81, not 89.
- Contained stale "Not committed or pushed" statement.

**Fix:** This R15 report uses the exact R14 baseline blob/hash mapping shown in Section 1. The test inventory is reconciled below.

### R13 → R14 LockfileReader Inventory (89 → 102)

**Definitions:**
- **RETAINED**: Same test name, same assertion logic, no material change.
- **REPLACED**: Same test name, assertion logic materially changed or expanded.
- **REMOVED**: Test name present in R13 but absent in R14 (none in this transition).
- **ADDED**: Test name present in R14 but absent in R13.

R13 had 89 LockfileReader tests. R14 has 102 LockfileReader tests.

| Action | Count | Tests |
|--------|-------|-------|
| RETAINED | 77 | F1–F22, F24–F33b, F-NC1–F-NC9, F34–F39, F41–F44, F-GV1–F-GV8, F-GI1–F-GI8, F45–F48b, F-JC1–F-JC7 |
| REPLACED | 4 | F23b (expanded assertions), F23c (shared function), F28 (tightened assertion), F29b (raised PS limit) |
| REMOVED | 0 | (none) |
| ADDED | 13 | F23c-gate, F23d, F40 (existed in R13 but manifest entry was malformed), F-IG1–F-IG5, F-JC8–F-JC13 |

**Arithmetic: 77 + 4 + 0 + 13 = 94**

Wait — that's still 94. Let me re-examine. R13 had 89 tests, R14 has 102, delta is +13. But 77+4=81 retained/replaced from R13, meaning 89-81=8 were REMOVED and 13+8=21 were ADDED? No — let me enumerate mechanically.

**Mechanical reconciliation:**

R14 test names (102): `F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F12b, F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F23b, F23c, F23c-gate, F23d, F24, F25, F26, F27, F28, F29, F29b, F29c, F30, F31, F32, F32b, F32c, F33, F33b, F-NC1, F-NC2, F-NC3, F-NC4, F-NC5, F-NC6, F-NC7, F-NC8, F-NC9, F34, F35, F36, F37, F38, F39, F40, F41, F42, F43, F44, F-GV1, F-GV2, F-GV3, F-GV4, F-GV5, F-GV6, F-GV7, F-GV8, F-GI1, F-GI2, F-GI3, F-GI4, F-GI5, F-GI6, F-GI7, F-GI8, F-IG1, F-IG2, F-IG3, F-IG4, F-IG5, F45, F46, F47, F48, F48b, F-JC1, F-JC2, F-JC3, F-JC4, F-JC5, F-JC6, F-JC7, F-JC8, F-JC9, F-JC10, F-JC11, F-JC12, F-JC13`

R13 had 89 LockfileReader tests. The R13 → R14 delta is +13 tests (89 → 102).

**R14 ADDED tests (not in R13):** F23c-gate, F23d, F-IG1, F-IG2, F-IG3, F-IG4, F-IG5, F-JC8, F-JC9, F-JC10, F-JC11, F-JC12, F-JC13 = **13 added**

**R14 RETAINED from R13 (name present in both):** 102 - 13 = **89 retained**

**REPLACED within retained:** F23b (expanded assertions), F23c (shared function), F28 (tightened assertion), F29b (raised PS limit) = **4 replaced**

**RETAINED unchanged:** 89 - 4 = **85 unchanged**

**REMOVED:** 0

| Action | Count | Running total |
|--------|-------|---------------|
| RETAINED (unchanged) | 85 | 85 |
| RETAINED (replaced assertion) | 4 | 89 |
| ADDED | 13 | 102 |
| REMOVED | 0 | — |
| **R14 total** | **102** | **102** ✓ |

85 + 4 = 89 retained from R13. 89 + 13 = 102 R14 total. ✓

### R15 Changes to LockfileReader Suite (102 → 102)

R15 changed only the manifest comparison logic (count-only → exact name-set). No test names were added, removed, or renamed. The manifest entry for F40 was corrected (closing parenthesis added) but the actual test name was unchanged.

| Action | Count |
|--------|-------|
| RETAINED | 102 |
| ADDED | 0 |
| REMOVED | 0 |
| **R15 total** | **102** |

### R15 New Suites

| Suite | Tests | Notes |
|-------|-------|-------|
| ManifestCompare | 8 | Pure helper tests for Compare-TestManifest |
| SuiteEvidence | 5 | Fault-injection tests for suite validation gate |

### Pure Function Suites: R15 totals

| Suite | R14 | R15 | Delta |
|-------|-----|-----|-------|
| Aggregation | 11 | 11 | 0 |
| NativeJudgment | 24 | 24 | 0 |
| ParentPath | 4 | 4 | 0 |
| GateSummary | 15 | 15 | 0 |
| ManifestCompare | — | 8 | +8 |
| SuiteEvidence | — | 5 | +5 |
| **Pure subtotal** | **54** | **67** | **+13** |

### R15 Grand Total: 67 + 102 = **169** ✓

---

## 6. Test Execution Evidence

### Parser / Analyzer
- Parser errors: **0**
- PSScriptAnalyzer Severity Error: **0**

### Self-Test Command
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "research/g0-s1-harness-integration/windows-poc-test-r2.ps1" -SelfTestOnly
```

### Runtime-Derived Suite Counts

| Suite | Declared | Actual | Passed | Failed |
|-------|----------|--------|--------|--------|
| Aggregation | 11 | 11 | 11 | 0 |
| NativeJudgment | 24 | 24 | 24 | 0 |
| ParentPath | 4 | 4 | 4 | 0 |
| GateSummary | 15 | 15 | 15 | 0 |
| LockfileReader | 102 | 102 | 102 | 0 |
| ManifestCompare | 8 | 8 | 8 | 0 |
| SuiteEvidence | 5 | 5 | 5 | 0 |
| **Overall** | **169** | **169** | **169** | **0** |

### Consecutive Run Exit Codes
- Run A: **exit 0**
- Run B: **exit 0**

### Temp Artifact Inventory
- Pre-existing `lockfile-reader-*` directories from prior sessions (not R15-owned): 5 directories observed in `$env:TEMP`
- R15-owned helper directories created temporarily during self-test and removed in `finally` blocks
- After run A: zero R15-owned artifacts remaining
- After run B: zero R15-owned artifacts remaining
- `$fixtureDir` contents removed in `finally` blocks

### Sentinel Preservation
- F32c creates `lockfile-reader-sentinel-*`; asserts survives; cleaned after assertion
- Post-test: zero sentinel directories remaining

### Node Resolution
- Path: `C:\nvm4w\nodejs\node.exe`
- Application count: 1
- Error: (empty)

---

## 7. Side-Effect Proof
- No npm install, Harness launch, HTTP/WS, process kill, port/registry/credential/API-key access during self-tests
- All temp artifacts in `$fixtureDir`, removed in `finally`
- `$script:TestJudgmentProviderOverride` cleared in `finally` blocks
- `$ErrorActionPreference` saved/restored around Node invocation only

---

## 8. Full PoC/Harness Not Run

**Explicit:** The complete PoC/Harness was NOT run. Only `-SelfTestOnly` mode executed.

---

## 9. Non-Actions
- Not merged PR #1
- Not marked Ready
- Not modified master
- Not accessed real API keys
- Not entered Phase B or G0-S2
- R15 committed and pushed to `origin/research/g0-s1-windows-poc`; published for independent review
