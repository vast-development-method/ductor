# Ductor

An agent conductor for your own infrastructure.

Ductor is a **single Bash executable** that installs and configures the services
behind an agent team: Paperclip, MemPalace, ContextForge, OpenBao, and isolated
Incus execution environments. It keeps installation, inventory, and integration
configuration together while reusing the upstream applications. The script also
contains the small JavaScript adapter it generates for Paperclip's native sandbox
provider interface; there is no separate Ductor runtime package to fetch.

The initial release provides deployment and integration commands. It is a pilot
foundation: the complete service-to-VM execution path still requires testing on
real infrastructure before entrusting it with unattended production work.

## Install and start setup

On a Linux server with `curl`, `sudo`, and Bash installed:

```bash
curl -fsSL https://raw.githubusercontent.com/vast-development-method/ductor/main/src/ductor | sudo bash -s -- install
```

The downloaded script installs itself as `/usr/local/bin/ductor`, then immediately
starts the first-run setup. A piped invocation downloads a complete copy over
HTTPS to persist the executable; this is one installation command, not a promise
of one HTTP request. This executes the repository's current `main` version
with administrator privileges. Read [the complete executable](src/ductor) before
running it if you need to review what will change.

The setup offers three roles:

| Role | What runs on this server |
| --- | --- |
| Control | Paperclip, MemPalace, ContextForge, OpenBao, and their databases |
| Worker | Existing Incus host; no shared service stack |
| Combined | Services and an existing Incus host |

Run `sudo ductor` to open the terminal management console again. Run
`sudo ductor setup` to resume its guided configuration. On supported Debian/Ubuntu
hosts, setup offers installation of missing utilities and Docker/Compose for a
service role. The console covers server budgets, agent types, connections,
readiness, and reviewed upgrades. Its **Connections** menu initializes and
unseals OpenBao, stores an existing administration token privately, and imports
or versions service credentials from private JSON files. Desired
configuration is saved in `/var/lib/ductor/config.json`; `sudo ductor apply`
reconciles it and records completed phases and missing prerequisites. Repeated
setup reuses existing credentials. Secret values stay outside that configuration
file. Incus installation, platform image preparation, network policy, and external
account sign-in remain explicit operator steps.

For installation without the interactive setup, use:

```bash
curl -fsSL https://raw.githubusercontent.com/vast-development-method/ductor/main/src/ductor | sudo bash -s -- install --no-setup
```

## Day to day: talk to your team

Use Paperclip's native **Agent Chat** as your ongoing conversation with the
configured secretary or coordinator:

```bash
sudo ductor paperclip conversation enable
sudo ductor paperclip conversation open
```

The first command enables Paperclip's experimental Agent Chat feature with your
instance-admin authority. The second prints the correct company Chat URL. In the
dashboard, choose the secretary/coordinator agent and describe the outcome you
want. Its existing profile supplies its model, account, tools, and execution
environment. Ask it to plan, create assigned project tasks, arrange review, and
return task links and results to the conversation. Task cards expose the work
behind the discussion; approvals and resource limits still apply.

Invite colleagues through **Settings → Members → Invites** after claiming the
instance and enabling team HTTPS. Each person uses their own Paperclip account
and company role. To work from an outside assistant, Paperclip separately offers
**Connectors → Assistant Connection (MCP)** with explicit human sign-in and consent.
That connection does not supply the worker agents' model credentials.

See [conversation, delegation, and team onboarding](docs/conversations.md) and
[service access, credentials, and upgrades](docs/services.md) for the complete
setup and its current limits.

## Each component owns one responsibility

