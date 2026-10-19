#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "Bindings test failed at line %s\n" "$LINENO" >&2' ERR
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export DUCTOR_STATE_DIR=$TEST_DIR/state
mkdir -p "$DUCTOR_STATE_DIR/services"
# shellcheck source=/dev/null
source "${DUCTOR_SCRIPT:-$ROOT/../src/ductor}"
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_die() { ductor_log "$*"; exit 1; }
ductor_require_cmd() { :; }
ductor_services_value() { awk -v key="$1" 'index($0,key"=")==1 {sub(/^[^=]*=/,"");print;exit}' "$2"; }
cat > "$DUCTOR_STATE_DIR/services/settings.env" <<'SETTINGS'
CONTEXTFORGE_PORT=4444
OPENBAO_PORT=8200
PLATFORM_ADMIN_EMAIL=admin@company.test
SETTINGS
printf 'PLATFORM_ADMIN_PASSWORD=generated-admin-password\n' > "$DUCTOR_STATE_DIR/services/secrets.env"
printf 'test-admin-token\n' > "$TEST_DIR/bao-admin-token"
TEAM=aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa
SERVER=bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb
GATEWAY=cccccccc-cccc-4ccc-cccc-cccccccccccc
fixture_jwt() {
    local payload=$1 header body
    header=$(printf '{"alg":"HS256"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
    body=$(printf '%s' "$payload" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    printf '%s.%s.fixture-signature' "$header" "$body"
}
USER_JWT=$(fixture_jwt "{\"user\":{\"is_admin\":false},\"teams\":[\"$TEAM\"]}")
GATEWAY_JWT=$(fixture_jwt "{\"user\":{\"is_admin\":false},\"scopes\":{\"server_id\":\"$SERVER\",\"permissions\":[\"servers.use\",\"tools.read\",\"tools.execute\"]},\"exp\":4102444800}")
ductor_services_memory_scope() {
    mkdir -p "$DUCTOR_STATE_DIR/services/memory/$1"
    printf 'private-memory-token\n' > "$DUCTOR_STATE_DIR/services/memory/$1/token"
    jq -n --arg name "$1" --arg token "$DUCTOR_STATE_DIR/services/memory/$1/token" \
        '{name:$name,backendUrl:("http://ductor-memory-"+$name+":8765/mcp"),httpTokenFile:$token,palaceVolume:("ductor-memory-"+$name+"-data")}' > "$DUCTOR_STATE_DIR/services/memory/$1/scope.json"
}
cat > "$TEST_DIR/request.json" <<EOF
{"name":"project-implementer","projectKey":"project","agentKey":"implementer","memoryScope":"project","serviceEmail":"agent@company.test","gatewayOrigin":"http://127.0.0.1:4444","openbaoUrl":"http://127.0.0.1:8200","openbaoAdminTokenFile":"$TEST_DIR/bao-admin-token","runtime":{"command":"/usr/bin/codex","uid":1000,"machineId":"0123456789abcdef0123456789abcdef","paperclipEnvironmentId":"dddddddd-dddd-4ddd-dddd-dddddddddddd"},"isolation":{"provider":"incus","node":"worker-1","vm":"agent-1"},"memoryQuery":"Current project objectives","memoryWrite":true,"extraToolIds":[]}
EOF
printf '%s\n' '[{"id":"1","original_name":"mempalace_search","name":"project-search","enabled":true},{"id":"2","original_name":"mempalace_get_drawer","name":"project-get","enabled":true},{"id":"3","original_name":"mempalace_add_drawer","name":"project-add","enabled":true},{"id":"4","original_name":"mempalace_checkpoint","name":"project-checkpoint","enabled":true}]' > "$TEST_DIR/tools.json"
ductor_binding_http() {
    local method=$1 url=$2 token=$3 payload=$5 output=$6
    printf '%s %s\n' "$method" "$url" >> "$TEST_DIR/http-calls"
    case "$method $url" in
        'GET http://127.0.0.1:8200/v1/sys/seal-status') printf '{"initialized":true,"sealed":false}' > "$output" ;;
        'GET http://127.0.0.1:8200/v1/auth/token/lookup-self') printf '{"data":{"policies":["provisioner"]}}' > "$output" ;;
        'POST http://127.0.0.1:4444/auth/login')
            if [[ $(jq -r .email "$payload") == admin@company.test ]]; then
                printf '{"access_token":"admin-session","user":{"is_admin":true}}' > "$output"
            else
                jq -n --arg token "$USER_JWT" '{access_token:$token,user:{is_admin:false}}' > "$output"
            fi ;;
        'POST http://127.0.0.1:4444/auth/email/admin/users')
            jq -e '.is_admin == false' "$payload" >/dev/null
            printf '{}' > "$output" ;;
        'POST http://127.0.0.1:4444/gateways')
            [[ $token == */forge-user ]]
            jq -e '.visibility == "private" and .url == "http://ductor-memory-project:8765/mcp"' "$payload" >/dev/null
            jq -n --arg id "$GATEWAY" '{id:$id}' > "$output" ;;
        "GET http://127.0.0.1:4444/gateways/$GATEWAY")
            jq -n --arg team "$TEAM" '{url:"http://ductor-memory-project:8765/mcp",team_id:$team,owner_email:"agent@company.test",visibility:"private"}' > "$output" ;;
        "GET http://127.0.0.1:4444/tools?gateway_id=$GATEWAY&limit=0") cp "$TEST_DIR/tools.json" "$output" ;;
        'POST http://127.0.0.1:4444/servers')
            [[ $token == */forge-user ]]
            jq -e '.server.associated_tools == ["1","2","3","4"] and .visibility == "private"' "$payload" >/dev/null
            jq -n --arg id "$SERVER" '{id:$id}' > "$output" ;;
        'POST http://127.0.0.1:4444/tokens')
            jq -e --arg server "$SERVER" '.scope.server_id == $server and .scope.permissions == ["servers.use","tools.read","tools.execute"] and .user_email == "agent@company.test"' "$payload" >/dev/null
            jq -n --arg server "$SERVER" --arg team "$TEAM" --arg token "$GATEWAY_JWT" \
                '{token:{id:"token-one",server_id:$server,team_id:$team,user_email:"agent@company.test"},access_token:$token,warnings:[]}' > "$output" ;;
        'GET http://127.0.0.1:8200/v1/sys/mounts'|'GET http://127.0.0.1:8200/v1/sys/auth') printf '{}' > "$output" ;;
        'POST http://127.0.0.1:8200/v1/sys/mounts/ductor'|'POST http://127.0.0.1:8200/v1/sys/auth/ductor-approle') printf '{}' > "$output" ;;
        'POST http://127.0.0.1:8200/v1/ductor/data/bindings/project-implementer/gateway') cp "$payload" "$TEST_DIR/bao-kv.json"; printf '{}' > "$output" ;;
        'PUT http://127.0.0.1:8200/v1/sys/policies/acl/ductor-project-implementer')
            jq -er .policy "$payload" > "$TEST_DIR/policy.hcl"; printf '{}' > "$output" ;;
        'POST http://127.0.0.1:8200/v1/auth/ductor-approle/role/ductor-project-implementer')
            jq -e '.token_no_default_policy == true and .token_policies == ["ductor-project-implementer"]' "$payload" >/dev/null
            printf '{}' > "$output" ;;
        'GET http://127.0.0.1:8200/v1/auth/ductor-approle/role/ductor-project-implementer/role-id') printf '{"data":{"role_id":"role-one"}}' > "$output" ;;
        'POST http://127.0.0.1:8200/v1/auth/ductor-approle/role/ductor-project-implementer/secret-id') printf '{"data":{"secret_id":"secret-one"}}' > "$output" ;;
        'POST http://127.0.0.1:8200/v1/auth/ductor-approle/login')
            [[ ${FAIL_BAO:-false} == false ]] || return 1
            printf '{"auth":{"client_token":"scoped-bao-token","policies":["ductor-project-implementer"],"lease_duration":300}}' > "$output" ;;
        'GET http://127.0.0.1:8200/v1/ductor/data/bindings/project-implementer/gateway')
            jq '{data:.}' "$TEST_DIR/bao-kv.json" > "$output" ;;
        *) printf 'Unexpected fixture HTTP route: %s %s\n' "$method" "$url" >&2; return 1 ;;
    esac
}
# Exercise the real MCP handshake/list/pagination/recall logic with curl fixtures.
curl() {
    local payload='' output='' headers='' method
    while (($#)); do
        case $1 in
            --data-binary) payload=${2#@}; shift ;;
            --output) output=$2; shift ;;
            --dump-header) headers=$2; shift ;;
        esac
        shift
    done
    [[ -n $payload && -n $output ]]
    method=$(jq -r .method "$payload")
    if [[ -n $headers ]]; then printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: fixture-session\r\n\r\n' > "$headers"; fi
    case $method in
        initialize) printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}' > "$output" ;;
        notifications/initialized) : > "$output" ;;
        tools/list)
            jq --argjson extra "${EXTRA_TOOL:-false}" '{jsonrpc:"2.0",id:2,result:{tools:(map({name})+(if $extra then [{name:"unapproved-delete"}] else [] end))}}' "$TEST_DIR/tools.json" > "$output" ;;
        tools/call)
            jq -e '.params.name == "project-search" and .params.arguments.limit == 5' "$payload" >/dev/null
            if [[ ${FAIL_MEMORY:-false} == true ]]; then
                printf '{"jsonrpc":"2.0","id":3,"result":{"isError":true,"content":[]}}' > "$output"
            else
                printf 'event: message\ndata: {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Approved project decision with provenance"}]}}\n\n' > "$output"
            fi ;;
        *) return 1 ;;
    esac
}
if ! ductor_bindings_provision "$TEST_DIR/request.json" > "$TEST_DIR/output" 2> "$TEST_DIR/errors"; then
    cat "$TEST_DIR/errors" >&2
    exit 1
