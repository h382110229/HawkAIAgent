# G0-S1-R3-R3-R4-R5 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R3-R3-R4-R5 (Cleanup and Native Dependency Gate Alignment)
**Date:** 2026-08-23
**Previous Head:** `6dc559bca4c3ab7116a1630ae42417592b696a63`
**Gate Result:** REMEDIATION COMPLETE — pending Windows 11 x64 execution

---

## 1. Finding R4-01: Aggregation Semantics

**Finding:** Kill/Wait failure was treated as `CleanupError/FAIL` → `ERROR` (exit 3), but should be gate-blocking `FAIL` (exit 1). IdentityBlocked correctly handled as `BLOCKED` (exit 2).

**Fix:**
- Kill/Wait failure → `MandatoryFunctional` category, status `FAIL` → gate-blocking FAIL (exit 1)
- IdentityBlocked → `MandatoryFunctional` category, status `BLOCKED` → exit 2, never kill
- Script internal / cleanup framework exception → `CleanupError` + `FatalInternalError` → ERROR (exit 3)
- Test 18 and finally cleanup produce consistent final states

**Truth Table:**

| Scenario | Exit Code | Priority |
|----------|-----------|----------|
| Script internal / framework exception | 3 (ERROR) | Highest |
| Kill/Wait failure (identity confirmed) | 1 (FAIL) | High |
| IdentityBlocked (identity unconfirmed) | 2 (BLOCKED) | Medium |
| Gate-blocking assertion FAIL | 1 (FAIL) | Medium |
| All Gate-blocking PASS | 0 (PASS) | Lowest |
| Kill fail + IdentityBlocked | 1 (FAIL) | Fail takes priority |

**Self-Test Cases (11 total):**
- Case 1: All PASS + Info FAIL → PASS
- Case 2: EvidenceDependent BLOCKED → BLOCKED
- Case 3: MandatoryFunctional FAIL → FAIL
- Case 4: FAIL + BLOCKED → FAIL
- Case 5: Fatal internal error → ERROR
- Case 6: Cleanup fatal error → ERROR
- Case 7: No Gate-blocking → ERROR
- Case 8: IdentityBlocked → BLOCKED
- Case 9: Script exception (CleanupError) → ERROR (R5-06: clarified from "Kill failure")
- Case 10: Script exception + IdentityBlocked → ERROR (R5-06: clarified priority)
- Case 11: Kill fail (gate) + IdentityBlocked → FAIL (R4-01)

---

## 2. Finding R4-02 + R5-02 + R5-03: Native Judgment Pure Function

**Finding:** Native addon platform/optional judgment was inline in Test 6, not extractable or independently testable.

**R5-02 Fix:**
- Expanded from 10 to 18 self-test cases
- Added: `cpu=x64`, `cpu=!arm`, empty/missing cpu, empty/missing os
- Added: root parent (lockfile packages key `""`), nested parent, scoped parent
- Added: same-name native dep at two different instance paths with different parent optional/platform properties
- Added: all optional/platform-n/a and not installed → Informational
- Added: mapping missing, mapping ambiguous → BLOCKED

**R5-03 Fix:**
- `Get-NativeAddonJudgment` now accepts per-instance `ParentPath` instead of scanning all lockfile packages
- Each `DependencyMap` item carries `InstancePath` and `ParentPath`
- Only queries the exact parent for that instance — never scans all packages
- Results include `ResolutionStatus` and `BlockReason` fields

**Pure Function Coverage:**
- os: `win32`, `!darwin`, `!win32`, `linux`, empty/missing
- cpu: `x64`, `!arm`, `!x64`, empty/missing
- Root-level, nested, scoped parent, parent `optionalDependencies` edge
- Same-name native dep at different paths with different properties
- All optional/platform-n/a and missing → Informational
- Missing package data → BLOCKED

