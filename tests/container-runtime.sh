#!/usr/bin/env bash
# Controller image contracts that do not require Docker or host service changes.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DUCTOR_TEST_SOURCE:-$ROOT/src/ductor}
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export DUCTOR_CONTAINER=1
export DUCTOR_STATE_DIR="$TEST_DIR/state"
export DUCTOR_INSTALL_DIR="$TEST_DIR/bin"
# shellcheck source=/dev/null
source "$SOURCE"
expect_failure() {
    if "$@" >"$TEST_DIR/failure.log" 2>&1; then
        printf 'FAIL: command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
}

[[ $INCUS_CONF == "$TEST_DIR/state/incus" ]]
for action in install dependencies update uninstall; do
    expect_failure bash "$SOURCE" "$action"
    grep -q 'versioned container image' "$TEST_DIR/failure.log"
done
[[ ! -e $DUCTOR_INSTALL_DIR ]]
bash "$SOURCE" help >/dev/null
bash "$SOURCE" version | grep -q 'Ductor '

# The container path must select the container handler before any useradd,
# sudoers, systemctl, or host-directory operation in the native install path.
ssh-keygen -q -t ed25519 -N '' -C fixture -f "$TEST_DIR/key"
ductor_container_broker_install() { printf '%s\n' "$1" >"$TEST_DIR/installed-key"; }
if [[ $EUID == 0 ]]; then
    ductor_broker_install "$TEST_DIR/key.pub"
    [[ $(cat "$TEST_DIR/installed-key") == "$TEST_DIR/key.pub" ]]
fi

mkdir -p "$DUCTOR_STATE_DIR/container"
cp "$TEST_DIR/key.pub" "$DUCTOR_STATE_DIR/container/ssh_host_ed25519_key.pub"
[[ $(ductor_broker_host_key_files) == "$DUCTOR_STATE_DIR/container/ssh_host_ed25519_key.pub" ]]
rm "$DUCTOR_STATE_DIR/container/ssh_host_ed25519_key.pub"
ln -s "$TEST_DIR/key.pub" "$DUCTOR_STATE_DIR/container/ssh_host_ed25519_key.pub"
[[ -z $(ductor_broker_host_key_files) ]]

# Independent container instances must contend on the persisted-state lock,
# while the ordinary mutation lock remains available to Docker exec commands.
ductor_container_supervisor_lock
expect_failure bash -c 'source "$1"; ductor_container_supervisor_lock' _ "$SOURCE"
grep -q 'already running for this state directory' "$TEST_DIR/failure.log"
ductor_lock
ductor_unlocked
flock -u 8
exec 8>&-

if [[ $EUID == 0 ]]; then
    expect_failure bash -c 'source "$1"; ductor_container_settings' _ "$SOURCE"
    export DUCTOR_STATE_DIR=/var/lib/ductor DUCTOR_INSTALL_DIR=/usr/local/bin INCUS_CONF=/var/lib/ductor/incus
    ductor_container_settings
    [[ $DUCTOR_BROKER_PORT == 2222 && $DUCTOR_BROKER_LISTEN_ADDRESS == 0.0.0.0 && $DUCTOR_REAPER_INTERVAL == 30 ]]
    for invalid in 0 65536 22junk '22
PermitRootLogin yes'; do
        expect_failure env "DUCTOR_BROKER_PORT=$invalid" bash -c 'source "$1"; ductor_container_settings' _ "$SOURCE"
    done
    expect_failure env DUCTOR_BROKER_LISTEN_ADDRESS='127.0.0.1 PermitRootLogin=yes' bash -c 'source "$1"; ductor_container_settings' _ "$SOURCE"
    expect_failure env DUCTOR_REAPER_INTERVAL=0 bash -c 'source "$1"; ductor_container_settings' _ "$SOURCE"
    expect_failure env INCUS_CONF=/tmp/different-incus-identity bash -c 'source "$1"; ductor_container_settings' _ "$SOURCE"
fi

# A remote Docker context breaks host-path identity for sibling bind mounts.
docker() {
    case "$*" in
        'context show') printf 'fixture\n' ;;
        'context inspect fixture --format {{.Endpoints.docker.Host}}') printf 'ssh://external.example\n' ;;
        *) return 99 ;;
    esac
}
export -f docker
expect_failure bash -c 'source "$1"; ductor_container_docker_endpoint' _ "$SOURCE"
grep -q 'Remote Docker contexts' "$TEST_DIR/failure.log"
expect_failure env DOCKER_HOST=tcp://external.example:2376 bash -c 'source "$1"; ductor_container_docker_endpoint' _ "$SOURCE"
grep -q 'Remote Docker contexts' "$TEST_DIR/failure.log"
printf 'Container runtime offline checks passed.\n'
