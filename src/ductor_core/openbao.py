"""Native OpenBao deployment and operator actions. No runtime renewal service."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import ssl
import stat
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request

OPENBAO_IMAGE = "ghcr.io/openbao/openbao:2.7.1"
_ID = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$")


class OpenBaoError(ValueError):
    """A redacted, operator-readable failure."""


def _private_file(value: str, label: str, *, missing: bool = False) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise OpenBaoError(f"{label} must be an absolute path")
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise OpenBaoError(f"{label} must not traverse symlinks")
    try:
        info = path.lstat()
    except FileNotFoundError:
        if missing:
            return path
        raise OpenBaoError(f"{label} does not exist") from None
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise OpenBaoError(f"{label} must be a regular, single-link file")
    if info.st_mode & 0o077 or info.st_uid not in (0, os.getuid()):
        raise OpenBaoError(f"{label} must be owned by the operator/root with mode 0600 or stricter")
    if info.st_size > 1024 * 1024:
        raise OpenBaoError(f"{label} exceeds the size limit")
    return path


def _read_private(value: str, label: str) -> str:
    path = _private_file(value, label)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o077:
            raise OpenBaoError(f"{label} changed during access")
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            fd = -1
            return stream.read(1024 * 1024 + 1).strip()
    finally:
        if fd >= 0:
            os.close(fd)


def _write_private(path: Path, value: str) -> None:
    _private_file(str(path), "output file", missing=True)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())


def _services(config: dict, kind: str) -> list[tuple[str, dict]]:
    return [(key, val) for key, val in config.get("services", {}).items()
            if val.get("enabled", True) and val.get("kind", key) == kind]


def _select(config: dict, service_id: str | None = None) -> tuple[str, dict]:
    candidates = _services(config, "openbao")
    if service_id:
        candidates = [(key, val) for key, val in candidates if key == service_id]
    if len(candidates) != 1:
        raise OpenBaoError("Select exactly one enabled OpenBao service")
    return candidates[0]


def _url(service: dict) -> str:
    value = service.get("url", "")
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or
            parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
        raise OpenBaoError("OpenBao url must be an HTTPS origin without embedded credentials")
    return value.rstrip("/")


def _request(service: dict, method: str, route: str, *, token: str | None = None,
             data: dict | None = None, allowed: tuple[int, ...] = (200, 204), binary: bool | Path = False):
    context = ssl.create_default_context(cafile=service.get("ca_file"))
    headers = {"Accept": "application/json"}
    if token:
        headers["X-Vault-Token"] = token
    body = None if data is None else json.dumps(data).encode()
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = Request(_url(service) + "/v1/" + route.lstrip("/"), data=body, headers=headers, method=method)
    # Redirects must never carry credentials to another endpoint.
    from urllib.request import HTTPRedirectHandler, HTTPSHandler, build_opener
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = build_opener(NoRedirect(), HTTPSHandler(context=context))
    try:
        with opener.open(req, timeout=30) as response:
            if response.status not in allowed:
                raise OpenBaoError(f"OpenBao {method} request failed (HTTP {response.status})")
            if isinstance(binary, Path):
                fd = os.open(binary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                count = 0
                try:
                    with os.fdopen(fd, "wb") as stream:
                        while chunk := response.read(1024 * 1024):
                            stream.write(chunk)
                            count += len(chunk)
                        stream.flush()
                        os.fsync(stream.fileno())
                except Exception:
                    binary.unlink(missing_ok=True)
                    raise
                return count
            raw = response.read(8 * 1024 * 1024 + 1)
            if len(raw) > 8 * 1024 * 1024:
                raise OpenBaoError("OpenBao response exceeds the size limit")
    except HTTPError as error:
        if error.code in allowed:
            raw = error.read()
        else:
            raise OpenBaoError(f"OpenBao {method} request failed (HTTP {error.code})") from None
    except (URLError, OSError, ValueError):
        raise OpenBaoError("OpenBao request failed; check endpoint, TLS trust and reachability") from None
    if binary:
        return raw
    try:
        return json.loads(raw) if raw else {}
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise OpenBaoError("OpenBao returned an invalid response") from None


def validate_openbao(config: dict) -> list[str]:
    errors: list[str] = []
    for key, service in _services(config, "openbao"):
        try:
            if not _ID.fullmatch(key):
                raise OpenBaoError("invalid OpenBao service id")
            _url(service)
            if service.get("bind_address", "127.0.0.1") != "127.0.0.1":
                raise OpenBaoError("OpenBao HTTP backend must bind to loopback behind the operator TLS proxy")
            for unsupported in ("seal", "raft_peers", "cluster_url", "node_id"):
                if unsupported in service:
                    raise OpenBaoError(f"{unsupported} is unsupported by this single-node Shamir deployment")
            for field in ("uid", "gid"):
                if field in service and (type(service[field]) is not int or service[field] <= 0):
                    raise OpenBaoError(f"{field} must be a non-root positive integer")
            if service.get("kv_mount", "secret") != "secret":
                raise OpenBaoError("this release supports the OpenBao KV v2 mount 'secret'")
            for field in ("unseal_shares", "unseal_threshold"):
                if field in service and (type(service[field]) is not int or not 1 <= service[field] <= 10):
                    raise OpenBaoError(f"{field} must be an integer from 1 to 10")
            if service.get("unseal_threshold", 3) > service.get("unseal_shares", 5):
                raise OpenBaoError("unseal_threshold exceeds unseal_shares")
            if service.get("ca_file") and not Path(service["ca_file"]).is_file():
                raise OpenBaoError("ca_file must reference an existing CA bundle")
        except (OpenBaoError, TypeError, ValueError) as error:
            errors.append(f"services.{key}: {error}")
    for key, gateway in _services(config, "openclaw"):
        if not gateway.get("provider_keys"):
            continue
        try:
            _select(config, gateway.get("openbao_service"))
            for provider, ref in gateway["provider_keys"].items():
                if not _ID.fullmatch(provider) or not isinstance(ref, str):
                    raise OpenBaoError("provider_keys must map provider ids to SecretRef id strings")
                if not ref.startswith(f"gateways/{key}/") or any(x in ("", ".", "..") for x in ref.split("/")):
                    raise OpenBaoError(f"provider key paths must be beneath gateways/{key}/")
        except (OpenBaoError, TypeError, ValueError) as error:
            errors.append(f"services.{key}: {error}")
    credentials = config.get("credentials", {})
    for field in ("openbao_token_file", "openbao_unseal_file"):
        if credentials.get(field):
            try:
                _private_file(credentials[field], field, missing=True)
            except (OpenBaoError, TypeError, ValueError) as error:
                errors.append(f"credentials.{field}: {error}")
    for gateway, refs in credentials.get("openbao_approles", {}).items():
        for field in ("role_id_file", "secret_id_file"):
            try:
                _private_file(refs[field], f"{gateway}.{field}", missing=True)
            except (OpenBaoError, KeyError, TypeError, ValueError) as error:
                errors.append(f"credentials.openbao_approles.{gateway}.{field}: {error}")
    return errors


def render_openbao(config: dict, output_dir: str | Path) -> dict:
    errors = validate_openbao(config)
    if errors:
        raise OpenBaoError("; ".join(errors))
    output = Path(output_dir)
    files: list[str] = []
    for key, service in _services(config, "openbao"):
        host = config["hosts"][service["host"]]
        root = f"{host['data_root']}/services/{key}"
        target = output / "services" / key
        target.mkdir(parents=True, exist_ok=True)
        hcl = (f'ui = true\napi_addr = {json.dumps(_url(service))}\n'
               'cluster_addr = "https://127.0.0.1:8201"\n'
               f'storage "raft" {{\n  path = "/openbao/data"\n  node_id = {json.dumps(key)}\n}}\n'
               'listener "tcp" {\n  address = "0.0.0.0:8200"\n  tls_disable = true\n}\n')
        (target / "server.hcl").write_text(hcl)
        uid, gid = service.get("uid", 1000), service.get("gid", 1000)
        compose = {"name": f"ductor-{key}", "services": {"openbao": {
            "image": service.get("image", OPENBAO_IMAGE),
            # Explicit executable avoids the image entrypoint adding its own
            # -config directory and loading the same listener twice.
            "command": ["bao", "server", "-config=/openbao/config/server.hcl"],
            "restart": "unless-stopped", "user": f"{uid}:{gid}",
            "environment": {"SKIP_CHOWN": "1", "BAO_ADDR": "http://127.0.0.1:8200"},
            "ports": [f"{service.get('bind_address', '127.0.0.1')}:{service.get('port', 8200)}:8200"],
            "volumes": [f"{root}/server.hcl:/openbao/config/server.hcl:ro", f"{root}/data:/openbao/data", f"{root}/audit:/openbao/audit", f"{root}/backups:/openbao/backups"],
            "read_only": True, "tmpfs": ["/tmp:rw,noexec,nosuid,size=16m"],
            "cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"],
            "mem_swappiness": 0, "mem_limit": f"{service.get('memory_mib', 512)}m",
            "memswap_limit": f"{service.get('memory_mib', 512)}m",
            "cpus": service.get("cpus", 1), "ulimits": {"core": {"soft": 0, "hard": 0}},
            "logging": {"driver": "json-file", "options": {"max-size": "10m", "max-file": "3"}},
            "healthcheck": {"test": ["CMD", "bao", "status"], "interval": "15s", "timeout": "5s", "retries": 3}
        }}}
        (target / "compose.yaml").write_text(json.dumps(compose, indent=2) + "\n")
        files.extend(str(target / name) for name in ("server.hcl", "compose.yaml"))
    for key, gateway in _services(config, "openclaw"):
        if not gateway.get("provider_keys") and not gateway.get("openbao_service"):
            continue
        _, bao = _select(config, gateway.get("openbao_service"))
        target = output / "services" / key
        target.mkdir(parents=True, exist_ok=True)
        ca = '\n  ca_cert = "/etc/openbao/ca.pem"' if bao.get("ca_file") else ""
        hcl = f'''vault {{
  address = {json.dumps(_url(bao))}{ca}
}}
auto_auth {{
  method "approle" {{
    mount_path = "auth/approle"
    config = {{
      role_id_file_path = "/etc/openbao/auth/role-id"
      secret_id_file_path = "/etc/openbao/auth/secret-id"
      remove_secret_id_file_after_reading = false
    }}
  }}
  sink "file" {{
    config = {{
      path = "/run/openbao/token"
      mode = 0600
      uid = {gateway.get('uid', 1000)}
      gid = {gateway.get('gid', 1000)}
    }}
  }}
}}
exit_after_auth = false
'''
        (target / "agent.hcl").write_text(hcl)
        files.append(str(target / "agent.hcl"))
    return {"files": files, "runtime_renewal": "OpenBao Agent", "qualification": "requires live host validation"}


def bootstrap(config: dict, service_id: str | None = None) -> dict:
    key, service = _select(config, service_id)
    output = config.get("credentials", {}).get("openbao_bootstrap_output_file")
    if not output:
        raise OpenBaoError("credentials.openbao_bootstrap_output_file is required")
    path = _private_file(output, "bootstrap output", missing=True)
    if path.exists():
        raise OpenBaoError("Bootstrap output already exists; refusing to overwrite recovery material")
    token_destination = config.get("credentials", {}).get("openbao_token_file")
    token_path = _private_file(token_destination, "bootstrap operator token output", missing=True) if token_destination else None
    if token_path and (token_path == path or token_path.exists()):
        raise OpenBaoError("Bootstrap operator token destination must be separate and absent; refusing to overwrite")
    status = _request(service, "GET", "sys/init")
    if status.get("initialized"):
        raise OpenBaoError("OpenBao is already initialized; recovery material cannot be regenerated")
    # Reserve the destination before irreversible initialization; never print response.
    _write_private(path, "")
    if token_path:
        _write_private(token_path, "")
    try:
        result = _request(service, "POST", "sys/init", data={
            "secret_shares": service.get("unseal_shares", 5),
            "secret_threshold": service.get("unseal_threshold", 3)})
        fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
        with os.fdopen(fd, "w") as stream:
            json.dump(result, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if token_path:
            root_token = result.get("root_token")
            if not isinstance(root_token, str) or not root_token or any(char.isspace() for char in root_token):
                raise OpenBaoError("Initialization response did not contain an operator token")
            fd = os.open(token_path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
            with os.fdopen(fd, "w") as stream:
                stream.write(root_token + "\n")
                stream.flush()
                os.fsync(stream.fileno())
    except Exception:
        # Retain the reservation: an interrupted request can have initialized Bao.
        raise OpenBaoError("Initialization did not complete safely; inspect server state and protected recovery output before retrying") from None
    return {"service": key, "initialized": True, "sealed": True, "recovery_file": str(path),
            "operator_token_file": str(token_path) if token_path else None}


def unseal(config: dict, service_id: str | None = None) -> dict:
    key, service = _select(config, service_id)
    value = config.get("credentials", {}).get("openbao_unseal_file")
    if not value:
        raise OpenBaoError("credentials.openbao_unseal_file is required")
    raw = _read_private(value, "unseal input")
    try:
        material = json.loads(raw)
        shares = material if isinstance(material, list) else material.get("keys_base64", material.get("unseal_keys_b64", []))
        if not isinstance(shares, list) or not shares or not all(isinstance(x, str) and x for x in shares):
            raise ValueError()
    except (ValueError, AttributeError):
        raise OpenBaoError("Unseal input must contain a JSON list of shares or initialization keys_base64") from None
    status = _request(service, "GET", "sys/seal-status")
    for share in shares:
        if not status.get("sealed", True):
            break
        status = _request(service, "POST", "sys/unseal", data={"key": share})
    return {"service": key, "sealed": bool(status.get("sealed", True)), "progress": status.get("progress", 0)}


def _token(config: dict) -> str:
    value = config.get("credentials", {}).get("openbao_token_file")
    if not value:
        raise OpenBaoError("credentials.openbao_token_file is required")
    token = _read_private(value, "OpenBao operator token")
    if not token or any(c.isspace() for c in token):
        raise OpenBaoError("OpenBao operator token file must contain one token")
    return token


def provision_credentials(config: dict, service_id: str | None = None) -> dict:
    key, service = _select(config, service_id)
    token = _token(config)
    destinations = config.get("credentials", {}).get("openbao_approles", {})
    gateways = [(name, val) for name, val in _services(config, "openclaw")
                if (val.get("provider_keys") or val.get("openbao_service")) and
                val.get("openbao_service", key) == key]
    for name, _ in gateways:
        refs = destinations.get(name, {})
        for field in ("role_id_file", "secret_id_file"):
            if not refs.get(field):
                raise OpenBaoError(f"credentials.openbao_approles.{name}.{field} is required")
            path = _private_file(refs[field], field, missing=True)
            if path.exists():
                raise OpenBaoError(f"{name} AppRole destination already exists; explicit credential rotation is required")
    mounts = _request(service, "GET", "sys/mounts", token=token)
    mount_info = mounts.get("data", mounts).get("secret/")
    if not mount_info:
        _request(service, "POST", "sys/mounts/secret", token=token, data={"type": "kv", "options": {"version": "2"}})
    elif mount_info.get("type") != "kv" or str(mount_info.get("options", {}).get("version")) != "2":
        raise OpenBaoError("Existing secret/ mount is not KV v2; refusing to replace it")
    auth = _request(service, "GET", "sys/auth", token=token)
    auth_info = auth.get("data", auth).get("approle/")
    if not auth_info:
        _request(service, "POST", "sys/auth/approle", token=token, data={"type": "approle"})
    elif auth_info.get("type") != "approle":
        raise OpenBaoError("Existing approle/ mount is not AppRole")
    audit = _request(service, "GET", "sys/audit", token=token)
    if "ductor/" not in audit.get("data", audit):
        _request(service, "PUT", "sys/audit/ductor", token=token,
                 data={"type": "file", "options": {"file_path": "/openbao/audit/audit.json"}})
    created = []
    for name, _ in gateways:
        if not _ID.fullmatch(name):
            raise OpenBaoError("Invalid gateway id")
        role = f"ductor-{name}"
        policy = f'path "secret/data/gateways/{name}/*" {{ capabilities = ["read"] }}\n'
        _request(service, "PUT", f"sys/policies/acl/{quote(role)}", token=token, data={"policy": policy})
        _request(service, "POST", f"auth/approle/role/{quote(role)}", token=token, data={
            "bind_secret_id": True, "secret_id_ttl": 0, "secret_id_num_uses": 0,
            "token_ttl": "1h", "token_max_ttl": "24h", "token_num_uses": 0,
            "token_type": "service", "token_policies": [role]})
        role_id = _request(service, "GET", f"auth/approle/role/{quote(role)}/role-id", token=token)["data"]["role_id"]
        result = _request(service, "POST", f"auth/approle/role/{quote(role)}/secret-id", token=token, data={})["data"]
        refs = destinations[name]
        _write_private(Path(refs["role_id_file"]), role_id + "\n")
        _write_private(Path(refs["secret_id_file"]), result["secret_id"] + "\n")
        created.append({"gateway": name, "role": role, "role_id_file": refs["role_id_file"], "secret_id_file": refs["secret_id_file"]})
    return {"service": key, "credentials_created": created, "audit_enabled": True,
            "next": "Deploy gateway credentials; enroll provider API keys through native OpenBao KV v2. Revoke bootstrap root after operator auth is configured."}


def backup(config: dict, output_file: str, service_id: str | None = None) -> dict:
    key, service = _select(config, service_id)
    path = _private_file(output_file, "snapshot output", missing=True)
    if path.exists():
        raise OpenBaoError("Snapshot output already exists")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    count = _request(service, "GET", "sys/storage/raft/snapshot", token=_token(config), binary=path)
    return {"service": key, "snapshot": str(path), "bytes": count}


def put_secret(config: dict, gateway_id: str, provider_id: str, value_file: str) -> dict:
    """Enroll one configured provider key from a protected file using KV v2 CAS."""
    gateways = dict(_services(config, "openclaw"))
    gateway = gateways.get(gateway_id)
    if not gateway:
        raise OpenBaoError("Select an enabled OpenClaw gateway")
    ref = gateway.get("provider_keys", {}).get(provider_id)
    if (not isinstance(ref, str) or not ref.startswith(f"gateways/{gateway_id}/") or
            any(part in ("", ".", "..") for part in ref.split("/"))):
        raise OpenBaoError("Provider must have a configured per-gateway OpenBao SecretRef")
    key, service = _select(config, gateway.get("openbao_service"))
    value = _read_private(value_file, "provider key input")
    if not value or "\n" in value or "\r" in value:
        raise OpenBaoError("Provider key input must contain one nonempty line")
    token = _token(config)
    path, field = ref.rsplit("/", 1)
    route = "secret/data/" + "/".join(quote(part, safe="") for part in path.split("/"))
    current = _request(service, "GET", route, token=token, allowed=(200, 404))
    entry = current.get("data", {})
    values = entry.get("data", {})
    version = entry.get("metadata", {}).get("version", 0)
    if not isinstance(values, dict) or type(version) is not int:
        raise OpenBaoError("OpenBao returned an invalid KV v2 response")
    values[field] = value
    written = _request(service, "POST", route, token=token,
                       data={"options": {"cas": version}, "data": values})
    return {"service": key, "gateway": gateway_id, "provider": provider_id,
            "secret_ref": ref, "version": written.get("data", {}).get("version"),
            "next": "Activate the gateway or run native openclaw secrets reload to refresh the runtime snapshot."}
