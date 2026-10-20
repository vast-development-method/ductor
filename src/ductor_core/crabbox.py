"""Render upstream Crabbox/Incus configuration; no lease or scheduling logic."""
from __future__ import annotations

import json
import ipaddress
import re
from pathlib import Path
from urllib.parse import urlsplit

CRABBOX_VERSION = "0.79.0"
CRABBOX_SHA256 = {
    "amd64": "fc4d8d04b1a596e8e5fdc6af7b0794d44f3f19c2f63153205b92d45ebc5f095b",
    "arm64": "f950990700bda55851233c185c2397dc978a2576b113ff5567962e5387d6dd31",
}
_NAME = re.compile(r"[a-z][a-z0-9-]{0,47}\Z")
_FINGERPRINT = re.compile(r"[a-f0-9]{64}\Z")
_POOL_KEYS = {"host", "address", "project", "profile", "network", "storage_pool", "network_acl",
              "image_source_project", "image_fingerprint", "image_import", "instance_type",
              "allow_vm_lowlevel", "worker_node_version", "client_certificate_file", "client_key_file",
              "server_certificate_file", "cpus", "memory_mib", "disk_gib", "instance_cpus",
              "instance_memory_mib", "instance_disk_gib", "max_instances"}
_BOOTSTRAP_KEYS = {"enabled", "package_version", "listen_address", "storage_driver", "storage_pool",
                   "network", "ipv4_address", "ipv4_nat", "network_acl", "ingress", "egress"}


def artifact(architecture: str) -> dict[str, str]:
    """Return an immutable release artifact and GitHub-published checksum."""
    architecture = {"x86_64": "amd64", "aarch64": "arm64"}.get(architecture, architecture)
    if architecture not in CRABBOX_SHA256:
        raise ValueError(f"Unsupported Crabbox architecture: {architecture}")
    name = f"crabbox_{CRABBOX_VERSION}_linux_{architecture}.tar.gz"
    return {"version": CRABBOX_VERSION, "url": f"https://github.com/openclaw/crabbox/releases/download/v{CRABBOX_VERSION}/{name}",
            "checksum": "sha256:" + CRABBOX_SHA256[architecture]}


def supported_node(version: str) -> bool:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if not match:
        return False
    major, minor, _ = map(int, match.groups())
    return major == 24 and minor >= 16 or major == 26 and minor >= 1 or major > 26


