# G0-S1 R5 Preflight Report

**Date**: 2026-08-27
**Script**: `research/g0-s1-harness-integration/windows-poc-test-r2.ps1`

## Code Commit

| Field | Value |
|---|---|
| Hash | `159dec955bd564a8e5bfc86da9873e60d4198532` |
| Parent | `0bc5e950c3086bd9c05286b8cf2137ac8133a00b` |
| Subject | `test: R5 remediation — token-based process tree cleanup, bounded capture, CleanupFailure fixture, dynamic counts` |
| Files | `research/g0-s1-harness-integration/windows-poc-test-r2.ps1` |

## Script Blob

| Field | Value |
|---|---|
| Git blob | `30bfeefb47326e12d13a219068298eef1aead1e0` |
| SHA-256 | `760389f22b47a39f1c1bd2ec6ce568aa0e8bad7bc9aa178a81be0ef09c82cab3` |

## Static Analysis

| Tool | Result |
|---|---|
| PowerShell Parser | **0 errors** |
| PSScriptAnalyzer Severity Error | **0** (tool available and invoked) |

## Test Runs

Two consecutive `-SelfTestOnly` runs on the exact code commit:

| Run | Exit | Tests | PASS | FAIL | Duration | stderr |
|---|---|---|---|---|---|---|
| Run 1 | 0 | 194 | 194 | 0 | ~45s | empty |
| Run 2 | 0 | 194 | 194 | 0 | ~45s | empty |

Suite inventory (both runs identical):

| Suite | Declared | Actual | Passed | Failed |
|---|---|---|---|---|
| Aggregation | 11 | 11 | 11 | 0 |
| NativeJudgment | 24 | 24 | 24 | 0 |
| ParentPath | 4 | 4 | 4 | 0 |
| GateSummary | 15 | 15 | 15 | 0 |
| LockfileReader | 102 | 102 | 102 | 0 |
| ManifestCompare | 14 | 14 | 14 | 0 |
| SuiteEvidence | 11 | 11 | 11 | 0 |
| ProcessLevelFaults | 13 | 13 | 13 | 0 |
| **Total** | **194** | **194** | **194** | **0** |

Display formula: `Aggregation(11) + NativeJudgment(24) + ParentPath(4) + GateSummary(15) = 54` pure + `LockfileReader(102)` node-backed + `ManifestCompare(14) + SuiteEvidence(11) + ProcessLevelFaults(13) = 38` R15 = **194** total. All counts dynamically derived from runtime suite objects.

## Process-Level Fault Fixtures (13 cases)

### Structural (5 cases)

| Fixture | Exit | stdout total | captured | truncated | stderr | UNTRUSTED | ScriptInternal |
|---|---|---|---|---|---|---|---|
| MissingSuite | 3 | 679 | 679 | False | 0 | True | True |
| DeclaredMismatch | 3 | 688 | 688 | False | 0 | True | True |
| PassedMismatch | 3 | 751 | 751 | False | 0 | True | True |
| FailedNonZero | 3 | 733 | 733 | False | 0 | True | True |
| ManifestMismatch | 3 | 688 | 688 | False | 0 | True | True |

### Timeout (1 case)

| Fixture | Exit | stdout total | captured | truncated | marker | timedOut |
|---|---|---|---|---|---|---|
| Timeout | -1 | 54 | 54 | False | True | True |

Process tree cleanup: parent powershell.exe killed via `Kill-TestProcessTree`. Descendant tracked via PID marker file and CIM CommandLine token verification. Post-loop orphan scan: **no orphans**.

### Oversize (4 cases)

| Fixture | stdout total | captured | truncated | stderr total | captured | truncated |
|---|---|---|---|---|---|---|
| StdoutOversize | 61500 | 51200 | True | 0 | 0 | False |
| StderrOversize | 0 | 0 | False | 61500 | 51200 | True |
| DualStreamOversize | 61500 | 51200 | True | 61500 | 51200 | True |
| LongLine | 61441 | 51200 | True | 0 | 0 | False |

All oversize: exit=3, captured ≤ 51200, captured ≤ total, truncated iff total > 51200. LongLine: no premature newline in captured text (single line verified).

### Boundary (2 cases)

| Fixture | stdout total | captured | truncated | stderr total |
|---|---|---|---|---|
| BoundaryExact | 51200 | 51200 | False | 0 |
| BoundaryOver | 51201 | 51200 | True | 0 |

BoundaryExact: total=captured=limit, not truncated. BoundaryOver: total=limit+1, captured=limit, truncated.

### CleanupFailure (1 case)

| Field | Value |
|---|---|
| Exit | 3 |
| No success banner | True |
| Cleanup failure detected | True |
| Emergency cleanup done | True |
| Orphan-free after cleanup | True |
| stdout total/captured | 0/0 |

The CleanupFailure fixture spawns a real descendant process with the test token in its command line. The fast-fault child exits WITHOUT killing the descendant (simulating cleanup failure). The parent detects the living descendant via PID marker file, verifies identity via CIM CommandLine token match, and invokes `Invoke-EmergencyCleanup` (independent code path). Post-cleanup orphan scan confirms no test-owned processes remain.

## Bounded Capture Semantics

- **Encoding**: All fixtures emit ASCII characters via `[Console]::Out.Write()` / `[Console]::Error.Write()`. UTF-8 byte count = character count for ASCII range.
- **Total bytes**: `[System.Text.Encoding]::UTF8.GetByteCount(rawOutput)` — same metric for total and captured.
- **Captured bytes**: `min(totalBytes, 51200)` — enforced by post-read truncation.
- **Truncated**: `$totalBytes -gt 51200` — strict equivalence.
- **Invariant**: captured ≤ total AND captured ≤ 51200 — verified in all fixture assertions.

## Process Identity and Tree Cleanup

- **Token**: `PLF-<GUID>` generated per `Test-ProcessLevelFaults` invocation.
- **Identity mechanism**: Token passed as CLI argument to child process (`-PLFToken`), queryable via `Win32_Process.CommandLine`. PID marker files (`parent-<PID>.txt`, `desc-<PID>.txt`) written to shared marker directory.
- **Parent cleanup**: `$proc.Kill()` + `$proc.WaitForExit(3000)`.
- **Descendant cleanup**: Read PID from marker file → verify CIM CommandLine token → `Stop-Process -Force`.
- **Safety net**: CIM scan for any remaining processes matching token.
- **Emergency cleanup**: Independent `Invoke-EmergencyCleanup` function, always runs in `finally` block.
- **Orphan verification**: `Test-NoOrphans` scans CIM post-loop; any survivors trigger emergency cleanup + test FAIL.

## Non-action Checklist

- [x] No npm install / Harness / HTTP/WS / port operations
- [x] No real credentials or API keys
- [x] No process-name-wide kill (all kills are token-verified or PID-specific)
- [x] PR remains OPEN + Draft, base=master, merged=null
- [x] No merge, no Ready, no master modification
- [x] No Phase B / G0-S2 entry
- [x] No Full PoC / Harness run
