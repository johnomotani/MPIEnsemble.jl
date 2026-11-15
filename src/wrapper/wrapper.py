"""Per-rank wrapper: runs one command in a pseudo-terminal and relays it over a Unix socket.

Start one wrapper per MPI rank, for example `mpiexec -n 2 PYTHON wrapper.py -- julia -t2`, where PYTHON is the
Python interpreter; `MpiLauncher.python_executable()` returns the one from Python_jll. Uses only the
standard library.
Requires Linux and Python 3.11 or later (for `os.login_tty`); on other systems it exits with status 1
and a message on stderr.

Environment
    Rank and size are read from the first complete pair that is set:
    OMPI_COMM_WORLD_RANK with OMPI_COMM_WORLD_SIZE, then PMIX_RANK with OMPI_COMM_WORLD_SIZE,
    then PMI_RANK with PMI_SIZE. If no pair is set, the wrapper exits with status 1.

    MPIENSEMBLE_SOCKET
        Path of the Unix stream socket that the parent listens on. Paths longer than about
        100 bytes do not fit in the socket address.

    JULIA_PROJECT
        Not read by the wrapper. It is inherited by the child, as is the rest of the environment.

Command line
    `wrapper.py` alone runs the default command, `julia -q`, where `julia` is found on PATH. The
    launcher must put the Julia executable it wants first on PATH.

    `wrapper.py -- COMMAND [ARGUMENT...]` runs COMMAND with the given arguments, exactly as given: the
    first is looked up on PATH, and the rest are passed unchanged. Everything after `--` is the command.

    The child is started with TERM=xterm-256color in either case.

Protocol
    Every message is a frame: a 1-byte type, a 4-byte big-endian payload length, then the
    payload. The frame types are:

        T_DATA = 1    Both directions. Wrapper to parent: bytes read from the terminal, which
                      is REPL output. Parent to wrapper: bytes written to the terminal, which
                      is REPL input.
        T_RESIZE = 2  Parent to wrapper. Payload: rows, then columns, as two unsigned 16-bit
                      big-endian integers. Both must be at least 1.
        T_SIGNAL = 3  Parent to wrapper. Payload: one byte with the signal number. Only
                      SIG_INTERRUPT (2) is accepted; it is sent to the REPL as Ctrl+C.
        T_HELLO = 4   Wrapper to parent, once, after connecting. Payload: rank, size and pid,
                      three unsigned 32-bit big-endian integers.
        T_EXIT = 5    Wrapper to parent, last, when the child has exited. Payload: exit code, then
                      terminating signal, as two signed 32-bit big-endian integers. A child
                      killed by a signal has code 0 and the signal number; otherwise the signal
                      is 0.

    The wrapper sends HELLO on connecting. The parent must then send RESIZE as its first frame:
    it gives the initial terminal size, and the child is started only after it arrives. Any other
    first frame is an error. Frames after that may come in any order.

Shutdown
    When the parent closes the socket, the wrapper writes Ctrl+D to the terminal, keeps relaying
    output (which is discarded, as the parent is gone), and sends SIGKILL to the child if it has not
    exited after 5 seconds. The child's exit status is not reported, because the socket is closed.

Failures
    If the command cannot be started, the child writes a message to the terminal, so it appears in
    the pane: "command not found: NAME" when the first argument is not found on PATH. The wrapper
    then sends EXIT with code 127 for that, or 126 for any other failure to exec the command.

    If the socket cannot be reached, the parent sends a malformed or unexpected frame, or the
    command line is malformed, the wrapper writes a message to stderr, kills the child with SIGKILL
    and exits with status 1. No EXIT frame is sent, so the parent sees the socket end without one.

    The wrapper writes nothing to stderr in normal operation. Its exit status is the child's exit
    code, or 1 if the child was killed by a signal.
"""

import sys

if sys.version_info < (3, 11):
    sys.exit("wrapper.py needs Python 3.11 or later (for os.login_tty); found "
             + sys.version.split()[0])
if not sys.platform.startswith("linux"):
    sys.exit("wrapper.py runs on Linux only; found " + sys.platform)

import errno
import fcntl
import os
import select
import signal
import socket
import struct
import termios
import time

T_DATA, T_RESIZE, T_SIGNAL, T_HELLO, T_EXIT = 1, 2, 3, 4, 5
SIG_INTERRUPT = 2
CTRL_C = b"\x03"
CTRL_D = b"\x04"
SHUTDOWN_TIMEOUT = 5.0
POLL_INTERVAL = 0.05
EXIT_NOT_EXECUTABLE = 126
EXIT_NOT_FOUND = 127
RANK_VARIABLES = (
    ("OMPI_COMM_WORLD_RANK", "OMPI_COMM_WORLD_SIZE"),
    ("PMIX_RANK", "OMPI_COMM_WORLD_SIZE"),
    ("PMI_RANK", "PMI_SIZE"),
)
DEFAULT_COMMAND = ["julia", "-q"]

