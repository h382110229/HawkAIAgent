# R2: ABI Matrix (Revised)

## Two Independent Dimensions

### Dimension 1: UI Layer

| Option | Description | Native deps risk |
|--------|------------|-----------------|
| Official Web UI | Electron BrowserWindow loads `localhost:3080` | None |
| Hawk React UI + official client packages | Custom renderer using `dsh-client-connection`, `dsh-api-remotes/client` | None (client packages are pure JS) |

### Dimension 2: Harness Host Runtime

| Option | Description | Native deps | electron-rebuild | Status |
|--------|------------|-------------|-----------------|--------|
| Independent Node 22 | `spawn('node', ['dsh', 'web'])` | node-pty, koffi (host-side) | NOT needed (separate process) | ⚠️ Needs verification |
| ELECTRON_RUN_AS_NODE | `ELECTRON_RUN_AS_NODE=1` + Electron binary as Node | Same as above | NOT needed | ❌ NOT tested, cannot claim viable |
| Electron Main embedded | `import` Harness directly into Electron main | node-pty, koffi, SQLite | REQUIRED | ❌ High risk |

## Key Facts

1. **Client packages** (`dsh-client-connection`, `dsh-api-remotes`, `dsh-api-gateway`): **No native addons.** Pure JS. Confirmed by scanning installed `node_modules/`.

2. **Harness Host** depends on:
   - `node-pty` — pseudo-terminal for bash/pwsh
   - `koffi` — FFI for native bindings (if used)
   - These are in the HOST process, not the client

3. **Independent Node 22 route**: Native addons run in the spawned Node process. No electron-rebuild needed because Electron never loads them. BUT must verify node-pty loads correctly on Windows with the bundled Node 22.

4. **ELECTRON_RUN_AS_NODE**: Has NOT been tested. Cannot claim "viable" without evidence. The Electron binary compiled with a specific Node ABI; native addons compiled for system Node may not load.

5. **Electron Main embedded**: High risk. Would require electron-rebuild for all native addons. Not recommended.

## Verification Required

| Test | Command | Expected |
|------|---------|----------|
| node-pty on Windows + Node 22 | `node -e "require('node-pty')"` | Loads or clear error |
| koffi on Windows + Node 22 | `node -e "require('koffi')"` | Loads or clear error |
| ELECTRON_RUN_AS_NODE | Set env, spawn Electron binary, require node-pty | Unknown — NOT tested |

## Current Recommendation

**Independent Node 22 + spawn** — lowest risk, no electron-rebuild, but native addon verification BLOCKED until Windows PoC.
