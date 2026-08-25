# G0-S1-R14 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R14 (Independent Review Remediation)
**Date:** 2026-08-25
**Previous Head (R13):** `9438e309356d886663a398ffb833c83369221a5b`
**Gate Result:** REMEDIATION PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED

---

## 1. R13 Verified Baseline

| Field | Value |
|---|---|
| R13 Head | `9438e309356d886663a398ffb833c83369221a5b` |
| R13 Parent (R12) | `c040ab3c59ed1e26974a1c5ca9f6cb1595d39fd5` |
| R13 Subject | `test: harden self-test isolation and evidence for R13` |

Two-file scope: `windows-poc-test-r2.ps1` and `G0-S1-R2-preflight.md`.

---

## 2. REV Item Status

| REV | Item | Status |
|-----|------|--------|
| REV-01 | Shared Test 6 instance conversion | **Done** |
| REV-02 | F29b Node-side 50 MiB check | **Done** |
| REV-03 | F28 bounded-stderr branch proof | **Done** |
| REV-04 | Paired Node/PS grammar tests | **Done** |
| REV-05 | Judgment validation + per-candidate isolation | **Done** |
| REV-06 | LockfileReader independent declared count | **Done** |
| REV-07 | Preflight replaced with authoritative R14 report | **Done** |

---

## 3. REV-01: Shared Test 6 Instance Conversion Wired

**Finding:** `ConvertFrom-MappingToInstanceResult` was called only by F23, not by production Test 6. The function ignored `InstancePath`, hard-coded `LoadExit = 0`, and did not preserve installed `Path`.

**Fix:**
- Redesigned `ConvertFrom-MappingToInstanceResult` to accept: `MappingEntry` (nullable), `InstancePath`, `InstalledPath`, `Version`, `PackageJsonError`, `LoadExit`, `LoadOutput`.
- Returns structured `Blocked` with reason `"No lockfile mapping for $InstancePath"` when `MappingEntry` is `$null`.
- Package.json error overrides mapping status only when mapping was `Resolved`.
- Preserves `InstancePath` and `Path` in result; never hard-codes load success.
- Production Test 6 loop replaced: extracts package.json info, looks up mapping entry, collects real load evidence, calls the shared function.
- No inline `$resolutionStatus`/`$platformApplicable`/`$parentOptional`/`$isNative`/`$blockReason` reconstruction or manual `[PSCustomObject]@{}` in Test 6.
- F23 asserts exact `InstancePath`, `Path`, `ResolutionStatus`, `PlatformApplicable`, `IsNative`, `LoadExit`, `Version`, `PASS`, `Informational`.
- F23c asserts structured `BLOCKED` via null `MappingEntry` and `BLOCKED` gate outcome.
- F23d asserts same-name/different-instance exact-path isolation.

