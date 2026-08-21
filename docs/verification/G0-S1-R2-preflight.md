# G0-S1-R2 Preflight Report

**Gate:** HawkAIAgent-G0-S1-R2 (Windows PoC Preflight)
**Date:** 2026-08-20
**Gate Result:** BLOCKED — pending Windows 11 x64 verification

---

## R2-1: Gate Status

Previous R1 status was incorrect ("PASS WITH DOCUMENTED RISKS").
Corrected to: **BLOCKED — pending Windows 11 x64 verification.**

Only real Windows execution results can unblock this gate.

---

## R2-2: ABI Matrix (Revised)

Two independent dimensions:

### UI Layer
| Option | Native deps | Notes |
|--------|------------|-------|
| Official Web UI | None | BrowserWindow loads localhost |
| Hawk React UI + client packages | None (client) | ⚠️ ModuleLoader issue (see R2-4) |

### Harness Host Runtime
| Option | Native deps | electron-rebuild | Status |
|--------|------------|-----------------|--------|
| Independent Node 22 | node-pty, koffi (host-side) | NOT needed | ⚠️ Needs Windows verification |
| ELECTRON_RUN_AS_NODE | Unknown | Unknown | ❌ NOT tested |
| Electron Main embedded | High | Required | ❌ High risk |

Key fact: Client packages have NO native addons. Native deps are host-side only.

---

## R2-3: Loopback Authentication (Revised)

Three candidates evaluated:

| Candidate | Security | Client pkg changes | Status |
|-----------|----------|-------------------|--------|
| A: Bearer + WS subprotocol | Good | Requires patching | ⚠️ Blocked |
| B: HttpOnly SameSite cookie | Best | No changes needed | ✅ Preferred |
| C: Electron IPC carrier | Weakest | Manual per-call | ❌ Not recommended |

**Preferred: Candidate B (HttpOnly Cookie)**
- Main process generates 32-byte token
- Sets via `session.defaultSession.cookies.set()`
- httpOnly, sameSite=strict, secure=false (localhost)
- Official fetch/WebSocket auto-attach cookie
- Token never in Renderer JS, URL, localStorage, or logs
- Harness auth plugin validates Cookie header

---

## R2-4: Vite Fixture Results

**BLOCKER identified:** Official client packages cannot be used in browser as-is.

### Test 1: Import from `/client`
```
import { API_PATH } from '@deepseek-ai/dsh-client-connection/client';
```
- Build: ✅ Exit code 0, 386 kB
- Runtime: ❌ Requires `window.__ModuleLoader__` (non-standard global)

### Test 2: Import from root
```
import { API_PATH } from '@deepseek-ai/dsh-client-connection';
```
- Build: ❌ FAIL — `AsyncLocalStorage is not exported`
- Cause: Root entry contains Host-side Node.js code

### Implication for Route B
Hawk React UI cannot directly import official client packages without either:
1. Providing a `__ModuleLoader__` polyfill
2. Writing a Vite plugin to transform the pattern
3. Using Route A (load official Web UI which already handles this)

---

## R2-5: PowerShell Script Security Review

### Script: `windows-poc-test-r2.ps1`

| Check | Result |
|-------|--------|
| Requires admin | ❌ No |
| Modifies execution policy | ❌ No |
| Writes system directories | ❌ No |
| Modifies registry | ❌ No |
| Modifies firewall | ❌ No |
| Modifies system env vars | ❌ No |
| Installs global npm | ❌ No (uses local install) |
| Reads/prints API Key | ❌ No |
| Uploads data | ❌ No |
| Temp dir scope | ✅ `$env:TEMP\hawkai-poc-*` only |
| Cleanup scope | ✅ Only removes its own temp dir |
| Uses Invoke-Expression | ❌ No |
| Uses broad taskkill | ❌ No (uses process.Kill()) |
| Pollutes ~/.dsh | ❌ No (uses temp DSH_HOME) |
| Default mode | ✅ No-credential test only |
| PID tracking | ✅ Exact PID recorded |

### Script metadata
- SHA-256: [computed at runtime]
- Size: ~6.5 KB
- Lines: ~175
- Required execution: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`
- Estimated time: 60-90 seconds
- Files created: `$env:TEMP\hawkai-poc-*\` (temp dir, logs, npm install)
- Processes spawned: node (dsh), npm (install)
- Cleanup: `Remove-Item -Recurse -Force '$env:TEMP\hawkai-poc-*'`

### User execution command
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass; .\windows-poc-test-r2.ps1
```

---

## R2-6: File Inventory

### git status --short (untracked files)
```
docs/adr/
docs/architecture.md
docs/mvp.md
docs/research/
docs/verification/
research/
```

### All project files (15)
```
.gitignore
README.md
docs/adr/ADR-001-harness-integration.md
docs/adr/ADR-002-secret-storage.md
docs/adr/ADR-003-windows-sandbox.md
docs/architecture.md
docs/decisions.md
docs/mvp.md
docs/research/harness-integration-feasibility.md
docs/verification/G0-S1-verification.md
research/g0-s1-harness-integration/abi-matrix-r2.md
research/g0-s1-harness-integration/dsh-home-decision.md
research/g0-s1-harness-integration/key-security-analysis.md
research/g0-s1-harness-integration/loopback-auth-design-r2.md
research/g0-s1-harness-integration/report.md
research/g0-s1-harness-integration/vite-fixture-results.md
research/g0-s1-harness-integration/windows-poc-test-r2.ps1
```

Total: 17 files (15 from R1 + 2 new in R2: `abi-matrix-r2.md`, `loopback-auth-design-r2.md`, `vite-fixture-results.md`, `windows-poc-test-r2.ps1`)
Previous count of 15 was accurate for R1; R2 adds 4 new files.

---

## Remaining BLOCKERs

| # | Blocker | Resolution |
|---|---------|-----------|
| B1 | Windows PoC not executed | User must run script on Windows 11 x64 |
| B2 | Client package ModuleLoader issue | Must decide: polyfill, Vite plugin, or Route A only |

---

## Recommendation

Given the ModuleLoader blocker (R2-4), **Route A (load official Web UI) is the only immediately viable path.** Route B requires either:
1. Writing a `__ModuleLoader__` polyfill (untested, fragile)
2. Writing a custom Vite plugin (medium effort)
3. Waiting for upstream to publish proper ESM browser builds

**For MVP validation: Use Route A.** Revisit Route B when upstream improves client package browser support.

---

## Confirmation

- [x] NOT pushed to remote
- [x] NOT created PR
- [x] NOT merged
- [x] NOT exposed credentials
- [x] NOT modified upstream repository
- [x] Gate status: BLOCKED
- [x] Windows script reviewed and hardened
- [x] No fabricated Windows results
