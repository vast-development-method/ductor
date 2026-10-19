#!/usr/bin/env bash
# Real Docker test, separate from tests/run.sh. Requires a disposable Linux host:
# /var/lib/ductor must not exist. No user service volumes or VMs are provisioned.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=${1:-ductor:ci}
container="ductor-image-test-$$"
state=/var/lib/ductor
port=32222
created=false
declare -a elevate=()
if [[ $EUID != 0 ]]; then elevate=(sudo -n); fi

fail() { printf 'Container test: %s\n' "$*" >&2; exit 1; }
cleanup() {
    local result=$?
    trap - EXIT
    if ((result != 0)); then docker logs "$container" >&2 2>/dev/null || true; fi
    docker rm --force "$container" >/dev/null 2>&1 || true
    if [[ $created == true ]]; then "${elevate[@]}" rm -rf -- "$state"; fi
    exit "$result"
}
trap cleanup EXIT
command -v docker >/dev/null || fail 'Docker CLI is required.'
docker info >/dev/null
[[ $(docker info --format '{{.OSType}}') == linux ]] || fail 'A Linux Docker Engine is required.'
"${elevate[@]}" test ! -e "$state" || fail 'Refusing to use an existing /var/lib/ductor. Run on a disposable CI host.'
"${elevate[@]}" install -d -m 0700 "$state"
created=true

expected=$(bash "$ROOT/src/ductor" version)
[[ $(docker run --rm "$image" version) == "$expected" ]] || fail 'Image and script versions differ.'
docker run --rm --entrypoint /bin/bash "$image" -eu -o pipefail -c '
    for tool in docker incus ssh sshd sudo tini bash jq openssl curl flock whiptail; do command -v "$tool" >/dev/null; done
    docker compose version >/dev/null
    incus --version >/dev/null
    ! command -v dockerd
    ! command -v incusd
    test -f /etc/ductor-container
'

start() {
    docker run -d --name "$container" --network host \
        --mount "type=bind,source=$state,target=$state" \
        --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
        --env "DUCTOR_BROKER_PORT=$port" --env DUCTOR_BROKER_LISTEN_ADDRESS=127.0.0.1 \
        --env DUCTOR_REAPER_INTERVAL=30 "$image" >/dev/null
    local attempt
    for ((attempt=0; attempt<60; attempt++)); do
        if docker exec "$container" ductor container-health >/dev/null 2>&1; then return 0; fi
        [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] || fail 'Controller exited before becoming healthy.'
        sleep 1
    done
    fail 'Controller did not become healthy within 60 seconds.'
}

start
docker exec "$container" ductor container-status
docker exec "$container" ductor services prepare
docker exec "$container" /bin/bash -eu -o pipefail -c '
    source /usr/local/bin/ductor
    ductor_services_compose config --quiet
'
docker exec "$container" /bin/bash -eu -c 'printf "persisted\n" > /var/lib/ductor/image-smoke-marker'
# This goes through the mounted host daemon. An anonymous volume or a different
# host/container state path would fail to expose the generated state correctly.
[[ $(docker exec "$container" docker run --rm --network none \
    --mount "type=bind,source=$state,target=$state,readonly" \
    --entrypoint cat "$image" "$state/image-smoke-marker") == persisted ]] || fail 'Sibling container cannot see controller state.'
host_key=$(docker exec "$container" ssh-keyscan -T 5 -t ed25519 -p "$port" 127.0.0.1 2>/dev/null)
[[ -n $host_key ]] || fail 'Broker did not present an SSH host key.'
printf '%s\n' "$host_key" | docker exec -i "$container" /bin/bash -eu -c 'cat > /var/lib/ductor/image-test-known-hosts'
docker exec "$container" ssh-keygen -q -t ed25519 -N '' -C image-smoke -f "$state/image-test-key"
docker exec "$container" ssh-keygen -q -t ed25519 -N '' -C wrong-key -f "$state/image-wrong-key"
docker exec "$container" ductor broker install "$state/image-test-key.pub"
broker_auth() {
    local response result=0
    # A real protocol operation reaches the root broker and rejects an absent
    # lease. An SSH auth failure would instead return 255. An attacker-supplied
    # command must be replaced by the forced JSON broker command.
    response=$(printf '%s\n' '{"protocol":1,"operation":"realize","params":{"lease":{"providerLeaseId":"d-000000000000000000000000"}}}' |
        docker exec -i "$container" ssh -T -F /dev/null -o BatchMode=yes \
            -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
            -o "UserKnownHostsFile=$state/image-test-known-hosts" -o IdentitiesOnly=yes \
            -i "$state/image-test-key" -p "$port" ductor-broker@127.0.0.1 \
            'touch /tmp/ductor-unwanted-command' 2>&1) || result=$?
    [[ $result == 1 && $response == *'Lease not found.'* ]] || fail "SSH did not reach the restricted broker: $response"
    docker exec "$container" test ! -e /tmp/ductor-unwanted-command || fail 'SSH ran a supplied host command.'
}
broker_auth
for rejected in wrong-key root; do
    login=ductor-broker key=$state/image-wrong-key result=0
    if [[ $rejected == root ]]; then login=root; key=$state/image-test-key; fi
    docker exec "$container" ssh -T -F /dev/null -o BatchMode=yes \
        -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$state/image-test-known-hosts" -o IdentitiesOnly=yes \
        -i "$key" -p "$port" "$login@127.0.0.1" true </dev/null >/dev/null 2>&1 || result=$?
    [[ $result == 255 ]] || fail "Broker did not reject $rejected authentication."
done
if docker exec "$container" ductor update >/dev/null 2>&1; then
    fail 'Container allowed in-place replacement of its versioned executable.'
fi
docker stop --time 15 "$container" >/dev/null
[[ $(docker inspect --format '{{.State.ExitCode}}' "$container") == 0 ]] || fail 'Controller did not shut down cleanly.'
docker rm "$container" >/dev/null
start
[[ $(docker exec "$container" cat "$state/image-smoke-marker") == persisted ]] || fail 'State was lost on container replacement.'
[[ $(docker exec "$container" ssh-keyscan -T 5 -t ed25519 -p "$port" 127.0.0.1 2>/dev/null) == "$host_key" ]] || fail 'SSH host identity changed on container replacement.'
broker_auth
docker stop --time 15 "$container" >/dev/null
[[ $(docker inspect --format '{{.State.ExitCode}}' "$container") == 0 ]] || fail 'Replacement controller did not shut down cleanly.'
printf 'Ductor real-container checks passed: runtime, dependencies, broker, persistence, sibling mounts and clean replacement.\n'
