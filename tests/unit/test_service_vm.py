import base64
import copy
import json
from pathlib import Path
import tempfile
import unittest

from ductor_core.service_vm import render_service_vm, service_vm_documents, validate_service_vms


def example():
    public = base64.b64encode(b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + b"x" * 32).decode()
    return {"hosts": {
        "hypervisor": {"roles": ["incus"]},
        "gateway": {"roles": ["services"], "user": "deploy", "port": 22, "become": True,
                    "address": "10.77.0.2", "resources": {"cpus": 4, "memory_mib": 8192, "disk_gib": 70}}},
        "services": {"agents": {"kind": "openclaw", "enabled": True, "host": "gateway", "bind_address": "10.77.0.2", "port": 18789}},
        "incus": {"pools": {"workers": {"host": "hypervisor", "project": "ductor-workers", "network": "incusbr0"}}},
        "service_vms": {"gateway": {
            "hypervisor": "hypervisor", "guest_host": "gateway", "service": "agents", "project": "ductor-services",
            "instance": "gateway", "network": "svcbr0", "network_cidr": "10.77.0.1/29", "ipv4_address": "10.77.0.2", "ipv4_nat": True,
            "storage_pool": "default", "image_source_project": "default", "image_fingerprint": "a" * 64,
            "image_os": "ubuntu-24.04", "cpus": 4, "memory_mib": 8192, "disk_gib": 80,
            "ssh_public_key": "ssh-ed25519 " + public + " operator",
            "management_sources": ["10.1.0.10/32"], "proxy_sources": ["10.1.0.20/32"], "service_ports": [18789],
            "dns_servers": ["10.1.0.53"], "egress": [
                {"destination": "10.1.0.30/32", "protocol": "tcp", "ports": [443, 8443]},
                {"destination": "10.90.0.0/24", "protocol": "tcp", "ports": [22]}]}}}


def service_vm_config(root):
    """Complete controller fixture with an independently enrolled service VM."""
    from fixtures import complete_config
    config = complete_config(root)
    template = example()
    config["hosts"]["control"]["resources"]["cpus"] = 24
    config["hosts"]["control"]["resources"]["disk_gib"] = 320
    guest = copy.deepcopy(config["hosts"]["control"])
    guest.update(template["hosts"]["gateway"])
    guest["identity_file"] = str(Path(root) / "gateway-ssh-key")
    guest["known_hosts_file"] = str(Path(root) / "gateway-known-hosts")
    guest["resources"].update({"reserve_cpus": 1, "reserve_memory_mib": 2048, "reserve_disk_gib": 15})
    config["hosts"]["gateway"] = guest
    config["services"]["agents"].update({"host": "gateway", "bind_address": "10.77.0.2", "trusted_proxies": ["10.1.0.20/32"]})
    config["service_vms"] = template["service_vms"]
    config["service_vms"]["gateway"]["hypervisor"] = "control"
    return config


