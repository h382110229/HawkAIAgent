# G0-S1-R3-R3-R4 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R3-R3-R4 (Cleanup and Native Dependency Gate Alignment)
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
- Case 9: CleanupError FAIL → ERROR
- Case 10: Kill fail (CleanupError) + IdentityBlocked → ERROR
- Case 11: Kill fail (gate) + IdentityBlocked → FAIL (new R4-01)

---

## 2. Finding R4-02: Native Judgment Pure Function

**Finding:** Native addon platform/optional judgment was inline in Test 6, not extractable or independently testable.

**Fix:**
- Extracted `Get-NativeAddonJudgment` pure function (no side-effects, no I/O)
- Extracted `Test-NativeAddonJudgment` runtime self-test (10 cases)
- Self-test runs BEFORE npm install / Harness launch
- Failure → ScriptInternal ERROR (exit 3)

**Pure Function Coverage:**
- os: `win32`, `!darwin`, `!win32`, `linux`, empty/missing
- cpu: `x64`, `!arm`, `!x64`, empty/missing
- Root-level, nested, scoped parent, parent `optionalDependencies` edge
- Same-name native dep at different paths with different properties
- All optional/platform-n/a and missing → Informational

**Runtime Self-Test Cases:**
1. Native no os/cpu → applicable
2. `os=!win32` → not applicable
3. `os=[win32]` → applicable
4. `os=[linux]` no win32 → not applicable
5. `cpu=!x64` → not applicable
6. `optional=true` → parentOptional
7. Parent `optionalDependencies` → parentOptional
8. Non-native → !isNative, applicable, !optional
9. Missing PkgData → defaults
10. `os=!darwin` on win32 → applicable

---

## 3. Finding R4-03: Per-Instance Initialization

**Finding:** Variables could leak between found-directory instances via empty catch blocks.

**Fix:**
- Each found-directory instance initializes `PlatformApplicable`, `ParentOptional`, and resolution state fresh
- package.json/lockfile parse failure or mapping not unique → EvidenceDependent BLOCKED with instance path and reason
- No empty catch blocks that reuse previous instance variables

---

## 4. Finding R4-04: Lockfile Instance Model

**Finding:** `$transitiveNativeExpected` used dep name as key, overwriting when same dep exists at multiple lockfile paths.

**Fix:**
- Key changed to normalized lockfile package path (e.g. `node_modules/@parent/node_modules/dep`)
- Supports root packages key `""`, nested parent, scoped parent
- Installation directory maps to lockfile instance; unresolvable → BLOCKED
- `PlatformApplicable` and `ParentOptional` independently stored per instance

---

## 5. Finding R4-05: Test 18 Complete Identity

**Finding:** Test 18 survivor check compared CreationDate, CommandLine, ExecutablePath but not ParentProcessId.

**Fix:**
- Full identity comparison: PID, CreationDate, CommandLine, ExecutablePath, ParentProcessId (when available)
- Identity unconfirmed → BLOCKED, no kill
- `$ppidOk` added to survivor check: `(-not $record.ParentPID) -or (-not $cim.ParentProcessId) -or ([int]$cim.ParentProcessId -eq $record.ParentPID)`

---

## 6. Aggregation Self-Test Summary

11 test cases (expanded from 7). R4-01 added Case 11: kill failure as gate-blocking FAIL + IdentityBlocked → FAIL.

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
| Has Test-NativeAddonJudgment self-test | PASS |
| Per-instance PlatformApplicable init | PASS |
| Per-instance ParentOptional init | PASS |
| Lockfile key by normalized path | PASS |
| Test 18 ParentProcessId check | PASS |
| Lowercase `$pid` | 0 occurrences |
| PowerShell parser | PENDING WINDOWS HERMES PHASE A |
| PSScriptAnalyzer | PENDING WINDOWS HERMES PHASE A |
| Aggregation runtime | PENDING WINDOWS HERMES PHASE A |
| Native judgment runtime | PENDING WINDOWS HERMES PHASE A |
