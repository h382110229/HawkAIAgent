# G0-S1-R12 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R12 (Self-Test Mode, Fail-Closed Mapping, and Evidence Consolidation)
**Date:** 2026-08-24
**Previous Head (R11):** `c8cc541942a3961046736a7b76d53d7bb27dcbd0`
**Gate Result:** REMEDIATION PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED

---

## 1. R11-REV-01: Preflight/evidence contradiction resolved

**Finding:** R11 committed preflight said F25–F39 were PENDING; returned report said they all PASS.

**Fix:** This R12 report is the single authoritative post-execution document. All test results below were captured from an actual `-SelfTestOnly` run against the committed R12 head. No PENDING entries remain.

---

## 2. R11-REV-02 / R11-REV-11: Self-test-only mode

**Finding:** Dot-sourcing the full script executes main flow. No safe standalone self-test route existed.

**Fix:** Added `-SelfTestOnly` switch parameter. When set:
1. Runs all pure-function self-tests (Aggregation, NativeJudgment, ParentPath, GateSummary)
2. Resolves Node executable with fail-closed checks
3. Runs Node-backed integration tests (LockfileReader)
4. Records gate-blocking PASS results for proper aggregation
5. Exits before Test 1, ports, npm, snapshots, process management, or Harness

**Command:**
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "path\to\windows-poc-test-r2.ps1" -SelfTestOnly
```

---

## 3. R11-REV-03: Test 6 uses shared transitive function

**Finding:** Test 6 contained its own inline loop calling `Get-NativeAddonJudgment` directly, duplicating `ConvertFrom-TransitiveMapping`.

**Fix:** Replaced the entire inline loop (50+ lines) with:
```powershell
$transitiveNativeExpected = ConvertFrom-TransitiveMapping `
  -LockfilePackages $lockfilePackages `
  -NativeDepsToCheck $nativeDepsToCheck `
  -TargetOs "win32" -TargetCpu "x64"
```

---

## 4. R11-REV-04: F23 exercises real shared runtime path

**Finding:** F23 constructed a synthetic blocked object and called `Get-NativeGateSummary` directly.

**Fix:** F23 now:
1. Creates a lockfile fixture with a native dep (`os: ["linux"]`, not applicable on win32)
2. Calls `ConvertFrom-LockfileSafe` to parse it
3. Calls `ConvertFrom-TransitiveMapping` with the parsed packages
4. Builds instance results from the mapping (simulating Test 6 runtime)
5. Calls `Get-NativeGateSummary` with those results
6. Verifies the gate result is not FAIL (PASS/Informational for platform-n/a)

---

## 5. R11-REV-05: Shared mapping is fail-closed

**Finding:** `ConvertFrom-TransitiveMapping` accepted `$judgments.Count -ge 1`, silently selected index 0, accepted IsNative=$false, did not validate fields.

**Fix:** Now requires:
- Exactly one judgment (Count -ne 1 → blocked entry)
- Valid Name (non-null/non-empty)
- Valid ResolutionStatus (in allowed set)
- BlockReason present when Blocked
- IsNative non-null and equal to `$true`
- PlatformApplicable and ParentOptional non-null
- Any invalid result → structured blocked mapping entry (not silent omission)

---

## 6. R11-REV-06: IsNative=$true required for native candidates

**Finding:** Inline Test 6 only rejected `IsNative=$null`; accepted `$false`.

**Fix:** Shared function now requires `IsNative -eq $true` for native candidates. `IsNative=$false` produces a blocked entry with reason "IsNative is not true".

---

## 7. R11-REV-07: Node ambiguity is fail-closed

**Finding:** `Resolve-NodeExecutable` set both Path and AMBIGUOUS error. `Get-Command` was called without `-All`.

**Fix:**
- Uses `Get-Command node -All` to detect all candidates
- Rejects aliases/functions/scripts (Application type only)
- Requires exactly one Application (multiple → AMBIGUOUS error, no Path set)
- Requires Error empty whenever Path is accepted
- Validates resolved path exists and is a file
- Reports shadowed non-Application commands as Warning
- Node gate check now requires `$nodeResolution.Error -eq ""`

---

## 8. R11-REV-08: Path validation is complete

**Finding:** Regexes were prefix-only; terminal `/.`, `/..`, incomplete scope not caught.

**Fix:** Added to both PS and Node `canonicalize()`:
- Reject terminal `/.` and `/..`
- Reject incomplete scoped packages (`node_modules/@scope` without package)
- Added test cases F40–F44 for these plus control characters

---

## 9. R11-REV-09: Cleanup-failure test artifact recovered

**Finding:** F32 with `-TestCleanupFail` leaked a helper directory; harness only cleaned `$fixtureDir`.

