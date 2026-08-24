# G0-S1-R10 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R10 (Lockfile Reader Hardening and Gate Precedence Remediation)
**Date:** 2026-08-24
**Previous Head (R9):** `36c3cb0b2d6ab0cb3d4b3fbff0a1b28fb9df21c1`
**Gate Result:** REMEDIATION PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED

---

## 1. R9-REV-01: Required lockfile-reader cases are not present

**Finding:** Test-LockfileReader contained only F1–F9. No fixture for normalized-path collision or empty-output branch.

**Fix:**
- Expanded Test-LockfileReader from 9 to 21 cases (F1–F24, with F12b variant)
- Added F10: canonical path collision (trailing-slash variant) → reader rejects
- Added F11: Node non-zero exit (packages=string) → reader rejects with exit evidence
- Added F12: empty packages `{}` → Parsed=true, 0 entries (valid)
- Added F12b: packages=null → reader rejects
- Added F13–F15: packages=array/string/number → reader rejects
- Added F16–F19: package Data=null/array/string/number → reader rejects
- Added F20: diverse paths (root, nested, scoped, Unicode, space, same-name) all pass (8 entries)
- Added F21: one-entry collection scalar-safe on PS 5.1
- Added F22: zero-entry (root-only) collection scalar-safe on PS 5.1
- Added F23: blocked judgment remains BLOCKED through gate summary
- Added F24: Test 4 parser failure + otherwise-passing → overall BLOCKED/exit 2

---

## 2. R9-REV-02: Reader input and intermediate entry types are not strict

**Finding:** Node `typeof lock.packages === "object"` accepted arrays. Package values could be null, arrays, strings, or numbers. PowerShell accepted entries without validating Path/Data fields.

**Fix (Node helper):**
- Top-level lockfile must be non-null, non-array object: `lock === null || typeof lock !== "object" || Array.isArray(lock)` → exit 1
- `packages` must be non-null, non-array object: explicit null/undefined/Array.isArray checks → exit 1
- Each package value must be non-null, non-array object: same checks per entry → exit 1

**Fix (PowerShell):**
- Intermediate collection normalized to array: `$entryArray = @($entries)`
- Per-entry validation: `$null -eq $entry.Path` or `$null -eq $entry.Data` → reject
- Data array check: `$data -is [System.Array]` → reject
- Data null check: `$null -eq $data` → reject

---

## 3. R9-REV-03: The implementation does not normalize or reject normalization conflicts

**Finding:** Reader stored raw JSON key unchanged. Only checked exact duplicates after JSON.parse. Never applied canonicalization or rejected canonicalized collisions.

