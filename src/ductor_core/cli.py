"""Ductor v2 interactive and automation entry point."""
from __future__ import annotations
import argparse
import copy
from datetime import datetime, timezone
import importlib
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from .config import empty_config, load_config, require_valid, validate
from .inventory import build_inventory, build_service_vm_inventory, save_inventory, verify_ssh_files
from .remote_lock import infrastructure_lock
from .util import check_private_file, private_dir, state_lock, write_private

BUNDLE = Path(os.environ.get("DUCTOR_BUNDLE", Path(__file__).resolve().parents[2]))


def version():
    return (BUNDLE / "VERSION").read_text().strip()


def parser():
    p = argparse.ArgumentParser(description="Ductor v2 — infrastructure deployment over verified SSH")
    p.add_argument("--version", action="version", version=version())
    p.add_argument("--state-dir", type=Path, default=Path(os.environ.get("DUCTOR_STATE_DIR", Path.home() / ".local/state/ductor")))
    p.add_argument("--config", type=Path, default=os.environ.get("DUCTOR_CONFIG"))
    commands = p.add_subparsers(dest="command")
    init = commands.add_parser("init", help="create private desired state without changing any host")
    init.add_argument("--name", default="company")
    commands.add_parser("setup", help="guided initial configuration or terminal management menu")
    commands.add_parser("menu", help="terminal management menu")
    commands.add_parser("validate", help="validate configuration, integration contracts and budgets")
    commands.add_parser("doctor", help="check local deployment tools and configuration")
    config = commands.add_parser("config").add_subparsers(dest="config_action", required=True)
    config.add_parser("show")
    config.add_parser("edit")
    config.add_parser("import").add_argument("file", type=Path)
    host = commands.add_parser("host").add_subparsers(dest="host_action", required=True)
    host.add_parser("list")
    host.add_parser("add")
    trust = host.add_parser("trust", help="enroll host key against an independently verified SHA256 fingerprint")
    trust.add_argument("--host", required=True)
    trust.add_argument("--fingerprint", required=True)
    monitor = commands.add_parser("monitor", help="poll live status only; deployed services do not depend on this process")
    monitor.add_argument("--host")
    monitor.add_argument("--service")
    monitor.add_argument("--interval", type=int, default=30, help="seconds between completed status polls (minimum 10)")
    monitor.add_argument("--once", action="store_true", help="perform one status poll and exit")
    bundle = commands.add_parser("bundle", help="move private controller configuration and keys between installations").add_subparsers(dest="bundle_action", required=True)
    export = bundle.add_parser("export")
    export.add_argument("--output", required=True, type=Path)
    export.add_argument("--include-recovery", action="store_true")
    bundle.add_parser("import").add_argument("archive", type=Path)
    for action in ("render", "plan", "deploy", "update", "preflight", "status", "restart", "backup", "activate", "bootstrap-workers", "bootstrap-services"):
        operation = commands.add_parser(action)
        operation.add_argument("--host")
        operation.add_argument("--service")
        if action == "deploy":
            operation.add_argument("--stage-only", action="store_true", help="prepare gateway files/image before native account sign-in; do not activate")
    credentials = commands.add_parser("credentials").add_subparsers(dest="credentials_action", required=True)
    credentials.add_parser("incus", help="create a private Incus client identity for one pool").add_argument("--pool", required=True)
    for action in ("bootstrap", "unseal", "provision"):
        credentials.add_parser(action).add_argument("--service")
    put = credentials.add_parser("put", help="write provider credentials to scoped OpenBao KV v2")
    put.add_argument("--service", required=True, help="OpenClaw gateway id")
    put.add_argument("--provider", required=True, help="Configured provider key reference")
    put.add_argument("--input-file", required=True, type=Path)
    login = commands.add_parser("login", help="native OpenClaw account sign-in over SSH")
    login.add_argument("--service", required=True)
    login.add_argument("--agent", required=True)
    login.add_argument("--provider", required=True)
    login.add_argument("--profile", required=True)
    update = commands.add_parser("self-update", help="install a chosen checksum-verified Ductor release")
    update.add_argument("--version", required=True)
    update.add_argument("--sha256", required=True)
    return p


