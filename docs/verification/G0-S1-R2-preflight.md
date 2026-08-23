# G0-S1-R3-R3-R3 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R3-R3-R3 (Cleanup and Native Dependency Gate Alignment)
**Date:** 2026-08-23
**Previous Head:** `ac7a9b3d21626af32484be2e2f51d788eceb9ffc`
**Gate Result:** REMEDIATION COMPLETE — pending Windows 11 x64 execution

---

## 1. Finding 1: IdentityBlocked Semantics

**Finding:** `Invoke-Cleanup` treated IdentityBlocked as `CleanupError/FAIL` + `FatalInternalError`, producing `ERROR (exit 3)` instead of gate-blocking `BLOCKED (exit 2)`.

**Fix:**
- IdentityBlocked → `MandatoryFunctional` category, status `BLOCKED`
- Does NOT set `$script:FatalInternalError`
- Does NOT add to `$script:CleanupErrors`
- Gate aggregation: IdentityBlocked → `BLOCKED` (exit 2) unless higher-priority FAIL/ERROR exists
- Kill failure remains `CleanupError/FAIL` → `ERROR` (exit 3)

**Truth Table:**

| Scenario | Exit Code | Priority |
|----------|-----------|----------|
| Script internal exception | 3 (ERROR) | Highest |
| CleanupError FAIL (Kill failure) | 3 (ERROR) | High |
| IdentityBlocked (identity unconfirmed) | 2 (BLOCKED) | Medium |
| Gate-blocking FAIL | 1 (FAIL) | Medium |
| All Gate-blocking PASS | 0 (PASS) | Lowest |

---

## 2. Finding 2: Test 18 Structured Result Consumption

**Finding:** Test 18 relied on `$afterKill` with only CreationDate check, didn't consume `Stop-OwnedProcesses` structured results.

**Fix:**
- Full identity check: CreationDate + CommandLine + ExecutablePath
- `Failed.Count > 0` → Test 18 `FAIL`
- `IdentityBlocked.Count > 0` (no FAIL) → Test 18 `BLOCKED`
- `$afterKill.Count > 0` (identity confirmed, still alive) → Test 18 `FAIL`
- All terminated/exited → Test 18 `PASS`

**Test 18 Branch Matrix:**

| Condition | Result |
|-----------|--------|
| Kill/WaitForExit failure | FAIL |
| Identity unconfirmed (still running) | BLOCKED |
| Identity confirmed but survived | FAIL |
| All terminated or exited | PASS |
| No owned processes running | PASS |

---

## 3. Finding 3: Native Addon Platform/Optional Split

**Finding:** Single `IsOptional` conflated platform applicability with parent dependency optionality. `os: ["!darwin"]` incorrectly treated as "not for Windows".

**Fix:**
- Split into `PlatformApplicable` (os/cpu allow/deny) and `ParentOptional` (lockfile `optional` + parent `optionalDependencies` edge)
- Parent entry lookup via lockfile path parsing (handles nested `node_modules/<parent>/node_modules/<dep>`)
- Gate determination:
  - Required + platform-applicable + missing → `EvidenceDependent BLOCKED`
  - Required + platform-applicable + load-fail → `EvidenceDependent FAIL`
  - Optional or platform-n/a → `Informational` (never blocks Gate)

**os/cpu Judgment Cases:**

| os value | win32 result | Notes |
|----------|-------------|-------|
| `["win32"]` | Allowed | Explicit allowlist |
| `["!darwin"]` | Allowed | Denylist doesn't deny win32 |
| `["!win32"]` | Denied | Denylist denies win32 |
| `["linux"]` | Denied | Allowlist, win32 not in it |
| `[]` or missing | Allowed | Default allow |

| cpu value | x64 result |
|-----------|-----------|
| `["x64"]` | Allowed |
| `["!arm"]` | Allowed |
| `["!x64"]` | Denied |
| `[]` or missing | Allowed |

**Self-Test Coverage:**
- `[win32]` → PlatformApplicable=true
- `[!darwin]` → PlatformApplicable=true
- `[!win32]` → PlatformApplicable=false
- `[linux]` → PlatformApplicable=false
- Empty/missing → PlatformApplicable=true
- Parent optionalDependencies edge → ParentOptional=true
- Lockfile `optional: true` → ParentOptional=true
- Nested path parsing → correct parent lookup

---

## 4. Aggregation Self-Test

Expanded from 7 to 10 cases. New cases:

| # | Scenario | Expected |
|---|----------|----------|
| 8 | IdentityBlocked in MandatoryFunctional | BLOCKED/2 |
| 9 | CleanupError FAIL | ERROR/3 |
| 10 | Kill fail + IdentityBlocked | ERROR/3 |

---

## 5. Script SHA-256

`7af0ea733812caaad9b047219f1f6541fca0d8ed220dd79182eef2007716f985`

---

## 6. Static Analysis Summary

| Check | Result |
|-------|--------|
| IdentityBlocked not CleanupError | PASS |
| IdentityBlocked as MandatoryFunctional | PASS |
| Has r8 self-test | PASS |
| Has PlatformApplicable | PASS |
| Has ParentOptional | PASS |
| Has platformApplicable variable | PASS |
| Has parentOptional variable | PASS |
| No IsOptional in foundNative | PASS |
| Lowercase `$pid` | 0 occurrences |
| PowerShell parser | PENDING WINDOWS HERMES PHASE A |
| PSScriptAnalyzer | PENDING WINDOWS HERMES PHASE A |
| Aggregation runtime | PENDING WINDOWS HERMES PHASE A |
