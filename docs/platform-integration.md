# Incus and opencode-platform integration

Ductor uses Crabbox's native Incus provider. The approved worker image comes from
the operator's existing [opencode-platform](https://github.com/vast-development-method/opencode-platform)
workflow. Ductor does not replace that image supply chain or reuse its execution
reaper as a new runtime.

## Dedicated projects

Create a dedicated Incus project for each configured isolation boundary. Do not
silently modify an existing `vdm-agents` project. Configure a profile with the
approved network, storage and per-instance CPU, memory and disk limits. Apply
project aggregate quotas and separate instance-count limits.

Normal deployment consumes an initialized Incus host with KVM, an HTTPS listener,
managed network, approved ACL, storage pool and approved source VM image. It
creates/reconciles the dedicated project, profile, immutable image alias and
restricted client trust. Fresh hosts have a separate explicit bootstrap path;
neither path replaces opencode-platform's image build process.

The gateway holds the Incus client certificate and key. They are infrastructure
credentials and must remain outside worker guests. Pin and verify the Incus server
certificate; disabling TLS verification is not an enrollment method.

## Fresh host setup

Configure `incus.bootstrap.<host-id>` with `enabled: true`, an approved native
`package_version`, `listen_address`, `storage_driver: "dir"`, `storage_pool`,
`network`, `ipv4_address`, `ipv4_nat`, `network_acl` and explicit native ACL
`ingress`/`egress` allow rules. Supported fresh bootstrap hosts are Ubuntu 24.04
and Debian 13. The selected package must provide the required Incus APIs.

Generate the pool's private client identity, then bootstrap the chosen host:

```bash
ductor credentials incus --pool workers
ductor bootstrap-workers --host worker-host
```

The certificate command writes to the pool's configured file references. Bootstrap
installs the explicitly pinned Incus package from existing host repositories,
prepares directory storage, a bridge and the HTTPS listener, applies the approved
ACL and records ownership. It fetches the daemon certificate over the verified
SSH connection; an existing mismatched pin is not overwritten.

Bootstrap rejects an existing differently versioned Incus package, initialized
storage or managed networks without Ductor's ownership marker. It does not reset
an existing installation, format block devices or invent a package source. Later
changes to storage/network bootstrap inputs require a separately reviewed
migration. Normal `deploy` never silently initializes a fresh worker host.

An optional pool `image_import` specifies `metadata_url`, `metadata_sha256`,
`disk_url` and `disk_sha256` for an approved split Incus VM export. Deployment
verifies both downloads, imports the image into `image_source_project` and checks
the expected immutable fingerprint and Node-version attestation. This does not
make an incompatible image compatible.

## Pinned compatibility constraints

The integration targets Crabbox **0.79.0** and OpenClaw **2026.10.5**. It uses a
pool-specific executable that selects `CRABBOX_CONFIG` before executing the pinned
Crabbox binary. The wrapper has no runtime state or scheduling policy.

- Crabbox's Incus provider does not map OpenClaw `class` to host or machine shape.
  Placement and shape come from the selected pool and Incus profile.
- OpenClaw's required worker profile is configured per gateway. A failed required
  pool must not send work to the gateway host or a different pool.
- Incus native warm checkpoints are not supported for this VM path; VM profiles
  disable warm-image behavior.
- Gateway-to-guest SSH must be directly reachable for VMs. Do not assume an Incus
  API connection alone provides guest execution connectivity.
- Crabbox 0.79.0 sets `volatile.uuid` when creating an instance. Current Incus
  restrictions reject this under `restricted.virtual-machines.lowlevel=block`.
  Any required low-level permission must be an explicit, reviewed pool choice.
  It increases the authority of the gateway's Incus identity.

## Image and network preparation

The inspected opencode-platform manifest uses Node 22. The selected OpenClaw
worker requires Node **24.16+ or 26.1+**. An unchanged Node 22 image is therefore
not a qualified OpenClaw worker. Rebuild and approve a compatible image, or use an
explicit reviewed bootstrap supported by the deployment. Record its immutable
fingerprint and test worker enrollment before activation.

Set the source image's `user.ductor.openclaw.node_version` property to the
approved `worker_node_version` and configure its full `image_fingerprint` and
`image_source_project`. The metadata is an operator build attestation; it does
not replace executing the actual worker runtime check. The generated Crabbox
setup probe reads `process.versions.node` inside the acquired worker and rejects
an incompatible runtime before the turn proceeds.

The platform's default connected ACL blocks private destinations and inbound
traffic. That policy cannot be reused unchanged when a private gateway must reach
the guest or the guest must reach a private gateway. Add only the necessary
gateway/guest paths to a dedicated policy; do not disable the policy globally.

The inspected platform release publishes amd64 worker images. An arm64 controller
does not imply a qualified arm64 worker image. Confirm image architecture on each
pool's host.

The platform reaper recognizes its own `user.vdm.session.expires_epoch` metadata.
Keep Crabbox workers in their dedicated project and do not add that metadata to
them. Crabbox owns their lifecycle.

## Qualification on a real worker server

Verify image fingerprint and architecture, guest Node version, mTLS access,
gateway-to-guest SSH, guest-to-gateway connectivity, profile sizing and project
quotas. Exercise create, reuse, failed bootstrap, interrupted execution, cleanup,
capacity exhaustion and host loss. Repeat with Ductor stopped. A renderer test
cannot establish these runtime properties.
