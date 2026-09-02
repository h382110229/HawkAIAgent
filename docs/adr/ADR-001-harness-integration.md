# ADR-001: Harness Integration Method

## Status

**Accepted for Phase 0 / Provisional for product architecture** — 2026-08-20
**Updated: 2026-08-21 (G0-S1-R3)**

## Context

HawkAIAgent needs to integrate DeepSeek Harness as its AI backend. Three routes were evaluated:

- Route A: Electron BrowserWindow loading official dsh web page
- Route B: Custom React UI reusing official client packages
- Route C: Custom BFF wrapping Harness API

## Options

### Route A: Load official web page
- **Pros:** Zero UI development, fastest validation
- **Cons:** No UI customization, completely upstream-dependent

### Route B: Custom UI + official client packages
- **Pros:** Full UI control, reuses proven transport layer
- **Cons:** Medium coupling to upstream packages, must handle `window.__ModuleLoader__`

### Route C: Custom BFF
- **Pros:** Full API control, upstream buffer
- **Cons:** High development cost, reverse-engineering burden, unnecessary

## Evidence

1. Harness has complete Typert API Gateway (HTTP RPC + WebSocket)
2. Official client packages (`dsh-client-connection`, `dsh-api-remotes`) published to npm at 0.1.0-rc.8
3. npm install succeeds with 59 transitive deps, 0 peer warnings
4. Client packages use `window.__ModuleLoader__` — Vite can produce a bundle, **but the browser runtime still requires `window.__ModuleLoader__`; Route B remains blocked.**
5. No API gaps identified for MVP scope
6. All peer deps resolve via npm (not workspace-only)

## Decision

**Route A for Phase 0 validation.** Route B is a product-architecture candidate. It is not an accepted target until browser runtime compatibility is independently verified. Route C is deferred.

## Consequences

- Route B: Vite can produce a bundle, but the browser runtime still requires `window.__ModuleLoader__`; Route B remains blocked until polyfill, Vite plugin, or upstream browser build is verified.
- Must pin exact upstream versions with lockfile
- Must track upstream API changes between releases

## Rejected Alternatives

- **Route C (BFF):** No proven API gaps. Adds unnecessary complexity and process.
- **In-process Harness:** Electron's Node can run Harness but native addon ABI risk is high. Subprocess is safer.

## Open Questions

- [ ] Exact WebSocket message format for events.mux
- [ ] Agent approval flow UI protocol
- [ ] File/image upload via API
- [ ] `window.__ModuleLoader__` polyfill or Vite plugin feasibility
- [ ] Harness HTTP middleware and WS upgrade hook availability (affects loopback auth)
