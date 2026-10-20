# Service operations and credentials

The saved configuration selects service hosts, bind addresses, ports, advertised
URLs, persistent paths and image versions. All host administration uses verified
SSH. OpenBao credential operations use its native HTTPS API and protected files.
The external reverse proxy and certificates remain operator-managed.

## Controller downtime and reconnect

Ductor is an operations client. Closing it, stopping its container or losing the
controller host does not stop service containers, interrupt OpenBao Agent token
renewal or take ownership of running workers. Those responsibilities belong to
the installed native services. Their state and restart policies live on their
own hosts, not in a Ductor process.

When Ductor returns, open the menu or run `status` using the persisted desired
configuration and verified SSH inputs. It reconnects to inspect current live
state. Starting the controller or selecting status must not redeploy, restart,
reinitialize or reconcile services. An explicit deployment/update/restart action
is required to change them.

For ongoing infrastructure visibility, run:

```bash
ductor monitor --interval 30
ductor monitor --service team --once
```

`monitor` polls the same read-only status path, re-reads persisted configuration
on each cycle and releases its controller lock between polls. A failed connection
is reported; it does not trigger a repair or restart. Ctrl-C stops only the
monitor. Use OpenClaw's UI for agent conversations and current work; infrastructure
status is not a second task scheduler.

The monitor's `passed`/`failed` observation result reports whether the status
operation completed, not whether every service is healthy. Read the actual native
states: for example, an OpenBao server can be successfully observed as sealed.
Monitoring does not add alert delivery or automatic recovery, and an offline
controller does not capture the status polls it missed.

Use a [portable controller ZIP](controller-portability.md) to set up another
Ductor installation with the same configuration and referenced keys. Concurrent
monitors are supported; explicit mutation operations use remote host locks.
Configuration changes are propagated deliberately, not automatically synchronized.

Service Compose projects use native `restart: unless-stopped`; the dedicated
service VM uses Incus boot autostart. This is native restart behavior, not a claim
that every application failure is automatically repairable. In particular,
OpenBao's default Shamir seal still needs operator unseal after its server restarts.
That requirement comes from the OpenBao seal configuration, not Ductor being
offline. Recovery material and a tested recovery procedure must remain available
independently of the controller.

## OpenBao first

Deploy OpenBao separately before gateways that need it. The rendered server runs
in production mode with Raft storage; it never uses the image's default development
server. Its HTTP backend binds to the selected host's loopback address behind the
operator's TLS proxy. The advertised API URL must be HTTPS.

A new server starts sealed and uninitialized. Configure a protected
`credentials.openbao_bootstrap_output_file`, then run:

```bash
ductor deploy --service bao
ductor credentials bootstrap --service bao
```

Replace `bao` with the configured service ID. Initialization writes recovery
material into the configured private file and does not print it. Preserve that
material outside the deployment host using the organization's recovery procedure.
It also writes the bootstrap operator token to the configured absent
`credentials.openbao_token_file` with mode 0600; no token extraction into a shell
argument is needed. Existing token or recovery destinations are not overwritten.
An interrupted initialization must be investigated; blindly retrying cannot
recover keys that were already issued.

Set `credentials.openbao_unseal_file` to the protected share input, and
`credentials.openbao_token_file` to a protected operator-token file. Unseal and
provision the declared gateway AppRoles:

```bash
ductor credentials unseal --service bao
ductor credentials provision --service bao
```

Configure operator authentication and revoke the bootstrap root token after
provisioning. Keep recovery keys and root tokens out of gateway mounts. Default
Shamir sealing requires unseal after server restart. This release does not claim
unattended recovery or an HA cluster from a single-node deployment.

## Gateway secret delivery

A gateway's `provider_keys` maps provider IDs to references such as
`gateways/team/providers/openai/apiKey`. The last path segment names the KV v2
field. Only that gateway's namespace is granted to its AppRole. Create the actual
provider value from a protected single-line text file:

```bash
ductor credentials put --service team --provider openai --input-file /absolute/private/openai-key
```

The gateway/provider must already be declared. Ductor writes the configured KV v2
field, preserves sibling fields and uses native compare-and-set protection.
A reference alone is not a stored credential. Never put the key in command
arguments, ordinary configuration or a repository.

Configure a separate RoleID and SecretID file destination for each gateway under
`credentials.openbao_approles`. Provisioning writes these files privately.
Deployment mounts them only into OpenBao Agent. The Agent logs in, renews the
service token and reauthenticates independently of Ductor. The gateway receives a
read-only token sink, not the AppRole bootstrap credential.

OpenClaw uses the bundled Vault-compatible secret resolver against OpenBao's KV v2
API. No custom credential-renewal plugin is required. AppRole SecretIDs persist
so the service can restart without Ductor; rotate and revoke that bootstrap
credential through native OpenBao administration. Token renewal does not reload
changed provider values: use native `openclaw secrets reload` after a key rotation
and verify the affected account before resuming work.

OpenBao removed `mlock`; this deployment does not add obsolete IPC_LOCK settings.
Host swap must be disabled or appropriately encrypted. The service's memory and
core-dump settings do not excuse an unprotected host.

## Status, changes and backups

Use the saved configuration with the following controller actions:

```bash
ductor preflight
ductor status
ductor deploy --service team
ductor restart --service team
ductor backup --service team
```

A successful render is not a running-service health check. A reachable gateway is
not evidence that its provider account or worker pool works. Complete native
activation and the live checks in [production qualification](production-qualification.md).

Change pinned versions in reviewed configuration before running `update`. Review
upstream compatibility and take a backup first. An image downgrade is not
necessarily a data downgrade; rollback must use the service's supported restore
procedure and a compatible backup.

Protect backups as secrets. OpenBao requires its native Raft snapshot path for a
consistent online backup. Do not treat a tar archive of a live Raft data directory
as a recovery guarantee. OpenClaw recovery includes its state, workspaces and
native auth configuration, not only `openclaw.json`. Test restore on a separate
host and keep the result with the deployment acceptance record.

The gateway backup is a **cold backup**: it stops its currently running Compose
services, archives the persistent directory and restarts only those services that
were running before. Schedule its interruption deliberately. Archives are mode
0600 beneath `<data_root>/backups`. OpenBao's native online snapshots are mode
0600 beneath `<data_root>/services/<bao-id>/backups`. Copy completed backups to
encrypted off-host storage; host-local archives do not protect against host loss.