# Prefix of messages on stderr. Includes the rank once it is known.
prefix = "wrapper"


class WrapperError(Exception):
    """A failure that ends the wrapper with status 1, after its message is written to stderr."""


def warn(message):
    print(f"{prefix}: {message}", file=sys.stderr, flush=True)


def frame(frame_type, payload=b""):
    return struct.pack(">BI", frame_type, len(payload)) + payload


class Reader:
    """Splits the byte stream from the socket into frames."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = b""

    def read_frames(self):
        """Receive once and return the complete frames received so far, as (type, payload) pairs.

        Raises EOFError when the parent closes the socket between frames.
        """
        try:
            chunk = self.sock.recv(65536)
        except ConnectionResetError:
            # The kernel reports a reset when the parent closes with unread data; this is end of stream.
            chunk = b""
        except OSError as e:
            raise WrapperError(f"cannot read from the socket: {e}") from None
        if not chunk:
            if self.buf:
                raise WrapperError("the parent closed the socket in the middle of a frame")
            raise EOFError()
        self.buf += chunk
        frames = []
        while len(self.buf) >= 5:
            frame_type, n = struct.unpack(">BI", self.buf[:5])
            if len(self.buf) < 5 + n:
                break
            frames.append((frame_type, self.buf[5:5 + n]))
            self.buf = self.buf[5 + n:]
        return frames


def _int_variable(environ, name):
    try:
        return int(environ[name])
    except ValueError:
        raise WrapperError(f"{name} is not an integer: {environ[name]!r}") from None


def rank_info(environ):
    """Return (rank, size) from the first set pair in RANK_VARIABLES."""
    for rank_name, size_name in RANK_VARIABLES:
        if rank_name in environ and size_name in environ:
            rank = _int_variable(environ, rank_name)
            size = _int_variable(environ, size_name)
            if not 0 <= rank < size:
                raise WrapperError(f"{rank_name}={rank} is outside 0..{size - 1} for size {size}")
            return rank, size
    raise WrapperError("no MPI rank variables are set (expected OMPI_COMM_WORLD_RANK and "
                       "OMPI_COMM_WORLD_SIZE, or PMIX_RANK with OMPI_COMM_WORLD_SIZE, or "
                       "PMI_RANK and PMI_SIZE)")


def parse_resize(payload):
    if len(payload) != 4:
        raise WrapperError(f"RESIZE payload must be 4 bytes, got {len(payload)}")
    rows, cols = struct.unpack(">HH", payload)
    if rows == 0 or cols == 0:
        raise WrapperError(f"RESIZE to {rows} rows and {cols} columns")
    return rows, cols


def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def connect(path):
    if not path:
        raise WrapperError("MPIENSEMBLE_SOCKET is not set")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except OSError as e:
        sock.close()
        raise WrapperError(f"cannot connect to the socket {path}: {e}") from None
    return sock


def _report_in_child(message):
    try:
        os.write(2, (message + "\n").encode())
    except OSError:
        pass  # No other channel is open; the exit status still reports the failure.


def parse_command(argv):
    """Return the command to run, given the arguments after the script path.

    No arguments give DEFAULT_COMMAND. Otherwise the arguments must be `--` followed by the command.
    """
    if not argv:
        return list(DEFAULT_COMMAND)
    if argv[0] != "--":
        raise WrapperError(f"unexpected argument {argv[0]!r}; the command must follow --")
    if len(argv) == 1:
        raise WrapperError("-- must be followed by the command to run")
    return argv[1:]


def exec_command(master, slave, command, env):
    """Child side of the fork. Only returns if the command cannot be started, giving the exit status."""
    # Python ignores SIGPIPE, and exec would pass that on to the command.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try:
        os.close(master)
        os.login_tty(slave)
        os.execvpe(command[0], command, env)
    except FileNotFoundError:
        _report_in_child(f"wrapper: command not found: {command[0]}")
        return EXIT_NOT_FOUND
    except BaseException as e:
        _report_in_child(f"wrapper: cannot start {command[0]}: {e}")
        return EXIT_NOT_EXECUTABLE


def spawn_command(master, slave, command):
    env = dict(os.environ, TERM="xterm-256color")
    pid = os.fork()
    if pid == 0:
        os._exit(exec_command(master, slave, command, env))
    return pid


class Session:
    """Relays one child process between its terminal and the socket."""

    def __init__(self, sock, reader, master, pid, queued):
        self.sock = sock
        self.reader = reader
        self.master = master
        self.pid = pid
        self.queued = queued           # frames received before the child started
        self.status = None             # waitpid status once the child has exited
        self.pending_in = bytearray()  # terminal input not yet written
        self.sock_open = True
        self.master_open = True
        self.kill_at = None            # monotonic time at which the child is killed

    def serve(self):
        """Relay until the child exits, then send EXIT. Returns the wrapper's exit status."""
        try:
            for frame_type, payload in self.queued:
                self.handle(frame_type, payload)
            self.queued = []
            while not self.poll_child():
                self.step()
            self.drain_output()
            code, signum = self.exit_fields()
            self.send(frame(T_EXIT, struct.pack(">ii", code, signum)))
        except BaseException:
            self.kill_child()
            raise
        finally:
            self.sock.close()
        code, signum = self.exit_fields()
        return 1 if signum else code

    def poll_child(self):
        if self.status is None:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done == self.pid:
                self.status = status
        return self.status is not None

    def exit_fields(self):
        """(code, signal) for the EXIT frame. Valid once the child has exited."""
        code = os.waitstatus_to_exitcode(self.status)
        if code < 0:
            return 0, -code
        return code, 0

    def kill_child(self):
        # Only poll_child reaps the child, so while status is None the pid still refers to it.
        if self.status is None:
            os.kill(self.pid, signal.SIGKILL)

    def step(self):
        read = []
        write = []
        if self.master_open:
            read.append(self.master)
            if self.pending_in:
                write.append(self.master)
        if self.sock_open:
            read.append(self.sock)
        ready_read, ready_write, _ = select.select(read, write, [], POLL_INTERVAL)
        if self.master in ready_write:
            self.flush_input()
        if self.master in ready_read:
            self.read_output()
        if self.sock in ready_read:
            self.read_parent()
        self.check_kill_timer()

    def flush_input(self):
        try:
            written = os.write(self.master, self.pending_in)
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno != errno.EIO:
                raise
            # EIO: the child has closed the terminal. Its exit is reported by the EXIT frame.
            self.master_open = False
            self.pending_in.clear()
            return
        del self.pending_in[:written]

    def read_output(self):
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno != errno.EIO:
                raise
            data = b""  # EIO: the child has closed the terminal.
        if not data:
            self.master_open = False
            return
        self.send(frame(T_DATA, data))

    def read_parent(self):
        try:
            frames = self.reader.read_frames()
        except EOFError:
            self.start_shutdown()
            return
        for frame_type, payload in frames:
            self.handle(frame_type, payload)

    def handle(self, frame_type, payload):
        if frame_type == T_DATA:
            self.pending_in += payload
        elif frame_type == T_RESIZE:
            rows, cols = parse_resize(payload)
            set_winsize(self.master, rows, cols)
        elif frame_type == T_SIGNAL:
            if payload != bytes([SIG_INTERRUPT]):
                raise WrapperError(f"unsupported signal payload {payload!r}")
            self.pending_in += CTRL_C
        else:
            raise WrapperError(f"unexpected frame type {frame_type} from the parent")

    def start_shutdown(self):
        self.sock_open = False
        if self.kill_at is None:
            self.kill_at = time.monotonic() + SHUTDOWN_TIMEOUT
            self.pending_in += CTRL_D

    def check_kill_timer(self):
        if self.kill_at is not None and time.monotonic() >= self.kill_at and self.status is None:
            self.kill_at = None
            warn(f"the command did not exit {SHUTDOWN_TIMEOUT:g} s after Ctrl+D; sending SIGKILL")
            os.kill(self.pid, signal.SIGKILL)

    def drain_output(self):
        # The child has exited. Read what the terminal still holds, until it reports end of file or
        # nothing arrives for one poll interval.
        while self.master_open:
            ready, _, _ = select.select([self.master], [], [], POLL_INTERVAL)
            if not ready:
                return
            self.read_output()

    def send(self, data):
        if not self.sock_open:
            return
        try:
            self.sock.sendall(data)
        except (BrokenPipeError, ConnectionResetError):
            # The parent has closed its end, which is the same as end of stream.
            self.start_shutdown()


