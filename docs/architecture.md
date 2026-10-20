# Ductor v2 architecture

Ductor deploys the infrastructure behind an agent team. It is an operator tool,
not an agent runtime. Closing Ductor must not stop conversations, running work,
credential renewal, worker cleanup, or access to saved knowledge.

| Component | Owns | Does not own |
| --- | --- | --- |
| Ductor + Ansible | Desired configuration, verified SSH administration, deployment, status, explicit upgrades and backups | Agent scheduling, leases, inference, token renewal |
| OpenClaw | Conversations, agents, model routing, bounded delegation, sessions and native memory | Ductor host administration |
| Crabbox | Worker creation, connection, reuse and lifecycle through its native Incus provider | Company policy or a Ductor scheduler |
| Incus | VM/container isolation, projects, profiles, storage, network policy and enforceable quotas | Model credentials |
| OpenBao + OpenBao Agent | Scoped application secrets; native AppRole login and renewable token delivery | OAuth/subscription sign-in unsupported by a provider |
| Git + ordinary files | Portable instructions, reviewed knowledge sources, code and results | Automatic permission enforcement |

## Administration and runtime are separate

Ductor reaches every managed server over SSH, including a server on which the
controller itself runs. Host keys must already be verified. Ansible changes the
selected host; Docker and Incus commands run there. The Ductor container does not
mount a Docker socket or expose an agent broker.

After deployment, OpenClaw uses its native Crabbox integration. Crabbox reaches
the configured Incus API with a project-scoped client identity and reaches worker
guests over SSH. Workers connect to the gateway using OpenClaw's own protocol.
OpenBao Agent renews credentials without Ductor. These runtime connections are
not routed through the deployment controller.

The main gateway can be provisioned as a dedicated Incus service VM with its own
project, private address and controlled network paths. Its worker certificate is
restricted to a different project and cannot administer the service VM through
that project authorization. Ductor retains the hypervisor/guest SSH deployment
authority on the controller. See the [service-VM runbook](service-vm.md).

## Explicit placement

Each gateway chooses an explicit required worker pool. Pool-specific launchers
select an immutable Crabbox configuration; they do not allocate capacity, store
leases, or decide where work should run. Multiple pools and gateways allow
placement on different LAN or external servers.

This release does not invent an automatic cross-host scheduler. A gateway cannot
silently spill work onto another host when its required pool is full or
unavailable. Incus project quotas enforce pool limits. Ductor also checks declared
host budgets, including operating-system headroom, before deployment. Declared
budgets do not reserve hardware against unrelated processes on a shared server.

## Trust boundaries

A gateway serves a trusted team. It is not a hostile multi-tenant boundary.
Separate gateways, credentials and worker projects are required where accounts
or teams must be isolated. A model subscription does not automatically authorize
unattended use; native sign-in and the provider's supported execution path remain
necessary.

The dedicated service-VM route retains native token authentication and manual
browser-device approval behind the operator's TLS proxy. Organizational SSO can
restrict admission at that proxy. It does not convert a shared gateway token
into per-user tenancy, account isolation or independent attribution.

The gateway holds the Incus client identity and therefore has infrastructure
authority within the configured project. That identity, SSH administrator keys,
OpenBao recovery material and AppRole bootstrap credentials must never enter an
agent prompt, worker filesystem or repository. Scoped provider values reach the
supported native integration rather than a general-purpose secret-sharing tool.

## Portable state

The operator owns service domains, external TLS and reverse proxies. Persistent
service directories are explicit bind mounts on their service hosts. Ductor's
configuration is JSON; reviewed company knowledge and project records can remain
Markdown and Git. Native service backups preserve application-specific state.

The default stack excludes Paperclip, MemPalace, ContextForge, n8n and Memcached.
They can be reconsidered for a concrete gap; none is required merely to duplicate
OpenClaw, durable files, or the existing deployment engine. Memcached is not a
durable knowledge store.

See [deployment ownership](deployment-contract.md), [worker constraints](platform-integration.md)
and [production qualification](production-qualification.md).
