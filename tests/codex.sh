#!/usr/bin/env bash
# Offline pin/cache/archive tests and a deterministic Incus transport fixture.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export DUCTOR_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${DUCTOR_CODEX_SOURCE:-$ROOT/src/ductor}"
export DUCTOR_STATE_DIR
DUCTOR_STATE_DIR=$(mktemp -d)
trap 'rm -rf -- "$DUCTOR_STATE_DIR"' EXIT
ductor_die() { printf '%s\n' "$*" >&2; exit 1; }
ductor_log() { printf '%s\n' "$*" >&2; }
ductor_private_dir() { [[ ! -L $1 ]] || return 1; mkdir -p -- "$1"; chmod 700 "$1"; }
mkdir -p "$DUCTOR_STATE_DIR/fixture"
fixture=$DUCTOR_STATE_DIR/fixture
member=codex-x86_64-unknown-linux-musl
printf 'fixture bytes; never executed on the controller\n' > "$fixture/$member"
tar -czf "$fixture/source.tar.gz" -C "$fixture" "$member"
profile=$fixture/profile.json
lease=$fixture/lease.json
printf '{}\n' > "$lease"
make_profile() {
    local archive=$1 sha
    sha=$(sha256sum "$archive"); sha=${sha%% *}
    mkdir -p "$DUCTOR_STATE_DIR/cache/codex/$sha"
    cp -- "$archive" "$DUCTOR_STATE_DIR/cache/codex/$sha/artifact.tar.gz"
    chmod 600 "$DUCTOR_STATE_DIR/cache/codex/$sha/artifact.tar.gz"
    jq -n --arg sha "$sha" '{runtime:{uid:1000,command:"/usr/local/bin/codex",codexArtifact:{version:"0.163.0",sha256:$sha,url:"https://github.com/openai/codex/releases/download/rust-v0.163.0/codex-x86_64-unknown-linux-musl.tar.gz"}}}' > "$profile"
}
expect_failure() { if ( "$@" ) > "$fixture/failure.out" 2> "$fixture/failure.err"; then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi; }
curl() { printf 'Unexpected network call\n' >&2; return 91; }
make_profile "$fixture/source.tar.gz"
ductor_codex_artifact_validate "$profile" x86_64
cached=$(ductor_codex_artifact_cache "$profile" x86_64)
cmp "$cached" "$fixture/$member"
expect_failure ductor_codex_artifact_cache "$profile" aarch64
jq '.runtime.codexArtifact.url="https://example.org/codex.tar.gz"' "$profile" > "$fixture/wrong.json"
expect_failure ductor_codex_artifact_validate "$fixture/wrong.json" x86_64
jq '.runtime.codexArtifact.url += "?redirect=elsewhere"' "$profile" > "$fixture/wrong.json"
expect_failure ductor_codex_artifact_validate "$fixture/wrong.json" x86_64
jq '.runtime.command="/usr/bin/bash"' "$profile" > "$fixture/wrong.json"
expect_failure ductor_codex_artifact_validate "$fixture/wrong.json" x86_64
jq '.runtime.codexArtifact.version="latest"' "$profile" > "$fixture/wrong.json"
expect_failure ductor_codex_artifact_validate "$fixture/wrong.json" x86_64
sha=$(jq -r .runtime.codexArtifact.sha256 "$profile")
printf 'corrupted\n' >> "$DUCTOR_STATE_DIR/cache/codex/$sha/artifact.tar.gz"
expect_failure ductor_codex_artifact_cache "$profile" x86_64
make_profile "$fixture/source.tar.gz"
# A correct operator checksum does not authorize archive path/link extraction.
tar -czf "$fixture/wrong.tar.gz" -C "$fixture" lease.json
make_profile "$fixture/wrong.tar.gz"
expect_failure ductor_codex_artifact_cache "$profile" x86_64
mkdir "$fixture/symlink"
ln -s /etc/passwd "$fixture/symlink/$member"
tar -czf "$fixture/link.tar.gz" -C "$fixture/symlink" "$member"
make_profile "$fixture/link.tar.gz"
expect_failure ductor_codex_artifact_cache "$profile" x86_64
tar -czf "$fixture/path.tar.gz" --transform="s|^$member$|../$member|" -C "$fixture" "$member"
make_profile "$fixture/path.tar.gz"
expect_failure ductor_codex_artifact_cache "$profile" x86_64
make_profile "$fixture/source.tar.gz"
ductor_broker_location() { printf '%s\n' '{"remote":"local","project":"ductor","vm":"owned-vm","state":"Running"}'; }
timeout() { shift; "$@"; }
incus() {
    local action=$1; shift
    if [[ $action == file ]]; then
        [[ $1 == push ]] || return 1
        printf 'push\n' >> "$fixture/transport"
        return 0
    fi
    [[ $action == exec && $1 == local:owned-vm ]] || return 1
    shift
    while (($#)); do
        case "$1" in
            --project) [[ $2 == ductor ]] || return 1; shift 2 ;;
            --user|--group) [[ $2 == 1000 ]] || return 1; shift 2 ;;
            --cwd) [[ $2 == /tmp ]] || return 1; shift 2 ;;
            --) shift; break ;;
            *) return 1 ;;
        esac
    done
    case "$1" in
        id) printf '1000\n' ;;
        uname) if [[ $2 == -s ]]; then printf 'Linux\n'; else printf 'x86_64\n'; fi ;;
        /usr/local/bin/codex) [[ -f $fixture/installed ]] && cat "$fixture/installed" ;;
        /run/ductor-codex.ABC123xy/codex) printf 'codex-cli 0.163.0\n' ;;
        bash)
            cat > "$fixture/guest-script"
            if [[ $# == 2 ]]; then printf '/run/ductor-codex.ABC123xy\n'; else printf 'codex-cli 0.163.0\n' > "$fixture/installed"; fi
            ;;
        rm) [[ $* == 'rm -rf -- /run/ductor-codex.ABC123xy' ]] ;;
        *) printf 'Unexpected fixture command: %s\n' "$*" >&2; return 1 ;;
    esac
}
ductor_codex_prepare "$profile" "$lease"
[[ $(cat "$fixture/installed") == 'codex-cli 0.163.0' && $(wc -l < "$fixture/transport") == 1 ]]
# A matching CLI is reused, with no second transfer or authentication material.
ductor_codex_prepare "$profile" "$lease"
[[ $(wc -l < "$fixture/transport") == 1 ]]
jq 'del(.runtime.codexArtifact)' "$profile" > "$fixture/preinstalled.json"
ductor_codex_prepare "$fixture/preinstalled.json" "$lease"
rm "$fixture/installed"
expect_failure ductor_codex_prepare "$fixture/preinstalled.json" "$lease"
printf 'codex bootstrap tests passed\n'
