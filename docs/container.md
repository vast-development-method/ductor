# Run Ductor as a container or a standalone script

The same `src/ductor` executable supports both installations. The standalone
installer remains available. The container packages that executable and its
dependencies; it does not install another Docker or Incus daemon.

The initial image is `ghcr.io/vast-development-method/ductor:0.1.0-rc.1`, built
for Linux `amd64` and `arm64`. This is a pilot release. Container tests verify
the controller lifecycle, SSH broker, persistent state and sibling Docker
mounts; a complete authenticated Paperclip → Incus → OpenBao → ContextForge →
Codex run still needs qualification on your infrastructure.

## What stays running

`ductor serve` runs the restricted SSH broker and the expired-lease reaper.
Docker restarts the controller after an unexpected exit. `tini` forwards signals
and reaps orphaned child processes. The image health check monitors the local
broker and reaper, independently of whether you have finished configuring
Paperclip, unsealed OpenBao or enrolled any worker servers.

The terminal menu is opened with `docker compose exec`. Ductor does not add a
second web dashboard or TLS listener. Paperclip remains the normal team-facing
application. Its services run as sibling containers on the host Docker daemon,
with their existing databases and persistent volumes.

## Requirements

- A Linux server with Docker Engine 25 or newer and Docker Compose. Docker
  Desktop and rootless Docker are not the qualified controller environment.
- Administrative access to the Docker daemon. Its socket gives Ductor control
  of that host's containers; this is an infrastructure administrator component.
- `/var/lib/ductor` mounted at the **same absolute path** on the host and inside
  the controller. Generated service Compose files bind configuration files from
  this path. A named volume or a differently named host path breaks that mapping.
- A reachable Incus server, local or remote, with an authenticated client
  connection. The controller image contains the Incus client only.

The supplied controller Compose file uses Linux host networking so the service
ports already bound to `127.0.0.1` remain reachable by Ductor. The broker listens
on TCP `2222` by default, separately from the host's normal SSH port. Do not add
Docker `ports:` mappings to the controller while using host networking.

## Start the initial release candidate

The release-candidate workflow publishes only after the complete offline test
suite and real-container tests pass. The draft branch is the source for the
initial Compose manifest; after merge, use the manifest from the release you
are installing.

```bash
sudo install -d -m 0700 /var/lib/ductor
curl -fsSL https://raw.githubusercontent.com/vast-development-method/ductor/feature/ductor-bootstrap/compose.ductor.yaml -o compose.ductor.yaml
sudo docker compose -f compose.ductor.yaml pull
sudo docker compose -f compose.ductor.yaml up -d
sudo docker compose -f compose.ductor.yaml exec ductor ductor setup
```

If the organization keeps its GHCR package private, authenticate Docker to
GHCR with your own permitted account before `pull`, or make the Ductor package
public in GitHub's package settings. The publishing workflow uses its own
short-lived `GITHUB_TOKEN`; it requires no repository PAT secret.

Setup asks for hardware, service URLs, credentials and agent policy just as in
the standalone installation. Keep secret files below `/var/lib/ductor` so they
remain available after container replacement. OpenBao recovery material must
still be copied to a separate safe location through your normal recovery
process.

```bash
# Open the menu, inspect status or rerun saved configuration.
sudo docker compose -f compose.ductor.yaml exec ductor ductor menu
sudo docker compose -f compose.ductor.yaml exec ductor ductor status
sudo docker compose -f compose.ductor.yaml exec ductor ductor apply

# Inspect the controller itself, including its broker/reaper processes.
sudo docker compose -f compose.ductor.yaml exec ductor ductor container-status
sudo docker compose -f compose.ductor.yaml logs --tail 100 ductor
```

The image also supports direct commands with `docker run`. The long-running
Compose installation is preferred because the broker and reaper must remain
available while agents work. Do not start two controllers against the same
state directory.

## Service domains and your own reverse proxy

Each service keeps its own configured server port and external URL. Point your
reverse proxy at those ports and manage the certificates yourself. Keep managed
TLS disabled when using your own proxy. A Ductor image update does not
automatically enable TLS or replace your proxy.

Set the final service URLs in Ductor so allowed origins, authentication and
agent connections refer to the right domains. A proxy running on a different
machine needs service ports bound to a reachable server address and appropriate
network rules. PostgreSQL remains private within the service stack. Scoped
MemPalace instances stay behind ContextForge rather than exposing independent
agent tokens on public endpoints.

The controller's SSH broker is not an HTTP service and does not need an HTTPS
domain. Configure Paperclip's broker connection with an address reachable from
Paperclip's container, port `2222` (or your chosen port) and the verified SSH host
key. Do not use `localhost` inside Paperclip to mean the Docker host.

