# Deployment and runtime ownership

This branch aligns a fresh installation with the following contract. No existing
deployment or data migration is assumed.

## Ductor

Ductor installs and configures the harness, monitors service health, and performs
explicit service and self updates. Its wizard collects SSH hosts, verified host
keys, credential references, service domains and ports, storage paths, resource
budgets, and the initial Paperclip addon configuration.

Every service host is administered through SSH, including the server on which
Ductor happens to run. The Ductor container has no Docker socket mount and no
incoming agent broker. The controller can parse Compose locally; deployment and
Docker Engine preparation happen on the selected SSH host.

Ductor must not own agent leases, run a lease reaper, execute agent work, or be
required for Paperclip's continued agent operation.

## Paperclip addon

A separately versioned Paperclip addon and its restricted runtime companion own
Incus environment acquisition, approved agent profiles, resource admission,
bindings, delegation, guest execution and runtime reconciliation. Their durable
state and credentials belong to their services, independently of Ductor.

Paperclip remains the task, approval, session and team dashboard. MemPalace holds
scoped knowledge and checkpoints; ContextForge grants approved MCP access;
OpenBao supplies scoped external credentials; Incus and opencode-platform supply
execution isolation. Native Paperclip authentication and Codex connections keep
their own supported ownership.

Deployment configures these integrations. Simply mentioning a memory service in
an agent prompt is not an authorization boundary or a backup mechanism.

## Verification gates

- Controller startup and service operations require no mounted Docker socket.
- Same-server and remote deployment use the same verified SSH transport.
- Dependency preparation is performed on the selected SSH host.
- Bind-mounted service data is stored on that host and survives recreation.
- Resource admission and published-port collisions are checked per host.
- Ductor can stop after setup without preventing addon runtime operation.
- Missing credentials, approved scopes or capacity fail closed.
- Each service can be inspected and updated through Ductor.
- External domains and ports are configurable; operator-managed TLS is the default.
- CI distinguishes real SSH/container checks from mocked Incus/provider checks.

Live Incus, Paperclip/Codex authentication and the complete service integration
must be tested on actual infrastructure before production-readiness is claimed.
