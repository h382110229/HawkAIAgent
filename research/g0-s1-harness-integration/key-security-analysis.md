# R1-05: Key Security Analysis (Revised)

## Previous (incorrect) statement
> "只在 Harness 启动时注入，不在运行时暴露"
> "Agent 无法获得 Key"

## Corrected threat model

### safeStorage → env injection

**Flow:**
1. Main process: `safeStorage.encrypt(key)` → encrypted blob stored on disk
2. On Harness start: `safeStorage.decrypt(blob)` → plaintext key
3. Pass via `process.env.DEEPSEEK_API_KEY` to Harness subprocess
4. Harness reads env (highest priority layer in credentials-local)

**Exposure points:**
- Decrypted key exists in Harness process memory
- Key is in Harness subprocess `process.env`
- All child processes of Harness inherit env (bash, pwsh tools)
- Same-UID processes can read `/proc/<pid>/environ` on Linux

### subprocess-local env scrubbing

Harness's subprocess-local module scrubs env vars matching patterns:
- `*KEY*`, `*PASSWORD*`, `*SECRET*`, `*TOKEN*`, `*DSH_*`

**Limitations:**
- Heuristic pattern matching — custom named secrets may be missed
- Does not prevent Harness plugins from reading process.env
- Does not prevent same-UID processes from reading /proc/<pid>/environ
- This is **accidental exposure reduction**, NOT strong isolation

### Upstream OS-keychain credential provider

- Explicitly deferred in `credentials-local/README.md`
- Would store keys in Windows Credential Manager
- Agent processes could NOT read Credential Manager (different API surface)
- Not yet implemented upstream

### Comparison of approaches

| Approach | Static protection | Runtime protection | Agent isolation | Complexity |
|----------|------------------|-------------------|-----------------|------------|
| safeStorage → env | ✅ DPAPI | ⚠️ In process.env | ❌ Inherits | Low |
| safeStorage → IPC/Named Pipe | ✅ DPAPI | ✅ Point-to-point | ✅ No env exposure | Medium |
| Upstream keychain provider | ✅ OS keychain | ✅ OS-enforced | ✅ Cannot read | Medium (upstream) |
| credentials-local (current) | ⚠️ File perms | ❌ Same-UID readable | ❌ Full access | None |

### Recommendation by phase

**Developer Preview (current):**
- Use safeStorage → env injection
- Accept heuristic scrubbing as mitigation
- Document risk in UI

**Stable release:**
- Contribute or implement OS-keychain provider
- OR: safeStorage → Named Pipe with restricted ACL
- Agent tools should NOT inherit full env

### Concrete implementation for MVP

```typescript
// main.ts — Electron main process
import { safeStorage } from 'electron';
import { spawn } from 'child_process';

// On user saves API key
function saveApiKey(key: string) {
  const encrypted = safeStorage.encryptString(key);
  fs.writeFileSync(credentialPath, encrypted);
}

// On Harness start
function startHarness() {
  const encrypted = fs.readFileSync(credentialPath);
  const key = safeStorage.decryptString(encrypted);
  
  // Pass via env — Harness credentials-local reads this as priority 1
  const child = spawn('node', ['dsh', 'web', '--no-open'], {
    env: {
      ...process.env,
      DEEPSEEK_API_KEY: key,
      DSH_HOME: dshHome,
    },
  });
  
  // key is now in child process env — exposure risk documented
}
```

**Risk accepted for MVP:** Key in subprocess env. Mitigated by:
1. Local-only (no network exposure)
2. Short-lived (tied to app session)
3. User's own machine (same trust boundary)
