"""Regressions at boundaries that otherwise admit host execution or wrong accounts."""
import json
import tempfile
import unittest
from pathlib import Path

from ductor_core.openclaw import render_openclaw, validate_openclaw


class OpenClawRendererTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.knowledge = self.root / "knowledge"
        self.knowledge.mkdir()
        (self.knowledge / "AGENTS.md").write_text("Use established open interfaces. The operator decides.\n")
        self.config = {
            "services": {"agents": {"kind": "openclaw", "enabled": True,
                "url": "https://agents.example.org", "required_pool": "workers",
                "agents": ["lead", "review"], "trusted_proxies": ["172.20.0.2"]}},
            "incus": {"pools": {"workers": {}}},
            "agents": [
                {"id": "lead", "model": "openai/gpt-6-astra", "role": "orchestrator",
                 "auth_profiles": ["openai:work"], "allow_agents": ["review"]},
                {"id": "review", "model": "openai/gpt-6-astra", "role": "reviewer",
                 "auth_profiles": ["openai:work"]},
            ],
            "model_accounts": {"openai:work": {"provider": "openai", "mode": "oauth"},
                               "openai:review": {"provider": "openai", "mode": "oauth"}},
            "knowledge": {"source_dir": str(self.knowledge)},
            "runtime": {"max_concurrent": 2, "max_children": 2, "max_depth": 1},
        }

    def tearDown(self):
        self.temp.cleanup()

    def render(self):
        render_openclaw(self.config, self.root / "render")
        directory = self.root / "render/services/agents"
        return json.loads((directory / "openclaw.json").read_text()), json.loads((directory / "activation.json").read_text())

    def test_remote_execution_has_no_local_fallback_or_vm_snapshot_claim(self):
        native, _ = self.render()
        worker = native["cloudWorkers"]
        self.assertEqual(worker["requiredProfile"], "workers")
        settings = worker["profiles"]["workers"]["settings"]
        self.assertEqual(settings["binary"], "/usr/local/lib/ductor/crabbox-workers")
        self.assertFalse(settings["warmImage"])
        self.assertNotIn("class", settings)
        self.assertEqual(worker["preparedPool"]["maxTotal"], 0)

    def test_native_bounds_and_separate_readonly_reviewer(self):
        native, _ = self.render()
        agents = native["agents"]
        self.assertEqual(agents["ownership"], "explicit")
        self.assertEqual(agents["defaults"]["subagents"]["maxSpawnDepth"], 1)
        self.assertFalse(native["tools"]["swarm"])
        self.assertEqual(agents["entries"]["lead"]["subagents"]["allowAgents"], ["review"])
        self.assertNotIn("maxConcurrent", agents["entries"]["lead"]["subagents"])
        self.assertIn("exec", agents["entries"]["review"]["tools"]["deny"])
        self.assertIn("sessions_spawn", agents["entries"]["review"]["tools"]["deny"])
        self.assertEqual(agents["entries"]["lead"]["model"]["fallbacks"], [])

    def test_unenrolled_accounts_not_implicitly_rotated(self):
        native, activation = self.render()
        self.assertEqual(native["auth"]["order"]["openai"], ["openai:work"])
        self.assertNotIn("profiles", native["auth"])
        self.assertEqual(activation["auth_order_commands"][0], [
            "models", "auth", "order", "clear", "--agent", "lead", "--provider", "openai"])
        self.assertIn("--device-code", activation["enrollment"][0]["argv"])
        self.assertNotIn("access", json.dumps(native["auth"]))
        self.assertEqual(native["gateway"]["auth"]["token"]["source"], "file")

    def test_rejects_multiple_accounts_on_one_gateway_to_avoid_profile_drift_fallback(self):
        self.config["agents"][1]["auth_profiles"] = ["openai:review"]
        self.assertTrue(any("multiple accounts" in error for error in validate_openclaw(self.config)))

    def test_rejects_image_identity_that_cannot_own_private_runtime_cache(self):
        self.config["services"]["agents"]["uid"] = 1001
        self.assertTrue(any("uid=1000" in error for error in validate_openclaw(self.config)))

    def test_rejects_unsupported_native_codex_and_missing_pool(self):
        self.config["agents"][0]["runtime"] = "codex"
        self.config["services"]["agents"]["required_pool"] = "missing"
        errors = validate_openclaw(self.config)
        self.assertTrue(any("Codex-native" in error for error in errors))
        self.assertTrue(any("required_pool" in error for error in errors))
        with self.assertRaises(ValueError):
            self.render()

    def test_rejects_shared_key_fallback_for_named_accounts(self):
        self.config["services"]["agents"]["provider_keys"] = {"openai": "gateways/agents/openai/key"}
        self.assertTrue(any("cannot mix" in error for error in validate_openclaw(self.config)))

    def test_provider_key_is_vault_reference_and_never_inline(self):
        for agent in self.config["agents"]:
            agent["auth_profiles"] = []
        self.config["services"]["agents"]["provider_keys"] = {"openai": "gateways/agents/openai/key"}
        native, _ = self.render()
        self.assertEqual(native["models"]["providers"]["openai"]["apiKey"], {
            "source": "exec", "provider": "vault", "id": "gateways/agents/openai/key"})
        self.assertEqual(native["secrets"]["providers"]["vault"]["pluginIntegration"]["pluginId"], "vault")

    def test_company_context_reaches_each_assigned_agent_only(self):
        self.config["agents"].append({"id": "unassigned", "model": "invalid"})
        _, activation = self.render()
        state = self.root / "render/services/agents/state"
        for aid in ("lead", "review"):
            self.assertIn("The operator decides.", (state / "workspaces" / aid / "AGENTS.md").read_text())
        self.assertFalse((state / "workspaces/unassigned").exists())
        self.assertTrue(activation["knowledge_commands"])

    def test_knowledge_links_and_oversized_bootstrap_are_rejected(self):
        (self.knowledge / "escape.md").symlink_to(self.root / "outside.md")
        self.assertTrue(any("symlink" in error for error in validate_openclaw(self.config)))
        (self.knowledge / "escape.md").unlink()
        (self.knowledge / "AGENTS.md").write_text("x" * 12001)
        self.assertTrue(any("12000" in error for error in validate_openclaw(self.config)))

    def test_proxy_team_bootstraps_without_admin_default(self):
        self.config["services"]["agents"]["team"] = {
            "user_header": "x-auth-user", "required_headers": ["x-auth-verified"],
            "allow_users": ["owner@example.org"], "admin_users": ["owner@example.org"]}
        native, activation = self.render()
        gateway = native["gateway"]
        self.assertEqual(gateway["auth"]["mode"], "trusted-proxy")
        self.assertNotIn("token", gateway["auth"])
        self.assertIn("password", gateway["auth"])
        self.assertEqual(gateway["roles"]["default"], "observer")
        self.assertFalse(gateway["auth"]["trustedProxy"]["allowLoopback"])
        self.assertIn("team_bootstrap", activation)

    def test_mcp_scoping_uses_verified_server_prefix_and_explicit_tools(self):
        self.config["services"]["agents"]["mcp_servers"] = {
            "docs": {"url": "https://docs.example.org/mcp", "tools": ["search", "read_*"]}}
        self.config["agents"][0]["mcp_servers"] = ["docs"]
        native, activation = self.render()
        self.assertEqual(native["mcp"]["servers"]["docs"]["toolFilter"]["include"], ["search", "read_*"])
        self.assertIn("docs__*", native["agents"]["entries"]["review"]["tools"]["deny"])
        self.assertNotIn("docs__*", native["agents"]["entries"]["lead"]["tools"]["deny"])
        self.assertIn(["mcp", "doctor", "docs", "--probe"], activation["verification_commands"])

    def test_mcp_inline_credentials_and_unsafe_names_are_rejected(self):
        self.config["services"]["agents"]["mcp_servers"] = {
            "not safe": {"url": "https://user:secret@example.org/mcp", "tools": ["read"],
                         "headers": {"Authorization": "secret"}}}
        errors = validate_openclaw(self.config)
        self.assertTrue(any("provider-safe" in error for error in errors))
        self.assertTrue(any("unsupported fields" in error for error in errors))
        self.assertTrue(any("without credentials" in error for error in errors))

    def test_canonical_git_protocol_is_explicit_and_bounded(self):
        self.config["knowledge"]["repository"] = {"url": "https://git.example.org/company/knowledge.git", "branch": "main"}
        _, activation = self.render()
        instructions = (self.root / "render/services/agents/state/workspaces/lead/AGENTS.md").read_text()
        self.assertIn("at most 20 commits", instructions)
        self.assertIn("not automatically synchronized", instructions)
        self.assertEqual(activation["knowledge_repository"]["branch"], "main")
        self.assertEqual(len(activation["knowledge_sha256"]["AGENTS.md"]), 64)


if __name__ == "__main__":
    unittest.main()
