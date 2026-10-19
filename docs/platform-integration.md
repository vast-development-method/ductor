# Reusing VDM OpenCode Platform

Ductor uses the Incus infrastructure, images, and security profiles maintained by
[opencode-platform](https://github.com/vast-development-method/opencode-platform).
It does not build a competing VM image system. The review below is against
commit `0f86093c8469422b502018e5e4193a840454b6f1`, platform `0.3.0-rc.3`.

Ductor installs the shared services and manages its own VM placement records.
The upstream platform remains responsible for host preparation, image composition,
image validation, managed bridges, and network policy. A working Incus VM is not
by itself a working Paperclip/Codex execution environment: the runtime, identity,
network, and lifecycle checks below are necessary.

## Profile composition

Upstream launches each VM with three ordered profiles:

1. `vdm-opencode-VARIANT`: image variant metadata and secure boot.
2. `vdm-size-SIZE`: CPU, memory, and root disk.
3. `vdm-policy-POLICY`: network device and ACL selection.

Ductor accepts that same ordered composition in the `PROFILE` argument to
`nodes add`, separated by commas. It resolves profiles using Incus semantics:
configuration keys are overlaid, while a later named device replaces the whole
earlier device. It validates the resulting root disk and ACL-bound managed NICs
before admitting a node. Each profile is passed separately to `incus init`.
The explicitly requested VM CPU, memory, and root disk limits override the size
profile, so admission and actual VM limits use the same values.

A single profile name remains supported. It must provide the complete effective
configuration itself. Passing only `vdm-opencode-python` is insufficient because
that profile deliberately contains no disk or network devices.

Ductor rejects platform policies whose `user.vdm.policy.status` is not `ready`.
It does not bypass the upstream gates on `brokered`, `restricted`, `release`,
or experimental `lab`. Keep the policy and image variant consistent. The initial
node inventory selects one profile composition per host; choosing a different
composition per task is not currently implemented. For mixed language projects
on one host, use the upstream `full` image and its matching profile, with enough
resources for that image. Do not register the same physical host repeatedly to
manufacture separate capacity pools.

## Prepare the existing platform

Run the upstream bootstrap from an operator-owned platform checkout after
reviewing its `.env`. These are the upstream commands; Ductor does not change
APT sources or replace the upstream bridge configuration:

```bash
./tests/validate-repository.sh
./scripts/bootstrap-host.sh
./scripts/apply-incus.sh
```

If bootstrap adds the operator to `incus-admin`, start a new login session before
continuing. Incus administration is a trusted, root-equivalent capability. A VM
must not inherit the controller's Incus client certificate or socket.

Build or import the required released image using the platform's existing
workflow. For example, from the same checkout:

```bash
export LOCAL_BUILD_VARIANTS=php
./scripts/local-image-release.sh
incus image list local: --project vdm-agents
```

An existing VM does not acquire newer software when an image is rebuilt. The
image alias in the example below is the reviewed AMD64 PHP release. An ARM64
host or another approved platform release requires its actual matching artifact.

## Keep runtime quotas separate from image building

The reviewed `vdm-agents` project is restricted and isolates profiles, but it
does **not** define finite CPU, memory, disk, or VM-count quotas. Ductor therefore
refuses to register it unchanged. The upstream image builder also uses that
project, so imposing workload-only quotas directly on it can block builds.

Use a dedicated `ductor` workload project on each worker and reuse the existing
host-managed bridges and ACLs. Copy the approved profiles and image into that
project. This also avoids an upstream `apply-incus.sh` run replacing Ductor's
quota settings: that script edits its selected project from the upstream YAML.
Keep its `INCUS_PROJECT` set to the platform/build project.

The following is a concrete **fresh-project example** for the default local
platform layout. It reserves 8 CPU threads, 16 GiB RAM, 256 GiB disk quota, and
one resident VM. These numbers are an operator allocation, not a hardware
recommendation. Confirm sufficient physical resources and leave capacity for the
host, QEMU overhead, shared services, and image builds. Ductor checks declared
limits against hardware, but cannot know how much capacity you have promised to
unrelated applications.

```bash
incus query local:/1.0/resources |
  jq '{cpu:.cpu.total,memory_gib:(.memory.total/1073741824|floor)}'
incus query local:/1.0/storage-pools/default/resources |
  jq '{total_gib:(.space.total/1073741824|floor),used_gib:(.space.used/1073741824|ceil)}'

# Intentionally fails if the project already exists; inspect it before changing it.
incus project create local:ductor \
  --config features.images=true \
  --config features.networks=false \
  --config features.profiles=true \
  --config features.storage.volumes=true

# Preserve the upstream restrictions while adding the runtime allocation.
incus query local:/1.0/projects/vdm-agents |
  jq '{description:"Ductor workloads using VDM platform",config:(.config + {
    "limits.cpu":"8",
    "limits.memory":"16GiB",
    "limits.disk":"256GiB",
    "limits.virtual-machines":"1",
    "limits.containers":"0",
    "user.ductor.platform":"vdm-opencode-platform"
  })}' |
  incus project edit local:ductor

for profile in vdm-opencode-php vdm-size-standard vdm-policy-connected; do
  incus profile create "local:$profile" --project ductor
  incus query "local:/1.0/profiles/$profile?project=vdm-agents" |
    jq '{description,config,devices}' |
    incus profile edit "local:$profile" --project ductor
done

incus image copy local:vdm-opencode-php/0.3.0-rc.3-amd64 local: \
  --vm --project vdm-agents --target-project ductor \
  --alias vdm-opencode-php/0.3.0-rc.3-amd64

sudo ductor nodes add worker-one local 8 16384 256 1 ductor \
  vdm-opencode-php,vdm-size-standard,vdm-policy-connected default worker
sudo ductor plan 8 16384 120
sudo ductor vm create project-php 8 16384 120 \
  local:vdm-opencode-php/0.3.0-rc.3-amd64
sudo ductor vm start project-php
```

Project disk quotas also account for images and other project storage, not only
VM root disks. Leave room for the copied image and operational headroom. The
Incus server remains the final quota enforcer if a storage operation would
exceed that quota. Never shrink a VM disk below the source image's requirements.

Run Ductor with the Unix identity holding its intended Incus client configuration.
The example uses the root-owned Ductor installation and the local Unix socket.
Remote worker aliases must be configured and trusted for that same identity;
an operator's private Incus client configuration is not automatically root's
configuration. When using another server, replace `local` with its already
configured Incus remote and provide an explicit image remote as well. Bare image
names use the Incus client's default image source, which might differ from the
selected execution host.

In [Docker controller mode](container.md), configure those remotes using the
container's Incus client. Its client configuration and certificates persist under
`/var/lib/ductor/incus`. The host's client configuration and local Incus socket are
not inherited automatically. Authenticated network remotes support both LAN and
external hosts; an explicit socket mount is needed for local Unix-socket access.

This preparation preserves existing instances and the original platform project.
Do not run `launch-vm.sh` separately for a VM already owned by Ductor: that
launcher has its own creation/cleanup lifecycle and does not create Ductor's
placement reservation. It remains useful for independent manual platform tests.

## Network alignment

The upstream `connected` policy rejects inbound connections and private/special
IPv4 destinations. It explicitly allows DNS and HTTPS to `10.248.18.1`, the
runtime bridge gateway, before rejecting the wider private ranges. Consequently:

- A second LAN server hosting ContextForge or OpenBao is not automatically
  reachable from the VM.
- Guest inbound connections remain blocked; the provider reaches guests through
  the authenticated Incus API.
- Ductor's default loopback-bound Compose ports are not guest or LAN addresses.

A deployment must supply an approved TLS gateway route, its trusted certificate,
and a narrowly scoped management path. The existing gateway exception can be
used by an actual HTTPS reverse proxy on the worker bridge address that forwards
the approved service routes to the control server. Alternatively, introduce a
reviewed platform network policy for the exact control addresses and ports.
Do not open an entire private subnet or weaken the common `connected` ACL merely
to make a test pass. No proxy listener is created just because the ACL mentions
port 443.

Verify Paperclip's authenticated SSH broker connection to the controller from
inside Paperclip's container. The native Ductor provider then uses Incus exec and
file transfer to reach the guest; it does not require inbound guest SSH. Verify
the gateway and credential endpoints from inside the actual VM. The network
rules and endpoint certificates must agree with the runtime binding. Incus native
API access manages VM lifecycle and execution; it does not make guest HTTPS
egress work automatically.

## Native Codex and persistent agent identity

The reviewed platform pins `opencode-ai@1.18.4`; its session entry point launches
OpenCode. It does not install and start a native Codex worker by selecting a
Paperclip model name. For the current ChatGPT subscription path, the worker needs
the approved native Codex CLI and the Ductor runtime binding. Keep the Ubuntu
image, language tools, workspace ownership, and platform hardening.

An approved agent profile can include `runtime.codexArtifact` to install the
native CLI automatically when its VM is prepared. It contains exactly `url`,
`sha256`, and `version`. The URL must identify the matching stable official
OpenAI GitHub release archive, for example:

```json
{
  "runtime": {
    "command": "/usr/local/bin/codex",
    "uid": 1000,
    "workspace": "/workspace",
    "codexArtifact": {
      "version": "0.163.0",
      "url": "https://github.com/openai/codex/releases/download/rust-v0.163.0/codex-x86_64-unknown-linux-musl.tar.gz",
      "sha256": "beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4"
    }
  }
}
```

This is an x86_64 example; an aarch64 guest needs that release's aarch64 archive
and its own approved checksum. Ductor verifies the guest architecture, the
archive checksum on every cache use, and the archive's single regular binary
member. It transfers the binary with Incus and installs it atomically at
`/usr/local/bin/codex`, then checks its version as the bound non-root guest
account. The cache contains public software only. A working installed CLI with
the approved version is reused. Omit `codexArtifact` only when the image already
provides a working native CLI at `runtime.command`; missing CLI blocks the run
with a setup error. Ductor does not select an unpinned latest release.

Ductor's broker installs its policy/runtime integration and guest execution
helper in the identified KVM guest. Codex availability alone does not establish
account authorization or service routing. Paperclip registration and a real
bounded task must verify those pieces before enabling unattended work.

Preserve Paperclip's native selected-account authentication and session handling.
Do not give a worker the OpenBao root token or export a shared account cache to
all VMs. OpenCode login in a temporary interactive session is a different runtime
path and must not be presented as the persistent Codex integration.

## Session expiry and ownership

Upstream `start-session.sh` starts an interactive `systemd-run --pty --wait` unit,
redirects OpenCode data to `/run/vdm-opencode-ID/data`, and accepts a TTL of
60 seconds through 24 hours, defaulting to two hours. Cleanup removes runtime
credentials and OpenCode auth files. The reaper stops running VMs carrying an
expired `user.vdm.session.expires_epoch` value.

That is appropriate for its bounded interactive sessions, but it is not the
headless Paperclip/Codex run lifecycle. Do not launch the persistent worker through
`start-session.sh`, and do not leave an old expiry label on a VM expected to run
Paperclip work. The `retained` workspace label preserves intent; it does not
implement an always-on session or disable the reaper. A separate `ductor` project
also keeps the default `vdm-agents` reaper away from Ductor-owned workers.

Ductor sets `boot.autostart=false` and keeps a persistent placement record before
creation. Stopping a VM preserves its disk and reserves its declared resources.
It does not automatically release capacity or delete an idle workspace. Each
native provider lease has a bounded expiry, enforced by a guest power-off timer
and controller reaper. Execution timeouts are limited to the remaining lease.
VM retirement remains an explicit, recoverable operation. A resident logical
agent can remain assigned to a project while its VM is stopped.

## Qualification before unattended use

Complete one real task through the intended route: create the VM from the
approved platform artifact, establish authenticated broker transport, verify the runtime
binding from the VM, authenticate the selected native Codex account, retrieve
scoped memory, run repository checks, obtain an independent review, and retain
the task/commit evidence. Then test a rejected tool request, an offline worker,
expired credentials, a failed run, and restart/resume behavior.

Source inspection and offline fixtures verify integration contracts. They do not
replace this acceptance run on your actual Incus, storage driver, network, and
Paperclip deployment.

## Reviewed upstream sources

- [Project restrictions](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/incus/projects/vdm-agents.yaml)
- [Incus application](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/scripts/apply-incus.sh)
- [VM launcher](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/scripts/launch-vm.sh)
- [Image/policy/size manifest](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/manifest/images.yaml)
- [Connected ACL](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/incus/acls/generated/connected.yaml)
- [Interactive session](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/scripts/start-session.sh)
- [Expiry reaper](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/scripts/reap-expired-vms.sh)
- [Credential design](https://github.com/vast-development-method/opencode-platform/blob/0f86093c8469422b502018e5e4193a840454b6f1/docs/credentials-and-brokers.md)
- [Native Codex archive contract](https://github.com/openai/codex/blob/rust-v0.163.0/README.md)
- [Pinned Codex release and checksums](https://github.com/openai/codex/releases/tag/rust-v0.163.0)