class ServiceVMTests(unittest.TestCase):
    def test_persistent_native_vm_needs_no_controller_to_keep_running(self):
        config = example()
        self.assertEqual(validate_service_vms(config), [])
        with tempfile.TemporaryDirectory() as directory:
            paths = render_service_vm(config, Path(directory))
            self.assertEqual(len(paths), 5)
            docs = {path.name: json.loads(path.read_text()) for path in paths}
            profile, project = docs["profile.json"], docs["project.json"]
            self.assertEqual(profile["config"]["boot.autostart"], "true")
            self.assertEqual(profile["config"]["security.nesting"], "false")
            self.assertEqual(set(profile["devices"]), {"root", "eth0"})
            self.assertEqual(project["config"]["restricted.virtual-machines.lowlevel"], "block")
            self.assertEqual(project["config"]["limits.instances"], "1")
            self.assertEqual(project["config"]["features.images"], "false")
            self.assertEqual(project["config"]["limits.disk"], "80GiB")
            serialized = "".join(path.read_text() for path in paths)
            self.assertNotIn("client.key", serialized)
            self.assertNotIn("docker.sock", serialized)
            self.assertNotIn("expires", serialized)
            self.assertNotIn("reaper", serialized)

    def test_cloud_init_is_key_only_and_uses_fixed_mac_and_address(self):
        docs = service_vm_documents(example(), "gateway")
        profile = docs["profile.json"]
        cloud = json.loads(profile["config"]["cloud-init.user-data"].split("\n", 1)[1])
        self.assertFalse(cloud["ssh_pwauth"])
        self.assertTrue(cloud["disable_root"])
        self.assertTrue(cloud["users"][0]["lock_passwd"])
        self.assertNotIn("default", cloud["users"])
        self.assertIn("PermitRootLogin no", cloud["write_files"][0]["content"])
        network = json.loads(profile["config"]["cloud-init.network-config"])["ethernets"]["ductor0"]
        self.assertEqual(network["addresses"], ["10.77.0.2/29"])
        self.assertEqual(network["match"]["macaddress"], profile["devices"]["eth0"]["hwaddr"])

    def test_ingress_and_egress_are_explicit_and_default_rejected(self):
        docs = service_vm_documents(example(), "gateway")
        self.assertEqual([r["destination_port"] for r in docs["acl.json"]["ingress"]], ["22", "18789"])
        self.assertEqual({r["destination_port"] for r in docs["acl.json"]["egress"]}, {"443,8443", "22", "53"})
        for config in (docs["network.json"]["config"], docs["profile.json"]["devices"]["eth0"]):
            self.assertEqual(config["security.acls.default.ingress.action"], "reject")
            self.assertEqual(config["security.acls.default.egress.action"], "reject")

    def test_network_identity_and_runtime_authority_collisions_fail_before_writes(self):
        for key, value in (("project", "ductor-workers"), ("network", "incusbr0"), ("management_sources", ["0.0.0.0/0"]),
                           ("proxy_sources", ["0.0.0.0/0"]), ("network_cidr", "127.0.0.1/24"),
                           ("network", "service-network-too-long"), ("image_source_project", "vdm-agents"),
                           ("service_ports", [22, 18789]), ("ssh_public_key", "ssh-ed25519 AAAA"), ("disk_gib", 70)):
            with self.subTest(key=key):
                config = example()
                config["service_vms"]["gateway"][key] = value
                self.assertTrue(validate_service_vms(config))
                with tempfile.TemporaryDirectory() as directory:
                    with self.assertRaises(ValueError):
                        render_service_vm(config, Path(directory))
                    self.assertEqual(list(Path(directory).iterdir()), [])

    def test_policy_reconciliation_preserves_vm_but_image_and_ssh_changes_require_migration(self):
        config = example()
        before = service_vm_documents(config, "gateway")["identity.json"]["spec_sha256"]
        config["service_vms"]["gateway"]["egress"][0]["ports"] = [443]
        after = service_vm_documents(config, "gateway")["identity.json"]["spec_sha256"]
        self.assertEqual(before, after)
        self.assertEqual(after, service_vm_documents(copy.deepcopy(config), "gateway")["identity.json"]["spec_sha256"])
        config["service_vms"]["gateway"]["image_fingerprint"] = "b" * 64
        self.assertNotEqual(before, service_vm_documents(config, "gateway")["identity.json"]["spec_sha256"])
        config = example()
        config["hosts"]["gateway"]["user"] = "operator"
        self.assertNotEqual(before, service_vm_documents(config, "gateway")["identity.json"]["spec_sha256"])

    def test_malformed_references_return_errors_instead_of_crashing(self):
        for field in ("hypervisor", "guest_host", "service", "project", "network", "storage_pool"):
            config = example()
            config["service_vms"]["gateway"][field] = []
            self.assertTrue(validate_service_vms(config))


if __name__ == "__main__":
    unittest.main()
