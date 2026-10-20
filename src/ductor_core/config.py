"""Strict desired-state validation and resource admission before SSH."""
from pathlib import Path
from urllib.parse import urlsplit
import importlib
import ipaddress
import json
import re

ID = re.compile(r"^[a-z][a-z0-9-]{0,47}$")
IMAGE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9./_-]*(?::[a-zA-Z0-9._-]+)?@sha256:[a-f0-9]{64}$|^[a-zA-Z0-9][a-zA-Z0-9./_-]*:[a-zA-Z0-9._-]+$")
ROOT_KEYS = {"schema_version", "name", "hosts", "services", "service_vms", "incus", "agents", "model_accounts", "knowledge", "credentials", "runtime"}
HOST_KEYS = {"address", "port", "user", "identity_file", "known_hosts_file", "become", "data_root", "resources", "roles"}
RESOURCE_KEYS = {"cpus", "memory_mib", "disk_gib", "reserve_cpus", "reserve_memory_mib", "reserve_disk_gib"}
SERVICE_KEYS = {"kind", "host", "enabled", "image", "bind_address", "port", "url", "cpus", "memory_mib", "disk_gib", "trusted_proxies", "allowed_origins", "required_pool", "agents", "provider_keys", "team", "ca_file", "uid", "gid", "openbao_service", "kv_mount", "gateway_token_file", "mcp_servers", "unseal_shares", "unseal_threshold", "database_image", "database_cpus", "database_memory_mib", "site_name", "admin_username", "admin_email", "mcp_client"}


def empty_config(name="company"):
    return {"schema_version": 2, "name": name, "hosts": {}, "services": {},
            "incus": {"pools": {}}, "service_vms": {}, "agents": [], "model_accounts": {},
            "runtime": {"max_concurrent": 4, "max_children": 2, "max_depth": 2, "run_timeout_seconds": 1800},
            "knowledge": {"source_dir": ""}, "credentials": {}}


