"""The worker job (jobs/worker.sbatch.tpl) rendered and run whole, as Slurm would run it, against
stand-ins: a container runtime that runs its command directly, a Claude Code that answers --version,
`auth status` and `remote-control` (printing the registration block Claude Code 2.1.283 prints), and
the fake scheduler of fakegrid.py for the successor and its cancel. What is checked is framework 10's
side of the job: its first write over the queued status.json (node, got_computer_at, submitted_at kept,
ends_at, the title, renewal), progress.log, the job output's "<H:MM> Online. Open in Claude: <link>",
online_at in status.json and connection.json, the stop, a chain successor's renewal, and the sign-in
abandon (stopped, stop_reason login_abandoned, the successor cancelled, stop.done).

Needs tmux or script, mkfifo and timeout (Linux, WSL); skipped on a Windows checkout."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone

import fakegrid as G

LINUX = os.name != "nt" and all(shutil.which(t) for t in ("mkfifo", "timeout")) and (shutil.which("tmux") or shutil.which("script"))
ENV_URL = "https://claude.ai/code?environment=env_01XzAN32jsbL8W1PAFSvitBt"

FAKE_APPTAINER = r"""#!/bin/bash
# a container runtime that runs its command here: exec [binds] IMAGE CMD...
[ "$1" = exec ] && shift
while [ $# -gt 0 ]; do case "$1" in -B|--bind) shift 2;; --nv) shift;; *) break;; esac; done
shift
exec "$@"
"""
FAKE_CLAUDE = r"""#!/bin/bash
case "$1 ${2:-}" in
  "--version ") echo "2.1.283 (Claude Code)";;
  "auth status") if [ -e "${FAKE_LOGGED_IN:-/nonexistent}" ]; then echo '{"loggedIn": true, "email": "st1234@wayne.edu", "subscriptionType": "max"}'; else echo '{"loggedIn": false}'; fi;;
  "remote-control --help") echo "Usage: claude remote-control [options]  --name <name> --capacity <n> --continue --permission-mode <mode>";;
  remote-control*)
    printf '\033[2J\033[H'
    printf '\xc2\xb7\xe2\x9c\x94\xef\xb8\x8e\xc2\xb7 Connected \xc2\xb7 phone \xc2\xb7 HEAD\r\n'
    printf '    Capacity: 1/32 \xc2\xb7 New sessions will be created in the current directory\r\n'
    printf '    asx10-hazy-meadow\r\n'
    printf 'Continue coding in the Claude mobile app or %s\r\n' "$FAKE_ENV_URL"
    exec sleep 600;;
  *) echo "fake claude: $*" >&2; exit 2;;