def prompt(label, default=None, integer=False):
    suffix = f" [{default}]" if default is not None else ""
    value = input(f"{label}{suffix}: ").strip() or (str(default) if default is not None else "")
    if not value:
        raise ValueError(f"{label} is required")
    return int(value) if integer else value


def add_host(config, state):
    name = prompt("Host id", "control")
    if name in config["hosts"]:
        raise ValueError("Host already exists; use config edit to change its recorded settings")
    address = prompt("SSH hostname or IP")
    user = prompt("SSH deployment user", "deploy")
    roles = prompt("Host roles (services, incus or both)", "both")
    role_list = ["services", "incus"] if roles == "both" else [roles]
    config["hosts"][name] = {
        "address": address, "port": prompt("SSH port", 22, True), "user": user,
        "identity_file": prompt("Absolute private SSH key path", str(Path.home() / ".ssh/id_ed25519")),
        "known_hosts_file": str(state / "ssh" / f"{name}.known_hosts"),
        "become": prompt("Use sudo on this host? yes/no", "yes") == "yes",
        "data_root": prompt("Dedicated persistent host directory", "/srv/ductor"),
        "roles": role_list,
        "resources": {"cpus": prompt("Host CPU budget", 8, True), "memory_mib": prompt("Host RAM MiB", 16384, True),
                      "disk_gib": prompt("Host free disk GiB budget", 200, True),
                      "reserve_cpus": prompt("CPUs reserved for OS", 1, True),
                      "reserve_memory_mib": prompt("RAM MiB reserved for OS", 2048, True),
                      "reserve_disk_gib": prompt("Disk GiB reserved for OS", 20, True)}}
    return name


