#!/usr/bin/env python3
"""hpcworker connect's relay: the one writer to the terminal while the Claude sign-in sitting runs.

`hpcworker connect` sends the sitting's allocation (srun, its own messages included) into a pipe, and
this program copies it to the terminal one whole line at a time, so every line the extension parses
arrives whole and at the start of a line (docs/V11_CONTRACT.md, "The keepalive and the one-writer
rule"). When KEEPALIVE_S seconds pass with nothing written and no part of a line waiting, it writes
the keepalive line, "HPCW-LOGIN: still waiting": the portal's shell closes a connection that shows no
activity (Open OnDemand's default is 300 s), and the wait for the sign-in computer alone can be ten
minutes. A part of a line that waits five seconds with nothing after it is written as a line of its
own (the sitting prints whole lines; srun may split one only for a moment).

    relay.py KEEPALIVE_S SUMMARY_FILE

At the end SUMMARY_FILE gets two lines: the last "SIGNED-IN ..." line seen (or an empty line) and the
last "HPCW-LOGIN-FAILED: ..." line seen (or an empty line), the outcome connect turns into its
HPCW-STEP line. Nothing else is kept. The code the student pastes never passes through here: it goes
from the terminal to srun's standard input, and the sitting never echoes it.

Standard library only, Python 3.6 (the login node's system python). A reader thread rather than
select(): the unit tests also run this under Windows, where select() takes sockets only.
"""
import os
import sys
import threading
import time

try:
    import queue
except ImportError:  # pragma: no cover (python 2 is not supported; kept so the error is plain)
    import Queue as queue  # noqa: N813

KEEPALIVE = b"HPCW-LOGIN: still waiting"
PARTIAL_AFTER_S = 5.0


def _reader(fd, q):
    while True:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        q.put(chunk)
        if not chunk:
            return


class Relay(object):
    def __init__(self, out, every):
        self.out = out
        self.every = every
        self.last_out = time.time()
        self.signed = b""
        self.failed = b""
        self.broken = False

    def emit(self, line):
        text = line.replace(b"\r", b"")
        bare = text.strip()
        if bare.startswith(b"SIGNED-IN"):
            self.signed = bare
        elif bare.startswith(b"HPCW-LOGIN-FAILED"):
            self.failed = bare
        if not self.broken:
            try:
                # one write per line: a line never shares a write with another
                self.out.write(text + b"\n")
                self.out.flush()
            except (OSError, ValueError):
                self.broken = True  # the terminal went away; keep reading so srun is never stopped by a full pipe
        self.last_out = time.time()


def main(argv):
    every = float(argv[1]) if len(argv) > 1 else 20.0
    summary = argv[2] if len(argv) > 2 else ""
    out = getattr(sys.stdout, "buffer", sys.stdout)
    r = Relay(out, every)
    q = queue.Queue()
    t = threading.Thread(target=_reader, args=(sys.stdin.fileno(), q))
    t.daemon = True
    t.start()
    buf = b""
    last_in = time.time()
    while True:
        try:
            chunk = q.get(timeout=0.5)
        except queue.Empty:
            chunk = None
        now = time.time()
        if chunk is not None:
            if not chunk:
                break
            buf += chunk
            last_in = now
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                r.emit(line)
        if buf and now - last_in >= PARTIAL_AFTER_S:
            r.emit(buf)
            buf = b""
        if not buf and every > 0 and now - r.last_out >= every:
            r.emit(KEEPALIVE)
    if buf:
        r.emit(buf)
    if summary:
        try:
            fd = os.open(summary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as fh:
                fh.write(r.signed + b"\n" + r.failed + b"\n")
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
