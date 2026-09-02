# R2: Loopback Authentication Design (Revised)

## Three Candidates

### Candidate A: Authorization Header + WebSocket subprotocol

```
HTTP: Authorization: Bearer <token>
WS: new WebSocket(url, ['hawk-auth', token])
```

**Pros:**
- Standard HTTP auth pattern
- No cookie overhead

**Cons:**
- Browser WebSocket API does NOT support custom headers
- Subprotocol is a workaround, not standard auth
- `@deepseek-ai/dsh-client-connection` has NO public API for custom auth headers or subprotocols
- Would need to fork/patch the client package
- Cannot claim "20 lines" — integration with official client is unverified

**Status:** ⚠️ Blocked by client package API limitations

### Candidate B: HttpOnly SameSite=Strict session cookie (PREFERRED CANDIDATE)

> **Status: Candidate / pending PoC — not final security design**
>
> **Critical limitation:** Cookie 按 Host/Domain/Path 匹配，**不按 TCP 端口隔离**。为 127.0.0.1 设置的 Cookie 可能被发送到该 Host 的其他端口。如果同一机器上其他服务监听不同端口，Cookie 可能泄露。
>
> **Additional constraints:**
> - HttpOnly 只能阻止 JS 直接读取 Token，**不能阻止 XSS 发起已认证请求**
> - SameSite 不能替代 Origin、Host、CSP 和 Renderer 隔离
> - 需要验证 Electron、官方 UI、HTTP RPC、WebSocket Upgrade 的实际兼容性
> - Harness 是否暴露可用的 HTTP middleware 和 WS upgrade hook **尚未验证**

```
1. Main process generates 32-byte random token (hex or base64url)
2. Main process sets cookie via Electron session API:
   session.defaultSession.webContents.session.cookies.set({
     url: 'http://127.0.0.1:<port>',
     name: '__hawk_auth',
     value: <token>,
     httpOnly: true,
     sameSite: 'strict',
     secure: false,        // localhost, not HTTPS
     path: '/',
     expirationDate: ...   // session lifetime
   });
3. Renderer loads — cookie auto-attached by Chromium
4. Official fetch() and WebSocket carry cookie automatically
5. Harness auth plugin reads Cookie header on HTTP and WS Upgrade
6. Token never enters Renderer JS, URL, localStorage, or logs
7. On app exit: cookie expires (session cookie)
8. On next launch: new token generated
```

**Pros:**
- Token never in Renderer JS — XSS cannot exfiltrate
- Official `fetch()` and `WebSocket` carry cookie automatically — no client package modification needed
- SameSite=Strict prevents CSRF
- httpOnly prevents JS access
- Works with `@deepseek-ai/dsh-client-connection` without changes

**Cons:**
- Cookie scoped to `127.0.0.1:<port>` — port must be known at cookie-set time
- Harness auth plugin must parse Cookie header (standard)
- If port changes, cookie must be re-set

**Status:** ✅ Preferred — requires no client package changes

### Candidate C: Electron IPC carrier

```
1. Main process generates token
2. Renderer fetches token via IPC: ipcRenderer.invoke('get-auth-token')
3. Renderer passes token to every request manually
```

**Pros:**
- Token delivery is explicit and auditable
- No cookie dependency

**Cons:**
- Token enters Renderer JS — XSS can exfiltrate
- Must patch every API call to include token
- Official client packages don't support custom auth injection
- Highest integration complexity

**Status:** ❌ Not recommended — defeats purpose of auth

## Decision

**Candidate B (HttpOnly Cookie) is preferred.**

Key advantage: Official client packages (`fetch`, `WebSocket`) automatically send cookies. No modification to `@deepseek-ai/dsh-client-connection` needed.

## Implementation Sketch

### Main process (token generation + cookie)
```typescript
import { randomBytes } from 'crypto';
import { session } from 'electron';

const token = randomBytes(32).toString('hex');

// Set before renderer loads
await session.defaultSession.cookies.set({
  url: `http://127.0.0.1:${port}`,
  name: '__hawk_auth',
  value: token,
  httpOnly: true,
  sameSite: 'strict',
  secure: false,
  path: '/',
});

// Pass to Harness via env
spawn('node', ['dsh', 'web', '--no-open'], {
  env: { ...process.env, HAWK_AUTH_TOKEN: token, DSH_HOME: dshHome },
});
```

### Harness Cordis plugin (auth validation)
```typescript
export const name = 'hawk-auth';
export const inject = ['hostWebserver'];

export function apply(ctx: Context) {
  const token = process.env.HAWK_AUTH_TOKEN;
  if (!token) return;

  // HTTP middleware
  ctx.hostWebserver.use((req, res, next) => {
    const cookies = parseCookies(req.headers.cookie || '');
    if (cookies['__hawk_auth'] !== token) {
      res.writeHead(401);
      res.end('Unauthorized');
      return;
    }
    return next();
  });

  // WebSocket upgrade validation
  ctx.on('hostWebserver/upgrade', (req, socket) => {
    const cookies = parseCookies(req.headers.cookie || '');
    if (cookies['__hawk_auth'] !== token) {
      socket.destroy();
      return;
    }
  });
}
```

## Open Questions

1. Does `@deepseek-ai/dsh-host-webserver` expose a middleware hook? (Must verify)
2. Does the WS upgrade handler receive Cookie headers? (Standard browsers send them)
3. What if Harness changes its webserver plugin interface?
4. Cookie 不按端口隔离 — 如何防止跨端口泄露？
5. XSS 能否利用已认证 Cookie 发起请求（即使无法读取 Token）？
6. 组合防御候选是否足够？