def setup(config, state):
    if config["hosts"]:
        raise ValueError("Use the management menu to edit existing infrastructure")
    print("Ductor setup saves references and budgets. Host changes require deploy.\n"
          "This basic wizard enrolls existing hosts. For a dedicated main-agent VM,\n"
          "start from examples/service-vm.example.json and follow docs/service-vm.md;\n"
          "bootstrap-services provisions that VM before ordinary service deployment.\n"
          "Have your SSH key, approved Incus image fingerprint and mTLS files available.")
    host = add_host(config, state)
    worker = host
    if "incus" not in config["hosts"][host]["roles"]:
        print("Enroll the Incus worker host next.")
        worker = add_host(config, state)
    services_host = host
    if "services" not in config["hosts"][host]["roles"]:
        print("Enroll the services host next.")
        services_host = add_host(config, state)
    pool = "workers"
    config["incus"]["pools"][pool] = {
        "host": worker, "address": prompt("Incus HTTPS endpoint", f"https://{config['hosts'][worker]['address']}:8443"),
        "project": "ductor-agents", "profile": "ductor-worker", "instance_type": "virtual-machine",
        "image_fingerprint": prompt("Approved Incus image fingerprint (64 hex characters)"),
        "image_source_project": prompt("Image source project", "default"),
        "worker_node_version": prompt("Node version verified inside the approved image", "24.16.0"),
        "allow_vm_lowlevel": True,
        "network": prompt("Initialized Incus bridge", "incusbr0"),
        "network_acl": prompt("Prepared worker ACL permitting gateway enrollment", "ductor-workers"),
        "storage_pool": prompt("Initialized Incus storage pool", "default"),
        "client_certificate_file": prompt("Incus client certificate absolute path"),
        "client_key_file": prompt("Incus client private key absolute path"),
        "server_certificate_file": prompt("Incus server certificate absolute path"),
        "cpus": prompt("Pool total CPU budget", 4, True), "memory_mib": prompt("Pool total RAM MiB", 8192, True),
        "disk_gib": prompt("Pool total disk GiB", 100, True),
        "instance_cpus": prompt("Per-VM CPU limit", 2, True), "instance_memory_mib": prompt("Per-VM RAM MiB", 4096, True),
        "instance_disk_gib": prompt("Per-VM root disk GiB", 40, True),
        "max_instances": prompt("Maximum simultaneously existing VMs", 2, True)}
    bao_url = prompt("Your OpenBao HTTPS origin")
    claw_url = prompt("Your OpenClaw HTTPS origin")
    config["services"] = {
        "openbao": {"kind": "openbao", "host": services_host, "enabled": True,
                    "image": "ghcr.io/openbao/openbao:2.7.1", "bind_address": "127.0.0.1", "port": 8200,
                    "url": bao_url, "cpus": 1, "memory_mib": 1024, "disk_gib": 20},
        "openclaw": {"kind": "openclaw", "host": services_host, "enabled": True,
                     "image": "ghcr.io/openclaw/openclaw:2026.10.5", "bind_address": "127.0.0.1", "port": 18789,
                     "url": claw_url, "cpus": 2, "memory_mib": 4096, "disk_gib": 40,
                     "required_pool": pool, "agents": ["coordinator", "worker", "reviewer"],
                     "trusted_proxies": [], "allowed_origins": [claw_url], "openbao_service": "openbao"}}
    model = prompt("Exact provider/model for your agents")
    provider = model.split("/", 1)[0]
    config["services"]["openclaw"]["provider_keys"] = {provider: f"gateways/openclaw/{provider}/apiKey"}
    config["agents"] = [{"id": aid, "name": aid.title(), "model": model, "runtime": "openclaw", "role": role,
                          "auth_profiles": [], "allow_agents": ["worker", "reviewer"] if role == "orchestrator" else []}
                         for aid, role in (("coordinator", "orchestrator"), ("worker", "worker"), ("reviewer", "reviewer"))]
    source = prompt("Company Markdown knowledge directory", str(state / "knowledge"))
    private_dir(source)
    constitution = Path(source) / "AGENTS.md"
    if not constitution.exists():
        print(f"Create {constitution} with your approved objectives and standards before deployment.")
    config["knowledge"] = {"source_dir": source}
    private_dir(state / "credentials")
    token_file = state / "credentials/gateway-token"
    if not token_file.exists():
        write_private(token_file, secrets.token_urlsafe(48) + "\n")
    config["credentials"] = {
        "gateway_token_files": {"openclaw": str(token_file)},
        "openbao_token_file": str(state / "credentials/operator-token"),
        "openbao_bootstrap_output_file": str(state / "credentials/openbao-recovery.json"),
        "openbao_unseal_file": str(state / "credentials/openbao-recovery.json"),
        "openbao_approles": {"openclaw": {"role_id_file": str(state / "credentials/openclaw-role-id"),
                                        "secret_id_file": str(state / "credentials/openclaw-secret-id")}}}
    print("Saved deployment inputs. Verify SSH fingerprints, company standards, proxy routing and approved worker image before deployment.")


def edit_config(config, config_path):
    editor = shlex.split(os.environ.get("EDITOR", "vi"))
    with tempfile.TemporaryDirectory(prefix="ductor-edit-") as directory:
        candidate = Path(directory) / "config.json"
        write_private(candidate, config)
        subprocess.run([*editor, str(candidate)], check=True)
        updated = load_config(candidate)
        # Drafts may be incomplete, but malformed/unknown fields should be visible.
        errors = validate(updated, integrations=False)
        if errors:
            print("Saved draft still needs:\n- " + "\n- ".join(errors))
        write_private(config_path, updated)
    return updated


