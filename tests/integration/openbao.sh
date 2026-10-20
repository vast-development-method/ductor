#!/usr/bin/env bash
# Real containers and native APIs only; no external model/provider requests.
set -Eeuo pipefail
command -v docker >/dev/null
command -v python3 >/dev/null
docker compose version >/dev/null

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/ductor-bao-it.XXXXXX")
fixture_id="ductor-bao-$(basename "$fixture_dir" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  local ids
  ids=$(docker ps -aq --filter "label=io.ductor.integration=$fixture_id") || true
  if [[ -n $ids ]]; then
    # Every ID was obtained using the unique per-run label above.
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
  if [[ -f "$fixture_dir/rendered/services/bao/compose.yaml" ]]; then
    docker compose -f "$fixture_dir/rendered/services/bao/compose.yaml" down --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf -- "$fixture_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export PYTHONPATH="$repo_root/src${PYTHONPATH:+:$PYTHONPATH}"
python3 "$repo_root/tests/integration/bao_fixture.py" "$fixture_dir" "$fixture_id" \
  "${DUCTOR_OPENCLAW_TEST_IMAGE:-ductor-openclaw:test}"
