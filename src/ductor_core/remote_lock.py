"""Cross-controller host admission through short-lived, verified SSH flock sessions.

Locks are advisory and host-global, not configuration-specific. They exclude
other cooperating Ductor controllers, not administrators using other tools.
Losing a lock stops further local work; an already submitted remote operation
cannot be rolled back or fenced by killing its local SSH client.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, field
import ipaddress
import os
import secrets
import selectors
import shlex
import signal
import subprocess
import sys
import threading
import time
from typing import Any

from .inventory import verify_ssh_files

LOCK_PATH = "/run/lock/ductor-infrastructure.lock"
LOCK_CONFLICT = 73
MAX_DIAGNOSTIC = 2048
POLL_SECONDS = 0.1


class InfrastructureLockError(ValueError):
    """Admission failed or a held host lock was lost."""


def _targets(inventory: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    entries = inventory["all"]["children"]["ductor_hosts"]["hosts"]
    endpoints: dict[tuple[str, int], tuple[str, dict[str, Any], tuple[Any, ...]]] = {}
    for name, entry in entries.items():
        if entry.get("ansible_connection") != "ssh":
            raise InfrastructureLockError(f"Host locking requires verified SSH: {name}")
        address = str(entry["ansible_host"])
        try:
            normalized = ipaddress.ip_address(address).compressed
        except ValueError:
            normalized = address.rstrip(".").lower()
        endpoint = (normalized, int(entry["ansible_port"]))
        identity = (entry["ansible_user"], bool(entry.get("ansible_become")),
                    entry["ansible_ssh_private_key_file"], entry["ductor_host"]["known_hosts_file"])
        if endpoint in endpoints:
            previous_name, _, previous_identity = endpoints[endpoint]
            if identity != previous_identity:
                raise InfrastructureLockError(
                    f"Host aliases {previous_name} and {name} use inconsistent SSH trust or identities")
            continue
        endpoints[endpoint] = (name, entry, identity)
    if not endpoints:
        raise InfrastructureLockError("No selected hosts to lock")
    return [(endpoints[key][0], endpoints[key][1]) for key in sorted(endpoints)]


def _ssh_argv(entry: dict[str, Any], command: str) -> list[str]:
    # Use the inventory's exact identity and trust file. Disable multiplexing:
    # this connection must own one independently observable lock channel.
    return ["ssh", "-F", "/dev/null", "-T", "-p", str(entry["ansible_port"]),
            "-i", str(entry["ansible_ssh_private_key_file"]),
            "-o", "StrictHostKeyChecking=yes", "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes", "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UserKnownHostsFile=" + entry["ductor_host"]["known_hosts_file"],
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectionAttempts=1",
            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=2",
            "-o", "ServerAliveCountMax=3", "-o", "TCPKeepAlive=yes",
            "--", f"{entry['ansible_user']}@{entry['ansible_host']}", command]


def _remote_command(marker: str, become: bool) -> str:
    # Noclobber creates the shared inode once; never unlink/replace a lock file.
    # Existing unexpected ownership, links, or permissions fail closed. These
    # supported hosts provide util-linux flock/stat and POSIX sh/cat before the
    # Python bootstrap. No deployed Ductor daemon or renewable lease is needed.
    script = '''set -eu
umask 077
lock=$1
marker=$2
if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
  (set -C; : > "$lock") 2>/dev/null || :
fi
[ -f "$lock" ] && [ ! -L "$lock" ] || exit 74
[ "$(stat -c %u "$lock")" = "$(id -u)" ] || exit 74
[ "$(stat -c %h "$lock")" = 1 ] || exit 74
[ "$(stat -c %a "$lock")" = 600 ] || exit 74
exec /usr/bin/flock -n -E 73 "$lock" /bin/sh -c 'printf "%s\\n" "$1"; cat >/dev/null' ductor-lock "$marker"
'''
    argv = (["sudo", "-n", "--"] if become else []) + [
        "/bin/sh", "-c", script, "ductor-lock", LOCK_PATH, marker]
    return shlex.join(argv)


def _stop_group(process: subprocess.Popen, grace: float = 2.0) -> None:
    # The leader may already have exited while an SSH descendant is still alive.
    # Always address the owned process group, then reap the leader.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=grace)


def _diagnostic(data: bytearray) -> str:
    # Remove terminal control sequences/control characters; no credential values
    # are put in the command or environment by this module.
    decoded = bytes(data).decode("utf-8", errors="replace")
    safe = "".join(char for char in decoded if char.isprintable() or char in "\n\t")
    return safe.strip()[-MAX_DIAGNOSTIC:]


@dataclass
class _Channel:
    name: str
    process: subprocess.Popen
    marker: bytes
    selector: selectors.BaseSelector = field(default_factory=selectors.DefaultSelector)
    stdout: bytearray = field(default_factory=bytearray)
    stderr: bytearray = field(default_factory=bytearray)
    stdout_closed: bool = False
    acquired: bool = False

    def watch(self) -> None:
        for stream, label in ((self.process.stdout, "stdout"), (self.process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            self.selector.register(stream, selectors.EVENT_READ, label)

    def drain(self, wait: float = 0.0) -> None:
        for event, _ in self.selector.select(wait):
            try:
                data = os.read(event.fd, 4096)
            except BlockingIOError:
                continue
            if not data:
                self.selector.unregister(event.fileobj)
                if event.data == "stdout":
                    self.stdout_closed = True
                continue
            if event.data == "stderr":
                self.stderr.extend(data)
                del self.stderr[:-MAX_DIAGNOSTIC]
            else:
                self.stdout.extend(data)
                if self.marker + b"\n" in self.stdout.splitlines(keepends=True):
                    self.acquired = True
                # SSH startup noise must not create unbounded controller memory.
                del self.stdout[:-8192]

    def close(self) -> None:
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        try:
            self.process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            _stop_group(self.process, grace=1.0)
        self.selector.close()
        for stream in (self.process.stdout, self.process.stderr):
            if stream:
                stream.close()


def _foreground(process: subprocess.Popen, stdin: Any) -> tuple[int, int] | None:
    """Give an interactive child's process group the existing controlling TTY."""
    stream = sys.stdin if stdin is None else stdin
    try:
        fd = stream if isinstance(stream, int) else stream.fileno()
        if fd < 0 or not os.isatty(fd):
            return None
        previous = os.tcgetpgrp(fd)
        if previous != os.getpgrp():
            return None
        blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTTOU})
        try:
            os.tcsetpgrp(fd, process.pid)
            try:
                os.killpg(process.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass  # A fast child may exit after taking the foreground TTY.
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
        return fd, previous
    except (AttributeError, OSError, ValueError):
        return None


def _restore_foreground(terminal: tuple[int, int] | None, child_pid: int) -> None:
    if terminal is None:
        return
    fd, previous = terminal
    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTTOU})
    try:
        if os.tcgetpgrp(fd) == child_pid:
            os.tcsetpgrp(fd, previous)
    except OSError:
        pass
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, blocked)


