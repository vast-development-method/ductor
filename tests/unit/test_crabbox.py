import copy
import json
import tempfile
import unittest
from pathlib import Path

from ductor_core.crabbox import artifact, render_crabbox, supported_node, validate_pools


def example():
    return {"hosts": {"worker-host": {}}, "incus": {"pools": {"workers": {
        "host": "worker-host", "address": "https://incus.example.org:8443",
        "project": "ductor-workers", "profile": "ductor-worker", "network": "incusbr0",
        "network_acl": "worker-control", "storage_pool": "default", "instance_type": "virtual-machine",
        "image_source_project": "vdm-agents", "image_fingerprint": "a" * 64,
        "allow_vm_lowlevel": True, "worker_node_version": "24.16.0",
        "client_certificate_file": "/private/client.crt", "client_key_file": "/private/client.key",
        "server_certificate_file": "/private/server.crt", "cpus": 8, "memory_mib": 16384,
        "disk_gib": 120, "instance_cpus": 2, "instance_memory_mib": 4096,
        "instance_disk_gib": 20, "max_instances": 4,
    }}}}


class CrabboxContractTests(unittest.TestCase):
    def test_exact_supported_upstream_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = render_crabbox(example(), Path(tmp))
            self.assertEqual(len(paths), 5)
            base = Path(tmp) / "incus/workers"
            cb = json.loads((base / "crabbox.yaml").read_text())
            self.assertEqual(cb["incus"]["image"], "ductor-" + "a" * 64)
            self.assertEqual(cb["incus"]["instanceType"], "vm")
            self.assertTrue(cb["incus"]["deleteOnRelease"])
            self.assertFalse(cb["incus"]["insecureTLS"])
            self.assertNotIn("socket", cb["incus"])
            project = json.loads((base / "project.json").read_text())
            profile = json.loads((base / "profile.json").read_text())
            self.assertEqual(project["config"]["limits.cpu"], "8")
            self.assertEqual(profile["config"]["limits.cpu"], "2")
            self.assertEqual(project["config"]["limits.instances"], "4")
            self.assertEqual(profile["devices"]["root"]["size"], "20GiB")
            self.assertEqual(profile["devices"]["eth0"]["security.acls.default.ingress.action"], "reject")
            text = (base / "wrapper").read_text()
            self.assertIn('exec /usr/local/bin/crabbox "$@"', text)
            self.assertIn("export XDG_STATE_HOME=/home/node/.local/state", text)
            self.assertNotIn("cleanup", text)
            self.assertNotIn("warmup", text)
            self.assertNotIn("/private/client.key", "".join(p.read_text() for p in paths))

    def test_unsafe_or_incompatible_pools_fail_before_render(self):
        for key, value in (("address", "http://incus:8443"), ("address", "https://user:pass@incus"),
                           ("project", "vdm-agents"), ("allow_vm_lowlevel", False),
                           ("instance_type", "container"), ("worker_node_version", "22.20.0"),
                           ("image_fingerprint", "latest"), ("instance_cpus", 9),
                           ("client_key_file", "relative.key"), ("max_instances", True)):
            with self.subTest(key=key, value=value):
                config = example()
                config["incus"]["pools"]["workers"][key] = value
                self.assertTrue(validate_pools(config))
                with tempfile.TemporaryDirectory() as tmp:
                    with self.assertRaises(ValueError):
                        render_crabbox(config, Path(tmp))
                    self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_separate_pool_projects_cannot_overwrite_each_others_quota(self):
        config = example()
        config["incus"]["pools"]["other"] = copy.deepcopy(config["incus"]["pools"]["workers"])
        self.assertTrue(any("unique" in e for e in validate_pools(config)))

    def test_release_pin_and_supported_node_boundary(self):
        self.assertEqual(artifact("x86_64")["checksum"], "sha256:fc4d8d04b1a596e8e5fdc6af7b0794d44f3f19c2f63153205b92d45ebc5f095b")
        self.assertIn("v0.79.0/crabbox_0.79.0_linux_arm64.tar.gz", artifact("arm64")["url"])
        with self.assertRaises(ValueError):
            artifact("i386")
        self.assertFalse(supported_node("24.15.9"))
        self.assertFalse(supported_node("25.9.0"))
        self.assertTrue(supported_node("24.16.0"))
        self.assertTrue(supported_node("26.1.0"))

    def test_explicit_bootstrap_and_import_are_rendered_without_execution(self):
        config = example()
        config["incus"]["bootstrap"] = {"worker-host": {
            "enabled": True, "package_version": "7.1-1", "listen_address": "192.0.2.10:8443",
            "storage_driver": "dir", "storage_pool": "default", "network": "incusbr0",
            "network_acl": "worker-control", "ipv4_address": "10.70.0.1/24", "ipv4_nat": True,
            "ingress": [{"action": "allow", "source": "192.0.2.20/32", "protocol": "tcp", "destination_port": "22"}],
            "egress": [{"action": "allow", "destination": "192.0.2.20/32", "protocol": "tcp", "destination_port": "443"}],
        }}
        config["incus"]["pools"]["workers"]["image_import"] = {
            "metadata_url": "https://images.example.org/metadata.tar.xz", "metadata_sha256": "b" * 64,
            "disk_url": "https://images.example.org/disk.qcow2", "disk_sha256": "c" * 64,
        }
        self.assertEqual(validate_pools(config), [])
        with tempfile.TemporaryDirectory() as tmp:
            paths = render_crabbox(config, Path(tmp))
            self.assertEqual(len(paths), 8)
            preseed = json.loads((Path(tmp) / "incus/bootstrap/worker-host/preseed.json").read_text())
            self.assertEqual(preseed["storage_pools"][0]["driver"], "dir")
            self.assertEqual(preseed["networks"][0]["config"]["ipv4.nat"], "true")
            self.assertNotIn("source", preseed["storage_pools"][0]["config"])
        config["incus"]["bootstrap"]["worker-host"]["storage_driver"] = "zfs"
        self.assertTrue(validate_pools(config))

    def test_unknown_pool_routing_setting_is_never_silently_ignored(self):
        config = example()
        config["incus"]["pools"]["workers"]["scheduler"] = "round-robin"
        self.assertTrue(any("unsupported" in e for e in validate_pools(config)))


if __name__ == "__main__":
    unittest.main()
