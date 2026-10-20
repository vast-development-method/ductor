# V2 development contract

This file coordinates the v2 implementation. Desired configuration is JSON and
contains references, never credential values. Ductor is a Python CLI with a Bash
entry point; Ansible performs every service-host mutation over verified SSH.

## Configuration shape

```
{
  "schema_version": 2,
  "name": "company",
  "hosts": {
    "control": {
      "address": "server.example.org", "port": 22, "user": "deploy",
      "identity_file": "/absolute/operator/key", "known_hosts_file": "/absolute/known_hosts",
      "become": true, "data_root": "/srv/ductor",
      "resources": {"cpus": 8, "memory_mib": 16384, "disk_gib": 100,
                    "reserve_cpus": 1, "reserve_memory_mib": 2048, "reserve_disk_gib": 10},
      "roles": ["services", "incus"]
    }
  },
  "services": {
    "openbao": {"kind":"openbao", "host":"control", "enabled":true,
      "image":"openbao/openbao:VERSION", "bind_address":"127.0.0.1", "port":8200,
      "url":"https://secrets.example.org", "cpus":1, "memory_mib":512, "disk_gib":10},
    "openclaw": {"kind":"openclaw", "host":"control", "enabled":true,
      "image":"ghcr.io/openclaw/openclaw:VERSION", "bind_address":"127.0.0.1", "port":18789,
      "url":"https://agents.example.org", "cpus":2, "memory_mib":2048, "disk_gib":20,
      "trusted_proxies":[], "allowed_origins":["https://agents.example.org"]}
  },
  "incus": {"pools": {
    "workers": {"host":"control", "address":"https://server.example.org:8443",
      "project":"ductor-agents", "image":"existing-approved-image", "profile":"ductor-worker",
      "instance_type":"virtual-machine", "cpus":4, "memory_mib":8192, "disk_gib":60,
      "instance_cpus":2, "instance_memory_mib":2048, "instance_disk_gib":15,
      "max_instances":4, "network":"incusbr0", "storage_pool":"default"}
  }},
  "agents": [],
  "knowledge": {"source_dir":"/absolute/company-knowledge"},
  "credentials": {"openbao_token_file":"/absolute/private/token"}
}
```

Root owns CLI, schema, rendering inventory, distribution, main tests, docs.
Agent tasks will own specific Ansible roles/templates and integration modules.
All values must be validated before rendering. Unknown or unsupported config must
fail visibly rather than silently selecting another service/account/worker.

## Paths produced by render

`STATE/rendered/inventory.json`: Ansible inventory group `ductor_hosts`, forced ssh.
Each host gets `ansible_host`, `ansible_port`, `ansible_user`, private_key_file,
become, and StrictHostKeyChecking=yes with the absolute known_hosts file.
Host var `ductor_host` is its config with host id, and `ductor_services` is the list
of enabled services assigned to it (each including id). `ductor_pools` lists Incus
pools assigned to this host (with id). `ductor_config` is the non-secret full config.
`ductor_bundle_root`: checkout/bundle path on the controller.
`ductor_render_root`: absolute render directory.
`ductor_action`: selected action, default deploy.

Use `ansible.builtin` only initially to avoid unpinned collection downloads. Compose
operations run the remote docker compose CLI with argument arrays. Config staging
and secrets tasks use no_log/diff:false where necessary. No controller Docker socket.
Bind mounts only, explicit permissions, no implicit public TLS management. Never
run native application commands from agents with host infrastructure authority.

## Crabbox and Incus implementation contract

`ductor_core.crabbox.validate_pools(config)` returns validation errors;
`render_crabbox(config, output_dir)` writes `incus/<pool-id>/project.json`,
`profile.json`, `crabbox.yaml`, `incus-config.yml`, and executable `wrapper`.
JSON is also valid YAML for the two upstream config readers. No credential
contents are read by the renderer. `artifact(architecture)` returns the pinned
Crabbox 0.79.0 URL and release SHA256.

Each pool additionally requires `image_fingerprint` (full 64 hex),
`image_source_project`, `network_acl`, `worker_node_version`,
`allow_vm_lowlevel: true`, `client_certificate_file`, `client_key_file`, and
`server_certificate_file` (absolute operator file references). `image` is not
used as a mutable upstream selector: the role imports the fingerprint under
`ductor-<fingerprint>` and rejects an alias that has been retargeted. Pool
projects must be unique per host and cannot be `default` or `vdm-agents`.