esac
"""
FAKE_NODE = "#!/bin/bash\necho seeded\n"


@unittest.skipUnless(LINUX, "runs the whole job: needs tmux or script, mkfifo and timeout (Linux, WSL)")
class Job(unittest.TestCase):
    JOB = "4242"

    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="hpcw_job_")
        self.g = G.Grid(self.td)  # for the fake scheduler on PATH
        for name, text in (("apptainer", FAKE_APPTAINER), ("claude", FAKE_CLAUDE), ("node", FAKE_NODE)):
            p = os.path.join(self.g.bin, name)
            with open(p, "w", newline="\n") as fh:
                fh.write(text)
            os.chmod(p, 0o755)
        img = os.path.join(self.td, "image", "usr", "local", "bin")
        os.makedirs(img)
        os.symlink(os.path.join(self.g.bin, "node"), os.path.join(img, "node"))
        with open(os.path.join(G.ROOT, "profiles", "wayne.json"), encoding="utf-8") as fh:
            p = json.load(fh)
        p.update(site="testsite", shared_state_dir=os.path.join(self.td, "state"), runtime_module="", runtime_bin=os.path.join(self.g.bin, "apptainer"),
                 image_store={"type": "sandbox", "path": os.path.join(self.td, "image")}, claude_bin=os.path.join(self.g.bin, "claude"),
                 node_tmp=os.path.join(self.td, "nodetmp", "$USER", "hpcworker_$SLURM_JOB_ID"), ipc_dir=os.path.join(self.td, "ipc"),
                 claude_config_dir=os.path.join(self.td, "cfg"), consent_markers=[], binds=[self.td], scheduler_in_worker=False,
                 egress={"class": "direct", "proxy_env": {}, "proxy_module": "", "ca_bundle": "", "measured": {}})
        self.profile = os.path.join(self.td, "profile.json")
        with open(self.profile, "w", encoding="utf-8") as fh:
            json.dump(p, fh)
        self.home = os.path.join(self.td, "home")
        os.makedirs(os.path.join(self.home, ".hpcworker"))
        with open(os.path.join(self.home, ".hpcworker", "consent"), "w") as fh:
            fh.write("yes 2026-10-01T08:00:00Z %s\n" % G.INSTALL_ID)
        self.rd = os.path.join(self.td, "state", "worker")
        os.makedirs(self.rd)
        self.logged_in = os.path.join(self.td, "logged-in")

    def tearDown(self):
        subprocess.run(["bash", "-c", "pkill -f '%s' 2>/dev/null; true" % self.td])
        shutil.rmtree(self.td, ignore_errors=True)

    def env(self):
        e = dict(os.environ)
        e.update(HOME=self.home, USER="st1234", SLURM_JOB_ID=self.JOB, FAKE_SCHED_DIR=self.g.sched, FAKE_LOGGED_IN=self.logged_in,
                 FAKE_ENV_URL=ENV_URL, PATH=self.g.bin + ":" + e["PATH"], HPCW_PYTHON=sys.executable)
        for k in ("TMUX", "CLAUDECODE"):
            e.pop(k, None)
        return e

    def render(self, **over):
        kv = dict(RUN="worker", HPCW_HOME=os.path.join(self.home, ".hpcworker"), HPCW_CODE=G.ROOT, LOGIN_ABANDON_S="2", AUTH_RETRY_S="0", HEARTBEAT_S="5")
        kv.update(over)
        p = subprocess.run([sys.executable, os.path.join(G.ROOT, "lib", "profile.py"), "render", os.path.join(G.ROOT, "jobs", "worker.sbatch.tpl"), self.profile]
                           + ["%s=%s" % i for i in kv.items()], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env())
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(os.path.join(self.rd, "job.sbatch"), "wb") as fh:
            fh.write(p.stdout)

    def queued_file(self, submitted_at="2026-10-01T12:44:05Z"):
        """what `worker start` leaves: job.id, the queued status.json and the first progress line"""
        with open(os.path.join(self.rd, "job.id"), "w") as fh:
            fh.write(self.JOB + "\n")
        q = {"version": 10, "site": "testsite", "run": "worker", "job": self.JOB, "node": "", "state": "queued", "message": "waiting for a computer",
             "needs": "nothing", "hint": "Your worker is in line for a computer.", "submitted_at": submitted_at, "updated_at": submitted_at,
             "title": "Wayne State grid", "requested_name": "Wayne State grid", "renewal": False, "chain": True, "next_job": "", "consent": True,
             "consent_source": "marker", "scheduler_state": "PENDING", "reason": "Priority", "expected_start": "", "checked_at": submitted_at}
        with open(os.path.join(self.rd, "status.json"), "w") as fh:
            fh.write(json.dumps(q) + "\n")
        with open(os.path.join(self.rd, "progress.log"), "w") as fh:
            fh.write("%s Asked the grid for a computer\n" % submitted_at)

    def start_job(self):
        return subprocess.Popen(["bash", os.path.join(self.rd, "job.sbatch")], cwd=self.rd, env=self.env(), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, encoding="utf-8", errors="replace")

    def status(self):
        with open(os.path.join(self.rd, "status.json"), encoding="utf-8") as fh:
            return json.load(fh)

    def progress(self):
        with open(os.path.join(self.rd, "progress.log"), encoding="utf-8") as fh:
            return [l.split(" ", 1)[1] for l in fh.read().splitlines()]

    def wait_for(self, pred, seconds):
        t0 = time.time()
        while time.time() - t0 < seconds:
            try:
                if pred():
                    return True
            except (OSError, ValueError):
                pass
            time.sleep(0.5)
        return False

    @staticmethod
    def epoch(s):
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()

    def test_online_then_stopped(self):
        open(self.logged_in, "w").close()
        self.render()
        self.queued_file()
        t0 = time.time()
        proc = self.start_job()
        try:
            self.assertTrue(self.wait_for(lambda: self.status()["state"] == "online" and self.status()["online_at"], 90), "online within 90 s")
            s = self.status()
            self.assertEqual((s["job"], s["submitted_at"], s["renewal"], s["title"], s["requested_name"]), (self.JOB, "2026-10-01T12:44:05Z", False, "Wayne State grid", "Wayne State grid"),
                             "the queued file's submitted_at is kept; the session title is the profile's")
            self.assertEqual(s["got_computer_at"], s["started_at"])
            self.assertLess(abs(self.epoch(s["got_computer_at"]) - t0), 30)
            self.assertEqual(self.epoch(s["ends_at"]) - self.epoch(s["got_computer_at"]), 8 * 3600, "got_computer_at + the job's hours")
            self.assertGreaterEqual(self.epoch(s["online_at"]), self.epoch(s["got_computer_at"]))
            self.assertEqual(s["environment_url"], ENV_URL)
            self.assertNotIn("stop_reason", s)
            for key in ("version", "site", "run", "job", "node", "pid", "state", "message", "needs", "hint", "started_at", "updated_at", "session_name", "requested_name",
                        "session_url", "environment_url", "environment_id", "claude_login", "consent", "consent_source", "workspace_trusted", "rc_alive", "resumed",
                        "tmux", "restarts", "chain", "next_job", "chain_note", "scheduler_in_worker", "scheduler_note", "workspace", "rc_log", "token_path"):
                self.assertIn(key, s, "framework 9's field %s is kept" % key)
            with open(os.path.join(self.rd, "connection.json")) as fh:
                c = json.load(fh)
            self.assertEqual((c["title"], c["online_at"], c["environment_url"]), ("Wayne State grid", s["online_at"], ENV_URL))
            with open(os.path.join(self.rd, "node")) as fh:
                self.assertEqual(fh.read().strip(), s["node"])
            self.assertEqual(self.progress(), ["Asked the grid for a computer", "Got a computer", "Connecting to Claude", "Online: " + ENV_URL])
            open(os.path.join(self.rd, "stop"), "w").close()
            out, _ = proc.communicate(timeout=90)
        finally:
            if proc.poll() is None:
                proc.kill()
        self.assertEqual(proc.returncode, 0, out)
        s = self.status()
        self.assertEqual((s["state"], s["stop_reason"]), ("stopped", "request"))
        self.assertEqual(self.progress()[-1], "Stopped")
        self.assertTrue(os.path.exists(os.path.join(self.rd, "stop.done")))
        self.assertRegex(out, r"(?m)^\d{1,2}:\d\d Online\. Open in Claude: %s$" % re.escape(ENV_URL))
        self.assertIn("scancel 40501234", self.g.calls(), "the successor the job queued is cancelled by the stop")

    def test_signed_out_job_stops_itself(self):
        self.render(LOGIN_ABANDON_S="3")
        self.queued_file()
        proc = self.start_job()
        out, _ = proc.communicate(timeout=120)
        self.assertEqual(proc.returncode, 0, out)
        s = self.status()
        self.assertEqual((s["state"], s["stop_reason"], s["message"], s["needs"]), ("stopped", "login_abandoned", "stopped: waiting for your Claude sign-in timed out", "nothing"))
        self.assertEqual(self.progress(), ["Asked the grid for a computer", "Got a computer", "Waiting for your Claude sign-in", "Stopped: waiting for your Claude sign-in timed out"])
        self.assertTrue(os.path.exists(os.path.join(self.rd, "stop.done")))
        self.assertFalse(os.path.exists(os.path.join(self.rd, "next.id")), "no successor left queued")
        calls = self.g.calls()
        self.assertEqual([c.split()[0] for c in calls].count("sbatch"), 1, calls)
        self.assertIn("scancel 40501234", calls)
        # a later stop is a no-op, and status says why it stopped
        rc, sout, err = G.bash("source '%s/bin/hpcworker' && HPCW_STOP_WAIT_S=1 stop_worker_run '%s' worker" % (G.ROOT, self.rd), env={"HPCW_HOME": os.path.join(self.home, ".hpcworker")})
        self.assertIn("it had stopped before", sout)

    def test_a_sign_in_just_before_the_deadline_is_not_abandoned(self):
        # the once-a-minute check would only see it after the deadline: the abandon looks once more first
        self.render(LOGIN_ABANDON_S="8", LOGIN_RECHECK_S="600")
        self.queued_file()
        proc = self.start_job()
        try:
            self.assertTrue(self.wait_for(lambda: self.status()["state"] == "need_login", 60), "waits for the sign-in")
            time.sleep(2)
            open(self.logged_in, "w").close()   # the student finished on Anthropic's page
            self.assertTrue(self.wait_for(lambda: self.status()["state"] == "online", 90), "carries on to online, not stopped")
            self.assertNotIn("Stopped: waiting for your Claude sign-in timed out", self.progress())
            open(os.path.join(self.rd, "stop"), "w").close()
            out, _ = proc.communicate(timeout=90)
        finally:
            if proc.poll() is None:
                proc.kill()
        self.assertEqual(self.status()["stop_reason"], "request", out)

    def test_a_sitting_under_way_moves_the_clock(self):
        # connect touches signin.pending when its sitting starts: the 20-minute wait counts from there
        self.render(LOGIN_ABANDON_S="10", LOGIN_RECHECK_S="600")
        self.queued_file()
        proc = self.start_job()
        try:
            self.assertTrue(self.wait_for(lambda: self.status()["state"] == "need_login", 60))
            t_need = time.time()
            time.sleep(6)
            open(os.path.join(self.rd, "signin.pending"), "w").close()
            self.assertFalse(self.wait_for(lambda: self.status()["state"] == "stopped", max(0, 10 - (time.time() - t_need)) + 4), "not abandoned at the first deadline")
            self.assertEqual(self.status()["state"], "need_login")
            out, _ = proc.communicate(timeout=60)
        finally:
            if proc.poll() is None:
                proc.kill()
        s = self.status()
        self.assertEqual((s["state"], s["stop_reason"]), ("stopped", "login_abandoned"), out)

    def test_a_chain_successor_is_a_renewal(self):
        # the predecessor (4241) queued this job: its status.json names 4241, next.id names this job first; SubmitTime from the scheduler
        self.render(LOGIN_ABANDON_S="3")
        with open(os.path.join(self.rd, "job.id"), "w") as fh:
            fh.write("4241\n")
        with open(os.path.join(self.rd, "next.id"), "w") as fh:
            fh.write("%s 4241\n" % self.JOB)
        with open(os.path.join(self.rd, "status.json"), "w") as fh:
            json.dump({"version": 10, "job": "4241", "state": "preempted", "submitted_at": "2026-10-01T04:00:00Z", "next_job": self.JOB}, fh)
        e = self.env()
        e["FAKE_SUBMIT_TIME"] = "2026-10-01T08:30:00"
        proc = subprocess.Popen(["bash", os.path.join(self.rd, "job.sbatch")], cwd=self.rd, env=e, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                universal_newlines=True, encoding="utf-8", errors="replace")
        out, _ = proc.communicate(timeout=120)
        s = self.status()
        self.assertEqual((s["job"], s["renewal"]), (self.JOB, True), out)
        want = datetime.fromtimestamp(time.mktime(time.strptime("2026-10-01T08:30:00", "%Y-%m-%dT%H:%M:%S")), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(s["submitted_at"], want, "the predecessor's submitted_at is not this job's; the scheduler's SubmitTime is")
        self.assertIn("scontrol show job %s -o" % self.JOB, self.g.calls())


if __name__ == "__main__":
    unittest.main()
