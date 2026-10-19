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
# Published listeners are independent from public proxy origins; an update must
# preserve both literal IPv6/IPv4 addresses and operator-selected ports.
for address in 127.0.0.1 0.0.0.0 192.0.2.10 :: ::1 2001:db8::10 2001:db8:0:0:0:0:0:10; do
    ductor_services_bind_address "$address"
done
for address in 256.0.0.1 01.2.3.4 example.com ':::' '1::2::3' '1::2:' ':1::2' '1:2:3' '[::1]' '::1%eth0' '127.0.0.1;false'; do
    if ductor_services_bind_address "$address"; then printf 'Accepted invalid bind address: %s\n' "$address" >&2; exit 1; fi
done
ductor_services_setting_set PAPERCLIP_BIND_ADDRESS 192.0.2.10 "$DUCTOR_STATE_DIR/services/settings.env"
ductor_services_setting_set PAPERCLIP_PORT 13100 "$DUCTOR_STATE_DIR/services/settings.env"
ductor_services_setting_set OPENBAO_BIND_ADDRESS ::1 "$DUCTOR_STATE_DIR/services/settings.env"
ductor_services_prepare
[[ $(ductor_services_local_origin PAPERCLIP) == http://192.0.2.10:13100 ]]
[[ $(ductor_services_local_origin OPENBAO) == 'http://[::1]:8200' ]]
ductor_services_setting_set OPENBAO_BIND_ADDRESS :: "$DUCTOR_STATE_DIR/services/settings.env"
[[ $(ductor_services_local_origin OPENBAO) == 'http://[::1]:8200' ]]
ductor_services_setting_set CONTEXTFORGE_BIND_ADDRESS 0.0.0.0 "$DUCTOR_STATE_DIR/services/settings.env"
[[ $(ductor_services_local_origin CONTEXTFORGE) == http://127.0.0.1:4444 ]]
[[ $first == "$(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env")" ]]
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
        --env-file "$DUCTOR_STATE_DIR/services/secrets.env" -f "$DUCTOR_STATE_DIR/services/compose.yaml" config --format json >"$TEST_ROOT/compose.json"
    jq -e '.services.paperclip.ports[0].host_ip=="192.0.2.10" and .services.paperclip.ports[0].published=="13100" and .services.openbao.ports[0].host_ip=="::" and (.services["paperclip-db"].ports // [] | length)==0 and (.services["contextforge-db"].ports // [] | length)==0' "$TEST_ROOT/compose.json" >/dev/null
    "$DUCTOR_COMPOSE_TEST_BIN" --env-file "$DUCTOR_STATE_DIR/services/settings.env" \
        --env-file "$DUCTOR_STATE_DIR/services/secrets.env" -f "$DUCTOR_STATE_DIR/services/compose.yaml" \
        --profile ssh-credentials config --quiet
    "$DUCTOR_COMPOSE_TEST_BIN" -f "$DUCTOR_STATE_DIR/services/memory/project-one/compose.yaml" config --quiet
fi
printf 'Service configuration, scope isolation, idempotence, and failure tests passed.\n'