The Incus role uses existing initialized Incus, KVM, managed network, ACL,
storage pool, HTTPS listener, and approved source image. It does not initialize
storage, change package repositories, or upgrade opencode-platform. The source
VM image must carry `user.ductor.openclaw.node_version` matching the approved
`worker_node_version`; this is an operator build attestation, checked again by
the actual OpenClaw worker setup. Existing platform Node 22 images must be
rebuilt for Node 24.16+ or 26.1+. A metadata label alone is not a runtime test.

The project allows VM lowlevel because Crabbox 0.79.0 sets `volatile.uuid` for
durable fixed-ID ownership and Incus 7.1 otherwise rejects it. This also allows
other lowlevel VM settings: the project-restricted certificate is infrastructure
authority, stays only on the Gateway, and is never forwarded into workers.
There is no claim that a project-restricted certificate is harmless to its host.
Default platform connected ACL is unsuitable unchanged: workers need outbound
Gateway enrollment and the Gateway needs inbound guest SSH. The selected ACL
must permit those specific management routes and required artifact/repository
destinations, with all other ingress/egress rejected. VM proxy devices are not
supported by this Crabbox provider; routed guest reachability is required.

Runtime mount contract: `/usr/local/lib/ductor/crabbox-<pool-id>` is the
wrapper; `/etc/ductor/crabbox/<pool-id>.yaml` is the Crabbox configuration;
`/etc/ductor/incus/<pool-id>/config.yml` is the Incus config, with `client.crt`,
`client.key` (0600), and `servercerts/<pool-id>.crt`. All are read-only in the
Gateway. `/home/node/.local/state/crabbox` must be durable and private. The
wrapper sets XDG_STATE_HOME and directly execs `/usr/local/bin/crabbox`.

OpenClaw profiles must omit `settings.class` (Incus classes are unmapped),
select that absolute wrapper as `settings.binary`, set `settings.provider` to
`incus`, and set `warmImage: false` because native Incus checkpoints support
containers only. Each Gateway's `service.required_pool` sets its global
required profile. Multiple explicitly placed pools exist; automatic placement
across unrelated Incus hosts has not been implemented or represented as an
upstream capability. Incus enforces aggregate quotas atomically; instance limits
and per-instance CPU/memory/disk shapes are independent controls. Crabbox and
OpenClaw own leases, guest expiry, cleanup and runtime state; Ductor has no
runtime service and schedules no reaper.

### Fresh host bootstrap and artifact import

`incus.bootstrap` is keyed by the deployment host id. An entry explicitly
contains `enabled: true`, pinned `package_version`, `listen_address` (`IP:8443`),
`storage_driver: dir`, `storage_pool`, `network`, `ipv4_address` (CIDR), boolean
`ipv4_nat`, `network_acl`, and native ACL `ingress`/`egress` arrays of explicit
allow rules. Renderer writes `incus/bootstrap/<host>/preseed.json`, `acl.json`,
and `approval.json`. Ubuntu 24.04 and Debian 13 native package sources are
supported; operator must approve an available package version supporting the
needed APIs. No package repository is added, existing package upgraded, block
device formatted, or initialized storage/network adopted.

The explicit `bootstrap-workers` Ansible action installs the pinned native
Incus package and QEMU dependencies, starts Incus, initializes the approved
directory storage/bridge/HTTPS endpoint on a fresh host, applies the ACL, and
records `/var/lib/ductor/incus-bootstrap.json`. It skips runtime pool
registration and images. After bootstrap, each daemon certificate is fetched
over the existing verified SSH connection to its `server_certificate_file`
reference; a mismatch with an existing pin fails. Local controller client
certificate/key generation is provided by the root credentials command.
Regular `deploy` does not silently initialize a host; run worker-bootstrap
first. Preflight is read-only and reports missing preparation.

A pool can optionally define `image_import` with `metadata_url`,
`metadata_sha256`, `disk_url`, `disk_sha256`. Deployment downloads verified
native Incus split exports, imports them into `image_source_project`, and then
requires the expected VM fingerprint and Node attestation. Use `default` as
the source project on a fresh host, or an already established source project.
This consumes an approved prepared image; it does not invent a release URL,
approve a hash, bypass the opencode-platform release process, or claim that
the existing Node 22 image is compatible.