def validate_pools(config: dict) -> list[str]:
    """Validate explicit, operator-approved infrastructure inputs without I/O."""
    errors: list[str] = validate_bootstrap(config)
    pools = config.get("incus", {}).get("pools", {})
    if not isinstance(pools, dict):
        return ["incus.pools must be an object"]
    projects: set[tuple[str, str]] = set()
    for name, pool in pools.items():
        prefix = f"incus.pools.{name}"
        if not isinstance(pool, dict):
            errors.append(f"{prefix} must be an object")
            continue
        if set(pool) - _POOL_KEYS:
            errors.append(f"{prefix}: unsupported fields {sorted(set(pool) - _POOL_KEYS)}")
        for key, value in [("id", name)] + [(k, pool.get(k)) for k in ("project", "profile", "network", "storage_pool", "network_acl", "image_source_project")]:
            if not isinstance(value, str) or not _NAME.fullmatch(value):
                errors.append(f"{prefix}.{key} must be a lowercase infrastructure identifier")
        if pool.get("project") in {"default", "vdm-agents"}:
            errors.append(f"{prefix}.project must be a dedicated Ductor project, never default or vdm-agents")
        pair = (str(pool.get("host")), str(pool.get("project")))
        if pair in projects:
            errors.append(f"{prefix}.project must be unique on its host so quotas cannot overwrite another pool")
        projects.add(pair)
        if pool.get("host") not in config.get("hosts", {}):
            errors.append(f"{prefix}.host must reference a configured host")
        try:
            address = urlsplit(pool.get("address", ""))
            valid_address = address.scheme == "https" and bool(address.hostname) and not address.username and not address.password and address.path in ("", "/") and not address.query and not address.fragment
            _ = address.port
        except (ValueError, TypeError):
            valid_address = False
        if not valid_address:
            errors.append(f"{prefix}.address must be an authenticated HTTPS Incus endpoint")
        if pool.get("instance_type") != "virtual-machine":
            errors.append(f"{prefix}.instance_type must be virtual-machine for opencode-platform images")
        if not isinstance(pool.get("image_fingerprint"), str) or not _FINGERPRINT.fullmatch(pool["image_fingerprint"]):
            errors.append(f"{prefix}.image_fingerprint must be the approved 64-character Incus fingerprint")
        if pool.get("allow_vm_lowlevel") is not True:
            errors.append(f"{prefix}.allow_vm_lowlevel must explicitly acknowledge Crabbox volatile.uuid requirements; keep this authority on the Gateway")
        if not supported_node(str(pool.get("worker_node_version", ""))):
            errors.append(f"{prefix}.worker_node_version requires approved image Node 24.16+ or 26.1+; rebuild Node 22 opencode-platform images before deployment")
        for key in ("client_certificate_file", "client_key_file", "server_certificate_file"):
            value = pool.get(key)
            if not isinstance(value, str) or not Path(value).is_absolute() or ".." in Path(value).parts or any(c in value for c in "\n\r\x00"):
                errors.append(f"{prefix}.{key} must reference an absolute operator-supplied file")
        credential_paths = [pool.get(key) for key in ("client_certificate_file", "client_key_file", "server_certificate_file")]
        if all(isinstance(value, str) for value in credential_paths) and len(set(credential_paths)) != len(credential_paths):
            errors.append(f"{prefix}: client certificate, client key and server certificate require distinct file paths")
        image_import = pool.get("image_import")
        if image_import is not None:
            if not isinstance(image_import, dict) or set(image_import) != {"metadata_url", "metadata_sha256", "disk_url", "disk_sha256"}:
                errors.append(f"{prefix}.image_import requires metadata_url/metadata_sha256/disk_url/disk_sha256")
            else:
                for kind in ("metadata", "disk"):
                    try:
                        url = urlsplit(image_import[f"{kind}_url"])
                        valid = url.scheme == "https" and bool(url.hostname) and not url.username and not url.password
                    except (ValueError, TypeError):
                        valid = False
                    if not valid or not _FINGERPRINT.fullmatch(str(image_import[f"{kind}_sha256"])):
                        errors.append(f"{prefix}.image_import requires HTTPS and pinned SHA256 for {kind}")
        for key in ("cpus", "memory_mib", "disk_gib", "instance_cpus", "instance_memory_mib", "instance_disk_gib", "max_instances"):
            value = pool.get(key)
            if type(value) is not int or value <= 0:
                errors.append(f"{prefix}.{key} must be a positive integer")
        for instance, total in (("instance_cpus", "cpus"), ("instance_memory_mib", "memory_mib"), ("instance_disk_gib", "disk_gib")):
            if type(pool.get(instance)) is int and type(pool.get(total)) is int and pool[instance] > pool[total]:
                errors.append(f"{prefix}.{instance} exceeds the pool's {total} quota")
        bootstrap = config.get("incus", {}).get("bootstrap", {}).get(pool.get("host"), {})
        if bootstrap:
            for key in ("storage_pool", "network", "network_acl"):
                if pool.get(key) != bootstrap.get(key):
                    errors.append(f"{prefix}.{key} must match the explicit host bootstrap")
    return errors