fi
test -s "$DUCTOR_STATE_DIR/bindings/project-implementer/contract.json"
test ! -e "$DUCTOR_STATE_DIR/bindings/project-implementer/service-password"
rg -q 'path "ductor/data/bindings/project-implementer/gateway"' "$TEST_DIR/policy.hcl"
test "$(rg -c '^path ' "$TEST_DIR/policy.hcl")" -eq 1
! rg -q 'admin-session|private-memory-token|scoped-bao-token|secret-one|fixture-signature' "$TEST_DIR/output" "$TEST_DIR/errors" "$DUCTOR_STATE_DIR/bindings/project-implementer/contract.json"
before=$(rg -c '^POST .*4444/(gateways|servers|tokens)$' "$TEST_DIR/http-calls")
# The production function is sourced above; later overrides isolate another fixture.
# shellcheck disable=SC2218
ductor_bindings_provision "$TEST_DIR/request.json" >/dev/null 2>&1
after=$(rg -c '^POST .*4444/(gateways|servers|tokens)$' "$TEST_DIR/http-calls")
[[ $before == "$after" ]]
jq '.memoryScope="different-scope"' "$TEST_DIR/request.json" > "$TEST_DIR/changed-request.json"
if (ductor_bindings_provision "$TEST_DIR/changed-request.json" >/dev/null 2>&1); then echo 'Changed binding request was accepted'; exit 1; fi
jq '.name="rng-failure"' "$TEST_DIR/request.json" > "$TEST_DIR/rng-request.json"
if (openssl() { return 1; }; ductor_bindings_provision "$TEST_DIR/rng-request.json" >/dev/null 2>&1); then echo 'Failed RNG was accepted'; exit 1; fi
test ! -e "$DUCTOR_STATE_DIR/bindings/rng-failure/service-password"
ductor_bindings_render project-implementer "$TEST_DIR/bundle" >/dev/null 2>&1
rg -q '^\[mcp_servers.ductor_gateway.identity\]$' "$TEST_DIR/bundle/requirements.toml"
rg -q '^model_provider = "openai"$' "$TEST_DIR/bundle/requirements.toml"
ductor_runtime_model_arguments gpt-approved exec -m gpt-approved --model=gpt-approved -mgpt-approved -c 'model="gpt-approved"'
for argument in '--model=other' '-mother' '--config=model="other"' '--config=model_provider="other"' '--config="model"="other"' '--oss' '--'; do
    if (ductor_runtime_model_arguments gpt-approved exec "$argument" >/dev/null 2>&1); then echo "Model policy override accepted: $argument"; exit 1; fi
