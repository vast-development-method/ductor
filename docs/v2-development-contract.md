# Ductor v2 implementation contract

This document describes the interfaces shared by the controller and deployment
roles. Operator setup is documented in the README and the service runbooks.
The complete JSON examples are [standard configuration](../examples/config.example.json)
and [dedicated service VM](../examples/service-vm.example.json); replace their
placeholder infrastructure inputs before use.

## Desired configuration

`schema_version` is `2`. The root objects are `name`, `hosts`, `services`,
`service_vms`, `incus`, `agents`, `model_accounts`, `runtime`, `knowledge` and
`credentials`. Configuration contains references to private inputs, never private
credential values. An explicit SSH public key is allowed in a service-VM definition.
Unknown or unsupported fields fail validation instead of being silently ignored.

| Object | Contract |
| --- | --- |
| `hosts` | Named SSH endpoints, verified host-key file, private-key reference, become policy, dedicated data root, roles and resource budgets with OS reserves |
| `services` | Enabled `openclaw` or `openbao` services with explicit host, image, bind IP, fixed port, HTTPS origin and resource allocation |
| `service_vms` | Exact OpenClaw service/guest/hypervisor link, dedicated Incus project/network, approved image fingerprint, cloud-init public key, resource envelope and explicit network paths |
| `incus.pools` | Approved VM fingerprint, native project/profile, project quotas, instance shape/count, Node version attestation and mTLS file references |
| `incus.bootstrap` | Optional explicitly approved fresh-host initialization, pinned native package, directory storage, bridge and ACL inputs |
| `agents` / `model_accounts` | Exact model and account bindings, explicit gateway rosters and allowed delegation; one account per provider per gateway |
| `runtime` | Bounded native child concurrency, child count, depth and duration |
| `knowledge` | Local approved Markdown snapshot and optional credential-free Git repository/branch protocol |
| `credentials` | Private gateway-token, OpenBao operator/recovery and per-gateway AppRole file references |

Service-VM resources are charged to the physical hypervisor. Service allocations
inside that VM are separately charged to the guest budget. Guest usable capacity
must fit its VM envelope and retain OS/partition overhead; worker quotas remain
separate. A service VM's project and network cannot be a worker pool's project or
network on the same hypervisor.

## Controller and Ansible boundary

The Bash entry point invokes a Python controller. Ansible administers every
service host using verified SSH, including a server on which Ductor happens to
run. Native OpenBao credential operations use the configured HTTPS API. Ductor
has no agent daemon, broker, lease store, reaper or inference path.

The rendered inventory group is `ductor_hosts`. Each selected host receives:

- `ansible_connection: ssh`, its address/port/user/key and become policy;
- strict host-key checking and its explicit verified `known_hosts` path;
- `ductor_host`, enabled assigned `ductor_services`, selected `ductor_pools` and
  selected `ductor_service_vms`;
- `ductor_config`, `ductor_bundle_root`, `ductor_render_root` and the requested
  `ductor_action`.

Selection determines which hosts and services an operation may change. Selecting
one service does not implicitly reconcile every unrelated worker pool. A full
initial deployment reconciles worker prerequisites before gateways.

`plan` is a local desired-state summary, without SSH or host mutation.
`status` and `monitor` inspect live hosts without rendering or reconciling service
configuration. The menu and controller startup do not deploy anything. Explicit
mutation commands own their operation locks; controller availability is not a
runtime dependency.

## Rendered artifacts

The private render directory contains `inventory.json` and integration inputs:

- `services/<id>/`: native service configuration and gateway activation/source
  contracts; company instructions and approved Markdown import files;
- `incus/<pool>/`: `project.json`, `profile.json`, `crabbox.yaml`,
  `incus-config.yml` and the pool-selecting executable wrapper;
- `incus/bootstrap/<host>/`: approved fresh-host preseed and ACL inputs;
- `service-vms/<id>/`: project, network, ACL, profile and immutable ownership inputs.

JSON is used where upstream readers also accept YAML. Ansible uses argument
arrays for remote Compose/Incus commands and hides credential-transfer tasks from
logs and diffs. Services use explicit bind-mounted host storage. There is no
controller Docker-socket mount, automatic public certificate acquisition or
unapproved image builder.

## Native runtime contracts

The pinned integration baseline is OpenClaw `2026.10.5`, Crabbox `0.79.0` and
OpenBao `2.7.1`. Crabbox artifacts have release checksums; actual service images and
approved VM fingerprints belong in deployment qualification records.

Each gateway requires one explicit worker profile. Its pool wrapper selects a
Crabbox configuration and directly executes the pinned binary; it has no lease
state or scheduling policy. Incus classes are not used for placement. VM warm
images are disabled. Crabbox/OpenClaw own worker creation, execution and cleanup;
Ductor does not perform cross-host capacity scheduling.

The gateway stores its project-restricted Incus identity outside workers. The
worker project explicitly allows the low-level settings required by Crabbox's
`volatile.uuid` ownership mechanism; that identity is infrastructure authority.
The dedicated service-VM project remains separate and blocks those VM low-level
settings. No gateway identity is granted its own service-project administration.

OpenBao Agent owns AppRole login, renewal and reauthentication. OpenClaw receives
its scoped token sink and resolves provider values through the bundled
Vault-compatible integration. Bootstrap recovery material remains on the
controller. Native provider sign-in owns subscription/OAuth state.

Gateway deployment can stage without startup using `--stage-only`. Activation
checks the staged configuration, exact enrolled account policy, native model
readiness, company knowledge and startup health. Missing or unapproved credentials
must keep the gateway stopped. A dedicated service VM retains native token
authentication and manual browser-device approval behind external TLS/SSO.

## Image approval and live evidence

The service-VM OS image needs cloud-init and incus-agent. The worker image needs
the verified Node version; the generated worker setup probe checks the actual
runtime. The inspected opencode-platform Node 22 release is not sufficient.
Use its approved release pipeline with corrected version enforcement; no local
untracked override substitutes for that release input.

Source/schema tests and CI container checks do not prove routing, provider
account authorization, VM isolation, team ingress, controller-off continuity or
restore on the target environment. Record those separately using the
[production qualification runbook](production-qualification.md).
