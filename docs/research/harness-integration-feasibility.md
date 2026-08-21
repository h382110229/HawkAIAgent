# Harness Integration Feasibility Study

**Gate:** HawkAIAgent-G0-S1 / G0-S1-R1
**Date:** 2026-08-20
**Upstream:** DeepSeek Harness 0.1.0-rc.8 (SHA 141eb6fef83422698aef7a981029e843e8161534)

## Executive Summary

DeepSeek Harness provides a complete API surface (Typert Gateway + WebSocket events) that can be consumed directly from an Electron renderer process. **No custom BFF is needed.** The official client packages (`dsh-client-connection`, `dsh-api-remotes`, `dsh-api-gateway`) are published to npm at the exact version and install cleanly with 59 transitive dependencies.

**R1 Gate Result: BLOCKED — pending Windows 11 x64 verification**

---

## Key Findings

### 1. API Surface

| Protocol | Transport | Purpose |
|----------|-----------|---------|
| HTTP POST `/api` | Unary RPC | Settings, credentials, session CRUD, agent presets, host.describe |
| WebSocket `/api/events.mux` | Downlink stream | Session events (messages, tool calls, status) |
| WebSocket `/api/events.host` | Downlink stream | Host events |

### 2. npm Package Availability

All 4 packages verified on npm at `0.1.0-rc.8` (dist-tag: `next`):
- `@deepseek-ai/dsh`
- `@deepseek-ai/dsh-client-connection`
- `@deepseek-ai/dsh-api-remotes`
- `@deepseek-ai/dsh-api-gateway`

Install: 59 packages, 0 peer dependency warnings, exit code 0.

### 3. Client Package Loading

- `lib/index.js` (Node/CJS host): ✅ Works
- `lib/client.js` (Browser): Uses `window.__ModuleLoader__` — requires Vite/bundler to handle

### 4. Native Dependencies

- Client packages: **No native deps** — pure JS
- Host-side native deps (node-pty, koffi): Carried by Harness subprocess, not Electron
- electron-rebuild: **NOT required** for Route A/B

### 5. Security

- Credential storage: safeStorage/DPAPI recommended over plain YAML
- Loopback API: Needs thin auth plugin (token-based)
- Windows ACL sandbox: partial enforcement only

## Recommendations

1. **Route A for validation** → **Route B for product**
2. Use exact npm versions with lockfile
3. safeStorage for key management
4. Thin auth plugin for loopback API
5. DSH_HOME at `<userData>/dsh-home/`

## Detailed Reports

- [G0-S1 Gate Report](../g0-s1-harness-integration/report.md)
- [R1 Key Security Analysis](../g0-s1-harness-integration/key-security-analysis.md)
- [R1 Loopback Auth Design](../g0-s1-harness-integration/loopback-auth-design.md)
- [R1 DSH_HOME Decision](../g0-s1-harness-integration/dsh-home-decision.md)
- [Windows PoC Script](../g0-s1-harness-integration/windows-poc-test.ps1)