Controller settings can be supplied in a `.env` file next to the Compose file:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DUCTOR_IMAGE` | `ghcr.io/vast-development-method/ductor:0.1.0-rc.1` | Version or digest to run |
| `DUCTOR_BROKER_LISTEN_ADDRESS` | `0.0.0.0` | Broker interface; use a reachable private address where appropriate |
| `DUCTOR_BROKER_PORT` | `2222` | Broker SSH port |
| `DUCTOR_REAPER_INTERVAL` | `30` | Seconds between expired-lease checks |
| `DUCTOR_CONTROLLER_MEMORY` | `512m` | Controller container memory ceiling |
| `DUCTOR_CONTROLLER_CPUS` | `1.0` | Controller CPU ceiling |

These CPU and memory ceilings apply to Ductor itself. Worker and service budgets
are configured separately.

## Connect local and external Incus servers

Authenticate each server through the Incus client inside Ductor. Its settings,
client certificate and trusted server certificates persist under
`/var/lib/ductor/incus`.

```bash
read -rp 'Incus remote name: ' INCUS_REMOTE
read -rp 'Incus HTTPS URL: ' INCUS_URL
sudo docker compose -f compose.ductor.yaml exec ductor incus remote add "$INCUS_REMOTE" "$INCUS_URL"
sudo docker compose -f compose.ductor.yaml exec ductor incus remote list
sudo docker compose -f compose.ductor.yaml exec ductor ductor menu
```

Complete Incus's fingerprint verification and native trust enrollment. Then add
the server and its budgets through Ductor's menu. The same process works for a
LAN host or an externally reachable host; the network must permit the approved
Incus connection and agents must reach their service URLs. Ductor does not open
remote firewall ports or bypass Incus trust.

If Incus is on the Docker host and you explicitly prefer its Unix socket, add
this separate `compose.incus-local.yaml` override:

```yaml
services:
  ductor:
    volumes:
      - type: bind
        source: /var/lib/incus/unix.socket
        target: /var/lib/incus/unix.socket
        bind:
          create_host_path: false
```

Start and manage that installation with both files:

```bash
sudo docker compose -f compose.ductor.yaml -f compose.incus-local.yaml up -d
sudo docker compose -f compose.ductor.yaml -f compose.incus-local.yaml exec ductor incus info local:
```

Only add this mount when that is the actual socket path on your host. It grants
local administrative Incus access; authenticated network remotes are the
default path for other hosts.

## Persistence, updates and switching installation mode

`/var/lib/ductor` retains desired configuration, inventory, reservations, agent
registries, account references, generated service configuration, Incus client
identity and the controller's SSH host keys. The service databases, application
files, memory and OpenBao storage remain in their own Docker volumes. Removing
or replacing the controller does not remove those services or their volumes.

The initial `0.1.0-rc.1` tag follows tested updates on the trusted bootstrap
branch during review. Every successful publication also has a `sha-` tag with
the full source commit. Pin a verified digest for an installation that must not
change when a tag moves:

```bash
sudo docker pull ghcr.io/vast-development-method/ductor:0.1.0-rc.1
sudo docker image inspect ghcr.io/vast-development-method/ductor:0.1.0-rc.1 \
  --format '{{index .RepoDigests 0}}'
```

Use the returned `ghcr.io/vast-development-method/ductor@sha256:...` reference as
the `DUCTOR_IMAGE` value. Alternatively, select the exact `sha-<full commit>` tag
shown by the publication workflow. Prerelease publication never updates
`latest`; stable semantic-version tags publish their exact version, minor
series and `latest` only after both architectures pass.

To update, take your normal state and service-data backups, select the desired
image in `.env`, and run:

```bash
sudo docker compose -f compose.ductor.yaml pull ductor
sudo docker compose -f compose.ductor.yaml up -d --no-deps ductor
sudo docker compose -f compose.ductor.yaml exec ductor ductor container-status
sudo docker compose -f compose.ductor.yaml exec ductor ductor doctor
```

Do not run `ductor update` inside the container. The executable belongs to the
versioned image, so that command refuses in-place script replacement. Updating
Ductor does not upgrade the managed service images: use Ductor's separate
service update plan and backup-confirmed apply flow for those, including any
upstream database migrations.

To migrate an existing standalone installation, first back up its state and
stop its broker/reaper activity. Keep the original `/var/lib/ductor` path,
explicitly migrate any Incus client trust files into its `incus` subdirectory,
then start the container. Update Paperclip's broker endpoint and verify its
SSH host key for the new listener. Conversely, stop the container before
re-enabling a standalone controller. Never run both broker/reaper instances
against the same live state during a migration.

## Build and verify locally

```bash
docker build --tag ductor:ci .
# Only on a disposable Linux test host without an existing /var/lib/ductor:
bash tests/container-image.sh ductor:ci
```

The Dockerfile pins the Ubuntu base digest and Docker CLI/Compose package
versions. Ubuntu security packages are resolved at build time. The image
contains no embedded credentials or SSH host keys and installs no Docker or
Incus daemon. The build context allows only the Dockerfile, runtime script and
license so local configuration cannot accidentally enter an image layer.

Relevant upstream contracts:

- [Docker's Ubuntu package repository](https://docs.docker.com/engine/install/ubuntu/)
- [Ubuntu's Incus client package](https://packages.ubuntu.com/noble/incus-client)
- [Docker host networking](https://docs.docker.com/engine/network/drivers/host/)
- [Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)
- [GitHub Actions container publication](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
