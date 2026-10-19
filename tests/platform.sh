#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${DUCTOR_PLATFORM_SOURCE:-$ROOT/src/ductor}
platform_fixture=$(mktemp -d)
trap 'rm -rf -- "$platform_fixture"' EXIT
export DUCTOR_STATE_DIR=$platform_fixture/state
mkdir -p "$DUCTOR_STATE_DIR" "$platform_fixture/api"
# shellcheck source=/dev/null
source "$SOURCE"
ductor_inventory_init
printf '%s\n' '{"restricted":"true","features.profiles":"true","features.networks":"false","features.images":"true"}' > "$platform_fixture/source-config.json"
jq -n '{id:"worker",remote:"worker",project:"ductor",sourceProject:"vdm-agents",cpu:4,memoryMiB:8192,diskGiB:80,maxAgents:2,profiles:["vdm-base","vdm-network"],pool:"default",role:"worker"}' > "$platform_fixture/node.json"
printf '%s\n' '[{"image":"build:vdm/1"}]' > "$platform_fixture/profiles.json"
platform_fingerprint=$(printf '%064d' 1)
ductor_incus_query() {
    local remote=$1 path=$2
    case "$remote $path" in
        'worker /1.0/projects/vdm-agents') jq '{config:.}' "$platform_fixture/source-config.json" ;;
        'worker /1.0/projects/ductor') [[ -f $platform_fixture/api/project.json ]] && cat "$platform_fixture/api/project.json" ;;
        'worker /1.0/profiles/vdm-base?project=vdm-agents') printf '%s\n' '{"description":"approved","config":{"security.secureboot":"true"},"devices":{"root":{"type":"disk","path":"/","pool":"default"}}}' ;;
        'worker /1.0/profiles/vdm-network?project=vdm-agents') printf '%s\n' '{"description":"approved","config":{},"devices":{"eth0":{"type":"nic","network":"approved"}}}' ;;
        'worker /1.0/profiles/vdm-base?project=ductor') [[ -f $platform_fixture/api/vdm-base.json ]] && cat "$platform_fixture/api/vdm-base.json" ;;
        'worker /1.0/profiles/vdm-network?project=ductor') [[ -f $platform_fixture/api/vdm-network.json ]] && cat "$platform_fixture/api/vdm-network.json" ;;
        'build /1.0/images/aliases/vdm%2F1?project=vdm-agents') jq -n --arg fingerprint "$platform_fingerprint" '{target:$fingerprint}' ;;
        'worker /1.0/images/aliases/vdm%2F1?project=ductor') [[ -f $platform_fixture/api/image.json ]] && cat "$platform_fixture/api/image.json" ;;
        *) printf 'Unexpected query: %s %s\n' "$remote" "$path" >&2; return 1 ;;
    esac
}
incus() {
    printf '%s %s\n' "$1" "$2" >> "$platform_fixture/calls"
    case "$1 $2" in
        'query worker:/1.0/projects')
            [[ $3 == --request && $4 == POST && $5 == --data ]]
            jq -e '.config.restricted=="true" and .config["limits.cpu"]=="4" and .config["limits.memory"]=="8192MiB" and .config["limits.containers"]=="0" and .config["user.ductor.platform-source"]=="vdm-agents"' <<< "$6" >/dev/null
            printf '%s\n' "$6" > "$platform_fixture/api/project.json"
            ;;
        'query worker:/1.0/profiles?project=ductor')
            local name; name=$(jq -r .name <<< "$6")
            printf '%s\n' "$6" > "$platform_fixture/api/$name.json"
            ;;
        'image copy')
            [[ $3 == "build:$platform_fingerprint" && $4 == worker: && $* == *'--target-project ductor --alias vdm/1' ]]
            jq -n --arg fingerprint "$platform_fingerprint" '{target:$fingerprint}' > "$platform_fixture/api/image.json"
            ;;
        *) return 1 ;;
    esac
}
timeout() { shift; "$@"; }
ductor_platform_prepare_node "$platform_fixture/node.json" "$platform_fixture/profiles.json"
first=$(wc -l < "$platform_fixture/calls")
[[ $first == 4 ]]
ductor_platform_prepare_node "$platform_fixture/node.json" "$platform_fixture/profiles.json"
[[ $(wc -l < "$platform_fixture/calls") == "$first" ]]
jq '.config["limits.cpu"]="99"' "$platform_fixture/api/project.json" > "$platform_fixture/changed"
mv "$platform_fixture/changed" "$platform_fixture/api/project.json"
if (ductor_platform_prepare_node "$platform_fixture/node.json" "$platform_fixture/profiles.json") > "$platform_fixture/error" 2>&1; then
    printf 'Unapproved project drift was accepted\n' >&2; exit 1
fi
[[ $(wc -l < "$platform_fixture/calls") == "$first" ]]
jq '.config["limits.cpu"]="4"' "$platform_fixture/api/project.json" > "$platform_fixture/changed"
mv "$platform_fixture/changed" "$platform_fixture/api/project.json"
jq --arg other "$(printf '%064d' 2)" '.target=$other' "$platform_fixture/api/image.json" > "$platform_fixture/changed"
mv "$platform_fixture/changed" "$platform_fixture/api/image.json"
if (ductor_platform_prepare_node "$platform_fixture/node.json" "$platform_fixture/profiles.json") > "$platform_fixture/error" 2>&1; then
    printf 'Changed workload image alias was accepted\n' >&2; exit 1
fi
[[ $(wc -l < "$platform_fixture/calls") == "$first" ]]
jq '.sourceProject="ductor"' "$platform_fixture/node.json" > "$platform_fixture/unsafe.json"
if (ductor_platform_prepare_node "$platform_fixture/unsafe.json" "$platform_fixture/profiles.json") >/dev/null 2>&1; then exit 1; fi
printf 'Platform reuse, atomic quotas, immutable image fingerprint and project drift checks passed.\n'
