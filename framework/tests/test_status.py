"""Framework 10's status side, against a scratch account and the fake scheduler of fakegrid.py: the
queued status.json `worker start` writes (keys, values, order, the node file, progress.log and its
trim), `worker status` with its one scheduler call while queued (the reason, the estimate, a job that
got its computer, a job the grid dropped, a scheduler that did not answer), the person-facing line for
every state, `--json` and `--details`, `worker stop` of a worker still in line, `worker restrict`,
`claude consent --record`, `worker watch`, and what the 10.0.0 extension and a framework 9 worker
still find (V11_CONTRACT.md section 19)."""
import json
import os
import re
import time
import unittest
from datetime import datetime, timedelta, timezone

import fakegrid as G

ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


def iso(seconds_from_now=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds_from_now)).strftime("%Y-%m-%dT%H:%M:%SZ")


def local(seconds_from_now=0):
    """a time as Slurm prints it: local, no zone"""
    return datetime.fromtimestamp(time.time() + seconds_from_now).strftime("%Y-%m-%dT%H:%M:%S")


class Base(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.g.setup()

    def tearDown(self):
        self.tmp.cleanup()

    def start(self, args=""):
        rc, out, err = self.g.run("worker start " + args)
        self.assertEqual(rc, 0, (out, err))
        return out

    def status_json(self):
        rc, out, err = self.g.run("worker status --json")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(len(out.strip().splitlines()), 1, "one JSON object on one line")
        return json.loads(out)

    def line(self):
        rc, out, err = self.g.run("worker status")
        self.assertEqual(rc, 0, (out, err))
        return out.splitlines()[0]


class QueuedFile(Base):
    def test_keys_values_and_order(self):
        rd = self.g.rundir()
        os.makedirs(rd)
        with open(os.path.join(rd, "node"), "w") as fh:
            fh.write("node99\n")  # the last job's node file goes before the next one is asked for
        before = time.time()
        out = self.start()
        self.assertIn("worker worker submitted as job 40501234", out, "the sentence the 10.0.0 extension reads")
        with open(os.path.join(rd, "status.json"), encoding="utf-8") as fh:
            raw = fh.read()
        s = json.loads(raw)
        self.assertEqual(list(s), ["version", "site", "run", "job", "node", "state", "message", "needs", "hint", "submitted_at", "updated_at", "title",
                                   "requested_name", "renewal", "chain", "next_job", "consent", "consent_source", "scheduler_state", "reason",
                                   "expected_start", "checked_at"], "the contract's order")
        self.assertEqual((s["version"], s["site"], s["run"], s["job"], s["node"], s["state"]), (int(G.CURRENT_VERSION), "testsite", "worker", "40501234", "", "queued"))
        self.assertEqual((s["message"], s["needs"], s["hint"]), ("waiting for a computer", "nothing", "Your worker is in line for a computer."))
        self.assertRegex(s["submitted_at"], ISO)
        self.assertLessEqual(abs(datetime.strptime(s["submitted_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp() - before), 30)
        self.assertEqual(s["updated_at"], s["submitted_at"])
        self.assertEqual((s["title"], s["requested_name"], s["renewal"], s["chain"], s["next_job"]), ("Wayne State grid", "Wayne State grid", False, True, ""))
        self.assertEqual((s["consent"], s["consent_source"]), (False, "none"))
        self.assertEqual([s[k] for k in ("scheduler_state", "reason", "expected_start", "checked_at")], ["", "", "", ""])
        self.assertFalse(os.path.exists(os.path.join(rd, "node")))
        self.assertTrue(raw.endswith("}\n") and raw.count("\n") == 1, "one line")
        prog = self.g.progress()
        self.assertEqual(len(prog), 1)
        self.assertRegex(prog[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ Asked the grid for a computer$")
        self.assertEqual([c.split()[0] for c in self.g.calls()], ["sbatch"], "no squeue: there was no job on record")

    def test_title_for_another_name_and_consent_marker(self):
        with open(os.path.join(self.g.hpcw, "consent"), "w") as fh:
            fh.write("yes\n")
        self.start("--name gpu --no-chain")
        s = self.g.status("gpu")
        self.assertEqual(s["title"], "Wayne State grid \u00b7 gpu")
        self.assertEqual((s["chain"], s["consent"], s["consent_source"]), (False, True, "marker"))

    def test_progress_log_is_trimmed_to_400(self):
        rd = self.g.rundir()
        os.makedirs(rd)
        with open(os.path.join(rd, "progress.log"), "w", newline="\n") as fh:
            for i in range(450):
                fh.write("2026-09-30T00:00:%02dZ Got a computer %d\n" % (i % 60, i))
        self.start()
        prog = self.g.progress()
        self.assertEqual(len(prog), 400)
        self.assertTrue(prog[0].endswith("Got a computer 51"), prog[0])
        self.assertTrue(prog[-1].endswith(" Asked the grid for a computer"))

    def test_second_start_keeps_the_job_and_says_so(self):
        self.start()
        out = self.start()
        self.assertEqual(out.strip(), "worker worker already has job 40501234 (PENDING); nothing submitted", "the 10.0.0 extension's sentence")
        self.assertEqual([c.split()[0] for c in self.g.calls()], ["sbatch", "squeue"], "one squeue, nothing submitted twice")
        self.assertEqual(len(self.g.progress()), 1)


class SchedulerCall(Base):
    def setUp(self):
        super().setUp()
        self.start()
        self.calls0 = len(self.g.calls())

    def set_job(self, line):
        self.g.jobs([line])

    def test_in_line_with_a_future_estimate(self):
        self.set_job("40501234|PENDING|Priority|%s|" % local(3600))
        j = self.status_json()
        self.assertEqual(self.g.calls()[self.calls0:], ["squeue -h -j 40501234 -o %T|%r|%S|%N"], "ONE squeue")
        self.assertEqual(list(j), ["v", "run", "job", "next_job", "state_dir", "status", "connection", "scheduler", "line"])
        self.assertEqual((j["v"], j["run"], j["job"], j["next_job"], j["connection"]), (1, "worker", "40501234", "", None))
        self.assertEqual(j["state_dir"].replace("\\", "/"), G.posix(self.g.state))
        sch = j["scheduler"]
        self.assertEqual((sch["state"], sch["reason"], sch["node"]), ("PENDING", "Priority", ""))
        self.assertRegex(sch["expected_start"], ISO)
        exp = datetime.strptime(sch["expected_start"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        self.assertLess(abs(exp - (time.time() + 3600)), 120, "local Slurm time read as local, written as UTC")
        st = j["status"]
        self.assertEqual((st["state"], st["scheduler_state"], st["reason"], st["expected_start"]), ("queued", "PENDING", "Priority", sch["expected_start"]))
        self.assertEqual(st["checked_at"], sch["checked_at"])
        self.assertNotIn("got_computer_at", st)
        self.assertEqual(st, self.g.status(), "status.json itself was updated")
        self.assertEqual(j["line"], "Your worker is in line for a computer (0 min so far).")

    def test_estimates_that_do_not_count(self):
        for start in ("N/A", "Unknown", local(-600)):
            self.set_job("40501234|PENDING|Resources|%s|" % start)
            j = self.status_json()
            self.assertEqual(j["scheduler"]["expected_start"], "", start)
            self.assertEqual(j["status"]["expected_start"], "", start)

    def test_got_a_computer(self):
        self.set_job("40501234|RUNNING|None|%s|node07" % local(-5))
        j = self.status_json()
        st = j["status"]
        self.assertEqual((j["scheduler"]["state"], j["scheduler"]["node"]), ("RUNNING", "node07"))
        self.assertEqual(st["state"], "queued", "the job's own first write moves it on")
        self.assertEqual(st["got_computer_at"], st["checked_at"])
        got = st["got_computer_at"]
        time.sleep(1.1)
        self.status_json()
        self.assertEqual(self.g.status()["got_computer_at"], got, "set once")

    def test_the_grid_dropped_the_request(self):
        self.g.jobs([])
        j = self.status_json()
        self.assertEqual((j["scheduler"]["state"], j["scheduler"]["reason"], j["scheduler"]["expected_start"], j["scheduler"]["node"]), ("GONE", "", "", ""))
        st = self.g.status()
        self.assertEqual((st["state"], st["message"], st["needs"], st["scheduler_state"]), ("error", "the grid ended the request before it started", "nothing", "GONE"))
        self.assertEqual(st["submitted_at"], j["status"]["submitted_at"])
        self.assertEqual(j["line"], "Your worker couldn't start: the grid ended the request before it started.")
        self.assertTrue(self.g.progress()[-1].endswith(" Couldn't start: the grid ended the request before it started"))
        # no longer queued: nothing more is asked
        n = len(self.g.calls())
        j = self.status_json()
        self.assertIsNone(j["scheduler"])
        self.assertEqual(len(self.g.calls()), n)
        self.assertEqual(len([l for l in self.g.progress() if "Couldn't start" in l]), 1)

    def test_a_scheduler_that_did_not_answer_changes_nothing(self):
        self.set_job("40501234|PENDING|Priority|N/A|")
        before = self.g.status()
        open(os.path.join(self.g.sched, "squeue_fail"), "w").close()
        j = self.status_json()
        self.assertIsNone(j["scheduler"])
        self.assertEqual(self.g.status(), before)
        self.assertEqual(j["line"], "Your worker is in line for a computer (0 min so far).")

    def test_no_call_once_the_job_has_a_computer(self):
        self.set_job("40501234|RUNNING|None|N/A|node07")
        with open(os.path.join(self.g.rundir(), "node"), "w") as fh:
            fh.write("node07\n")
        j = self.status_json()
        self.assertIsNone(j["scheduler"])
        self.assertEqual(self.g.calls()[self.calls0:], [], "the job's own files say where it is")
        self.assertEqual(j["status"]["scheduler_state"], "", "worker status never writes once the node file exists")


class Lines(Base):
    """the person-facing line for each state (V11_CONTRACT.md 6), from a status.json written here"""

    def put(self, **fields):
        base = {"version": 10, "run": "worker", "job": "40501234", "node": "node07"}
        base.update(fields)
        rd = self.g.rundir()
        os.makedirs(rd, exist_ok=True)
        with open(os.path.join(rd, "job.id"), "w") as fh:
            fh.write("40501234\n")
        # a worker in line is one the scheduler still lists (else worker status reads it as dropped)
        self.g.jobs(["40501234|PENDING|Priority|N/A|"] if base.get("state") == "queued" else [])
        self.g.write_status(base)

    def test_each_state(self):
        cases = [
            (dict(state="queued", node="", submitted_at=iso(-6 * 60 - 5)), "Your worker is in line for a computer (6 min so far)."),
            (dict(state="starting"), "Your worker has a computer and is connecting to Claude."),
            (dict(state="running"), "Your worker has a computer and is connecting to Claude."),
            (dict(state="need_consent"), "Your worker has a computer and is connecting to Claude."),
            (dict(state="online", renewal=False, submitted_at=iso(-600), online_at=iso(-600 + 7 * 60 + 10), environment_url="https://claude.ai/code?environment=env_01X"),
             "Your worker is online (ready 7 min after you asked)."),
            (dict(state="online", renewal=True, submitted_at=iso(-30000), online_at=iso(-60)), "Your worker is online."),
            (dict(state="online"), "Your worker is online."),
            (dict(state="need_login"), "Your worker is waiting for your Claude sign-in."),
            (dict(state="preempted", next_job="40501300"), "Your worker is renewing itself; it is back in a few minutes."),
            (dict(state="preempted", next_job=""), "Your worker has ended. hpcworker connect starts it again."),
            (dict(state="stopped", stop_reason="login_abandoned"), "Your worker stopped: waiting for your Claude sign-in timed out."),
            (dict(state="stopped", stop_reason="request"), "Your worker is stopped."),
            (dict(state="stopped"), "Your worker is stopped."),
            (dict(state="error", message="image /x is not readable"), "Your worker couldn't start: image /x is not readable."),
        ]
        for fields, want in cases:
            self.put(**fields)
            self.assertEqual(self.line(), want, fields)
            self.assertEqual(self.status_json()["line"], want, fields)

    def test_no_status_yet(self):
        os.makedirs(self.g.rundir())
        with open(os.path.join(self.g.rundir(), "job.id"), "w") as fh:
            fh.write("40501234\n")
        self.g.jobs(["40501234|PENDING|Priority|N/A|"])
        j = self.status_json()
        self.assertEqual(j["line"], "Your worker has been asked for and has not reported yet.")
        self.assertIsNone(j["status"], "nothing is written for a job still in line without a queued file")
        self.assertEqual(j["scheduler"]["state"], "PENDING")

    def test_online_link_and_details(self):
        self.put(state="online", title="Wayne State grid", environment_url="https://claude.ai/code?environment=env_01X", session_name="asx1-a-b",
                 submitted_at=iso(-300), online_at=iso(-120), updated_at=iso())
        rc, out, err = self.g.run("worker status")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.splitlines(), ["Your worker is online (ready 3 min after you asked).", "Open in Claude: https://claude.ai/code?environment=env_01X  Look for Wayne State grid."])
        rc, out, err = self.g.run("worker status --details")
        self.assertEqual(rc, 0, err)
        lines = out.splitlines()
        self.assertEqual(lines[0], "Your worker is online (ready 3 min after you asked).")
        self.assertTrue(any(l.startswith("worker worker: online (job 40501234 on node07; heartbeat ") for l in lines), lines)
        self.assertIn("  session: asx1-a-b   open in Claude: https://claude.ai/code?environment=env_01X", lines)


class StopInLine(Base):
    def test_stop_of_a_worker_still_in_line(self):
        self.start()
        t0 = time.time()
        rc, out, err = self.g.run("worker stop")
        self.assertEqual(rc, 0, (out, err))
        self.assertLess(time.time() - t0, 30, "no 45 s wait for a job that never ran")
        self.assertEqual(out.strip(), "worker worker: stopped (it was still in line for a computer; cancelled at the scheduler: 40501234; the chain ended)")
        self.assertRegex(out, r"^worker \S+: stopped \(", "the 10.0.0 extension's test of success")
        s = self.g.status()
        self.assertEqual((s["state"], s["stop_reason"], s["needs"], s["submitted_at"] != ""), ("stopped", "request", "nothing", True))
        self.assertTrue(self.g.progress()[-1].endswith(" Stopped"))
        self.assertIn("scancel 40501234", self.g.calls())
        # a second stop is a no-op
        rc, out, err = self.g.run("worker stop")
        self.assertIn("it had stopped before", out)
        self.assertEqual(len([l for l in self.g.progress() if l.endswith(" Stopped")]), 1)
        # and a start begins afresh
        out = self.start()
        self.assertIn("submitted as job 40501235", out)
        self.assertEqual(self.g.status()["state"], "queued")

    def test_a_job_that_reached_its_computer_writes_its_own_stop(self):
        self.start()
        with open(os.path.join(self.g.rundir(), "node"), "w") as fh:
            fh.write("node07\n")
        self.g.jobs(["40501234|RUNNING|None|N/A|node07"])
        rc, out, err = self.g.source("HPCW_STOP_WAIT_S=1 HPCW_STOP_POLL_S=1 stop_worker_run '%s' worker" % G.posix(self.g.rundir()))
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("no word from job 40501234 within 1s", out)
        self.assertEqual(self.g.status()["state"], "queued", "not this command's to write once the job has a computer")


class Restrict(Base):
    def test_marker(self):
        rc, out, err = self.g.run("worker restrict --name gpu")
        m = os.path.join(self.g.state, "workspaces", "gpu", ".restricted")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip().replace("\\", "/"), "worker gpu: marked restricted (%s); it will not start there until the marker is removed" % G.posix(m))
        self.assertRegex(out, r"^worker \S+: (already )?marked restricted", "the extension's test")
        with open(m) as fh:
            self.assertRegex(fh.read(), r"^restricted \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ by hpcworker worker restrict\n$")
        if os.name != "nt":
            self.assertEqual(os.stat(m).st_mode & 0o777, 0o644)
        rc, out, err = self.g.run("worker restrict --name gpu")
        self.assertEqual((rc, out.strip().replace("\\", "/")), (0, "worker gpu: already marked restricted (%s)" % G.posix(m)))
        self.assertEqual(self.g.calls(), [], "no scheduler call")
        rc, out, err = self.g.run("connect --profile testsite --name gpu --login never")
        self.assertEqual(rc, 4, out)


class ConsentRecord(unittest.TestCase):
    def test_record(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            g = G.Grid(td)  # not set up: --record needs no profile
            rc, out, err = g.run("claude consent --record %s" % G.INSTALL_ID)
            self.assertEqual(rc, 0, (out, err))
            f = os.path.join(g.hpcw, "consent")
            self.assertEqual(out.strip(), "recorded in %s (fallback marker): your workers may now host Remote Control" % G.posix(f))
            with open(f) as fh:
                self.assertRegex(fh.read(), r"^yes \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ %s\n$" % G.INSTALL_ID)
            if os.name != "nt":
                self.assertEqual(os.stat(f).st_mode & 0o777, 0o600)
            for bad in ("", "XYZ", G.INSTALL_ID.upper(), G.INSTALL_ID + "0"):
                rc, out, err = g.run("claude consent --record '%s'" % bad)
                self.assertEqual((rc, err.strip()), (2, "hpcworker: claude consent --record needs this installation's 32-character id"), bad)


class Watch(Base):
    def test_online_ends_with_the_link(self):
        self.start()
        rd = self.g.rundir()
        with open(os.path.join(rd, "progress.log"), "a", newline="\n") as fh:
            fh.write("%s Got a computer\n%s Online: https://claude.ai/code?environment=env_01X\n" % (iso(-60), iso(-5)))
        s = self.g.status()
        s.update(state="online", online_at=iso(-5), environment_url="https://claude.ai/code?environment=env_01X", node="node07")
        self.g.write_status(s)
        rc, out, err = self.g.run("worker watch")
        self.assertEqual(rc, 0, (out, err))
        lines = out.splitlines()
        self.assertEqual(lines[-1], "Open in Claude: https://claude.ai/code?environment=env_01X  Look for Wayne State grid.")
        self.assertTrue(lines[-2].startswith("Your worker is online"), lines)

    def test_start_wait_follows_the_line_and_runs_out_of_time(self):
        rc, out, err = self.g.run("worker start --wait 0")
        self.assertEqual(rc, 0, ("--wait 0 does not wait", out, err))
        rc, out, err = self.g.run("worker watch --minutes 0", HPCW_WATCH_POLL_S="0")
        self.assertEqual(rc, 2, (out, err))
        lines = out.splitlines()
        self.assertEqual(lines[0], "Your worker is in line for a computer (0 min so far).")
        self.assertIn("(still not online after 0 min; hpcworker worker watch --name worker follows it again)", lines)
        self.assertEqual(len([c for c in self.g.calls() if c.startswith("squeue")]), 1, "the scheduler once, not in a loop")

    def test_need_login_and_stopped_end_it(self):
        self.start()
        s = self.g.status()
        s.update(state="need_login", node="n")
        self.g.write_status(s)
        rc, out, err = self.g.run("worker watch")
        self.assertEqual(rc, 3, (out, err))
        self.assertIn("hpcworker claude login", out)
        s.update(state="stopped", stop_reason="login_abandoned")
        self.g.write_status(s)
        rc, out, err = self.g.run("worker watch")
        self.assertEqual(rc, 1, (out, err))
        self.assertEqual(out.splitlines()[-1], "Your worker stopped: waiting for your Claude sign-in timed out.")


class Framework9Compat(Base):
    """What the 10.0.0 extension and a worker started by framework 9 still find (V11_CONTRACT.md 19)."""

    F9 = {"version": 9, "site": "wayne", "run": "worker", "job": "40500019", "node": "asx15", "pid": 123, "state": "online", "message": "Open in Claude",
          "needs": "nothing", "hint": "Your worker is online: open it in Claude.", "started_at": "2026-10-01T08:00:00Z", "updated_at": "2026-10-01T08:30:00Z",
          "session_name": "wayne-40500019", "requested_name": "wayne-worker", "session_url": "https://claude.ai/code?environment=env_01A",
          "environment_url": "https://claude.ai/code?environment=env_01A", "environment_id": "env_01A",
          "claude_login": {"loggedIn": True, "email": "go2432@wayne.edu", "subscriptionType": "max", "checked_at": "2026-10-01T08:30:00Z"},
          "consent": True, "consent_source": "claude_config", "workspace_trusted": True, "rc_alive": True, "resumed": False, "tmux": True, "restarts": 0,
          "chain": True, "next_job": "40500052", "chain_note": "successor 40500052 queued", "scheduler_in_worker": True, "scheduler_note": "ok",
          "workspace": "/x", "rc_log": "/x/rc.log", "token_path": "/x/job.token"}

    def test_a_framework_9_status_is_read(self):
        rd = self.g.rundir()
        os.makedirs(rd)
        with open(os.path.join(rd, "job.id"), "w") as fh:
            fh.write("40500019\n")
        with open(os.path.join(rd, "next.id"), "w") as fh:
            fh.write("40500052 40500019\n")
        self.g.write_status(self.F9)
        with open(os.path.join(rd, "connection.json"), "w") as fh:
            json.dump({"session_name": "wayne-40500019", "environment_url": "https://claude.ai/code?environment=env_01A", "job": "40500019"}, fh)
        j = self.status_json()
        self.assertEqual((j["run"], j["job"], j["next_job"]), ("worker", "40500019", "40500052"), "framework 9's --json fields")
        self.assertEqual(j["status"], self.F9, "read as written, nothing added")
        self.assertEqual(j["connection"]["session_name"], "wayne-40500019")
        self.assertIsNone(j["scheduler"])
        self.assertEqual(j["line"], "Your worker is online.", "no submitted_at: no wait to report")
        self.assertEqual(self.g.calls(), [], "no scheduler call for a worker that is not in line")
        lines = self.g.run("worker status")[1].splitlines()
        self.assertEqual(lines[:2], ["Your worker is online.", "Open in Claude: https://claude.ai/code?environment=env_01A  Look for Wayne State grid."])
        self.assertTrue(any(l.startswith("worker worker: online (job 40500019 on asx15") for l in self.g.run("worker status --details")[1].splitlines()))
        # 10.0.0's automatic start at most once a minute: nothing submitted while the framework 9 job runs
        self.g.jobs(["40500019|RUNNING|None|N/A|asx15", "40500052|PENDING|Dependency|N/A|"])
        out = self.start()
        self.assertEqual(out.strip().splitlines()[-1], "worker worker already has job 40500019 (RUNNING on asx15); nothing submitted")
        self.assertEqual(self.g.status(), self.F9, "worker start leaves a live worker's status alone")

    def test_plain_sitting_is_framework_9s(self):
        # `claude login --plain` (10.0.0's line): no keepalive, no framework 10 flag, and the 15-minute shortcut kept
        rc, out, err = self.g.run("claude login --plain", stdin_text=G.CODE + "\n", HPCW_KEEPALIVE_S="1", FAKE_SRUN_DELAY="2.5")
        self.assertEqual(rc, 0, (out, err))
        self.assertNotIn("still waiting", out)
        self.assertNotIn("HPCW-STEP", out)
        srun = [c for c in self.g.calls() if c.startswith("srun ")]
        self.assertEqual(len(srun), 1)
        self.assertTrue(srun[0].endswith("_exec login --plain"), srun[0])
        self.assertEqual(out.splitlines()[-1], "SIGNED-IN st1234@wayne.edu max")
        self.g.write_status(self.F9)
        rc, out, err = self.g.run("claude login --plain")
        self.assertEqual(rc, 0, (out, err))
        self.assertTrue(out.splitlines()[0].startswith("HPCW-LOGIN: already signed in (a worker confirmed it "), out)
        self.assertEqual(out.splitlines()[1], "SIGNED-IN go2432@wayne.edu max")
        self.assertEqual(len([c for c in self.g.calls() if c.startswith("srun ")]), 1, "no allocation for the shortcut")

    def test_marker_of_any_content_and_the_stop_file(self):
        # 10.0.0 writes the consent marker and the stop file through Files; both still count
        with open(os.path.join(self.g.hpcw, "consent"), "w") as fh:
            fh.write("yes 2026-09-29T05:13:00Z install-7f3a\n")
        rc, out, err = self.g.source("load_profile; consent_source")
        self.assertEqual(out.strip(), "marker")
        rd = self.g.rundir()
        os.makedirs(rd)
        with open(os.path.join(rd, "job.id"), "w") as fh:
            fh.write("40500019\n")
        self.g.write_status(self.F9)
        rc, out, err = self.g.source("HPCW_STOP_WAIT_S=1 HPCW_STOP_POLL_S=1 stop_worker_run '%s' worker" % G.posix(rd))
        self.assertTrue(os.path.exists(os.path.join(rd, "stop")), "the stop file is the job's signal, as before")
        self.assertRegex(out, r"^worker worker: stopped \(no word from job 40500019 within 1s")

    def test_version_says_10(self):
        rc, out, err = self.g.run("version")
        self.assertEqual(out.strip(), "%s (shared copy at %s)" % (G.CURRENT_VERSION, self.g.shared_spelled))
        self.assertEqual(G.CURRENT_VERSION, "10")


if __name__ == "__main__":
    unittest.main()
