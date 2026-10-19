#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FRAGMENT=${DUCTOR_CONSOLE_SOURCE:-$ROOT/src/ductor}
work=$(mktemp -d)
fixture_dir=$work
trap 'rm -rf -- "$work"' EXIT
export DUCTOR_STATE_DIR="$work/state"
mkdir -p "$DUCTOR_STATE_DIR"
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_die() { printf '%s\n' "$*" >&2; exit 1; }
ductor_require_cmd() { local cmd; for cmd in "$@"; do command -v "$cmd" >/dev/null || exit 1; done; }
# shellcheck source=/dev/null
source "$FRAGMENT"
expect_failure() { if ("$@") >"$work/failure" 2>&1; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }

# A clean host must bootstrap tools before its first JSON read. All package
# operations are mocked fresh-child calls; this test never modifies the host.
(
    ductor_console_tools_ready() { [[ -f $fixture_dir/tools-ready ]]; }
    ductor_console_control_ready() { [[ -f $fixture_dir/control-ready ]]; }
    jq() { [[ -f $fixture_dir/tools-ready ]] || { printf 'jq was used before bootstrap\n' >&2; return 98; }; command jq "$@"; }
    ductor_console_exec() {
        printf '%s\n' "$*" >>"$fixture_dir/dependency-calls"
        case "$*" in
            'dependencies --tools-only') touch "$fixture_dir/tools-ready" ;;
            dependencies) touch "$fixture_dir/control-ready" ;;
            *) return 1 ;;
        esac
    }
    ductor_ui_menu() { return 1; }
    ductor_wizard
    [[ $(cat "$fixture_dir/dependency-calls") == 'dependencies --tools-only' ]]
    ductor_console_dependencies worker
    [[ $(wc -l <"$fixture_dir/dependency-calls") == 1 ]]
    ductor_console_dependencies control
    [[ $(tail -1 "$fixture_dir/dependency-calls") == dependencies ]]
    ductor_console_dependencies combined
    [[ $(wc -l <"$fixture_dir/dependency-calls") == 2 ]]
)
(
    ductor_console_tools_ready() { return 1; }
    ductor_console_exec() { return 29; }
    ductor_ui_menu() { touch "$fixture_dir/unsafe-menu"; }
    if ductor_wizard; then exit 1; fi
    [[ ! -e $fixture_dir/unsafe-menu ]]
)
ductor_config_seed >"$work/seed"
jq '.profiles=[{name:"keep-this-profile"}] | .identity.emailDomain="vdm.dev"' "$work/seed" >"$work/config"
ductor_config_import "$work/config"
[[ $(stat -c %a "$DUCTOR_STATE_DIR/config.json") == 600 ]]
touch -d @10 "$DUCTOR_STATE_DIR/config.json"
ductor_config_import "$work/config"
[[ $(stat -c %Y "$DUCTOR_STATE_DIR/config.json") == 10 ]]
jq '.services.openbaoUrl="http://10.0.0.8:8200"' "$work/config" >"$work/unsafe"
expect_failure ductor_config_import "$work/unsafe"
[[ $(stat -c %Y "$DUCTOR_STATE_DIR/config.json") == 10 ]]
jq '.role="control"' "$work/config" >"$work/changed"
ductor_config_import "$work/changed"
compgen -G "$DUCTOR_STATE_DIR/config.previous.*.json" >/dev/null
printf '%s\n' 'hvs.private-test-token-only' | ductor_config token-import >"$work/token-result"
[[ $(cat "$work/token-result") == "$DUCTOR_STATE_DIR/credentials/openbao-admin.token" ]]
[[ $(stat -c %a "$DUCTOR_STATE_DIR/credentials/openbao-admin.token") == 600 ]]
[[ $(stat -c %a "$DUCTOR_STATE_DIR/credentials") == 700 ]]
! rg -q 'private-test-token' "$DUCTOR_STATE_DIR/config.json"
printf '%s\n' '{"nodes":[{"id":"node1","remote":"local","cpu":8,"memory_mib":8192,"disk_gib":100,"max_agents":3,"project":"ductor","profile":"base,python","pool":"default","role":"worker","enabled":false}]}' >"$DUCTOR_STATE_DIR/inventory.json"
ductor_config_sync_nodes
jq -e '.nodes[0].memoryMiB==8192 and .nodes[0].profiles==["base","python"] and .nodes[0].enabled==false and .profiles[0].name=="keep-this-profile"' "$DUCTOR_STATE_DIR/config.json" >/dev/null
jq '.nodes[0].sourceProject="vdm-agents"' "$DUCTOR_STATE_DIR/config.json" >"$work/platform-source"
ductor_config_import "$work/platform-source"
ductor_config_sync_nodes
jq -e '.nodes[0].sourceProject=="vdm-agents" and .nodes[0].enabled==false' "$DUCTOR_STATE_DIR/config.json" >/dev/null
jq '.nodes[0].sourceProject=.nodes[0].project' "$DUCTOR_STATE_DIR/config.json" >"$work/same-source-project"
expect_failure ductor_config_validate "$work/same-source-project"
jq '.nodes[0].sourceProject=""' "$DUCTOR_STATE_DIR/config.json" >"$work/existing-project"
ductor_config_validate "$work/existing-project"
jq '.nodes += [.nodes[0]]' "$DUCTOR_STATE_DIR/config.json" >"$work/duplicates"
expect_failure ductor_config_import "$work/duplicates"
jq '.broker={host:"controller.vdm.dev",user:"ductor-broker",port:22,knownHostsFile:""} | .agents=[{name:"Project manager",profile:"manager"},{name:"Project engineer",profile:"engineer",parentName:"Project manager"}]' "$DUCTOR_STATE_DIR/config.json" >"$work/fleet"
ductor_config_validate "$work/fleet"
jq '.broker.host=""' "$work/fleet" >"$work/pending-broker"
ductor_config_validate "$work/pending-broker"
jq '.agents |= reverse' "$work/fleet" >"$work/parent-after-child"
expect_failure ductor_config_validate "$work/parent-after-child"
jq '.agents += [.agents[0]]' "$work/fleet" >"$work/duplicate-agents"
expect_failure ductor_config_validate "$work/duplicate-agents"
jq '.agents[0].name="bad\nname"' "$work/fleet" >"$work/control-agent-name"
expect_failure ductor_config_validate "$work/control-agent-name"
jq '.broker.port=65536' "$work/fleet" >"$work/bad-broker-port"
expect_failure ductor_config_validate "$work/bad-broker-port"
jq '.broker.host="host; touch bad"' "$work/fleet" >"$work/bad-broker-host"
expect_failure ductor_config_validate "$work/bad-broker-host"
jq '.access={managedTls:true,email:"operator@vdm.dev"}' "$work/fleet" >"$work/managed-access"
ductor_config_validate "$work/managed-access"
jq '.access.email=""' "$work/managed-access" >"$work/bad-access"
expect_failure ductor_config_validate "$work/bad-access"
jq '.services.publish={paperclip:{bindAddress:"192.0.2.10",port:13100},contextforge:{bindAddress:"::",port:14444}} | .access.trustProxy=true' "$work/fleet" >"$work/network"
ductor_config_validate "$work/network"
jq '.services.publish.paperclip.bindAddress="1::2::3"' "$work/network" >"$work/bad-network"
expect_failure ductor_config_validate "$work/bad-network"
jq '.services.publish.contextforge.port=13100' "$work/network" >"$work/duplicate-ports"
expect_failure ductor_config_validate "$work/duplicate-ports"
jq '.access.trustProxy="true"' "$work/network" >"$work/bad-proxy"
expect_failure ductor_config_validate "$work/bad-proxy"
(
    cp "$work/network" "$work/network-form"
    ductor_ui_input() { case $2 in 'Optional MemPalace'*) printf 'https://memory.vdm.dev\n' ;; *) printf '%s\n' "$3" ;; esac; }
    ductor_ui_budget() { printf '%s\n' "$2"; }
    ductor_ui_confirm() { [[ $1 == 'Trusted reverse proxy' ]]; }
    ductor_console_network_form "$work/network-form"
    jq -e '.services.publish.paperclip=={bindAddress:"192.0.2.10",port:13100} and .services.publish.contextforge=={bindAddress:"::",port:14444} and .services.publish.mempalace.port==8765 and .services.publish.openbao.port==8200 and .services.mempalaceUrl=="https://memory.vdm.dev" and .access.managedTls==false and .access.trustProxy==true' "$work/network-form" >/dev/null
)

