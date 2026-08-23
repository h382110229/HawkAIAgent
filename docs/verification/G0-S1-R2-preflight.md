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

## 8. Static Analysis Summary

| Check | Result |
|-------|--------|
| IdentityBlocked not CleanupError | PASS |
| IdentityBlocked as MandatoryFunctional | PASS |
| Kill failure as MandatoryFunctional FAIL | PASS |
| Has Get-NativeAddonJudgment pure function | PASS |
| Has Test-NativeAddonJudgment self-test (18 cases) | PASS |
| Per-instance PlatformApplicable init | PASS |
| Per-instance ParentOptional init | PASS |
| Lockfile key by normalized path | PASS |
| Test 18 ParentProcessId check (fail-closed) | PASS |
| Stop-OwnedProcesses ParentPID check | PASS |
| Orphan check ParentPID match | PASS |
| Native judgment self-test called before main | PASS |
| Get-NativeAddonJudgment per-instance ParentPath | PASS |
| ResolutionStatus/BlockReason in results | PASS |
| Lowercase `$pid` | 0 occurrences |
| PowerShell parser | PENDING WINDOWS HERMES PHASE A |
| PSScriptAnalyzer | PENDING WINDOWS HERMES PHASE A |
| Aggregation runtime | PENDING WINDOWS HERMES PHASE A |
| Native judgment runtime | PENDING WINDOWS HERMES PHASE A |
