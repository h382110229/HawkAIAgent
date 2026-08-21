# R2-4: Vite Fixture Verification Results

## Test Setup
- Vite 6.4.3
- @deepseek-ai/dsh-client-connection@0.1.0-rc.8
- Node v24.14.0

## Test 1: Import from `/client` subpath

```typescript
import { API_PATH } from '@deepseek-ai/dsh-client-connection/client';
```

**Build result:** ✅ Exit code 0, 386 kB bundle
**Runtime issue:** Bundle contains `window.__ModuleLoader__.load({...})` — requires non-standard global

## Test 2: Import from package root

```typescript
import { API_PATH } from '@deepseek-ai/dsh-client-connection';
```

**Build result:** ❌ FAIL
**Error:** `"AsyncLocalStorage" is not exported by "__vite-browser-external"`
**Cause:** Root entry (`lib/index.js`) imports Host-side code (`node:async_hooks`, `node:crypto`, etc.)

## Conclusion

**BLOCKER:** The official client packages cannot be directly used in a browser/Electron renderer as-is.

- `/client` subpath: Uses `window.__ModuleLoader__` (non-standard)
- Root entry: Contains Node.js-only Host code

### Options
1. **Provide `__ModuleLoader__` polyfill** — shim the global loader before importing
2. **Use Vite plugin** to transform the ModuleLoader pattern
3. **Wait for upstream** to publish proper ESM browser builds
4. **Route A only** — load official Web UI in BrowserWindow (it already handles ModuleLoader)

### Evidence
- `lib/client.js` line 1: `window.__ModuleLoader__.load({...})`
- `lib/index.js` line 2: `import { AsyncLocalStorage } from "node:async_hooks"`
- Bundle size with externalized node builtins: 804 kB (includes full Host-side code)