def render(config, state, host=None, service=None, action=None):
    structural = validate(config, integrations=False)
    if structural:
        raise ValueError("Configuration is invalid:\n- " + "\n- ".join(structural))
    selected = copy.deepcopy(config)
    service_inventory = None
    if action == "bootstrap-services":
        service_inventory = build_service_vm_inventory(config, BUNDLE, state / "rendered", host, service)
        selected_ids = {vm["id"] for entry in service_inventory["all"]["children"]["ductor_hosts"]["hosts"].values()
                        for vm in entry["ductor_service_vms"]}
        selected["service_vms"] = {key: value for key, value in config.get("service_vms", {}).items() if key in selected_ids}
        # Only the structural service-VM contract applies during infrastructure
        # bootstrap. Model accounts and company documents are provisioned later.
    elif action == "bootstrap-workers":
        if service:
            raise ValueError("bootstrap-workers selects worker hosts with --host; --service is not supported")
        selected["services"] = {}
        selected["credentials"] = {}
        selected["agents"] = []
        selected["knowledge"] = {}
        selected["service_vms"] = {}
        if host:
            selected["incus"]["pools"] = {key: pool for key, pool in config["incus"]["pools"].items() if pool["host"] == host}
            selected["incus"]["bootstrap"] = {key: value for key, value in config["incus"].get("bootstrap", {}).items() if key == host}
        if not selected["incus"]["pools"]:
            raise ValueError("No worker pools selected for bootstrap")
    elif service or host:
        chosen = {key: value for key, value in config["services"].items() if (not service or key == service) and (not host or value["host"] == host)}
        selected["services"] = copy.deepcopy(chosen)
        needed = set()
        for value in chosen.values():
            if value["kind"] == "openclaw":
                needed.add(value["required_pool"])
                if value.get("provider_keys") or value.get("openbao_service"):
                    baoid = value.get("openbao_service")
                    matches = {k: v for k, v in config["services"].items() if v["kind"] == "openbao" and v["enabled"] and (not baoid or k == baoid)}
                    selected["services"].update(copy.deepcopy(matches))
        selected["incus"]["pools"] = {key: pool for key, pool in config["incus"]["pools"].items() if key in needed or (not service and pool["host"] == host)}
        pool_hosts = {pool["host"] for pool in selected["incus"]["pools"].values()}
        selected["incus"]["bootstrap"] = {key: value for key, value in config["incus"].get("bootstrap", {}).items() if key in pool_hosts}
        guest_hosts = {value["host"] for value in selected["services"].values()}
        selected["service_vms"] = {key: value for key, value in config.get("service_vms", {}).items() if value["guest_host"] in guest_hosts}
    if action != "bootstrap-services":
        require_valid(selected)
    private_dir(state)
    stage = Path(tempfile.mkdtemp(prefix="render-", dir=state))
    final = state / "rendered"
    try:
        for name in (("service_vm",) if action == "bootstrap-services" else ("openclaw", "crabbox", "openbao", "service_vm")):
            module = importlib.import_module(f"ductor_core.{name}")
            getattr(module, f"render_{name}")(config if name == "service_vm" and action != "bootstrap-services" else selected, stage)
        inventory = service_inventory or build_inventory(config, BUNDLE, final, host, service)
        if action == "bootstrap-workers":
            entries = inventory["all"]["children"]["ductor_hosts"]["hosts"]
            worker_entries = {key: value for key, value in entries.items() if value["ductor_pools"]}
            for value in worker_entries.values():
                value["ductor_services"] = []
            inventory["all"]["children"]["ductor_hosts"]["hosts"] = worker_entries
        save_inventory(inventory, stage)
        for path in stage.rglob("*"):
            if path.is_symlink():
                raise ValueError("Rendered bundle must not contain symlinks")
            path.chmod(0o700 if path.is_dir() else 0o600)
        previous = state / "rendered.previous"
        if final.is_symlink() or previous.is_symlink():
            raise ValueError("Refusing symlink render directories")
        if previous.exists():
            shutil.rmtree(previous)
        if final.exists():
            final.rename(previous)
        stage.rename(final)
        return final, inventory
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def record(state, command, result, **metadata):
    event = {"time": datetime.now(timezone.utc).isoformat(), "version": version(), "operation": command, "result": result, **metadata}
    path = state / "last-operation.json"
    write_private(path, event)


