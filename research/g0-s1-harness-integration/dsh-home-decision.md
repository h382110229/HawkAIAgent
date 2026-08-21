# R1-07: DSH_HOME Decision

## Decision

```
DSH_HOME = path.join(app.getPath('userData'), 'dsh-home')
```

### Windows path examples
- `C:\Users\霍克\AppData\Roaming\HawkAIAgent\dsh-home\`
- `C:\Users\John Smith\AppData\Roaming\HawkAIAgent\dsh-home\`

### Directory structure

```
<userData>/dsh-home/
├── profiles/           # Profile configurations
│   ├── web/           # Web profile (default)
│   │   ├── package.json
│   │   └── cordis.patch.yml
│   └── headless/
├── settings.yaml      # User settings
├── .credentials.yaml  # Encrypted credentials (if using upstream)
├── sessions/          # Session persistence (JSONL logs)
│   └── <session-id>/
│       ├── log.jsonl
│       └── state.json
├── logs/              # Application logs
└── cordis.patch.yml   # Home-level patch layer
```

### Data lifecycle

| Data | Preserve on upgrade | Preserve on rollback | Delete on uninstall |
|------|--------------------|--------------------|-------------------|
| profiles/ | ✅ Yes | ✅ Yes | ❌ User choice |
| settings.yaml | ✅ Yes | ✅ Yes | ❌ User choice |
| sessions/ | ✅ Yes | ✅ Yes | ❌ User choice |
| .credentials.yaml | ✅ Yes | ✅ Yes | ❌ User choice |
| logs/ | ⚠️ Prune old | ⚠️ Prune old | ✅ Yes |
| cordis.patch.yml | ✅ Yes | ✅ Yes | ❌ User choice |

### Path edge cases

- **Spaces in username:** `C:\Users\John Smith\...` — ✅ works (no shell escaping needed)
- **Chinese username:** `C:\Users\霍克\...` — ✅ works (Node.js handles UTF-8)
- **Non-ASCII app path:** Avoid installing to non-ASCII paths

### Isolation from ~/.dsh

- HawkAIAgent uses `<userData>/dsh-home/` — completely separate
- System `dsh` CLI continues using `~/.dsh/`
- No data sharing between the two
- User can use both independently

### Implementation

```typescript
import { app } from 'electron';
import path from 'path';

const DSH_HOME = path.join(app.getPath('userData'), 'dsh-home');

// Pass to Harness subprocess
const child = spawn('node', ['dsh', 'web', '--no-open'], {
  env: {
    ...process.env,
    DSH_HOME,
    DEEPSEEK_API_KEY: decryptedKey,
  },
});
```
