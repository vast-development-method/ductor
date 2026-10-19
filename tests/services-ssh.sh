#!/usr/bin/env bash
# Credential lifecycle and dispatch gates using deterministic service fixtures.
# Run as root in CI for provisioning UID ownership checks; no daemon is used.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FRAGMENT=${DUCTOR_SERVICES_SOURCE:-$ROOT/src/ductor}
if [[ ! -f $FRAGMENT ]]; then FRAGMENT=$ROOT/src/ductor; fi
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export DUCTOR_STATE_DIR="$TEST_ROOT/state"
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_die() { printf '%s\n' "$*" >&2; exit 1; }
ductor_require_cmd() { command -v "$1" >/dev/null || ductor_die "Missing test dependency: $1"; }
# shellcheck source=/dev/null
source "$FRAGMENT"
ductor_services_prepare
mkdir -p "$TEST_ROOT/fake-bao"
FAKE_BAO=$TEST_ROOT/fake-bao
BAD_NETWORK=false
FAKE_EXEC_FAILURE=false
# Docker discovery fixture verifies that untrusted network labels cannot add
# a CIDR to the gateway's SSRF allowlist.
docker() {
    [[ $* == 'network inspect --format {{json .}} ductor_memory' ]] || return 1
    if [[ $BAD_NETWORK == true ]]; then
        printf '%s\n' '{"Labels":{"com.docker.compose.project":"unrelated","com.docker.compose.network":"memory"},"IPAM":{"Config":[{"Subnet":"10.8.0.0/24"}]}}'
    else
        printf '%s\n' '{"Labels":{"com.docker.compose.project":"ductor","com.docker.compose.network":"memory"},"IPAM":{"Config":[{"Subnet":"172.29.42.0/24"}]}}'
    fi
}
ductor_services_compose() {
    case $1 in
        up)
            [[ $* == *'--no-deps'* ]] || { printf 'Unexpected restart of dependencies\n' >&2; return 1; }
            printf '%s\n' "$*" >> "$TEST_ROOT/compose-calls"
            ;;
        exec)
            [[ $* == *'--user 1000:1000 paperclip'* ]] || return 1
            cat > "$TEST_ROOT/container-script"
            [[ $FAKE_EXEC_FAILURE == false ]] || return 73
            printf '%s\n' "$*" > "$TEST_ROOT/exec-arguments"
            ;;
        *) return 1 ;;
    esac
}
ductor_services_memory_allow_network
[[ $(ductor_services_value MEMPALACE_NETWORK_CIDRS "$DUCTOR_STATE_DIR/services/settings.env") == '["172.29.42.0/24"]' ]]
first=$(sha256sum "$DUCTOR_STATE_DIR/services/settings.env")
if (BAD_NETWORK=true ductor_services_memory_allow_network >/dev/null 2>&1); then exit 1; fi
[[ $first == "$(sha256sum "$DUCTOR_STATE_DIR/services/settings.env")" ]]

