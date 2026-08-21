# G0-S1-R2 Preflight Report

**Gate:** HawkAIAgent-G0-S1-R2 (Windows PoC Preflight)
**Date:** 2026-08-20
**Updated: 2026-08-21 (G0-S1-R3, R3-R1, R3-R2 remediation)**

> R3-R2 addresses PowerShell runtime correctness: function name consistency, `$PID` conflict, gate aggregation truth table, null-safety, PID identity revalidation, depth-based termination, and cleanup resilience.
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
| Hawk React UI + client packages | None (client) | ⚠️ **Vite can produce a bundle, but the browser runtime still requires `window.__ModuleLoader__`; Route B remains blocked.** |

### Harness Host Runtime
| Option | Native deps | electron-rebuild | Status |
|--------|------------|-----------------|--------|
| Independent Node 22 | node-pty, koffi (host-side) | NOT needed | ⚠️ Needs Windows verification |
| ELECTRON_RUN_AS_NODE | Unknown | Unknown | ❌ NOT tested |
| Electron Main embedded | High | Required | ❌ High risk |

Key fact: Client packages have NO native addons. Native deps are host-side only.

---

## R2-3: Loopback Authentication (Revised)

> **Status: Candidate / pending PoC — not final security design**

Three candidates evaluated:

| Candidate | Security | Client pkg changes | Status |
|-----------|----------|-------------------|--------|
| A: Bearer + WS subprotocol | — | Requires patching | ⚠️ Blocked — client API limitations |
| B: HttpOnly SameSite cookie | — | No changes needed | ✅ Preferred candidate |
| C: Electron IPC carrier | — | Manual per-call | ❌ Not recommended |

**Preferred candidate: B (HttpOnly Cookie)** — but NOT accepted as final design.

### Critical limitation: Cookie 不按端口隔离

- Cookie 按 Host/Domain/Path 匹配，**不按 TCP 端口隔离**
- 为 `127.0.0.1` 设置的 Cookie 可能被发送到该 Host 的其他端口
- 如果同一机器上其他服务监听不同端口，Cookie 可能泄露

### Additional security constraints

- HttpOnly 只能阻止 JS 直接读取 Token，**不能阻止 XSS 发起已认证请求**
- SameSite 不能替代 Origin、Host、CSP 和 Renderer 隔离
- Cookie 方案需要验证 Electron、官方 UI、HTTP RPC、WebSocket Upgrade 的实际兼容性
- Harness 是否暴露可用的 HTTP middleware 和 WS upgrade hook **尚未验证**

### 组合防御候选（需全部验证）

- 随机高位端口
- 仅绑定 127.0.0.1
- Host allowlist
- Origin allowlist
- HttpOnly session Cookie 候选
- 严格 CSP
- `nodeIntegration: false` + `contextIsolation: true` + `sandbox: true`
- 独立 Electron session partition
- Token 每次启动重新生成
- 退出时清除 Cookie

> **注意：** 这些措施不构成强隔离。

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
1. Providing a `__ModuleLoader__` polyfill (untested, fragile)
2. Writing a Vite plugin to transform the pattern (medium effort)
3. Using Route A (load official Web UI which already handles this)

**Vite 构建成功 ≠ 浏览器运行成功。Route B remains blocked.**

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

### User execution command
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass; .\windows-poc-test-r2.ps1
```

---

## R2-6: File Inventory

### Pre-PR baseline files (3)
```
.gitignore
README.md
docs/decisions.md
```

### PR initial new deliverables (17)
```
docs/adr/ADR-001-harness-integration.md
docs/adr/ADR-002-secret-storage.md
docs/adr/ADR-003-windows-sandbox.md
docs/architecture.md
docs/mvp.md
docs/research/harness-integration-feasibility.md
docs/verification/G0-S1-verification.md
research/g0-s1-harness-integration/abi-matrix-r2.md
research/g0-s1-harness-integration/dsh-home-decision.md
research/g0-s1-harness-integration/key-security-analysis.md
research/g0-s1-harness-integration/loopback-auth-design-r2.md
research/g0-s1-harness-integration/loopback-auth-design.md
research/g0-s1-harness-integration/report.md
research/g0-s1-harness-integration/vite-fixture-results.md
research/g0-s1-harness-integration/windows-poc-test-r2.ps1
research/g0-s1-harness-integration/windows-poc-test.ps1
docs/verification/G0-S1-R2-preflight.md
```

### PR Head total repository files: 20

| Category | Count | Files |
|----------|-------|-------|
| Pre-PR baseline | 3 | .gitignore, README.md, docs/decisions.md |
| R1 deliverables | 13 | ADRs, architecture, mvp, feasibility, verification, report, key-security, loopback-auth, dsh-home, poc-test |
| R2 deliverables | 4 | abi-matrix-r2, loopback-auth-design-r2, vite-fixture-results, poc-test-r2, R2-preflight |
| **Total** | **20** | |

---

## Remaining BLOCKERs

| # | Blocker | Resolution |
|---|---------|-----------|
| B1 | Windows PoC not executed | User must run script on Windows 11 x64 |
| B2 | Client package ModuleLoader issue | Route B blocked; Route A for Phase 0 |

---

## Recommendation

Given the ModuleLoader blocker (R2-4), **Route A (load official Web UI) is the only immediately viable path.** Route B requires either:
1. Writing a `__ModuleLoader__` polyfill (untested, fragile)
2. Writing a custom Vite plugin (medium effort)
3. Waiting for upstream to publish proper ESM browser builds

**For MVP validation: Use Route A.** Revisit Route B when upstream improves client package browser support.

---

## Confirmation

- [x] NOT merged
- [x] NOT exposed credentials
- [x] NOT modified upstream repository
- [x] Gate status: BLOCKED
- [x] Windows script reviewed and hardened
- [x] No fabricated Windows results
