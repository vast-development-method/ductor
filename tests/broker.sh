#!/usr/bin/env bash
# Native Paperclip lease lifecycle and execution contract; no real Incus calls.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export DUCTOR_STATE_DIR="$TEST_DIR/state"
umask 077
mkdir -p "$DUCTOR_STATE_DIR/leases" "$DUCTOR_STATE_DIR/profiles" "$TEST_DIR/api"
# shellcheck source=/dev/null
source "${DUCTOR_BROKER_SOURCE:-$ROOT/src/ductor}"
if [[ $EUID != 0 ]]; then printf 'SKIP broker fixtures: broker enforces root; run tests in a root test container.\n'; exit 0; fi
ductor_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_private_dir() { mkdir -p -- "$1" && chmod 700 "$1"; }
ductor_pc_uuid() { [[ $1 =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || ductor_die 'Invalid UUID'; }
ductor_profile_file() { [[ $1 == worker || $1 == manager ]] || ductor_die 'Unknown profile'; printf '%s/profiles/%s.json\n' "$DUCTOR_STATE_DIR" "$1"; }
ductor_profile_validate() { jq -e . "$1" >/dev/null; }
ductor_profile_connection() { export DUCTOR_PC_COMPANY=11111111-1111-4111-8111-111111111111; }
ductor_pc_subscription_ready() { [[ $3 == 33333333-3333-4333-8333-333333333333 ]]; }
FAKE_REGISTRY_READY=true
ductor_agent_registry_check() { $FAKE_REGISTRY_READY; }
ductor_codex_prepare() { printf 'codex prepared\n' >>"$TEST_DIR/calls"; }
ductor_lock() { printf 'lock\n' >>"$TEST_DIR/locks"; }
ductor_plan() { printf '{}\n'; }
: >"$TEST_DIR/locks"; : >"$TEST_DIR/calls"
printf 'Stopped\n' >"$TEST_DIR/vm-state"
printf '{"nodes":[{"id":"node-one","remote":"local","project":"ductor","identity":"physical-one"}]}\n' >"$DUCTOR_STATE_DIR/inventory.json"
printf '{"placements":[]}\n' >"$DUCTOR_STATE_DIR/placements.json"
cat >"$DUCTOR_STATE_DIR/profiles/worker.json" <<'JSON'
{"name":"worker","companyId":"11111111-1111-4111-8111-111111111111","connectionId":"55555555-5555-4555-8555-555555555555","grantId":"66666666-6666-4666-8666-666666666666","model":"fixture-model","image":"local:fixture","maxInstances":3,"maxRunSeconds":3600,"resources":{"cpu":2,"memoryMiB":1024,"diskGiB":10},"runtime":{"uid":1000,"workspace":"/workspace","command":"/usr/local/bin/codex"},"children":{"maxConcurrent":0}}
JSON
jq '.name="manager" | .children.maxConcurrent=1' "$DUCTOR_STATE_DIR/profiles/worker.json" >"$DUCTOR_STATE_DIR/profiles/manager.json"
cat >"$TEST_DIR/api/agent" <<'JSON'
{"id":"33333333-3333-4333-8333-333333333333","status":"idle","reportsTo":null,"metadata":{"managedBy":"ductor","ductorProfile":"worker"},"defaultEnvironmentId":"22222222-2222-4222-8222-222222222222","adapterType":"codex_local","adapterConfig":{"command":"/usr/local/bin/ductor-runtime","cwd":"/workspace","model":"fixture-model","dangerouslyBypassApprovalsAndSandbox":false,"env":{"DUCTOR_BINDING_NAME":"agent-33333333333343338333333333333333"}},"runtimeConfig":{"heartbeat":{"maxConcurrentRuns":1},"aiConnection":{"provider":"openai","method":"subscription","mode":"shared","connectionId":"55555555-5555-4555-8555-555555555555","grantId":"66666666-6666-4666-8666-666666666666"}},"permissions":{"canCreateAgents":false}}
JSON
jq -n '{metadata:{managedBy:"ductor",ductorProfile:"manager"},status:"idle"}' >"$TEST_DIR/api/parent"
printf '[]\n' >"$TEST_DIR/api/agents"
ductor_pc_request() {
    case "$1 $2" in
        'GET /api/environments/22222222-2222-4222-8222-222222222222') printf '{"metadata":{"managedBy":"ductor"},"driver":"sandbox","status":"active","config":{"provider":"ductor-incus","profile":"worker"}}\n' ;;
        'GET /api/agents/33333333-3333-4333-8333-333333333333') cat "$TEST_DIR/api/agent" ;;
        'GET /api/agents/77777777-7777-4777-8777-777777777777') cat "$TEST_DIR/api/parent" ;;
        'GET /api/companies/11111111-1111-4111-8111-111111111111/agents') cat "$TEST_DIR/api/agents" ;;
        *) printf 'Unexpected Paperclip request: %s\n' "$*" >&2; return 90 ;;
    esac
}
ductor_incus_query() {
    case $2 in
        /1.0/resources) printf '{"system":{"uuid":"physical-one"}}\n' ;;
        /1.0/instances/*) jq -n --arg status "$(cat "$TEST_DIR/vm-state")" '{status:$status}' ;;
        *) return 91 ;;
    esac
}
ductor_vm_owned() { return 0; }
ductor_vm() {
    printf 'vm %s\n' "$*" >>"$TEST_DIR/calls"
    case $1 in
        create) jq -n --arg name "$2" '{placements:[{name:$name,node:"node-one"}]}' >"$DUCTOR_STATE_DIR/placements.json" ;;
        start) printf 'Running\n' >"$TEST_DIR/vm-state" ;;
        *) return 92 ;;
    esac
}
FAIL_BIND=false
FAIL_STOP=false
ductor_broker_bind() {
    $FAIL_BIND && return 93
    jq '.bindingName="fixture-binding"' "$3" | ductor_broker_write "$3"
}
timeout() {
    while [[ $1 == --* ]]; do shift; done
    shift
    "$@"
}
incus() {
    printf 'incus %s\n' "$1" >>"$TEST_DIR/calls"
    if [[ $1 == stop ]]; then
        $FAIL_STOP && return 94
        printf 'Stopped\n' >"$TEST_DIR/vm-state"; return 0
    fi
    if [[ $1 == file && $2 == push ]]; then
        if [[ $3 == */execute.json ]]; then cp "$3" "$TEST_DIR/execute-request"; fi
        return 0
    fi
    [[ $1 == exec ]] || return 95
    local invocation="$*"
    while [[ $1 != -- ]]; do shift; done
    shift
    case "$*" in
        'id -g 1000') printf '1000\n' ;;
        '/usr/local/bin/ductor broker-execute '* )
            [[ $invocation == *'--user 1000 --group 1000 --cwd /tmp --'* ]] || return 96
            printf '%s\n' '{"exitCode":0,"signal":null,"timedOut":false,"stdout":"exact output\n","stderr":""}' ;;
        true|'systemctl '*|'install '*|'rm '*) return 0 ;;
        *) printf 'Unexpected guest command: %s\n' "$*" >&2; return 97 ;;
    esac
}
expect_failure() { if ("$@") >"$TEST_DIR/failure.log" 2>&1; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }
cat >"$TEST_DIR/acquire" <<'JSON'
{"protocol":1,"operation":"acquire","params":{"driverKey":"ductor-incus","companyId":"11111111-1111-4111-8111-111111111111","environmentId":"22222222-2222-4222-8222-222222222222","agentId":"33333333-3333-4333-8333-333333333333","runId":"44444444-4444-4444-8444-444444444444","config":{"profile":"worker"}}}
JSON
FAKE_REGISTRY_READY=false
expect_failure ductor_broker <"$TEST_DIR/acquire"
[[ ! -s $TEST_DIR/calls ]]
: >"$TEST_DIR/locks"
FAKE_REGISTRY_READY=true
ductor_broker <"$TEST_DIR/acquire" >"$TEST_DIR/lease-reply"
lease_id=$(jq -er .providerLeaseId "$TEST_DIR/lease-reply")
lease_file=$DUCTOR_STATE_DIR/leases/$lease_id.json
jq -e '.state=="running" and .uid==1000 and .gid==1000 and (.expiresAt|type=="string")' "$lease_file" >/dev/null
[[ $(cat "$TEST_DIR/vm-state") == Running ]]
[[ $(wc -l <"$TEST_DIR/locks") == 1 ]]
# Repeated same-run acquisition is idempotent; a second concurrent run is denied.
ductor_broker <"$TEST_DIR/acquire" >"$TEST_DIR/repeat"
[[ $(rg -c '^vm create ' "$TEST_DIR/calls") == 1 ]]
jq '.params.runId="99999999-9999-4999-8999-999999999999"' "$TEST_DIR/acquire" >"$TEST_DIR/second-run"
expect_failure ductor_broker <"$TEST_DIR/second-run"
# Native realize and execute put the lease object under params.lease.
jq --arg id "$lease_id" '.operation="realize" | .params.lease={providerLeaseId:$id} | .params.workspace={remotePath:"/workspace"}' "$TEST_DIR/acquire" >"$TEST_DIR/realize"
locks_before=$(wc -l <"$TEST_DIR/locks")
ductor_broker <"$TEST_DIR/realize" | jq -e '.cwd=="/workspace"' >/dev/null
jq '.operation="execute" | .params.command="/bin/printf" | .params.args=["%s","literal; $(never) `never`"] | .params.stdin="first\nlast\n" | .params.env={EXAMPLE:"literal\nvalue"} | .params.timeoutMs=86400000' "$TEST_DIR/realize" >"$TEST_DIR/execute"
ductor_broker <"$TEST_DIR/execute" >"$TEST_DIR/result"
jq -e '.stdout=="exact output\n" and .exitCode==0' "$TEST_DIR/result" >/dev/null
jq -e '.stdin=="first\nlast\n" and .args[1]=="literal; $(never) `never`" and .env.EXAMPLE=="literal\nvalue" and .timeoutMs<=3600000' "$TEST_DIR/execute-request" >/dev/null
[[ $(wc -l <"$TEST_DIR/locks") == "$locks_before" ]]
jq '.params.companyId="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"' "$TEST_DIR/execute" >"$TEST_DIR/cross-company"
expect_failure ductor_broker <"$TEST_DIR/cross-company"
# Stop receipt is emitted only after a confirmed stop; a failed stop stays live.
jq --arg id "$lease_id" '.operation="release" | .params.providerLeaseId=$id | .params.resourceDisposition="stop_and_retain" | .params.cancelActiveWork=true' "$TEST_DIR/acquire" >"$TEST_DIR/release"
FAIL_STOP=true
expect_failure ductor_broker <"$TEST_DIR/release"
[[ $(jq -r .state "$lease_file") == running ]]
FAIL_STOP=false
ductor_broker <"$TEST_DIR/release" | jq -e '.state=="stopped"' >/dev/null
[[ -f $lease_file && $(cat "$TEST_DIR/vm-state") == Stopped ]]
# If post-start binding fails, force-stop and retain the same allocation.
FAIL_BIND=true
expect_failure ductor_broker <"$TEST_DIR/acquire"
[[ $(cat "$TEST_DIR/vm-state") == Stopped && $(jq -r .state "$lease_file") == stopped ]]
FAIL_BIND=false
# A provisioning deadline also reaches the independent controller reaper.
jq '.state="provisioning" | .expiresAt="2000-01-01T00:00:00Z"' "$lease_file" | ductor_broker_write "$lease_file"
printf 'Running\n' >"$TEST_DIR/vm-state"
ductor_broker reap
[[ $(cat "$TEST_DIR/vm-state") == Stopped ]]
# The manager's concurrent child cap is checked before starting another child.
jq '.reportsTo="77777777-7777-4777-8777-777777777777"' "$TEST_DIR/api/agent" >"$TEST_DIR/api/child"
jq -n '[{id:"other-child",reportsTo:"77777777-7777-4777-8777-777777777777"}]' >"$TEST_DIR/api/agents"
jq '.agentId="other-child" | .parentAgentId="77777777-7777-4777-8777-777777777777" | .state="running"' "$lease_file" >"$DUCTOR_STATE_DIR/leases/d-aaaaaaaaaaaaaaaaaaaaaaaa.json"
mkdir "$TEST_DIR/check"
expect_failure ductor_broker_concurrency "$TEST_DIR/api/child" "$TEST_DIR/check"
printf 'Broker lifecycle tests passed.\n'
