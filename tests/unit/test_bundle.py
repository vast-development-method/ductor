import copy
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

from ductor_core.bundle import export_bundle, import_bundle
from fixtures import complete_config


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "first-controller"
        self.source.mkdir(mode=0o700)
        self.config = complete_config(self.source)
        for name in ("ssh-key", "known-hosts", "incus.crt", "incus.key", "server.crt",
                     "gateway-token", "operator-token", "recovery.json", "role-id", "secret-id", "ca.pem"):
            target = self.source / name
            target.write_text("fixture-" + name)
            target.chmod(0o644 if name.endswith((".crt", ".pem")) or name == "known-hosts" else 0o600)
        self.config["services"]["bao"]["ca_file"] = str(self.source / "ca.pem")
        self.config["services"]["agents"]["gateway_token_file"] = str(self.source / "gateway-token")
        self.config["knowledge"]["repository"] = {"url": "https://example.org/company.git", "branch": "main"}
        (self.source / "knowledge" / "projects").mkdir()
        (self.source / "knowledge" / "projects" / "decisions.MD").write_text("# Decisions\n")
        (self.source / "knowledge" / "not-exported.txt").write_text("not a knowledge document")
        self.output = self.root / "controller.zip"
        self.state = self.root / "second-controller"
        self.config_path = self.state / "config.json"

    def tearDown(self):
        self.temp.cleanup()

    def export(self, **kwargs):
        return export_bundle(self.config, self.source, self.output, **kwargs)

    def imported(self):
        result = import_bundle(self.output, self.state, self.config_path)
        return result, json.loads(self.config_path.read_text())

    def rewrite(self, change_manifest=None, change_payload=None, extra=None):
        with zipfile.ZipFile(self.output) as source:
            entries = [(entry, source.read(entry)) for entry in source.infolist()]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.output, "w") as target:
                for entry, data in entries:
                    if entry.filename == "manifest.json" and change_manifest:
                        manifest = json.loads(data)
                        change_manifest(manifest)
                        data = json.dumps(manifest).encode()
                    if entry.filename != "manifest.json" and change_payload:
                        data = change_payload(entry.filename, data)
                    target.writestr(entry, data)
                if extra:
                    target.writestr(*extra)
        self.output.chmod(0o600)

    def test_roundtrip_relocates_all_local_refs_and_preserves_remote_settings(self):
        original = copy.deepcopy(self.config)
        exported = self.export()
        self.assertFalse(exported["encrypted"])
        self.assertIn("not encrypted", exported["message"])
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(self.config, original)
        result, imported = self.imported()
        root = Path(result["imported_root"])
        self.assertEqual(imported["hosts"]["control"]["data_root"], "/srv/ductor")
        self.assertEqual(imported["services"]["bao"]["url"], original["services"]["bao"]["url"])
        self.assertEqual(imported["incus"]["pools"]["workers"]["address"], original["incus"]["pools"]["workers"]["address"])
        self.assertEqual(imported["knowledge"]["repository"], original["knowledge"]["repository"])
        for section, keys in ((imported["hosts"]["control"], ["identity_file", "known_hosts_file"]),
                              (imported["incus"]["pools"]["workers"], ["client_certificate_file", "client_key_file", "server_certificate_file"]),
                              (imported["services"]["bao"], ["ca_file"]),
                              (imported["services"]["agents"], ["gateway_token_file"]),
                              (imported["credentials"], ["openbao_token_file"]),
                              (imported["credentials"]["openbao_approles"]["agents"], ["role_id_file", "secret_id_file"])):
            for key in keys:
                path = Path(section[key])
                self.assertTrue(path.is_relative_to(root))
                self.assertTrue(path.read_text().startswith("fixture-"))
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(imported["services"]["agents"]["gateway_token_file"], imported["credentials"]["gateway_token_files"]["agents"])
        knowledge = Path(imported["knowledge"]["source_dir"])
        self.assertTrue((knowledge / "projects" / "decisions.MD").exists())
        self.assertFalse((knowledge / "not-exported.txt").exists())
        self.assertFalse(Path(imported["credentials"]["openbao_unseal_file"]).exists())
        for current, _, _ in os.walk(root):
            self.assertEqual(stat.S_IMODE(Path(current).stat().st_mode), 0o700)

    def test_missing_inputs_rebase_without_inventing_contents(self):
        (self.source / "ssh-key").unlink()
        exported = self.export()
        self.assertIn("hosts.control.identity_file", exported["missing_references"])
        _, config = self.imported()
        self.assertTrue(config["hosts"]["control"]["identity_file"].startswith(str(self.state)))
        self.assertFalse(Path(config["hosts"]["control"]["identity_file"]).exists())

    def test_missing_knowledge_and_empty_knowledge_remain_distinct(self):
        empty = self.source / "empty-knowledge"
        empty.mkdir()
        self.config["knowledge"]["source_dir"] = str(empty)
        self.export()
        _, imported = self.imported()
        self.assertTrue(Path(imported["knowledge"]["source_dir"]).is_dir())
        self.output.unlink()
        self.config["knowledge"]["source_dir"] = str(self.source / "future-knowledge")
        result = self.export()
        self.assertIn("knowledge.source_dir", result["missing_references"])
        state = self.root / "third-controller"
        import_bundle(self.output, state, state / "config.json")
        imported = json.loads((state / "config.json").read_text())
        self.assertFalse(Path(imported["knowledge"]["source_dir"]).exists())

    def test_recovery_opt_in_and_alias_omission(self):
        self.config["credentials"]["openbao_token_file"] = str(self.source / "recovery.json")
        exported = self.export()
        self.assertIn("credentials.openbao_token_file", exported["omitted_recovery_references"])
        _, config = self.imported()
        self.assertFalse(Path(config["credentials"]["openbao_token_file"]).exists())
        self.output.unlink()
        self.export(include_recovery=True)
        other = self.root / "third-controller"
        result = import_bundle(self.output, other, other / "config.json")
        self.assertTrue(result["recovery_included"])
        config = json.loads((other / "config.json").read_text())
        self.assertEqual(Path(config["credentials"]["openbao_unseal_file"]).read_text(), "fixture-recovery.json")

    def test_export_and_import_never_overwrite_existing_files(self):
        self.export()
        before = self.output.read_bytes()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.export()
        self.assertEqual(self.output.read_bytes(), before)
        self.state.mkdir(mode=0o700)
        self.config_path.write_text("existing configuration")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.imported()
        self.assertEqual(self.config_path.read_text(), "existing configuration")
        self.assertFalse((self.state / "imported").exists())

    def test_import_config_race_rolls_back_imported_payload(self):
        self.export()
        real_link = os.link
        def raced_link(source, target):
            Path(target).write_text("another controller won")
            return real_link(source, target)
        with patch("ductor_core.bundle.os.link", side_effect=raced_link):
            with self.assertRaisesRegex(ValueError, "already exists"):
                self.imported()
        self.assertEqual(self.config_path.read_text(), "another controller won")
        self.assertEqual(list((self.state / "imported").iterdir()), [])

    def test_tampered_payload_fails_integrity_before_writing_state(self):
        self.export()
        self.rewrite(change_payload=lambda name, data: b"x" * len(data))
        with self.assertRaisesRegex(ValueError, "integrity"):
            self.imported()
        self.assertFalse(self.state.exists())

    def test_unsafe_archive_paths_links_and_duplicates_are_rejected(self):
        cases = ["../outside", "/absolute", "C:/drive", "objects\\evil", "objects/./dot", "objects//double", "manifest.json"]
        for name in cases:
            with self.subTest(name=name):
                self.output.unlink(missing_ok=True)
                self.export()
                self.rewrite(extra=(name, b"unsafe"))
                with self.assertRaises(ValueError):
                    self.imported()
                self.assertFalse(self.state.exists())
        for kind in (stat.S_IFLNK, stat.S_IFIFO):
            self.output.unlink()
            self.export()
            info = zipfile.ZipInfo("objects/special")
            info.create_system = 3
            info.external_attr = (kind | 0o600) << 16
            self.rewrite(extra=(info, b"target"))
            with self.assertRaisesRegex(ValueError, "links|file types"):
                self.imported()

    def test_unlisted_payload_and_oversized_members_are_rejected(self):
        self.export()
        self.rewrite(extra=("objects/unlisted", b"unexpected"))
        with self.assertRaisesRegex(ValueError, "unlisted"):
            self.imported()
        self.output.unlink()
        self.export()
        with patch("ductor_core.bundle.MAX_FILE_BYTES", 2):
            with self.assertRaisesRegex(ValueError, "size limit"):
                self.imported()

    def test_duplicate_manifest_keys_and_link_metadata_are_rejected(self):
        self.export()
        with zipfile.ZipFile(self.output) as source:
            entries = [(entry, source.read(entry)) for entry in source.infolist()]
        with zipfile.ZipFile(self.output, "w") as target:
            for entry, data in entries:
                if entry.filename == "manifest.json":
                    data = b'{"version":1,' + data[1:]
                target.writestr(entry, data)
        with self.assertRaisesRegex(ValueError, "Duplicate key"):
            self.imported()
        self.output.unlink()
        self.export()
        info = zipfile.ZipInfo("objects/link")
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o600) << 16
        info.extra = b"\x0d\x00\x00\x00"  # Unsupported Unix metadata, never interpreted as a link.
        self.rewrite(extra=(info, b"target"))
        with self.assertRaisesRegex(ValueError, "metadata"):
            self.imported()

    def test_bad_structural_config_and_reference_inventory_are_rejected(self):
        self.export()
        self.rewrite(change_manifest=lambda m: m["config"]["hosts"]["control"].update({"data_root": "/"}))
        with self.assertRaisesRegex(ValueError, "Invalid bundle configuration"):
            self.imported()
        self.assertFalse(self.state.exists())
        self.output.unlink()
        self.export()
        self.rewrite(change_manifest=lambda m: m["references"].pop())
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            self.imported()

    def test_source_permissions_symlinks_and_hardlinks_fail_closed(self):
        key = self.source / "ssh-key"
        key.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "permissions"):
            self.export()
        key.chmod(0o600)
        os.link(key, self.source / "hardlink")
        with self.assertRaisesRegex(ValueError, "links"):
            self.export()
        (self.source / "hardlink").unlink()
        (self.source / "knowledge" / "non-markdown-link.txt").symlink_to(key)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.export()


if __name__ == "__main__":
    unittest.main()
