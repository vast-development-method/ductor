#!/usr/bin/env bash
# Contract tests against a stateful, secret-aware curl fixture. No network calls.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FRAGMENT=${DUCTOR_PAPERCLIP_SOURCE:-$ROOT/src/ductor}
[[ -f $FRAGMENT ]] || FRAGMENT=$ROOT/src/ductor
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export DUCTOR_STATE_DIR="$TEST_DIR/state"
mkdir -p "$DUCTOR_STATE_DIR" "$TEST_DIR/api"
company=11111111-1111-4111-8111-111111111111
environment=22222222-2222-4222-8222-222222222222
project=33333333-3333-4333-8333-333333333333
agent=44444444-4444-4444-8444-444444444444
connection=55555555-5555-4555-8555-555555555555
grant=66666666-6666-4666-8666-666666666666
fixture_project=$project
fixture_agent=$agent
for collection in environments projects agents; do printf '[]\n' >"$TEST_DIR/api/$collection"; done
: >"$TEST_DIR/api/calls"
FAKE_AGENT_KEY=false
FAKE_BINDING_READY=true
FAKE_BINDING_ENV=$environment
FAKE_TRANSPORT_READY=true
FAKE_GRANT_STATUS=connected
ductor_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_require() { local name; for name in "$@"; do command -v "$name" >/dev/null || exit 1; done; }
# shellcheck source=/dev/null
source "$FRAGMENT"
ductor_bindings_require() {
    $FAKE_BINDING_READY || return 1
    jq -n --arg env "$FAKE_BINDING_ENV" '{runtime:{paperclipEnvironmentId:$env},memory:{isolation:"dedicated-instance"},isolation:{provider:"incus"}}'
}
ductor_services_paperclip_ssh_probe() {
    $FAKE_TRANSPORT_READY || return 1
    jq -e --arg env "$environment" '.id==$env and .config.host=="worker.example"' "$1" >/dev/null || return 1
    jq -e --arg env "$environment" '.runtime.paperclipEnvironmentId==$env' "$2" >/dev/null || return 1
    printf 'ssh-probe\n' >>"$TEST_DIR/api/calls"
}
curl() {
    local method=GET output='' body='' headers='' url='' arg code=200
    local -a arguments=("$@")
    for arg in "${arguments[@]}"; do
        [[ $arg != *test-secret-token* ]] || { printf 'Secret leaked in argv!\n' >&2; return 90; }
    done
    while (($#)); do
        case $1 in
            --request) method=$2; shift 2 ;;
            --output) output=$2; shift 2 ;;
            --data-binary) body=${2#@}; shift 2 ;;
            --header) headers=${2#@}; shift 2 ;;
            --proto|--connect-timeout|--max-time|--max-filesize|--write-out) shift 2 ;;
            -q|--silent|--show-error) shift ;;
            http://*|https://*) url=$1; shift ;;
            *) printf 'Unexpected curl option %s\n' "$1" >&2; return 91 ;;
        esac
    done
    [[ -n $output && -f $headers ]] || return 92
    [[ $(stat -c %a "$headers") == 600 ]] || return 93
    [[ $(<"$headers") == *'Authorization: Bearer test-secret-token'* ]] || return 94
    url=${url#https://paperclip.example}
    printf '%s %s\n' "$method" "$url" >>"$TEST_DIR/api/calls"
    case "$method $url" in
        'GET /api/cli-auth/me')
            if $FAKE_AGENT_KEY; then printf '{}\n' >"$output"; code=403
            else jq -n --arg company "$company" '{userId:"operator",isInstanceAdmin:true,companyIds:[$company]}' >"$output"; fi
            ;;
        "GET /api/companies/$company/ai-connections"*)
            jq -n --arg id "$connection" --arg grant "$grant" --arg status "$FAKE_GRANT_STATUS" '{connections:[{id:$id,grantId:$grant,provider:"openai",method:"subscription",ownership:"shared",status:$status}]}' >"$output"
            ;;
        "GET /api/companies/$company/environments") cp "$TEST_DIR/api/environments" "$output" ;;
        "GET /api/companies/$company/projects") cp "$TEST_DIR/api/projects" "$output" ;;
        "GET /api/companies/$company/agents") cp "$TEST_DIR/api/agents" "$output" ;;
        "GET /api/environments/$environment") jq '.[0]' "$TEST_DIR/api/environments" >"$output" ;;
        "GET /api/agents/$fixture_agent") jq '.[0]' "$TEST_DIR/api/agents" >"$output" ;;
        "GET /api/projects/$fixture_project") jq '.[0]' "$TEST_DIR/api/projects" >"$output" ;;
        "POST /api/agents/$fixture_agent/resume") jq '.[0] + {status:"idle"}' "$TEST_DIR/api/agents" >"$output" ;;
        "POST /api/companies/$company/environments")
            jq --arg id "$environment" '. + {id:$id}' "$body" >"$output"
            jq -s '.[0] + [.[1]]' "$TEST_DIR/api/environments" "$output" >"$TEST_DIR/api/new"
            mv "$TEST_DIR/api/new" "$TEST_DIR/api/environments"
            ;;
        "POST /api/companies/$company/projects")
            jq --arg id "$project" '. + {id:$id}' "$body" >"$output"
            jq -s '.[0] + [.[1]]' "$TEST_DIR/api/projects" "$output" >"$TEST_DIR/api/new"
            mv "$TEST_DIR/api/new" "$TEST_DIR/api/projects"
            ;;
        "POST /api/companies/$company/agents")
            jq --arg id "$agent" '. + {id:$id,status:"idle"}' "$body" >"$output"
            jq -s '.[0] + [.[1]]' "$TEST_DIR/api/agents" "$output" >"$TEST_DIR/api/new"
            mv "$TEST_DIR/api/new" "$TEST_DIR/api/agents"
            ;;
        "POST /api/companies/$company/issues") jq '. + {id:"77777777-7777-4777-8777-777777777777",identifier:"TEST-1"}' "$body" >"$output" ;;
        *) printf 'Unexpected API request: %s %s\n' "$method" "$url" >&2; return 95 ;;
    esac
    printf '%s' "$code"
}
expect_failure() { if ("$@") >"$TEST_DIR/failure.log" 2>&1; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }

