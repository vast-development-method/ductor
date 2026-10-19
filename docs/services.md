# Control services, team access, and updates

Ductor renders pinned upstream containers and persistent volumes. `services prepare`
works offline without Docker; `services up` validates and starts the stack. Existing
credentials are retained. Application ports default to `127.0.0.1`; each service's
bind address and published port are adjustable. Databases are not published.
Production OpenBao uses durable PebbleDB storage; it starts sealed.

```bash
sudo ductor services prepare
sudo ductor services up
sudo ductor services status
sudo ductor services urls
```

## First owner and recovery material

With an external proxy, configure its route and certificate for the declared
Paperclip origin before onboarding. A new installation uses that origin from its
first account claim. Existing installations retain their canonical origin until
the new endpoint and operator access have been verified.

When using the private loopback defaults, forward the Paperclip port from your workstation:

```bash
ssh -L 3100:127.0.0.1:3100 operator@control-server
```

Open `http://localhost:3100`, create your Paperclip account, and claim the instance.
The first claim establishes its administrator. Ductor keeps Paperclip in
`authenticated` mode and enables its authentication rate limit.

Initialize OpenBao to a new private recovery file, then supply three distinct
unseal shares through the hidden terminal prompt:

```bash
sudo ductor services bao-init /root/ductor-openbao-recovery.json
sudo ductor services bao-unseal
```

Run the unseal command for each required share. Initialization creates five shares
with a threshold of three. Move the recovery material to your approved offline
storage and distribute shares to their custodians. Ductor does not print or retain
an automatic unseal token. A host/container restart can require unsealing again.

The generated ContextForge administrator email is initially
`admin@ductor.example.com`, unless `DUCTOR_ADMIN_EMAIL` was supplied before first
preparation. Its random password is in the root-only `services/secrets.env`. Configure
an actual operator email during setup. Changing that environment value after the
ContextForge database has been initialized is not an account-renaming operation.

## Your reverse proxy and service ports

The standard setup leaves domains, certificates and the reverse proxy under your
control. In the terminal menu, choose **Connections → Service networking**. Select
the published IPv4 or IPv6 address and port for each application, enter its public
origin, save, and apply. The same settings are available in `config.json`:

```json
{
  "services": {
    "paperclipUrl": "https://work.example.com",
    "gatewayOrigin": "https://tools.example.com",
    "openbaoUrl": "https://keys.example.com",
    "mempalaceUrl": "https://memory.example.com",
    "publish": {
      "paperclip": {"bindAddress": "127.0.0.1", "port": 3100},
      "contextforge": {"bindAddress": "127.0.0.1", "port": 4444},
      "openbao": {"bindAddress": "127.0.0.1", "port": 8200},
      "mempalace": {"bindAddress": "127.0.0.1", "port": 8765}
    }
  },
  "access": {"managedTls": false, "email": "", "trustProxy": true}
}
```

This is the service/access portion of the generated configuration. Use your actual
domains. A proxy on another machine needs the controller's reachable interface
address in place of loopback. `0.0.0.0` and `::` bind all interfaces for that address
family. Ports must be distinct and in the range 1024–65535. Ductor's local control
requests use the selected interface; wildcard bindings use the matching loopback
address. Existing configurations without `publish` retain their saved bindings.

Map each domain to its HTTP backend port and forward the original `Host` and scheme.
Set `trustProxy` only for exactly one trusted Paperclip reverse proxy that replaces
forwarded headers, with direct backend access restricted to that proxy. Authentication
remains enabled. The public HTTPS origins configure canonical URLs and secure browser
cookies; Ductor does not request certificates or open ports 80/443 in this mode.
An existing managed Caddy instance is stopped when applying `managedTls: false`.

The optional MemPalace origin exposes the base token-authenticated service. Agent
and project memory scopes retain separate private containers and remain accessible
through ContextForge only. Scoped memory and PostgreSQL are not given host ports.
Published addresses, credentials, and all named data volumes survive upgrades.

When Ductor itself runs in Docker, use the controller container's `ductor` CLI for
these operations. Its host networking and persistent state mounts preserve the
same service URLs and Compose bind mounts as the standalone installation.

## Optional managed team HTTPS

Prepare three DNS names pointing to the control server. The names must be reachable
for ACME validation on TCP ports 80/443; route firewall/NAT traffic accordingly.
Clients and VMs must also resolve and reach these names. Public DNS certificates
can be used with a private network, but this built-in flow does not implement DNS
challenge credentials or distribute a private certificate authority.

```bash
sudo ductor services access \
  --paperclip-host work.example.com \
  --gateway-host tools.example.com \
  --bao-host keys.example.com \
  --email operator@example.com
sudo ductor services access-check
```

Replace the example names and email with your own. This explicit command enables a
pinned Caddy reverse proxy on ports 80/443, configures Paperclip's canonical origin
and allowed hostname, trusts exactly the one managed proxy hop, and enables secure ContextForge cookies and matching browser
origins. MemPalace is not routed by Caddy and the databases remain unpublished. The Caddy admin endpoint
is not published. Caddy certificate/account state persists in dedicated volumes.

