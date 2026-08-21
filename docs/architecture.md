# HawkAIAgent Architecture

## System Overview

```mermaid
graph TB
    subgraph Electron["Electron App"]
        Main["Main Process<br/>- Harness lifecycle mgmt<br/>- Native window & tray<br/>- safeStorage bridge<br/>- Auth token generation<br/>- Logging & crash detection"]
        Renderer["Renderer Process<br/>- React + TypeScript<br/>- Custom UI (Stitch + Shadcn)<br/>- dsh-client-connection<br/>- dsh-api-remotes/client<br/>- Auth token via IPC"]
        Main <-->|IPC: auth token, lifecycle| Renderer
    end

    subgraph Harness["Harness Host (subprocess)"]
        DSH["@deepseek-ai/dsh web --no-open<br/>- Agent loop<br/>- Session management<br/>- Tools & approval<br/>- Typert API Gateway<br/>- WebSocket event streams<br/>- Auth validation plugin"]
    end

    subgraph Security["Security Layer"]
        SafeStorage["Electron safeStorage<br/>(DPAPI on Windows)"]
        AuthPlugin["hawk-auth plugin<br/>(token validation)"]
        Sandbox["Windows ACL Sandbox<br/>(partial enforcement)"]
    end

    Main -->|spawn + env vars| DSH
    Renderer -->|HTTP POST /api + Bearer token| DSH
    Renderer -->|WS /api/events.mux + subprotocol| DSH
    Renderer -->|WS /api/events.host + subprotocol| DSH
    Main --> SafeStorage
    DSH --> AuthPlugin
    DSH --> Sandbox
```

## Data Flow

### Chat Message Flow

```
User types message
    ↓
Renderer: HTTP POST /api { method: "session.send", params: { prompt, sessionId } }
    ↓
Harness: agent.followup() → agent loop claims prompt
    ↓
Harness: LLM stream → session event log
    ↓
Harness: WebSocket events.mux → ServerRequest frames
    ↓
Renderer: Display streaming response
```

### Tool Approval Flow

```
Harness: tool/call event → approval policy check
    ↓
WebSocket events.mux → tool_call frame with approval_required
    ↓
Renderer: Show approval dialog
    ↓
User clicks approve/reject
    ↓
Renderer: HTTP POST /api { method: "tool.approve", params: { callId, approved } }
    ↓
Harness: tools/execute or tools/reject
```

### Key Management Flow

```
User enters API key in Settings
    ↓
Renderer: IPC → Main process
    ↓
Main: safeStorage.encryptString(key) → write to disk
    ↓
On app start:
Main: safeStorage.decryptString(blob) → plaintext key
    ↓
Main: spawn harness with DEEPSEEK_API_KEY in env
    ↓
Harness: credentials-local reads env (priority 1)
```

## Component Responsibilities

| Component | Technology | Responsibilities |
|-----------|-----------|-----------------|
| Main Process | Electron + Node.js | Window management, Harness lifecycle, safeStorage, auth token, crash detection |
| Renderer | React + TypeScript + Tailwind | UI rendering, user interaction, API calls, event display |
| Harness Host | @deepseek-ai/dsh | Agent loop, session management, tools, approval, persistence |
| Auth Plugin | Cordis plugin | Token validation on HTTP and WebSocket |
| Sandbox | Windows ACL | File-effect confinement for agent tools |

## DSH_HOME

```
<app.getPath('userData')>/dsh-home/
├── profiles/           # Profile configurations
├── settings.yaml       # User settings
├── sessions/           # Session persistence (JSONL)
├── logs/               # Application logs
└── cordis.patch.yml    # Home-level patch layer
```

Completely isolated from `~/.dsh/` used by system `dsh` CLI.

## Security Boundaries

| Boundary | Protection | Limitation |
|----------|-----------|------------|
| Static key storage | safeStorage/DPAPI | Decrypted in memory at runtime |
| Runtime key passing | env var to subprocess | Same-UID processes can read env |
| Loopback API | hawk-auth token | Token in process memory |
| Browser trust | Host/Origin/sec-fetch-site | Not authentication |
| File effects | Windows ACL sandbox | Partial enforcement, no read restriction |
