# G0-S1 R4 Remediation Evidence Report

**Gate:** REMEDIATION ROUND 4 PUBLISHED FOR INDEPENDENT REVIEW — Phase B remains BLOCKED
**Date:** 2026-08-27

---

## 1. Code Commit (bound by this document)

| Field | Value |
|---|---|
| Commit | `287e51f` |
| Parent | `257a0c4` (R3 docs) |
| Subject | `test: add temp-file bounded capture, oversize/boundary fixtures, timeout marker, and count validation matrix for R4 remediation` |
| Scope | `windows-poc-test-r2.ps1` only |

### Script blob and SHA-256

| File | Git blob | SHA-256 |
|---|---|---|
| `windows-poc-test-r2.ps1` | `e3e430c02f58f15afbcd0a697e665f8f67bd000e` | `811c70cd21905b1ff90b9fa96e46b87842435539b6fbdf5c2ee553c5d92f8413` |

*(This document's own blob/hash cannot be known until after this commit.)*

---

## 2. R4-REM Fixes

### R4-REM-01: True bounded capture via temp files

**Before:** `ReadToEndAsync()` loaded full stdout into memory, then truncated post-hoc.

**After:** Non-timeout fixtures use `cmd.exe /c ... > tempfile 2> tempfile` with file-redirect. After process exits, `Get-Item` checks file size FIRST, then reads up to `maxStreamBytes` (50KB) using bounded `FileStream.Read()`. Files cleaned in `finally`.

Timeout fixture uses direct stream reading (small output only — one marker line).

### R4-REM-02: Oversize/boundary fixtures

Added 6 new fixtures:

| Fixture | Output | Verification |
|---------|--------|-------------|
| StdoutOversize | 60KB stdout | total=61500, captured=51200, truncated=True |
| StderrOversize | 60KB stderr | total=61500, captured=51200, truncated=True |
| DualStreamOversize | 60KB each | both total=61500, both truncated=True |
| LongLine | 60KB single line | total=61441, captured=51200, truncated=True |
| BoundaryExact | 51199 chars + newline = 51200 bytes | total=51200, not truncated |
| BoundaryOver | 51200 chars + newline = 51201 bytes | total=51201, truncated=True |

### R4-REM-03: Timeout fixture with real marker capture

**Before:** `captured=0` — default value, not real capture.

**After:** Uses direct stream reading (`ReadToEndAsync`). Child outputs `PRE-TIMEOUT-MARKER: <timestamp>` then hangs. Parent kills after 5s, drains streams. Verifies: marker=True, captured=54 bytes (real), timedOut=True.

### R4-REM-04: Count validation fault matrix

Added 6 new tests to Test-SuiteEvidence (T6-T11):

| Test | Fault | Result |
|------|-------|--------|
| T6 | Missing field (no 'Declared') | ERROR/3 |
| T7 | String value ('11' not 11) | ERROR/3 |
| T8 | Float value (11.5) | ERROR/3 |
| T9 | Negative value (Failed=-1) | ERROR/3 |
| T10 | Overflow (MaxValue+1) | ERROR/3 |
| T11 | Passed+Failed != Actual | ERROR/3 |

### R4-REM-05: Dynamic displayed inventory

All suite headings, formula, and Declared values derived from runtime objects. No hardcoded counts.

### R4-REM-06: Preflight corrections

- Removed "unbounded window negligible" overclaiming
- Bounded capture verified with real byte counts from 6 oversize/boundary fixtures
- Inventory mechanically derived from runtime suite objects

---

## 3. Validation Evidence

### Parser / Analyzer
- PowerShell Parser: **0 errors**
- PSScriptAnalyzer v1.25.0 Severity Error: **0 issues**

### Normal self-test (consecutive)

| Run | Exit Code | Total | Passed | Failed |
|-----|-----------|-------|--------|--------|
| A | 0 | 193 | 193 | 0 |
| B | 0 | 193 | 193 | 0 |

### Runtime-derived suite inventory

| Suite | Declared | Actual | Passed | Failed |
|-------|----------|--------|--------|--------|
| Aggregation | 11 | 11 | 11 | 0 |
| NativeJudgment | 24 | 24 | 24 | 0 |
| ParentPath | 4 | 4 | 4 | 0 |
| GateSummary | 15 | 15 | 15 | 0 |
| LockfileReader | 102 | 102 | 102 | 0 |
| ManifestCompare | 14 | 14 | 14 | 0 |
| SuiteEvidence | 11 | 11 | 11 | 0 |
| ProcessLevelFaults | 12 | 12 | 12 | 0 |
| **Overall** | **193** | **193** | **193** | **0** |

11+24+4+15+102 = 156 + 14+11+12 = 37 = **193** ✓

### Bounded capture evidence (from run A)

| Fixture | stdout total | stdout captured | stdout truncated | stderr total | stderr captured | stderr truncated |
|---------|-------------|----------------|-----------------|-------------|----------------|-----------------|
| MissingSuite | 483 | 483 | False | 0 | 0 | False |
| DeclaredMismatch | 483 | 483 | False | 0 | 0 | False |
| PassedMismatch | 483 | 483 | False | 0 | 0 | False |
| FailedNonZero | 465 | 465 | False | 0 | 0 | False |
| ManifestMismatch | 420 | 420 | False | 0 | 0 | False |
| Timeout | 54 | 54 | False | 0 | 0 | False |
| StdoutOversize | 61500 | 51200 | True | 0 | 0 | False |
| StderrOversize | 0 | 0 | False | 61500 | 51200 | True |
| DualStreamOversize | 61500 | 51200 | True | 61500 | 51200 | True |
| LongLine | 61441 | 51200 | True | 0 | 0 | False |
| BoundaryExact | 51200 | 51200 | False | 0 | 0 | False |
| BoundaryOver | 51201 | 51200 | True | 0 | 0 | False |

All captured bytes ≤ 51200 byte limit. ✓
Truncated is True if and only if total > limit. ✓

### Process-level fault fixtures

| Fault | Exit | noSuccess | noTrusted | Structured | UNTRUSTED | stderrEmpty | Budget | Marker |
|-------|------|-----------|-----------|------------|-----------|-------------|--------|--------|
| MissingSuite | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| DeclaredMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| PassedMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| FailedNonZero | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| ManifestMismatch | 3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| Timeout | -1 | ✓ | — | — | — | — | ✓ | ✓ (54 bytes) |

### Temp file cleanup

All fixture directories (`plf-*`) removed in `finally` blocks. No orphan temp files.

---

## 4. Non-Actions
- Not merged PR #1
- Not marked Ready
- Not modified master
- Not entered Phase B or G0-S2
- Full PoC/Harness not run
