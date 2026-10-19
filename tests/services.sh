#!/usr/bin/env bash
# Configuration and fail-closed secret generation without Docker or a network.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FRAGMENT=${DUCTOR_SERVICES_SOURCE:-$ROOT/src/ductor}
if [[ ! -f $FRAGMENT ]]; then FRAGMENT=$ROOT/src/ductor; fi
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export DUCTOR_STATE_DIR="$TEST_ROOT/healthy"
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_die() { printf '%s\n' "$*" >&2; exit 1; }
ductor_require_cmd() { command -v "$1" >/dev/null || ductor_die "Missing test dependency: $1"; }
# shellcheck source=/dev/null
source "$FRAGMENT"

ductor_services_prepare
first=$(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env")
ductor_services_prepare
[[ $first == "$(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env")" ]]
[[ $(stat -c %a "$DUCTOR_STATE_DIR/services/secrets.env") == 600 ]]
[[ $(stat -c %a "$DUCTOR_STATE_DIR/services") == 700 ]]
for name in project-one project-two; do ductor_services_memory_scope "$name" --prepare; done
first=$(sha256sum "$DUCTOR_STATE_DIR/services/memory/project-one/token")
ductor_services_memory_scope project-one --prepare
[[ $first == "$(sha256sum "$DUCTOR_STATE_DIR/services/memory/project-one/token")" ]]
! cmp -s "$DUCTOR_STATE_DIR/services/memory/project-one/token" "$DUCTOR_STATE_DIR/services/memory/project-two/token"
[[ $(stat -c %a "$DUCTOR_STATE_DIR/services/memory/project-one/token") == 600 ]]
jq -e '.backendUrl == "http://ductor-memory-project-one:8765/mcp" and .palaceVolume == "ductor-memory-project-one-data"' \
    "$DUCTOR_STATE_DIR/services/memory/project-one/scope.json" >/dev/null
if (ductor_services_memory_scope ../../escape --prepare >/dev/null 2>&1); then exit 1; fi
if (DUCTOR_PAPERCLIP_PORT=4444 ductor_services_prepare >/dev/null 2>&1); then exit 1; fi

# The conditional call disables Bash errexit inside functions. A broken RNG
# must still stop before a credential/configuration file is committed.
(
    DUCTOR_STATE_DIR="$TEST_ROOT/rng-failure"
    openssl() { return 72; }
    if ductor_services_prepare; then printf 'FAIL: accepted broken RNG\n' >&2; exit 1; fi
    [[ ! -e $DUCTOR_STATE_DIR/services/secrets.env ]]
    [[ ! -e $DUCTOR_STATE_DIR/services/compose.yaml ]]
    if ductor_services_memory_scope failure --prepare; then printf 'FAIL: accepted broken scope RNG\n' >&2; exit 1; fi
    [[ ! -e $DUCTOR_STATE_DIR/services/memory/failure/compose.yaml ]]
)
# A successful command that emits no entropy is also rejected.
(
    DUCTOR_STATE_DIR="$TEST_ROOT/empty-rng"
    openssl() { return 0; }
    if ductor_services_prepare >/dev/null 2>&1; then exit 1; fi
    [[ ! -e $DUCTOR_STATE_DIR/services/secrets.env ]]
)
(
    DUCTOR_STATE_DIR="$TEST_ROOT/lost-secrets"
    ductor_services_prepare
    rm -- "$DUCTOR_STATE_DIR/services/secrets.env"
    if ductor_services_prepare >/dev/null 2>&1; then printf 'FAIL: regenerated lost installation secrets\n' >&2; exit 1; fi
)
# This optional validation uses the real Compose parser, without a daemon.
if [[ -n ${DUCTOR_COMPOSE_TEST_BIN:-} ]]; then
    "$DUCTOR_COMPOSE_TEST_BIN" --env-file "$DUCTOR_STATE_DIR/services/settings.env" \
        --env-file "$DUCTOR_STATE_DIR/services/secrets.env" -f "$DUCTOR_STATE_DIR/services/compose.yaml" config --quiet
    "$DUCTOR_COMPOSE_TEST_BIN" --env-file "$DUCTOR_STATE_DIR/services/settings.env" \
        --env-file "$DUCTOR_STATE_DIR/services/secrets.env" -f "$DUCTOR_STATE_DIR/services/compose.yaml" \
        --profile ssh-credentials config --quiet
    "$DUCTOR_COMPOSE_TEST_BIN" -f "$DUCTOR_STATE_DIR/services/memory/project-one/compose.yaml" config --quiet
fi
printf 'Service configuration, scope isolation, idempotence, and failure tests passed.\n'