def monitor(config_path, state, interval=30, host=None, service=None, once=False):
    """Reload saved state for each observation; never reconcile or repair hosts."""
    if not 10 <= interval <= 3600:
        raise ValueError("Monitoring interval must be between 10 and 3600 seconds")
    while True:
        code = 1
        try:
            with state_lock(state):
                try:
                    config = load_config(config_path)
                    code = operation(config, state, "status", host, service)
                except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
                    print(f"Monitoring observation failed: {error}", file=sys.stderr, flush=True)
                write_private(state / "monitor-status.json", {
                    "observed_at": datetime.now(timezone.utc).isoformat(),
                    "result": "passed" if code == 0 else "failed", "returncode": code,
                    "host": host, "service": service, "remote_changes": False})
        except (ValueError, OSError) as error:
            print(f"Monitoring poll deferred: {error}", file=sys.stderr, flush=True)
        if once:
            return code
        # No local or remote lock is retained while waiting. Other controllers
        # and native services continue independently when this process exits.
        time.sleep(interval)


def operation(config, state, action, host=None, service=None, stage_only=False):
    if action == "activate" and service and config["services"].get(service, {}).get("kind") != "openclaw":
        raise ValueError("activate --service must select an OpenClaw gateway")
    if action in ("status", "restart", "backup"):
        errors = validate(config, integrations=False)
        if errors:
            raise ValueError("\n".join(errors))
        rendered = private_dir(state / "operations")
        inventory = build_inventory(config, BUNDLE, rendered, host, service)
        save_inventory(inventory, rendered)
    else:
        rendered, inventory = render(config, state, host, service, action)
    if action in ("render", "plan"):
        if action == "plan":
            print(json.dumps({"version": version(), "transport": "verified SSH", "hosts": {
                name: {"address": entry["ansible_host"], "services": [{"id": s["id"], "image": s["image"], "url": s["url"]} for s in entry["ductor_services"]],
                       "pools": [{"id": pool["id"], "max_instances": pool["max_instances"], "project": pool["project"]} for pool in entry["ductor_pools"]],
                       "service_vms": [{"id": vm["id"], "guest_host": vm["guest_host"], "project": vm["project"]} for vm in entry["ductor_service_vms"]],
                       "resources": entry["ductor_host"]["resources"]}
                for name, entry in inventory["all"]["children"]["ductor_hosts"]["hosts"].items()},
                "rendered": str(rendered), "host_changes": False}, indent=2))
        else:
            print(f"Rendered deployment: {rendered}")
        return 0
    verify_ssh_files(inventory)
    if action in ("deploy", "update", "activate"):
        for entry in inventory["all"]["children"]["ductor_hosts"]["hosts"].values():
            for service_entry in entry["ductor_services"]:
                if service_entry["kind"] != "openclaw":
                    continue
                sid = service_entry["id"]
                token = service_entry.get("gateway_token_file") or config.get("credentials", {}).get("gateway_token_files", {}).get(sid)
                if not token:
                    raise ValueError(f"Configure a private gateway_token_files reference for {sid}")
                check_private_file(token)
                pool = config["incus"]["pools"][service_entry["required_pool"]]
                check_private_file(pool["client_key_file"])
                if service_entry.get("provider_keys") or service_entry.get("openbao_service"):
                    refs = config.get("credentials", {}).get("openbao_approles", {}).get(sid, {})
                    for field in ("role_id_file", "secret_id_file"):
                        if not refs.get(field):
                            raise ValueError(f"Provision OpenBao AppRole credential references for {sid}")
                        check_private_file(refs[field])
    executable = shutil.which("ansible-playbook")
    if not executable:
        sibling = Path(sys.executable).parent / "ansible-playbook"
        if sibling.exists():
            executable = str(sibling)
    if not executable:
        raise ValueError("ansible-playbook is missing; install the pinned Ductor release dependencies")
    playbook = ("service-vms.yml" if action == "bootstrap-services" else
                "site.yml" if action in ("plan", "deploy", "update", "preflight", "activate", "bootstrap-workers") else "operations.yml")
    argv = [executable, "-i", str(rendered / "inventory.json"), str(BUNDLE / "ansible" / playbook),
            "--extra-vars", json.dumps({"ductor_action": action, "ductor_activate": not stage_only})]
    temporary = private_dir(state / "ansible-tmp")
    controls = private_dir(state / "ssh-control")
    env = dict(os.environ, ANSIBLE_CONFIG=str(BUNDLE / "ansible/ansible.cfg"), ANSIBLE_HOST_KEY_CHECKING="True",
               ANSIBLE_HOME=str(private_dir(state / "ansible")), ANSIBLE_LOCAL_TEMP=str(temporary), ANSIBLE_SSH_CONTROL_PATH_DIR=str(controls))
    record(state, action, "running", host=host, service=service)
    if action in ("deploy", "update", "activate", "bootstrap-workers", "bootstrap-services", "restart", "backup"):
        with infrastructure_lock(inventory) as held:
            result = held.run(argv, env=env, cwd=BUNDLE, check=False)
    else:
        result = subprocess.run(argv, env=env, cwd=BUNDLE, check=False)
    record(state, action, "passed" if result.returncode == 0 else "failed", returncode=result.returncode, host=host, service=service)
    if result.returncode == 0 and action in ("deploy", "update"):
        print("Deployment reconciled. Run preflight and activate; live production qualification remains required.")
    if result.returncode == 0 and action == "bootstrap-services":
        print("Service VMs provisioned. Enroll each guest SSH key using the fingerprint reported through its verified hypervisor, then deploy services.")
    return result.returncode


