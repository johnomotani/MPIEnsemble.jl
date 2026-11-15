"""Stand-in for src/wrapper/wrapper.py in the launcher tests. It speaks the same frame protocol without
starting julia. FAKE_WRAPPER_MODE selects what it does:

    echo         Echoes DATA back as DATA, reports RESIZE and SIGNAL as DATA, and sends EXIT 0 when the
                 socket closes.
    no_exit      Sends one DATA frame, then exits without an EXIT frame.
    exit_frame   Sends one DATA frame, then EXIT with code 7.
    wrong_size   Sends HELLO with one more rank than the launch has.
    ignore_close Ignores SIGTERM and, when the socket closes, sleeps and does not exit.
    silent       Never connects.
    exit_on_input Echoes as echo does, but when a DATA frame contains "exit", sends EXIT 0 and exits.
    argv         Echoes as echo does, but first sends DATA with the repr of its arguments (sys.argv[1:]), then a
                 line with its PATH.

Any mode may be given as MODE@RANK, which applies it to that rank only. The echo mode writes "resize R C"
for each RESIZE frame it receives, and the initial one.
"""
import os
import select
import signal
import socket
import struct
import sys
import time

T_DATA, T_RESIZE, T_SIGNAL, T_HELLO, T_EXIT = 1, 2, 3, 4, 5

rank = int(os.environ["OMPI_COMM_WORLD_RANK"])
size = int(os.environ["OMPI_COMM_WORLD_SIZE"])
mode = os.environ.get("FAKE_WRAPPER_MODE", "echo")
# A mode of the form MODE@RANK applies to that rank only; the other ranks echo.
if "@" in mode:
    mode, _, only_rank = mode.partition("@")
    if int(only_rank) != rank:
        mode = "echo"


def frame(frame_type, payload=b""):
    return struct.pack(">BI", frame_type, len(payload)) + payload


def read_frame(sock, buf):
    """Return (type, payload) for the next frame, or None when the socket closes."""
    while True:
        if len(buf) >= 5:
            frame_type, n = struct.unpack(">BI", buf[:5])
            if len(buf) >= 5 + n:
                return frame_type, bytes(buf[5:5 + n]), buf[5 + n:]
        chunk = sock.recv(65536)
        if not chunk:
            return None
        buf += chunk


if mode == "silent":
    time.sleep(1000)
    sys.exit(0)

if mode == "ignore_close":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(os.environ["MPIENSEMBLE_SOCKET"])
hello_size = size + 1 if mode == "wrong_size" else size
sock.sendall(frame(T_HELLO, struct.pack(">III", rank, hello_size, os.getpid())))

if mode == "wrong_size":
    time.sleep(1000)

buf = b""
first = read_frame(sock, buf)
if first is None or first[0] != T_RESIZE:
    sys.exit("fake wrapper: the first frame must be RESIZE")
rows, cols = struct.unpack(">HH", first[1])
buf = first[2]

if mode == "ignore_close":
    # Keep the socket open until the parent closes it, then ignore that.
    read_frame(sock, buf)
    time.sleep(1000)

if mode == "no_exit":
    sock.sendall(frame(T_DATA, b"bye\n"))
    sys.exit(0)

if mode == "exit_frame":
    sock.sendall(frame(T_DATA, b"bye\n"))
    sock.sendall(frame(T_EXIT, struct.pack(">ii", 7, 0)))
    sys.exit(0)

# echo, and argv, which also reports its arguments and PATH
if mode == "argv":
    # Lines end with CR LF, as a terminal sends them, so that the pane starts each line at its left edge.
    sock.sendall(frame(T_DATA, (repr(sys.argv[1:]) + "\r\n").encode()))
    sock.sendall(frame(T_DATA, ("PATH " + repr(os.environ.get("PATH", "")) + "\r\n").encode()))
sock.sendall(frame(T_DATA, f"resize {rows} {cols}\n".encode()))
while True:
    item = read_frame(sock, buf)
    if item is None:
        try:
            sock.sendall(frame(T_EXIT, struct.pack(">ii", 0, 0)))
        except BrokenPipeError:
            pass  # The parent has closed its end, so there is nobody to report to.
        sys.exit(0)
    frame_type, payload, buf = item
    if frame_type == T_DATA:
        if mode == "exit_on_input" and b"exit" in payload:
            sock.sendall(frame(T_EXIT, struct.pack(">ii", 0, 0)))
            sys.exit(0)
        sock.sendall(frame(T_DATA, payload))
    elif frame_type == T_SIGNAL:
        sock.sendall(frame(T_DATA, f"signal {payload[0]}\n".encode()))
    elif frame_type == T_RESIZE:
        rows, cols = struct.unpack(">HH", payload)
        sock.sendall(frame(T_DATA, f"resize {rows} {cols}\n".encode()))