# A fresh child must keep errexit even when the caller is an if condition.
cat >"$work/child" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
false
printf 'unsafe continuation\n'
CHILD
export DUCTOR_SELF="$work/child"
if ductor_console_exec test >"$work/child-output"; then exit 1; fi
[[ ! -s $work/child-output ]]

# The wizard retains profiles and node inventory and records only file paths for
# secrets. No service start is claimed when the operator defers apply.
ductor_ui_has_dialog() { return 1; }
ductor_console_control_ready() { return 0; }
ductor_ui_message() { :; }
ductor_ui_menu() { printf 'control\n'; }
ductor_ui_input() {
    case $2 in
        'Paperclip origin;'*) printf 'https://paperclip.vdm.dev\n' ;;
        'ContextForge origin;'*) printf 'https://tools.vdm.dev\n' ;;
        'OpenBao origin;'*) printf 'https://bao.vdm.dev\n' ;;
        'Your real email domain'*) printf 'vdm.dev\n' ;;
        'Existing private OpenBao'*) printf '%s\n' "$DUCTOR_STATE_DIR/credentials/openbao-admin.token" ;;
        'Company UUID shown in Paperclip') printf '11111111-1111-4111-8111-111111111111\n' ;;
        *) printf 'Unexpected wizard prompt: %s\n' "$2" >&2; return 1 ;;
    esac
}
ductor_ui_confirm() { [[ $1 == 'Save configuration' ]]; }
ductor_console_exec() {
    printf '%s\n' "$*" >>"$fixture_dir/commands"
    [[ $1 == config && $2 == import ]] || return 1
    ductor_config_import "$3"
}
ductor_wizard
jq -e '.role=="control" and .services.paperclipUrl=="https://paperclip.vdm.dev" and .credentials.openbaoAdminTokenFile!="" and .identity.emailDomain=="vdm.dev" and .profiles[0].name=="keep-this-profile" and .nodes[0].id=="node1"' "$DUCTOR_STATE_DIR/config.json" >/dev/null
[[ $(wc -l <"$work/commands") == 1 ]]

