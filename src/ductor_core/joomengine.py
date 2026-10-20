"""Persistent JoomEngine services; all runtime work belongs to native containers."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import secrets

from .config import load_config
from .util import check_private_file, private_dir

SECRET_KEYS = ("admin_password", "database_password", "database_root_password", "mcp_password")
_DIGEST = r"@sha256:[a-f0-9]{64}"


def validate_joomengine(config):
    errors = []
    for name, service in config.get("services", {}).items():
        if service.get("kind") != "joomengine":
            continue
        label = "services." + name
        image = str(service.get("image", ""))
        if not re.fullmatch(r"(?:docker.io/)?octoleo/joomengine:(?:[A-Za-z0-9_.-]+-apache-mcp|latest-mcp|6-mcp)" + _DIGEST, image):
            errors.append(f"{label}.image must pin an official Apache -mcp image tag and sha256 digest")
        if not re.fullmatch(r"(?:docker.io/(?:library/)?)?mariadb:[A-Za-z0-9_.-]+" + _DIGEST, str(service.get("database_image", ""))):
            errors.append(f"{label}.database_image must pin a MariaDB release tag and sha256 digest")
        for field, total, minimum in (("database_cpus", "cpus", 1), ("database_memory_mib", "memory_mib", 512)):
            value, budget = service.get(field), service.get(total)
            if type(value) is not int or value < minimum or type(budget) is not int or budget - value < minimum:
                errors.append(f"{label}.{field} must reserve at least {minimum} for both database and Joomla within {total}")
        if not re.fullmatch(r"[a-zA-Z]{3,32}", str(service.get("admin_username", ""))):
            errors.append(f"{label}.admin_username must be 3-32 letters (upstream bootstrap contract)")
        if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", str(service.get("admin_email", ""))):
            errors.append(f"{label}.admin_email must be a valid email address")
        title = service.get("site_name", "")
        if not isinstance(title, str) or not 3 <= len(title) <= 100 or any(ord(c) < 32 for c in title):
            errors.append(f"{label}.site_name requires 3-100 printable characters")
        client = service.get("mcp_client")
        if not isinstance(client, dict) or set(client) != {"id", "username", "name", "email", "permissions"}:
            errors.append(f"{label}.mcp_client requires id, username, name, email and permissions")
            continue
        for field in ("id", "username"):
            if not re.fullmatch(r"[a-z][a-z0-9_-]{2,47}", str(client.get(field, ""))):
                errors.append(f"{label}.mcp_client.{field} must be a 3-48 character identifier")
        if client.get("username") == service.get("admin_username"):
            errors.append(f"{label}.mcp_client must use a separate dedicated identity")
        if not isinstance(client.get("name"), str) or not 3 <= len(client["name"]) <= 100:
            errors.append(f"{label}.mcp_client.name must be 3-100 characters")
        if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", str(client.get("email", ""))):
            errors.append(f"{label}.mcp_client.email must be a valid email address")
        permissions = client.get("permissions")
        if not isinstance(permissions, dict):
            errors.append(f"{label}.mcp_client.permissions must be an explicit Joomla ACL map")
        else:
            for asset, actions in permissions.items():
                if not re.fullmatch(r"com_[a-z0-9_]+(?:\.[a-z0-9_.-]+)?", str(asset)) or not isinstance(actions, dict):
                    errors.append(f"{label}.mcp_client.permissions contains an invalid asset")
                    continue
                for action, allowed in actions.items():
                    if not re.fullmatch(r"[a-z][a-z0-9_.-]+", str(action)) or allowed is not True or action == "core.login.admin" or (action == "core.admin" and asset not in ("com_componentbuilder", "com_installer")):
                        errors.append(f"{label}.mcp_client.permissions requires explicit actions; administrative grants are forbidden")
        for group in ("joomengine_files", "joomengine_client_files"):
            value = config.get("credentials", {}).get(group, {}).get(name)
            if not isinstance(value, str) or not Path(value).is_absolute():
                errors.append(f"credentials.{group}.{name} requires an absolute protected file path")
        if config.get("credentials", {}).get("joomengine_files", {}).get(name) == config.get("credentials", {}).get("joomengine_client_files", {}).get(name):
            errors.append(f"{label}: deployment secrets and client credentials require distinct files")
    return errors


def _select(config, service_id):
    service = config.get("services", {}).get(service_id, {})
    if service.get("kind") != "joomengine" or not service.get("enabled"):
        raise ValueError("Select an enabled JoomEngine service")
    return service


def read_credentials(config, service_id):
    _select(config, service_id)
    path = check_private_file(config["credentials"]["joomengine_files"][service_id])
    if path.stat().st_size > 16384:
        raise ValueError("JoomEngine credentials exceed the size limit")
    value = load_config(path)
    if not isinstance(value, dict) or set(value) != set(SECRET_KEYS):
        raise ValueError("JoomEngine credentials must contain exactly the four generated password fields")
    if any(not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", v) for v in value.values()) or len(set(value.values())) != 4:
        raise ValueError("JoomEngine credentials require four distinct, 32-128 character URL-safe secrets")
    return value


def create_credentials(config, service_id):
    _select(config, service_id)
    path = Path(config["credentials"]["joomengine_files"][service_id])
    if path.exists():
        read_credentials(config, service_id)
        return {"service": service_id, "file": str(path), "created": False}
    private_dir(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump({key: secrets.token_urlsafe(36) for key in SECRET_KEYS}, stream)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    return {"service": service_id, "file": str(path), "created": True}


def compose_document(config, service_id):
    service = _select(config, service_id)
    memory = service["memory_mib"]
    database_memory = service["database_memory_mib"]
    common = {"restart": "unless-stopped", "security_opt": ["no-new-privileges:true"],
              "pids_limit": 256, "stop_grace_period": "60s", "ulimits": {"core": {"soft": 0, "hard": 0}},
              "logging": {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}}}
    database = {**common, "image": service["database_image"], "cpus": service["database_cpus"],
        "mem_limit": f"{database_memory}m", "memswap_limit": f"{database_memory}m",
        "environment": {"MARIADB_DATABASE": "joomla", "MARIADB_USER": "joomla", "MARIADB_PASSWORD_FILE": "/run/secrets/database_password", "MARIADB_ROOT_PASSWORD_FILE": "/run/secrets/database_root_password"},
        "secrets": ["database_password", "database_root_password"],
        "volumes": [{"type": "bind", "source": "./database", "target": "/var/lib/mysql"}],
        "networks": ["database"], "healthcheck": {"test": ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"], "interval": "10s", "timeout": "5s", "retries": 30, "start_period": "30s"}}
    joomla = {**common, "image": service["image"], "cpus": service["cpus"] - service["database_cpus"],
        "mem_limit": f"{memory-database_memory}m", "memswap_limit": f"{memory-database_memory}m",
        "entrypoint": ["/bin/bash", "/opt/ductor/entrypoint.sh"], "command": ["apache2-foreground"],
        "environment": {"JOOMLA_DB_HOST": "database:3306", "JOOMLA_DB_USER": "joomla", "JOOMLA_DB_NAME": "joomla", "JOOMLA_DB_PASSWORD_FILE": "/run/secrets/database_password", "JOOMLA_SITE_NAME": service["site_name"], "JOOMLA_ADMIN_USERNAME": service["admin_username"], "JOOMLA_ADMIN_USER": "JoomEngine Administrator", "JOOMLA_ADMIN_EMAIL": service["admin_email"]},
        "secrets": ["admin_password", "database_password"],
        "depends_on": {"database": {"condition": "service_healthy"}},
        "ports": [{"target": 80, "published": str(service["port"]), "host_ip": service["bind_address"], "protocol": "tcp"}],
        "networks": ["frontend", "database"],
        "volumes": [{"type": "bind", "source": "./joomla", "target": "/var/www/html"},
                    {"type": "bind", "source": "./artifacts", "target": "/var/lib/joomengine-mcp/artifacts"},
                    {"type": "bind", "source": "./entrypoint.sh", "target": "/opt/ductor/entrypoint.sh", "read_only": True}],
        "healthcheck": {"test": ["CMD", "php", "-r", "$$s=@fsockopen('127.0.0.1',80,$$e,$$m,3);exit($$s?0:1);"], "interval": "10s", "timeout": "5s", "retries": 60, "start_period": "60s"}}
    return {"name": "ductor-" + service_id, "services": {"database": database, "joomla": joomla},
            "networks": {"frontend": {}, "database": {"internal": True}},
            "secrets": {key: {"file": "./secrets/" + key} for key in SECRET_KEYS if key != "mcp_password"}}


def render_joomengine(config, output_dir):
    errors = validate_joomengine(config)
    if errors:
        raise ValueError("\n".join(errors))
    paths = []
    for name, service in config.get("services", {}).items():
        if service.get("kind") != "joomengine" or not service.get("enabled"):
            continue
        target = Path(output_dir) / "services" / name
        target.mkdir(parents=True, exist_ok=True)
        files = {"compose.yaml": json.dumps(compose_document(config, name), indent=2) + "\n",
                 "entrypoint.sh": '#!/bin/bash\nset -euo pipefail\nexport JOOMLA_ADMIN_PASSWORD\nJOOMLA_ADMIN_PASSWORD=$(cat /run/secrets/admin_password)\nexec /entrypoint.sh "$@"\n'}
        for filename, content in files.items():
            path = target / filename
            path.write_text(content)
            path.chmod(0o600)
            paths.append(path)
    return paths
