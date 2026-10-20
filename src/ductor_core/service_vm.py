"""Native Incus service-VM bootstrap inputs, separate from runtime workers."""
from __future__ import annotations

import base64
import hashlib
import ipaddress
import json
import re
from pathlib import Path

_NAME = re.compile(r"[a-z][a-z0-9-]{0,39}[a-z0-9]\Z|[a-z]\Z")
_FIELDS = {"hypervisor", "guest_host", "service", "project", "instance", "network", "network_cidr",
           "ipv4_address", "ipv4_nat", "storage_pool", "image_source_project", "image_fingerprint",
           "image_os", "cpus", "memory_mib", "disk_gib", "ssh_public_key", "management_sources",
           "proxy_sources", "service_ports", "dns_servers", "egress"}


def _ports(value):
    return isinstance(value, list) and bool(value) and all(type(p) is int and 1 <= p <= 65535 for p in value) and len(value) == len(set(value))


def validate_service_vms(config: dict) -> list[str]:
    """Structural validation only; public key is explicit data, never a file read."""
    errors = []
    entries = config.get("service_vms", {})
    if not isinstance(entries, dict):
        return ["service_vms must be an object"]
    hosts = config.get("hosts", {}) if isinstance(config.get("hosts", {}), dict) else {}
    services = config.get("services", {}) if isinstance(config.get("services", {}), dict) else {}
    identities, guests, subnets = set(), set(), []
    for name, vm in entries.items():
        label = f"service_vms.{name}"
        if not isinstance(vm, dict):
            errors.append(f"{label} must be an object")
            continue
        if set(vm) != _FIELDS:
            errors.append(f"{label}: missing fields {sorted(_FIELDS - set(vm))}; unsupported fields {sorted(set(vm) - _FIELDS)}")
        if any(not isinstance(vm.get(k), str) for k in ("hypervisor", "guest_host", "service", "project", "instance", "network", "storage_pool", "image_source_project")):
            errors.append(f"{label}: host, service and infrastructure references must be strings")
            continue
        for key, value in [("id", name)] + [(key, vm.get(key)) for key in ("project", "instance", "network", "storage_pool", "image_source_project")]:
            if not isinstance(value, str) or not _NAME.fullmatch(value):
                errors.append(f"{label}.{key} requires a lowercase infrastructure identifier, at most 41 characters")
        if isinstance(vm.get("network"), str) and len(vm["network"]) > 15:
            errors.append(f"{label}.network exceeds the Linux bridge interface name limit of 15 characters")
        hypervisor, guest = hosts.get(vm.get("hypervisor"), {}), hosts.get(vm.get("guest_host"), {})
        hypervisor = hypervisor if isinstance(hypervisor, dict) else {}
        guest = guest if isinstance(guest, dict) else {}
        hypervisor_roles = hypervisor.get("roles") if isinstance(hypervisor.get("roles"), list) else []
        guest_roles = guest.get("roles") if isinstance(guest.get("roles"), list) else []
        if "incus" not in hypervisor_roles or vm.get("hypervisor") == vm.get("guest_host"):
            errors.append(f"{label}.hypervisor must reference a separate enrolled Incus host")
        if "services" not in guest_roles or not re.fullmatch(r"[a-z_][a-z0-9_-]*", str(guest.get("user", ""))) or guest.get("user") == "root" or guest.get("port") != 22 or guest.get("become") is not True:
            errors.append(f"{label}.guest_host requires an enrolled services host with non-root SSH user, port 22 and become=true")
        service = services.get(vm.get("service"), {})
        service = service if isinstance(service, dict) else {}
        if service.get("kind") not in ("openclaw", "joomengine") or service.get("host") != vm.get("guest_host") or not service.get("enabled"):
            errors.append(f"{label}.service must reference an enabled OpenClaw or JoomEngine service on guest_host")
        if any(isinstance(s, dict) and s.get("enabled") and s.get("host") == vm.get("guest_host") and key != vm.get("service") for key, s in services.items()):
            errors.append(f"{label}.guest_host must be dedicated to this service")
        if not _ports(vm.get("service_ports")) or vm.get("service_ports") != [service.get("port")]:
            errors.append(f"{label}.service_ports must contain only the referenced service's fixed port")
        if service.get("bind_address") != vm.get("ipv4_address") or guest.get("address") != vm.get("ipv4_address"):
            errors.append(f"{label}: guest SSH address and service bind_address must equal ipv4_address")
        if vm.get("guest_host") in guests:
            errors.append(f"{label}.guest_host is already owned by another service VM")
        guests.add(vm.get("guest_host"))
        for key in ("project", "network"):
            identity = (vm.get("hypervisor"), key, vm.get(key))
            if identity in identities:
                errors.append(f"{label}.{key} must be unique on its hypervisor")
            identities.add(identity)
        if vm.get("project") in ("default", "vdm-agents"):
            errors.append(f"{label}.project must be a dedicated service project")
        incus = config.get("incus", {})
        pools = incus.get("pools", {}) if isinstance(incus, dict) else {}
        for pool in (pools.values() if isinstance(pools, dict) else []):
            if not isinstance(pool, dict):
                continue
            if pool.get("host") == vm.get("hypervisor") and (pool.get("project") == vm.get("project") or pool.get("network") == vm.get("network")):
                errors.append(f"{label}: service project and network must be separate from every worker pool")
        try:
            bridge = ipaddress.IPv4Interface(vm["network_cidr"])
            address = ipaddress.IPv4Address(vm["ipv4_address"])
            private = [ipaddress.IPv4Network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
            if not any(bridge.network.subnet_of(n) for n in private) or address not in bridge.network or address in (bridge.ip, bridge.network.network_address, bridge.network.broadcast_address):
                raise ValueError()
            if bridge.network.prefixlen > 29 or bridge.network.prefixlen < 16:
                raise ValueError()
            for other in subnets:
                if bridge.network.overlaps(other):
                    errors.append(f"{label}.network_cidr overlaps another service VM subnet")
            subnets.append(bridge.network)
        except (ValueError, KeyError, TypeError):
            errors.append(f"{label} requires distinct private bridge/guest IPv4 addresses in a /16 through /29 subnet")
        if type(vm.get("ipv4_nat")) is not bool:
            errors.append(f"{label}.ipv4_nat must be explicit boolean")
        if vm.get("image_os") not in ("ubuntu-24.04", "debian-13") or not re.fullmatch(r"[a-f0-9]{64}", str(vm.get("image_fingerprint", ""))):
            errors.append(f"{label}: pin a full fingerprint of an Ubuntu 24.04 or Debian 13 cloud-init VM image with incus-agent")
        if vm.get("image_source_project") != "default":
            errors.append(f"{label}.image_source_project must be default; service VMs use the existing shared image without consuming their root-volume quota")
        resources = guest.get("resources", {}) if isinstance(guest.get("resources", {}), dict) else {}
        for key in ("cpus", "memory_mib", "disk_gib"):
            if type(vm.get(key)) is not int or vm[key] <= 0:
                errors.append(f"{label}.{key} must be a positive integer")
            elif type(resources.get(key)) is int and resources[key] > vm[key]:
                errors.append(f"{label}.{key} must cover the enrolled guest host's declared {key} budget")
        if type(vm.get("disk_gib")) is int and type(resources.get("disk_gib")) is int and resources["disk_gib"] >= vm["disk_gib"]:
            errors.append(f"{label}.disk_gib must exceed the guest usable disk budget to leave partition/filesystem overhead")
        key = vm.get("ssh_public_key", "")
        try:
            if not isinstance(key, str) or "\n" in key or "\r" in key or not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\r\n]+)?", key):
                raise ValueError()
            blob = base64.b64decode(key.split()[1], validate=True)
            if len(blob) != 51 or blob[:19] != b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20":
                raise ValueError()
        except (ValueError, TypeError):
            errors.append(f"{label}.ssh_public_key requires one valid SSH Ed25519 public key")
        for field in ("management_sources", "proxy_sources"):
            values = vm.get(field)
            if not isinstance(values, list) or not values:
                errors.append(f"{label}.{field} must list explicit IPv4 source CIDRs")
                continue
            for value in values:
                try:
                    source = ipaddress.IPv4Network(value, strict=True)
                    if source.prefixlen == 0:
                        raise ValueError()
                except (ValueError, TypeError):
                    errors.append(f"{label}.{field} rejects invalid CIDRs and unrestricted 0.0.0.0/0 ingress")
        dns = vm.get("dns_servers")
        if not isinstance(dns, list) or not dns:
            errors.append(f"{label}.dns_servers must list explicit IPv4 resolvers")
        else:
            for value in dns:
                try:
                    ipaddress.IPv4Address(value)
                except (ValueError, TypeError):
                    errors.append(f"{label}.dns_servers contains an invalid resolver")
        egress = vm.get("egress")
        if not isinstance(egress, list) or not egress:
            errors.append(f"{label}.egress must explicitly permit required destinations and TCP/UDP ports")
        else:
            for rule in egress:
                if not isinstance(rule, dict) or set(rule) != {"destination", "protocol", "ports"} or rule.get("protocol") not in ("tcp", "udp") or not _ports(rule.get("ports")):
                    errors.append(f"{label}.egress requires destination, tcp/udp protocol and explicit ports")
                    continue
                try:
                    ipaddress.IPv4Network(rule["destination"], strict=True)
                except (ValueError, TypeError):
                    errors.append(f"{label}.egress destination must be an IPv4 CIDR")
    return errors


