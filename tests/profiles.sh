#!/usr/bin/env bash
# Profile policy and native Paperclip registration contracts; no host services.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT
export DUCTOR_STATE_DIR="$TEST_DIR/state"
mkdir -p "$DUCTOR_STATE_DIR/profiles" "$TEST_DIR/api"
umask 077
# shellcheck source=/dev/null
source "${DUCTOR_PROFILE_SOURCE:-$ROOT/src/ductor}"
ductor_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_binding_id() { [[ $1 =~ ^[a-z][a-z0-9-]{0,47}$ ]]; }
ductor_pc_uuid() { [[ $1 =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] || ductor_die 'Invalid UUID'; }
ductor_pc_private_file() { [[ -f $1 && ! -L $1 && $(stat -c %a "$1") == 600 ]] || ductor_die 'Expected private profile'; }
ductor_private_dir() { mkdir -p -- "$1" && chmod 700 "$1"; }
fixture_company=11111111-1111-4111-8111-111111111111
fixture_connection=22222222-2222-4222-8222-222222222222
fixture_grant=33333333-3333-4333-8333-333333333333
fixture_environment=44444444-4444-4444-8444-444444444444
fixture_project=55555555-5555-4555-8555-555555555555
fixture_agent=66666666-6666-4666-8666-666666666666
parent=77777777-7777-4777-8777-777777777777
grandparent=88888888-8888-4888-8888-888888888888
FAKE_GRANT_REASON=null
FAKE_MODELS='[{"id":"test-model-v1","label":"Fixture model"}]'
for collection in agents projects; do printf '[]\n' >"$TEST_DIR/api/$collection"; done
: >"$TEST_DIR/api/calls"
ductor_pc_load() { export DUCTOR_PC_COMPANY=$fixture_company; }
ductor_provider_environment() { jq -n --arg id "$fixture_environment" '{id:$id}'; }
ductor_pc_request() {
    local method=$1 path=$2 body=${3:-}
    printf '%s %s\n' "$method" "$path" >>"$TEST_DIR/api/calls"
    case "$method $path" in
        "GET /api/companies/$fixture_company/ai-connections")
            jq -n --arg id "$fixture_connection" --arg grant "$fixture_grant" --argjson reason "$FAKE_GRANT_REASON" '{connections:[{id:$id,grantId:$grant,provider:"openai",method:"subscription",ownership:"shared",status:"connected",unavailableReason:$reason}]}' ;;
        "GET /api/companies/$fixture_company/adapters/codex_local/models") printf '%s\n' "$FAKE_MODELS" ;;
        "GET /api/companies/$fixture_company/agents") cat "$TEST_DIR/api/agents" ;;
        "GET /api/companies/$fixture_company/projects") cat "$TEST_DIR/api/projects" ;;
        "POST /api/companies/$fixture_company/projects")
            cp "$body" "$TEST_DIR/api/project-request"
            jq --arg id "$fixture_project" '.+{id:$id}' "$body" >"$TEST_DIR/api/project"
            jq -s '.[0]+[.[1]]' "$TEST_DIR/api/projects" "$TEST_DIR/api/project" >"$TEST_DIR/api/new"
            mv "$TEST_DIR/api/new" "$TEST_DIR/api/projects"
            cat "$TEST_DIR/api/project" ;;
        "POST /api/companies/$fixture_company/agents")
            cp "$body" "$TEST_DIR/api/agent-request"
            jq --arg id "$fixture_agent" --arg company "$fixture_company" '.+{id:$id,companyId:$company,status:"idle"} | .adapterConfig.env={EXISTING_MANAGED_ENTRY:"preserve"}' "$body" >"$TEST_DIR/api/agent"
            jq -s '.[0]+[.[1]]' "$TEST_DIR/api/agents" "$TEST_DIR/api/agent" >"$TEST_DIR/api/new"
            mv "$TEST_DIR/api/new" "$TEST_DIR/api/agents"
            cat "$TEST_DIR/api/agent" ;;
        "PATCH /api/agents/$fixture_agent")
            cp "$body" "$TEST_DIR/api/agent-patch"
            jq -s '.[0]+.[1]' "$TEST_DIR/api/agent" "$body" ;;
        *) printf 'Unexpected API request: %s %s\n' "$method" "$path" >&2; return 90 ;;
    esac
}
expect_failure() { if ("$@") >"$TEST_DIR/failure.log" 2>&1; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }
ductor_profiles example | jq '.model="test-model-v1"' >"$TEST_DIR/profile"
ductor_profiles import "$TEST_DIR/profile" >/dev/null
ductor_profiles import "$TEST_DIR/profile" >/dev/null
[[ $(stat -c %a "$DUCTOR_STATE_DIR/profiles/repository-engineer.json") == 600 ]]
jq '.resources.cpu=3' "$TEST_DIR/profile" >"$TEST_DIR/changed"
expect_failure ductor_profiles import "$TEST_DIR/changed"
for mutation in '.runtime.uid=0' '.resources.memoryMiB=-1' '.children.maxConcurrent=1' '.companyId="not-a-uuid"' '.name="../../escape"' '.model="model;touch marker"'; do
    jq "$mutation" "$TEST_DIR/profile" >"$TEST_DIR/invalid"
    expect_failure ductor_profile_validate "$TEST_DIR/invalid"