class InfrastructureLock:
    """Held channels and subprocess supervision; use infrastructure_lock()."""
    def __init__(self) -> None:
        self._channels: list[_Channel] = []
        self._closed = False

    def assert_held(self) -> None:
        if self._closed:
            raise InfrastructureLockError("Infrastructure lock has already been released")
        for channel in self._channels:
            channel.drain()
            if channel.process.poll() is not None or channel.stdout_closed:
                raise InfrastructureLockError(
                    f"Infrastructure lock connection lost for {channel.name}; mutation stopped. "
                    "Inspect the host before retrying; an already submitted remote command may still have completed.")

    def run(self, argv, *, check: bool = False, timeout: float | None = None,
            input=None, capture_output: bool = False, **kwargs) -> subprocess.CompletedProcess:
        """Run a child while watching every lock, preserving an inherited login TTY.

        Supports subprocess.run's ordinary Popen arguments and capture/input.
        Process-group/session overrides are forbidden so lock-loss cancellation
        always includes local Ansible/SSH descendants.
        """
        if any(key in kwargs for key in ("start_new_session", "process_group", "preexec_fn")):
            raise ValueError("Lock-supervised subprocesses must use the managed process group")
        if kwargs.get("shell"):
            raise ValueError("Lock-supervised subprocesses require an argument array, not shell=True")
        if input is not None:
            if "stdin" in kwargs:
                raise ValueError("stdin and input cannot both be supplied")
            kwargs["stdin"] = subprocess.PIPE
        if capture_output:
            if "stdout" in kwargs or "stderr" in kwargs:
                raise ValueError("capture_output cannot be combined with stdout or stderr")
            kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assert_held()
        if not self._channels:
            raise InfrastructureLockError("Mutation requires at least one held host lock")
        process = subprocess.Popen(argv, process_group=0, **kwargs)
        terminal = None
        deadline = None if timeout is None else time.monotonic() + timeout
        first = True
        try:
            terminal = _foreground(process, kwargs.get("stdin"))
            while True:
                self.assert_held()
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    raise subprocess.TimeoutExpired(argv, timeout)
                try:
                    stdout, stderr = process.communicate(
                        input=input if first else None,
                        timeout=min(POLL_SECONDS, remaining) if remaining is not None else POLL_SECONDS)
                    self.assert_held()
                    break
                except subprocess.TimeoutExpired:
                    first = False
            result = subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
            if check:
                result.check_returncode()
            return result
        except BaseException:
            _stop_group(process)
            raise
        finally:
            _restore_foreground(terminal, process.pid)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()

    def close(self) -> None:
        self._closed = True
        for channel in reversed(self._channels):
            channel.close()
        self._channels.clear()


