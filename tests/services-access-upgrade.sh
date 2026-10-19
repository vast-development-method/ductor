#!/usr/bin/env bash
# Exposure gates, TLS failure reporting, and upgrade recovery boundaries.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FRAGMENT=${DUCTOR_SERVICES_SOURCE:-$ROOT/src/ductor}
if [[ ! -f $FRAGMENT ]]; then FRAGMENT=$ROOT/src/ductor; fi
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export DUCTOR_STATE_DIR="$TEST_ROOT/state"
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_die() { printf '%s\n' "$*" >&2; exit 1; }
ductor_require_cmd() { local item; for item in "$@"; do command -v "$item" >/dev/null || ductor_die "Missing test dependency: $item"; done; }
# shellcheck source=/dev/null
source "$FRAGMENT"
ductor_services_prepare
original_secrets=$(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env")
[[ $(ductor_services_value PLATFORM_ADMIN_EMAIL "$DUCTOR_STATE_DIR/services/settings.env") == admin@ductor.example.com ]]
[[ ! -e $DUCTOR_STATE_DIR/services/Caddyfile ]]
CLAIMED=false
INITIALIZED=true
TLS_OK=true
PULL_OK=true
curl() {
    [[ $1 == -q ]] || return 1
    local url=${!#}
    [[ $url != https://* || $TLS_OK == true ]] || return 60
    case $url in
        */api/health)
            if [[ $CLAIMED == true ]]; then printf '%s\n' '{"status":"ok","deploymentMode":"authenticated","bootstrapStatus":"ready"}';
            else printf '%s\n' '{"status":"ok","deploymentMode":"authenticated","bootstrapStatus":"bootstrap_pending"}'; fi ;;
        */v1/sys/seal-status) printf '{"initialized":%s,"sealed":false}\n' "$INITIALIZED" ;;
        */health) printf '%s\n' '{"status":"healthy"}' ;;
        *) printf 'Unexpected fixture URL\n' >&2; return 1 ;;
    esac
}
docker() { printf '%s\n' "$*" >> "$TEST_ROOT/docker-calls"; }
ductor_services_compose() {
    printf '%s\n' "$*" >> "$TEST_ROOT/compose-calls"
    [[ $1 != pull || $PULL_OK == true ]] || return 74
}
access_arguments=(--paperclip-host work.example.com --gateway-host tools.example.com --bao-host keys.example.com --email admin@example.com)
first=$(sha256sum "$DUCTOR_STATE_DIR/services/settings.env")
if ductor_services_access "${access_arguments[@]}" >/dev/null 2>&1; then exit 1; fi
[[ ! -e $DUCTOR_STATE_DIR/services/Caddyfile && ! -e $TEST_ROOT/compose-calls ]]
[[ $first == "$(sha256sum "$DUCTOR_STATE_DIR/services/settings.env")" ]]
CLAIMED=true
if (INITIALIZED=false ductor_services_access "${access_arguments[@]}" >/dev/null 2>&1); then exit 1; fi
[[ ! -e $DUCTOR_STATE_DIR/services/Caddyfile && ! -e $TEST_ROOT/compose-calls ]]
if ductor_services_access_render 'good.example.com;evil' tools.example.com keys.example.com admin@example.com >/dev/null 2>&1; then exit 1; fi
if ductor_services_access_render work.example.com work.example.com keys.example.com admin@example.com >/dev/null 2>&1; then exit 1; fi
ductor_services_access "${access_arguments[@]}"
[[ $(ductor_services_value PAPERCLIP_PUBLIC_URL "$DUCTOR_STATE_DIR/services/settings.env") == https://work.example.com ]]
[[ $(ductor_services_value PAPERCLIP_TRUST_PROXY "$DUCTOR_STATE_DIR/services/settings.env") == 1 ]]
[[ $(ductor_services_value CONTEXTFORGE_SECURE_COOKIES "$DUCTOR_STATE_DIR/services/settings.env") == true ]]
[[ $(stat -c %a "$DUCTOR_STATE_DIR/services/settings.env") == 600 ]]
[[ $original_secrets == "$(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env")" ]]
# The access operation must not restart Bao and accidentally reseal it.
rg -q '^up -d --no-deps .* paperclip contextforge caddy$' "$TEST_ROOT/compose-calls"
! rg -q '^up .*openbao' "$TEST_ROOT/compose-calls"
if (TLS_OK=false ductor_services_access_check >/dev/null 2>&1); then exit 1; fi
if [[ -n ${DUCTOR_COMPOSE_TEST_BIN:-} ]]; then
    "$DUCTOR_COMPOSE_TEST_BIN" --env-file "$DUCTOR_STATE_DIR/services/settings.env" \
        --env-file "$DUCTOR_STATE_DIR/services/secrets.env" -f "$DUCTOR_STATE_DIR/services/compose.yaml" \
        --profile team-access --profile ssh-credentials config --quiet
fi
# Plan and failed pulls cannot mutate live config, even when the old bundle differs.
sed -i 's/paperclip:2026.1012.0/paperclip:2026.1001.0/' "$DUCTOR_STATE_DIR/services/compose.yaml"
first=$(sha256sum "$DUCTOR_STATE_DIR/services/compose.yaml")
ductor_services_upgrade plan > "$TEST_ROOT/plan-output"
[[ $first == "$(sha256sum "$DUCTOR_STATE_DIR/services/compose.yaml")" ]]
[[ ! -e $DUCTOR_STATE_DIR/service-config-backups ]]
if ductor_services_upgrade apply >/dev/null 2>&1; then exit 1; fi
if (PULL_OK=false ductor_services_upgrade apply --backup-confirmed >/dev/null 2>&1); then exit 1; fi
[[ $first == "$(sha256sum "$DUCTOR_STATE_DIR/services/compose.yaml")" ]]
[[ ! -e $DUCTOR_STATE_DIR/service-config-backups ]]
ductor_services_up() {
    ductor_services_prepare || return
    printf '%s\n' 'up' > "$TEST_ROOT/applied"
}
ductor_services_upgrade apply --backup-confirmed > "$TEST_ROOT/apply-output"
[[ -f $TEST_ROOT/applied ]]
[[ $original_secrets == "$(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env")" ]]
backup_compose=("$DUCTOR_STATE_DIR"/service-config-backups/*/services/compose.yaml)
[[ ${#backup_compose[@]} == 1 && -f ${backup_compose[0]} ]]
rg -q 'paperclip:2026.1001.0' "${backup_compose[0]}"
rg -q 'paperclip:2026.1012.0' "$DUCTOR_STATE_DIR/services/compose.yaml"
[[ $(stat -c %a "${backup_compose[0]%/services/compose.yaml}") == 700 ]]
printf 'Team exposure gates, TLS verification, and pinned upgrade recovery boundaries passed.\n'
