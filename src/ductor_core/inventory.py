"""Ansible inventory: host administration always traverses verified SSH."""
from pathlib import Path
import shlex
import os
import stat
from .util import check_private_file, write_private


def build_inventory(config, bundle, render, host_filter=None, service_filter=None):
    if host_filter and host_filter not in config["hosts"]:
        raise ValueError(f"Unknown host: {host_filter}")
    if service_filter and service_filter not in config["services"]:
        raise ValueError(f"Unknown service: {service_filter}")
    entries = {}
    for name, host in config["hosts"].items():
        if host_filter and name != host_filter:
            continue
        services = [dict(value, id=key) for key, value in config["services"].items()
                    if value["host"] == name and value["enabled"] and (not service_filter or key == service_filter)]
        pools = [dict(value, id=key) for key, value in config["incus"]["pools"].items() if value["host"] == name] if not service_filter else []
        if service_filter and not services:
            continue
        entries[name] = {"ansible_connection": "ssh", "ansible_host": host["address"],
            "ansible_port": host["port"], "ansible_user": host["user"],
            "ansible_ssh_private_key_file": host["identity_file"], "ansible_become": host["become"],
            "ansible_ssh_common_args": "-o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=" + shlex.quote(host["known_hosts_file"]),
            "ductor_host": dict(host, id=name), "ductor_services": services, "ductor_pools": pools,
            "ductor_service_vms": [dict(value, id=key) for key, value in config.get("service_vms", {}).items()
                                   if value["hypervisor"] == name and (not service_filter or value["guest_host"] == config["services"][service_filter]["host"])]}
    if not entries:
        raise ValueError("Selection contains no enabled deployment targets")
    return {"all": {"children": {"ductor_hosts": {"hosts": entries}}, "vars": {
        "ductor_config": config, "ductor_bundle_root": str(Path(bundle).resolve()),
        "ductor_render_root": str(Path(render).resolve())}}}


def build_service_vm_inventory(config, bundle, render, host_filter=None, service_filter=None):
    """Bootstrap only hypervisors; no SSH attempt to a not-yet-created guest."""
    if host_filter and host_filter not in config["hosts"]:
        raise ValueError(f"Unknown host: {host_filter}")
    if service_filter and config["services"].get(service_filter, {}).get("kind") != "openclaw":
        raise ValueError("bootstrap-services --service must select an OpenClaw gateway")
    selected = [dict(value, id=key) for key, value in config.get("service_vms", {}).items()
                if (not host_filter or value["hypervisor"] == host_filter)
                and (not service_filter or value["guest_host"] == config["services"][service_filter]["host"])]
    if not selected:
        raise ValueError("No service VMs selected for bootstrap")
    inventory = build_inventory(config, bundle, render)
    entries = inventory["all"]["children"]["ductor_hosts"]["hosts"]
    inventory["all"]["children"]["ductor_hosts"]["hosts"] = {
        key: dict(value, ductor_services=[], ductor_pools=[],
                  ductor_service_vms=[vm for vm in selected if vm["hypervisor"] == key])
        for key, value in entries.items() if any(vm["hypervisor"] == key for vm in selected)}
    return inventory


def verify_ssh_files(inventory):
    for host in inventory["all"]["children"]["ductor_hosts"]["hosts"].values():
        check_private_file(host["ansible_ssh_private_key_file"])
        known = Path(host["ductor_host"]["known_hosts_file"])
        if any(part.is_symlink() for part in (known, *known.parents)) or not known.is_file() or not known.read_text().strip():
            raise ValueError(f"Verified SSH host keys required: {known}; use host trust with an independently verified fingerprint")
        metadata = known.stat()
        if metadata.st_uid not in (0, os.getuid()) or stat.S_IMODE(metadata.st_mode) & 0o022:
            raise ValueError(f"SSH trust file must be operator/root owned and not writable by others: {known}")


def save_inventory(inventory, render):
    path = Path(render) / "inventory.json"
    write_private(path, inventory)
    return path
