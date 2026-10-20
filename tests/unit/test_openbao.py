import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from ductor_core.openbao import (OpenBaoError, _read_private, bootstrap,
                                provision_credentials, put_secret, render_openbao, unseal,
                                validate_openbao)


class OpenBaoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = {
            "hosts": {"control": {"data_root": "/srv/ductor"}},
            "services": {
                "bao": {"kind": "openbao", "host": "control", "url": "https://secrets.example.org",
                        "image": "ghcr.io/openbao/openbao:2.7.1"},
                "agents": {"kind": "openclaw", "host": "control", "openbao_service": "bao",
                           "provider_keys": {"openai": "gateways/agents/providers/openai/apiKey"}}},
            "credentials": {"openbao_bootstrap_output_file": str(self.root / "recovery.json")}}

    def tearDown(self):
        self.temp.cleanup()

    def private(self, name, contents):
        path = self.root / name
        path.write_text(contents)
        path.chmod(0o600)
        return str(path)

    def test_private_ref_rejects_world_readable_symlink_and_hardlink(self):
        path = Path(self.private("token", "secret-token"))
        self.assertEqual(_read_private(str(path), "token"), "secret-token")
        path.chmod(0o644)
        with self.assertRaises(OpenBaoError):
            _read_private(str(path), "token")
        path.chmod(0o600)
        link = self.root / "link"
        link.symlink_to(path)
        with self.assertRaises(OpenBaoError):
            _read_private(str(link), "token")
        link.unlink()
        os.link(path, link)
        with self.assertRaises(OpenBaoError):
            _read_private(str(path), "token")

    def test_remote_guard_rejects_linked_destination_and_ancestor(self):
        helper = Path(__file__).parents[2] / "ansible/roles/openbao/files/guard-managed-paths.py"
        managed = self.root / "managed"
        managed.mkdir()
        target = self.root / "outside"
        target.write_text("untouched")
        manifest = {"root": str(managed), "files": ["token"]}
        def guard():
            return subprocess.run([sys.executable, str(helper)], input=json.dumps(manifest),
                                  text=True, capture_output=True).returncode
        self.assertEqual(guard(), 0)
        (managed / "token").symlink_to(target)
        self.assertNotEqual(guard(), 0)
        (managed / "token").unlink()
        os.link(target, managed / "token")
        self.assertNotEqual(guard(), 0)
        (managed / "token").unlink()
        managed.rmdir()
        managed.symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(guard(), 0)
        self.assertEqual(target.read_text(), "untouched")

    def test_validation_rejects_insecure_endpoint_and_cross_gateway_secret(self):
        self.assertEqual(validate_openbao(self.config), [])
        bad = copy.deepcopy(self.config)
        bad["services"]["bao"]["url"] = "http://secrets.example.org"
        self.assertTrue(validate_openbao(bad))
        bad = copy.deepcopy(self.config)
        bad["services"]["agents"]["provider_keys"]["openai"] = "gateways/other/apiKey"
        self.assertTrue(validate_openbao(bad))

    def test_new_install_allows_future_references_but_actions_require_inputs(self):
        self.config["credentials"]["openbao_token_file"] = str(self.root / "missing-token")
        self.config["credentials"]["openbao_unseal_file"] = str(self.root / "missing-shares")
        self.assertEqual(validate_openbao(self.config), [])
        render_openbao(self.config, self.root / "rendered")
        with self.assertRaisesRegex(OpenBaoError, "does not exist"):
            provision_credentials(self.config)
        with self.assertRaisesRegex(OpenBaoError, "does not exist"):
            unseal(self.config)

    @patch("ductor_core.openbao._request")
    def test_provider_enrollment_preserves_other_fields_with_cas(self, request):
        self.config["credentials"]["openbao_token_file"] = self.private("operator", "operator-token")
        value_file = self.private("provider-key", "sensitive-api-key")
        request.side_effect = [{"data": {"data": {"other": "keep"}, "metadata": {"version": 2}}}, {"data": {"version": 3}}]
        result = put_secret(self.config, "agents", "openai", value_file)
        self.assertNotIn("sensitive-api-key", json.dumps(result))
        self.assertEqual(request.call_args.args[2], "secret/data/gateways/agents/providers/openai")
        self.assertEqual(request.call_args.kwargs["data"], {
            "options": {"cas": 2}, "data": {"other": "keep", "apiKey": "sensitive-api-key"}})
        with self.assertRaises(OpenBaoError):
            put_secret(self.config, "agents", "unconfigured", value_file)

    def test_render_native_agent_and_persistent_nondev_raft(self):
        report = render_openbao(self.config, self.root / "rendered")
        compose = json.loads((self.root / "rendered/services/bao/compose.yaml").read_text())
        server = compose["services"]["openbao"]
        self.assertNotIn("-dev", server["command"])
        self.assertEqual(server["command"], ["bao", "server", "-config=/openbao/config/server.hcl"])
        self.assertEqual(server["restart"], "unless-stopped")
        self.assertEqual(server["cap_drop"], ["ALL"])
        self.assertFalse("IPC_LOCK" in server.get("cap_add", []))
        self.assertIn("/srv/ductor/services/bao/data:/openbao/data", server["volumes"])
        agent = (self.root / "rendered/services/agents/agent.hcl").read_text()
        self.assertIn('method "approle"', agent)
        self.assertIn("remove_secret_id_file_after_reading = false", agent)
        self.assertIn("exit_after_auth = false", agent)
        self.assertEqual(report["runtime_renewal"], "OpenBao Agent")

    @patch("ductor_core.openbao._request")
    def test_bootstrap_protects_material_and_report_contains_no_secrets(self, request):
        self.config["credentials"]["openbao_token_file"] = str(self.root / "operator-token")
        request.side_effect = [{"initialized": False}, {"keys_base64": ["sensitive-share"], "root_token": "sensitive-root"}]
        report = bootstrap(self.config)
        path = Path(report["recovery_file"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(path.read_text())["root_token"], "sensitive-root")
        self.assertNotIn("sensitive", json.dumps(report))
        token = Path(report["operator_token_file"])
        self.assertEqual(token.read_text(), "sensitive-root\n")
        self.assertEqual(token.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(OpenBaoError):
            bootstrap(self.config)
        self.assertEqual(request.call_count, 2)

    @patch("ductor_core.openbao._request")
    def test_bootstrap_never_overwrites_existing_operator_token(self, request):
        self.config["credentials"]["openbao_token_file"] = self.private("operator", "existing")
        with self.assertRaises(OpenBaoError):
            bootstrap(self.config)
        request.assert_not_called()
        self.assertEqual(Path(self.config["credentials"]["openbao_token_file"]).read_text(), "existing")

    @patch("ductor_core.openbao._request")
    def test_failed_bootstrap_retains_destination_to_prevent_unsafe_retry(self, request):
        request.side_effect = [{"initialized": False}, OpenBaoError("simulated request failure")]
        with self.assertRaises(OpenBaoError):
            bootstrap(self.config)
        self.assertTrue(Path(self.config["credentials"]["openbao_bootstrap_output_file"]).exists())

    @patch("ductor_core.openbao._request")
    def test_unseal_stops_at_threshold_and_redacts_report(self, request):
        self.config["credentials"]["openbao_unseal_file"] = self.private("shares", json.dumps(["one", "two", "three"]))
        request.side_effect = [{"sealed": True}, {"sealed": True, "progress": 1}, {"sealed": False, "progress": 0}]
        result = unseal(self.config)
        self.assertEqual(result, {"service": "bao", "sealed": False, "progress": 0})
        self.assertEqual(request.call_count, 3)

    @patch("ductor_core.openbao._request")
    def test_provision_scopes_credential_and_uses_native_renewal(self, request):
        self.config["credentials"]["openbao_token_file"] = self.private("operator", "operator-token")
        self.config["credentials"]["openbao_approles"] = {"agents": {
            "role_id_file": str(self.root / "role-id"), "secret_id_file": str(self.root / "secret-id")}}
        def native(service, method, route, **kwargs):
            if route == "sys/mounts":
                return {"data": {"secret/": {"type": "kv", "options": {"version": "2"}}}}
            if route == "sys/auth":
                return {"data": {"approle/": {"type": "approle"}}}
            if route == "sys/audit":
                return {"data": {"ductor/": {"type": "file"}}}
            if route.endswith("/role-id"):
                return {"data": {"role_id": "role-private"}}
            if route.endswith("/secret-id"):
                return {"data": {"secret_id": "secret-private", "secret_id_accessor": "accessor"}}
            return {}
        request.side_effect = native
        result = provision_credentials(self.config)
        self.assertNotIn("secret-private", json.dumps(result))
        self.assertEqual((self.root / "secret-id").stat().st_mode & 0o777, 0o600)
        calls = {call.args[2]: call.kwargs for call in request.call_args_list}
        policy = calls["sys/policies/acl/ductor-agents"]["data"]["policy"]
        self.assertIn('secret/data/gateways/agents/*', policy)
        role = calls["auth/approle/role/ductor-agents"]["data"]
        self.assertEqual(role["token_num_uses"], 0)
        self.assertEqual(role["token_type"], "service")
        with self.assertRaises(OpenBaoError):
            provision_credentials(self.config)


if __name__ == "__main__":
    unittest.main()
