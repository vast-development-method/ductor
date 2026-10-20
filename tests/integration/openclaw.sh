#!/usr/bin/env bash
# Exercise the actual pinned OpenClaw image, without credentials or network.
# Build service-images/openclaw as ductor-openclaw:test before running this gate.
set -Eeuo pipefail
umask 077

ductor_repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ductor_image=${DUCTOR_OPENCLAW_TEST_IMAGE:-ductor-openclaw:test}
ductor_smoke=$(mktemp -d "${TMPDIR:-/tmp}/ductor-openclaw-smoke.XXXXXXXX")
ductor_gateway_container="ductor-openclaw-smoke-$$"
ductor_fixture_owner="$(id -u):$(id -g)"
ductor_chown=(chown)
if [[ $(id -u) != 0 ]]; then
  ductor_chown=(sudo -n chown)
fi
cleanup() {
  docker rm -f "$ductor_gateway_container" >/dev/null 2>&1 || true
  "${ductor_chown[@]}" -R "$ductor_fixture_owner" "$ductor_smoke" 2>/dev/null || true
  rm -rf -- "$ductor_smoke"
}
trap cleanup EXIT
export DUCTOR_SMOKE_ROOT="$ductor_smoke"
export PYTHONPATH="$ductor_repo/src:$ductor_repo/tests/unit${PYTHONPATH:+:$PYTHONPATH}"

command -v docker >/dev/null || { echo 'Docker is required for the native OpenClaw integration gate.' >&2; exit 1; }
docker image inspect "$ductor_image" >/dev/null

# These are real renderer outputs from the full deployment fixture. No native
# fields are rewritten for a more permissive test configuration.
python3 - <<'PY'
import copy
import json
import os
import secrets
import shutil
from pathlib import Path
from fixtures import complete_config
from ductor_core.openclaw import render_openclaw
from ductor_core.crabbox import wrapper

root = Path(os.environ["DUCTOR_SMOKE_ROOT"])
base = complete_config(root)
oauth = copy.deepcopy(base)
oauth["services"]["agents"]["provider_keys"] = {}
oauth["model_accounts"] = {"openai:work": {"provider": "openai", "mode": "oauth"}}
for agent in oauth["agents"]:
    agent["auth_profiles"] = ["openai:work"]
# Include the proxy and MCP branches so their generated keys are validated too.
team = copy.deepcopy(oauth)
team["services"]["agents"].update({
    "trusted_proxies": ["172.20.0.2"],
    "team": {"user_header": "x-auth-user", "required_headers": ["x-auth-verified"],
             "allow_users": ["owner@example.org"], "admin_users": ["owner@example.org"]},
    "mcp_servers": {"docs": {"url": "https://docs.invalid/mcp", "tools": ["search", "read_*"]}},
})
team["agents"][0]["mcp_servers"] = ["docs"]
for name, config in (("oauth", oauth), ("vault", base), ("team", team)):
    destination = root / name
    render_openclaw(config, destination)
    service = destination / "services" / "agents"
    shutil.copyfile(service / "openclaw.json", service / "state" / "openclaw.json")
    (destination / "auth").mkdir()
    (destination / "secrets").mkdir()
    (destination / "secrets" / "gateway-token").write_text(secrets.token_hex(32))
    (destination / "secrets" / "gateway-token").chmod(0o600)
    (destination / "bin").mkdir()
    path = destination / "bin" / "crabbox-workers"
    path.write_text(wrapper("workers"))
    path.chmod(0o700)
PY

# The production image owns its private home/cache as node1000. Exercise that
# exact identity, including ownership checks, rather than the CI runner's UID.
for variant in oauth vault team; do
  "${ductor_chown[@]}" -R 1000:1000 "$ductor_smoke/$variant"
done

ductor_options=(--rm --network none --cap-drop ALL --security-opt no-new-privileges:true
  --user 1000:1000
  --env HOME=/home/node --env OPENCLAW_HOME=/home/node
  --env OPENCLAW_STATE_DIR=/home/node/.openclaw
  --env OPENCLAW_CONFIG_DIR=/home/node/.openclaw
  --env OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json
  --env OPENCLAW_DISABLE_BONJOUR=1
  --env VAULT_ADDR=https://bao.invalid
  --env OPENCLAW_VAULT_AUTH_METHOD=token_file
  --env VAULT_TOKEN_FILE=/run/openbao/token)

native() {
  local variant=$1
  shift
  docker run "${ductor_options[@]}" \
    --mount "type=bind,src=$ductor_smoke/$variant/services/agents/state,dst=/home/node/.openclaw" \
    --mount "type=bind,src=$ductor_smoke/$variant/auth,dst=/home/node/.config/openclaw" \
    --mount "type=bind,src=$ductor_smoke/$variant/secrets,dst=/run/secrets,readonly" \
    --mount "type=bind,src=$ductor_smoke/$variant/bin,dst=/usr/local/lib/ductor,readonly" \
    --entrypoint node "$ductor_image" dist/index.js "$@"
}

native oauth --version > "$ductor_smoke/openclaw-version.txt"
docker run "${ductor_options[@]}" --entrypoint /usr/local/bin/crabbox \
  "$ductor_image" --version > "$ductor_smoke/crabbox-version.txt"
