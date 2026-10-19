#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DUCTOR_APPLY_SOURCE:-$ROOT/src/ductor}
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# shellcheck source=/dev/null
source "$SOURCE"
record() { printf '%s\n' "$*" >>"$TMP/calls"; }
ductor_apply_root() { :; }
# shellcheck disable=SC2329 # Called indirectly by apply before the image-pin test override.
ductor_services_prepare() { record services.prepare; mkdir -p "$DUCTOR_STATE_DIR/services"; printf 'PAPERCLIP_PUBLIC_URL=%s\n' "${DUCTOR_PAPERCLIP_URL:-http://localhost:3100}" >"$DUCTOR_STATE_DIR/services/settings.env"; }
ductor_services_value() { awk -F= -v key="$1" '$1==key {print $2;exit}' "$2"; }
# shellcheck disable=SC2329 # Called indirectly by apply before the image-pin test override.
ductor_services_up() { record services.up; [[ ${FAIL_PHASE:-} != services ]]; }
ductor_nodes() {
    local operation=$1; shift
    record "node:$operation:$1"
    if [[ $operation == add ]]; then
        jq -n --arg id "$1" --arg remote "$2" --argjson cpu "$3" --argjson ram "$4" --argjson disk "$5" --argjson maximum "$6" --arg project "$7" --arg profile "$8" --arg pool "$9" --arg role "${10}" '{nodes:[{id:$id,remote:$remote,cpu:$cpu,memory_mib:$ram,disk_gib:$disk,max_agents:$maximum,project:$project,profile:$profile,pool:$pool,role:$role,identity:"hardware-1",enabled:true}]}' >"$DUCTOR_STATE_DIR/inventory.json"
    fi
}
ductor_services_ssh_credentials() { record credentials; mkdir -p "$DUCTOR_STATE_DIR/services/ssh-agent"; : >"$DUCTOR_STATE_DIR/services/ssh-agent/id_ed25519.pub"; }
ductor_apply_broker_identity() { record broker.identity; }
ductor_broker_install() { record broker.install; }
ductor_provider_prepare() { record provider.prepare; }
ductor_provider_install() { record provider.install; printf '{"status":"ready"}\n'; }
ductor_apply_access() { record access; }
ductor_paperclip_conversation() { record conversation; }
# shellcheck disable=SC2329 # Invoked indirectly by apply before the later access-test override.
ductor_pc_operator() { record operator; }
ductor_profile_connection() { record profile.connection; ductor_pc_load; }
ductor_pc_request() {
    local method=$1 path=$2
    record "request:$method:$path"
    case $path in
        */agents) cat "$DUCTOR_STATE_DIR/mock-agents.json" ;;
        /api/environments/*) printf '{"metadata":{"managedBy":"ductor"},"driver":"sandbox","status":"active","config":{"provider":"ductor-incus","profile":"engineer"}}\n' ;;
        *) printf 'Unhandled test endpoint: %s\n' "$path" >&2; return 1 ;;
    esac
}
ductor_agents_create() {
    local profile='' name='' parent='' id='44444444-4444-4444-8444-444444444444' file temporary
    while (($#)); do case $1 in --profile) profile=$2 ;; --name) name=$2 ;; --parent) parent=$2 ;; *) return 1 ;; esac; shift 2; done
    record "agent.create:$name"
    file=$(ductor_profile_file "$profile")
    temporary=$(mktemp)
    jq -n --slurpfile p "$file" --arg name "$name" --arg parent "$parent" --arg id "$id" '{id:$id,name:$name,role:$p[0].role,reportsTo:$parent,status:"idle",metadata:{managedBy:"ductor",ductorProfile:$p[0].name,repository:$p[0].repository,binding:("agent-"+($id|gsub("-";"")))},adapterType:"codex_local",adapterConfig:{command:"/usr/local/bin/ductor-runtime",model:$p[0].model,cwd:$p[0].runtime.workspace,timeoutSec:$p[0].maxRunSeconds,dangerouslyBypassApprovalsAndSandbox:false,env:{DUCTOR_BINDING_NAME:("agent-"+($id|gsub("-";"")))}},runtimeConfig:{aiConnection:{mode:"shared",provider:"openai",method:"subscription",connectionId:$p[0].connectionId,grantId:$p[0].grantId}},permissions:{canCreateAgents:false,canCreateSkills:false},defaultEnvironmentId:"55555555-5555-4555-8555-555555555555"}' >"$temporary"
    jq --slurpfile p "$file" '.companyId=$p[0].companyId | .metadata.projectId="77777777-7777-4777-8777-777777777777"' "$temporary" >"$temporary.identity"
    mv "$temporary.identity" "$temporary"
    jq --slurpfile a "$temporary" '.+[$a[0]]' "$DUCTOR_STATE_DIR/mock-agents.json" >"$temporary.list"
    mv "$temporary.list" "$DUCTOR_STATE_DIR/mock-agents.json"
    ductor_agent_registry_record "$temporary" "$file" || return 1
    cat "$temporary"; rm "$temporary"
}
fixture() {
    export DUCTOR_STATE_DIR="$TMP/$1"
    mkdir -p "$DUCTOR_STATE_DIR/paperclip"
    printf 'test-private-token\n' >"$DUCTOR_STATE_DIR/admin.token"; chmod 600 "$DUCTOR_STATE_DIR/admin.token"
    printf 'verified-test-key\n' >"$DUCTOR_STATE_DIR/known_hosts"
    printf '[]\n' >"$DUCTOR_STATE_DIR/mock-agents.json"
    jq -n '{url:"https://paperclip.internal",companyId:"11111111-1111-4111-8111-111111111111",token:"test-private-board-token"}' >"$DUCTOR_STATE_DIR/paperclip/connection.json"
    chmod 600 "$DUCTOR_STATE_DIR/paperclip/connection.json"
    ductor_profiles example | jq '.name="engineer" | .model="exact-model-v1"' >"$DUCTOR_STATE_DIR/profile.json"
    jq -n --arg root "$DUCTOR_STATE_DIR" --slurpfile p "$DUCTOR_STATE_DIR/profile.json" '{schemaVersion:1,role:"combined",services:{paperclipUrl:"https://paperclip.internal",gatewayOrigin:"https://tools.internal",openbaoUrl:"https://bao.internal"},identity:{emailDomain:"company.internal"},credentials:{openbaoAdminTokenFile:($root+"/admin.token")},broker:{host:"broker.internal",port:22,user:"ductor-broker",knownHostsFile:($root+"/known_hosts")},nodes:[{id:"worker1",remote:"local",cpu:4,memoryMiB:8192,diskGiB:80,maxAgents:2,project:"ductor",profiles:["isolation","runtime"],pool:"default",role:"worker",enabled:true}],profiles:$p,agents:[{name:"Project engineer",profile:"engineer"}]}' >"$DUCTOR_STATE_DIR/config.json"
    : >"$TMP/calls"
}
fixture check
ductor_apply --check >"$TMP/check.json"
jq -e '.status=="validated" and .liveServicesChecked==false' "$TMP/check.json" >/dev/null
[[ ! -s $TMP/calls && ! -f $DUCTOR_STATE_DIR/apply-state.json ]]

fixture failure
FAIL_PHASE=services
if ductor_apply >"$TMP/failure.json" 2>"$TMP/failure.err"; then printf 'Apply ignored a failed first phase.\n' >&2; exit 1; fi
unset FAIL_PHASE
rg -q '^services.up$' "$TMP/calls"
if rg -q 'node:|credentials|provider.install|agent.create' "$TMP/calls"; then printf 'Apply continued after a failed service phase.\n' >&2; exit 1; fi
jq -e '.status=="failed" and .phase=="services" and .liveAgentExecutionQualified==false' "$DUCTOR_STATE_DIR/apply-state.json" >/dev/null

fixture pending
rm "$DUCTOR_STATE_DIR/paperclip/connection.json" "$DUCTOR_STATE_DIR/admin.token"
if ductor_apply >"$TMP/pending.json" 2>"$TMP/pending.err"; then printf 'Apply claimed readiness without authentication.\n' >&2; exit 1; fi
jq -e '.status=="pending" and any(.pending[];.requirement=="paperclip.operator") and any(.pending[];.requirement=="credentials.openbaoAdminTokenFile")' "$DUCTOR_STATE_DIR/apply-state.json" >/dev/null
if rg -q 'credentials|provider.install|agent.create' "$TMP/calls"; then printf 'Apply entered provisioning without prerequisites.\n' >&2; exit 1; fi

fixture configured
ductor_apply >"$TMP/configured.json" 2>"$TMP/configured.err"
jq -e '.status=="configured" and .liveAgentExecutionQualified==false' "$DUCTOR_STATE_DIR/apply-state.json" >/dev/null
[[ $(rg -c '^agent.create:' "$TMP/calls") == 1 ]]
ductor_apply >"$TMP/reapplied.json" 2>"$TMP/reapplied.err"
[[ $(rg -c '^agent.create:' "$TMP/calls") == 1 ]]
[[ $(jq length "$DUCTOR_STATE_DIR/mock-agents.json") == 1 ]]
if rg -q 'test-private-(token|board-token)' "$TMP/calls" "$TMP/configured.json" "$TMP/configured.err"; then printf 'Apply exposed credentials.\n' >&2; exit 1; fi

# A manual Paperclip clone can copy all editable profile fields and still lacks
# the controller-owned authorization record required for reuse.
cp "$DUCTOR_STATE_DIR/mock-agents.json" "$TMP/registered-agents.json"
jq '.[0].id="66666666-6666-4666-8666-666666666666" | .[0].metadata.binding="agent-66666666666646668666666666666666" | .[0].adapterConfig.env.DUCTOR_BINDING_NAME=.[0].metadata.binding' "$TMP/registered-agents.json" >"$DUCTOR_STATE_DIR/mock-agents.json"
if ductor_apply >"$TMP/unregistered.out" 2>"$TMP/unregistered.err"; then printf 'Apply accepted an unregistered manual agent clone.\n' >&2; exit 1; fi
jq -e '.status=="failed" and .phase=="agents"' "$DUCTOR_STATE_DIR/apply-state.json" >/dev/null
[[ ! -e $DUCTOR_STATE_DIR/agents/66666666-6666-4666-8666-666666666666.json ]]
[[ $(rg -c '^agent.create:' "$TMP/calls") == 1 ]]
cp "$TMP/registered-agents.json" "$DUCTOR_STATE_DIR/mock-agents.json"

# A model change in Paperclip is drift, never permission to silently rewrite it.
jq '.[0].adapterConfig.model="unexpected-model"' "$DUCTOR_STATE_DIR/mock-agents.json" >"$TMP/drift.json"
mv "$TMP/drift.json" "$DUCTOR_STATE_DIR/mock-agents.json"
if ductor_apply >"$TMP/drift.out" 2>"$TMP/drift.err"; then printf 'Apply reused an agent with the wrong model.\n' >&2; exit 1; fi
jq -e '.status=="failed" and .phase=="agents"' "$DUCTOR_STATE_DIR/apply-state.json" >/dev/null

fixture worker
jq '.role="worker"' "$DUCTOR_STATE_DIR/config.json" >"$TMP/worker.json"
mv "$TMP/worker.json" "$DUCTOR_STATE_DIR/config.json"
ductor_apply >"$TMP/worker.out" 2>"$TMP/worker.err"
jq -e '.status=="worker-configured" and .liveAgentExecutionQualified==false' "$DUCTOR_STATE_DIR/apply-state.json" >/dev/null
if rg -q 'services.up|credentials|provider.install|agent.create' "$TMP/calls"; then printf 'Worker apply started controller services.\n' >&2; exit 1; fi
printf 'Apply tests passed: validation without mutation, fail-first sequencing, explicit pending prerequisites, registered agent reuse, manual clone rejection, model drift rejection and worker-only configuration.\n'

# Restore the real access reconciler and mock only its external boundaries.
# shellcheck source=/dev/null
source "$SOURCE"
fixture access
ductor_pc_operator() { record "operator:$DUCTOR_PC_URL"; }
ductor_services_access() { record access.managed; [[ ${FAIL_ACCESS:-} != true ]]; }
ductor_services_setting_set() { record "setting:$1=$2"; }
ductor_services_compose() { record services.restart; }
curl() { record endpoint.health; [[ ${FAIL_ACCESS:-} != true ]] || return 7; printf '{"status":"ok","initialized":true,"sealed":false}\n'; }
rewrite_operator_url() {
    jq '.url="http://localhost:3100"' "$DUCTOR_STATE_DIR/paperclip/connection.json" >"$TMP/operator.json"
    mv "$TMP/operator.json" "$DUCTOR_STATE_DIR/paperclip/connection.json"
    chmod 600 "$DUCTOR_STATE_DIR/paperclip/connection.json"
    ductor_pc_load
}
rewrite_operator_url
jq '.access={managedTls:true,email:"operator@company.internal"}' "$DUCTOR_STATE_DIR/config.json" >"$TMP/access.json"
mv "$TMP/access.json" "$DUCTOR_STATE_DIR/config.json"
FAIL_ACCESS=true
if ductor_apply_access "$DUCTOR_STATE_DIR/config.json" "$TMP"; then printf 'Failed TLS setup was accepted.\n' >&2; exit 1; fi
[[ $(jq -r .url "$DUCTOR_STATE_DIR/paperclip/connection.json") == http://localhost:3100 ]]
unset FAIL_ACCESS
mkdir -p "$DUCTOR_STATE_DIR/services"
printf 'PAPERCLIP_BIND_ADDRESS=127.0.0.1\n' >"$DUCTOR_STATE_DIR/services/settings.env"
ductor_apply_access "$DUCTOR_STATE_DIR/config.json" "$TMP"
[[ $(jq -r .url "$DUCTOR_STATE_DIR/paperclip/connection.json") == https://paperclip.internal ]]

rewrite_operator_url
jq '.access.managedTls=false' "$DUCTOR_STATE_DIR/config.json" >"$TMP/access.json"
mv "$TMP/access.json" "$DUCTOR_STATE_DIR/config.json"
: >"$TMP/calls"
FAIL_ACCESS=true
if ductor_apply_access "$DUCTOR_STATE_DIR/config.json" "$TMP"; then printf 'Unavailable external TLS was accepted.\n' >&2; exit 1; fi
[[ $(jq -r .url "$DUCTOR_STATE_DIR/paperclip/connection.json") == http://localhost:3100 ]]
if rg -q '^setting:|services.restart' "$TMP/calls"; then printf 'Canonical origins changed before TLS verification.\n' >&2; exit 1; fi
unset FAIL_ACCESS
ductor_apply_access "$DUCTOR_STATE_DIR/config.json" "$TMP"
[[ $(jq -r .url "$DUCTOR_STATE_DIR/paperclip/connection.json") == https://paperclip.internal ]]
[[ $(rg -c '^endpoint.health$' "$TMP/calls") == 4 ]]
printf 'Apply TLS tests passed: failed managed/external TLS preserves bootstrap authentication; canonical origins change only after verified access.\n'

# A newer installer cannot overwrite existing image pins before the upgrade
# command's data-backup gate. Rendering occurs only in a disposable copy.
fixture service-pins
SERVICE_PIN='example/service:1@sha256:aaaaaaaa'
MEMORY_PIN='example/memory:1@sha256:bbbbbbbb'
ductor_services_prepare() {
    record "prepare:$DUCTOR_STATE_DIR"
    mkdir -p "$DUCTOR_STATE_DIR/services"
    printf 'PAPERCLIP_PUBLIC_URL=http://localhost:3100\n' >"$DUCTOR_STATE_DIR/services/settings.env"
    printf 'services:\n  app:\n    image: %s\n' "$SERVICE_PIN" >"$DUCTOR_STATE_DIR/services/compose.yaml"
}
ductor_services_up() { record services.up; }
ductor_services_memory_scope() {
    record "memory.prepare:$1"
    printf 'services:\n  memory:\n    image: %s\n' "$MEMORY_PIN" >"$DUCTOR_STATE_DIR/services/memory/$1/compose.yaml"
}
ductor_apply_services "$DUCTOR_STATE_DIR/config.json"
ductor_apply_services "$DUCTOR_STATE_DIR/config.json"
[[ $(rg -c '^services.up$' "$TMP/calls") == 2 ]]
cp "$DUCTOR_STATE_DIR/services/compose.yaml" "$TMP/old-compose.yaml"
SERVICE_PIN='example/service:2@sha256:cccccccc'
if ductor_apply_services "$DUCTOR_STATE_DIR/config.json" >"$TMP/pins.out" 2>"$TMP/pins.err"; then printf 'Apply bypassed the service upgrade gate.\n' >&2; exit 1; fi
cmp "$TMP/old-compose.yaml" "$DUCTOR_STATE_DIR/services/compose.yaml"
[[ $(rg -c '^services.up$' "$TMP/calls") == 2 ]]
rg -q 'upgrade apply --backup-confirmed' "$TMP/pins.err"
SERVICE_PIN='example/service:1@sha256:aaaaaaaa'
mkdir -p "$DUCTOR_STATE_DIR/services/memory/project"
ductor_services_memory_scope project --prepare
cp "$DUCTOR_STATE_DIR/services/memory/project/compose.yaml" "$TMP/old-memory.yaml"
MEMORY_PIN='example/memory:2@sha256:dddddddd'
if ductor_apply_services "$DUCTOR_STATE_DIR/config.json" >"$TMP/memory-pins.out" 2>"$TMP/memory-pins.err"; then printf 'Apply bypassed the memory scope upgrade gate.\n' >&2; exit 1; fi
cmp "$TMP/old-memory.yaml" "$DUCTOR_STATE_DIR/services/memory/project/compose.yaml"
[[ $(rg -c '^services.up$' "$TMP/calls") == 2 ]]
[[ -z $(find "$DUCTOR_STATE_DIR" -maxdepth 1 -name '.apply-pins.*' -print -quit) ]]
printf 'Apply image-pin tests passed: first install and same pins succeed; changed main/memory images preserve installed files and require the upgrade backup gate.\n'

# Reconcile real persisted publication settings, with no Docker or HTTP effects.
# shellcheck source=/dev/null
source "$SOURCE"
fixture networking
ductor_services_prepare >/dev/null
jq '.services.publish={paperclip:{bindAddress:"192.0.2.20",port:13100},contextforge:{bindAddress:"::1",port:14444},mempalace:{bindAddress:"127.0.0.1",port:18765},openbao:{bindAddress:"0.0.0.0",port:18200}} | .services.mempalaceUrl="https://memory.internal" | .access={managedTls:false,email:"",trustProxy:true}' "$DUCTOR_STATE_DIR/config.json" >"$TMP/networking.json"
settings="$DUCTOR_STATE_DIR/services/settings.env"
secret_hash=$(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env")
ductor_apply_service_network "$TMP/networking.json" "$settings"
[[ $(ductor_services_local_origin PAPERCLIP) == http://192.0.2.20:13100 ]]
[[ $(ductor_services_local_origin CONTEXTFORGE) == 'http://[::1]:14444' ]]
[[ $(ductor_services_local_origin OPENBAO) == http://127.0.0.1:18200 ]]
[[ $(ductor_services_value MEMPALACE_ALLOWED_HOSTS "$settings") == mempalace,mempalace:8765,memory.internal ]]
before=$(sha256sum "$settings")
ductor_apply_service_network "$TMP/networking.json" "$settings"
[[ $(sha256sum "$settings") == "$before" ]]
[[ $(sha256sum "$DUCTOR_STATE_DIR/services/secrets.env") == "$secret_hash" ]]
jq '.services.publish.openbao.port=13100' "$TMP/networking.json" >"$TMP/conflicting-network.json"
if ductor_apply_service_network "$TMP/conflicting-network.json" "$settings"; then printf 'Accepted colliding service ports.\n' >&2; exit 1; fi
[[ $(sha256sum "$settings") == "$before" ]]
printf 'Service publication tests passed: distinct listeners, public origins, idempotence, secret retention and atomic collision rejection.\n'
