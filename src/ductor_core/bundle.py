"""Portable, unencrypted controller bundles. Never package remote runtime data."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import uuid
import zipfile

from .config import validate
from .util import private_dir

FORMAT = "ductor-controller-bundle"
VERSION = 1
MAX_FILES = 10000
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_TOTAL_BYTES = 128 * 1024 * 1024
MAX_MANIFEST_BYTES = 4 * 1024 * 1024
NOTICE = "This ZIP contains credentials and is not encrypted. Transfer and store it privately. SHA256 checks detect corruption, not an untrusted sender."


def _references(config):
    """Only schema-defined controller paths; never infer paths from strings."""
    result = []
    def add(parts, kind="private", recovery=False):
        value = config
        for part in parts:
            if not isinstance(value, dict) or part not in value:
                return
            value = value[part]
        if value == "" and parts == ["knowledge", "source_dir"]:
            return
        if not isinstance(value, str) or not value:
            raise ValueError("Invalid file reference: " + ".".join(parts))
        result.append({"config_path": parts, "kind": kind, "recovery": recovery, "source": value})
    for host in config.get("hosts", {}):
        add(["hosts", host, "identity_file"])
        add(["hosts", host, "known_hosts_file"], "public")
    for pool in config.get("incus", {}).get("pools", {}):
        for field in ("client_certificate_file", "client_key_file", "server_certificate_file"):
            add(["incus", "pools", pool, field], "private" if field == "client_key_file" else "public")
    for service in config.get("services", {}):
        add(["services", service, "ca_file"], "public")
        add(["services", service, "gateway_token_file"])
    for field in ("openbao_token_file", "openbao_bootstrap_output_file", "openbao_unseal_file"):
        add(["credentials", field], recovery=field != "openbao_token_file")
    for service in config.get("credentials", {}).get("gateway_token_files", {}):
        add(["credentials", "gateway_token_files", service])
    for group in ("joomengine_files", "joomengine_client_files"):
        for service in config.get("credentials", {}).get(group, {}):
            add(["credentials", group, service])
    for service in config.get("credentials", {}).get("openbao_approles", {}):
        for field in ("role_id_file", "secret_id_file"):
            add(["credentials", "openbao_approles", service, field])
    add(["knowledge", "source_dir"], "tree")
    return result


def _set(config, parts, value):
    item = config
    for part in parts[:-1]:
        item = item[part]
    item[parts[-1]] = value


def _checked_path(value):
    path = Path(value)
    if (not path.is_absolute() or ".." in path.parts
            or any(ord(c) < 32 or ord(c) == 127 for c in str(path))):
        raise ValueError("Controller file references must be absolute paths without traversal or control characters")
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError(f"Refusing symlink in controller path: {path}")
    return path


def _read_file(path, private):
    _checked_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        forbidden = 0o077 if private else 0o022
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid not in (0, os.getuid()) or info.st_mode & forbidden):
            raise ValueError(f"Unsafe ownership, permissions, links or file type: {path}")
        if private and info.st_size == 0:
            raise ValueError(f"Private bundle source is empty: {path}")
        if info.st_size > MAX_FILE_BYTES:
            raise ValueError(f"Bundle file exceeds size limit: {path}")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(MAX_FILE_BYTES + 1)
        if len(data) > MAX_FILE_BYTES or len(data) != info.st_size:
            raise ValueError(f"Bundle source changed or exceeds size limit: {path}")
        return data
    finally:
        os.close(fd)


def _name(value):
    if (not isinstance(value, str) or not value or value.startswith("/")
            or "\\" in value or ":" in value
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError("Unsafe bundle member path")
    return value


def _json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate key in bundle manifest")
            result[key] = value
        return result
    try:
        def nonfinite(value):
            raise ValueError("Non-finite number in bundle manifest")
        return json.loads(data, object_pairs_hook=unique, parse_constant=nonfinite)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as exc:
        raise ValueError("Invalid bundle manifest JSON") from exc


def _validate(config):
    try:
        errors = validate(config, integrations=False)
    except (AttributeError, TypeError, KeyError, ValueError) as exc:
        raise ValueError("Invalid bundle configuration structure") from exc
    if errors:
        raise ValueError("Invalid bundle configuration: " + "; ".join(errors))


def _metadata(manifest):
    return {"bundle_id": manifest["bundle_id"], "file_count": len(manifest["files"]),
            "missing_references": [".".join(r["config_path"]) for r in manifest["references"] if r["status"] == "missing"],
            "omitted_recovery_references": [".".join(r["config_path"]) for r in manifest["references"] if r["status"] == "excluded"],
            "recovery_included": manifest["recovery_included"], "encrypted": False, "message": NOTICE}


def export_bundle(config, state, output: Path, include_recovery=False):
    """Write one private ZIP without overwriting output; missing refs stay explicit."""
    _validate(config)
    output = _checked_path(Path(output).absolute())
    private_dir(output.parent)
    if output.exists():
        raise ValueError(f"Bundle output already exists: {output}")
    refs = _references(config)
    for ref in refs:
        ref["source"] = str(_checked_path(ref["source"]))
    excluded = {r["source"] for r in refs if r["recovery"] and not include_recovery}
    private = {r["source"] for r in refs if r["kind"] == "private"}
    portable = deepcopy(config)
    files, objects, descriptors = {}, {}, []
    total = 0
    def put(name, path):
        nonlocal total
        data = _read_file(path, str(path) in private)
        total += len(data)
        if total > MAX_TOTAL_BYTES or len(files) >= MAX_FILES:
            raise ValueError("Bundle exceeds total size or file-count limit")
        files[_name(name)] = data
    for ref in refs:
        source = ref["source"]
        kind = "tree" if ref["kind"] == "tree" else "file"
        if source not in objects:
            path = Path(source)
            target = "objects/" + hashlib.sha256(source.encode()).hexdigest() + "/" + kind
            status = "excluded" if source in excluded else "included" if path.exists() else "missing"
            objects[source] = (target, status, kind)
            if status == "included":
                if kind == "tree":
                    if not path.is_dir():
                        raise ValueError("Knowledge source must be a directory")
                    for current, dirs, names in os.walk(path, followlinks=False):
                        for name in sorted(dirs + names):
                            child = Path(current) / name
                            _checked_path(child)  # Reject even non-Markdown symlinks.
                            info = child.lstat()
                            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                                raise ValueError("Knowledge tree contains a special file")
                            if (stat.S_ISREG(info.st_mode) and child.suffix.lower() == ".md"
                                    and str(child) not in excluded):
                                put(target + "/" + child.relative_to(path).as_posix(), child)
                else:
                    put(target, path)
        target, status, previous_kind = objects[source]
        if previous_kind != kind:
            raise ValueError("One source cannot be both a file and a knowledge directory")
        descriptors.append({"config_path": ref["config_path"], "kind": ref["kind"],
                            "path": target, "status": status, "recovery": ref["recovery"]})
        _set(portable, ref["config_path"], target)
    manifest = {"format": FORMAT, "version": VERSION, "bundle_id": uuid.uuid4().hex,
                "config": portable, "references": descriptors,
                "recovery_included": bool(include_recovery),
                "files": [{"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                          for name, data in sorted(files.items())]}
    raw = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode()
    if len(raw) > MAX_MANIFEST_BYTES:
        raise ValueError("Bundle manifest exceeds size limit")
    fd, temporary = tempfile.mkstemp(prefix=".ductor-bundle-", dir=output.parent)
    try:
        with os.fdopen(fd, "w+b") as stream:
            with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED, allowZip64=False) as archive:
                for name, data in [("manifest.json", raw), *sorted(files.items())]:
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFREG | 0o600) << 16
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(entry, data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, output)  # Exclusive publication; never replace an existing file.
    except FileExistsError as exc:
        raise ValueError(f"Bundle output already exists: {output}") from exc
    finally:
        os.unlink(temporary)
    return {**_metadata(manifest), "output": str(output)}


def _read_archive(archive):
    """Validate all archive metadata before reading bounded payloads."""
    entries = archive.infolist()
    if not entries or len(entries) > MAX_FILES + 1:
        raise ValueError("Bundle entry-count limit exceeded")
    seen, total = set(), 0
    for entry in entries:
        name = _name(entry.filename)
        if name in seen or entry.orig_filename != entry.filename:
            raise ValueError("Duplicate or malformed bundle member")
        seen.add(name)
        mode = entry.external_attr >> 16
        if (entry.is_dir() or entry.extra or entry.flag_bits & 1
                or stat.S_IFMT(mode) not in (0, stat.S_IFREG)
                or entry.external_attr & 0x10
                or entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
            raise ValueError("Bundle contains unsupported links, metadata or file types")
        limit = MAX_MANIFEST_BYTES if name == "manifest.json" else MAX_FILE_BYTES
        if entry.file_size < 0 or entry.file_size > limit:
            raise ValueError("Bundle member exceeds size limit")
        total += entry.file_size
    if total > MAX_TOTAL_BYTES + MAX_MANIFEST_BYTES or "manifest.json" not in seen:
        raise ValueError("Bundle exceeds total size limit or has no manifest")
    manifest = _json(archive.read("manifest.json"))
    expected = {"format", "version", "bundle_id", "config", "references", "recovery_included", "files"}
    if (not isinstance(manifest, dict) or set(manifest) != expected
            or manifest["format"] != FORMAT or type(manifest["version"]) is not int or manifest["version"] != VERSION
            or not isinstance(manifest["bundle_id"], str) or not re.fullmatch(r"[a-f0-9]{32}", manifest["bundle_id"])
            or type(manifest["recovery_included"]) is not bool
            or not isinstance(manifest["files"], list) or not isinstance(manifest["references"], list)):
        raise ValueError("Unsupported or malformed bundle manifest")
    payload = {}
    for item in manifest["files"]:
        if (not isinstance(item, dict) or set(item) != {"path", "size", "sha256"}
                or type(item["size"]) is not int or not isinstance(item["sha256"], str)
                or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"])):
            raise ValueError("Invalid bundle file descriptor")
        name = _name(item["path"])
        if not name.startswith("objects/") or name in payload or name not in seen:
            raise ValueError("Missing or duplicate bundle payload")
        entry = archive.getinfo(name)
        if item["size"] != entry.file_size:
            raise ValueError("Bundle file size mismatch")
        data = archive.read(entry)
        if len(data) != item["size"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise ValueError("Bundle SHA256 integrity check failed")
        payload[name] = data
    if seen != {"manifest.json", *payload}:
        raise ValueError("Bundle contains unlisted payloads")
    return manifest, payload


def import_bundle(archive, state, config_path):
    """Import into an independent private state tree; existing config is never replaced."""
    state = _checked_path(Path(state).absolute())
    config_path = _checked_path(Path(config_path).absolute())
    if config_path.exists():
        raise ValueError(f"Configuration already exists: {config_path}")
    source = _checked_path(Path(archive).absolute())
    # A transferred bundle contains private keys even when its original mode was lost.
    info = source.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o077
            or info.st_uid not in (0, os.getuid())):
        raise ValueError("Bundle must be a private regular file owned by the current user (mode 0600)")
    if info.st_size > MAX_TOTAL_BYTES + MAX_MANIFEST_BYTES + 10 * 1024 * 1024:
        raise ValueError("Bundle archive exceeds size limit")
    try:
        with zipfile.ZipFile(source) as zipped:
            manifest, payload = _read_archive(zipped)
    except (zipfile.BadZipFile, NotImplementedError, RuntimeError) as exc:
        raise ValueError("Invalid or unsupported bundle ZIP") from exc
    config = deepcopy(manifest["config"])
    if not isinstance(config, dict):
        raise ValueError("Invalid bundle configuration")
    try:
        refs = _references(config)
    except (AttributeError, TypeError) as exc:
        raise ValueError("Invalid bundle configuration structure") from exc
    if len(refs) != len(manifest["references"]):
        raise ValueError("Bundle reference inventory mismatch")
    descriptors = {}
    for descriptor in manifest["references"]:
        if (not isinstance(descriptor, dict)
                or set(descriptor) != {"config_path", "kind", "path", "status", "recovery"}
                or not isinstance(descriptor["config_path"], list)
                or any(not isinstance(p, str) for p in descriptor["config_path"])):
            raise ValueError("Invalid bundle reference descriptor")
        key = tuple(descriptor["config_path"])
        if key in descriptors:
            raise ValueError("Duplicate bundle reference descriptor")
        descriptors[key] = descriptor
    if set(descriptors) != {tuple(r["config_path"]) for r in refs}:
        raise ValueError("Bundle reference inventory mismatch")
    final = state / "imported" / manifest["bundle_id"]
    declared, occupied, trees = set(), {}, set()
    for ref in refs:
        descriptor = descriptors[tuple(ref["config_path"])]
        if (descriptor["kind"] != ref["kind"]
                or descriptor["recovery"] is not ref["recovery"] or descriptor["path"] != ref["source"]
                or descriptor["status"] not in ("included", "missing", "excluded")):
            raise ValueError("Invalid bundle reference descriptor")
        target = _name(descriptor["path"])
        suffix = "tree" if ref["kind"] == "tree" else "file"
        if not re.fullmatch(r"objects/[a-f0-9]{64}/" + suffix, target):
            raise ValueError("Invalid portable reference path")
        status = descriptor["status"]
        if target in occupied and occupied[target] != status:
            raise ValueError("Aliased bundle references have inconsistent status")
        occupied[target] = status
        if status == "included":
            if suffix == "tree":
                trees.add(target)
                declared.update(name for name in payload if name.startswith(target + "/"))
            elif target not in payload:
                raise ValueError("Included bundle reference has no payload")
            else:
                declared.add(target)
        elif target in payload or any(name.startswith(target + "/") for name in payload):
            raise ValueError("Missing or excluded reference contains a payload")
        _set(config, ref["config_path"], str(final / target))
    recovery_targets = {d["path"] for d in manifest["references"] if d["recovery"]}
    if not manifest["recovery_included"] and any(occupied[p] != "excluded" for p in recovery_targets):
        raise ValueError("Recovery material is present without the include-recovery flag")
    if any(d["status"] == "excluded" and d["path"] not in recovery_targets for d in manifest["references"]):
        raise ValueError("Only recovery references may be excluded")
    if declared != set(payload):
        raise ValueError("Bundle contains payloads outside its reference inventory")
    if any(PurePosixPath(name).suffix.lower() != ".md" for tree in trees for name in payload if name.startswith(tree + "/")):
        raise ValueError("Knowledge payloads must be Markdown files")
    _validate(config)  # Structural validation uses final paths without reading staged knowledge.
    private_dir(state)
    imported = private_dir(state / "imported")
    private_dir(config_path.parent)
    if final.exists():
        raise ValueError("This bundle has already been imported into this state")
    temporary = Path(tempfile.mkdtemp(prefix=".import-", dir=imported))
    reserved, committed = False, False
    config_temporary = None
    try:
        for target in sorted(trees):
            (temporary / target).mkdir(parents=True, mode=0o700, exist_ok=True)
        for name, data in payload.items():
            target = temporary / name
            target.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
            with open(target, "xb") as stream:
                os.chmod(target, 0o600)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        # mkdir(parents=True) applies umask to intermediate directories; enforce privacy throughout.
        for current, directories, _ in os.walk(temporary):
            os.chmod(current, 0o700)
        fd, config_temporary = tempfile.mkstemp(prefix=".ductor-config-", dir=config_path.parent)
        with os.fdopen(fd, "w") as stream:
            json.dump(config, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        final.mkdir(mode=0o700)  # Reserve exclusively, then replace only our own empty reservation.
        reserved = True
        os.replace(temporary, final)
        os.link(config_temporary, config_path)  # Atomic, no-clobber commit point.
        committed = True
    except FileExistsError as exc:
        raise ValueError("Bundle destination or configuration already exists") from exc
    finally:
        if config_temporary is not None:
            Path(config_temporary).unlink(missing_ok=True)
        if temporary.exists():
            shutil.rmtree(temporary)
        if reserved and not committed:
            shutil.rmtree(final)
    return {**_metadata(manifest), "config_path": str(config_path), "imported_root": str(final)}