**Fix:** F32 now:
1. Records pre-existing `lockfile-reader-*` directories before the test
2. After the assertion, scans for new `lockfile-reader-*` directories
3. Removes any leaked directories
4. Asserts no helper directories remain

---

## 10. R11-REV-10: Test evidence strengthened

**Fixes:**
- F28: Asserts Parsed=false, error non-empty, error bounded (< 2000 chars)
- F33: Added F33b (Error empty on success) and F33c (Warning field exists)
- Added F45–F48: ConvertFrom-TransitiveMapping tests (0/1/N judgment, IsNative=false)
- Added runtime declared-vs-actual count assertions to ALL 5 suites
- Fixed Gate Summary heading from "7 cases" to "15 cases"
- Updated SelfTestOnly output with accurate counts

---

## 11. R11-REV-12: Test injection boundary guarded

**Finding:** Test injection parameters (`-TestCustomNodeScriptPath`, `-TestMaxInputBytes`, `-TestCleanupFail`) were exposed on the production reader without guards.

**Fix:**
- Added `$script:SelfTestMode = $false` script-level variable
- Set to `$true` before self-test execution, `$false` after
- `ConvertFrom-LockfileSafe` rejects test injection parameters when `$script:SelfTestMode` is `$false`
- Production calls (Test 4, Test 6) use default hardened path

---

## 12. Test Execution Evidence