ductor_services_bao_request() {
    local method=$1 path=$2 payload=$4 output=$5
    case "$method $path" in
        'GET /v1/sys/seal-status') printf '%s\n' '{"initialized":true,"sealed":false}' > "$output" ;;
        'GET /v1/auth/token/lookup-self') printf '%s\n' '{"data":{"policies":["admin"]}}' > "$output" ;;
        'GET /v1/sys/mounts') printf '%s\n' '{}' > "$output" ;;
        'POST /v1/sys/mounts/ductor') jq -e '.type=="kv" and .options.version=="2"' "$payload" >/dev/null; printf '{}' > "$output" ;;
        'GET /v1/ductor/data/transport/paperclip-ssh')
            [[ -f $FAKE_BAO/key.json ]] || return 4
            jq '{data:{data:.data}}' "$FAKE_BAO/key.json" > "$output"
            ;;
        'POST /v1/ductor/data/transport/paperclip-ssh')
            [[ ! -e $FAKE_BAO/key.json ]] || return 1
            jq -e '.options.cas==0 and .data.managed_by=="ductor" and (.data.private_key|startswith("-----BEGIN OPENSSH PRIVATE KEY-----"))' "$payload" >/dev/null
            cp "$payload" "$FAKE_BAO/key.json"
            printf '{}' > "$output"
            ;;
        'PUT /v1/sys/policies/acl/ductor-paperclip-ssh')
            jq -er .policy "$payload" > "$FAKE_BAO/policy.hcl"
            printf '{}' > "$output"
            ;;
        'GET /v1/sys/auth') printf '%s\n' '{}' > "$output" ;;
        'POST /v1/sys/auth/ductor-approle') printf '{}' > "$output" ;;
        'POST /v1/auth/ductor-approle/role/ductor-paperclip-ssh')
            jq -e '.token_policies==["ductor-paperclip-ssh"] and .token_no_default_policy==true and .bind_secret_id==true and .secret_id_ttl=="720h"' "$payload" >/dev/null
            printf '{}' > "$output"
            ;;
        'GET /v1/auth/ductor-approle/role/ductor-paperclip-ssh/role-id') printf '%s\n' '{"data":{"role_id":"fixture-role-id"}}' > "$output" ;;
        'POST /v1/auth/ductor-approle/role/ductor-paperclip-ssh/secret-id') printf '%s\n' '{"data":{"secret_id":"fixture-secret-id"}}' > "$output" ;;
        *) printf 'Unexpected mock API path: %s %s\n' "$method" "$path" >&2; return 1 ;;
    esac
}
if [[ $EUID == 0 ]]; then
    # This sandbox may map only UID 0. Record requested ownership while retaining
    # real installation and mode checks; Docker integration verifies UID mapping.
    install() {
        local owner='' group='' destination=${!#}
        local -a arguments=()
        while (($#)); do
            case $1 in
                -o) owner=$2; shift 2 ;;
                -g) group=$2; shift 2 ;;
                *) arguments+=("$1"); shift ;;
            esac
        done
        if [[ -n $owner ]]; then printf '%s:%s %s\n' "$owner" "$group" "$destination" >> "$TEST_ROOT/ownership"; fi
        command install "${arguments[@]}"
    }
    ductor_services_ssh_credentials "$TEST_ROOT/unused-admin-token"
    first=$(sha256sum "$FAKE_BAO/key.json")
    ductor_services_ssh_credentials "$TEST_ROOT/unused-admin-token"
    [[ $first == "$(sha256sum "$FAKE_BAO/key.json")" ]]
    [[ $(stat -c '%a' "$DUCTOR_STATE_DIR/services/ssh-agent/secret-id") == 600 ]]
    [[ $(stat -c '%a' "$DUCTOR_STATE_DIR/services/ssh-agent/role-id") == 600 ]]
    grep -q '^1000:1000 .*ssh-agent/secret-id$' "$TEST_ROOT/ownership"
    grep -q '^1000:1000 .*ssh-agent/role-id$' "$TEST_ROOT/ownership"
    [[ $(awk '/^path / {n++} END {print n}' "$FAKE_BAO/policy.hcl") == 3 ]]
    ! grep -q '\*' "$FAKE_BAO/policy.hcl"
    [[ ! -e $DUCTOR_STATE_DIR/services/ssh-agent/id_ed25519 ]]
else
    printf 'Skipping root-only AppRole file ownership provisioning test.\n'
    mkdir -p "$DUCTOR_STATE_DIR/services/ssh-agent"
    printf '%s\n' 'ssh-ed25519 AAAATEST public-fixture' > "$DUCTOR_STATE_DIR/services/ssh-agent/id_ed25519.pub"
fi
cat > "$TEST_ROOT/environment.json" <<'JSON'
{"driver":"ssh","config":{"host":"worker.internal","username":"agent","port":22,"strictHostKeyChecking":true,"knownHosts":"worker.internal ssh-ed25519 AAAATEST"}}
JSON
cat > "$TEST_ROOT/binding.json" <<'JSON'
{"name":"project-one","runtime":{"machineId":"0123456789abcdef0123456789abcdef","uid":1000},"openbao":{"roleIdFile":"/private/role-id","secretIdFile":"/private/secret-id"}}
JSON
ductor_services_paperclip_ssh_probe "$TEST_ROOT/environment.json" "$TEST_ROOT/binding.json"
# A container execution failure must stop dispatch without a host-SSH fallback.
if (FAKE_EXEC_FAILURE=true ductor_services_paperclip_ssh_probe "$TEST_ROOT/environment.json" "$TEST_ROOT/binding.json"); then exit 1; fi
jq '.config.strictHostKeyChecking=false' "$TEST_ROOT/environment.json" > "$TEST_ROOT/unsafe-environment.json"
if (ductor_services_paperclip_ssh_probe "$TEST_ROOT/unsafe-environment.json" "$TEST_ROOT/binding.json" >/dev/null 2>&1); then exit 1; fi
printf 'SSH credential retention, scoped policy, private-network admission, and dispatch failure gates passed.\n'
