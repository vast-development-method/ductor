#!/usr/bin/env bash
# Exercise admission and ownership with a deterministic Incus API/CLI fixture.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FRAGMENT=${DUCTOR_INVENTORY_SOURCE:-$ROOT/src/ductor}
if [[ ! -f $FRAGMENT ]]; then FRAGMENT=$ROOT/src/ductor; fi
export DUCTOR_STATE_DIR
DUCTOR_STATE_DIR=$(mktemp -d)
trap 'rm -rf -- "$DUCTOR_STATE_DIR"' EXIT
mkdir -p "$DUCTOR_STATE_DIR/mock"
printf '%s\n' '[]' > "$DUCTOR_STATE_DIR/mock/instances.json"
ductor_die() { printf 'Expected or actual error: %s\n' "$*" >&2; exit 1; }
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_require() { :; }
# Single distributable supports a source guard; the fragment consists of functions.
export DUCTOR_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$FRAGMENT"
FAKE_QUOTA_CPU=8
FAKE_OFFLINE=false
FAKE_UNSAFE=false
FAKE_CREATE_FAIL=false
FAKE_DRAIN_UUID=fixture-server-one
ductor_incus_query() {
    [[ $FAKE_OFFLINE == false ]] || return 1
    case "$2" in
        /1.0) printf '%s\n' '{"environment":{"server_clustered":false}}' ;;
        /1.0/resources) jq -n --arg id "$FAKE_DRAIN_UUID" '{cpu:{total:16},memory:{total:34359738368},system:{uuid:$id}}' ;;
        /1.0/projects/ductor) jq -n --arg cpu "$FAKE_QUOTA_CPU" --arg restricted "$([[ $FAKE_UNSAFE == true ]] && printf false || printf true)" '{config:{restricted:$restricted,"features.profiles":"true","limits.containers":"0","limits.cpu":$cpu,"limits.memory":"16GiB","limits.disk":"80GiB","limits.virtual-machines":"4"}}' ;;
        '/1.0/profiles/ductor?project=ductor') printf '%s\n' '{"devices":{"root":{"type":"disk","path":"/","pool":"default"},"eth0":{"type":"nic","network":"incusbr0","security.acls":"vdm-agent-connected","security.acls.default.ingress.action":"reject","security.acls.default.egress.action":"reject","security.ipv4_filtering":"true"}}}' ;;
        '/1.0/profiles/vdm-opencode-python?project=ductor') printf '%s\n' '{"config":{"security.secureboot":"true","user.vdm.variant":"python","limits.cpu":"1"},"devices":{}}' ;;
        '/1.0/profiles/vdm-size-standard?project=ductor') printf '%s\n' '{"config":{"limits.cpu":"8","limits.memory":"16GiB"},"devices":{"root":{"type":"disk","path":"/","pool":"default","size":"120GiB"}}}' ;;
        '/1.0/profiles/vdm-policy-connected?project=ductor') printf '%s\n' '{"config":{"user.vdm.policy":"connected","user.vdm.policy.status":"ready"},"devices":{"eth0":{"type":"nic","network":"vdm-agentbr0","security.acls":"vdm-agent-connected","security.acls.default.ingress.action":"reject","security.acls.default.egress.action":"reject","security.ipv4_filtering":"true"}}}' ;;
        '/1.0/profiles/bad-nic?project=ductor') printf '%s\n' '{"devices":{"eth0":{"type":"nic","network":"vdm-agentbr0"}}}' ;;
        '/1.0/profiles/blocked-policy?project=ductor') printf '%s\n' '{"config":{"user.vdm.policy.status":"blocked"},"devices":{}}' ;;
        /1.0/storage-pools/default/resources) printf '%s\n' '{"space":{"total":214748364800,"used":21474836480}}' ;;
        '/1.0/instances?project=ductor&recursion=1') cat "$DUCTOR_STATE_DIR/mock/instances.json" ;;
        *) printf 'Unexpected fixture query: %s\n' "$2" >&2; return 1 ;;
    esac
}
incus() {
    local action=$1; shift
    case "$action" in
        init)
            [[ $FAKE_CREATE_FAIL == false ]] || return 1
            printf '%s\n' "$1" > "$DUCTOR_STATE_DIR/mock/launch-image"
            local target=$2 name key value config='{}' root='{}' profiles='[]'; shift 2
            name=${target#*:}
            while (($#)); do
                case "$1" in
                    --config) key=${2%%=*}; value=${2#*=}; config=$(jq --arg key "$key" --arg value "$value" '. + {($key):$value}' <<< "$config"); shift 2 ;;
                    --device) value=${2#*=}; root=$(jq -n --arg size "$value" '{type:"disk",path:"/",pool:"default",size:$size}'); shift 2 ;;
                    --profile) profiles=$(jq --arg profile "$2" '. + [$profile]' <<< "$profiles"); shift 2 ;;
                    --project) shift 2 ;;
                    --vm) shift ;;
                    *) printf 'Unexpected init argument: %s\n' "$1" >&2; return 1 ;;
                esac
            done
            jq --arg name "$name" --argjson config "$config" --argjson root "$root" --argjson profiles "$profiles" '. + [{name:$name,status:"Stopped",type:"virtual-machine",profiles:$profiles,config:$config,expanded_config:$config,expanded_devices:{root:$root}}]' "$DUCTOR_STATE_DIR/mock/instances.json" > "$DUCTOR_STATE_DIR/mock/new.json"
            mv "$DUCTOR_STATE_DIR/mock/new.json" "$DUCTOR_STATE_DIR/mock/instances.json"
            ;;
        start|stop)
            local name=${1#*:} state=Running
            [[ $action != stop ]] || state=Stopped
            jq --arg name "$name" --arg state "$state" '(.[] | select(.name == $name) | .status) = $state' "$DUCTOR_STATE_DIR/mock/instances.json" > "$DUCTOR_STATE_DIR/mock/new.json"
            mv "$DUCTOR_STATE_DIR/mock/new.json" "$DUCTOR_STATE_DIR/mock/instances.json"
            ;;
        *) printf 'Unexpected fixture Incus action: %s\n' "$action" >&2; return 1 ;;
    esac
}
timeout() { shift; "$@"; }
assert() { jq -e "$2" <<< "$1" >/dev/null || { printf 'Assertion failed: %s\n%s\n' "$2" "$1" >&2; exit 1; }; }
expect_failure() { if ( "$@" ) >/dev/null 2>&1; then printf 'Expected failure from %s\n' "$*" >&2; exit 1; fi; }

