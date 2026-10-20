# Persistent JoomEngine MCP services

Ductor deploys the existing `octoleo/joomengine` Apache MCP image with a private
MariaDB service. It does not build a competing Joomla image. Both images must
include an explicit tag and a full `@sha256:` digest. Standard JoomEngine tags
without `-mcp` do not include MCP. The leading image version is JCB's version.

Use an enrolled dedicated services host, preferably an isolated Incus VM. The
existing `service_vms` contract now accepts `kind: joomengine` as well as OpenClaw:
the VM references the service ID, its fixed private address and one backend port.
Its own project, storage, firewall rules and `boot.autostart` persist independently
of Ductor. See [service-vm.md](service-vm.md) for the hypervisor/guest enrollment
and explicit ingress/egress contract. Permit only the reverse proxy to reach the
Joomla backend; operator SSH and approved image/update destinations are separate
rules. Ductor never exposes a MariaDB host port or mounts the Docker/Incus socket
into Joomla.

## Desired configuration

Add the service to `services` with these fields:

| Field | Value |
|---|---|
| `kind`, `enabled`, `host` | `joomengine`, `true`, enrolled guest host ID |
| `image` | Digest-pinned official Apache `-mcp` image |
| `database_image` | Digest-pinned `mariadb` release image |
| `bind_address`, `port` | Guest private IP and fixed backend port |
| `url` | Your canonical HTTPS origin, terminated by your reverse proxy |
| `cpus`, `memory_mib`, `disk_gib` | Combined service resource reservation |
| `database_cpus`, `database_memory_mib` | Database's share of CPU/RAM; Joomla receives the remainder |
| `site_name`, `admin_username`, `admin_email` | Explicit installation identity; admin username uses 3–32 letters |
| `mcp_client` | Dedicated `{id, username, name, email, permissions}` object |

`mcp_client.permissions` defaults to `{}` for discovery and basic system reads.
Content/JCB read authority must be explicitly added for the target component:
the article read integration uses `{"com_content":{"core.manage":true}}`.
The map contains selected Joomla component assets and boolean `true` actions.
For example, JCB operations can receive only the required actions on
`com_componentbuilder`. Root permissions and administrator login are rejected.
Native JCB jobs require explicitly selected `core.admin` on
`com_componentbuilder`; compilation with installation additionally requires it
on `com_installer`. These are scoped component grants, never global Super User
membership. `core.admin` on other assets is rejected.
The helper owns the narrow global API-login grant. Write access
requires an explicit native `mcp.write` grant and remains subject to the MCP
component's guarded write protocol and the target component's Joomla ACL.

Add two absolute private file references:

- `credentials.joomengine_files.<service-id>`: generated deployment passwords.
- `credentials.joomengine_client_files.<service-id>`: generated native MCP handoff.

Neither file's contents belong in desired configuration, source control, image
layers, command arguments or logs. Deployment accepts protected local credential
files, including files materialized from your existing OpenBao workflow. OpenBao
is not contacted by the Joomla/database containers at startup. Their existing
local secrets keep the service running during controller or vault outages.

Resolve image digests once on a Docker-enabled operator host before saving the
configuration. For example:

```bash
docker pull octoleo/joomengine:6.2.0-php8.4-apache-mcp
docker image inspect --format '{{index .RepoDigests 0}}' octoleo/joomengine:6.2.0-php8.4-apache-mcp
docker pull mariadb:11.4
docker image inspect --format '{{index .RepoDigests 0}}' mariadb:11.4
```

Retain each selected tag before the reported `@sha256:…` value in the service
configuration. Changing a rolling registry tag cannot alter a pinned deployment.

## Deployment and enrollment

With the service ID `joomla` enrolled:

```bash
ductor validate
ductor joomengine credentials --service joomla
ductor bootstrap-services --service joomla
# Enroll the guest host key using the verified hypervisor's reported fingerprint.
ductor deploy --service joomla
ductor joomengine provision --service joomla
ductor status --service joomla
```

`bootstrap-services` applies only when this service has a `service_vms` entry.
An already enrolled standalone services host can go straight to deployment.

Credential generation creates four distinct random passwords in mode `0600` and
preserves existing valid credentials on repeat invocations. Deployment rejects
changes to the installed database/admin secret files rather than silently
rotating passwords underneath an existing site. Rotate credentials through the
native application/database procedures and update their protected references
deliberately.