def load_config(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    try:
        return json.loads(Path(path).read_text(), object_pairs_hook=unique)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read configuration {path}: {exc}") from exc


def validate(config, integrations=True):
    errors = []
    def fail(message):
        errors.append(message)
    def mapping(value, label):
        if not isinstance(value, dict):
            fail(f"{label}: expected object")
            return {}
        return value
    def unknown(value, allowed, label):
        for key in value.keys() - allowed:
            fail(f"{label}: unsupported field {key}")
    def positive(value, label, zero=False):
        if type(value) is not int or value < (0 if zero else 1):
            fail(f"{label}: expected {'non-negative' if zero else 'positive'} integer")
            return 0
        return value
    def absolute(value, label):
        if not isinstance(value, str) or not value.startswith("/") or ".." in Path(value).parts or any(c in value for c in "\n\r\x00"):
            fail(f"{label}: expected absolute path without traversal/control characters")
    def identifier(value, label):
        if not isinstance(value, str) or not ID.fullmatch(value):
            fail(f"{label}: use lowercase letters, digits, and hyphens; start with a letter")
    config = mapping(config, "config")
    unknown(config, ROOT_KEYS, "config")
    if config.get("schema_version") != 2:
        fail("schema_version must be 2; v1 runtime configurations are not compatible")
    identifier(config.get("name"), "name")
    hosts = mapping(config.get("hosts"), "hosts")
    if not hosts:
        fail("At least one SSH host is required")
    allocations = {}
    for key, value in hosts.items():
        identifier(key, "host id")
        if key in {"localhost", "all", "ungrouped", "ductor-hosts", "ductor_hosts"}:
            fail(f"hosts.{key}: reserved Ansible host identifier")
        host = mapping(value, f"hosts.{key}")
        unknown(host, HOST_KEYS, f"hosts.{key}")
        address = host.get("address", "")
        if not isinstance(address, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", address):
            fail(f"hosts.{key}.address: invalid hostname/IP")
        if not re.fullmatch(r"[a-z_][a-z0-9_-]*", str(host.get("user", ""))):
            fail(f"hosts.{key}.user: invalid SSH user")
        port = positive(host.get("port"), f"hosts.{key}.port")
        if port > 65535:
            fail(f"hosts.{key}.port exceeds 65535")
        for field in ("identity_file", "known_hosts_file", "data_root"):
            absolute(host.get(field), f"hosts.{key}.{field}")
        if host.get("identity_file") == host.get("known_hosts_file"):
            fail(f"hosts.{key}: SSH identity and host trust must use distinct files")
        if host.get("data_root") in ("/", "/etc", "/usr", "/var", "/home", "/root"):
            fail(f"hosts.{key}.data_root must be a dedicated directory")
        if type(host.get("become")) is not bool:
            fail(f"hosts.{key}.become must be boolean")
        roles = host.get("roles", [])
        if not isinstance(roles, list) or not roles or any(r not in ("services", "incus") for r in roles):
            fail(f"hosts.{key}.roles: select services and/or incus")
        resources = mapping(host.get("resources"), f"hosts.{key}.resources")
        unknown(resources, RESOURCE_KEYS, f"hosts.{key}.resources")
        for field in RESOURCE_KEYS:
            positive(resources.get(field), f"hosts.{key}.resources.{field}")
        allocations[key] = {r: 0 for r in ("cpus", "memory_mib", "disk_gib")}
    services = mapping(config.get("services"), "services")
    binds = {}
    for key, value in services.items():
        identifier(key, "service id")
        service = mapping(value, f"services.{key}")
        unknown(service, SERVICE_KEYS, f"services.{key}")
        if service.get("kind") not in ("openclaw", "openbao", "joomengine"):
            fail(f"services.{key}.kind: supported services are openclaw, openbao and joomengine")
        if type(service.get("enabled")) is not bool:
            fail(f"services.{key}.enabled must be boolean")
        common = {"kind", "host", "enabled", "image", "bind_address", "port", "url", "cpus", "memory_mib", "disk_gib", "uid", "gid"}
        if service.get("kind") == "joomengine":
            common -= {"uid", "gid"}
        specific = ({"database_image", "database_cpus", "database_memory_mib", "site_name", "admin_username", "admin_email", "mcp_client"} if service.get("kind") == "joomengine" else
                    {"ca_file", "kv_mount", "unseal_shares", "unseal_threshold"} if service.get("kind") == "openbao"
                    else {"trusted_proxies", "allowed_origins", "required_pool", "agents", "provider_keys", "team", "openbao_service", "gateway_token_file", "mcp_servers"})
        unknown(service, common | specific, f"services.{key}")
        for field in ("uid", "gid"):
            if field in service:
                positive(service[field], f"services.{key}.{field}")
        for field in ("trusted_proxies", "allowed_origins", "agents"):
            if field in service and (not isinstance(service[field], list) or any(not isinstance(v, str) for v in service[field])):
                fail(f"services.{key}.{field} must be a list of strings")
        for field in ("provider_keys", "mcp_servers", "team"):
            if field in service and not isinstance(service[field], dict):
                fail(f"services.{key}.{field} must be an object")
        if isinstance(service.get("team"), dict):
            unknown(service["team"], {"user_header", "required_headers", "allow_users", "admin_users"}, f"services.{key}.team")
        host_id = service.get("host")
        if host_id not in hosts or "services" not in hosts.get(host_id, {}).get("roles", []):
            fail(f"services.{key}.host: select an enrolled services host")
        image = service.get("image", "")
        if not isinstance(image, str) or not IMAGE.fullmatch(image) or image.rsplit(":", 1)[-1] in ("latest", "main", "master", "dev"):
            fail(f"services.{key}.image: use an explicit release tag or sha256 digest")
        try:
            ipaddress.ip_address(service.get("bind_address", ""))
        except ValueError:
            fail(f"services.{key}.bind_address must be an explicit IP")
        port = positive(service.get("port"), f"services.{key}.port")
        if port > 65535:
            fail(f"services.{key}.port exceeds 65535")
        url = urlsplit(str(service.get("url", "")))
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ("", "/"):
            fail(f"services.{key}.url: expected own HTTPS origin (external TLS required)")
        if service.get("enabled"):
            for other, (other_host, other_bind, other_port) in binds.items():
                if host_id == other_host and port == other_port and (service.get("bind_address") == other_bind or service.get("bind_address") in ("0.0.0.0", "::") or other_bind in ("0.0.0.0", "::")):
                    fail(f"services.{key}: port conflicts with {other}")
            binds[key] = (host_id, service.get("bind_address"), port)
        for resource in ("cpus", "memory_mib", "disk_gib"):
            amount = positive(service.get(resource), f"services.{key}.{resource}")
            if service.get("enabled") and host_id in allocations:
                allocations[host_id][resource] += amount
    incus = mapping(config.get("incus", {}), "incus")
    unknown(incus, {"pools", "bootstrap"}, "incus")
    for key, value in mapping(incus.get("pools", {}), "incus.pools").items():
        identifier(key, "pool id")
        pool = mapping(value, f"incus.pools.{key}")
        unknown(pool, {"host", "address", "project", "profile", "instance_type", "image_fingerprint", "image_source_project", "worker_node_version", "allow_vm_lowlevel", "network", "network_acl", "storage_pool", "client_certificate_file", "client_key_file", "server_certificate_file", "cpus", "memory_mib", "disk_gib", "instance_cpus", "instance_memory_mib", "instance_disk_gib", "max_instances", "image_import"}, f"incus.pools.{key}")
        host_id = pool.get("host")
        if host_id not in hosts or "incus" not in hosts.get(host_id, {}).get("roles", []):
            fail(f"incus.pools.{key}.host: select an enrolled incus host")
        for resource in ("cpus", "memory_mib", "disk_gib"):
            amount = positive(pool.get(resource), f"incus.pools.{key}.{resource}")
            if host_id in allocations:
                allocations[host_id][resource] += amount
        count = positive(pool.get("max_instances"), f"incus.pools.{key}.max_instances")
        for resource in ("cpus", "memory_mib", "disk_gib"):
            per_instance = positive(pool.get(f"instance_{resource}"), f"incus.pools.{key}.instance_{resource}")
            budget = pool.get(resource, 0)
            if type(budget) is int and count * per_instance > budget:
                fail(f"incus.pools.{key}: max_instances × instance_{resource} exceeds pool {resource} budget")
    # Charge a service VM to its physical host; services inside it are charged
    # separately to the guest budget, which must leave room for its operating OS.
    for key, value in mapping(config.get("service_vms", {}), "service_vms").items():
        identifier(key, "service VM id")
        vm = mapping(value, f"service_vms.{key}")
        hypervisor = vm.get("hypervisor")
        guest = vm.get("guest_host")
        if not isinstance(hypervisor, str) or not isinstance(guest, str):
            fail(f"service_vms.{key}: hypervisor and guest_host must be enrolled host ids")
            continue
        for resource in ("cpus", "memory_mib", "disk_gib"):
            amount = positive(vm.get(resource), f"service_vms.{key}.{resource}")
            if hypervisor in allocations:
                allocations[hypervisor][resource] += amount
            guest_budget = hosts.get(guest, {}).get("resources", {}).get(resource)
            if type(guest_budget) is int and guest_budget > amount:
                fail(f"service_vms.{key}: guest {resource} budget exceeds its VM allocation")
    for host_id, allocated in allocations.items():
        resource = hosts[host_id].get("resources", {})
        for key, amount in allocated.items():
            total, reserve = resource.get(key, 0), resource.get(f"reserve_{key}", 0)
            if type(total) is int and type(reserve) is int and amount + reserve > total:
                fail(f"hosts.{host_id}: {key} allocations {amount} + OS reserve {reserve} exceed capacity {total}")
    agents = config.get("agents", [])
    if not isinstance(agents, list):
        fail("agents must be a list")
        agents = []
    seen_agents = set()
    for agent in agents:
        agent = mapping(agent, "agent")
        unknown(agent, {"id", "name", "model", "runtime", "role", "auth_profiles", "allow_agents", "mcp_servers"}, "agent")
        identifier(agent.get("id"), "agent.id")
        aid = str(agent.get("id"))
        if aid in seen_agents:
            fail(f"Duplicate agent id: {aid}")
        seen_agents.add(aid)
        for field in ("auth_profiles", "allow_agents", "mcp_servers"):
            if field in agent and (not isinstance(agent[field], list) or any(not isinstance(v, str) for v in agent[field])):
                fail(f"agents.{aid}.{field} must be a list of strings")
    runtime = mapping(config.get("runtime", {}), "runtime")
    unknown(runtime, {"max_concurrent", "max_children", "max_depth", "run_timeout_seconds"}, "runtime")
    accounts = mapping(config.get("model_accounts", {}), "model_accounts")
    for account, value in accounts.items():
        unknown(mapping(value, f"model_accounts.{account}"), {"provider", "mode"}, f"model_accounts.{account}")
    knowledge = mapping(config.get("knowledge", {}), "knowledge")
    unknown(knowledge, {"source_dir", "repository"}, "knowledge")
    if "repository" in knowledge:
        unknown(mapping(knowledge["repository"], "knowledge.repository"), {"url", "branch"}, "knowledge.repository")
    credentials = mapping(config.get("credentials", {}), "credentials")
    unknown(credentials, {"gateway_token_files", "openbao_token_file", "openbao_bootstrap_output_file", "openbao_unseal_file", "openbao_approles", "joomengine_files", "joomengine_client_files"}, "credentials")
    for field in ("openbao_token_file", "openbao_bootstrap_output_file", "openbao_unseal_file"):
        if field in credentials:
            absolute(credentials[field], f"credentials.{field}")
    for sid, value in mapping(credentials.get("gateway_token_files", {}), "credentials.gateway_token_files").items():
        absolute(value, f"credentials.gateway_token_files.{sid}")
    for group in ("joomengine_files", "joomengine_client_files"):
        for sid, value in mapping(credentials.get(group, {}), f"credentials.{group}").items():
            absolute(value, f"credentials.{group}.{sid}")
    for sid, value in mapping(credentials.get("openbao_approles", {}), "credentials.openbao_approles").items():
        refs = mapping(value, f"credentials.openbao_approles.{sid}")
        unknown(refs, {"role_id_file", "secret_id_file"}, f"credentials.openbao_approles.{sid}")
        for field in ("role_id_file", "secret_id_file"):
            absolute(refs.get(field), f"credentials.openbao_approles.{sid}.{field}")
    for key in credentials:
        if any(word in key.lower() for word in ("password", "secret_value", "api_key", "access_token")):
            fail(f"credentials.{key}: store secret values in protected files or OpenBao, not desired state")
    if not errors:
        # This contract is structural and applies to operations as well as deploy.
        from .service_vm import validate_service_vms
        errors.extend(validate_service_vms(config))
    if integrations and not errors:
        for module_name, function in (("openclaw", "validate_openclaw"), ("crabbox", "validate_pools"), ("openbao", "validate_openbao"), ("joomengine", "validate_joomengine")):
            module = importlib.import_module(f"ductor_core.{module_name}")
            errors.extend(getattr(module, function)(config))
    return errors


def require_valid(config):
    errors = validate(config)
    if errors:
        raise ValueError("Configuration is not deployable:\n- " + "\n- ".join(errors))