def service_vm_documents(config: dict, name: str) -> dict:
    vm = config["service_vms"][name]
    guest = config["hosts"][vm["guest_host"]]
    bridge = ipaddress.IPv4Interface(vm["network_cidr"])
    marker = {"user.ductor.service-vm": name}
    mac = "02:" + ":".join(hashlib.sha256(name.encode()).hexdigest()[i:i+2] for i in range(0, 10, 2))
    acl_name, profile_name = "ductor-svc-" + name, "ductor-service"
    acl = {"description": "Ductor service VM explicit routes", "config": marker, "ingress": [], "egress": []}
    for sources, ports in ((vm["management_sources"], [22]), (vm["proxy_sources"], vm["service_ports"])):
        acl["ingress"].append({"action": "allow", "state": "enabled", "source": ",".join(sources), "protocol": "tcp", "destination_port": ",".join(map(str, ports))})
    for rule in vm["egress"]:
        acl["egress"].append({"action": "allow", "state": "enabled", "destination": rule["destination"], "protocol": rule["protocol"], "destination_port": ",".join(map(str, rule["ports"]))})
    for protocol in ("tcp", "udp"):
        acl["egress"].append({"action": "allow", "state": "enabled", "destination": ",".join(vm["dns_servers"]), "protocol": protocol, "destination_port": "53"})
    cloud = {"hostname": vm["instance"], "manage_etc_hosts": True, "disable_root": True, "ssh_pwauth": False,
             "ssh_deletekeys": True, "ssh_genkeytypes": ["ed25519"], "package_update": True,
             "packages": ["openssh-server", "sudo"],
             "users": [{"name": guest["user"], "shell": "/bin/bash", "lock_passwd": True,
                        "sudo": ["ALL=(ALL) NOPASSWD:ALL"], "ssh_authorized_keys": [vm["ssh_public_key"]]}],
             "write_files": [{"path": "/etc/ssh/sshd_config.d/00-ductor.conf", "owner": "root:root", "permissions": "0644",
                              "content": "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowUsers " + guest["user"] + "\n"}],
             "runcmd": [["systemctl", "enable", "--now", "ssh"], ["systemctl", "restart", "ssh"]]}
    network_data = {"version": 2, "ethernets": {"ductor0": {"match": {"macaddress": mac}, "set-name": "eth0", "dhcp4": False, "dhcp6": False,
                    "addresses": [f"{vm['ipv4_address']}/{bridge.network.prefixlen}"], "routes": [{"to": "0.0.0.0/0", "via": str(bridge.ip)}],
                    "nameservers": {"addresses": vm["dns_servers"]}}}}
    project = {"description": "Ductor isolated service VM " + name, "config": {**marker,
        "features.images": "false", "features.profiles": "true", "features.networks": "false", "features.storage.volumes": "true",
        "restricted": "true", "restricted.devices.disk": "managed", "restricted.devices.nic": "managed",
        "restricted.networks.access": vm["network"], "restricted.storage-pools.access": vm["storage_pool"],
        "restricted.devices.proxy": "block", "restricted.virtual-machines.lowlevel": "block",
        "restricted.snapshots": "block", "limits.containers": "0", "limits.instances": "1", "limits.virtual-machines": "1",
        "limits.cpu": str(vm["cpus"]), "limits.memory": f"{vm['memory_mib']}MiB", "limits.disk": f"{vm['disk_gib']}GiB",
        "images.auto_update_cached": "false"}}
    network = {"description": "Ductor dedicated service bridge " + name, "config": {**marker,
        "ipv4.address": vm["network_cidr"], "ipv4.nat": str(vm["ipv4_nat"]).lower(), "ipv6.address": "none",
        "security.acls": acl_name, "security.acls.default.ingress.action": "reject", "security.acls.default.egress.action": "reject"}}
    profile = {"description": "Ductor dedicated service VM profile", "config": {**marker,
        "limits.cpu": str(vm["cpus"]), "limits.memory": f"{vm['memory_mib']}MiB", "security.secureboot": "true", "security.nesting": "false", "boot.autostart": "true",
        "cloud-init.user-data": "#cloud-config\n" + json.dumps(cloud, indent=2) + "\n", "cloud-init.network-config": json.dumps(network_data, indent=2)},
        "devices": {"root": {"type": "disk", "path": "/", "pool": vm["storage_pool"], "size": f"{vm['disk_gib']}GiB"},
                    "eth0": {"type": "nic", "name": "eth0", "network": vm["network"], "hwaddr": mac, "ipv4.address": vm["ipv4_address"],
                             "security.ipv4_filtering": "true", "security.mac_filtering": "true", "security.acls": acl_name,
                             "security.acls.default.ingress.action": "reject", "security.acls.default.egress.action": "reject"}}}
    # Native ACL policy is independently reconcilable. Cloud-init, image,
    # identity and resource changes need a deliberate persistent-VM migration.
    immutable = {key: value for key, value in vm.items() if key not in {"management_sources", "proxy_sources", "egress", "service_ports"}}
    spec = hashlib.sha256(json.dumps({"vm": immutable, "ssh_user": guest["user"]}, sort_keys=True).encode()).hexdigest()
    return {"project.json": project, "network.json": network, "acl.json": acl, "profile.json": profile,
            "identity.json": {"spec_sha256": spec, "profile": profile_name, "acl": acl_name}}


def render_service_vm(config: dict, output_dir: Path) -> list[Path]:
    errors = validate_service_vms(config)
    if errors:
        raise ValueError("\n".join(errors))
    paths = []
    for name in config.get("service_vms", {}):
        directory = Path(output_dir) / "service-vms" / name
        directory.mkdir(parents=True, exist_ok=True)
        for filename, content in service_vm_documents(config, name).items():
            path = directory / filename
            path.write_text(json.dumps(content, indent=2, sort_keys=True) + "\n")
            path.chmod(0o600)
            paths.append(path)
    return paths