def trust_host(config, state, name, fingerprint):
    import re
    if name not in config["hosts"]:
        raise ValueError(f"Unknown host: {name}")
    if not re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", fingerprint):
        raise ValueError("Expected independently verified SHA256 SSH host-key fingerprint")
    host = config["hosts"][name]
    scan = subprocess.run(["ssh-keyscan", "-T", "10", "-p", str(host["port"]), host["address"]], capture_output=True, text=True, check=False)
    matched = []
    with tempfile.TemporaryDirectory(prefix="ductor-hostkey-") as directory:
        for line in scan.stdout.splitlines():
            if not line or line.startswith("#"):
                continue
            candidate = Path(directory) / "host-key"
            candidate.write_text(line + "\n")
            result = subprocess.run(["ssh-keygen", "-l", "-E", "sha256", "-f", str(candidate)], capture_output=True, text=True, check=False)
            if result.returncode == 0 and fingerprint in result.stdout.split():
                matched.append(line)
    if not matched:
        raise ValueError("Scanned host keys do not match the verified fingerprint; nothing was trusted")
    trust_path = Path(host["known_hosts_file"])
    retained = []
    if trust_path.exists():
        if trust_path.is_symlink() or not trust_path.is_file():
            raise ValueError("Existing SSH trust must be a regular file")
        existing = trust_path.read_text().splitlines()
        lookup_name = host["address"] if host["port"] == 22 else f"[{host['address']}]:{host['port']}"
        found = subprocess.run(["ssh-keygen", "-F", lookup_name, "-f", str(trust_path)], capture_output=True, text=True, check=False)
        if found.returncode not in (0, 1):
            raise ValueError("Existing SSH trust file could not be inspected; nothing changed")
        replaced = {line for line in found.stdout.splitlines() if line and not line.startswith("#")}
        retained = [line for line in existing if line not in replaced]
    write_private(trust_path, "\n".join(retained + matched) + "\n")
    print(f"Verified SSH host key saved for {name}")


