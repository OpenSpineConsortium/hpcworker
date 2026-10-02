"""Framework 10 after its review (2026-10-01): what must never happen when the scheduler, the student or
another start misbehaves. A scheduler that does not answer is never read as "no job alive" (worker start
and connect submit nothing beside a worker that may still be in line); two starts at once submit one
job; a state word the tool does not know is never read as a job that ended; a worker whose job stopped
writing says so on its first line; a worker still in line is cancelled even when the scheduler cannot be
asked; and the one-time grid key is hidden from Claude Code inside the worker's container. Against the
fake scheduler of fakegrid.py; nothing reaches a real scheduler."""
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone

import fakegrid as G


def iso(seconds_from_now=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds_from_now)).strftime("%Y-%m-%dT%H:%M:%SZ")


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.g.setup()

    def tearDown(self):
        self.tmp.cleanup()

    def sbatches(self):
        return [c for c in self.g.calls() if c.startswith("sbatch ")]

    def scheduler_down(self, down=True):
        p = os.path.join(self.g.sched, "squeue_fail")
        if down:
            open(p, "w").close()
        elif os.path.exists(p):
            os.remove(p)


class SchedulerSilent(Base):
    def test_worker_start_submits_nothing_when_squeue_fails(self):
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("submitted as job 40501234", out)
        self.scheduler_down()
        rc, out, err = self.g.run("worker start")
        self.assertNotEqual(rc, 0, (out, err))
        self.assertIn("the scheduler did not answer", err)
        self.assertIn("nothing was submitted", err)
        self.assertEqual(len(self.sbatches()), 1, "no second worker beside one still in line")
        with open(os.path.join(self.g.rundir(), "job.id")) as fh:
            self.assertEqual(fh.read().strip(), "40501234", "job.id unchanged")
        self.assertFalse(os.path.exists(os.path.join(self.g.rundir(), ".start.lock")), "the lock is let go")

    def test_connect_says_refused_and_exits_5(self):
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.scheduler_down()
        rc, out, err = self.g.run("connect --name worker --login never")
        self.assertEqual(rc, 5, (out, err))
        self.assertEqual(out.strip().splitlines()[-1], "HPCW-STEP failed refused the scheduler did not answer, so nothing was submitted; try again in a minute")
        self.assertEqual(len(self.sbatches()), 1)

    def test_stop_of_a_worker_in_line_cancels_even_when_squeue_fails(self):
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.scheduler_down()
        rc, out, err = self.g.run("worker stop")
        self.assertEqual(rc, 0, (out, err))
        self.assertRegex(out, r"^worker worker: stopped \(it was still in line for a computer; cancelled at the scheduler: 40501234;")
        self.assertIn("scancel 40501234", self.g.calls())
        self.assertEqual(self.g.status()["state"], "stopped")


class TwoStarts(Base):
    def test_two_starts_at_once_submit_one_job(self):
        results = []

        def go():
            results.append(self.g.run("worker start", FAKE_SBATCH_DELAY="2"))

        threads = [threading.Thread(target=go) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(self.sbatches()), 1, (results, self.g.calls()))
        outs = "\n".join(r[1] + r[2] for r in results)
        self.assertIn("submitted as job 40501234", outs)
        self.assertTrue("already has job 40501234" in outs or "another start of worker worker is under way" in outs, outs)
        self.assertNotIn("cannot stat", outs, "no race on a shared temporary file")
        self.assertFalse(os.path.exists(os.path.join(self.g.rundir(), ".start.lock")))


class UnknownAnswer(Base):
    def test_an_unknown_state_word_changes_nothing(self):
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.g.jobs(["40501234|BOOT_UP|None|N/A|"])
        rc, out, err = self.g.run("worker status --json")
        self.assertEqual(rc, 0, (out, err))
        j = json.loads(out)
        self.assertIsNone(j["scheduler"])
        self.assertEqual(self.g.status()["state"], "queued", "a job still in line is never read as gone")
        self.assertFalse(any("Couldn't start" in l for l in self.g.progress()))

    def test_a_job_the_scheduler_no_longer_lists_is_an_error(self):
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.g.jobs([])
        j = json.loads(self.g.run("worker status --json")[1])
        self.assertEqual(j["scheduler"]["state"], "GONE")
        self.assertEqual(self.g.status()["state"], "error")


class StaleLine(Base):
    def test_a_live_state_with_an_old_heartbeat_says_so(self):
        rd = self.g.rundir()
        os.makedirs(rd)
        with open(os.path.join(rd, "job.id"), "w") as fh:
            fh.write("40501234\n")
        self.g.write_status({"state": "online", "job": "40501234", "submitted_at": iso(-20000), "online_at": iso(-19000), "renewal": False,
                             "environment_url": "https://claude.ai/code?environment=env_01X", "title": "Wayne State grid"}, mtime=time.time() - 5 * 3600)
        rc, out, err = self.g.run("worker status")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines()[0], "Your worker last reported 300 min ago (it said: online); it may have ended.")
        j = json.loads(self.g.run("worker status --json")[1])
        self.assertEqual(j["line"], "Your worker last reported 300 min ago (it said: online); it may have ended.")


class HiddenKey(unittest.TestCase):
    """the one-time grid key behind an empty file inside the worker's container (common.sh hpcw_hide_login_key)"""

    def run_hide(self, binds, make_key=True):
        td = tempfile.mkdtemp(prefix="hpcw_hide_")
        home = os.path.join(td, "home")
        nt = os.path.join(td, "nt")
        os.makedirs(os.path.join(home, ".ssh"))
        os.makedirs(nt)
        if make_key:
            with open(os.path.join(home, ".ssh", "beethoven_ed25519"), "w") as fh:
                fh.write("key\n")
        h, n = G.msys(home), G.msys(nt)
        script = "source '%s/lib/adapters/common.sh' && hpcw_hide_login_key \"%s\" '%s'" % (G.posix(G.ROOT), binds.replace("HOME", h).replace("TD", G.msys(td)), n)
        rc, out, err = G.bash(script, env={"HOME": h})
        return rc, out, h, n

    def test_bound_home(self):
        rc, out, h, n = self.run_hide("-B HOME -B /rs/x")
        self.assertEqual((rc, out), (0, "-B %s/no-login-key:%s/.ssh/beethoven_ed25519:ro" % (n, h)))

    def test_a_folder_above_the_home(self):
        rc, out, h, n = self.run_hide("-B 'TD' -B /a:/b:ro")
        self.assertEqual((rc, out), (0, "-B %s/no-login-key:%s/.ssh/beethoven_ed25519:ro" % (n, h)))

    def test_no_bind_of_the_home_no_extra_bind(self):
        self.assertEqual(self.run_hide("-B /rs/x")[1], "")

    def test_no_key_no_extra_bind(self):
        self.assertEqual(self.run_hide("-B HOME", make_key=False)[1], "")


if __name__ == "__main__":
    unittest.main()