python3 - <<'PY'
import os
import re
from pathlib import Path
p = Path(os.environ["DUCTOR_SMOKE_ROOT"])
assert re.search(r"(?<![\d.])2026\.10\.5(?![\d.])", (p / "openclaw-version.txt").read_text()), "Unexpected OpenClaw version"
assert re.search(r"(?<![\d.])0\.79\.0(?![\d.])", (p / "crabbox-version.txt").read_text()), "Unexpected Crabbox version"
PY

for variant in oauth vault team; do
  echo "Validating native OpenClaw schema: $variant"
  if ! native "$variant" config validate --json > "$ductor_smoke/$variant-validation.json"; then
    cat "$ductor_smoke/$variant-validation.json" >&2
    exit 1
  fi
done

# Doctor imports modules without activation: no provider call, Vault request,
# worker lease, or network dependency is permitted by this test container.
native vault plugins doctor --json > "$ductor_smoke/plugins-doctor.json"
for plugin in crabbox memory-core memory-wiki vault; do
  native vault plugins inspect "$plugin" --runtime --json > "$ductor_smoke/plugin-$plugin.json"
done
python3 - <<'PY'
import json
import os
from pathlib import Path
root = Path(os.environ["DUCTOR_SMOKE_ROOT"])
for name in ("crabbox", "memory-core", "memory-wiki", "vault"):
    report = json.loads((root / f"plugin-{name}.json").read_text())
    plugin = report["plugin"]
    assert plugin["id"] == name, report
    assert plugin.get("imported") is True, f"Required plugin module was not imported: {name}"
    assert plugin.get("status") != "error", report
PY

# Verify the upstream CLI contract used by Ductor login and activation.
# --help never enrolls a profile or contacts an identity provider.
native oauth models auth --help > "$ductor_smoke/auth-help.txt"
native oauth models auth login --help > "$ductor_smoke/login-help.txt"
native oauth models auth order clear --help > "$ductor_smoke/order-help.txt"
native oauth models status --help > "$ductor_smoke/status-help.txt"
native oauth wiki --help > "$ductor_smoke/wiki-help.txt"
native oauth wiki ingest --help > "$ductor_smoke/wiki-ingest-help.txt"
python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ["DUCTOR_SMOKE_ROOT"])
login = (root / "login-help.txt").read_text()
auth = (root / "auth-help.txt").read_text()
for flag in ("--provider", "--profile-id", "--device-code", "--method"):
    assert flag in login, f"Native login does not advertise {flag}"
assert "--agent" in login + auth, "Native per-agent enrollment option is missing"
assert "--provider" in (root / "order-help.txt").read_text(), "Native auth order clear provider option is missing"
assert "--check" in (root / "status-help.txt").read_text(), "Native readiness check option is missing"
assert "--agent" in (root / "wiki-help.txt").read_text() + (root / "wiki-ingest-help.txt").read_text(), "Native wiki agent selection is missing"
PY

# Metadata alone must not satisfy the exact-account startup admission used by
# the Ansible role. This reads actual native state, not the rendered JSON.
native oauth models auth list --agent lead --provider openai --json > "$ductor_smoke/empty-auth.json"
python3 - <<'PY'
import json
import os
from pathlib import Path
report = json.loads((Path(os.environ["DUCTOR_SMOKE_ROOT"]) / "empty-auth.json").read_text())
assert report["agentId"] == "lead", report
assert report["profiles"] == [], "An unenrolled fixture unexpectedly contains credentials"
PY
set +e
native oauth models status --agent lead --json --check > "$ductor_smoke/not-ready.json" 2> "$ductor_smoke/not-ready.log"
ductor_status=$?
set -e
if [[ $ductor_status != 1 ]]; then
  echo "Native unenrolled-account readiness must exit 1; received $ductor_status." >&2
  cat "$ductor_smoke/not-ready.log" >&2
  exit 1
fi

# No inference and no secret values: prove the actual startup refuses a missing
# required Gateway secret. The timeout is a failure, not an accepted refusal.
set +e
timeout --signal=TERM --kill-after=5s 60s docker run "${ductor_options[@]}" \
  --name "$ductor_gateway_container" \
  --mount "type=bind,src=$ductor_smoke/oauth/services/agents/state,dst=/home/node/.openclaw" \
  --mount "type=bind,src=$ductor_smoke/oauth/auth,dst=/home/node/.config/openclaw" \
  --mount "type=bind,src=$ductor_smoke/oauth/bin,dst=/usr/local/lib/ductor,readonly" \
  "$ductor_image" node dist/index.js gateway --bind lan --port 18789 \
  > "$ductor_smoke/missing-secret.log" 2>&1
ductor_status=$?
set -e
if [[ $ductor_status == 0 || $ductor_status == 124 || $ductor_status == 137 ]]; then
  echo "Gateway did not promptly reject the missing required secret (exit $ductor_status)." >&2
  cat "$ductor_smoke/missing-secret.log" >&2
  exit 1
fi
python3 - <<'PY'
import os
from pathlib import Path
log = (Path(os.environ["DUCTOR_SMOKE_ROOT"]) / "missing-secret.log").read_text()
assert "gateway-token" in log or "gateway-auth" in log, "Startup failed for an unrelated reason, not the required Gateway secret:\n" + log
PY

echo 'Native OpenClaw schema, plugin loading, CLI contract, and credential rejection checks passed.'