ductor_nodes add host-one local 8 16384 80 4
assert "$(ductor_nodes list)" '.nodes|length == 1'
ductor_nodes add host-one local 8 16384 80 4
assert "$(ductor_nodes list)" '.nodes|length == 1'
expect_failure ductor_nodes add duplicate another 8 16384 80 4
expect_failure ductor_nodes add unsafe local 8 16384 80 4 default
expect_failure ductor_nodes add bad local 2 16384 80 4
expect_failure ductor_nodes add bad local 8 16384 80 4 ductor ductor default unknown
assert "$(ductor_plan 2 4096 10)" '.eligible_nodes == ["host-one"]'
assert "$(ductor_plan 9 4096 10)" '.eligible_nodes == []'
ductor_vm create alpha 2 4096 10 images:debian/12
[[ $(cat "$DUCTOR_STATE_DIR/mock/launch-image") == images:debian/12 ]]
assert "$(ductor_plan 2 4096 10)" '.nodes[0].reserved == {cpu:2,memory_mib:4096,disk_gib:10,agents:1}'
# A real instance and its durable placement reserve capacity exactly once.
ductor_vm create alpha 2 4096 10 images:debian/12
assert "$(ductor_plan 2 4096 10)" '.nodes[0].instances == null and .nodes[0].pending == 0 and .nodes[0].reserved.agents == 1'
expect_failure ductor_vm create alpha 4 4096 10 images:debian/12
ductor_vm start alpha
assert "$(cat "$DUCTOR_STATE_DIR/mock/instances.json")" '.[0].status == "Running"'
ductor_nodes drain host-one
assert "$(ductor_plan 1 1024 10)" '.eligible_nodes == []'
expect_failure ductor_vm create beta 2 4096 10 images:debian/12
ductor_vm stop alpha
assert "$(cat "$DUCTOR_STATE_DIR/mock/instances.json")" '.[0].status == "Stopped"'
ductor_nodes enable host-one
assert "$(ductor_plan 2 4096 10)" '.nodes[0].reserved.cpu == 2'
FAKE_CREATE_FAIL=true
expect_failure ductor_vm create retry-me 2 2048 10 images:debian/12
assert "$(ductor_plan 2 4096 10)" '.nodes[0].pending == 1 and .nodes[0].reserved.agents == 2 and .nodes[0].reserved.cpu == 4'
FAKE_CREATE_FAIL=false
ductor_vm create retry-me 2 2048 10 images:debian/12
assert "$(ductor_plan 2 4096 10)" '.nodes[0].pending == 0 and .nodes[0].reserved.agents == 2 and .nodes[0].reserved.cpu == 4'
FAKE_OFFLINE=true
assert "$(ductor_plan 1 1024 10)" '.eligible_nodes == [] and .nodes[0].reason == "unreachable or invalid configuration"'
FAKE_OFFLINE=false
FAKE_UNSAFE=true
assert "$(ductor_plan 1 1024 10 2>/dev/null)" '.eligible_nodes == []'
FAKE_UNSAFE=false
FAKE_DRAIN_UUID=replaced-server
expect_failure ductor_vm start alpha
FAKE_DRAIN_UUID=fixture-server-one
# Ownership drift cannot stop an unrelated VM, even if the local name is known.
jq '.[0].config["user.ductor.owner"] = "other-controller"' "$DUCTOR_STATE_DIR/mock/instances.json" > "$DUCTOR_STATE_DIR/mock/new.json"
mv "$DUCTOR_STATE_DIR/mock/new.json" "$DUCTOR_STATE_DIR/mock/instances.json"
expect_failure ductor_vm stop alpha
expect_failure ductor_nodes remove host-one
expect_failure ductor_inventory_profiles_valid 'ductor,'
expect_failure ductor_inventory_profiles_valid 'ductor,,bad'
expect_failure ductor_inventory_profiles_valid 'ductor,ductor'
(
    DUCTOR_STATE_DIR=$DUCTOR_STATE_DIR/multiple
    mkdir -p "$DUCTOR_STATE_DIR/mock"
    printf '%s\n' '[]' > "$DUCTOR_STATE_DIR/mock/instances.json"
    platform_profiles=vdm-opencode-python,vdm-size-standard,vdm-policy-connected
    resolved=$(ductor_inventory_profiles_resolve local ductor "$platform_profiles")
    assert "$resolved" '.config["limits.cpu"] == "8" and .config["security.secureboot"] == "true" and .devices.root.pool == "default" and .devices.eth0.network == "vdm-agentbr0"'
    # A later device replaces the entire device. It cannot inherit the ACL
    # from the earlier policy and accidentally pass validation.
    resolved=$(ductor_inventory_profiles_resolve local ductor "$platform_profiles,bad-nic")
    assert "$resolved" '.devices.eth0["security.acls"] == null'
    expect_failure ductor_nodes add insecure local 8 16384 80 4 ductor "$platform_profiles,bad-nic"
    expect_failure ductor_nodes add blocked local 8 16384 80 4 ductor "$platform_profiles,blocked-policy"
    ductor_nodes add platform-one local 8 16384 80 4 ductor "$platform_profiles"
    ductor_vm create platform-python 2 4096 10 vdm-opencode-python/0.3.0-rc.3-amd64
    assert "$(cat "$DUCTOR_STATE_DIR/mock/instances.json")" '.[0].profiles == ["vdm-opencode-python","vdm-size-standard","vdm-policy-connected"] and .[0].config["limits.cpu"] == "2"'
    printf '%s\n' '{"nodes":[{"id":"platform-one","remote":"local","project":"ductor","sourceProject":"vdm-agents"}]}' > "$DUCTOR_STATE_DIR/config.json"
    ductor_vm create copied-python 2 4096 10 build:vdm-opencode-python/0.3.0-rc.3-amd64
    [[ $(cat "$DUCTOR_STATE_DIR/mock/launch-image") == local:vdm-opencode-python/0.3.0-rc.3-amd64 ]]
    assert "$(cat "$DUCTOR_STATE_DIR/placements.json")" '.placements[] | select(.name=="copied-python") | .image=="build:vdm-opencode-python/0.3.0-rc.3-amd64"'
    ductor_vm create copied-python 2 4096 10 build:vdm-opencode-python/0.3.0-rc.3-amd64
    jq '.nodes[0].sourceProject=""' "$DUCTOR_STATE_DIR/config.json" > "$DUCTOR_STATE_DIR/config-next.json"
    mv "$DUCTOR_STATE_DIR/config-next.json" "$DUCTOR_STATE_DIR/config.json"
    ductor_vm create direct-python 2 4096 10 build:vdm-opencode-python/0.3.0-rc.3-amd64
    [[ $(cat "$DUCTOR_STATE_DIR/mock/launch-image") == build:vdm-opencode-python/0.3.0-rc.3-amd64 ]]
)
printf '%s\n' 'Inventory admission, reservations, retry, drain, offline, identity and ownership tests passed.'
