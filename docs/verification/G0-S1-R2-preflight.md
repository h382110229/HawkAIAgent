# G0-S1-R3-R3-R2 Preflight & Verification Report

**Gate:** HawkAIAgent-G0-S1-R3-R3-R2 (Final Identity and Platform Checks)
**Date:** 2026-08-23
**Previous Head:** `bb367903bff207cdb082266483be157e675241d2`
**Gate Result:** REMEDIATION COMPLETE — pending Windows 11 x64 execution

---

## 1. Mandatory 1: `$pid` Variable

**Finding:** Test 23 used `foreach ($pid in $chainPids)` which writes to read-only `$PID`.

**Fix:** Changed to `$chainProcessId`. Full file search confirms zero lowercase `$pid` assignments/loop variables.

---

## 2. Mandatory 2: Identity Mismatch Gate Impact

**Finding:** `Stop-OwnedProcesses` put all identity mismatches in `Skipped`; `Invoke-Cleanup` only checked `Failed.Count`.

**Fix:**
- Four result categories: `Terminated`, `AlreadyExited`, `IdentityBlocked`, `Failed`
- `IdentityBlocked` = still running but identity unconfirmed → NOT killed, generates Gate-blocking `BLOCKED` via `CLEANUP-IDENTITY` result
- `Failed` = identity confirmed but Kill/WaitForExit failed → `MandatoryFunctional FAIL`
- `Invoke-Cleanup` only writes "OK" when BOTH `Failed` and `IdentityBlocked` are empty
- Orphan check now verifies CreationDate + CommandLine + ExecutablePath (not just CreationDate)
- Test 18 consumes structured result from `Stop-OwnedProcesses`

---

## 3. Mandatory 3: Harness Proof PID Reuse Protection

**Finding:** `cmdOk` used broad `*dsh*` wildcard; no CreationDate/CommandLine/ExecutablePath/ParentPID comparison.

**Fix:**
- `cmdOk` now matches exact `$dshBin` path
- Full identity comparison: CIM CreationDate, CommandLine, ExecutablePath, ParentPID vs owned record
- Any mismatch → `SavedHarnessProven = false`
- Chain display order: reversed for `launcher -> node` presentation

---

## 4. Mandatory 4: npm os/cpu Allow/Deny Semantics

**Finding:** `$pkgData.os -notcontains "win32"` treats `["!darwin"]` as "not for Windows".

**Fix:**
- Positive items = allowlist; `!value` = denylist; no positive items = allow unless denied
- `["!win32"]` → denied (correct)
- `["!darwin"]` → NOT denied for win32 (correct)
- `["win32"]` → allowed (correct)
- `["!win32", "linux"]` → denied (correct)
- Missing/empty → allowed (correct)
- Nested lockfile paths parsed correctly: `node_modules/<parent>/node_modules/node-pty` extracts `node-pty`
- Unresolvable → EvidenceDependent BLOCKED

**Static judgment cases:**

| os value | win32 result |
|----------|-------------|
| `["win32"]` | Allowed ✅ |
| `["!darwin"]` | Allowed ✅ (no win32 deny) |
| `["!win32"]` | Denied ✅ |
| `["linux"]` | Denied ✅ (allowlist, win32 not in it) |
| `[]` or missing | Allowed ✅ (default) |

| cpu value | x64 result |
|-----------|-----------|
| `["x64"]` | Allowed ✅ |
| `["!arm"]` | Allowed ✅ |
| `["!x64"]` | Denied ✅ |
| `[]` or missing | Allowed ✅ |

---

## 5. Mandatory 5: Test 15 Resource & Single-Result

**Finding:** `$reader` not disposed in finally; each path already produces one result (verified).

**Fix:**
- `$reader = $null` declared at Test 15 start
- `$reader.Dispose()` in `finally` block (before `$memStream.Dispose()`)
- StreamReader created with `UTF8Encoding($false, $true, $true)` (encoder + throwOnInvalid + detectBOM)
- All 8 paths verified to produce exactly one Test 15 result

**Single-result matrix:**

| Path | Result |
|------|--------|
| WS not open | BLOCKED |
| Oversize | FAIL (test15Finalized=true, break) |
| Timeout, 0 bytes | BLOCKED |
| Close frame | FAIL |
| Non-Text | FAIL |
| No EndOfMessage | FAIL |
| Invalid UTF-8 | FAIL |
| Invalid JSON | FAIL |
| Valid JSON, unverified envelope | BLOCKED |

---

## 6. Script SHA-256

`4ea9102e53b437362b2536f6e60224dc785841357f48ea7e5420168013879425`

---

## 7. Static Analysis Summary

| Check | Result |
|-------|--------|
| Lowercase `$pid` variable | ✅ None found |
| IdentityBlocked in gate | ✅ 12 references |
| KillResults.Skipped | ✅ 0 references |
| Harness dshBin path match | ✅ Exact path |
| identityOk in harness proof | ✅ 7 references |
| os/cpu denylist (`!`) | ✅ 8 references |
| reader.Dispose in finally | ✅ Present |
| chainProcessId | ✅ 2 references |
| ReversedChain display | ✅ Present |
| PowerShell parser | PENDING WINDOWS HERMES PHASE A |
| PSScriptAnalyzer | PENDING WINDOWS HERMES PHASE A |
| Aggregation runtime | PENDING WINDOWS HERMES PHASE A |
