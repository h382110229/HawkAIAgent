# ADR-003: Windows Sandbox Strategy

## Status

Accepted — 2026-08-20

## Context

Harness agents can execute shell commands and read/write files. On Windows, we need to confine agent tool execution. The user's corporate Windows machine cannot install Docker Desktop.

## Options

### 1. Windows ACL sandbox (Harness built-in)
- **Pros:** Built into Harness, no extra dependencies
- **Cons:** Partial enforcement, no read restriction, Everyone ACL gaps

### 2. Docker Desktop
- **Pros:** Strong isolation
- **Cons:** Cannot install on corporate machine (user constraint)

### 3. E2B (remote sandbox)
- **Pros:** Full isolation, cloud-based
- **Cons:** Requires internet + account, latency, cost

### 4. Windows Job Objects + process restrictions
- **Pros:** OS-level process containment
- **Cons:** Complex to implement, no file-system policy

## Evidence

1. `docs/subsystems/sandbox.md`: Windows ACL enforcement is `partial`
2. "workspace-write file policy confines mutations rather than reads"
3. "Network and process visibility are outside this vocabulary"
4. `read-only` mode: "the Windows ACL runner grants no explicit writable root and reports partial enforcement for its ambient ACL gaps"
5. Docker Desktop explicitly blocked by corporate policy

## Decision

**MVP: Windows ACL sandbox (Option 1) with documented limitations**

Rationale:
- Only viable option that works without Docker
- Built into Harness — no custom implementation
- Partial enforcement is acceptable for single-user desktop
- User is running on their own machine (trust boundary)

## Consequences

- Agent can READ any file the user can read
- Agent writes confined to workspace root + temp (partial)
- Network access is NOT restricted
- Process visibility is NOT restricted
- Must warn user in UI about limitations
- Future: evaluate E2B as optional remote execution mode

## Limitations (documented)

| Aspect | Status |
|--------|--------|
| Write restriction | Partial (workspace root + temp) |
| Read restriction | None |
| Network restriction | None |
| Process visibility | None |
| Enforcement | Partial (older kernel ABI gaps) |

## Rejected Alternatives

- **Docker:** Blocked by corporate policy
- **E2B:** Requires internet, not suitable as default
- **Job Objects:** Too complex, no file policy

## Open Questions

- [ ] Can Windows Defender Application Control supplement ACL sandbox?
- [ ] What specific operations bypass partial enforcement?
- [ ] E2B as opt-in for high-security scenarios
