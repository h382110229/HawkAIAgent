# G0-S1-R13 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R13 (Independent Review Remediation)
**Date:** 2026-08-25
**Previous Head (R12):** `c040ab3c59ed1e26974a1c5ca9f6cb1595d39fd5`
**Gate Result:** REMEDIATION PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED

---

## 1. R12 Verified Baseline

| Field | Value |
|---|---|
| R12 Head | `c040ab3c59ed1e26974a1c5ca9f6cb1595d39fd5` |
| R12 Parent | `c8cc541942a3961046736a7b76d53d7bb27dcbd0` |
| R12 Subject | `test: add SelfTestOnly mode, fail-closed mapping, and consolidate evidence for R12` |
| Script blob | `c7435837fdc8b31cad4bdb9152eebe691e02a2eb` |
| Script SHA-256 | `a84ee6b31be92e73be8fe259fda6890e34c28e70be3aa98a4705581808842a8b` |
| Preflight blob | `302b4df7b29e2a8bd6edc41048d4b7a30cc54ddf` |
| Preflight SHA-256 | `d0bb1d86f342f11cbc40182dc1562c23e3fad8f0c4f0773d4dfa79dd51b5d7db` |

Two-file scope: `windows-poc-test-r2.ps1` and `G0-S1-R2-preflight.md`.

---

## 2. R12-REV-01: Node shadowing blocks resolution

**Finding:** `Resolve-NodeExecutable` filtered to Application but accepted the path when non-Application candidates (alias/function/script/cmdlet) coexisted.

**Fix:**
- Extracted pure `Test-NodeCandidateValidation` function operating on a pre-built candidate list (no ambient PATH dependency).
- `Resolve-NodeExecutable` now calls `Test-NodeCandidateValidation`.
- Any non-Application candidate in the candidate list blocks resolution with `Path = $null` and a bounded error.
- Removed Warning field; non-Application presence is now an error, not a warning.

**New tests (9):** F-NC1 through F-NC9 covering missing Node, nonexistent path, directory path, multiple Applications, alias+app shadowing, function-only, cmdlet-only, script+app shadowing, and single valid Application acceptance.

---

## 3. R12-REV-02: Complete path grammar validation

**Finding:** Both PS and Node `canonicalize()` used a prefix-only regex for node_modules paths. `node_modules/pkg/arbitrary` could pass.

**Fix:**
- PS `ConvertFrom-LockfilePathPolicy`: regex now anchored with `$` — `^node_modules/(?:@[^/]+/[^/]+|[^@/][^/]*)(?:/node_modules/(?:@[^/]+/[^/]+|[^@/][^/]*))*$`
- Node `canonicalize()`: matching regex (backslash-doubled for PS here-string).
- Alternation `(?:@[^/]+/[^/]+|[^@/][^/]*)` rejects bare `@scope` as a package name (scoped packages must have `@scope/pkg`).
- Non-node_modules paths (workspace paths) still pass all existing rejection checks.

**New tests (16):** F-GV1–F-GV8 (valid: root, unscoped, scoped, nested, scoped-nested, deeply nested, same-name, space in name) and F-GI1–F-GI8 (invalid: arbitrary suffix, arbitrary suffix after scoped, incomplete scope at depth, bare node_modules/, nested bare, trailing after deep, scoped without pkg at root, double scope).

---

## 4. R12-REV-03: Ownership-safe cleanup recovery

**Finding:** F32 used wildcard `lockfile-reader-*` enumeration to find and delete leaked directories, risking deletion of unrelated processes' directories.

**Fix:**
- `ConvertFrom-LockfileSafe` exposes `_HelperDir` in its result when `$script:SelfTestMode = $true`.
- F32 uses the exact owned helper directory path for cleanup.
- Validates the path starts with the expected temp prefix before deletion.
- F32b asserts the owned directory was recovered.
- F32c creates a sentinel `lockfile-reader-sentinel-*` directory before F32 and asserts it survives afterward.
- Failed recovery fails the test (not just a warning).

---

## 5. R12-REV-04: Judgment cardinality and field validation

**Finding:** F45–F47 varied matching dependency counts but didn't force `Get-NativeAddonJudgment` to return 0/1/N judgments. F48 accepted absence when fail-closed requires a blocked entry.

