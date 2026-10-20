# Controller container

The Ductor container is an interactive operations tool. It has no runtime daemon,
Docker socket mount, incoming broker port or host-network requirement. Closing it
does not stop the deployed services.

The image repository is `ghcr.io/vast-development-method/ductor`. Use a published
version or commit tag and record the resolved image digest for the deployment.
A version in `VERSION` is not proof that its release image has been published.

## Persistent controller inputs

Create two private directories on the machine running the controller container:

```bash
sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" /srv/ductor-controller /srv/ductor-inputs
export DUCTOR_STATE_PATH=/srv/ductor-controller
export DUCTOR_INPUTS_PATH=/srv/ductor-inputs
export DUCTOR_UID="$(id -u)"
export DUCTOR_GID="$(id -g)"
```

Put SSH private keys, existing private credential inputs and company knowledge
sources under `/srv/ductor-inputs`. The container sees this directory read-only
at `/run/ductor-inputs`. Configuration must use those container-visible paths,
not their source paths on the Docker host.

Run the container with the UID/GID that owns the mounted private files. The
Compose defaults are root; setting `DUCTOR_UID` and `DUCTOR_GID` as above uses the
operator's identity. Root/current-user ownership and restrictive permissions are
checked before private credentials are read.

The controller state directory is writable at `/var/lib/ductor`. Save desired
configuration, rendered plans, verified `known_hosts` files and newly generated
credential/recovery outputs there. In particular, host-key enrollment cannot
write to the read-only inputs mount. Protect the state directory and its backups
as secrets even though desired configuration contains only secret references.

Select an available reviewed image and run:

```bash
export DUCTOR_IMAGE=ghcr.io/vast-development-method/ductor:2.0.0-rc.1
docker compose -f compose.ductor.yaml run --rm ductor setup
docker compose -f compose.ductor.yaml run --rm ductor validate
docker compose -f compose.ductor.yaml run --rm ductor preflight
docker compose -f compose.ductor.yaml run --rm ductor deploy
```

These commands require that the selected image has been built and published.
During development, build the checked-out branch locally and set `DUCTOR_IMAGE`
to that local image tag instead.

## Which host owns service storage?

`hosts.<id>.data_root` is a path on the selected SSH service host. It is not a
path inside the Ductor container and does not need to be mounted into it. Service
bind mounts live under that host's `data_root/services/<service-id>`.

Even a service deployed on the controller's own Docker host is administered via
SSH. Use an address reachable from the container; `127.0.0.1` inside the container
means the container itself. Verify that host's SSH key through an independent
trusted channel before enrollment.

The read-only container filesystem has a temporary `/tmp`; persistent controller
state and native service state are separate. Do not add a Docker socket mount to
work around SSH failures.

## Controller upgrades

Choose an explicit new image version or digest, pull it, and run the same Compose
command with the same bind mounts. Back up controller state first. Container
upgrades do not change service versions automatically; service changes remain
explicit desired-configuration updates followed by Ductor's `update` action.
