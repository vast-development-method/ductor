#!/usr/bin/env python3
"""Exercise pinned OpenBao and the actual bundled OpenClaw Vault resolver.

The fixture uses HTTP only on a private Docker network/loopback ephemeral port.
It does not qualify operator TLS ingress, remote hosts, model inference, or HA.
No fixture credentials or resolved values are printed, even on failure.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener

from ductor_core.openbao import OPENBAO_IMAGE, render_openbao

SECRETS = {"fixture-only-api-key-v1", "fixture-only-api-key-v2", "fixture-other-gateway"}
PHASE = "fixture setup"


def progress(phase):
    global PHASE
    PHASE = phase
    print(f"OpenBao integration: {phase}", flush=True)


def safe_text(value):
    for secret in sorted(SECRETS, key=len, reverse=True):
        if secret:
            value = value.replace(secret, "[REDACTED]")
    return re.sub(r"\b(?:hvs|hvb|hvr|s|b|r)\.[A-Za-z0-9_-]{12,}", "[REDACTED-TOKEN]", value)


def diagnostics(label):
    """Show bounded native process state/logs, never env or HTTP response bodies."""
    try:
        result = subprocess.run(["docker", "ps", "-a", "--filter", "label=io.ductor.integration=" + label,
                                 "--format", "{{.ID}} {{.Names}} {{.Status}}"],
                                capture_output=True, text=True, timeout=10)
        print("Native fixture containers:\n" + safe_text(result.stdout), file=sys.stderr)
        for line in result.stdout.splitlines():
            container_id = line.split()[0]
            if not re.fullmatch(r"[a-f0-9]{12,64}", container_id):
                continue
            logs = subprocess.run(["docker", "logs", "--tail", "60", container_id],
                                  capture_output=True, text=True, timeout=10)
            print(f"Native log tail ({container_id}):\n" + safe_text((logs.stdout + logs.stderr)[-14000:]), file=sys.stderr)
    except Exception:
        print("Native container diagnostics unavailable", file=sys.stderr)


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(argv, *, input=None, ok=True):
    result = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=90)
    if ok:
        if result.returncode != 0:
            print(safe_text(result.stderr[-3000:]), file=sys.stderr)
        check(result.returncode == 0, f"Native container command failed in {PHASE} (exit {result.returncode}; stdout withheld)")
    return result


def wait_for(probe, message, seconds=45):
    deadline = time.monotonic() + seconds
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = probe()
            if result:
                return result
        except (URLError, OSError, ValueError, RuntimeError) as error:
            last_error = error
        time.sleep(0.5)
    detail = f"; last diagnostic: {safe_text(str(last_error))}" if last_error else ""
    raise RuntimeError(message + detail)


def main():
    work, label, gateway_image = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    progress("verify pinned images")
    run(["docker", "image", "inspect", gateway_image])
    run(["docker", "pull", OPENBAO_IMAGE])
    uid, gid = os.getuid() or 1000, os.getgid() or 1000
    host_root = work / "host"
    server_root = host_root / "services/bao"
    for name in ("data", "audit", "backups"):
        path = server_root / name
        path.mkdir(parents=True, mode=0o700)
        if os.getuid() == 0:
            os.chown(path, uid, gid)
    config = {
        "hosts": {"test": {"data_root": str(host_root)}},
        "services": {
            "bao": {"kind": "openbao", "host": "test", "url": "https://bao.fixture.invalid",
                    "image": OPENBAO_IMAGE, "uid": uid, "gid": gid},
            "gateway": {"kind": "openclaw", "host": "test", "openbao_service": "bao",
                        "uid": uid, "gid": gid,
                        "provider_keys": {"openai": "gateways/gateway/providers/openai/apiKey"}}},
        "credentials": {}}
    render_openbao(config, work / "rendered")
    rendered = work / "rendered/services/bao"
    (server_root / "server.hcl").write_bytes((rendered / "server.hcl").read_bytes())
    (server_root / "server.hcl").chmod(0o600)
    if os.getuid() == 0:
        os.chown(server_root / "server.hcl", uid, gid)
    compose_path = rendered / "compose.yaml"
    compose = json.loads(compose_path.read_text())
    compose["name"] = label
    compose["services"]["openbao"]["ports"] = ["127.0.0.1:0:8200"]
    compose["services"]["openbao"]["labels"] = {"io.ductor.integration": label}
    compose_path.write_text(json.dumps(compose))
    compose_cmd = ["docker", "compose", "--file", str(compose_path)]
    progress("start production-mode Raft server")
    run(compose_cmd + ["up", "--detach"])
    endpoint = run(compose_cmd + ["port", "openbao", "8200"]).stdout.strip()
    check(endpoint.startswith("127.0.0.1:"), "Fixture server must publish only on loopback")
    base_url = "http://" + endpoint
    network = label + "_default"

    # This fixture is deliberately loopback-only; do not route through CI proxies.
    http = build_opener(ProxyHandler({}))

    def api(method, route, *, token=None, data=None, codes=(200, 204), binary=False, timeout=30):
        headers = {"Content-Type": "application/json"}
        if token:
            SECRETS.add(token)
            headers["X-Vault-Token"] = token
        request = Request(base_url + "/v1/" + route, headers=headers, method=method,
                          data=None if data is None else json.dumps(data).encode())
        try:
            response = http.open(request, timeout=timeout)
        except HTTPError as error:
            response = error
        except (TimeoutError, URLError, OSError) as error:
            # Mutating init/unseal requests are never retried blindly.
            raise RuntimeError(f"OpenBao {method} {route}: transport failure ({type(error).__name__}, timeout {timeout}s)") from None
        with response:
            raw = response.read()
            check(response.status in codes, f"OpenBao {method} {route} failed (HTTP {response.status})")
        return raw if binary else (json.loads(raw) if raw else {})

    wait_for(lambda: api("GET", "sys/health", codes=(501,), timeout=3), "Production server did not become uninitialized")
    progress("initialize Raft (allow native initialization and leader election)")
    initialized = api("POST", "sys/init", data={"secret_shares": 1, "secret_threshold": 1}, timeout=60)
    # Single-share test fixture only; production renderer/operator defaults are 5/3.
    root_token = initialized["root_token"]
    unseal_key = initialized["keys_base64"][0]
    SECRETS.update([root_token, unseal_key])
    progress("unseal and wait for active leader")
    check(api("POST", "sys/unseal", data={"key": unseal_key})["sealed"] is False, "Initial native unseal failed")
    wait_for(lambda: api("GET", "sys/health", timeout=3), "Unsealed server did not become active")
    progress("provision native KV v2, policy, and scoped AppRole")
    api("POST", "sys/mounts/secret", token=root_token, data={"type": "kv", "options": {"version": "2"}})
    api("POST", "secret/data/gateways/gateway/providers/openai", token=root_token,
        data={"data": {"apiKey": "fixture-only-api-key-v1"}})
    api("POST", "secret/data/gateways/other/providers/openai", token=root_token,
        data={"data": {"apiKey": "fixture-other-gateway"}})
    api("POST", "sys/auth/approle", token=root_token, data={"type": "approle"})
    api("PUT", "sys/policies/acl/fixture-gateway", token=root_token,
        data={"policy": 'path "secret/data/gateways/gateway/*" { capabilities = ["read"] }'})
    api("POST", "auth/approle/role/fixture-gateway", token=root_token, data={
        "bind_secret_id": True, "secret_id_ttl": 0, "secret_id_num_uses": 0,
        "token_type": "service", "token_policies": ["fixture-gateway"],
        "token_ttl": "12s", "token_max_ttl": "36s", "token_num_uses": 0})
    role_id = api("GET", "auth/approle/role/fixture-gateway/role-id", token=root_token)["data"]["role_id"]
    secret_id = api("POST", "auth/approle/role/fixture-gateway/secret-id", token=root_token, data={})["data"]["secret_id"]
    SECRETS.update([role_id, secret_id])

    auth = work / "auth"
    sink = work / "sink"
    for directory in (auth, sink):
        directory.mkdir(mode=0o700)
        if os.getuid() == 0:
            os.chown(directory, uid, gid)
    for name, value in (("role-id", role_id), ("secret-id", secret_id)):
        path = auth / name
        path.write_text(value + "\n")
        path.chmod(0o400)
        if os.getuid() == 0:
            os.chown(path, uid, gid)
    agent_hcl = work / "agent.hcl"
    agent_hcl.write_text((work / "rendered/services/gateway/agent.hcl").read_text().replace(
        "https://bao.fixture.invalid", "http://openbao:8200"))
    agent_hcl.chmod(0o400)
    if os.getuid() == 0:
        os.chown(agent_hcl, uid, gid)
    agent = label + "-agent"
    progress("start native Agent and obtain private token sink")
    run(["docker", "run", "--detach", "--name", agent, "--label", "io.ductor.integration=" + label,
         "--network", network, "--user", f"{uid}:{gid}", "--cap-drop", "ALL",
         "--security-opt", "no-new-privileges:true", "--env", "SKIP_CHOWN=1",
         "--mount", f"type=bind,src={auth},dst=/etc/openbao/auth,readonly",
         "--mount", f"type=bind,src={sink},dst=/run/openbao",
         "--mount", f"type=bind,src={agent_hcl},dst=/etc/openbao/agent.hcl,readonly",
         OPENBAO_IMAGE, "bao", "agent", "-config=/etc/openbao/agent.hcl"])
    token_path = sink / "token"
    first_token = wait_for(lambda: token_path.read_text().strip(), "Agent did not write its token sink")
    SECRETS.add(first_token)
    check(token_path.stat().st_mode & 0o777 == 0o600, "Token sink permissions are not private")
    check(first_token != root_token, "Agent was given a root credential")
    first_lookup = api("GET", "auth/token/lookup-self", token=first_token)["data"]
    check("root" not in first_lookup["policies"], "AppRole token unexpectedly has root policy")
    # Check renewal before potentially slow Gateway-image startup/discovery.
    progress("verify token renewal past its initial 12-second lifetime")
    time.sleep(14)
    check(token_path.read_text().strip() == first_token, "Agent reauthenticated before the renewal assertion")
    check(api("GET", "auth/token/lookup-self", token=first_token)["data"]["ttl"] > 0,
          "Native Agent did not renew its short-lived service token")

    # Discover the real artifact in the image and require the matching manifest.
    progress("discover and invoke the bundled Vault resolver")
    discover = r'''
const fs=require('node:fs'), path=require('node:path');
const roots=[process.cwd(), '/app', '/usr/local/lib/node_modules/openclaw'];
const found=new Set();
function scan(dir,depth){
 if(depth>6||!fs.existsSync(dir))return;
 for(const e of fs.readdirSync(dir,{withFileTypes:true})){
  if(e.isSymbolicLink())continue;
  const p=path.join(dir,e.name);
  if(e.isFile()&&e.name==='vault-secret-ref-resolver.js'){
   const m=path.join(dir,'openclaw.plugin.json');
   if(fs.existsSync(m)){const j=JSON.parse(fs.readFileSync(m,'utf8'));
    if(j.id==='vault'&&j.secretProviderIntegrations?.vault?.args?.includes('./vault-secret-ref-resolver.js'))found.add(p);}
  } else if(e.isDirectory()&&!['node_modules','.git','.cache'].includes(e.name))scan(p,depth+1);
 }
}
for(const r of new Set(roots))scan(r,0);
if(found.size===0)throw new Error('Bundled Vault integration artifact not found');
process.stdout.write([...found].sort()[0]);
'''
    resolver = run(["docker", "run", "--rm", "--label", "io.ductor.integration=" + label,
                    "--entrypoint", "node", gateway_image, "-e", discover]).stdout.strip()
    check(resolver.startswith("/"), "Resolver discovery returned an invalid artifact path")
    read_id = "gateways/gateway/providers/openai/apiKey"
    denied_id = "gateways/other/providers/openai/apiKey"

    def resolve(ids, success=True):
        response = run(["docker", "run", "--rm", "--interactive", "--label", "io.ductor.integration=" + label, "--entrypoint", "node",
            "--network", network, "--user", f"{uid}:{gid}", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges:true", "--env", "VAULT_ADDR=http://openbao:8200",
            "--env", "OPENCLAW_VAULT_AUTH_METHOD=token_file", "--env", "VAULT_TOKEN_FILE=/run/openbao/token",
            "--env", "OPENCLAW_VAULT_KV_MOUNT=secret", "--env", "OPENCLAW_VAULT_KV_VERSION=2",
            "--mount", f"type=bind,src={sink},dst=/run/openbao,readonly", gateway_image, resolver],
            input=json.dumps({"protocolVersion": 1, "ids": ids}), ok=success)
        if not success:
            check(response.returncode != 0, "Resolver did not fail closed during sealed outage")
        return json.loads(response.stdout)

    resolved = resolve([read_id, denied_id])
    check(resolved["values"].get(read_id) == "fixture-only-api-key-v1", "Bundled resolver failed native KV v2 read")
    check(denied_id not in resolved["values"] and denied_id in resolved["errors"], "Gateway policy did not isolate another gateway")
    progress("verify native reauthentication and key rotation")
    wait_for(lambda: token_path.read_text().strip() != first_token,
             "Agent did not reauthenticate at the token max TTL", seconds=45)
    check(resolve([read_id])["values"].get(read_id) == "fixture-only-api-key-v1",
          "Resolver did not consume the rotated native token file")
    api("POST", "secret/data/gateways/gateway/providers/openai", token=root_token,
        data={"options": {"cas": 1}, "data": {"apiKey": "fixture-only-api-key-v2"}})
    check(resolve([read_id])["values"].get(read_id) == "fixture-only-api-key-v2",
          "Resolver did not load the new provider-key version on its next invocation")
    snapshot = api("GET", "sys/storage/raft/snapshot", token=root_token, binary=True)
    snapshot_file = work / "raft.snap"
    snapshot_file.write_bytes(snapshot)
    snapshot_file.chmod(0o600)
    check(snapshot_file.stat().st_size > 128, "Native Raft snapshot was empty")
    progress("verify native snapshot, sealed failure, and persistent restart")
    api("PUT", "sys/seal", token=root_token)
    failed = resolve([read_id], success=False)
    check(not failed.get("values"), "Resolver returned a secret from a sealed server")
    run(compose_cmd + ["restart", "openbao"])
    sealed = wait_for(lambda: api("GET", "sys/seal-status"), "Persistent server did not restart")
    check(sealed["initialized"] and sealed["sealed"], "Restart did not preserve initialization and seal state")
    api("POST", "sys/unseal", data={"key": unseal_key})
    wait_for(lambda: api("GET", "sys/health", timeout=3), "Restarted server did not become active")
    wait_for(lambda: resolve([read_id])["values"].get(read_id) == "fixture-only-api-key-v2",
             "Persistent secret or Agent recovery failed after server restart")
    pre_restart_token = token_path.read_text().strip()
    SECRETS.add(pre_restart_token)
    run(["docker", "restart", agent])
    wait_for(lambda: token_path.read_text().strip() != pre_restart_token,
             "Agent restart did not reauthenticate with its persisted AppRole")
    wait_for(lambda: resolve([read_id])["values"].get(read_id) == "fixture-only-api-key-v2",
             "Agent did not recover using persisted AppRole credentials")
    print("PASS: real OpenBao Raft, AppRole, Agent renewal/reauth, bundled Vault resolver, ACL denial, rotation, snapshot, sealed failure, persistent restart")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Never print native command output, HTTP payloads, or fixture credentials.
        print(f"FAIL in {PHASE}: {type(error).__name__}: {safe_text(str(error))}", file=sys.stderr)
        if len(sys.argv) > 2:
            diagnostics(sys.argv[2])
        raise SystemExit(1) from None
