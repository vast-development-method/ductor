"""Reject links and special files before privileged deployment file operations."""
import json
import stat
import sys
from pathlib import Path

manifest = json.load(sys.stdin)
root = Path(manifest["root"])
if not root.is_absolute() or ".." in root.parts:
    raise SystemExit("Managed destination must be a normalized absolute path")


def inspect(path, directory=False):
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise SystemExit(f"Refusing managed destination symlink: {current}")
        if (current != path or directory) and not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit(f"Managed destination parent is not a directory: {current}")
        if current == path and not directory and not stat.S_ISREG(metadata.st_mode):
            raise SystemExit(f"Managed destination is not a regular file: {current}")
        if current == path and not directory and metadata.st_nlink != 1:
            raise SystemExit(f"Refusing hard-linked managed destination: {current}")


def destination(relative):
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise SystemExit("Invalid managed destination manifest entry")
    return root / candidate


inspect(root, directory=True)
for relative in manifest.get("directories", []):
    inspect(destination(relative), directory=True)
for relative in manifest.get("files", []):
    inspect(destination(relative))