**Fix:**
- Added `$script:TestJudgmentProviderOverride` (script-level variable, PS 5.1 compatible).
- `ConvertFrom-TransitiveMapping` checks the override when `$script:SelfTestMode = $true`.
- Override is cleared in `finally` blocks to prevent cross-contamination.
- Provider exceptions produce structured blocked entries (not silent omission).
- PS 5.1 scalar unwrapping fix: `$rawJudgments = if (...) {...} else {...}; $judgments = @($rawJudgments)`.

**New tests (9):** F48b (IsNative=false must produce blocked entry), F-JC1 (0 judgments → blocked), F-JC2 (N judgments → blocked), F-JC3 (null Name → blocked), F-JC4 (invalid ResolutionStatus → blocked), F-JC5 (null IsNative → blocked), F-JC6 (null PlatformApplicable → blocked), F-JC7 (null ParentOptional → blocked). All assert exact instance path, ResolutionStatus=Blocked, nonempty BlockReason.

---

## 6. R12-REV-05: Shared installed-instance resolution

**Finding:** F23 manually built instance-result objects and only asserted `-ne FAIL`.

**Fix:**
- Extracted `ConvertFrom-MappingToInstanceResult` shared function (deterministic, no side effects).
- Both Test 6 and F23 use this function.
- F23 asserts exact Status=PASS, Category=Informational for platform-not-applicable case.
- F23b asserts exact instance fields (Name, ResolutionStatus, PlatformApplicable, IsNative).
- F23c proves no-match dep produces empty mapping (no dependency-name fallback).

---

## 7. R12-REV-06: Bounded I/O branch evidence

**Finding:** F28 accepted any nonempty short error; F29 only tested PS-side input size limit.

**Fix:**
- F28 now asserts the explicit bounded-stderr/size-limit branch (`-match "exceeds|Stderr diagnostic|cleanup|exception"`).
- F29b creates a sparse file >50 MiB using `[System.IO.File]::SetLength()` and verifies Node's independent `statSync` check rejects it.
- F29c tests malformed intermediate JSON via custom Node script.

---

## 8. R12-REV-07: Runtime-derived counts

**Finding:** SelfTestOnly totals and PASS values were hard-coded. Main header said "40 cases" while suite asserted 51.

**Fix:**
- Added `$script:SelfTestSuiteResults` collector hashtable.
- Each of the 5 suite functions records `{Declared, Actual, Passed}` in the collector before returning.
- LockfileReader expected count is now `$tests.Count` (runtime-derived, not hardcoded).
- SelfTestOnly section computes and displays totals from the collector.
- Fixed "40 cases" heading, "7 self-tests" stale reference.

---

## 9. R12-REV-08: Preflight replaced

This document replaces the R12 preflight. All claims below are backed by runtime evidence.

---

## 10. Test Execution Evidence

### Parser Check
```
powershell.exe -NoProfile -Command '[System.Management.Automation.Language.Parser]::ParseFile("path", [ref]$null, [ref]$errors); "Errors: $($errors.Count)"'
```
**Result:** 0 errors

### PSScriptAnalyzer
```
Invoke-ScriptAnalyzer -Path "path" -Severity Error
```
**Result:** 0 errors

