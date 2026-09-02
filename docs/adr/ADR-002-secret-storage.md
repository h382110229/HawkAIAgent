# ADR-002: Secret Storage

## Status

Accepted — 2026-08-20

## Context

HawkAIAgent needs to store API keys for DeepSeek (and potentially other providers). The approach must:
- Protect keys at rest
- Work on Windows (primary target)
- Integrate with Harness credential system
- Not require user to manage a master password

## Options

### 1. AES encrypted file (original proposal)
- **Pros:** Cross-platform, no OS dependency
- **Cons:** Requires master password or hardcoded key, not OS-integrated

### 2. Electron safeStorage → env injection
- **Pros:** OS-native encryption (DPAPI on Windows), no master password, simple
- **Cons:** Decrypted key in subprocess env, same-UID exposure

### 3. Electron safeStorage → Named Pipe/IPC
- **Pros:** Point-to-point delivery, no env exposure
- **Cons:** Complex, requires custom Harness credential provider

### 4. Upstream OS-keychain provider
- **Pros:** Strongest isolation, OS-enforced
- **Cons:** Not yet implemented upstream, requires contribution

## Evidence

1. `credentials-local/README.md`: "A same-UID process can read the document... an OS-keychain provider is the deferred answer"
2. `safeStorage` uses DPAPI on Windows — no master password needed
3. Subprocess env scrubbing is heuristic (`*KEY*`, `*PASSWORD*` patterns)
4. Agent tools inherit parent env — key exposure possible

## Decision

**MVP: safeStorage → env injection (Option 2)**

Rationale:
- DPAPI provides adequate static protection for Developer Preview
- Env injection is the simplest integration with upstream credentials-local
- Risk is acceptable for single-user desktop app on own machine

**Stable release: Evaluate upstream keychain provider or Named Pipe (Option 3/4)**

## Consequences

- Key decrypted in main process memory on app start
- Key passed to Harness via `process.env.DEEPSEEK_API_KEY`
- Agent child processes inherit env (potential exposure)
- Must document risk in UI settings page
- Future: migrate to OS-keychain when upstream supports it

## Rejected Alternatives

- **AES encrypted file:** Requires master password UX, less secure than DPAPI
- **Named Pipe:** Too complex for MVP, requires custom credential provider
- **Upstream keychain:** Not yet available

## Open Questions

- [ ] Upstream timeline for OS-keychain provider
- [ ] Can Harness credential provider accept Named Pipe input?
- [ ] Windows Credential Manager API access from Electron