**Runtime Self-Test Cases (18 total):**
1. Native no os/cpu → applicable, Resolved
2. `os=!win32` → not applicable, Resolved
3. `os=[win32]` → applicable
4. `os=[linux]` no win32 → not applicable
5. `cpu=!x64` → not applicable
6. `cpu=[x64]` → applicable
7. `cpu=!arm` on x64 → applicable (denylist doesn't hit)
8. empty os → applicable (default allow)
9. empty cpu → applicable (default allow)
10. `optional=true` → parentOptional
11. root parent optDep → parentOptional
12. nested parent optDep → parentOptional
13. scoped parent optDep → parentOptional
14. non-native → !isNative, applicable, !optional
15. missing PkgData → BLOCKED
16. `os=!darwin` on win32 → applicable
17. same-name different paths → independent judgment (no cross-contamination)
18. `os=!win32` `cpu=!arm` → not applicable (both deny)

---

## 3. Finding R4-03 + R5-04: Per-Instance Initialization

**Finding:** Variables could leak between found-directory instances via empty catch blocks.

**R4-03 Fix:**
- Each found-directory instance initializes `PlatformApplicable`, `ParentOptional`, and resolution state fresh
- package.json/lockfile parse failure or mapping not unique → EvidenceDependent BLOCKED with instance path and reason
- No empty catch blocks that reuse previous instance variables

**R5-04 Fix (fail-closed per-instance):**
- `Get-NativeAddonJudgment`: per-instance initialization with fail-closed defaults (`ResolutionStatus = "Unresolved"`, `ParentOptional = $false`)
- Missing package data → BLOCKED (not defaults)
- `ResolutionStatus` and `BlockReason` fields added to results
- Test 6 runtime loop: removed depName fallback for lockfile mapping (exact path only)
- Parse failure or missing package.json → BLOCKED (not silently skipped)

---

## 4. Finding R4-04: Lockfile Instance Model

**Finding:** `$transitiveNativeExpected` used dep name as key, overwriting when same dep exists at multiple lockfile paths.

**Fix:**
- Key changed to normalized lockfile package path (e.g. `node_modules/@parent/node_modules/dep`)
- Supports root packages key `""`, nested parent, scoped parent
- Installation directory maps to lockfile instance; unresolvable → BLOCKED
- `PlatformApplicable` and `ParentOptional` independently stored per instance

---

## 5. Finding R4-05 + R5-05: Test 18 Complete Identity

**Finding:** Test 18 survivor check compared CreationDate, CommandLine, ExecutablePath but not ParentProcessId.

**R4-05 Fix:**
- Full identity comparison: PID, CreationDate, CommandLine, ExecutablePath, ParentProcessId (when available)
- Identity unconfirmed → BLOCKED, no kill
- `$ppidOk` added to survivor check

**R5-05 Fix (fail-closed ParentPID):**
- `Stop-OwnedProcesses`: Added ParentPID identity check — exact equality, fail-closed
- Test 18 `$ppidOk` logic: changed from fail-open to fail-closed (both must be present and equal; either missing → BLOCKED)
- Orphan check in `Invoke-Cleanup`: added `$ppidMatch` with fail-closed logic
- Previous fail-open: `(-not $record.ParentPID) -or (-not $cim.ParentProcessId) -or ([int]$cim.ParentProcessId -eq $record.ParentPID)`
- New fail-closed: both must be present AND equal; either missing → identity unconfirmed

---

## 5b. Finding R5-01: Native Judgment Self-Test in Main Execution

**Finding:** `Test-NativeAddonJudgment` existed but was never called in the main execution path.

**Fix:**
- Added call to `Test-NativeAddonJudgment` BEFORE `$cleanupLog` initialization (before any external operations)
- Failure → ScriptInternal ERROR (exit 3) with `SELFTEST-NATIVE` test ID
- Updated aggregation self-test header from "7 cases implemented" to "11 cases" (reflecting actual count)

---

## 6. Aggregation Self-Test Summary

11 test cases (expanded from 7). R4-01 added Case 11: kill failure as gate-blocking FAIL + IdentityBlocked → FAIL.

R5-06: Cases 9 and 10 clarified — CleanupError FAIL is script exception (NOT kill failure), takes priority over IdentityBlocked.

---

## 7. Script SHA-256

**Previous:** `7af0ea733812caaad9b047219f1f6541fca0d8ed220dd79182eef2007716f985`
**Current:** PENDING — compute after commit

---

## 8. Finding R6: Native Gate Fail-Closed Remediation

### R6-01: Blocked Resolution State Enters Gate

**Finding:** Test 6 could report PASS when native instances had unresolved/blocked resolution status, because `require()` success was checked before resolution status.

**Fix:**
- ResolutionStatus and BlockReason determined BEFORE load test
- `foundNative` results now include ResolutionStatus and BlockReason fields
- Gate determination delegated to `Get-NativeGateSummary` pure function
- Any instance with ResolutionStatus ≠ "Resolved" → gate BLOCKED
- Unresolved/Blocked/missing/ambiguous mapping → gate-blocking BLOCKED

### R6-02: Lockfile Parsing Fail-Closed

**Finding:** Lockfile parsing used empty `catch {}` block, silently swallowing errors.

**Fix:**
- Explicit `$lockfileParsed` boolean and `$lockfileParseError` string
- Three failure modes tracked: file not found, JSON parse error, packages key missing
- Lockfile not parsed → ALL instances BLOCKED (even if no native dirs found)
- Lockfile not parsed + no instances → EvidenceDependent BLOCKED (not Informational/PASS)
- No empty catch blocks in lockfile parsing path

### R6-03: Single Parent Path Resolution Implementation

**Finding:** Parent path resolution logic was inline in both `Get-NativeAddonJudgment` and Test 6 runtime, with inconsistent implementations.

**Fix:**
- Extracted `Resolve-LockfileParentPath` pure function (line 110)
- Single implementation used by: `Get-NativeAddonJudgment`, Test 6 runtime, self-tests
- Self-test covers 4 cases: root, nested, scoped, deeply nested
- Self-test runs BEFORE harness startup; failure → ERROR/3

### R6-04: Native Gate Summary Pure Function

**Finding:** Gate determination logic was inline in Test 6, not independently testable.

**Fix:**
- Extracted `Get-NativeGateSummary` pure function (line 129)
- 7 self-test cases covering all gate outcomes:
  1. Required resolved + loaded → PASS
  2. Required load failure → FAIL
  3. Blocked instance (even if load succeeded) → BLOCKED
  4. Lockfile not parsed → BLOCKED
  5. All optional/platform-n/a → Informational PASS
  6. Mixed blocked/resolved → BLOCKED
  7. Empty instance list → Informational PASS
- Self-test runs BEFORE harness startup; failure → ERROR/3
- Does NOT break existing R5 aggregation self-test (11 cases)

### R6-05: Security Invariants Preserved

- PID, CreationDate, CommandLine, ExecutablePath, ParentProcessId identity checks unchanged
- No process-name batch termination or wide taskkill introduced
- No lowercase `$pid` reintroduced
- BFS ownership model preserved

### R6-06: Documentation Updated

This section and the static analysis table updated to reflect R6 changes.

---

## 9. Native Gate Truth Table

| Lockfile Parsed | Instance Status | Load Result | Gate Outcome |
|-----------------|-----------------|-------------|---------------|
| No | any | any | BLOCKED |
| Yes | Blocked/Unresolved | any | BLOCKED |
| Yes | Resolved + required | success | PASS |
| Yes | Resolved + required | failure | FAIL |
| Yes | Resolved + optional/n-a | failure | Informational PASS |
| Yes | Resolved + optional/n-a | success | Informational PASS |
| Yes | mixed Blocked + Resolved | any | FAIL if required load failure present, else BLOCKED (R8-01) |
| Yes | no instances | — | Informational PASS |

---

## 10. Static Analysis Summary

| Check | Result |
|-------|--------|
| IdentityBlocked not CleanupError | PASS |
| IdentityBlocked as MandatoryFunctional | PASS |
| Kill failure as MandatoryFunctional FAIL | PASS |
| Has Get-NativeAddonJudgment pure function | PASS |
| Has Test-NativeAddonJudgment self-test (24 cases, R8) | PASS |
| Has Resolve-LockfileParentPath pure function (R6-03) | PASS |
| Has Test-ResolveLockfileParentPath self-test (4 cases) | PASS |
| Has Get-NativeGateSummary pure function (R6-04) | PASS |
| Has Test-NativeGateSummary self-test (15 cases) | PASS |
| Resolve-LockfileParentPath self-test called before main | PASS |
| NativeGateSummary self-test called before main | PASS |
| Per-instance PlatformApplicable init | PASS |
| Per-instance ParentOptional init | PASS |
| Lockfile key by normalized path | PASS |
| Test 6 lockfile parse fail-closed (R6-02) | PASS |
| Test 6 ResolutionStatus/BlockReason in results (R6-01) | PASS |
| Test 6 uses Get-NativeGateSummary (R6-04) | PASS |
| Test 6 uses Resolve-LockfileParentPath (R6-03) | PASS |
| Test 18 ParentProcessId check (fail-closed) | PASS |
| Stop-OwnedProcesses ParentPID check | PASS |
| Orphan check ParentPID match | PASS |
| Native judgment self-test called before main | PASS |
| Get-NativeAddonJudgment per-instance ParentPath | PASS |
| ResolutionStatus/BlockReason in results | PASS |
| Lowercase `$pid` | 0 occurrences |
| Empty catch in lockfile parsing | 0 (removed) |
| PowerShell parser | PASS (0 errors, PS 5.1.26100.9168) |
| PSScriptAnalyzer | PASS (0 Error, 94 Warning, module 1.24.0) |
| Aggregation runtime | PASS (11/11, R8) |
| Native judgment runtime | PASS (24/24, R8) |
| Resolve-LockfileParentPath runtime | PASS (4/4 cases, isolated AST harness) |
| NativeGateSummary runtime | PASS (15/15, R8) |

---

## 11. R7 Remediation: PowerShell 5.1 Scalar Safety

**Date:** 2026-08-24
**Trigger:** ChatGPT Phase A review identified that PS 5.1 pipeline unwrapping is a runtime risk, not a test-only artifact. When `Where-Object` returns exactly 1 item, the result is a bare `PSCustomObject` (not an array). Calling `.Count` on it returns `$null`, causing `$null -gt 0` → `False`, which can incorrectly skip FAIL/BLOCKED branches.

### R7-01: Pipeline Collection Normalization

All `Where-Object` results in `Get-NativeGateSummary` and `Get-OverallResult` wrapped with `@()`:
- `$blockedInstances`, `$resolvedInstances`, `$requiredResolved`, `$optionalOrNaResolved`, `$requiredLoadFailures`, `$requiredLoaded`, `$optionalLoadFailures`
- `$scriptInternalResults`, `$gateBlocking`, `$hasFail`, `$hasBlocked`

### R7-02: Representation-Agnostic Key Lookup

New `Test-HasKey` pure function: accepts `IDictionary/Hashtable` via `ContainsKey()` and `PSCustomObject` via `PSObject.Properties`. Replaces direct `.PSObject.Properties[$key]` lookups in:
- `Get-NativeAddonJudgment` optional dependency check (line ~320)
- `Get-NativeAddonJudgment` native indicator check (line ~278)

`$LockfilePackages` parameter changed from `[hashtable]` to untyped `$LockfilePackages` to accept both representations. Indexer `[$key]` replaced with `.$key` for PSCustomObject compatibility.

### R7-03: Test Fixture Dual Representation

C11-C13 (optionalDependencies lookup) now tested with both:
- **Hashtable** (`@{ ... }`) — original representation
- **PSCustomObject** (`ConvertFrom-Json`) — runtime representation from lockfile parsing

Root parent case (ParentPath="") uses `$pkgData.optional` by design (empty string is falsy in `if ($parentPath -and ...)`).

### R7-04: PS 5.1 Regression Test Cases

8 new cases added to `Test-NativeGateSummary` (T8–T15):
- T8: 0 blocked → PASS
- T9: bare PSCustomObject blocked → BLOCKED
- T10: 2 blocked → BLOCKED
- T11: bare 1 load failure → FAIL
- T12: bare 1 loaded → PASS
- T13: 1 FAIL + 1 BLOCKED → BLOCKED (priority)
- T14: bare optional n/a → Informational PASS
- T15: bare Unresolved → BLOCKED

### R7-05: Self-Test Results

| Suite | Cases | Result | Exit Code |
|-------|-------|--------|-----------|
| Aggregation (Get-OverallResult) | 11 | 11/11 PASS | 0 |
| Parent Resolver (Resolve-LockfileParentPath) | 4 | 4/4 PASS | 0 |
| Native Judgment (Get-NativeAddonJudgment) | 24 | 24/24 PASS | 0 |
| Gate Summary (Get-NativeGateSummary) | 15 | 15/15 PASS | 0 |
| **Overall** | **54** | **54/54 PASS** | **0** |

**PowerShell version:** 5.1.26100.9168
**Harness method:** AST-extracted allowlist (no dot-source, no full script execution)

### R7-06: Key Risks Documented

- PS 5.1 single-item pipeline unwrapping is a **runtime risk**, not test-only. Any `Where-Object` returning 0/1 items produces a bare object, not an array. `.Count` on bare `PSCustomObject` returns `$null`.
- `ConvertFrom-Json` produces `PSCustomObject`, not `Hashtable`. Code using `.ContainsKey()` or `[$key]` indexer on JSON output will fail. `Test-HasKey` and `.$key` property access resolve this.
- No complete PoC or Harness was executed. Only pure-function isolated self-tests were run.

---

## 12. R8 Remediation: Gate Precedence and Runtime Scalar Safety

**Date:** 2026-08-24
**Trigger:** ChatGPT review identified gate precedence mismatch, remaining unwrapped pipeline, and root parent falsy skip.

### R8-01: Unified Gate Precedence FAIL > BLOCKED

`Get-NativeGateSummary` previously checked BLOCKED before FAIL. When both a required load failure and an unresolved instance exist, the BLOCKED result masked the definitive FAIL.

**Fix:** Reordered to check `$requiredLoadFailures` (FAIL) first, then `$blockedInstances` (BLOCKED). T13 updated: `1 FAIL + 1 BLOCKED → FAIL`.

### R8-02: Full Script Pipeline Audit

Audited all 27 pipeline assignments across the script:
- 11 already wrapped with `@()` (R7)
- 15 unwrapped but safe (boolean truthiness, `-join` string, `Select-Object -First 1` scalar)
- 1 needed fixing: `$candidateNodes` (L1650) — uses `.Count` on unwrapped `Where-Object` result

**Fix:** `$candidateNodes` wrapped with `@()`. All other unwrapped pipelines documented as safe.

### R8-03: Root Parent Empty-String Key Support

`if ($parentPath -and (Test-HasKey ...))` skipped the lookup when `$parentPath` was `""` (empty string is falsy in PowerShell). This prevented root optionalDependencies from being checked.

**Fix:** Changed to `if (Test-HasKey $LockfilePackages $parentPath)` — `Test-HasKey` handles empty string correctly for Hashtable (returns `$true` if key exists). PSCustomObject cannot have empty-string property names, so `Test-HasKey` returns `$false` gracefully.

**New test cases:**
- C11d: root optDep via Hashtable with `PkgData.optional=false` → `ParentOptional=true`
- C11e: root no-key via PSCustomObject → `ParentOptional` stays `$false` (graceful fallback)

### R8-04: Self-Test Coverage

| Suite | Cases | Result | Exit Code |
|-------|-------|--------|-----------|
| Aggregation | 11 | 11/11 PASS | 0 |
| Parent Resolver | 4 | 4/4 PASS | 0 |
| Native Judgment | 24 | 24/24 PASS | 0 |
| Gate Summary | 15 | 15/15 PASS | 0 |
| **Overall** | **54** | **54/54 PASS** | **0** |

**PowerShell:** 5.1.26100.9168
**Harness:** AST-extracted allowlist (no dot-source, no full script execution)