def validate_bootstrap(config: dict) -> list[str]:
    errors = []
    entries = config.get("incus", {}).get("bootstrap", {})
    if not isinstance(entries, dict):
        return ["incus.bootstrap must be keyed by host identifier"]
    for host, entry in entries.items():
        prefix = f"incus.bootstrap.{host}"
        if not isinstance(host, str) or not _NAME.fullmatch(host) or host not in config.get("hosts", {}) or not isinstance(entry, dict):
            errors.append(f"{prefix} must describe a configured host")
            continue
        if set(entry) - _BOOTSTRAP_KEYS:
            errors.append(f"{prefix}: unsupported fields {sorted(set(entry) - _BOOTSTRAP_KEYS)}")
        if entry.get("enabled") is not True:
            errors.append(f"{prefix}.enabled must explicitly be true or omit bootstrap")
        if not re.fullmatch(r"[0-9][A-Za-z0-9.+:~_-]*", str(entry.get("package_version", ""))):
            errors.append(f"{prefix}.package_version must pin an approved distro Incus package")
        if entry.get("storage_driver") != "dir":
            errors.append(f"{prefix}.storage_driver must be dir; disk-formatting backends require separate approved provisioning")
        for key in ("storage_pool", "network", "network_acl"):
            if not _NAME.fullmatch(str(entry.get(key, ""))):
                errors.append(f"{prefix}.{key} is invalid")
        try:
            ipaddress.IPv4Interface(entry["ipv4_address"])
            listener = urlsplit("https://" + entry["listen_address"])
            if not listener.hostname or listener.port is None or listener.path or listener.username or listener.query or listener.fragment:
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            errors.append(f"{prefix} requires ipv4_address CIDR and listen_address host:port")
        if type(entry.get("ipv4_nat")) is not bool:
            errors.append(f"{prefix}.ipv4_nat must be a boolean")
        for direction in ("ingress", "egress"):
            rules = entry.get(direction)
            if not isinstance(rules, list) or not rules:
                errors.append(f"{prefix}.{direction} must explicitly allow required management/artifact routes")
                continue
            for rule in rules:
                allowed = {"action", "source", "destination", "protocol", "source_port", "destination_port", "state", "description"}
                if not isinstance(rule, dict) or set(rule) - allowed or rule.get("action") != "allow" or rule.get("protocol") not in {"tcp", "udp", "icmp4", "icmp6"}:
                    errors.append(f"{prefix}.{direction} must contain explicit allow rules with supported fields")
    return errors


def bootstrap_preseed(entry: dict) -> dict:
    return {"config": {"core.https_address": entry["listen_address"]},
            "networks": [{"name": entry["network"], "type": "bridge", "config": {
                "ipv4.address": entry["ipv4_address"], "ipv4.nat": str(entry["ipv4_nat"]).lower(), "ipv6.address": "none"}}],
            "storage_pools": [{"name": entry["storage_pool"], "driver": "dir", "config": {}}]}


def pool_profile(pool: dict) -> dict:
    return {"description": "Ductor OpenClaw worker; Crabbox owns its lifetime", "config": {
        "limits.cpu": str(pool["instance_cpus"]), "limits.memory": f"{pool['instance_memory_mib']}MiB",
        "security.secureboot": "true", "security.nesting": "false", "boot.autostart": "false",
    }, "devices": {
        "root": {"type": "disk", "path": "/", "pool": pool["storage_pool"], "size": f"{pool['instance_disk_gib']}GiB"},
        "eth0": {"type": "nic", "name": "eth0", "network": pool["network"],
                 "security.acls": pool["network_acl"], "security.acls.default.ingress.action": "reject",
                 "security.acls.default.egress.action": "reject", "security.ipv4_filtering": "true"},
    }}


def pool_project(name: str, pool: dict) -> dict:
    return {"description": f"Ductor managed worker pool {name}", "config": {
        "user.ductor.pool": name, "features.images": "true", "features.profiles": "true",
        "features.networks": "false", "features.storage.volumes": "true", "restricted": "true",
        "restricted.devices.disk": "managed", "restricted.devices.nic": "managed",
        "restricted.networks.access": pool["network"], "restricted.storage-pools.access": pool["storage_pool"],
        "restricted.devices.proxy": "block", "restricted.virtual-machines.lowlevel": "allow",
        "restricted.virtual-machines.nesting": "block", "restricted.snapshots": "block",
        "limits.containers": "0", "limits.instances": str(pool["max_instances"]),
        "limits.virtual-machines": str(pool["max_instances"]), "limits.cpu": str(pool["cpus"]),
        "limits.memory": f"{pool['memory_mib']}MiB", "limits.disk": f"{pool['disk_gib']}GiB",
        "images.auto_update_cached": "false",
    }}


