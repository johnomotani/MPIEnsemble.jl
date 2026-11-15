"""Tests for src/wrapper/wrapper.py, run by its own interpreter.

Run with `python3 -B -m unittest discover -s test/wrapper`. Each test starts the wrapper with the
interpreter that runs the tests, and julia from PATH. The tests need Linux, and a julia on PATH.
"""

import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
WRAPPER = os.path.normpath(os.path.join(HERE, "..", "..", "src", "wrapper", "wrapper.py"))

T_DATA, T_RESIZE, T_SIGNAL, T_HELLO, T_EXIT = 1, 2, 3, 4, 5
SIG_INTERRUPT = 2
STARTUP_TIMEOUT = 90
WAIT_TIMEOUT = 15


def wrapper_env(**extra):
    """The test environment, without TERM, DISPLAY or MPI rank variables, plus `extra`."""
    env = {k: v for k, v in os.environ.items()
           if k not in ("TERM", "DISPLAY") and not k.startswith(("OMPI_", "PMIX_", "PMI_"))}
    env.update(extra)
    return env


def run_wrapper(env):
    """Run the wrapper to completion, returning (status, stderr text)."""
    proc = subprocess.run([sys.executable, "-X", "dev", "-W", "error::DeprecationWarning", WRAPPER],
                          env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=WAIT_TIMEOUT)
    return proc.returncode, proc.stderr.decode(errors="replace")