The native PHP enrollment helper runs outside the public web root. It uses
Joomla's user, user-group, extension, asset and token-plugin APIs, creates a group
under Public, grants API login and MCP access/execute, and applies only the
configured component permissions. It never assigns the Super Users group. It
refuses unrelated existing users/groups and changed grants. Repeated enrollment
preserves the identity and token. Its temporary password input is removed after
the operation. Explicit provisioning also runs the installed
`joomla:mcp:jcb-sync` console command as `www-data`, so JCB API definitions are
refreshed before the client handoff is reported as ready.

The private client handoff contains `schema`, `service_id`, `client_id`,
`username`, `user_id`, `write_enabled`, `url`, `alias` and `token`. `url` is the
native endpoint at `/api/index.php/v1/joomengine-mcp`; clients send the token using
`X-Joomla-Token`. Import that handoff into the agent platform's protected runtime
credential flow. The controller ZIP includes both private file references and
rebases them when imported on another controller.

Each service configuration manages one explicit MCP client. Adding further
identities requires a separate deliberate native enrollment; provisioning never
shares a broad administrator token with every agent. Empty component permissions
allow discovery and system reads. Article reads additionally need
`com_content.core.manage`; JCB compilation needs explicit
`com_componentbuilder.core.admin` plus MCP write/approval permissions, while
installation additionally needs `com_installer.core.admin`. These are scoped
component grants, never global Super User access.

## Persistence, updates and backups

Persistent bind directories under the selected host data root hold Joomla,
MariaDB, MCP artifacts and protected service inputs. Docker's
`restart: unless-stopped` owns service restart behavior; Incus owns VM autostart.
Neither service depends on a running Ductor process. `monitor` and `status` only
read current state. Bringing a controller back online does not redeploy it.

An image update does not upgrade extensions already installed in a persistent
Joomla site. After selecting and deploying a new pinned MCP image, explicitly run:

```bash
ductor joomengine migrate-mcp --service joomla
ductor joomengine provision --service joomla
```

Migration first stops writers, archives the entire service directory, and restores
the previous running state. It then verifies the bundled MCP archive and invokes
Joomla's native extension installer as `www-data`. A failed installer leaves the
backup available for recovery; Ductor does not pretend that database migrations
are automatically reversible. Existing site data is never replaced with a fresh
Joomla installation. Use `ductor backup --service joomla` for the same consistent
backup independently; transfer backups to encrypted off-host storage.

## Verification

The native integration workflow runs generated Compose services against real
MariaDB, enrolls a dedicated client twice, checks authenticated MCP initialization
and discovery, an allowed read and a denied write, then recreates containers and
checks the same identity and persistent data again. It uses a disposable trusted
TLS certificate and private files. When `PLATFORM_CHECKOUT` names the pinned
opencode-platform checkout, the same service is exercised by its actual
`vdm-joomla-mcp read-test` client before and after recreation. Its token remains
in a mode-`0600` file and diagnostic evidence remains private on the test runner.
JoomEngine remains an independent, general-purpose upstream service. Ductor
consumes the published image by digest; it does not build a platform-specific
variant or require an upstream change. Its existing Joomla CLI exposes MCP
commands and the native `componentbuilder:compile:component` command.

With `JOOMENGINE_TEST_JCB=1`, CI discovers the installed CLI catalogue and invokes
the existing compiler as the trusted local `www-data` operator, then verifies
the generated archives. This deliberate local test has the service filesystem's
authority; it does not give an agent Docker access or bypass the scoped HTTP
identity. It compiles the pinned installer's Demo fixture without installation.

CI separately probes the installed MCP component's detached-job capability. If
available, a separate HTTP compiler identity explicitly approves the compile,
observes its durable job from a new session, verifies confirmation replay safety,
and checks downloaded archives by SHA-256, ZIP integrity and Joomla manifest.
If that capability is unavailable, CI requires the native
`WORKER_UNAVAILABLE` planning response before any mutation and reports that
specific limitation. Native CLI availability and compilation are still tested;
they are not inferred from detached-worker support. Test credentials, containers
and artifacts are removed on exit.
Production Incus routing, external TLS and
backup restoration still require validation against the actual infrastructure.