def native_login(config, state, service_id, agent_id, provider, profile):
    rendered, inventory = render(config, state, service=service_id)
    verify_ssh_files(inventory)
    manifest = json.loads((rendered / "services" / service_id / "activation.json").read_text())
    candidates = [item for item in manifest.get("enrollment", []) if item["agent"] == agent_id and item["profile"] == profile]
    if len(candidates) != 1 or config["model_accounts"][profile]["provider"] != provider:
        raise ValueError("Requested login is not an explicitly configured agent/account/provider binding")
    service = config["services"][service_id]
    host = config["hosts"][service["host"]]
    compose = str(Path(host["data_root"]) / "services" / service_id / "compose.yaml")
    remote = (["sudo", "-n"] if host["become"] else []) + ["docker", "compose", "-f", compose, "run", "--rm", "--no-deps", "--entrypoint", "node", "gateway", "dist/index.js", *candidates[0]["argv"]]
    ssh = ["ssh", "-tt", "-p", str(host["port"]), "-i", host["identity_file"], "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "UserKnownHostsFile=" + host["known_hosts_file"], f"{host['user']}@{host['address']}", shlex.join(remote)]
    stop = (["sudo", "-n"] if host["become"] else []) + ["docker", "compose", "-f", compose, "stop", "--timeout", "30", "gateway"]
    with infrastructure_lock(inventory) as held:
        stopped = held.run([*ssh[:-1], shlex.join(stop)], check=False)
        if stopped.returncode:
            return stopped.returncode
        result = held.run(ssh, check=False)
    print("Gateway remains stopped. Run activate after account enrollment to verify the exact binding.")
    return result.returncode


def incus_identity(config, pool_id):
    pool = config.get("incus", {}).get("pools", {}).get(pool_id)
    if not pool:
        raise ValueError("Unknown Incus pool")
    certificate, key = Path(pool["client_certificate_file"]), Path(pool["client_key_file"])
    if certificate == key:
        raise ValueError("Client certificate and key must have distinct paths")
    for path in (certificate, key):
        if not path.is_absolute() or path.exists() or path.is_symlink():
            raise ValueError("New client identity paths must be absolute and absent; refusing to replace credentials")
        private_dir(path.parent)
    with tempfile.TemporaryDirectory(prefix="ductor-incus-") as temporary:
        temporary = Path(temporary)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-keyout", str(temporary / "key"),
                        "-out", str(temporary / "certificate"), "-days", "365", "-subj", f"/CN=ductor-{pool_id}"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        write_private(key, (temporary / "key").read_text())
        write_private(certificate, (temporary / "certificate").read_text())
    print("Created Incus client identity; bootstrap-workers/deploy enrolls it only in the selected project")


def menu(config, state, config_path=None):
    config_path = config_path or state / "config.json"
    actions = {"3": "validate", "4": "plan", "5": "deploy", "6": "status", "7": "preflight", "8": "backup", "9": "activate", "10": "update"}
    while True:
        print("\nDuctor v2\n1 Edit saved configuration  2 Add SSH host\n3 Validate  4 Plan  5 Deploy  6 Status\n7 Preflight  8 Backup  9 Activate  10 Update services\n0 Exit")
        choice = input("Select: ").strip()
        if choice == "0":
            return
        try:
            if choice == "1":
                config = edit_config(config, config_path)
            elif choice == "2":
                add_host(config, state)
                write_private(config_path, config)
            elif choice == "3":
                require_valid(config)
                print("Configuration valid")
            elif choice in actions:
                operation(config, state, actions[choice])
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            print(f"Blocked: {error}", file=sys.stderr)


def main(argv=None):
    args = parser().parse_args(argv)
    state = args.state_dir.expanduser().absolute()
    path = (args.config or state / "config.json").expanduser().absolute()
    command = args.command or "menu"
    try:
        if command == "monitor":
            return monitor(path, state, args.interval, args.host, args.service, args.once)
        with state_lock(state):
            if command == "self-update":
                if os.environ.get("DUCTOR_CONTAINER") == "1":
                    raise ValueError("Update the controller container by selecting a new pinned DUCTOR_IMAGE and recreating it; state bind mounts are retained")
                return subprocess.run([str(BUNDLE / "install.sh"), "--version", args.version, "--sha256", args.sha256], check=False).returncode
            if command == "init":
                if path.exists():
                    raise ValueError(f"Configuration already exists: {path}")
                write_private(path, empty_config(args.name))
                print(f"Created private draft: {path}; run setup to configure infrastructure")
                return 0
            if command == "bundle":
                from .bundle import export_bundle, import_bundle
                if args.bundle_action == "import":
                    result = import_bundle(args.archive.expanduser().absolute(), state, path)
                else:
                    result = export_bundle(load_config(path), state, args.output.expanduser().absolute(), args.include_recovery)
                print(json.dumps(result, indent=2))
                return 0
            if command == "config" and args.config_action == "import":
                config = load_config(args.file)
                require_valid(config)
                write_private(path, config)
                print("Validated configuration imported")
                return 0
            if command in ("setup", "menu") and not path.exists():
                config = empty_config()
                setup(config, state)
                write_private(path, config)
                return 0
            config = load_config(path)
            if command == "setup":
                if config["hosts"]:
                    menu(config, state, path)
                else:
                    setup(config, state)
                    write_private(path, config)
            elif command == "menu":
                menu(config, state, path)
            elif command == "config":
                if args.config_action == "show":
                    print(json.dumps(config, indent=2))
                else:
                    edit_config(config, path)
            elif command == "host":
                if args.host_action == "list":
                    print(json.dumps(config["hosts"], indent=2))
                elif args.host_action == "add":
                    add_host(config, state)
                    write_private(path, config)
                else:
                    # Validate host syntax before using it in SSH argv.
                    host_errors = [e for e in validate(config, integrations=False) if e.startswith("hosts.")]
                    if host_errors:
                        raise ValueError("\n".join(host_errors))
                    trust_host(config, state, args.host, args.fingerprint)
            elif command == "validate":
                require_valid(config)
                print("Configuration valid; this is not a live qualification result")
            elif command == "doctor":
                missing = [name for name in ("ssh", "ssh-keyscan", "ssh-keygen", "ansible-playbook") if not shutil.which(name)]
                errors = validate(config)
                print(json.dumps({"version": version(), "missing_local_tools": missing, "configuration_errors": errors}, indent=2))
                return 1 if missing or errors else 0
            elif command == "credentials":
                from . import openbao
                if args.credentials_action == "incus":
                    incus_identity(config, args.pool)
                else:
                    errors = validate(config, integrations=False)
                    if errors:
                        raise ValueError("\n".join(errors))
                    selected_bao = args.service
                    if args.credentials_action == "put":
                        gateway = config["services"].get(args.service, {})
                        if gateway.get("kind") != "openclaw":
                            raise ValueError("Provider credentials require an OpenClaw gateway")
                        selected_bao = gateway.get("openbao_service")
                    bao_id, _ = openbao._select(config, selected_bao)
                    inventory = build_inventory(config, BUNDLE, state / "operations", service_filter=bao_id)
                    verify_ssh_files(inventory)
                    with infrastructure_lock(inventory) as held:
                        held.assert_held()
                        if args.credentials_action == "put":
                            result = openbao.put_secret(config, args.service, args.provider, str(args.input_file))
                        else:
                            operation_name = {"bootstrap": "bootstrap", "unseal": "unseal", "provision": "provision_credentials"}[args.credentials_action]
                            result = getattr(openbao, operation_name)(config, service_id=args.service)
                        held.assert_held()
                    print(json.dumps(result, indent=2))
            elif command == "login":
                return native_login(config, state, args.service, args.agent, args.provider, args.profile)
            else:
                return operation(config, state, command, getattr(args, "host", None), getattr(args, "service", None), getattr(args, "stage_only", False))
        return 0
    except KeyboardInterrupt:
        print("Interrupted; inspect status before retrying.", file=sys.stderr)
        return 130
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Ductor: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
