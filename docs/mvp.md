# HawkAIAgent MVP Definition

## Scope

**Vertical slice:** Windows 11 x64, single window, single workspace, single provider, basic chat with tools and approval.

## Included

| Feature | Details |
|---------|---------|
| Platform | Windows 11 x64 |
| Window | Single window, single workspace |
| Provider | DeepSeek only |
| Model config | Settings page to enter API key |
| Session | Create, resume, persist |
| Streaming | Real-time response display via WebSocket |
| Tool calls | Display tool call cards |
| Approval | Accept/reject tool execution |
| Tools | PowerShell + file read/write |
| Lifecycle | Harness spawn, health check, crash prompt, restart button |
| Packaging | Development build (electron-forge) |
| Key storage | Electron safeStorage (DPAPI) |
| Auth | Loopback token validation (hawk-auth plugin) |
| DSH_HOME | `<userData>/dsh-home/` (isolated from ~/.dsh) |

## Deferred

| Feature | Reason | Target Phase |
|---------|--------|-------------|
| Multi-window | Complexity, not needed for validation | Phase 2 |
| Global hotkey | Nice-to-have | Phase 2 |
| Task Scheduler | Post-MVP feature | Phase 3 |
| Image generation | Requires multi-model routing | Phase 3 |
| Video generation | Requires multi-model routing | Phase 3 |
| Agent Teams | Experimental upstream feature | Phase 3 |
| Plugin marketplace | No upstream support yet | Phase 3 |
| macOS | Windows first | Phase 2 |
| Linux | Windows first | Phase 2 |
| Auto-update | Post-MVP | Phase 2 |
| Self-modification | **Explicitly excluded** — security risk | Never as-is |
| Multiple providers | Single provider for MVP | Phase 2 |
| Multi-model routing | Single model for MVP | Phase 3 |

## Acceptance Criteria

1. ✅ App launches on Windows 11 x64
2. ✅ Harness subprocess starts and responds to health check
3. ✅ User can enter DeepSeek API key in Settings
4. ✅ User can create a new chat session
5. ✅ User can send a message and see streaming response
6. ✅ Agent tool calls display correctly
7. ✅ User can approve/reject tool execution
8. ✅ Session persists across app restarts
9. ✅ Harness crash shows restart prompt (no silent failure)
10. ✅ API key encrypted with safeStorage
11. ✅ Loopback API requires auth token
12. ✅ No orphan processes after app exit