def first_frames(reader):
    """Block until the parent sends its first frames, and return them."""
    try:
        while True:
            frames = reader.read_frames()
            if frames:
                return frames
    except EOFError:
        raise WrapperError("the parent closed the socket before sending the terminal size") from None


def run():
    global prefix
    command = parse_command(sys.argv[1:])
    rank, size = rank_info(os.environ)
    prefix = f"wrapper (rank {rank})"
    sock = connect(os.environ.get("MPIENSEMBLE_SOCKET", ""))
    try:
        try:
            sock.sendall(frame(T_HELLO, struct.pack(">III", rank, size, os.getpid())))
        except OSError as e:
            raise WrapperError(f"cannot send HELLO: {e}") from None
        reader = Reader(sock)
        frames = first_frames(reader)
        if frames[0][0] != T_RESIZE:
            raise WrapperError(f"the first frame from the parent must be RESIZE, got type {frames[0][0]}")
        rows, cols = parse_resize(frames[0][1])
        master, slave = os.openpty()
        set_winsize(slave, rows, cols)
        os.set_blocking(master, False)
        pid = spawn_command(master, slave, command)
        os.close(slave)
        return Session(sock, reader, master, pid, frames[1:]).serve()
    finally:
        sock.close()


def main():
    try:
        status = run()
    except WrapperError as e:
        warn(str(e))
        status = 1
    sys.exit(status)


if __name__ == "__main__":
    main()