class Session:
    """A wrapper started for one rank, connected to a socket that the test listens on."""

    def __init__(self, rank=0, size=1, extra_env=None):
        self.dir = tempfile.mkdtemp(prefix="mpie-")
        self.path = os.path.join(self.dir, "s")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(1)
        env = wrapper_env(OMPI_COMM_WORLD_RANK=str(rank), OMPI_COMM_WORLD_SIZE=str(size),
                          MPIENSEMBLE_SOCKET=self.path, **(extra_env or {}))
        self.proc = subprocess.Popen(
            [sys.executable, "-X", "dev", "-W", "error::DeprecationWarning", WRAPPER],
            env=env, stdin=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.conn = None
        self.buf = b""
        self.out = b""
        self.exit = None
        self.hello = None

    def accept(self):
        self.server.settimeout(WAIT_TIMEOUT)
        self.conn, _ = self.server.accept()

    def start(self, rows=40, cols=120):
        """Accept the connection, read HELLO and send the initial terminal size."""
        self.accept()
        self.pump(until=None, timeout=WAIT_TIMEOUT, stop_at_exit=False, need_hello=True)
        self.send(T_RESIZE, struct.pack(">HH", rows, cols))

    def pump(self, until=None, timeout=10, stop_at_exit=True, need_hello=False):
        """Read frames until `until` is in the output, EXIT arrives, or the time runs out.

        Returns True if `until` is in the output.
        """
        deadline = time.monotonic() + timeout
        while True:
            if until is not None and until in self.out:
                return True
            if stop_at_exit and self.exit is not None:
                return False
            if need_hello and self.hello is not None:
                return True
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([self.conn], [], [], min(remaining, 0.1))
            if not ready:
                continue
            chunk = self.conn.recv(65536)
            if not chunk:
                return False
            self.buf += chunk
            self._parse()

    def _parse(self):
        while len(self.buf) >= 5:
            t, n = struct.unpack(">BI", self.buf[:5])
            if len(self.buf) < 5 + n:
                break
            payload = self.buf[5:5 + n]
            self.buf = self.buf[5 + n:]
            if t == T_DATA:
                self.out += payload
            elif t == T_HELLO:
                self.hello = struct.unpack(">III", payload)
            elif t == T_EXIT:
                self.exit = struct.unpack(">ii", payload)
            else:
                raise AssertionError(f"unexpected frame type {t} from the wrapper")

    def send(self, t, payload=b""):
        self.conn.sendall(struct.pack(">BI", t, len(payload)) + payload)

    def line(self, text):
        self.send(T_DATA, text.encode() + b"\n")

    def wait_status(self, timeout=WAIT_TIMEOUT):
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            return None

    def close(self):
        if self.conn is not None:
            self.conn.close()
        self.server.close()
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        if self.proc.stderr is not None:
            self.proc.stderr.close()
        shutil.rmtree(self.dir, ignore_errors=True)


class WrapperTests(unittest.TestCase):

    def session(self, **kwargs):
        s = Session(**kwargs)
        self.addCleanup(s.close)
        return s

    def assert_quiet(self, s):
        self.assertEqual(s.proc.stderr.read().decode(), "", "stderr should be empty in normal operation")

    def test_hello_prompt_and_round_trip(self):
        s = self.session()
        s.start()
        self.assertEqual(s.hello[:2], (0, 1))
        self.assertGreater(s.hello[2], 0)
        self.assertTrue(s.pump(b"julia>", timeout=STARTUP_TIMEOUT), s.out)
        s.line('println("R=", 6*7)')
        self.assertTrue(s.pump(b"R=42"), s.out)
        s.line("exit(0)")
        s.pump(timeout=WAIT_TIMEOUT)
        self.assertEqual(s.exit, (0, 0))
        self.assertEqual(s.wait_status(), 0)
        self.assert_quiet(s)

    def test_initial_and_later_resize(self):
        s = self.session()
        s.start(rows=30, cols=90)
        self.assertTrue(s.pump(b"julia>", timeout=STARTUP_TIMEOUT), s.out)
        s.line('println("SZ=", displaysize(stdout))')
        self.assertTrue(s.pump(b"SZ=(30, 90)"), s.out)
        s.send(T_RESIZE, struct.pack(">HH", 40, 100))
        time.sleep(0.5)
        s.line('println("SZ2=", displaysize(stdout))')
        self.assertTrue(s.pump(b"SZ2=(40, 100)"), s.out)
        s.line("exit(0)")
        s.pump(timeout=WAIT_TIMEOUT)
        self.assertEqual(s.exit, (0, 0))

    def test_interrupt_frame(self):
        s = self.session()
        s.start()
        self.assertTrue(s.pump(b"julia>", timeout=STARTUP_TIMEOUT), s.out)
        s.line("sleep(30)")
        time.sleep(1)
        s.send(T_SIGNAL, bytes([SIG_INTERRUPT]))
        self.assertTrue(s.pump(b"InterruptException", timeout=WAIT_TIMEOUT), s.out)
        s.line('println("ALIVE")')
        self.assertTrue(s.pump(b"ALIVE"), s.out)
        s.line("exit(0)")
        s.pump(timeout=WAIT_TIMEOUT)
        self.assertEqual(s.exit, (0, 0))

    def test_exit_frame_and_status(self):
        s = self.session()
        s.start()
        self.assertTrue(s.pump(b"julia>", timeout=STARTUP_TIMEOUT), s.out)
        s.line("exit(7)")
        s.pump(timeout=WAIT_TIMEOUT)
        self.assertEqual(s.exit, (7, 0))
        self.assertEqual(s.wait_status(), 7)
        self.assert_quiet(s)

    def test_parent_close_ends_julia_and_wrapper(self):
        s = self.session()
        s.start()
        self.assertTrue(s.pump(b"julia>", timeout=STARTUP_TIMEOUT), s.out)
        s.conn.close()
        s.conn = None
        start = time.monotonic()
        status = s.wait_status()
        self.assertIsNotNone(status, "wrapper did not end after the socket closed")
        self.assertLess(time.monotonic() - start, 10)
        self.assertEqual(status, 0)
        self.assert_quiet(s)

    def test_parent_close_kills_julia_after_timeout(self):
        s = self.session()
        s.start()
        self.assertTrue(s.pump(b"julia>", timeout=STARTUP_TIMEOUT), s.out)
        s.line("sleep(60)")
        time.sleep(1)
        s.conn.close()
        s.conn = None
        status = s.wait_status(timeout=30)
        self.assertIsNotNone(status, "wrapper did not end after SIGKILL")
        self.assertNotEqual(status, 0)
        err = s.proc.stderr.read().decode()
        self.assertIn("SIGKILL", err)

    def test_missing_julia_reports_in_pane_and_exits_127(self):
        empty = self.session_dir_without_julia()
        s = self.session(extra_env={"PATH": empty})
        s.start()
        s.pump(timeout=WAIT_TIMEOUT)
        self.assertEqual(s.exit, (127, 0), s.out)
        self.assertIn(b"julia was not found on PATH", s.out)
        self.assertEqual(s.wait_status(), 127)

    def session_dir_without_julia(self):
        d = tempfile.mkdtemp(prefix="mpie-nojulia-")
        self.addCleanup(shutil.rmtree, d, True)
        return d

    def test_missing_rank_variables(self):
        status, err = run_wrapper(wrapper_env(MPIENSEMBLE_SOCKET="/nonexistent/s"))
        self.assertNotEqual(status, 0)
        self.assertIn("no MPI rank variables are set", err)
        self.assertNotIn("Traceback", err)

    def test_unreachable_socket(self):
        d = tempfile.mkdtemp(prefix="mpie-")
        self.addCleanup(shutil.rmtree, d, True)
        env = wrapper_env(OMPI_COMM_WORLD_RANK="0", OMPI_COMM_WORLD_SIZE="1",
                          MPIENSEMBLE_SOCKET=os.path.join(d, "absent"))
        status, err = run_wrapper(env)
        self.assertEqual(status, 1)
        self.assertIn("cannot connect to the socket", err)
        self.assertNotIn("Traceback", err)

    def test_first_frame_must_be_resize(self):
        s = self.session()
        s.accept()
        s.pump(until=None, timeout=WAIT_TIMEOUT, stop_at_exit=False, need_hello=True)
        s.line("1 + 1")
        self.assertIsNotNone(s.wait_status())
        self.assertEqual(s.proc.returncode, 1)
        err = s.proc.stderr.read().decode()
        self.assertIn("must be RESIZE", err)
        self.assertIsNone(s.exit)

    def test_unknown_frame_type_fails_without_exit_frame(self):
        s = self.session()
        s.start()
        self.assertTrue(s.pump(b"julia>", timeout=STARTUP_TIMEOUT), s.out)
        s.send(9, b"")
        self.assertIsNotNone(s.wait_status())
        self.assertEqual(s.proc.returncode, 1)
        self.assertIn("unexpected frame type 9", s.proc.stderr.read().decode())
        s.pump(timeout=2)
        self.assertIsNone(s.exit)


if __name__ == "__main__":
    unittest.main()
