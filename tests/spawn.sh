#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export DUCTOR_STATE_DIR=$TEST_DIR/state
mkdir -p "$DUCTOR_STATE_DIR/profiles" "$TEST_DIR/work"
# shellcheck source=/dev/null
source "${DUCTOR_SCRIPT:-$ROOT/../src/ductor}"
ductor_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_binding_id() { [[ $1 =~ ^[a-z][a-z0-9-]{0,47}$ ]]; }
ductor_pc_uuid() { [[ $1 =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; }
ductor_pc_private_file() { [[ -f $1 && ! -L $1 && $(stat -c %a "$1") == 600 ]] || ductor_die 'Private file required'; }
ductor_private_dir() { [[ ! -L $1 ]] && mkdir -p "$1" && chmod 700 "$1"; }
company=11111111-1111-4111-8111-111111111111
parent=22222222-2222-4222-8222-222222222222
issue=33333333-3333-4333-8333-333333333333
fixture_project=44444444-4444-4444-8444-444444444444
comment=55555555-5555-4555-8555-555555555555
event=66666666-6666-4666-8666-666666666666
fixture_environment=77777777-7777-4777-8777-777777777777
connection=88888888-8888-4888-8888-888888888888
FAIL_CREATE_RESPONSE=false
FAIL_PATCH_RESPONSE=false
jq -n --arg company "$company" --arg connection "$connection" '{schemaVersion:1,name:"worker",companyId:$company,repository:"https://github.com/company/repo",role:"engineer",model:"model-approved",connectionId:$connection,grantId:$connection,image:"local:approved",resources:{cpu:2,memoryMiB:4096,diskGiB:20},runtime:{uid:1000,command:"/usr/bin/codex",workspace:"/workspace"},memory:{scope:"",write:true},toolIds:[],maxInstances:10,maxRunSeconds:3600,children:{allowedTypes:[],maxTotal:0,maxConcurrent:0,maxDepth:0}}' > "$DUCTOR_STATE_DIR/profiles/worker.json"
jq '.name="manager" | .role="pm" | .children={allowedTypes:["worker"],maxTotal:10,maxConcurrent:2,maxDepth:2}' "$DUCTOR_STATE_DIR/profiles/worker.json" > "$DUCTOR_STATE_DIR/profiles/manager.json"
jq -n --arg company "$company" --arg parent "$parent" --arg project "$fixture_project" '[{id:$parent,companyId:$company,name:"Manager",status:"idle",reportsTo:null,metadata:{managedBy:"ductor",ductorProfile:"manager",projectId:$project,repository:"https://github.com/company/repo"}}]' > "$TEST_DIR/agents.json"
jq --arg env "$fixture_environment" --arg connection "$connection" 'map(. + {defaultEnvironmentId:$env,adapterType:"codex_local",adapterConfig:{model:"model-approved",command:"/usr/local/bin/ductor-runtime",cwd:"/workspace"},runtimeConfig:{aiConnection:{provider:"openai",method:"subscription",connectionId:$connection,grantId:$connection}}})' "$TEST_DIR/agents.json" > "$TEST_DIR/next.json"
mv "$TEST_DIR/next.json" "$TEST_DIR/agents.json"
jq '.[0]' "$TEST_DIR/agents.json" > "$TEST_DIR/parent.json"
ductor_agent_registry_record "$TEST_DIR/parent.json" "$DUCTOR_STATE_DIR/profiles/manager.json"
jq -n --arg issue "$issue" --arg company "$company" --arg project "$fixture_project" '{id:$issue,companyId:$company,projectId:$project}' > "$TEST_DIR/issue.json"
printf '[]\n' > "$TEST_DIR/comments.json"
: > "$TEST_DIR/calls"
ductor_pc_load() { export DUCTOR_PC_COMPANY=$company; }
ductor_profile_connection() { ductor_pc_load; [[ $(jq -r .companyId "$1") == "$company" ]]; }
ductor_provider_environment() { jq -n --arg id "$fixture_environment" '{id:$id}'; }
ductor_pc_request() {
    local method=$1 path=$2 payload=${3:-} child count
    printf '%s %s\n' "$method" "$path" >> "$TEST_DIR/calls"
    case "$method $path" in
        "GET /api/issues/$issue") cat "$TEST_DIR/issue.json" ;;
        "GET /api/agents/$parent") jq --arg id "$parent" '.[]|select(.id==$id)' "$TEST_DIR/agents.json" ;;
        "GET /api/issues/$issue/comments") cat "$TEST_DIR/comments.json" ;;
        "GET /api/companies/$company/agents") cat "$TEST_DIR/agents.json" ;;
        "GET /api/companies/$company/projects") jq -n --arg id "$fixture_project" '[{id:$id,description:"ductor:repository:https://github.com/company/repo"}]' ;;
        "POST /api/companies/$company/agents")
            count=$(jq 'length' "$TEST_DIR/agents.json")
            printf -v child 'aaaaaaaa-aaaa-4aaa-8aaa-%012d' "$count"
            jq --arg id "$child" --arg company "$company" '. + {id:$id,companyId:$company,status:"idle"}' "$payload" > "$TEST_DIR/created.json"
            jq -s '.[0]+[.[1]]' "$TEST_DIR/agents.json" "$TEST_DIR/created.json" > "$TEST_DIR/next.json"
            mv "$TEST_DIR/next.json" "$TEST_DIR/agents.json"
            [[ $FAIL_CREATE_RESPONSE == false ]] || return 1
            cat "$TEST_DIR/created.json" ;;
        PATCH\ /api/agents/*)
            child=${path##*/}
            jq --arg id "$child" --slurpfile update "$payload" 'map(if .id==$id then .+$update[0] else . end)' "$TEST_DIR/agents.json" > "$TEST_DIR/next.json"
            mv "$TEST_DIR/next.json" "$TEST_DIR/agents.json"
            [[ $FAIL_PATCH_RESPONSE == false ]] || return 1
            jq --arg id "$child" '.[]|select(.id==$id)' "$TEST_DIR/agents.json" ;;
        "POST /api/issues/$issue/comments")
            count=$(jq 'length' "$TEST_DIR/comments.json")
            printf -v child 'bbbbbbbb-bbbb-4bbb-8bbb-%012d' "$count"
            jq --arg id "$child" --arg company "$company" --arg issue "$issue" '.+{id:$id,companyId:$company,issueId:$issue,authorType:"user",authorAgentId:null,authorUserId:"operator",deletedAt:null}' "$payload" > "$TEST_DIR/notice.json"
            jq -s '.[0]+[.[1]]' "$TEST_DIR/comments.json" "$TEST_DIR/notice.json" > "$TEST_DIR/next.json"
            mv "$TEST_DIR/next.json" "$TEST_DIR/comments.json"
            cat "$TEST_DIR/notice.json" ;;
        *) printf 'Unexpected fixture API: %s %s\n' "$method" "$path" >&2; return 1 ;;
    esac
}
make_request() {
    local source_comment=$1 child_name=$2 profile=${3:-worker}
    jq -n --arg company "$company" --arg parent "$parent" --arg issue "$issue" --arg comment "$source_comment" --arg event "$event" --arg name "$child_name" --arg profile "$profile" '{protocol:1,operation:"spawn",params:{companyId:$company,agentId:$parent,eventId:$event,issueId:$issue,commentId:$comment,profile:$profile,name:$name}}' > "$TEST_DIR/request.json"
    jq -n --arg company "$company" --arg parent "$parent" --arg issue "$issue" --arg comment "$source_comment" --arg name "$child_name" --arg profile "$profile" '{id:$comment,companyId:$company,issueId:$issue,authorType:"agent",authorAgentId:$parent,authorUserId:null,deletedAt:null,body:("/ductor spawn "+({profile:$profile,name:$name}|tojson))}' > "$TEST_DIR/source.json"
    jq -s --arg comment "$source_comment" '(.[0]|map(select(.id!=$comment)))+[.[1]]' "$TEST_DIR/comments.json" "$TEST_DIR/source.json" > "$TEST_DIR/next.json"
    mv "$TEST_DIR/next.json" "$TEST_DIR/comments.json"
}
posts() { rg -c "^POST /api/companies/$company/agents$" "$TEST_DIR/calls"; }
make_request "$comment" 'Worker One'
ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" > "$TEST_DIR/result.json" || { cat "$TEST_DIR/work/spawn-error.log" >&2; exit 1; }
jq -e '.ok and .registered and (.runStarted|not)' "$TEST_DIR/result.json" >/dev/null
[[ $(posts) == 1 ]]
ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" > "$TEST_DIR/retry.json"
cmp "$TEST_DIR/result.json" "$TEST_DIR/retry.json"
[[ $(posts) == 1 ]]
[[ $(rg -c "^POST /api/issues/$issue/comments$" "$TEST_DIR/calls") == 1 ]]
jq '.params.eventId="99999999-9999-4999-8999-999999999999"' "$TEST_DIR/request.json" > "$TEST_DIR/new-event.json"
ductor_broker_spawn "$TEST_DIR/new-event.json" "$TEST_DIR/work" >/dev/null
jq -e '.events|length==2' "$DUCTOR_STATE_DIR/broker/spawns/$company-$comment.json" >/dev/null
[[ $(posts) == 1 ]]
# The event cannot impersonate a human comment or smuggle changed instructions.
jq --arg comment "$comment" 'map(if .id==$comment then .authorType="user" | .authorUserId="operator" else . end)' "$TEST_DIR/comments.json" > "$TEST_DIR/next.json"
mv "$TEST_DIR/next.json" "$TEST_DIR/comments.json"
if (ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Human comment spoof accepted'; exit 1; fi
make_request "$comment" 'Worker One'
jq '.params.name="Changed"' "$TEST_DIR/request.json" > "$TEST_DIR/changed.json"
if (ductor_broker_spawn "$TEST_DIR/changed.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Changed body request accepted'; exit 1; fi
jq '.projectId="99999999-9999-4999-8999-999999999999"' "$TEST_DIR/issue.json" > "$TEST_DIR/next.json"
mv "$TEST_DIR/next.json" "$TEST_DIR/issue.json"
if (ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Cross-project source accepted'; exit 1; fi
jq --arg id "$fixture_project" '.projectId=$id' "$TEST_DIR/issue.json" > "$TEST_DIR/next.json"; mv "$TEST_DIR/next.json" "$TEST_DIR/issue.json"
make_request "$comment" 'Changed After Completion'
if (ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Journal drift accepted'; exit 1; fi
[[ $(posts) == 1 ]]
# The actual API saved the agent, but the caller never received its POST response.
lost=cccccccc-cccc-4ccc-8ccc-cccccccccccc
make_request "$lost" 'Worker Two'
if (FAIL_CREATE_RESPONSE=true ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Lost POST response falsely succeeded'; exit 1; fi
[[ $(posts) == 2 ]]
jq -e '.status=="failed"' "$DUCTOR_STATE_DIR/broker/spawns/$company-$lost.json" >/dev/null
if (ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Indeterminate create was unsafely adopted'; exit 1; fi
[[ $(posts) == 2 ]]
jq -e 'any(.body|contains("indeterminate create outcome"))' "$TEST_DIR/comments.json" >/dev/null
# A known ID is persisted before PATCH, so a failed PATCH response can resume.
make_request eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee 'Worker Three'
if (FAIL_PATCH_RESPONSE=true ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Failed PATCH response falsely succeeded'; exit 1; fi
[[ $(posts) == 3 ]]
ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" > "$TEST_DIR/recovered.json"
[[ $(posts) == 3 ]]
jq -e '.ok and .agentId=="aaaaaaaa-aaaa-4aaa-8aaa-000000000003"' "$TEST_DIR/recovered.json" >/dev/null
test -f "$DUCTOR_STATE_DIR/agents/aaaaaaaa-aaaa-4aaa-8aaa-000000000003.json"
# A denied profile produces a safe issue blocker and cannot create a child.
make_request dddddddd-dddd-4ddd-8ddd-dddddddddddd 'Unauthorized manager' manager
if (ductor_broker_spawn "$TEST_DIR/request.json" "$TEST_DIR/work" >/dev/null 2>&1); then echo 'Unauthorized child type accepted'; exit 1; fi
[[ $(posts) == 3 ]]
jq -e 'any(.body|contains("is blocked"))' "$TEST_DIR/comments.json" >/dev/null
printf 'PASS: authenticated spawn comments, trusted registry, journal idempotence, indeterminate POST protection, known-ID retry recovery, and bounded parent policy.\n'