def image_alias(pool: dict) -> str:
    # Crabbox's direct create path resolves an alias. Never use a mutable channel.
    return "ductor-" + pool["image_fingerprint"]


def wrapper(name: str) -> str:
    if not _NAME.fullmatch(name):
        raise ValueError("Invalid pool identifier")
    # A configuration selector only: argv, stdin, exit status, and signals pass
    # directly to upstream Crabbox. Ductor never stores a runtime lease.
    return f'''#!/bin/sh
set -eu
unset CRABBOX_INCUS_SOCKET CRABBOX_INCUS_REMOTE CRABBOX_INCUS_ADDRESS CRABBOX_INCUS_PROJECT
unset CRABBOX_INCUS_IMAGE CRABBOX_INCUS_PROFILE CRABBOX_INCUS_INSTANCE_TYPE
unset CRABBOX_INCUS_INSECURE_TLS CRABBOX_INCUS_TLS_SERVER_CERT CRABBOX_INCUS_REMOTE_IMAGE_SERVER
unset CRABBOX_INCUS_PROXY_LISTEN_PORT CRABBOX_INCUS_PROXY_LISTEN_HOST CRABBOX_INCUS_DELETE_ON_RELEASE
export CRABBOX_CONFIG=/etc/ductor/crabbox/{name}.yaml
export INCUS_CONF=/etc/ductor/incus/{name}
export XDG_STATE_HOME=/home/node/.local/state
exec /usr/local/bin/crabbox "$@"
'''


def render_crabbox(config: dict, output_dir: Path) -> list[Path]:
    errors = validate_pools(config)
    if errors:
        raise ValueError("\n".join(errors))
    paths = []
    for host, entry in config.get("incus", {}).get("bootstrap", {}).items():
        directory = Path(output_dir) / "incus" / "bootstrap" / host
        directory.mkdir(parents=True, exist_ok=True)
        for filename, data in {"preseed.json": bootstrap_preseed(entry), "acl.json": {
            "description": "Ductor explicitly approved worker routes", "config": {},
            "ingress": entry["ingress"], "egress": entry["egress"]}, "approval.json": entry}.items():
            path = directory / filename
            path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
            path.chmod(0o600)
            paths.append(path)
    for name, pool in config.get("incus", {}).get("pools", {}).items():
        directory = Path(output_dir) / "incus" / name
        directory.mkdir(parents=True, exist_ok=True)
        files = {
            "project.json": pool_project(name, pool), "profile.json": pool_profile(pool),
            "crabbox.yaml": {"provider": "incus", "incus": {
                "remote": name, "address": pool["address"], "project": pool["project"],
                "instanceType": "vm", "image": image_alias(pool), "profile": pool["profile"],
                "user": "crabbox", "workRoot": "/work/crabbox", "deleteOnRelease": True,
                "startTimeout": "10m", "launchPort": "22", "insecureTLS": False,
                "tlsServerCert": f"/etc/ductor/incus/{name}/servercerts/{name}.crt"}},
            "incus-config.yml": {"default-remote": name, "remotes": {name: {
                "addr": pool["address"], "auth_type": "tls", "protocol": "incus",
                "public": False, "project": pool["project"]}}, "aliases": {}},
        }
        for filename, content in files.items():
            path = directory / filename
            path.write_text(json.dumps(content, indent=2, sort_keys=True) + "\n")
            path.chmod(0o600)
            paths.append(path)
        path = directory / "wrapper"
        path.write_text(wrapper(name))
        path.chmod(0o755)
        paths.append(path)
    return paths
