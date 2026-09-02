# R1-06: Loopback API Authentication Design

> **Status: Superseded by loopback-auth-design-r2.md**
> The Bearer + WS subprotocol approach described below is blocked by client package API limitations.
> See R2 design for current candidates.

## Previous (incorrect) statement
> "无认证层，桌面场景可接受"

## Corrected risk assessment

- Host/Origin/sec-fetch-site: prevents browser confused-deputy and DNS rebinding ONLY
- NOT authentication — any local process can craft loopback requests
- API exposes: prompts, tool execution, settings, credentials, session data
- Random port is NOT authentication (port is discoverable via /proc, netstat)

## Minimal auth design (thin plugin, not BFF)

### Token generation

```typescript
// main.ts — Electron main process
import { randomBytes } from 'crypto';

// Generate 32-byte hex token on each app launch
const authToken = randomBytes(32).toString('hex');
```

### Token delivery to Harness

Option A: Environment variable
```typescript
const child = spawn('node', ['dsh', 'web', '--no-open'], {
  env: { ...process.env, HAWK_AUTH_TOKEN: authToken },
});
```

Option B: CLI argument (less secure — visible in process list)
```
dsh web --no-open --auth-token <token>
```

Option C: One-shot stdin injection (most secure)
```
// Write token to Harness stdin on startup
child.stdin.write(authToken + '\n');
```

**Recommended: Option A** — env var is not visible in /proc on Windows, simple to implement.

### Harness-side validation

Requires a thin Cordis plugin (NOT a BFF):

```typescript
// dsh-plugin-auth.ts
export const name = 'hawk-auth'
export const inject = ['hostWebserver']

export function apply(ctx: Context) {
  const token = process.env.HAWK_AUTH_TOKEN
  if (!token) return // no auth configured

  // HTTP middleware
  ctx.hostWebserver.use(async (req, res, next) => {
    const auth = req.headers.authorization
    if (auth !== `Bearer ${token}`) {
      res.writeHead(401)
      res.end('Unauthorized')
      return
    }
    return next()
  })

  // WebSocket upgrade validation
  ctx.on('hostWebserver/upgrade', (req, socket) => {
    // Check subprotocol or first message
    // See below for WebSocket auth strategy
  })
}
```

### WebSocket authentication challenge

**Problem:** Browser WebSocket API does NOT support custom headers:
```javascript
// ❌ Not possible in browser
new WebSocket('ws://localhost:3080/api/events.mux', {
  headers: { Authorization: 'Bearer <token>' } // NOT supported
});
```

**Solutions evaluated:**

| Approach | Security | Complexity | Browser support |
|----------|----------|------------|-----------------|
| Query parameter `?token=xxx` | ⚠️ Token in URL/logs | Low | ✅ Universal |
| HttpOnly SameSite cookie | ✅ Not JS-accessible | Medium | ✅ Universal |
| WebSocket subprotocol | ✅ Custom header equivalent | Low | ✅ Universal |
| First-message auth | ✅ Token in first WS frame | Medium | ✅ Universal |
| Electron IPC carrier | ✅ No network at all | High | Electron only |

**Recommended: WebSocket subprotocol**

```javascript
// Renderer
const ws = new WebSocket('ws://127.0.0.1:3080/api/events.mux', [
  'hawk-auth',
  authToken,  // token as subprotocol
]);

// Harness plugin validates on upgrade
ctx.on('hostWebserver/upgrade', (req, socket) => {
  const protocols = req.headers['sec-websocket-protocol']?.split(',').map(s => s.trim())
  if (!protocols?.includes(token)) {
    socket.destroy()
    return
  }
})
```

**Alternative: Cookie approach**
```javascript
// Main process sets cookie before renderer loads
session.defaultSession.webContents.session.cookies.set({
  url: 'http://127.0.0.1:3080',
  name: 'hawk-auth',
  value: authToken,
  httpOnly: true,
  sameSite: 'strict',
  secure: false, // localhost, not HTTPS
});

// Harness plugin reads cookie on HTTP and WS
const cookie = parseCookies(req.headers.cookie)
if (cookie['hawk-auth'] !== token) { reject() }
```

### Token lifecycle

1. Generated fresh on each app launch
2. Held ONLY in Electron main process memory
3. Passed to Harness via env (cleared after startup)
4. Passed to renderer via IPC (contextBridge, not global)
5. NOT stored in localStorage, sessionStorage, or disk
6. NOT written to logs
7. Destroyed on app exit

### Renderer access

```typescript
// preload.ts
contextBridge.exposeInMainWorld('hawkAPI', {
  getAuthToken: () => ipcRenderer.invoke('get-auth-token'),
});

// renderer.ts
const token = await window.hawkAPI.getAuthToken();
// Use token for HTTP and WebSocket connections
```

### Summary

- Thin Cordis plugin on Harness side (~50 lines)
- Token generation + delivery in Electron main (~20 lines)
- Subprotocol or cookie for WebSocket auth
- No BFF required
- Token never in URL, logs, or persistent storage