done
if (ductor_runtime_model_arguments gpt-approved exec -c 'model ="other"' >/dev/null 2>&1); then echo 'Spaced model override accepted'; exit 1; fi
ductor_runtime_model_arguments '' exec -m legacy-choice
! rg -q 'fixture-signature|private-memory-token|admin-session' "$TEST_DIR/bundle/config.toml" "$TEST_DIR/bundle/contract.json"
if (EXTRA_TOOL=true ductor_bindings_check project-implementer >/dev/null 2>&1); then echo 'Unapproved tool was not rejected'; exit 1; fi
if (FAIL_MEMORY=true ductor_bindings_check project-implementer >/dev/null 2>&1); then echo 'Memory failure was not rejected'; exit 1; fi
if (FAIL_BAO=true ductor_bindings_check project-implementer >/dev/null 2>&1); then echo 'OpenBao failure was not rejected'; exit 1; fi
if (ductor_binding_url 'http://10.0.0.2:8200'); then echo 'Unencrypted remote URL accepted'; exit 1; fi
if (ductor_binding_url 'https://company.test/path?token=secret'); then echo 'Credential-bearing URL accepted'; exit 1; fi
printf '%s\n' '{"version":1,"controller_id":"controller-one","nodes":[{"id":"worker-1","remote":"node-remote","project":"ductor","identity":"host-identity"}]}' > "$DUCTOR_STATE_DIR/inventory.json"
printf '%s\n' '{"version":1,"placements":[{"name":"agent-1","node":"worker-1"}]}' > "$DUCTOR_STATE_DIR/placements.json"
ductor_inventory_id() { [[ $1 =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,62}$ ]]; }
ductor_node_verify() { printf '{"identity":"host-identity"}\n'; }
ductor_incus_query() {
    [[ $1 == node-remote && $2 == '/1.0/instances/agent-1?project=ductor' ]]
    printf '{"name":"agent-1","status":"Running","type":"virtual-machine","config":{"user.ductor.owner":"controller-one","user.ductor.node":"worker-1"}}\n'
}
ductor_vm_owned() {
    jq -e '.type == "virtual-machine" and .config["user.ductor.owner"] == "controller-one"' <<< "$1" >/dev/null
    [[ $2 == worker-1 && $3 == agent-1 ]]
}
timeout() { shift; "$@"; }
incus() {
    printf '%s\n' "$*" >> "$TEST_DIR/incus-calls"
    if [[ $1 == file && $2 == push ]]; then return 0; fi
    [[ $1 == exec && $2 == node-remote:agent-1 ]]
    while [[ $1 != -- ]]; do shift; done
    shift
    case "$*" in
        'cat /etc/machine-id') printf '%s\n' "${GUEST_MACHINE_ID:-0123456789abcdef0123456789abcdef}" ;;
        'id -u 1000') printf '1000\n' ;;
        'id -g 1000') printf '1000\n' ;;
        'test -x /usr/bin/codex') return 0 ;;
        'mktemp -d /run/ductor-install-project-implementer.XXXXXXXX') printf '/run/ductor-install-project-implementer.AbCd1234\n' ;;
        'test ! -L /usr/local/bin/ductor') return 0 ;;
        install*) return 0 ;;
        '/usr/local/bin/ductor bindings install-runtime /run/ductor-install-project-implementer.AbCd1234') return 0 ;;
        '/usr/local/bin/ductor-runtime --ductor-check') [[ ${FAIL_GUEST:-false} == false ]] ;;
        'rm -rf -- /run/ductor-install-project-implementer.AbCd1234') return 0 ;;
        *) printf 'Unexpected Incus fixture: %s\n' "$*" >&2; return 1 ;;
    esac
}
printf '#!/usr/bin/env bash\n# DUCTOR_SINGLE_FILE\n' > "$TEST_DIR/ductor"
export DUCTOR_SELF=$TEST_DIR/ductor
if (GUEST_MACHINE_ID=ffffffffffffffffffffffffffffffff # The production function is sourced above; later overrides isolate another fixture.
# shellcheck disable=SC2218
ductor_bindings_deploy project-implementer >/dev/null 2>&1); then echo 'Wrong VM identity accepted'; exit 1; fi
! rg -q '^file push ' "$TEST_DIR/incus-calls"
ductor_bindings_deploy project-implementer >/dev/null 2>&1
test -f "$DUCTOR_STATE_DIR/bindings/project-implementer/deployed.json"
rg -q -- '--user 1000 --group 1000 --cwd /tmp --env DUCTOR_BINDING_NAME=project-implementer -- /usr/local/bin/ductor-runtime --ductor-check' "$TEST_DIR/incus-calls"
rm "$DUCTOR_STATE_DIR/bindings/project-implementer/deployed.json"
if (FAIL_GUEST=true ductor_bindings_deploy project-implementer >/dev/null 2>&1); then echo 'Failed guest preflight accepted'; exit 1; fi
test ! -e "$DUCTOR_STATE_DIR/bindings/project-implementer/deployed.json"
chmod 0644 "$DUCTOR_STATE_DIR/bindings/project-implementer/secret-id"
if (ductor_bindings_check project-implementer >/dev/null 2>&1); then echo 'Publicly readable credential accepted'; exit 1; fi
cat > "$TEST_DIR/profile.json" <<'PROFILE'
{"name":"project","model":"gpt-approved","runtime":{"uid":1000,"command":"/usr/bin/codex","workspace":"/workspace/project"},"memory":{"scope":"project","write":true},"toolIds":[]}
PROFILE
printf '{"id":"dddddddd-dddd-4ddd-dddd-dddddddddddd"}\n' > "$TEST_DIR/agent.json"
printf '{"agentId":"dddddddd-dddd-4ddd-dddd-dddddddddddd","environmentId":"eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee","node":"worker-1","vm":"agent-1"}\n' > "$TEST_DIR/lease.json"
jq -n --arg path "$TEST_DIR/bao-admin-token" '{services:{gatewayOrigin:"http://127.0.0.1:4444",openbaoUrl:"http://127.0.0.1:8200"},credentials:{openbaoAdminTokenFile:$path},identity:{emailDomain:"company.com"}}' > "$DUCTOR_STATE_DIR/config.json"
ductor_bindings_provision() { cp "$1" "$TEST_DIR/broker-request.json"; }
ductor_bindings_deploy() { [[ $1 == agent-dddddddddddd4ddddddddddddddddddd ]]; }
actual=$(ductor_broker_bind "$TEST_DIR/profile.json" "$TEST_DIR/agent.json" "$TEST_DIR/lease.json")
[[ $actual == agent-dddddddddddd4ddddddddddddddddddd ]]
jq -e '.serviceEmail == "agent-dddddddddddd4ddddddddddddddddddd@company.com" and .memoryScope == "project" and .runtime.machineId == "0123456789abcdef0123456789abcdef" and .runtime.paperclipEnvironmentId == "eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee"' "$TEST_DIR/broker-request.json" >/dev/null
jq -e --arg name "$actual" '.bindingName == $name' "$TEST_DIR/lease.json" >/dev/null
jq -e '.runtime.model=="gpt-approved"' "$TEST_DIR/broker-request.json" >/dev/null
printf 'PASS: provisioning contracts, non-admin grants, one-path OpenBao policy, secret redaction, idempotence, exact tool allowlist, SSE recall, and fail-closed checks.\n'