# Credential setup delegates to the existing private service commands. Unseal
# must stay interactive and must never go through a captured dialog command.
(
    ductor_ui_input() { case $2 in 'New absolute path'*) printf '%s/recovery.json\n' "$fixture_dir" ;; *) return 1 ;; esac; }
    ductor_ui_confirm() { [[ $1 == 'Create recovery material' ]]; }
    ductor_console_run() { [[ $1 == 'Initialize OpenBao' && $2 == services && $3 == bao-init && $4 == "$fixture_dir/recovery.json" ]]; }
    ductor_console_bao_init
    ductor_console_run() { printf 'Unsafe captured unseal\n' >&2; return 97; }
    ductor_console_exec() { [[ $1 == services && $2 == bao-unseal ]]; printf 'hidden-unseal-delegated\n' >"$fixture_dir/unseal-delegated"; }
    ductor_ui_confirm() { return 1; }
    ductor_console_bao_unseal
    [[ -s $fixture_dir/unseal-delegated ]]
)

# First-run apply can start services yet fail on missing native login. The
# wizard must still offer approval and then actually retry reconciliation.
mkdir -p "$DUCTOR_STATE_DIR/services"
printf 'PAPERCLIP_PUBLIC_URL=http://localhost:3100\n' >"$DUCTOR_STATE_DIR/services/settings.env"
[[ $(ductor_console_paperclip_url) == http://localhost:3100 ]]
ductor_ui_confirm() { case $1 in 'Save configuration'|'Apply configuration'|'Paperclip sign-in'|'Retry apply') return 0 ;; *) return 1 ;; esac; }
ductor_console_exec() {
    printf '%s\n' "$*" >>"$fixture_dir/recovery-commands"
    case "$1 ${2:-}" in
        'config import') ductor_config_import "$3" ;;
        'paperclip login') return 0 ;;
        *)
            [[ $1 == apply ]] || return 1
            if [[ ! -f $fixture_dir/applied-once ]]; then touch "$fixture_dir/applied-once"; return 17; fi
            return 0
            ;;
    esac
}
ductor_wizard
[[ $(rg -c '^apply$' "$work/recovery-commands") == 2 ]]
rg -q '^paperclip login --url http://localhost:3100 --company 11111111-1111-4111-8111-111111111111$' "$work/recovery-commands"

# Agent declarations are retained with readable names and manager-first order.
jq '.profiles=[{name:"manager"},{name:"engineer"}] | .agents=[{name:"Project manager",profile:"manager"}]' "$DUCTOR_STATE_DIR/config.json" >"$work/agent-config"
ductor_config_import "$work/agent-config"
ductor_ui_input() {
    case $2 in
        'Configured agent profile name') printf 'engineer\n' ;;
        'New agent name') printf 'Project engineer\n' ;;
        'Parent agent name already declared'*) printf 'Project manager\n' ;;
        *) return 1 ;;
    esac
}
ductor_ui_confirm() { [[ $1 == 'Save desired agent' ]]; }
ductor_console_agent_create
jq -e '.agents==[{name:"Project manager",profile:"manager"},{name:"Project engineer",profile:"engineer",parentName:"Project manager"}]' "$DUCTOR_STATE_DIR/config.json" >/dev/null
before=$(sha256sum "$DUCTOR_STATE_DIR/config.json")
ductor_ui_menu() { return 1; }
ductor_wizard
[[ $(sha256sum "$DUCTOR_STATE_DIR/config.json") == "$before" ]]
[[ $(wc -l <"$work/commands") == 1 ]]
printf 'Console configuration and wizard tests passed.\n'
