from pathlib import Path
from ductor_core.config import empty_config


def complete_config(root):
    root = Path(root)
    knowledge = root / 'knowledge'
    knowledge.mkdir(exist_ok=True)
    (knowledge / 'AGENTS.md').write_text('# Company standards\nUse portable formats and reviewed changes.\n')
    config = empty_config('example')
    config['hosts'] = {'control': {
        'address': '127.0.0.1', 'port': 2222, 'user': 'deploy', 'identity_file': str(root / 'ssh-key'),
        'known_hosts_file': str(root / 'known-hosts'), 'become': True, 'data_root': '/srv/ductor',
        'roles': ['services', 'incus'], 'resources': {'cpus': 16, 'memory_mib': 32768, 'disk_gib': 250,
        'reserve_cpus': 2, 'reserve_memory_mib': 4096, 'reserve_disk_gib': 30}}}
    config['incus'] = {'pools': {'workers': {
        'host': 'control', 'address': 'https://incus.example.org:8443', 'project': 'ductor-workers',
        'profile': 'ductor-worker', 'instance_type': 'virtual-machine', 'image_fingerprint': 'a' * 64,
        'image_source_project': 'default', 'worker_node_version': '24.16.0', 'allow_vm_lowlevel': True,
        'network': 'incusbr0', 'network_acl': 'ductor-workers', 'storage_pool': 'default',
        'client_certificate_file': str(root / 'incus.crt'), 'client_key_file': str(root / 'incus.key'),
        'server_certificate_file': str(root / 'server.crt'), 'cpus': 8, 'memory_mib': 16384, 'disk_gib': 120,
        'instance_cpus': 2, 'instance_memory_mib': 4096, 'instance_disk_gib': 30, 'max_instances': 4}}}
    config['services'] = {
        'bao': {'kind': 'openbao', 'host': 'control', 'enabled': True, 'image': 'ghcr.io/openbao/openbao:2.7.1',
                'bind_address': '127.0.0.1', 'port': 8200, 'url': 'https://bao.example.org',
                'cpus': 1, 'memory_mib': 1024, 'disk_gib': 20},
        'agents': {'kind': 'openclaw', 'host': 'control', 'enabled': True, 'image': 'ghcr.io/openclaw/openclaw:2026.10.5',
                   'bind_address': '127.0.0.1', 'port': 18789, 'url': 'https://agents.example.org',
                   'cpus': 2, 'memory_mib': 4096, 'disk_gib': 40, 'required_pool': 'workers',
                   'agents': ['lead', 'worker', 'reviewer'], 'trusted_proxies': [],
                   'allowed_origins': ['https://agents.example.org'], 'openbao_service': 'bao',
                   'provider_keys': {'openai': 'gateways/agents/openai/apiKey'}}}
    config['agents'] = [{'id': aid, 'name': aid.title(), 'model': 'openai/gpt-6-astra',
                         'runtime': 'openclaw', 'role': role, 'auth_profiles': [],
                         'allow_agents': ['worker', 'reviewer'] if role == 'orchestrator' else []}
                        for aid, role in [('lead','orchestrator'), ('worker','worker'), ('reviewer','reviewer')]]
    config['knowledge'] = {'source_dir': str(knowledge)}
    config['credentials'] = {'gateway_token_files': {'agents': str(root / 'gateway-token')},
        'openbao_token_file': str(root / 'operator-token'), 'openbao_unseal_file': str(root / 'recovery.json'),
        'openbao_bootstrap_output_file': str(root / 'recovery.json'),
        'openbao_approles': {'agents': {'role_id_file': str(root / 'role-id'), 'secret_id_file': str(root / 'secret-id')}}}
    return config
