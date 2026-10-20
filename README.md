# Ductor v2

Ductor installs and operates the infrastructure behind your agent team through
**Ansible over verified SSH**. It runs standalone or as an interactive container.
It does not become another runtime service that your agents depend on.

You can close Ductor while services continue running. When it returns, its menu
and status checks reconnect to live state; they do not redeploy or restart the
infrastructure. Changes require an explicit operation.

The v2 stack is **OpenClaw + Crabbox/Incus + OpenBao**. OpenClaw provides the
conversation and agent workspace; Crabbox manages isolated workers through Incus;
OpenBao and its native Agent deliver scoped credentials. Company instructions and
reviewed knowledge remain portable Markdown/Git sources, with native OpenClaw
memory and wiki integration.

The recommended deployment gives the main gateway its own Incus service VM,
separate from worker projects. The team reaches a fixed private gateway port
through the operator's domain/TLS proxy. Native token authentication and browser
device approval remain in place; external SSO can add a further admission layer.

**Version 2.0.0-rc.1 is a deployment candidate.** It replaces the original
Paperclip-centric prototype. Real servers, provider sign-ins, worker connectivity,
restore and team access must pass [production qualification](docs/production-qualification.md)
before a deployment is called production-ready.

## What Ductor owns

| Need | Implementation |
| --- | --- |
| Setup and saved configuration | Terminal workflow and validated JSON |
| Multiple LAN/external hosts | Verified SSH inventory; the same path for local and remote hosts |
| Service deployment and updates | Ansible, explicit image versions and host bind mounts |
| Worker placement | Explicit Incus pools, approved images, profiles and project quotas |
| Main gateway isolation | Dedicated Incus service VM, separate project and explicit network paths |
| Credentials | Native OpenBao initialization/provisioning and OpenBao Agent renewal |
| Operations | Preflight, status, restart, backup and explicit updates |
| Runtime work | Owned by OpenClaw, Crabbox and Incus; continues with Ductor stopped |

The default stack does not require Paperclip, MemPalace, ContextForge, n8n or
Memcached. Add another service only to close an identified gap. Ductor is not an
agent scheduler, lease broker, reaper or model proxy.

## Start from a checkout

