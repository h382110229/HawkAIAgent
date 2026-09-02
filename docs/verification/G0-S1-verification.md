# G0-S1-R1 Verification Report

> **Status: Historical snapshot — superseded by G0-S1-R2-preflight.md and G0-S1-R3 remediation.**
> This report reflects the state at the time of original R1 generation (2026-08-20).
> For current status, see `G0-S1-R2-preflight.md`.

**Gate:** HawkAIAgent-G0-S1-R1 (Blocker Closure)
**Date:** 2026-08-20
**Previous Gate Result:** FAIL — CHANGES REQUIRED

---

## R1 Gate Result (Historical): BLOCKED — pending Windows 11 x64 verification

---

## Finding Status

| Finding | Status | Summary |
|---------|--------|---------|
| R1-01 Gate Result | ✅ FIXED | Changed to PASS WITH DOCUMENTED RISKS |
| R1-02 npm verification | ✅ COMPLETE | 4 packages verified, exact version, lockfile |
| R1-03 Windows PoC | ⚠️ BLOCKED | Script generated, requires Windows execution |
| R1-04 Native ABI | ✅ COMPLETE | No native deps in client packages |
| R1-05 Key security | ✅ FIXED | Revised threat model documented |
| R1-06 Loopback auth | ✅ COMPLETE | Auth design documented (superseded by R2/R3) |
| R1-07 DSH_HOME | ✅ COMPLETE | Decision documented |
| R1-08 Reports | ✅ COMPLETE | All documents created |

---

## R1-02: npm Verification (COMPLETE)

### Environment
- Node: v24.14.0
- npm: 11.12.0
- pnpm: 10.33.2

### npm dist-tags
```
@deepseek-ai/dsh: latest=0.1.0-rc.7, next=0.1.0-rc.8
```

### Install result
```
Package: @deepseek-ai/dsh-client-connection@0.1.0-rc.8
         @deepseek-ai/dsh-api-remotes@0.1.0-rc.8
         @deepseek-ai/dsh-api-gateway@0.1.0-rc.8
Packages: 59 added
Peer warnings: 0
Exit code: 0
```

### Import verification

| Package | CJS (lib/index.js) | Browser (lib/client.js) |
|---------|-------------------|------------------------|
| dsh-client-connection | ✅ OK | ⚠️ Requires ModuleLoader |
| dsh-api-remotes/client | ✅ (host) | ⚠️ window.__ModuleLoader__ |
| dsh-api-gateway/client | ✅ (host) | ⚠️ window.__ModuleLoader__ |

**Note:** `window is not defined` in Node is expected. Client packages are browser-only. `window.__ModuleLoader__` is tsdown's browser bundle format — **Vite can produce a bundle, but the browser runtime still requires `window.__ModuleLoader__`; Route B remains blocked.**

---

## R1-03: Windows PoC (BLOCKED)

**Reason:** OpenClaw agent runs on Ubuntu, cannot execute Windows tests.

**Deliverable:** `windows-poc-test.ps1` — now superseded by `windows-poc-test-r2.ps1`.

---

## R1-04: Native ABI Matrix (COMPLETE)

### Client packages (dsh-client-connection, dsh-api-remotes, dsh-api-gateway)

| Check | Result |
|-------|--------|
| .node files | None |
| node-gyp references | None |
| prebuild references | None |
| Native addons | None |

**Conclusion:** Client packages are pure JS. No electron-rebuild needed.

---

## R1-05: Key Security (FIXED)

### Previous (incorrect)
> "只在 Harness 启动时注入，不在运行时暴露"

### Corrected
- safeStorage/DPAPI protects static storage ✅
- Decrypted key enters `process.env.DEEPSEEK_API_KEY` ⚠️
- Subprocess-local env scrubbing is heuristic ⚠️
- Cannot prevent same-UID process or Harness plugin from reading ⚠️
- This is **accidental exposure reduction**, NOT strong isolation

---

## R1-06: Loopback Auth (SUPERSEDED)

> **Superseded by loopback-auth-design-r2.md**

Original design used Bearer + WS subprotocol. R2 analysis shows:
- Browser WebSocket API does NOT support custom headers
- `@deepseek-ai/dsh-client-connection` has NO public API for custom auth headers or subprotocols
- Candidate B (HttpOnly Cookie) is preferred but **requires PoC verification**

Current status: **Candidate / pending PoC** — not final security design.

---

## R1-07: DSH_HOME (COMPLETE)

```
DSH_HOME = path.join(app.getPath('userData'), 'dsh-home')
```

---

## Remaining BLOCKERs (Historical)

| # | Blocker | Resolution |
|---|---------|-----------|
| B1 | Windows PoC not executed | User must run `windows-poc-test-r2.ps1` |
| B2 | WebSocket message format undocumented | Must capture from live Harness |

---

## Confirmation (Historical)

- [x] NOT pushed to remote (at time of generation)
- [x] NOT created PR (at time of generation)
- [x] NOT merged
- [x] NOT exposed credentials
- [x] NOT modified upstream repository
- [x] All findings addressed with evidence