done
mkdir "$TEST_DIR/check"
FAKE_MODELS='[{"id":"another-model"}]'
expect_failure ductor_profile_connection "$TEST_DIR/profile" "$TEST_DIR/check"
FAKE_MODELS='[{"id":"test-model-v1"}]'
FAKE_GRANT_REASON='"agent-not-permitted"'
expect_failure ductor_profile_connection "$TEST_DIR/profile" "$TEST_DIR/check"
FAKE_GRANT_REASON=null
ductor_profile_connection "$TEST_DIR/profile" "$TEST_DIR/check"
# A root has no parent restriction. A child's direct parent and every ancestor
# impose independent depth limits; a permissive child cannot reset its root cap.
jq '.name="manager" | .children={allowedTypes:["repository-engineer","manager"],maxTotal:3,maxConcurrent:2,maxDepth:1}' "$TEST_DIR/profile" >"$TEST_DIR/manager"
ductor_profiles import "$TEST_DIR/manager" >/dev/null
jq '.name="delegate" | .children={allowedTypes:["repository-engineer"],maxTotal:3,maxConcurrent:2,maxDepth:8}' "$TEST_DIR/profile" >"$TEST_DIR/delegate"
ductor_profiles import "$TEST_DIR/delegate" >/dev/null
fixture_register_graph() {
    local source=$1 row type fixture_profile
    rm -rf -- "$DUCTOR_STATE_DIR/agents"
    jq -c '.[]' "$source" > "$TEST_DIR/fixture-rows"
    printf '[]\n' > "$TEST_DIR/enriched"
    while IFS= read -r row; do
        type=$(jq -r '.metadata.ductorProfile // "repository-engineer"' <<< "$row")
        fixture_profile=$DUCTOR_STATE_DIR/profiles/$type.json
        jq --slurpfile p "$fixture_profile" --arg env "$fixture_environment" --arg project "$fixture_project" '
          . + {companyId:$p[0].companyId,defaultEnvironmentId:$env,adapterType:"codex_local",
          adapterConfig:{model:$p[0].model,command:"/usr/local/bin/ductor-runtime",cwd:$p[0].runtime.workspace},
          runtimeConfig:{aiConnection:{provider:"openai",method:"subscription",connectionId:$p[0].connectionId,grantId:$p[0].grantId}}} |
          .metadata=((.metadata // {})+{managedBy:"ductor",ductorProfile:$p[0].name,repository:$p[0].repository,projectId:$project})
        ' <<< "$row" > "$TEST_DIR/fixture-agent"
        ductor_agent_registry_record "$TEST_DIR/fixture-agent" "$fixture_profile"
        jq -s '.[0]+[.[1]]' "$TEST_DIR/enriched" "$TEST_DIR/fixture-agent" > "$TEST_DIR/fixture-next"
        mv "$TEST_DIR/fixture-next" "$TEST_DIR/enriched"
    done < "$TEST_DIR/fixture-rows"
    mv "$TEST_DIR/enriched" "$source"
}
jq -n --arg parent "$parent" '[{id:$parent,status:"idle",reportsTo:null,metadata:{managedBy:"ductor",ductorProfile:"manager"}}]' >"$TEST_DIR/parents"
fixture_register_graph "$TEST_DIR/parents"
ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/parents"
jq -n --arg parent "$parent" --arg root "$grandparent" '[{id:$parent,status:"idle",reportsTo:$root,metadata:{managedBy:"ductor",ductorProfile:"delegate"}},{id:$root,status:"idle",reportsTo:null,metadata:{managedBy:"ductor",ductorProfile:"manager"}}]' >"$TEST_DIR/parents"
fixture_register_graph "$TEST_DIR/parents"
expect_failure ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/parents"
jq '.[1].metadata.ductorProfile="delegate"' "$TEST_DIR/parents" >"$TEST_DIR/permissive-parents"
# Editing live profile metadata cannot upgrade the trusted role.
expect_failure ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/permissive-parents"
fixture_register_graph "$TEST_DIR/permissive-parents"
ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/permissive-parents"
jq --arg parent "$parent" '.[1].reportsTo=$parent' "$TEST_DIR/permissive-parents" >"$TEST_DIR/cycle"
expect_failure ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/cycle"
jq '.[0].status="terminated"' "$TEST_DIR/permissive-parents" >"$TEST_DIR/terminated"
expect_failure ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/terminated"
jq -n --arg parent "$parent" '[{id:$parent,status:"idle",reportsTo:null,metadata:{managedBy:"ductor",ductorProfile:"manager"}},{id:"aaaaaaaa-aaaa-4aaa-8aaa-000000000001",status:"idle",reportsTo:$parent},{id:"aaaaaaaa-aaaa-4aaa-8aaa-000000000002",status:"idle",reportsTo:$parent},{id:"aaaaaaaa-aaaa-4aaa-8aaa-000000000003",status:"paused",reportsTo:$parent}]' >"$TEST_DIR/full"
fixture_register_graph "$TEST_DIR/full"
expect_failure ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/full"
# A child cannot evade a root-pinned parent cap by editing its live reportsTo.
jq '.[1].reportsTo=null | .[1].metadata.ductorProfile="delegate"' "$TEST_DIR/full" > "$TEST_DIR/hidden-child"
expect_failure ductor_profile_parent_check "$TEST_DIR/profile" "$parent" "$TEST_DIR/hidden-child"
# Creation keeps the operator-approved exact model/account and native sandbox;
# Paperclip's returned managed environment entries must survive the binding patch.
ductor_agents_create --profile repository-engineer --name 'Fixture engineer' >"$TEST_DIR/result"
jq -e --arg env "$fixture_environment" --arg conn "$fixture_connection" --arg grant "$fixture_grant" '.defaultEnvironmentId==$env and .adapterType=="codex_local" and .adapterConfig.model=="test-model-v1" and .adapterConfig.command=="/usr/local/bin/ductor-runtime" and .permissions.canCreateAgents==false and .runtimeConfig.aiConnection.connectionId==$conn and .runtimeConfig.aiConnection.grantId==$grant' "$TEST_DIR/api/agent-request" >/dev/null
jq -e '.executionWorkspacePolicy.enabled==true and .executionWorkspacePolicy.defaultMode=="shared_workspace" and .executionWorkspacePolicy.sharedWorkspaceConcurrency=="serialize" and .executionWorkspacePolicy.environmentId==null' "$TEST_DIR/api/project-request" >/dev/null
jq -e '.adapterConfig.env.EXISTING_MANAGED_ENTRY=="preserve" and .adapterConfig.env.DUCTOR_BINDING_NAME=="agent-66666666666646668666666666666666"' "$TEST_DIR/api/agent-patch" >/dev/null
expect_failure ductor_agents_create --profile repository-engineer --name 'Fixture engineer'
jq 'map(.metadata.ductorProfile="delegate")' "$TEST_DIR/api/agents" > "$TEST_DIR/api/renamed"
mv "$TEST_DIR/api/renamed" "$TEST_DIR/api/agents"
expect_failure ductor_agents_create --profile repository-engineer --name 'Would evade type cap'
expect_failure ductor_profiles remove repository-engineer
test -f "$DUCTOR_STATE_DIR/profiles/repository-engineer.json"
jq -e '.instructionsBundle.files["AGENTS.md"] | contains("/ductor spawn ") and contains("assign that child a concrete Paperclip task")' "$TEST_DIR/api/agent-request" >/dev/null
[[ $(rg -c '^POST .*/agents$' "$TEST_DIR/api/calls") == 1 ]]
test -f "$DUCTOR_STATE_DIR/agents/$fixture_agent.json"
jq --arg id "$fixture_agent" '.+{id:$id}' "$TEST_DIR/api/agent" > "$TEST_DIR/registered-live"
ductor_agent_registry_check "$TEST_DIR/registered-live" "$TEST_DIR/profile"
jq '.reportsTo="77777777-7777-4777-8777-777777777777"' "$TEST_DIR/registered-live" > "$TEST_DIR/drifted-agent"
expect_failure ductor_agent_registry_check "$TEST_DIR/drifted-agent" "$TEST_DIR/profile"
printf 'Profile policy and trusted agent registry tests passed.\n' 