Read the configuration and deployment changes before applying them. The Bash
entry point launches the Python controller; Ansible performs host changes.
The Linux controller needs Python 3.12–3.14, its `venv` package and an OpenSSH
client. Install the pinned deployment dependency in a local virtual environment:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install ansible-core==2.20.10
export PATH="$PWD/.venv/bin:$PATH"
./src/ductor --help
./src/ductor setup
./src/ductor validate
./src/ductor render
./src/ductor plan
./src/ductor preflight
```

Use `--config /absolute/config.json` and `--state-dir /absolute/state` to choose
operator paths explicitly. `setup` saves configuration; it does not authenticate
provider accounts or prove a worker image is compatible. See the CLI help for the
installed prerequisites and commands. `plan` renders and summarizes the desired
deployment locally without SSH or host changes. `preflight` inspects the selected
hosts through SSH; it does not install missing services.

[The example configuration](examples/config.example.json) shows the complete
shape. Its domains, paths, fingerprints and other deployment inputs must be
replaced with approved values for the actual infrastructure.
Use [the service-VM example](examples/service-vm.example.json) for the recommended
dedicated main-gateway topology.

Before deployment, supply verified SSH host keys, the operator's TLS reverse
proxy, approved Incus worker prerequisites, protected credential references and a
company knowledge directory. A missing selected account or pool is a blocked
prerequisite, not permission to silently substitute another one.

For a fresh worker host, configure the explicit bootstrap inputs, generate its
pool identity with `credentials incus --pool workers`, then run
`bootstrap-workers --host worker-host`. See [worker setup](docs/platform-integration.md)
for package, network, storage and approved-image requirements.

To provision the main gateway VM, configure its approved service-VM inputs, run
`bootstrap-services --host hypervisor`, and enroll the reported guest SSH
fingerprint before ordinary deployment. Follow the [service-VM runbook](docs/service-vm.md)
for the project, ingress, worker and OpenBao boundaries.

Deploy OpenBao first if gateways need it, initialize/unseal it, provision the
scoped credentials, then deploy and activate the selected gateway:

```bash
./src/ductor deploy --service bao
./src/ductor credentials bootstrap --service bao
./src/ductor credentials unseal --service bao
./src/ductor credentials provision --service bao
./src/ductor deploy --stage-only
./src/ductor login --service team --agent coordinator --provider openai --profile openai:work
./src/ductor activate --service team
```

`bao`, `team` and `coordinator` are example configuration IDs. Credential actions
require the private file references described in [service operations](docs/services.md).
The full `deploy` reconciles the worker projects and profiles as well as services;
selecting a service alone does not initialize all worker pools.
`--stage-only` builds and validates the gateway without starting it. Complete the
declared login commands, then run `activate` for credential, knowledge and startup
checks. For OpenBao API keys, import the value first and use plain `deploy`, which
also attempts activation. Missing credentials always leave the gateway stopped.
Provider sign-in uses the native supported flow. Configuration declarations do
not create authenticated subscriptions or API keys. Complete every enrollment
listed in the rendered gateway's `activation.json` before activation.

For an API-key gateway, import the declared credential from a protected text file:

```bash
./src/ductor credentials put --service team --provider openai --input-file /absolute/private/openai-key
```

The file contains only the key. Ductor uses the gateway's configured provider
reference and preserves other fields in that secret. Never put the value in
command arguments or desired configuration. Such a gateway uses OpenBao instead
of the native profile-login step above.

For a published v2 release, the reviewed `install.sh` accepts an explicit version
and optional independently obtained SHA-256 checksum:

```bash
./install.sh --version 2.0.0-rc.1 --sha256 RELEASE_ARCHIVE_SHA256
```

Replace the checksum placeholder with the release archive's actual 64-digit
digest. Installation verifies the archive, prepares an isolated Ansible
environment and switches the active release only after checks pass. Its defaults
are `~/.local/share/ductor` and `~/.local/bin`; add the latter to `PATH` if needed.
The command requires that the selected release assets have been published.

For a container controller, follow [container installation](docs/container.md).
No Docker socket is mounted into Ductor. Every service host is administered over
SSH, including the server that happens to run the controller.

## Daily use

Open the configured OpenClaw URL and work through the orchestrator. It can delegate
to explicitly allowed workers and a reviewer. The native applications retain
sessions, memory and worker lifecycle independently of Ductor.

Run Ductor again when operating the infrastructure:

```bash
./src/ductor status
./src/ductor monitor --interval 30
./src/ductor backup --service team
./src/ductor config edit
./src/ductor update --service team
```

Image changes are explicit. Backups and a tested service-compatible restore plan
are required before a production upgrade. Resource budgets include OS headroom;
Incus project quotas enforce worker limits. Ductor does not automatically balance
work across unrelated hosts.

`monitor` polls live infrastructure state without changing it. Ctrl-C stops the
monitor only. The optional [container monitoring mode](docs/container.md#persistent-monitoring)
resumes polling after the controller restarts, without redeploying services.

## Read before activation

- [Architecture and trust boundaries](docs/architecture.md)
- [Dedicated gateway service VM](docs/service-vm.md)
- [Multiple controllers and portable ZIP setup](docs/controller-portability.md)
- [Deployment ownership and acceptance](docs/deployment-contract.md)
- [Conversation, accounts and shared knowledge](docs/conversations.md)
- [Portable company knowledge protocol](docs/knowledge-protocol.md)
- [Credentials and service operations](docs/services.md)
- [Incus and approved-image integration](docs/platform-integration.md)
- [Production qualification and remaining boundaries](docs/production-qualification.md)

The initial acceptance scope is functional: build the intended system and verify
that its boundaries and recovery work. Cost and productivity benchmarking are a
later activity, not a prerequisite for installation.

Apache-2.0; see [LICENSE](LICENSE).