### Self-Test Command
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\projects\HawkAIAgent\research\g0-s1-harness-integration\windows-poc-test-r2.ps1" -SelfTestOnly
```

### Parser Check
```
powershell.exe -Command '[System.Management.Automation.Language.Parser]::ParseFile("path", [ref]$null, [ref]$errors); "Errors: $($errors.Count)"'
```
**Result:** 0 errors

### PSScriptAnalyzer
```
Invoke-ScriptAnalyzer -Path "path" -Severity Error
```
**Result:** 0 errors

### Self-Test Results (exit 0)

| Suite | Declared | Actual | Result |
|-------|----------|--------|--------|
| Aggregation (Get-OverallResult) | 11 | 11 | 11/11 PASS |
| Native Judgment (Get-NativeAddonJudgment) | 24 | 24 | 24/24 PASS |
| Parent Resolver (Resolve-LockfileParentPath) | 4 | 4 | 4/4 PASS |
| Gate Summary (Get-NativeGateSummary) | 15 | 15 | 15/15 PASS |
| Lockfile Reader (Test-LockfileReader) | 51 | 51 | 51/51 PASS |
| **Overall** | **105** | **105** | **105/105 PASS (exit 0)** |

### Lockfile Reader Per-Case Results

| Test | Expected | Actual | Result |
|------|----------|--------|--------|
| F1: root key + optdep + required | Parsed=true, 3 entries | Parsed=true, 3 entries | ✅ PASS |
| F2: nested dependency | Parsed=true | Parsed=true | ✅ PASS |
| F3: scoped parent | Parsed=true | Parsed=true | ✅ PASS |
| F4: same-name different paths | Parsed=true, 5 entries | Parsed=true, 5 entries | ✅ PASS |
| F5: malformed JSON | Parsed=false | Parsed=false | ✅ PASS |
| F6: missing packages | Parsed=false | Parsed=false | ✅ PASS |
| F7: missing file | Parsed=false | Parsed=false | ✅ PASS |
| F8: root optDep via reader | ParentOptional=true | ParentOptional=true | ✅ PASS |
| F9: nested optDep via reader | ParentOptional=true | ParentOptional=true | ✅ PASS |
| F10: canonical collision | Parsed=false | Parsed=false | ✅ PASS |
| F11: non-obj packages | Parsed=false | Parsed=false | ✅ PASS |
| F12: empty packages | Parsed=true, 0 entries | Parsed=true, 0 entries | ✅ PASS |
| F12b: packages=null | Parsed=false | Parsed=false | ✅ PASS |
| F13: packages=array | Parsed=false | Parsed=false | ✅ PASS |
| F14: packages=string | Parsed=false | Parsed=false | ✅ PASS |
| F15: packages=number | Parsed=false | Parsed=false | ✅ PASS |
| F16: Data=null | Parsed=false | Parsed=false | ✅ PASS |
| F17: Data=array | Parsed=false | Parsed=false | ✅ PASS |
| F18: Data=string | Parsed=false | Parsed=false | ✅ PASS |
| F19: Data=number | Parsed=false | Parsed=false | ✅ PASS |
| F20: diverse paths (8 entries) | Parsed=true, Count=8 | Parsed=true, Count=8 | ✅ PASS |
| F21: one-entry scalar-safe | Parsed=true, Count=2 | Parsed=true, Count=2 | ✅ PASS |
| F22: root-only scalar-safe | Parsed=true, Count=1 | Parsed=true, Count=1 | ✅ PASS |
| F23: real shared path not FAIL | gate != FAIL | gate != FAIL | ✅ PASS |
| F24: parser fail → overall BLOCKED | BLOCKED | BLOCKED | ✅ PASS |
| F25: exit 0 + empty stdout | Parsed=false | Parsed=false | ✅ PASS |
| F26: exit 0 + stderr | Parsed=false | Parsed=false | ✅ PASS |
| F27: oversized stdout | Parsed=false | Parsed=false | ✅ PASS |
| F28: oversized stderr bounded | Parsed=false, error < 2000 | Parsed=false, error < 2000 | ✅ PASS |
| F29: oversized input (100B) | Parsed=false | Parsed=false | ✅ PASS |
| F30: non-string Path | Parsed=false | Parsed=false | ✅ PASS |
| F31: boolean Data | Parsed=false | Parsed=false | ✅ PASS |
| F32: cleanup failure | Parsed=false, artifact recovered | Parsed=false, artifact recovered | ✅ PASS |
| F33: NodeExecutable valid path | Path non-null, exists | Path non-null, exists | ✅ PASS |
| F33b: Error empty on success | Error="" | Error="" | ✅ PASS |
| F33c: Warning field exists | Warning field present | Warning field present | ✅ PASS |
| F34: trailing slash | $null | $null | ✅ PASS |
| F35: repeated slash | $null | $null | ✅ PASS |
| F36: backslash | $null | $null | ✅ PASS |
| F37: dot segment | $null | $null | ✅ PASS |
| F38: dot-dot segment | $null | $null | ✅ PASS |
| F39: absolute path | $null | $null | ✅ PASS |
| F40: terminal dot (/. ) | $null | $null | ✅ PASS |
| F41: terminal dot-dot (/..) | $null | $null | ✅ PASS |
| F42: incomplete scope (@scope) | $null | $null | ✅ PASS |
| F43: drive letter (C:/...) | $null | $null | ✅ PASS |
| F44: control char (0x01) | $null | $null | ✅ PASS |
| F45: 0 matching deps | empty mapping | empty mapping | ✅ PASS |
| F46: 1 matching dep | 1-entry mapping | 1-entry mapping | ✅ PASS |
| F47: N matching deps | multi-entry mapping | multi-entry mapping | ✅ PASS |
| F48: IsNative=false | blocked or absent | blocked or absent | ✅ PASS |

### Node Resolution Evidence
- `Get-Command node -All`: Found 1 Application
- Resolved path: `C:\nvm4w\nodejs\node.exe`
- Path exists: yes
- Is file: yes
- Error: (empty)
- Warning: (empty)

### Temp Artifact Inventory
- Before self-test: 0 `lockfile-reader-*` directories in $env:TEMP
- After F32 (cleanup failure): leaked directory created, then recovered by harness
- After self-test: 0 `lockfile-reader-*` directories remaining
- All `$fixtureDir` contents removed in `finally` blocks

### Self-Test Gate Results
| TestId | Category | Status | Description |
|--------|----------|--------|-------------|
| SELFTEST-PURE | MandatoryFunctional | PASS | Pure-function self-tests (54/54) |
| SELFTEST-NODEBACKED | MandatoryFunctional | PASS | Node-backed self-tests (51/51) |
| SELFTEST-NODECHECK | EvidenceDependent | PASS | Node executable resolution |

---

## 13. Allowlist Functions (22)

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
12. Resolve-NodeExecutable
13. Read-BoundedFile
14. Test-NativeAddonJudgment
15. Test-LockfileReader
16. Test-ResolveLockfileParentPath
17. Test-NativeGateSummary
18. Test-GetOverallResult
19. Save-ProcessSnapshot
20. Update-OwnedProcessRecords
21. Stop-OwnedProcesses
22. Invoke-Cleanup

---

## 14. Side-Effect Proof

- No npm install during self-tests
- No Harness launch (no `$TEST_PORT`, no `Start-Process`)
- No HTTP/WS traffic
- No process kill
- No port/registry/credential/API-key access
- All temp artifacts created in `$fixtureDir` and removed in `finally` blocks
- F32 leaked helper directory recovered by harness
- Actual process exit code captured externally (exit 0)

---

## 15. Full PoC/Harness Not Run

**Explicit statement:** The complete PoC/Harness was NOT run in R12. Only the `-SelfTestOnly` mode was executed, which runs parser checks, pure-function self-tests, Node resolution, and Node-backed integration tests, then exits before any main-flow operations. No npm install, Harness launch, HTTP requests, WebSocket connections, process management, port operations, or external API calls occurred.

---

## 16. Non-Actions

- ❌ Not merged PR #1
- ❌ Not marked Ready for review
- ❌ Not modified master
- ❌ Not accessed real API keys
- ❌ Not entered Phase B
- ❌ Not entered G0-S2
