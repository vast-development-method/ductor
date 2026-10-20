"""Private local state and safe deterministic serialization."""
from contextlib import contextmanager
from pathlib import Path
import fcntl
import json
import os
import stat
import tempfile


def private_dir(path):
    path = Path(path)
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError(f"Refusing symlink directory: {path}")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.stat().st_uid != os.getuid():
        raise ValueError(f"Directory is not owned by current user: {path}")
    if stat.S_IMODE(path.stat().st_mode) & 0o022:
        raise ValueError(f"Private directory must not be writable by group or other users: {path}")
    return path


def write_private(path, content):
    path = Path(path)
    private_dir(path.parent)
    if path.is_symlink() or (path.exists() and (not path.is_file() or path.stat().st_nlink != 1)):
        raise ValueError(f"Refusing symlink, hardlink or non-regular file: {path}")
    data = content if isinstance(content, str) else json.dumps(content, indent=2, sort_keys=True) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=".ductor-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def check_private_file(value):
    path = Path(value)
    if not path.is_absolute() or any(part.is_symlink() for part in (path, *path.parents)) or not path.is_file():
        raise ValueError(f"Expected an absolute, regular private file: {path}")
    metadata = path.stat()
    if metadata.st_uid not in (0, os.getuid()) or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise ValueError(f"Private file must be owned by current user with mode 0600 or 0400: {path}")
    if metadata.st_size == 0:
        raise ValueError(f"Private file is empty: {path}")
    return path


@contextmanager
def state_lock(state):
    private_dir(state)
    path = Path(state) / "operation.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Another Ductor operation is running in this state directory") from exc
        yield
    finally:
        os.close(fd)