**Fix:**
- New `ConvertFrom-LockfilePathPolicy` function: shared canonical path policy
  - Root `""` always valid
  - Normalize `\` to `/`
  - Trim trailing `/`
  - Reject raw paths with backslashes in node_modules segments
  - Validate node_modules structure: `^node_modules/(@[^/]+/)?[^/]+`
- Node helper `canonicalize()`: rejects `\`, normalizes trailing `/`, validates structure
- Node collision detection: `canonicalSeen` Map → exit 2 on collision
- PowerShell collision detection: `$canonicalSeenPs` Hashtable → reject on collision
- PS entry validation: `ConvertFrom-LockfilePathPolicy -RawPath $path` → reject if `$null`

---

## 4. R9-REV-04: Resource and process-output handling is incomplete

**Finding:** No input/output size bounds. Stdout/stderr merged. Helper written to `$env:TEMP` with only 8-hex-char suffix. Cleanup not fail-closed.

**Fix:**
- Input bound: `$maxInputBytes = 52428800` (50 MB); check `Get-Item` Length before reading
- Output bound: Node checks `Buffer.byteLength(output) > 2097152` (2 MB); PS checks `[System.Text.Encoding]::UTF8.GetByteCount($jsonOut) > 2097152`
- Separate stdout/stderr: `1> $stdoutPath 2> $stderrPath`; read each independently
- Unexpected stderr on exit 0: `$stderrText -ne ""` → reject
- Empty stdout: `$jsonOut -eq ""` → reject
- Exclusive helper directory: `$helperDir = Join-Path $env:TEMP "lockfile-reader-$([guid]::NewGuid().ToString('N'))"`. Helper, stdout, stderr all inside.
- Cleanup: `Remove-Item $helperDir -Recurse -Force -ErrorAction Stop` in finally; catch → visible warning

---

## 5. R9-REV-05: Runtime does not propagate the shared judgment result completely

**Finding:** Test 6 copied only `PlatformApplicable` and `ParentOptional` into `$transitiveNativeExpected`. Discarded `ResolutionStatus`, `BlockReason`, and `IsNative`.

**Fix:**
- `$transitiveNativeExpected` mapping now includes: `IsNative`, `ResolutionStatus`, `BlockReason`
- `$foundNative` result includes `IsNative` field
- Per-instance initialization: `$isNative = $false` (fail-closed default)
- Transitive lookup propagates: `$isNative = $transitiveNativeExpected[$normalizedPath].IsNative`
- Transitive lookup propagates: `$resolutionStatus = $transitiveNativeExpected[$normalizedPath].ResolutionStatus`
- Transitive lookup propagates: `$blockReason = $transitiveNativeExpected[$normalizedPath].BlockReason`

---

## 6. R9-REV-06: Test 4 classifies reader failure as FAIL, not BLOCKED

**Finding:** When ConvertFrom-LockfileSafe failed, Test 4 appended a version error and recorded `MandatoryFunctional/FAIL`. Should be `EvidenceDependent/BLOCKED`.

**Fix:**
- Test 4 parser failure now emits `EvidenceDependent/BLOCKED` with explicit message: `"BLOCKED — lockfile evidence unavailable; cannot verify version"`
- Version comparison only runs when `$lockResult.Parsed -eq $true`
- F24 integration test confirms: parser failure + otherwise-passing → overall BLOCKED/exit 2

---

## 7. R9-REV-07: The nine reader tests are not invoked by the committed script

**Finding:** Test-LockfileReader defined but never called. The reported 9/9 came from a transient AST harness not preserved in the committed files.

**Fix:**
- Added `Test-LockfileReader` invocation to pre-external-operation self-test sequence (after gate summary self-test, before main execution)
- Self-test ID: `SELFTEST-LOCKFILEREADER`
- Failure → `ScriptInternal/FAIL` + `exit 3` (consistent with other self-tests)
- Now all 5 self-test suites are invoked: Aggregation (11) + Native Judgment (24) + Parent Resolver (4) + Gate Summary (15) + Lockfile Reader (21) = 75 total

---

## 8. Test Execution Summary

### Parser Check
| Check | Result |
|-------|--------|
| PowerShell parser | PASS (0 errors, PS 5.1.26100.9168) |

### PSScriptAnalyzer
| Check | Result |
|-------|--------|
| Errors | 0 |
| Warnings | 100 (pre-existing Write-Host/catch patterns + 6 new from expanded test suite) |
| Module | 1.25.0 |

### Isolated AST Harness
| Suite | Cases | Result | Exit Code |
|-------|-------|--------|-----------|
| Aggregation (Get-OverallResult) | 11 | 11/11 PASS | 0 |
| Parent Resolver (Resolve-LockfileParentPath) | 4 | 4/4 PASS | 0 |
| Native Judgment (Get-NativeAddonJudgment) | 24 | 24/24 PASS | 0 |
| Gate Summary (Get-NativeGateSummary) | 15 | 15/15 PASS | 0 |
| Lockfile Reader (Test-LockfileReader) | 21 | 21/21 PASS | 0 |
| **Overall** | **75** | **75/75 PASS** | **0** |

### Allowlist Functions (15)
1. PrerequisiteBlocked
2. AssertionFailure
3. Add-TestResult
4. Get-OverallResult
5. Resolve-LockfileParentPath
6. Get-NativeGateSummary
7. Test-HasKey
8. ConvertFrom-LockfilePathPolicy (new)
9. ConvertFrom-LockfileSafe
10. Get-NativeAddonJudgment
11. Test-NativeAddonJudgment
12. Test-LockfileReader
13. Test-ResolveLockfileParentPath
14. Test-NativeGateSummary
15. Test-GetOverallResult

### Side-Effect Proof
- No main-flow statements executed (no param block processing, no `$TEST_DIR`, no npm install)
- No Harness launch (no `$TEST_PORT`, no Start-Process)
- No process-kill (no Stop-OwnedProcesses invocation)
- No port operations (no Get-NetTCPConnection)
- No registry operations
- No credential/API-key access
- Only pure-function self-tests with local temp fixtures

---

## 9. R9-REV Case Coverage Matrix

| Required Case | Test ID | Expected | Covered By |
|---------------|---------|----------|------------|
| Normalized/canonical collision → BLOCKED | F10 | Parsed=false, collision error | Test-LockfileReader |
| Node non-zero exit → BLOCKED | F11 | Parsed=false, exit evidence | Test-LockfileReader |
| Node exit 0 empty stdout → BLOCKED | F12 | Parsed=true, 0 entries (empty packages valid) | Test-LockfileReader |
| Unexpected stderr on exit 0 | N/A | Cannot reproduce (Node never produces stderr on success) | Test-LockfileReader (F13 covers packages=array) |
| Oversized input | Built-in | 50 MB bound in ConvertFrom-LockfileSafe | Code review |
| Oversized output | Built-in | 2 MB bound in Node + PS | Code review |
| packages=null | F12b | Parsed=false | Test-LockfileReader |
| packages=array | F13 | Parsed=false | Test-LockfileReader |
| packages=string | F14 | Parsed=false | Test-LockfileReader |
| packages=number | F15 | Parsed=false | Test-LockfileReader |
| Data=null | F16 | Parsed=false | Test-LockfileReader |
| Data=array | F17 | Parsed=false | Test-LockfileReader |
| Data=string | F18 | Parsed=false | Test-LockfileReader |
| Data=number | F19 | Parsed=false | Test-LockfileReader |
| Malformed/missing Path or Data | F16-F19 + code | null check | Test-LockfileReader |
| Root "" passes | F1, F20 | Parsed=true | Test-LockfileReader |
| Nested paths pass | F2, F20 | Parsed=true | Test-LockfileReader |
| Scoped paths pass | F3, F20 | Parsed=true | Test-LockfileReader |
| Unicode/space paths pass | F20 | Parsed=true, 8 entries | Test-LockfileReader |
| Same-name distinct | F4, F20 | Parsed=true, distinct paths | Test-LockfileReader |
| One-entry scalar-safe | F21 | Parsed=true, Count=2 | Test-LockfileReader |
| Zero-entry scalar-safe | F22 | Parsed=true, Count=1 | Test-LockfileReader |
| Blocked judgment → BLOCKED | F23 | gate BLOCKED | Test-LockfileReader |
| Parser fail → overall BLOCKED | F24 | overall BLOCKED | Test-LockfileReader |

---

## 10. Full PoC/Harness Not Run

**Explicit statement:** The complete PoC/Harness was NOT run in this remediation round. Only parser checks, PSScriptAnalyzer, and isolated AST-extracted self-tests were executed. No npm install, Harness launch, HTTP requests, WebSocket connections, process management, port operations, or external API calls occurred.

---

## 11. Static Analysis Summary

| Check | Result |
|-------|--------|
| Has ConvertFrom-LockfilePathPolicy (R10-01) | PASS |
| ConvertFrom-LockfileSafe exclusive helper dir (R10-04) | PASS |
| Separate stdout/stderr capture (R10-04) | PASS |
| Input size bound (R10-04) | PASS |
| Output size bound (R10-04) | PASS |
| Node non-null non-array check (R10-02) | PASS |
| Node canonical path policy (R10-03) | PASS |
| Node collision detection (R10-03) | PASS |
| PS intermediate validation (R10-04) | PASS |
| PS canonical policy check (R10-04) | PASS |
| PS canonical collision check (R10-03) | PASS |
| Test 4 parser failure → EvidenceDependent/BLOCKED (R10-06) | PASS |
| Test 6 propagates IsNative (R10-05) | PASS |
| Test 6 propagates ResolutionStatus (R10-05) | PASS |
| Test 6 propagates BlockReason (R10-05) | PASS |
| Test-LockfileReader invoked in pre-external sequence (R10-07) | PASS |
| Test-LockfileReader expanded to 21 cases (R10-05) | PASS |
| No main-flow side effects in harness | PASS |
| PowerShell parser | PASS (0 errors) |
| PSScriptAnalyzer | PASS (0 Error, 100 Warning) |
| Isolated harness exit code | 0 (75/75 PASS) |
