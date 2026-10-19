#!/usr/bin/env bash
# Credential imports preserve scope, file privacy, and KV compare-and-set writes.
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
printf '%s\n' '{"api_key":"fixture-never-print-this-key"}' > "$TEST_ROOT/credential.json"
chmod 0600 "$TEST_ROOT/credential.json"
VERSION=0
WRITE_OK=true
ductor_services_bao_request() {
    local method=$1 path=$2 payload=$4 output=$5
    case "$method $path" in
        'GET /v1/sys/mounts') printf '%s\n' '{"ductor/":{"type":"kv","options":{"version":"2"}}}' > "$output" ;;
        'GET /v1/ductor/data/credentials/mail/service')
            [[ $VERSION -gt 0 ]] || return 4
            jq -n --argjson version "$VERSION" '{data:{metadata:{version:$version}}}' > "$output"
            ;;
        'POST /v1/ductor/data/credentials/mail/service')
            jq -e --argjson version "$VERSION" '.options.cas==$version and .data.api_key=="fixture-never-print-this-key"' "$payload" >/dev/null || return
            [[ $WRITE_OK == true ]] || return 76
            cp "$payload" "$TEST_ROOT/last-write.json"
            printf '{}' > "$output"
            ;;
        *) printf 'Unexpected fixture API path\n' >&2; return 1 ;;
    esac
}
ductor_services_secret_import mail/service "$TEST_ROOT/credential.json" "$TEST_ROOT/admin-token" > "$TEST_ROOT/output" 2>&1
jq -e '.options.cas == 0' "$TEST_ROOT/last-write.json" >/dev/null
! rg -q 'fixture-never-print-this-key' "$TEST_ROOT/output"
VERSION=7
first=$(sha256sum "$TEST_ROOT/last-write.json")
if ductor_services_secret_import mail/service "$TEST_ROOT/credential.json" "$TEST_ROOT/admin-token" > /dev/null 2>&1; then exit 1; fi
[[ $first == "$(sha256sum "$TEST_ROOT/last-write.json")" ]]
ductor_services_secret_import mail/service "$TEST_ROOT/credential.json" "$TEST_ROOT/admin-token" --replace > "$TEST_ROOT/output" 2>&1
jq -e '.options.cas == 7' "$TEST_ROOT/last-write.json" >/dev/null
! rg -q 'fixture-never-print-this-key' "$TEST_ROOT/output"
if (WRITE_OK=false ductor_services_secret_import mail/service "$TEST_ROOT/credential.json" "$TEST_ROOT/admin-token" --replace >/dev/null 2>&1); then exit 1; fi
chmod 0644 "$TEST_ROOT/credential.json"
if ductor_services_secret_import mail/service "$TEST_ROOT/credential.json" "$TEST_ROOT/admin-token" --replace >/dev/null 2>&1; then exit 1; fi
if ductor_services_secret_import ../../escape "$TEST_ROOT/credential.json" "$TEST_ROOT/admin-token" --replace >/dev/null 2>&1; then exit 1; fi
printf 'Credential import file privacy, CAS updates, and failed writes passed.\n'
