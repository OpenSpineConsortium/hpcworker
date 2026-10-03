"""hpcworker worker watch --json (framework 11), against a scratch account and the fake scheduler of
fakegrid.py: one JSON line per change and at the start and the end, a keepalive line when nothing was
written for a while (2 s here for the 20 s of the real thing; the look every 1 s for every 5 s), the
scheduler asked at most once a minute and only while the worker is in line (and not at all within the
gate's floor), the end at online, stopped, error, an ended chain, or out of time, each with its exit
status, and the end when the reader goes away, with a gate's watch slot given back. Framework 13: a job
that ended naming its successor has the successor asked about, and the watch ends "stopped" when the
successor is gone."""
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest

import fakegrid as G

STATUS_KEYS = ["v", "event", "final", "run", "job", "next_job", "state_dir", "status", "connection", "scheduler", "line"]
FAST = {"HPCW_WATCH_POLL_S": "1", "HPCW_WATCH_KEEPALIVE_S": "2"}


def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t or time.time()))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.g.setup()
        os.makedirs(self.g.rundir())
        with open(os.path.join(self.g.rundir(), "job.id"), "w", newline="\n") as fh:
            fh.write("40501234\n")
        self.g.jobs(["40501234|PENDING|Priority|N/A|"])

    def tearDown(self):
        self.tmp.cleanup()

    def queued(self, **extra):
        s = {"version": 11, "site": "testsite", "run": "worker", "job": "40501234", "node": "", "state": "queued",
             "message": "waiting for a computer", "needs": "nothing", "submitted_at": iso(), "title": "Wayne State grid",
             "renewal": False, "chain": True, "next_job": "", "scheduler_state": "", "reason": "", "expected_start": "", "checked_at": ""}
        s.update(extra)
        return s

    def popen(self, args, **env):
        e = dict(os.environ)
        e.update({"HPCW_PYTHON": G.PY, "MSYS_NO_PATHCONV": "1", "MSYS2_ARG_CONV_EXCL": "*"})
        e.update(self.g.env(**dict(FAST, **env)))
        script = "export PATH='%s':\"$PATH\"; exec bash '%s' %s" % (G.msys(self.g.bin), self.g.tool, args)
        return subprocess.Popen([G.BASH, "-c", script], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                universal_newlines=True, encoding="utf-8", env=e)

    def watch(self, args="--name worker --json --minutes 1", steps=(), timeout=90, **env):
        """run the watch; STEPS are (seconds after its first line, status dict) written while it runs: timed
        from the first line, not from the start, because a Windows checkout's Git Bash takes seconds to start
        it. -> (rc, [(seconds after the first line, obj)], stderr)"""
        p = self.popen("worker watch " + args, **env)
        t0 = time.time()
        th = None
        lines = []
        for raw in p.stdout:
            if not lines:
                t0 = time.time()

                def writer():
                    for at, st in steps:
                        time.sleep(max(0, t0 + at - time.time()))
                        self.put(st)
                th = threading.Thread(target=writer)
                th.start()
            lines.append((time.time() - t0, json.loads(raw)))
            if time.time() - t0 > timeout:
                p.kill()
                break
        p.wait(timeout)
        if th:
            th.join()
        err = p.stderr.read()
        p.stdout.close()
        p.stderr.close()
        return p.returncode, lines, err

    def squeues(self):
        return [c for c in self.g.calls() if c.startswith("squeue")]

    def put(self, st):
        """status.json as the job writes it: whole, through a temporary name and a rename"""
        p = os.path.join(self.g.rundir(), "status.json")
        with open(p + ".tmp", "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(st) + "\n")
        os.replace(p + ".tmp", p)


class Lines(Base):
    def test_queued_then_starting_then_online(self):
        self.put(self.queued())
        online = self.queued(state="online", node="asx15", needs="nothing", environment_url="https://claude.ai/code?environment=env_01X",
                             online_at=iso(), message="online")
        rc, lines, err = self.watch(steps=[(3.5, self.queued(state="starting", node="asx15", message="connecting")), (7.5, online)])
        self.assertEqual(rc, 0, err)
        objs = [o for _, o in lines]
        status = [o for o in objs if o["event"] == "status"]
        for o in status:
            self.assertEqual(list(o.keys()), STATUS_KEYS, o)
            self.assertEqual(o["v"], 1)
        self.assertEqual([o["status"]["state"] for o in status], ["queued", "starting", "online"])
        self.assertEqual([o["final"] for o in status], [False, False, True])
        self.assertEqual(status[0]["line"], "Your worker is in line for a computer (0 min so far).")
        self.assertRegex(status[-1]["line"], r"^Your worker is online( \(ready \d+ min after you asked\))?\.$")
        # the one scheduler call while in line went into the queued file and onto the first line
        self.assertEqual(status[0]["scheduler"]["state"], "PENDING")
        self.assertEqual(len(self.squeues()), 1, self.g.calls())
        # keepalives in the quiet stretches, about 2 s apart (a Windows checkout's Git Bash takes seconds per
        # look, so the timing is held to only where the watch runs: Linux)
        kas = [t for t, o in lines if o["event"] == "keepalive"]
        self.assertGreaterEqual(len(kas), 1 if os.name == "nt" else 2, lines)
        for t, o in lines:
            if o["event"] == "keepalive":
                self.assertRegex(o["at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        if os.name != "nt":
            gaps = [b - a for (a, _), (b, _) in zip(lines, lines[1:])]
            self.assertLess(max(gaps), 4.5, gaps)
        self.assertEqual(objs[-1]["event"], "status", "the last line is the final status")

    def test_a_heartbeat_alone_is_no_change(self):
        st = self.queued(state="running", node="asx15", message="connecting", updated_at=iso())
        self.put(st)
        # two heartbeats that change only the time and fields no reader acts on, then the end
        rc, lines, err = self.watch(steps=[(1.5, dict(st, updated_at=iso(time.time() + 1), rc_alive=True)),
                                           (3.0, dict(st, updated_at=iso(time.time() + 2), restarts=0)),
                                           (4.5, dict(st, state="stopped", stop_reason="request"))])
        self.assertEqual(rc, 1, err)
        status = [o for _, o in lines if o["event"] == "status"]
        self.assertEqual([(o["status"]["state"], o["final"]) for o in status], [("running", False), ("stopped", True)])
        self.assertGreaterEqual(len([o for _, o in lines if o["event"] == "keepalive"]), 1, lines)

    def test_waiting_for_the_sign_in_goes_on(self):
        self.put(self.queued(state="need_login", node="asx15", needs="login", message="sign in"))
        online = self.queued(state="online", node="asx15", environment_url="https://claude.ai/code?environment=env_01X")
        rc, lines, err = self.watch(steps=[(3, online)])
        self.assertEqual(rc, 0, err)
        status = [o for _, o in lines if o["event"] == "status"]
        self.assertEqual([(o["status"]["state"], o["status"]["needs"], o["final"]) for o in status],
                         [("need_login", "login", False), ("online", "nothing", True)])
        self.assertEqual(self.squeues(), [], "nothing asked of the scheduler once the job has a computer")

    def test_online_without_its_link_is_not_the_end(self):
        self.put(self.queued(state="online", node="asx15"))
        rc, lines, err = self.watch(steps=[(2.5, self.queued(state="online", node="asx15", environment_url="https://claude.ai/code?environment=env_01X"))])
        self.assertEqual(rc, 0)
        self.assertEqual([o["final"] for _, o in lines if o["event"] == "status"], [False, True])


class Ends(Base):
    def one(self, st, want_rc, **env):
        self.put(st)
        rc, lines, err = self.watch(**env)
        self.assertEqual(rc, want_rc, err)
        self.assertEqual(len(lines), 1, lines)
        o = lines[0][1]
        self.assertEqual((o["event"], o["final"]), ("status", True))
        return o

    def test_stopped(self):
        o = self.one(self.queued(state="stopped", node="asx15", stop_reason="request"), 1)
        self.assertEqual(o["line"], "Your worker is stopped.")

    def test_error(self):
        o = self.one(self.queued(state="error", message="the grid ended the request before it started"), 1)
        self.assertEqual(o["line"], "Your worker couldn't start: the grid ended the request before it started.")

    def test_ended_with_no_successor(self):
        self.one(self.queued(state="preempted", node="asx15"), 1)

    def test_renewing_is_not_the_end(self):
        # the successor in line (framework 13 asks the scheduler about it)
        self.g.jobs(["40501300|PENDING|Dependency|N/A|"])
        self.put(self.queued(state="preempted", node="asx15", next_job="40501300"))
        rc, lines, err = self.watch("--name worker --json --minutes 0")
        self.assertEqual(rc, 2, "out of time, not ended")
        self.assertEqual(self.squeues(), ["squeue -h -j 40501234,40501300 -o %i|%T|%N"], "the job and its successor, in one call")
        self.assertEqual(lines[-1][1]["status"]["state"], "preempted")

    def test_a_successor_that_is_gone_ends_it_stopped(self):
        # framework 13: the successor was cancelled on its own (2026-10-02); the watch ends on "stopped"
        self.g.jobs([])
        o = self.one(self.queued(state="preempted", node="asx15", next_job="40501300",
                                 claude_login={"loggedIn": True, "email": "st1234@wayne.edu", "subscriptionType": "max", "checked_at": iso()}), 1)
        self.assertEqual((o["status"]["state"], o["status"]["stop_reason"], o["status"]["next_job"]), ("stopped", "successor_gone", ""))
        self.assertEqual(o["status"]["claude_login"]["email"], "st1234@wayne.edu", "the job's own fields kept")
        self.assertEqual(o["scheduler"]["state"], "GONE")
        self.assertEqual(o["line"], "Your worker stopped: the next job in the chain was cancelled or never started. hpcworker connect starts it again.")
        self.assertEqual(self.squeues(), ["squeue -h -j 40501234,40501300 -o %i|%T|%N"], "the job and its successor, once")

    def test_a_job_listed_again_is_not_the_end(self):
        # framework 13: a job preempted under --qos=requeue is listed again under its own id: the watch goes on, its
        # successor gone or not, and the record is left as the job wrote it
        self.g.jobs(["40501234|PENDING|BeginTime|N/A|"])
        self.put(self.queued(state="preempted", node="asx15", next_job="40501300"))
        rc, lines, err = self.watch("--name worker --json --minutes 0")
        self.assertEqual(rc, 2, "out of time, not ended")
        self.assertEqual(self.squeues(), ["squeue -h -j 40501234,40501300 -o %i|%T|%N"])
        self.assertEqual((lines[-1][1]["status"]["state"], lines[-1][1]["status"]["next_job"]), ("preempted", "40501300"))

    def test_the_successor_is_not_asked_within_the_floor(self):
        self.g.jobs([])
        self.put(self.queued(state="preempted", node="asx15", next_job="40501300", checked_at=iso(time.time() - 10), scheduler_state="PENDING"))
        rc, lines, err = self.watch("--name worker --json --minutes 0 --poll-floor 60")
        self.assertEqual(rc, 2, err)
        self.assertEqual(self.squeues(), [])
        self.assertEqual(lines[-1][1]["status"]["state"], "preempted")

    def test_the_grid_dropped_the_request(self):
        # the scheduler no longer lists the job: status_refresh writes the error, and the watch ends on it
        self.g.jobs([])
        o = self.one(self.queued(), 1)
        self.assertEqual(o["status"]["state"], "error")
        self.assertEqual(o["scheduler"]["state"], "GONE")

    def test_out_of_time(self):
        o = self.one(self.queued(), 2, args="--name worker --json --minutes 0")
        self.assertEqual(o["status"]["state"], "queued")

    def test_no_such_worker(self):
        p = self.popen("worker watch --name nosuch --json")
        out, err = p.communicate(timeout=60)
        self.assertEqual((p.returncode, out), (1, ""))
        self.assertIn("no worker named nosuch", err)


class Scheduler(Base):
    def test_floor(self):
        # the gate's floor: asked 10 s ago by someone else, so not asked now
        self.put(self.queued(checked_at=iso(time.time() - 10), scheduler_state="PENDING", reason="Priority"))
        rc, lines, err = self.watch("--name worker --json --minutes 0 --poll-floor 60")
        self.assertEqual(rc, 2, err)
        self.assertEqual(self.squeues(), [])
        self.assertIsNone(lines[0][1]["scheduler"])
        # without the floor it asks, once
        rc, lines, err = self.watch("--name worker --json --minutes 0")
        self.assertEqual(len(self.squeues()), 1)
        # and status --json with the floor, likewise
        self.put(self.queued(checked_at=iso(time.time() - 10)))
        n = len(self.squeues())
        rc, out, err = self.g.run("worker status --name worker --json --poll-floor 60")
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(self.squeues()), n)
        self.assertIsNone(json.loads(out)["scheduler"])
        rc, out, err = self.g.run("worker status --name worker --json --poll-floor x")
        self.assertNotEqual(rc, 0)

    def test_text_watch_unchanged(self):
        # without --json the watch is framework 10's, for a person at a terminal
        self.put(self.queued(state="online", node="asx15", environment_url="https://claude.ai/code?environment=env_01X", title="Wayne State grid"))
        rc, out, err = self.g.run("worker watch --name worker --minutes 1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.splitlines()[-1], "Open in Claude: https://claude.ai/code?environment=env_01X  Look for Wayne State grid.")


@unittest.skipIf(os.name == "nt", "closes a pipe under a running process and reads /proc (Linux)")
class ReaderGone(Base):
    def test_the_watch_ends_when_its_reader_goes(self):
        self.put(self.queued(state="running", node="asx15"))
        slot = os.path.join(self.tmp.name, "watch.1")
        os.makedirs(slot)
        p = self.popen("worker watch --name worker --json --minutes 5", HPCW_GATE_SLOT=slot)
        first = p.stdout.readline()
        self.assertIn('"event":"status"', first)
        t0 = time.time()
        p.stdout.close()   # the ssh channel is gone
        p.wait(20)
        p.stderr.close()
        self.assertLess(time.time() - t0, 6, "ended within a keepalive and a look")
        self.assertFalse(os.path.exists(slot), "the gate's watch slot is given back")

    def test_a_hang_up_gives_the_slot_back(self):
        import signal
        self.put(self.queued(state="running", node="asx15"))
        slot = os.path.join(self.tmp.name, "watch.2")
        os.makedirs(slot)
        p = self.popen("worker watch --name worker --json --minutes 5", HPCW_GATE_SLOT=slot)
        p.stdout.readline()
        p.send_signal(signal.SIGHUP)
        p.wait(20)
        p.stdout.close()
        p.stderr.close()
        self.assertFalse(os.path.exists(slot))


if __name__ == "__main__":
    unittest.main()