The command refuses to expose an unclaimed Paperclip or an uninitialized OpenBao.
It checks the resulting HTTPS endpoints with certificate verification; a DNS,
certificate, or application failure returns an error rather than reporting success.
A reachable but sealed OpenBao is reported as sealed and cannot release credentials.
Use `access-check` to repeat verification after fixing DNS or firewall routing.
The command saves previous access settings under a private `.access-backup.*`
directory in service state. It does not replace an existing operator-managed proxy.

Once HTTPS is enabled, use the HTTPS ContextForge admin URL: its secure browser
cookies intentionally do not work over a plain HTTP SSH-forwarded URL. Trusted
local controller API calls still use explicit bearer credentials on the configured
host-side listener.

## Service credentials and SSH transport

A credential import reads a private JSON file into OpenBao KV v2:

```bash
sudo ductor services secret-import email/service \
  /root/email-credentials.json /root/bao-admin-token
```

Both files must be regular files owned by the invoking operator with mode `0600`.
The administrator token file contains only the token, not the recovery JSON.
Credential content is not passed as a command argument or logged. Existing entries
require `--replace`; updates use the previous KV version as a compare-and-set guard.
Importing a credential does not automatically grant it to an agent. A scoped
connector/policy grant remains necessary.

```bash
sudo ductor services ssh-credentials /root/bao-admin-token
```

This generates a dedicated Ed25519 transport key once, stores it in OpenBao, and
issues a narrow AppRole to a native OpenBao Agent sidecar. Only that sidecar receives
the AppRole SecretID. Paperclip reads the rendered private key from a read-only
volume; the key does not enter Paperclip's database. The public key is available
at `services/ssh-agent/id_ed25519.pub` for trusted controller/VM authorization.
The helper verifies the rendered public identity inside the actual Paperclip
container before reporting completion. The AppRole SecretID expires after 30 days;
rerun the helper before expiry to refresh it while retaining the same SSH key.

Removing an AppRole or sealing OpenBao does **not** revoke an already rendered
static SSH key. Remove the public key from the affected `authorized_keys`, or rotate
it, when revoking transport access. Agent/VM dispatch additionally verifies SSH host
keys, machine ID, non-root runtime UID, and the installed runtime contract from the
Paperclip container. That transport probe does not itself prove guest-to-gateway
or guest-to-OpenBao connectivity.

## Isolated memory

```bash
sudo ductor services memory-scope project-one
```

Each scope receives its own MemPalace process, bearer token, and durable volume.
The endpoint has no host port; only the dedicated gateway/memory Docker network can
reach it. ContextForge's SSRF permission covers that network's validated actual
CIDR, rather than all private networks. The credential/database network is separate.
A scope is a trust boundary; agent-level isolation requires separate scopes where
agents must not share the same memory. The binding workflow registers the backend
and grants the narrower agent gateway identity.

## Updating the pinned service bundle

Updating the Ductor executable and applying its service bundle are separate steps:

```bash
sudo ductor update
sudo ductor services upgrade plan
```

The plan renders the new configuration privately and shows existing versus embedded
image pins. It does not start containers or select upstream `latest` tags.

Before applying, take a consistent, restorable backup of **both PostgreSQL
databases, OpenBao data and recovery material, all MemPalace volumes, Paperclip
application data, and the private service configuration**. Use each application's
backup procedure or stop writers before taking consistent storage snapshots. Retain
the previous Ductor version and verify that your restoration procedure works.

```bash
sudo ductor services upgrade apply --backup-confirmed
```

The flag records your assertion that the full data backup exists; Ductor does not
perform or verify that backup. It first validates and pulls the new pinned images,
then saves a private configuration snapshot under `service-config-backups`, refreshes
configuration, starts containers, and checks their health. Existing secrets and
volumes are retained. The snapshot **does not contain database/application volumes**.

If a migration or health check fails, Ductor returns an error and leaves evidence
for diagnosis. It does not attempt a database rollback. Restoring old Compose files
alone cannot undo schema migrations. Recovery may require restoring the full
pre-upgrade data backup with the previous application images. OpenBao may need
unsealing after a container replacement; jobs still need their normal credential
and runtime readiness checks.

`services down` stops containers while retaining volumes. Never add `-v` to a manual
Compose shutdown unless you intentionally want to destroy the persisted data.

## Validation status

Offline tests cover configuration parsing with the official Compose parser,
credential retention, failed entropy generation, isolated memory scopes, narrow
credential policies, private-file/CAS imports, bootstrap exposure gates, TLS error
reporting, and upgrade failure boundaries. API/container fixtures test failure
propagation. They are not a substitute for deploying and exercising this stack on
your actual Docker/Incus hosts, including DNS, certificate issuance, account login,
unsealing, database migrations, and a complete agent task.