expect_failure ductor_pc_url http://192.168.1.3:3100
expect_failure ductor_pc_url https://operator@paperclip.example
expect_failure ductor_pc_url https://paperclip.example/path
printf '%s\n' test-secret-token | ductor_paperclip configure --url https://paperclip.example --company "$company" --token-stdin >"$TEST_DIR/config.log" 2>&1
[[ $(stat -c %a "$DUCTOR_STATE_DIR/paperclip/connection.json") == 600 ]]
[[ $(stat -c %a "$DUCTOR_STATE_DIR/paperclip") == 700 ]]
! rg -q test-secret-token "$TEST_DIR/config.log"
FAKE_AGENT_KEY=true
expect_failure ductor_paperclip status
FAKE_AGENT_KEY=false
printf '%s\n' 'worker.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexampleVerifiedFixtureKey' >"$TEST_DIR/known_hosts"
env_args=(--name worker --host worker.example --user opencode --cwd /workspace/project --known-hosts "$TEST_DIR/known_hosts")
ductor_paperclip environment "${env_args[@]}" >"$TEST_DIR/environment-result"
ductor_paperclip environment "${env_args[@]}" >"$TEST_DIR/environment-repeat"
[[ $(jq length "$TEST_DIR/api/environments") == 1 ]]
jq -e '.[0].config.privateKeySecretRef==null and .[0].config.strictHostKeyChecking==true' "$TEST_DIR/api/environments" >/dev/null
register_args=(--name Project --repo https://github.com/example/project --cwd /workspace/project --model gpt-5.4 --environment "$environment" --binding project-worker --connection "$connection" --grant "$grant")
FAKE_BINDING_READY=false
expect_failure ductor_paperclip register "${register_args[@]}"
[[ $(jq length "$TEST_DIR/api/projects") == 0 ]]
FAKE_BINDING_READY=true
FAKE_BINDING_ENV=$project
expect_failure ductor_paperclip register "${register_args[@]}"
[[ $(jq length "$TEST_DIR/api/projects") == 0 ]]
FAKE_BINDING_ENV=$environment
FAKE_TRANSPORT_READY=false
expect_failure ductor_paperclip register "${register_args[@]}"
[[ $(jq length "$TEST_DIR/api/projects") == 0 ]]
FAKE_TRANSPORT_READY=true
cp "$TEST_DIR/api/environments" "$TEST_DIR/api/safe-environments"
for unsafe in '.config.privateKey="unexpected-key"' '.config.privateKeySecretRef={secretId:"unexpected"}' '.config.knownHosts=""' '.config.strictHostKeyChecking=false' '.metadata.managedBy="another-manager"'; do
    jq ".[0] |= ($unsafe)" "$TEST_DIR/api/safe-environments" >"$TEST_DIR/api/environments"
    expect_failure ductor_paperclip register "${register_args[@]}"
    [[ $(jq length "$TEST_DIR/api/projects") == 0 ]]
done
cp "$TEST_DIR/api/safe-environments" "$TEST_DIR/api/environments"
ductor_paperclip register "${register_args[@]}" >"$TEST_DIR/register-result"
ductor_paperclip register "${register_args[@]}" >"$TEST_DIR/register-repeat"
[[ $(jq length "$TEST_DIR/api/projects") == 1 && $(jq length "$TEST_DIR/api/agents") == 1 ]]
jq -e '.[0].adapterConfig.command=="/usr/local/bin/ductor-runtime" and .[0].adapterConfig.env.DUCTOR_BINDING_NAME=="project-worker" and .[0].runtimeConfig.heartbeat.maxConcurrentRuns==1 and .[0].runtimeConfig.aiConnection.method=="subscription" and .[0].adapterConfig.dangerouslyBypassApprovalsAndSandbox==false' "$TEST_DIR/api/agents" >/dev/null
expect_failure ductor_paperclip register "${register_args[@]}" --model changed-model
[[ $(jq length "$TEST_DIR/api/agents") == 1 ]]
FAKE_BINDING_READY=false
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Unavailable bindings' </dev/null
FAKE_BINDING_READY=true
FAKE_TRANSPORT_READY=false
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Transport failure' </dev/null
expect_failure ductor_paperclip resume "$agent"
FAKE_TRANSPORT_READY=true
FAKE_GRANT_STATUS=revoked
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Revoked grant' </dev/null
expect_failure ductor_paperclip resume "$agent"
FAKE_GRANT_STATUS=connected
if rg -q 'POST .*/issues|POST .*/resume' "$TEST_DIR/api/calls"; then printf 'Unsafe task/resume was dispatched.\n' >&2; exit 1; fi
printf '%s\n' 'Implement the fix; demonstrate tests and independent review.' | ductor_paperclip task --project "$project" --agent "$agent" --title 'Fix the bug' >"$TEST_DIR/task-result"
jq -e '.identifier=="TEST-1" and .status=="todo"' "$TEST_DIR/task-result" >/dev/null
ductor_paperclip status >"$TEST_DIR/status"
jq -e '.agents==1 and .byStatus[0].status=="idle"' "$TEST_DIR/status" >/dev/null
ductor_paperclip resume "$agent" >"$TEST_DIR/resume-result"
jq -e '.status=="idle"' "$TEST_DIR/resume-result" >/dev/null
# Native provider agents can queue their first task before a VM/binding exists.
# The acquisition hook, not task submission, creates that isolated runtime.
jq -n --arg connection "$connection" --arg grant "$grant" '{name:"native-worker",model:"gpt-5.4",runtime:{workspace:"/workspace/project"},connectionId:$connection,grantId:$grant}' >"$TEST_DIR/native-profile"
ductor_profile_file() { [[ $1 == native-worker ]] || return 1; printf '%s\n' "$TEST_DIR/native-profile"; }
FAKE_PROFILE_READY=true
ductor_profile_connection() { $FAKE_PROFILE_READY; }
FAKE_REGISTRY_READY=true
ductor_agent_registry_check() { $FAKE_REGISTRY_READY; }
jq --arg binding "agent-${agent//-/}" '.[0].metadata.ductorProfile="native-worker" | .[0].adapterConfig.env.DUCTOR_BINDING_NAME=$binding' "$TEST_DIR/api/agents" >"$TEST_DIR/api/native-agent"
cp "$TEST_DIR/api/native-agent" "$TEST_DIR/api/agents"
jq -n --arg env "$environment" '[{id:$env,metadata:{managedBy:"ductor"},driver:"sandbox",status:"active",config:{provider:"ductor-incus",profile:"native-worker"}}]' >"$TEST_DIR/api/environments"
FAKE_BINDING_READY=false
FAKE_TRANSPORT_READY=false
printf '%s\n' 'Provision the approved VM and perform a bounded first task.' | ductor_paperclip task --project "$project" --agent "$agent" --title 'Native first task' >"$TEST_DIR/native-task"
jq -e '.identifier=="TEST-1"' "$TEST_DIR/native-task" >/dev/null
FAKE_REGISTRY_READY=false
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Missing native registry' </dev/null
FAKE_REGISTRY_READY=true
FAKE_GRANT_STATUS=revoked
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Revoked native grant' </dev/null
FAKE_GRANT_STATUS=connected
cp "$TEST_DIR/api/projects" "$TEST_DIR/api/safe-projects"
jq '.[0].executionWorkspacePolicy.sharedWorkspaceConcurrency="allow"' "$TEST_DIR/api/safe-projects" >"$TEST_DIR/api/projects"
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Drifted native concurrency' </dev/null
cp "$TEST_DIR/api/safe-projects" "$TEST_DIR/api/projects"
FAKE_PROFILE_READY=false
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Unavailable native profile' </dev/null
FAKE_PROFILE_READY=true
jq '.[0].adapterConfig.model="unapproved-model"' "$TEST_DIR/api/native-agent" >"$TEST_DIR/api/agents"
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Drifted native model' </dev/null
cp "$TEST_DIR/api/native-agent" "$TEST_DIR/api/agents"
jq '.[0].config.provider="other-provider"' "$TEST_DIR/api/environments" >"$TEST_DIR/api/changed"
mv "$TEST_DIR/api/changed" "$TEST_DIR/api/environments"
expect_failure ductor_paperclip task --project "$project" --agent "$agent" --title 'Drifted native provider' </dev/null
printf 'Paperclip contract tests passed.\n'