| Component | Responsibility |
| --- | --- |
| **Ductor** | Installation, inventory, resource admission, bindings, and integration checks |
| [**Paperclip**](https://github.com/paperclipai/paperclip) | Projects, tasks, assignments, approvals, run/session state, and work dashboard |
| [**MemPalace**](https://github.com/MemPalace/mempalace) | Shared knowledge and durable recall within explicitly separated scopes |
| [**ContextForge**](https://github.com/IBM/mcp-context-forge) | Approved MCP tool access and gateway authorization |
| [**OpenBao**](https://github.com/openbao/openbao) | External service credentials and policies used by trusted integrations |
| [**Incus / opencode-platform**](https://github.com/vast-development-method/opencode-platform) | VM isolation, platform images, project restrictions, and resource limits |
| **Git** | Code, reviewed configuration, and versioned project instructions |

Paperclip retains its native task and session database. OpenAI subscription
sign-in uses Paperclip's supported Codex connection flow. These native sessions
are separate from the external tool credentials managed through OpenBao.
Bootstrap database passwords and application encryption keys also remain private
service configuration; they are needed before OpenBao can be initialized.

Ductor's manual agent registration requires a verified binding for memory,
gateway, credentials, and Incus isolation. Native provider registration stores
the approved agent type first; acquisition must provision and verify those
bindings inside its VM before Paperclip receives a usable lease. Missing services
block execution; no alternate memory store or unrestricted tool access is selected. See
[the architecture and enforcement boundaries](docs/architecture.md).

## Shared services

The service stack uses pinned upstream images, named persistent volumes, and
loopback-only published ports. Defaults are:

| Service | Local endpoint |
| --- | --- |
| Paperclip | `http://127.0.0.1:3100` |
| MemPalace MCP | `http://127.0.0.1:8765/mcp` |
| ContextForge | `http://127.0.0.1:4444/admin` |
| OpenBao | `http://127.0.0.1:8200` |

```bash
sudo ductor services prepare
sudo ductor services up
sudo ductor services status
sudo ductor services urls
sudo ductor doctor
```

`prepare` writes configuration without starting containers. `up` validates the
Compose configuration and waits for health checks. `status` also reports whether
OpenBao is initialized and sealed. A healthy OpenBao process can still be sealed;
sealed means it cannot supply credentials.

Access services on another machine through SSH forwarding or an authenticated
TLS reverse proxy. Loopback URLs are not automatically reachable from a worker
VM or from another server. Ductor does not change your firewall or publish the
stack on all interfaces by default. The optional managed HTTPS command configures
Caddy for three distinct DNS names after Paperclip has been claimed and OpenBao
initialized:

```bash
sudo ductor services access --paperclip-host office.example.com --gateway-host tools.example.com --bao-host secrets.example.com --email admin@example.com
```

This opens ports 80/443 for certificate issuance and HTTPS. The names must resolve
to the control server, with the required network reachability. An existing
authenticated TLS proxy is also supported; worker bindings need the HTTPS origins
that the VMs can actually reach.

Initialize OpenBao once, saving its recovery response to a new protected file:

```bash
sudo ductor services bao-init /root/ductor-openbao-recovery.json
sudo ductor services bao-unseal
```

Run `bao-unseal` for three distinct shares from the initialization response. Keep
the recovery material offline and distribute shares according to your operating
policy. Ductor never prints the root token or unseal shares to task logs.

Create a separate palace for a project or agent trust boundary:

```bash
sudo ductor services memory-scope project-one
```

Each such scope has its own server process, volume, and backend token on the
private service network. A MemPalace wing or agent name is a retrieval label, not
an authorization boundary. Register private palaces through the trusted gateway;
do not hand their backend tokens to arbitrary agents.

## One server or many

One control bundle can manage any number of **standalone Incus remotes**. A
combined installation can run everything on one host. Add separate execution
hosts without changing that layout into a fixed two-server design.

Register existing Incus remotes with an explicit budget. Ductor verifies each
host's physical identity, selected project quotas, and profile before admission:

```bash
sudo ductor nodes probe local
sudo ductor nodes help
sudo ductor vm help
```

For example, after preparing an Incus project and profile both named `ductor`, a
node with an allocated budget of 8 CPUs, 16 GiB RAM, 80 GiB disk, and four VMs can
be registered and inspected with:

```bash
sudo ductor nodes add worker-one local 8 16384 80 4 ductor ductor default
sudo ductor plan 2 4096 10
sudo ductor nodes list
sudo ductor vm list
```

The selected project must be restricted, have isolated profiles, disallow
containers, and have finite CPU, memory, disk, and VM quotas within the declared
budget. Ductor refuses the default project and unknown or unbounded resource
configurations. It does not modify an existing project's policies to make a
request fit.

VM creation uses an image already prepared for your platform. Manual `vm create`
leaves a new VM stopped; native Paperclip acquisition creates and starts it.
Failed creation preserves its placement reservation so
that retrying the same request cannot allocate another VM on a different server.
Stopped VMs retain their reservations. This is conservative capacity admission,
not automatic elastic scaling or automatic VM deletion.

Use `nodes drain` to stop new work being admitted to a host. Existing VMs remain
unchanged. Incus clustering, live migration, and distributed Ductor controllers
are not implemented by this release.

## Native automatic deployment

Use the terminal console to save your control/worker roles, server budgets,
service origins, broker host keys, and approved agent types. Each type specifies
its repository, role, exact model ID, subscription connection and grant, existing
Incus image, nonroot runtime account, resource limits, memory scope, tool IDs, and
child-agent limits. You can also import its complete JSON schema:

```bash
sudo ductor profiles example > agent-type.json
# Edit the example with your real image, model and account identifiers.
sudo ductor profiles import agent-type.json
sudo ductor profiles list
```

Profiles use immutable versioned names. To change a policy, import a new name and
migrate agents explicitly. A private controller registry pins agent ownership,
profile, parent, environment, project and account choices; editable Paperclip
metadata is checked against that registry, not accepted as permission to change
it. The console saves approved profiles in desired configuration; direct CLI
imports register the profile independently.

The selected image must already provide its nonroot account, Incus guest agent,
Linux/systemd, Node.js, Bash and the runtime utilities. It can include Codex, or the
profile can add `runtime.codexArtifact` with these exact fields:

| Field | Required value |
| --- | --- |
| `version` | Approved stable Codex version, such as `MAJOR.MINOR.PATCH` |
| `url` | Its official `openai/codex` GitHub release archive for Linux `x86_64` or `aarch64` musl |
| `sha256` | Independently verified 64-character SHA-256 digest of that archive |

Automatic artifact installation targets `/usr/local/bin/codex`, verifies its hash
and archive member, installs it inside the owned VM, and checks its version as the
agent user. Without this optional policy, a working Codex installation is required
in the image. Neither option embeds a ChatGPT login in an image or cache. See
[platform integration](docs/platform-integration.md) for image and network details.

After completing native account sign-in, OpenBao initialization/unsealing, and
the verified controller SSH identity, `sudo ductor apply` provisions the transport
credential through OpenBao Agent, installs the forced-command broker, generates
and registers the native Paperclip provider, and registers desired agents. It
reports missing prerequisites instead of claiming readiness. Use
`sudo ductor apply --check` for configuration validation without deploying.

For explicit agent registration:

```bash
sudo ductor agents create --profile repository-engineer --name "Project engineer"
```

Registration creates a logical agent and its native environment. When Paperclip
starts a run, the provider asks the trusted Ductor broker to reserve capacity,
create or reuse that agent's Incus VM, start it, enforce a lease deadline, provision
its memory/tools/credential binding, install the runtime, and test access from the
actual guest user. Only then does it return the lease. The native Paperclip
sandbox transport carries commands and file synchronization into that VM.

An approved manager can request a child through an entire Paperclip issue comment
of this form, using a profile permitted by its policy:

```text
/ductor spawn {"profile":"repository-reviewer","name":"Review worker"}
```

The plugin verifies the persisted comment's agent identity; the trusted broker
checks the parent, project, allowed type and limits. Normal unrestricted native
agent creation remains disabled. `maxTotal` counts nonterminated direct children;
`maxConcurrent` bounds their active VM leases; every ancestor's `maxDepth` limits
its descendant distance. Spawn events currently depend on Paperclip's in-process
event delivery, so inspect the source issue and agent list after interruption;
this is not a durable external queue.

Creation requests are recorded privately on the controller. If a create request
has an unknown outcome, reconcile its preserved intent before retrying. Matching
Paperclip names or metadata do not prove ownership and cannot authorize adoption.
A retried spawn can continue only when its original intent already records the
returned agent ID and that agent still matches the approved request.

Release and cancellation force-stop the owned VM and confirm it stopped. Files
and placement reservations are retained, including when native destruction is
requested. Stopping a VM therefore does not reclaim its allocation. Guest timers
and the controller reaper enforce bounded lease lifetimes; partial provisioning
failures attempt a stop while retaining the same allocation for recovery.

## Connect Paperclip

Use Paperclip's dashboard to create your company, sign in to the permitted
ChatGPT subscription accounts through Codex AI Connections, and configure the
appropriate human responsibility and account grants. Ductor does not request
ChatGPT passwords or reuse browser cookies. Each approved profile selects an
explicit connection, grant, and model ID. Ductor verifies that selection again
for the particular agent before execution; it does not pool account quotas or
automatically switch accounts or models when a grant becomes unavailable.

```bash
sudo ductor paperclip help
sudo ductor paperclip connections
sudo ductor paperclip environments
sudo ductor paperclip agents
sudo ductor paperclip projects
```

The help command documents login, verified SSH environments, manual project/agent
registration, and task submission. `paperclip task` supports native provider
agents before their first VM exists: submission validates approved policy and
grants, then native acquisition prepares the VM before execution. The manual SSH
path verifies its already deployed binding and transport separately. Registration uses explicit environment,
model, connection, grant, and service-binding identifiers. It reuses matching
managed records and rejects conflicting configuration.

SSH environment registration does not provision a VM. The environment must point
to the prepared repository workspace inside the selected Incus VM, and the
Paperclip service must have working SSH transport authentication. Access from
the administrator's shell alone does not establish access from Paperclip.

Task submission can immediately wake the assigned agent. After a network failure
on submission, inspect the task list before retrying: a lost response does not
prove that task creation failed. Agent heartbeat automation is initially disabled
so operators can qualify a bounded task and review cycle first.

## Bind memory, tools, and credentials

```bash
sudo ductor bindings help
```

The provisioning request explicitly identifies the project, agent, memory trust
scope, ContextForge service identity, gateway and OpenBao origins reachable from
the VM, the Incus node/VM, and the guest's UID and machine identity. It also names
the exact Paperclip environment and Codex executable. The help output gives the
complete required schema; credentials are supplied through private files rather
than embedded in that request.

`bindings provision` creates a dedicated palace, a non-administrator gateway
identity, and a private virtual server containing the selected memory tools and
any explicitly approved extra tool IDs. It stores that server's scoped gateway
grant in OpenBao and issues an AppRole restricted to reading that one grant.
`bindings check` checks the credential flow, exact MCP catalog, and a recall call.

`bindings deploy NAME` transfers the same complete executable and private bundle
into the owned VM, installs root-owned Codex policy, and verifies access as its
nonroot user. Native acquisition invokes this automatically. For an explicit
manual transfer, `bindings render` creates the bundle and `bindings install-runtime`
installs it inside the guest as root. `/usr/local/bin/ductor-runtime` is a symlink
to the same executable, invoked by Paperclip as the bound nonroot user.

Before invoking Codex, the wrapper obtains its current scoped grant from OpenBao,
checks the approved tools, and retrieves bounded initial memory. It configures
the mandatory ContextForge endpoint and disables Codex's separate memory feature.
For native profile agents it also rejects conflicting model/provider CLI overrides
and injects the approved model while preserving Paperclip's authentication home.
Missing required services stop that run. A permitted MCP endpoint does not by
itself prevent arbitrary network access through shell commands: the VM's network
and privilege policies remain essential enforcement boundaries.

Gateway grants and AppRole SecretIDs expire after 30 days. This release does not
automatically rotate them: use the upstream administrative procedures and deploy
the replacement guest identity before expiry. Expired credentials block new
runs. Removing a credential from OpenBao does not revoke an already issued
credential at its upstream service; revocation must be applied there too.

Use `services secret-import` to place a private JSON credential in OpenBao.
Import alone does not grant an agent access or configure an email/Git service:
the trusted integration still needs the corresponding scoped policy and tool.
Human Paperclip accounts, controller administrative tokens, and worker AppRoles
remain separate identities; see [the credential setup](docs/services.md).

## Operations and recovery

```bash
sudo ductor update
sudo ductor services down
sudo ductor uninstall
```

`update` checks shell syntax and the Ductor marker before atomically replacing the
executable, retaining `ductor.previous`. It does not upgrade running services.
`services upgrade plan` displays current and proposed pinned images. After taking
and checking full application/database/volume backups,
`services upgrade apply --backup-confirmed` pulls the pins and reconciles the stack.
A private configuration snapshot is retained; it cannot roll back database
migrations.
`services down` stops containers and retains data volumes. `uninstall` removes
the executable after confirmation and retains services, state, and VMs.

Back up `/var/lib/ductor` together with consistent database and named-volume
backups. Keep OpenBao recovery material separately. Restoring a service volume
without its original passwords or encryption keys can make it inaccessible;
Ductor refuses to regenerate a missing service secret file for an initialized
installation.

The default state directory is private to its operator. Use one controller for
an inventory: mutation commands use a local kernel `flock`, not a distributed
lock. `DUCTOR_STATE_DIR` and `DUCTOR_INSTALL_DIR` support explicit alternative
absolute paths for testing or operator-managed installations.

## Validation and remaining integration work

The repository includes offline regression fixtures for installation and
update recovery, inventory admission, runtime bindings, approved profile policies,
native provider transport, and broker lifecycle contracts. They make
no production API calls and do not install host services:

```bash
bash tests/run.sh
```

These checks are not evidence that a live Docker/Incus deployment has passed.
Qualify startup, authorization denial, credential renewal/revocation, VM
execution, context retrieval, review handoff, and restart recovery on your target
hosts before unattended use.

Live qualification of native VM acquisition remains required. Automatic allocation
reclamation, event bridges for GitHub/Gitea/email, Telegram decision round-trips,
durable spawn-event reconciliation, and unattended review loops remain further
integration work. Paperclip is the web work dashboard; Ductor supplies the terminal
management console and service-health overview. It does not provide another web
fleet dashboard or claim that an autonomous team has passed production testing.

## Requirements and license

Linux and Bash 4.4 or newer are required. Dependency installation supports
Debian/Ubuntu APT repositories. The service host requires Docker Engine and
Compose v2. The controller needs an Incus client with configured remotes for VM
management. Existing Docker packages and Incus installations are retained.

Ductor is licensed under [Apache-2.0](LICENSE). It installs upstream services;
those projects retain their own licenses. The executable is original integration
code and does not include copied Octojoom installer code.