@contextmanager
def infrastructure_lock(inventory: dict[str, Any], timeout: float = 15.0):
    """Acquire all selected hosts without waiting on another controller.

    Each SSH connection has a bounded acquisition deadline. Closing its stdin
    releases the native lock; no persistent Ductor service or lease is installed.
    Distinct DNS aliases resolving to one host safely conflict unless their
    configured address/port can be normalized to the same endpoint.
    """
    if timeout <= 0:
        raise ValueError("Lock acquisition timeout must be positive")
    targets = _targets(inventory)
    verify_ssh_files(inventory)
    held = InfrastructureLock()
    previous_term = None
    install_handler = threading.current_thread() is threading.main_thread()
    if install_handler:
        previous_term = signal.getsignal(signal.SIGTERM)
        def terminate(signum, frame):
            if not held._closed:
                raise InfrastructureLockError("Ductor termination requested; stopping mutation before releasing host locks")
        signal.signal(signal.SIGTERM, terminate)
    try:
        for name, entry in targets:
            held.assert_held()
            marker = ("DUCTOR_LOCKED:" + secrets.token_hex(16)).encode("ascii")
            process = subprocess.Popen(
                _ssh_argv(entry, _remote_command(marker.decode(), bool(entry.get("ansible_become")))),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                bufsize=0, start_new_session=True)
            channel = _Channel(name, process, marker)
            held._channels.append(channel)
            channel.watch()
            deadline = time.monotonic() + timeout
            while not channel.acquired:
                channel.drain(min(POLL_SECONDS, max(0.0, deadline - time.monotonic())))
                status = process.poll()
                if status is not None or channel.stdout_closed:
                    if status == LOCK_CONFLICT:
                        raise InfrastructureLockError(f"Another Ductor controller holds the infrastructure lock for {name}")
                    detail = _diagnostic(channel.stderr)
                    raise InfrastructureLockError(
                        f"Cannot acquire infrastructure lock for {name} (SSH exit {status}). "
                        "Check verified SSH access, noninteractive sudo, util-linux flock, and the private lock file."
                        + (f"\n{detail}" if detail else ""))
                if time.monotonic() >= deadline:
                    raise InfrastructureLockError(f"Infrastructure lock acquisition timed out for {name}")
                # A previous host's channel can fail while another is acquired.
                for previous in held._channels[:-1]:
                    previous.drain()
                    if previous.process.poll() is not None or previous.stdout_closed:
                        raise InfrastructureLockError(f"Infrastructure lock connection lost for {previous.name} during acquisition")
            held.assert_held()
        yield held
    finally:
        try:
            held.close()
        finally:
            if install_handler:
                signal.signal(signal.SIGTERM, previous_term)
