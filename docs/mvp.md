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
| Auth | Loopback token validation (candidate — pending PoC verification) |
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

## Phase 0 Harness Integration Gate

> 以下为 Harness 集成验证条件。全部通过后才能进入产品 MVP 开发。

- [ ] Harness subprocess starts and responds to `host.describe`
- [ ] WebSocket `/api/events.mux` upgrade succeeds
- [ ] WebSocket `/api/events.host` upgrade succeeds
- [ ] No-Key error path returns expected error (no silent failure)
- [ ] No orphan processes after Harness exit
- [ ] Port released after Harness exit
- [ ] Temp directory cleaned up

## Product MVP Acceptance Criteria

> 以下为桌面应用 MVP 的验收条件。Phase 0 Gate 通过后，逐项实现。

- [ ] App launches on Windows 11 x64
- [ ] Harness subprocess starts and responds to health check
- [ ] User can enter DeepSeek API key in Settings
- [ ] User can create a new chat session
- [ ] User can send a message and see streaming response
- [ ] Agent tool calls display correctly
- [ ] User can approve/reject tool execution
- [ ] Session persists across app restarts
- [ ] Harness crash shows restart prompt (no silent failure)
- [ ] API key encrypted with safeStorage
- [ ] Loopback API requires auth token
- [ ] No orphan processes after app exit

> **注意：** Harness PoC 成功 ≠ 桌面应用 MVP 已完成。Phase 0 Gate 是前置条件，不是验收完成。
