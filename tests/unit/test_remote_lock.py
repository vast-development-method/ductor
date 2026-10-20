"""Real local flock/process checks behind a substituted SSH transport."""
import copy
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from ductor_core import remote_lock
from ductor_core.inventory import build_inventory
from fixtures import complete_config


class RemoteLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config = complete_config(self.root)
        for name in ("ssh-key", "known-hosts"):
            path = self.root / name
            path.write_text("private test fixture\n")
            path.chmod(0o600)
        self.inventory = build_inventory(self.config, self.root, self.root)
        for host in self.entries().values():
            host["ansible_become"] = False
        self.lock_path = self.root / "global-infrastructure.lock"
        self.path_patch = patch.object(remote_lock, "LOCK_PATH", str(self.lock_path))
        self.path_patch.start()
        self.transport_patch = patch.object(remote_lock, "_ssh_argv", side_effect=self.local_transport)
        self.transport = self.transport_patch.start()

    def tearDown(self):
        self.transport_patch.stop()
        self.path_patch.stop()
        self.temp.cleanup()

    def entries(self):
        return self.inventory["all"]["children"]["ductor_hosts"]["hosts"]

    @staticmethod
    def local_transport(entry, command):
        return ["/bin/sh", "-c", command]

    def test_real_host_lock_conflicts_across_controllers_and_releases_without_daemon(self):
        with remote_lock.infrastructure_lock(self.inventory) as first:
            first.assert_held()
            with self.assertRaises(remote_lock.InfrastructureLockError):
                with remote_lock.infrastructure_lock(copy.deepcopy(self.inventory)):
                    self.fail("A second controller acquired the same host")
            first.assert_held()
        with remote_lock.infrastructure_lock(self.inventory) as second:
            result = second.run([sys.executable, "-c", "print('admitted')"], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), "admitted")
        self.assertEqual(self.lock_path.stat().st_mode & 0o777, 0o600)

    def test_untrusted_ssh_inputs_are_rejected_before_contact(self):
        (self.root / "known-hosts").chmod(0o666)
        with self.assertRaises(ValueError):
            with remote_lock.infrastructure_lock(self.inventory):
                pass
        self.transport.assert_not_called()

    def test_endpoint_aliases_are_deduplicated_and_conflicting_identity_refused(self):
        self.entries()["alias"] = copy.deepcopy(self.entries()["control"])
        with remote_lock.infrastructure_lock(self.inventory):
            self.assertEqual(self.transport.call_count, 1)
        self.entries()["alias"]["ansible_user"] = "different-owner"
        with self.assertRaisesRegex(remote_lock.InfrastructureLockError, "inconsistent SSH"):
            with remote_lock.infrastructure_lock(self.inventory):
                pass

    def test_failed_second_host_releases_first_host(self):
        second = copy.deepcopy(self.entries()["control"])
        first = self.entries()["control"]
        first["ansible_host"] = "a.example.org"
        second["ansible_host"] = "z.example.org"
        self.entries()["second"] = second
        def transport(entry, command):
            if entry["ansible_host"] == "z.example.org":
                return ["/bin/sh", "-c", "exit 73"]
            return self.local_transport(entry, command)
        self.transport.side_effect = transport
        with self.assertRaises(remote_lock.InfrastructureLockError):
            with remote_lock.infrastructure_lock(self.inventory):
                pass
        self.entries().pop("second")
        with remote_lock.infrastructure_lock(self.inventory) as held:
            held.assert_held()

    def test_acquisition_is_bounded_and_does_not_treat_startup_noise_as_acknowledgement(self):
        self.transport.side_effect = lambda entry, command: [
            sys.executable, "-c", "import time;print('DUCTOR_LOCKED',flush=True);time.sleep(20)"]
        start = time.monotonic()
        with self.assertRaisesRegex(remote_lock.InfrastructureLockError, "timed out"):
            with remote_lock.infrastructure_lock(self.inventory, timeout=0.15):
                pass
        self.assertLess(time.monotonic() - start, 3)

    def test_lost_lock_terminates_running_mutation_process_group(self):
        started = self.root / "started"
        completed = self.root / "completed"
        pid_path = self.root / "child.pid"
        with remote_lock.infrastructure_lock(self.inventory) as held:
            def lose_channel():
                deadline = time.monotonic() + 5
                while not started.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                held._channels[0].process.kill()
            breaker = threading.Thread(target=lose_channel)
            breaker.start()
            code = (
                "import os,pathlib,time;"
                f"pathlib.Path({str(pid_path)!r}).write_text(str(os.getpid()));"
                f"pathlib.Path({str(started)!r}).write_text('started');"
                "time.sleep(10);"
                f"pathlib.Path({str(completed)!r}).write_text('unsafe continuation')")
            try:
                with self.assertRaisesRegex(remote_lock.InfrastructureLockError, "connection lost"):
                    held.run([sys.executable, "-c", code])
            finally:
                breaker.join(timeout=6)
            self.assertFalse(completed.exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_path.read_text()), 0)

    def test_subprocess_input_capture_error_status_and_timeout(self):
        with remote_lock.infrastructure_lock(self.inventory) as held:
            result = held.run([sys.executable, "-c", "import sys;print(sys.stdin.read())"],
                              input="ordinary input", capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "ordinary input")
            with self.assertRaises(subprocess.CalledProcessError):
                held.run([sys.executable, "-c", "raise SystemExit(7)"], check=True)
            with self.assertRaises(subprocess.TimeoutExpired):
                held.run([sys.executable, "-c", "import time;time.sleep(10)"], timeout=0.1)
            held.assert_held()

    def test_existing_symlink_lock_is_never_followed_or_replaced(self):
        outside = self.root / "outside"
        outside.write_text("unchanged")
        self.lock_path.symlink_to(outside)
        with self.assertRaises(remote_lock.InfrastructureLockError):
            with remote_lock.infrastructure_lock(self.inventory):
                pass
        self.assertTrue(self.lock_path.is_symlink())
        self.assertEqual(outside.read_text(), "unchanged")

    def test_controller_sigterm_stops_child_before_releasing_host_lock(self):
        child_pid = self.root / "mutation.pid"
        mutation = ("import os,pathlib,time;"
                    f"pathlib.Path({str(child_pid)!r}).write_text(str(os.getpid()));time.sleep(30)")
        controller_code = (
            "import json,sys;from ductor_core import remote_lock as r;"
            f"r.LOCK_PATH={str(self.lock_path)!r};"
            "r._ssh_argv=lambda entry,command:['/bin/sh','-c',command];"
            "inventory=json.loads(sys.argv[1]);\n"
            "with r.infrastructure_lock(inventory) as held:\n"
            f" held.run([sys.executable,'-c',{mutation!r}])\n")
        controller = subprocess.Popen([sys.executable, "-c", controller_code, json.dumps(self.inventory)],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not child_pid.exists() and controller.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(child_pid.exists(), "Controller did not start supervised mutation")
            controller.send_signal(signal.SIGTERM)
            _, error = controller.communicate(timeout=6)
            self.assertNotEqual(controller.returncode, 0)
            self.assertIn(b"stopping mutation before releasing", error)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(child_pid.read_text()), 0)
            with remote_lock.infrastructure_lock(self.inventory) as held:
                held.assert_held()
        finally:
            if controller.poll() is None:
                controller.kill()
                controller.wait()
            for stream in (controller.stdout, controller.stderr):
                stream.close()

    def test_ssh_options_keep_strict_trust_and_independent_noninteractive_channel(self):
        self.transport_patch.stop()
        try:
            entry = self.entries()["control"]
            command = remote_lock._ssh_argv(entry, "remote-lock")
            for required in ("StrictHostKeyChecking=yes", "IdentitiesOnly=yes", "BatchMode=yes",
                             "ControlMaster=no", "ControlPath=none", "ServerAliveInterval=2",
                             "UserKnownHostsFile=" + str(self.root / "known-hosts")):
                self.assertIn(required, command)
            self.assertIn(str(self.root / "ssh-key"), command)
            self.assertIn("-T", command)
            self.assertEqual(command[-1], "remote-lock")
            self.assertTrue(remote_lock._remote_command("marker", True).startswith("sudo -n -- "))
        finally:
            self.transport = self.transport_patch.start()


if __name__ == "__main__":
    unittest.main()
