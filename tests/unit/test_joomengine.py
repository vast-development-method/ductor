import copy
import json
import os
from pathlib import Path
import tempfile
import unittest

from ductor_core.bundle import export_bundle, import_bundle
from ductor_core.cli import render
from ductor_core.config import validate
from ductor_core.joomengine import create_credentials, read_credentials, render_joomengine, validate_joomengine
from ductor_core.service_vm import service_vm_documents, validate_service_vms
from fixtures import complete_config
from test_service_vm import example as vm_example


def fixture(root):
    root = Path(root)
    config = complete_config(root)
    config['services'] = {'joomla': {
        'kind': 'joomengine', 'host': 'control', 'enabled': True,
        'image': 'octoleo/joomengine:6.2.0-php8.4-apache-mcp@sha256:' + 'a' * 64,
        'database_image': 'mariadb:11.4@sha256:' + 'b' * 64,
        'bind_address': '127.0.0.1', 'port': 8080, 'url': 'https://joomla.example.org',
        'cpus': 4, 'memory_mib': 4096, 'disk_gib': 40, 'database_cpus': 1, 'database_memory_mib': 1024,
        'site_name': 'Company Joomla', 'admin_username': 'siteowner', 'admin_email': 'owner@example.org',
        'mcp_client': {'id': 'developer', 'username': 'agentreader', 'name': 'Development Agent',
                       'email': 'agent@example.org', 'permissions': {}}}}
    config['incus'] = {'pools': {}}
    config['agents'] = []
    config['credentials'] = {'joomengine_files': {'joomla': str(root / 'credentials.json')},
                             'joomengine_client_files': {'joomla': str(root / 'client.json')}}
    return config


class JoomEngineTests(unittest.TestCase):
    def test_valid_service_renders_without_reading_or_serializing_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            config = fixture(directory)
            self.assertEqual(validate(config), [])
            render(config, Path(directory) / 'state', service='joomla')
            create_credentials(config, 'joomla')
            secrets = read_credentials(config, 'joomla')
            output, _ = render(config, Path(directory) / 'state', service='joomla')
            rendered = '\n'.join(p.read_text() for p in output.rglob('*') if p.is_file())
            for secret in secrets.values():
                self.assertNotIn(secret, rendered)
            compose = json.loads((output / 'services/joomla/compose.yaml').read_text())
            self.assertEqual(compose['services']['joomla']['ports'][0]['published'], '8080')
            self.assertNotIn('ports', compose['services']['database'])
            self.assertTrue(compose['networks']['database']['internal'])
            for service in compose['services'].values():
                self.assertEqual(service['restart'], 'unless-stopped')
                self.assertNotIn('privileged', service)
                self.assertNotIn('/var/run/docker.sock', json.dumps(service))
            self.assertEqual(sum(s['cpus'] for s in compose['services'].values()), 4)

    def test_generated_credentials_are_distinct_private_and_never_rotated_implicitly(self):
        with tempfile.TemporaryDirectory() as directory:
            config = fixture(directory)
            result = create_credentials(config, 'joomla')
            path = Path(result['file'])
            before = path.read_bytes()
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(set(read_credentials(config, 'joomla').values())), 4)
            self.assertFalse(create_credentials(config, 'joomla')['created'])
            self.assertEqual(path.read_bytes(), before)
            self.assertNotIn('admin_password', json.dumps(result))
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                read_credentials(config, 'joomla')

    def test_unsafe_credential_links_unknown_keys_and_reused_passwords_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            config = fixture(directory)
            create_credentials(config, 'joomla')
            path = Path(config['credentials']['joomengine_files']['joomla'])
            value = read_credentials(config, 'joomla')
            for invalid in ({**value, 'token': 'hidden'}, {key: 'a' * 40 for key in value}):
                path.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    read_credentials(config, 'joomla')
            path.unlink()
            target = Path(directory) / 'target'
            target.write_text(json.dumps(value))
            target.chmod(0o600)
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                create_credentials(config, 'joomla')

    def test_pins_resource_split_and_scoped_identity_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            base = fixture(directory)
            for key, value in [('image', 'octoleo/joomengine:latest-mcp'),
                               ('image', 'octoleo/joomengine:6.2.0-php8.4-fpm-mcp@sha256:' + 'a' * 64),
                               ('database_image', 'mariadb:latest'), ('database_cpus', 4),
                               ('database_memory_mib', 4000), ('admin_username', 'invalid--user')]:
                config = copy.deepcopy(base)
                config['services']['joomla'][key] = value
                self.assertTrue(validate_joomengine(config), key)
            for permissions in ({'root.1': {'core.admin': True}}, {'com_content': {'core.login.admin': True}}, {'root.1': {'core.manage': True}}):
                config = copy.deepcopy(base)
                config['services']['joomla']['mcp_client']['permissions'] = permissions
                self.assertTrue(validate_joomengine(config))
            config = copy.deepcopy(base)
            config['services']['joomla']['mcp_client']['permissions'] = {'com_componentbuilder': {'core.admin': True}, 'com_installer': {'core.admin': True}}
            self.assertEqual(validate_joomengine(config), [])

    def test_joomengine_service_vm_is_persistent_dedicated_and_uses_fixed_port(self):
        config = vm_example()
        config['services']['agents']['kind'] = 'joomengine'
        self.assertEqual(validate_service_vms(config), [])
        profile = service_vm_documents(config, 'gateway')['profile.json']
        self.assertEqual(profile['config']['boot.autostart'], 'true')
        self.assertNotIn('expires', json.dumps(profile))
        config['services']['other'] = dict(config['services']['agents'])
        self.assertTrue(validate_service_vms(config))

    def test_controller_bundle_carries_and_rebases_service_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = fixture(root)
            create_credentials(config, 'joomla')
            client = root / 'client.json'
            client.write_text('{"token":"private-token"}')
            client.chmod(0o600)
            export_bundle(config, root / 'state', root / 'controller.zip')
            destination = root / 'second'
            result = import_bundle(root / 'controller.zip', destination, destination / 'config.json')
            imported = json.loads((destination / 'config.json').read_text())
            self.assertEqual(read_credentials(config, 'joomla'), read_credentials(imported, 'joomla'))
            self.assertNotEqual(imported['credentials']['joomengine_files']['joomla'], config['credentials']['joomengine_files']['joomla'])
            self.assertEqual(Path(imported['credentials']['joomengine_client_files']['joomla']).read_text(), client.read_text())


if __name__ == '__main__':
    unittest.main()