### Self-Test Command
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "research/g0-s1-harness-integration/windows-poc-test-r2.ps1" -SelfTestOnly
```

### Runtime-Derived Suite Counts (from `$script:SelfTestSuiteResults`)

| Suite | Declared | Actual | Passed | Failed |
|-------|----------|--------|--------|--------|
| Aggregation (Get-OverallResult) | 11 | 11 | 11 | 0 |
| Native Judgment (Get-NativeAddonJudgment) | 24 | 24 | 24 | 0 |
| Parent Resolver (Resolve-LockfileParentPath) | 4 | 4 | 4 | 0 |
| Gate Summary (Get-NativeGateSummary) | 15 | 15 | 15 | 0 |
| Lockfile Reader (Test-LockfileReader) | 89 | 89 | 89 | 0 |
| **Overall** | **143** | **143** | **143** | **0** |

### Consecutive Run Exit Codes
- Run A: exit 0
- Run B: exit 0

### Temp Artifact Inventory
- Before self-test: 5 stale `lockfile-reader-*` directories from previous sessions (Aug 24), excluded from R13 ownership
- R13-owned helper directories were created temporarily during each self-test run and successfully removed by test cleanup and `finally` blocks
- After self-test run A: zero R13-owned helper artifacts remaining; pre-existing directories preserved
- After self-test run B: zero R13-owned helper artifacts remaining; pre-existing directories preserved
- No R13-owned `lockfile-test-fixtures-*` artifacts remaining
- All `$fixtureDir` contents removed in `finally` blocks

### Sentinel Preservation
- F32c creates `lockfile-reader-sentinel-*` before F32 cleanup-failure test
- F32c asserts sentinel survives (no wildcard deletion)
- Sentinel cleaned up after assertion

### Node Resolution
- `Get-Command node -All`: Found 1 Application
- Resolved path: `C:\nvm4w\nodejs\node.exe`
- Path exists: yes
- Is file: yes
- Error: (empty)

### Self-Test Gate Results

| TestId | Category | Status | Description |
|--------|----------|--------|-------------|
| SELFTEST-PURE | MandatoryFunctional | PASS | Pure-function self-tests (54/54) |
| SELFTEST-NODEBACKED | MandatoryFunctional | PASS | Node-backed self-tests (89/89) |
| SELFTEST-NODECHECK | EvidenceDependent | PASS | Node executable resolution |

---

## 11. Newly Added Test Inventory

### REV-01: Node candidate validation (9 tests)
F-NC1 (no candidates), F-NC2 (nonexistent path), F-NC3 (directory path), F-NC4 (multiple Applications), F-NC5 (alias+app), F-NC6 (function only), F-NC7 (cmdlet only), F-NC8 (script+app), F-NC9 (single valid Application)

### REV-02: Path grammar (16 tests)
F-GV1–F-GV8 (valid paths: root, unscoped, scoped, nested, scoped-nested, deeply nested, same-name, space)
F-GI1–F-GI8 (invalid paths: arbitrary suffix, scoped suffix, incomplete scope at depth, bare node_modules/, nested bare, trailing, scoped without pkg, double scope)

### REV-03: Cleanup ownership (2 tests)
F32b (owned helper dir recovered), F32c (sentinel preserved)

### REV-04: Judgment cardinality (9 tests)
F48b (IsNative=false blocked entry), F-JC1 (0 judgments), F-JC2 (N judgments), F-JC3–F-JC7 (null/invalid fields)

### REV-05: Shared function (3 tests)
F23 (exact PASS/Informational), F23b (exact instance fields), F23c (no-match empty mapping)

### REV-06: Bounded I/O (2 tests)
F29b (Node 50MiB sparse file), F29c (malformed intermediate JSON)

Total new tests: 41 (from 51 to 89 in LockfileReader suite, plus the existing 54 pure-function tests = 143 total)

---

## 12. Allowlist Functions (24)

1. PrerequisiteBlocked
2. AssertionFailure
3. Add-TestResult
4. Get-OverallResult
5. Resolve-LockfileParentPath
6. Get-NativeGateSummary
7. Test-HasKey
8. ConvertFrom-LockfilePathPolicy
9. ConvertFrom-LockfileSafe
10. Get-NativeAddonJudgment
11. ConvertFrom-TransitiveMapping
12. Test-NodeCandidateValidation (NEW — R12-REV-01)
13. Resolve-NodeExecutable
14. ConvertFrom-MappingToInstanceResult (NEW — R12-REV-05)
15. Read-BoundedFile
16. Test-NativeAddonJudgment
17. Test-LockfileReader
18. Test-ResolveLockfileParentPath
19. Test-NativeGateSummary
20. Test-GetOverallResult
21. Save-ProcessSnapshot
22. Update-OwnedProcessRecords
23. Stop-OwnedProcesses
24. Invoke-Cleanup

---

## 13. Side-Effect Proof

- No npm install during self-tests
- No Harness launch (no `$TEST_PORT`, no `Start-Process`)
- No HTTP/WS traffic
- No process kill
- No port/registry/credential/API-key access
- All temp artifacts created in `$fixtureDir` and removed in `finally` blocks
- F32 cleanup-failure artifact recovered via exact owned path
- F29b sparse file cleaned up in `finally` block
- `$script:TestJudgmentProviderOverride` cleared in `finally` blocks
- Actual process exit code captured externally (exit 0, twice)

---

## 14. Full PoC/Harness Not Run

**Explicit statement:** The complete PoC/Harness was NOT run in R13. Only the `-SelfTestOnly` mode was executed. No npm install, Harness launch, HTTP requests, WebSocket connections, process management, port operations, or external API calls occurred.

---

## 15. Non-Actions

- Not merged PR #1
- Not marked Ready for review
- Not modified master
- Not accessed real API keys
- Not entered Phase B
- Not entered G0-S2