**`rg` proof — production and test calls to shared function:**
```
3741:            $foundNative += ConvertFrom-MappingToInstanceResult `     ← PRODUCTION Test 6
1624:                $r23instances += ConvertFrom-MappingToInstanceResult ` ← F23 test
1656:            $r23cResult = ConvertFrom-MappingToInstanceResult `        ← F23c test
1693:            $r23d_a = ConvertFrom-MappingToInstanceResult `            ← F23d test
1698:            $r23d_b = ConvertFrom-MappingToInstanceResult `            ← F23d test
```

**`rg` proof — no remaining inline final instance-object construction in Test 6:**
```
$ grep -n "foundNative.*PSCustomObject\|PSCustomObject.*foundNative" windows-poc-test-r2.ps1
(no output — zero matches)
```

---

## 4. REV-02: F29b Reaches Node's Independent 50 MiB Check

**Finding:** PS pre-check used the same 50 MiB threshold and returned first; F29b's loose assertion matched the PS error, not Node's `statSync` check.

**Fix:**
- F29b calls `ConvertFrom-LockfileSafe -TestMaxInputBytes 62914560` (60 MiB) to raise the PS-side limit above the fixture.
- Node's fixed 50 MiB check in the embedded script remains unchanged at exactly 52428800 bytes.
- Assertion requires `"input exceeds 50MB"` (Node's exact diagnostic) AND rejects `"exceeds maximum input size"` (PS diagnostic).
- Sparse file creation and cleanup in `try`/`finally`.

---

## 5. REV-03: F28 Proves the Bounded-Stderr Branch

**Finding:** PS 5.1's `$ErrorActionPreference = "Stop"` converted native stderr into a terminating exception in the `catch` block before `Read-BoundedFile` could check file size.

**Fix (in `ConvertFrom-LockfileSafe`):**
- Save `$ErrorActionPreference` before the Node invocation.
- Set `$ErrorActionPreference = "Continue"` only around the native Node invocation with stderr/stdout redirected to exact owned files.
- Capture `$LASTEXITCODE` immediately after.
- Restore previous preference in `finally`.
- This is narrowly scoped: does not weaken error handling outside the Node invocation.
- `Read-BoundedFile` is now deterministically reached for oversized stderr.

**F28 assertion:**
- `Parsed = false`
- Error matches `^Stderr diagnostic:.*exceeds maximum size` (the explicit `Read-BoundedFile` diagnostic)
- Diagnostic length bounded (< 2000 chars)
- Oversized stderr body not embedded (file was too large to read)
- Rejects `cleanup|Cleanup` and `^Lockfile reader exception:`

---

## 6. REV-04: Paired Node/PS Grammar Tests

**Finding:** F-GV1–F-GV8 and F-GI1–F-GI8 called only `ConvertFrom-LockfilePathPolicy`; did not exercise the fixed Node helper.

**Fix:**
- Kept all pure PS policy cases.
- Added5 real `ConvertFrom-LockfileSafe` fixtures through the production Node helper:
  - **F-IG1:** Valid grammar (root, unscoped, scoped, nested, scoped-nested, deeply nested, same-name) — 8 entries parsed.
  - **F-IG2:** Arbitrary suffix at depth — rejected.
  - **F-IG3:** Incomplete scope at depth — rejected.
  - **F-IG4:** PS grammar matches Node for trailing at depth.
  - **F-IG5:** Double scope — rejected by Node.
- No `TestCustomNodeScriptPath` used.

---

## 7. REV-05: Judgment Validation and Per-Candidate Isolation

**Finding:** `$providerException` was not reset per candidate. Several malformed outcomes untested.

**Fix:**
- `$providerException = $null` at start of each `foreach` iteration in `ConvertFrom-TransitiveMapping`.
- Boolean type validation (`-isnot [bool]`) for `PlatformApplicable` and `ParentOptional`.
- 6 new tests:
  - **F-JC8:** Provider exception → exact-path `Blocked` with exception message.
  - **F-JC9:** Cross-candidate isolation — first throws, second succeeds.
  - **F-JC10:** `Blocked` with empty `BlockReason` → caught.
  - **F-JC11:** Null `ResolutionStatus` → blocked.
  - **F-JC12:** Non-Boolean `PlatformApplicable` → blocked.
  - **F-JC13:** Non-Boolean `ParentOptional` → blocked.
- All overrides cleared in `finally` blocks.

---

## 8. REV-06: LockfileReader Independent Declared Count

**Finding:** `$expectedTestCount = $tests.Count` was circular.

**Fix:**
- Independent named manifest of all 102 expected test names.
- Manifest count compared to actual result objects; uniqueness checked.
- `Declared`, `Actual`, `Passed`, `Failed` as separate fields.
- Suite validation: for every suite, `declared = actual`, `passed = actual`, `failed = 0`.
- Displayed totals computed from validated suite objects.
- Duplicate `$script:SelfTestSuiteResults` and `$script:TestJudgmentProviderOverride` declarations removed.

---

## 9. Test Execution Evidence

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
| **Overall** | **156** | **156** | **156** | **0** |

### Consecutive Run Exit Codes
- Run A: **exit 0**
- Run B: **exit 0**

### Temp Artifact Inventory
- Pre-existing `lockfile-reader-*` directories from prior sessions (not R14-owned)
- R14-owned helper directories created temporarily during self-test and removed in `finally` blocks
- After run A: zero R14-owned artifacts remaining
- After run B: zero R14-owned artifacts remaining
- `$fixtureDir` contents removed in `finally` blocks

### Sentinel Preservation
- F32c creates `lockfile-reader-sentinel-*`; asserts survives; cleaned after assertion
- Post-test: zero sentinel directories remaining

### Node Resolution
- Path: `C:\nvm4w\nodejs\node.exe`
- Application count: 1
- Error: (empty)

---

## 10. Test Inventory Reconciliation

### R13: 143 total (54 pure + 89 LockfileReader)

### R14 Changes to LockfileReader Suite (89 → 102)

| Action | Count | Tests |
|--------|-------|-------|
| RETAINED | 77 | F1–F22, F24–F33b, F-NC1–F-NC9, F34–F44, F-GV1–F-GV8, F-GI1–F-GI8, F45–F48b, F-JC1–F-JC7 |
| REPLACED | 3 | F23b (expanded assertions), F23c (shared function), F29b (raised PS limit) |
| MODIFIED | 1 | F28 (tightened assertion) |
| NEW | 13 | F23c-gate, F23d, F-IG1–F-IG5, F-JC8–F-JC13 |

**Arithmetic: 89 retained/replaced/modified + 13 new = 102** ✓

### Pure Function Suites: Unchanged (54)
- Aggregation: 11, NativeJudgment: 24, ParentPath: 4, GateSummary: 15

### R14 Total: 54 + 102 = **156** ✓

---

## 11. Side-Effect Proof
- No npm install, Harness launch, HTTP/WS, process kill, port/registry/credential/API-key access during self-tests
- All temp artifacts in `$fixtureDir`, removed in `finally`
- `$script:TestJudgmentProviderOverride` cleared in `finally` blocks
- `$ErrorActionPreference` saved/restored around Node invocation only

---

## 12. Full PoC/Harness Not Run

**Explicit:** The complete PoC/Harness was NOT run. Only `-SelfTestOnly` mode executed.

---

## 13. Non-Actions
- Not merged PR #1
- Not marked Ready
- Not modified master
- Not accessed real API keys
- Not entered Phase B or G0-S2
- Not committed or pushed
