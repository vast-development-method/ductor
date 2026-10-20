import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from ductor_core import cli
from ductor_core.config import validate, load_config
from ductor_core.inventory import build_inventory, verify_ssh_files
from ductor_core.util import state_lock, write_private
from fixtures import complete_config


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.config = complete_config(self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_full_contract_and_initial_missing_credential_refs_render(self):
        self.assertEqual(validate(self.config), [])
        directory, inventory = cli.render(self.config, self.root / 'state')
        self.assertTrue((directory / 'services/bao/server.hcl').exists())
        native = json.loads((directory / 'services/agents/openclaw.json').read_text())
        self.assertEqual(native['cloudWorkers']['requiredProfile'], 'workers')
        self.assertNotIn('operator-token', json.dumps(native))
        self.assertEqual((directory / 'inventory.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(inventory['all']['children']['ductor_hosts']['hosts']['control']['ansible_connection'], 'ssh')

    def test_combined_reservations_and_vm_instance_limits_reject_overcommit(self):
        self.config['hosts']['control']['resources']['cpus'] = 12
        self.assertTrue(any('OS reserve' in error for error in validate(self.config)))
        self.config['hosts']['control']['resources']['cpus'] = 16
        self.config['incus']['pools']['workers']['max_instances'] = 5
        self.assertTrue(any('max_instances' in error for error in validate(self.config)))

    def test_wrong_services_unknown_fields_and_duplicate_json_fail_closed(self):
        for field, value in [('secret_value', 'do-not-print'), ('raft_peers', []), ('typo', True)]:
            bad = copy.deepcopy(self.config)
            bad['services']['bao'][field] = value
            self.assertTrue(validate(bad))
        path = self.root / 'duplicate.json'
        path.write_text('{"schema_version":2,"schema_version":1}')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            load_config(path)

    def test_wildcard_port_collision_and_shell_host_rejected(self):
        self.config['services']['agents']['port'] = 8200
        self.config['services']['agents']['bind_address'] = '0.0.0.0'
        self.assertTrue(any('port conflicts' in error for error in validate(self.config)))
        self.config['hosts']['control']['address'] = '-oProxyCommand=evil'
        self.assertTrue(any('invalid hostname' in error for error in validate(self.config)))

    def test_selected_service_never_mutates_an_unselected_host_pool(self):
        inventory = build_inventory(self.config, cli.BUNDLE, self.root, service_filter='bao')
        host = inventory['all']['children']['ductor_hosts']['hosts']['control']
        self.assertEqual([s['id'] for s in host['ductor_services']], ['bao'])
        self.assertEqual(host['ductor_pools'], [])
        self.assertIn('StrictHostKeyChecking=yes', host['ansible_ssh_common_args'])
        with self.assertRaises(ValueError):
            build_inventory(self.config, cli.BUNDLE, self.root, host_filter='wrong')

    @patch('ductor_core.cli.subprocess.run')
    def test_render_and_plan_never_contact_remote_hosts(self, run):
        self.assertEqual(cli.operation(self.config, self.root / 'state', 'plan'), 0)
        run.assert_not_called()

    def test_untrusted_ssh_key_and_concurrent_controller_refused(self):
        inventory = build_inventory(self.config, cli.BUNDLE, self.root)
        with self.assertRaises(ValueError):
            verify_ssh_files(inventory)
        state = self.root / 'state'
        with state_lock(state):
            with self.assertRaisesRegex(ValueError, 'Another'):
                with state_lock(state):
                    pass

    def test_cli_init_is_private_and_never_overwrites(self):
        state = self.root / 'state'
        self.assertEqual(cli.main(['--state-dir', str(state), 'init']), 0)
        self.assertEqual((state / 'config.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(cli.main(['--state-dir', str(state), 'init']), 1)

    @patch('ductor_core.cli.subprocess.run')
    def test_host_trust_rejects_unmatched_scanned_fingerprint(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, 'host ssh-ed25519 AAAA\n', '')
        with self.assertRaisesRegex(ValueError, 'do not match'):
            cli.trust_host(self.config, self.root, 'control', 'SHA256:' + 'a' * 43)
        self.assertFalse((self.root / 'known-hosts').exists())

    def test_symlink_state_and_secret_outputs_refused(self):
        outside = self.root / 'outside'
        outside.mkdir()
        link = self.root / 'state'
        link.symlink_to(outside)
        with self.assertRaises(ValueError):
            write_private(link / 'file', 'private')
