#!/usr/bin/env bash
# The native conversation helper enables one gate, verifies persisted state,
# preserves all other gates, and prints the authenticated company's own route.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FRAGMENT=${DUCTOR_CONVERSATION_SOURCE:-$ROOT/../ductor-conversation.part}
[[ -f $FRAGMENT ]] || FRAGMENT=$ROOT/src/ductor
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
DUCTOR_STATE_DIR=$TEST_ROOT
export DUCTOR_STATE_DIR
ductor_die() { printf '%s\n' "$*" >&2; exit 1; }
# shellcheck source=/dev/null
source "$FRAGMENT"
OPERATOR_OK=true
WRITE_OK=true
RETAIN_WRITE=true
WRONG_COMPANY=false
ductor_pc_load() {
    export DUCTOR_PC_URL=https://work.example.com
    DUCTOR_PC_COMPANY=11111111-1111-4111-8111-111111111111
}
ductor_pc_operator() { printf '%s\n' "$1" >> "$TEST_ROOT/operators"; [[ $OPERATOR_OK == true ]]; }
printf '%s\n' '{"enableAgentChat":false,"enablePublicMcp":false,"enableConferenceRoomChat":false,"someOtherGate":true}' > "$TEST_ROOT/settings"
ductor_pc_request() {
    local method=$1 path=$2 body=${3:-}
    printf '%s %s\n' "$method" "$path" >> "$TEST_ROOT/calls"
    case "$method $path" in
        'GET /api/instance/settings/experimental') cat "$TEST_ROOT/settings" ;;
        'PATCH /api/instance/settings/experimental')
            [[ $WRITE_OK == true ]] || return 77
            jq -e 'keys == ["enableAgentChat"] and .enableAgentChat == true' "$body" >/dev/null || return
            jq '.enableAgentChat=true' "$TEST_ROOT/settings" > "$TEST_ROOT/new-settings" || return
            cat "$TEST_ROOT/new-settings" || return
            if [[ $RETAIN_WRITE == true ]]; then mv "$TEST_ROOT/new-settings" "$TEST_ROOT/settings"; fi
            ;;
        "GET /api/companies/$DUCTOR_PC_COMPANY")
            if [[ $WRONG_COMPANY == true ]]; then printf '%s\n' '{"id":"other-company","issuePrefix":"OTHER"}'
            else jq -n --arg id "$DUCTOR_PC_COMPANY" '{id:$id,issuePrefix:"TEAM"}'; fi
            ;;
        *) printf 'Unexpected API fixture path\n' >&2; return 1 ;;
    esac
}
ductor_paperclip_conversation status > "$TEST_ROOT/output"
rg -q 'Agent Chat: disabled' "$TEST_ROOT/output"
! rg -q '^PATCH' "$TEST_ROOT/calls"
if ductor_paperclip_conversation open >/dev/null 2>&1; then exit 1; fi
if (OPERATOR_OK=false ductor_paperclip_conversation enable >/dev/null 2>&1); then exit 1; fi
! rg -q '^PATCH' "$TEST_ROOT/calls"
if (WRITE_OK=false ductor_paperclip_conversation enable >/dev/null 2>&1); then exit 1; fi
if (RETAIN_WRITE=false ductor_paperclip_conversation enable >/dev/null 2>&1); then exit 1; fi
jq -e '.enableAgentChat == false' "$TEST_ROOT/settings" >/dev/null
ductor_paperclip_conversation enable > "$TEST_ROOT/output"
jq -e '.enableAgentChat==true and .enablePublicMcp==false and .enableConferenceRoomChat==false and .someOtherGate==true' "$TEST_ROOT/settings" >/dev/null
rg -q 'https://work.example.com/TEAM/chats' "$TEST_ROOT/output"
[[ $(tail -n 1 "$TEST_ROOT/operators") == admin ]]
first=$(rg -c '^PATCH ' "$TEST_ROOT/calls")
ductor_paperclip_conversation enable > /dev/null
[[ $first == "$(rg -c '^PATCH ' "$TEST_ROOT/calls")" ]]
if (WRONG_COMPANY=true ductor_paperclip_conversation open >/dev/null 2>&1); then exit 1; fi
printf 'Native conversation gate, authority checks, persisted readback, and company route tests passed.\n'
