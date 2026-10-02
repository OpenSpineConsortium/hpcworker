"""hpcworker connect (framework 10), against a scratch account and the fake scheduler of fakegrid.py:
the HPCW-STEP lines in each order the contract allows (a first run, a returning run, a job already in
line, a refusal, a restricted workspace, a usage error, a setup that cannot be done), the four --login
modes, each sign-in failure code with its exit status, the keepalive while the sign-in computer is
awaited, the pasted code never echoed, and the relay (lib/relay.py) on its own."""
import json
import os
import re
import subprocess
import tempfile
import time
import unittest

import fakegrid as G

STEP_ORDER = ["setup", "consent", "queued", "signin", "signed-in", "done"]
KNOWN = re.compile(r"^(HPCW-STEP (setup (ready|changed)|consent|queued [0-9]+ (new|kept) .+|signin|signed-in \S+ \S+|done|failed [a-z-]+( .*)?)"
                   r"|HPCW-LOGIN: .+|HPCW-LOGIN-FAILED: .+|AUTH-URL: \S+|SIGNED-IN \S+ \S+|srun: .+)$")


def fwd(text):
    """paths with forward slashes: on a Windows checkout the state directory comes back with backslashes
    (Git Bash hands a native python a backslashed HOME); on the grid there are none to change"""
    return text.replace("\\", "/")


def steps(out):
    return [l.split()[1] for l in out.splitlines() if l.startswith("HPCW-STEP ")]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def connect(self, flags="", stdin_text=None, **env):
        rc, out, err = self.g.run("connect --profile testsite " + flags, stdin_text=stdin_text if stdin_text is not None else G.CODE + "\n", **env)
        return rc, fwd(out), err

    def assert_whole_lines(self, out):
        for line in out.splitlines():
            self.assertRegex(line, KNOWN, "every line is one of the contract's, whole: %r" % line)

    def assert_order(self, out):
        seen = steps(out)
        self.assertEqual(len(seen), len(set(seen)), "each HPCW-STEP at most once: %s" % seen)
        order = [s for s in seen if s != "failed"]
        self.assertEqual(order, sorted(order, key=STEP_ORDER.index), seen)
        if "failed" in seen:
            self.assertEqual(seen[-1], "failed", "nothing after a failed line")


class Orders(Base):
    def test_first_run(self):
        rc, out, err = self.connect("--consent %s" % G.INSTALL_ID)
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(err.strip(), "", "connect writes nothing to stderr")
        self.assert_whole_lines(out)
        self.assert_order(out)
        rd = G.posix(self.g.rundir())
        lines = out.splitlines()
        self.assertEqual(lines[:4], ["HPCW-STEP setup changed", "HPCW-STEP consent", "HPCW-STEP queued 40501234 new %s" % rd, "HPCW-STEP signin"])
        self.assertEqual(lines[4], "HPCW-LOGIN: requesting a compute node")
        self.assertIn("AUTH-URL: https://claude.ai/oauth/authorize?code=true", lines)
        self.assertEqual(lines[-3:], ["SIGNED-IN st1234@wayne.edu max", "HPCW-STEP signed-in st1234@wayne.edu max", "HPCW-STEP done"])
        self.assertNotIn(G.CODE, out, "the pasted code is never echoed")
        # the account is set up for the shared copy, without the ~/.bashrc block
        self.assertEqual(sorted(os.listdir(self.g.hpcw)), ["bin", "consent", "log", "profile.json", "shared"])
        self.assertEqual(os.listdir(os.path.join(self.g.hpcw, "log")), [], "the sitting's outcome file is removed")
        self.assertFalse(os.path.exists(os.path.join(self.g.home, ".bashrc")))
        with open(os.path.join(self.g.hpcw, "consent")) as fh:
            self.assertRegex(fh.read(), r"^yes \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ %s\n$" % G.INSTALL_ID)
        # one sbatch, one srun with the framework 10 flags: keepalive 20 s, the 840 s deadline, 600 s for the computer
        calls = self.g.calls()
        self.assertEqual([c.split()[0] for c in calls], ["sbatch", "srun"], calls)
        srun = calls[1]
        self.assertIn("-p secp -q secondary -t 00:20:00", srun)
        self.assertIn("-I600 --pty", srun)
        m = re.search(r"_exec login --plain --keepalive 20 --deadline (\d+)$", srun)
        self.assertTrue(m, srun)
        self.assertLessEqual(abs(int(m.group(1)) - (int(time.time()) + 840)), 120)
        self.assertNotIn("--fresh", srun)

    def test_returning_signed_in_skips_the_sitting(self):
        self.g.setup()
        # a worker stopped earlier said it was signed in; the newest status carrying claude_login decides, whatever its age
        self.g.write_status({"version": 9, "run": "worker", "job": "40500019", "state": "stopped",
                             "claude_login": {"loggedIn": True, "email": "alex@wayne.edu", "subscriptionType": "max", "checked_at": "2026-09-01T00:00:00Z"}},
                            mtime=time.time() - 30 * 86400)
        rc, out, err = self.connect("--consent %s" % G.INSTALL_ID)
        self.assertEqual(rc, 0, (out, err))
        rd = G.posix(self.g.rundir())
        self.assertEqual(out.splitlines(), ["HPCW-STEP setup ready", "HPCW-STEP consent", "HPCW-STEP queued 40501234 new %s" % rd,
                                           "HPCW-STEP signed-in alex@wayne.edu max", "HPCW-STEP done"])
        self.assertNotIn("srun", " ".join(self.g.calls()))

    def test_signed_out_status_runs_the_sitting(self):
        self.g.setup()
        self.g.write_status({"state": "stopped", "job": "1", "claude_login": {"loggedIn": False, "email": "", "subscriptionType": ""}})
        rc, out, err = self.connect()
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(steps(out), ["setup", "queued", "signin", "signed-in", "done"])

    def test_job_already_in_line_is_kept(self):
        self.g.setup()
        os.makedirs(self.g.rundir())
        with open(os.path.join(self.g.rundir(), "job.id"), "w") as fh:
            fh.write("40500019\n")
        with open(os.path.join(self.g.rundir(), "next.id"), "w") as fh:
            fh.write("40500052 40500019\n")
        self.g.jobs(["40500019|RUNNING|None|2026-10-01T08:00:00|node03", "40500052|PENDING|Dependency|N/A|"])
        rc, out, err = self.connect("--login never")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines(), ["HPCW-STEP setup ready", "HPCW-STEP queued 40500019 kept %s" % G.posix(self.g.rundir()), "HPCW-STEP done"],
                         "the running one is named, not its successor")
        calls = self.g.calls()
        self.assertEqual(calls, ["squeue -h -j 40500019,40500052 -o %i|%T|%N"], "one scheduler call and nothing submitted")

    def test_refused(self):
        with open(os.path.join(self.g.sched, "sbatch_fail"), "w") as fh:
            fh.write("sbatch: error: Batch job submission failed: Invalid qos specification\n")
        rc, out, err = self.connect("--consent %s" % G.INSTALL_ID)
        self.assertEqual(rc, 5, (out, err))
        self.assertEqual(out.splitlines(), ["HPCW-STEP setup changed", "HPCW-STEP consent",
                                            "HPCW-STEP failed refused sbatch: error: Batch job submission failed: Invalid qos specification"])
        self.assertFalse(os.path.exists(os.path.join(self.g.rundir(), "status.json")), "no queued file for a job the scheduler refused")

    def test_restricted_marker_and_profile(self):
        self.g.setup()
        ws = os.path.join(self.g.state, "workspaces", "worker")
        os.makedirs(ws)
        open(os.path.join(ws, ".restricted"), "w").close()
        rc, out, err = self.connect("--consent %s" % G.INSTALL_ID)
        self.assertEqual(rc, 4, (out, err))
        self.assertEqual(out.splitlines(), ["HPCW-STEP setup ready", "HPCW-STEP consent", "HPCW-STEP failed restricted the workspace %s is marked restricted" % G.posix(ws)])
        self.assertEqual(self.g.calls(), [], "nothing reaches the scheduler")
        # the site profile can restrict every workspace ("*") or one by name
        for value in (["*"], ["gpu"]):
            with tempfile.TemporaryDirectory() as td:
                g = G.Grid(td, profile_edit=lambda p, v=value: p.update(restricted_workspaces=v))
                rc, out, err = g.run("connect --profile testsite --name gpu --login never")
                self.assertEqual(rc, 4, (value, out, err))
                self.assertIn("HPCW-STEP failed restricted", out)
                rc, out, err = g.run("connect --profile testsite --name other --login never")
                self.assertEqual(rc, 4 if value == ["*"] else 0, (value, out, err))

    def test_usage(self):
        for flags, why in (("--bogus", "unknown option --bogus"), ("--consent nothex", "--consent needs this installation's 32-character id"),
                           ("--login maybe", "--login must be auto, always, fresh or never"), ("--name 'a b'", "the worker name must be 1 to 32 letters, digits, _ or -"),
                           ("--permission-mode yolo", "--permission-mode must be default, acceptEdits or plan"), ("--name", "--name needs a value")):
            rc, out, err = self.g.run("connect --profile testsite " + flags)
            self.assertEqual((rc, out.strip()), (2, "HPCW-STEP failed usage " + why), flags)
        self.assertFalse(os.path.exists(self.g.hpcw), "a usage error changes nothing")
        self.assertEqual(self.g.calls(), [])

    def test_setup_that_cannot_be_done(self):
        with tempfile.TemporaryDirectory() as td:
            g = G.Grid(td, profile_edit=lambda p: p.update(shared_install="/nonexistent/beethoven/hpcworker/current"))
            rc, out, err = g.run("connect --profile testsite")
            self.assertEqual(rc, 3, (out, err))
            self.assertEqual(out.strip(), "HPCW-STEP failed setup the shared copy at /nonexistent/beethoven/hpcworker/current cannot be used from this account: "
                                          "this account cannot open it (it does not exist, or this account is not in the group that may read it). Nothing was changed.")
        # no profile named and none on record
        rc, out, err = self.g.run("connect")
        self.assertEqual((rc, out.strip()), (3, "HPCW-STEP failed setup this account has no site profile yet; connect needs --profile SITE"))

    def test_permission_mode_and_chain_reach_the_job(self):
        rc, out, err = self.connect("--login never --permission-mode plan --no-chain")
        self.assertEqual(rc, 0, (out, err))
        with open(os.path.join(self.g.rundir(), "params")) as fh:
            params = fh.read()
        self.assertIn("PERMISSION_MODE=plan", params)
        self.assertIn("CHAIN=0", params)
        self.assertFalse(self.g.status()["chain"])


class LoginModes(Base):
    def setUp(self):
        super().setUp()
        self.g.setup()
        self.g.write_status({"state": "stopped", "job": "1", "claude_login": {"loggedIn": True, "email": "alex@wayne.edu", "subscriptionType": "pro"}}, name="other")

    def test_never(self):
        rc, out, err = self.connect("--login never")
        self.assertEqual((rc, steps(out)), (0, ["setup", "queued", "done"]), (out, err))
        self.assertNotIn("srun", " ".join(self.g.calls()))

    def test_auto_takes_any_runs_answer(self):
        rc, out, err = self.connect("--login auto")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-STEP signed-in alex@wayne.edu pro", out.splitlines())
        self.assertNotIn("HPCW-STEP signin", out)

    def test_always_runs_the_sitting_even_when_signed_in(self):
        rc, out, err = self.connect("--login always", FAKE_SRUN="already")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(steps(out), ["setup", "queued", "signin", "signed-in", "done"])
        self.assertIn("HPCW-STEP signed-in st1234@wayne.edu max", out)
        self.assertNotIn("--fresh", " ".join(self.g.calls()))

    def test_fresh_signs_out_first(self):
        rc, out, err = self.connect("--login fresh")
        self.assertEqual(rc, 0, (out, err))
        srun = [c for c in self.g.calls() if c.startswith("srun ")]
        self.assertEqual(len(srun), 1)
        self.assertIn(" --fresh", srun[0])
        self.assertIn("HPCW-STEP signed-in st1234@wayne.edu max", out)

    def test_plan_word_and_empty_fields(self):
        rc, out, err = self.connect("--login always", FAKE_PLAN="-")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-STEP signed-in st1234@wayne.edu -", out.splitlines())


class SigninFailures(Base):
    def check(self, rc_want, code, extra_flags="--login always", stdin_text=None, last_login_line=None, **env):
        rc, out, err = self.connect(extra_flags, stdin_text=stdin_text, **env)
        self.assertEqual(rc, rc_want, (out, err))
        lines = out.splitlines()
        self.assertTrue(lines[-1].startswith("HPCW-STEP failed %s " % code), lines)
        self.assertTrue(lines[-2].startswith("HPCW-LOGIN-FAILED: "), lines)
        if last_login_line:
            self.assertEqual(lines[-2], last_login_line)
        self.assert_order(out)
        self.assertIn("HPCW-STEP queued", out, "the worker keeps its place in line")
        return lines

    def test_wrong_code(self):
        lines = self.check(7, "signin-code", stdin_text="WRONGCODE12345\n")
        self.assertEqual(lines[-1], "HPCW-STEP failed signin-code Claude Code did not accept the code; start the sign-in again and paste the whole code")
        self.assertNotIn("WRONGCODE", "\n".join(lines))

    def test_no_code_in_time(self):
        self.check(7, "signin-timeout", FAKE_SRUN="timeout")

    def test_no_computer(self):
        lines = self.check(6, "signin-node", FAKE_SRUN="nonode",
                           last_login_line="HPCW-LOGIN-FAILED: the cluster did not give a compute node in time, or the session ended early; try again in a minute")
        # srun's own message is relayed whole, as an ordinary line
        self.assertIn("srun: error: Unable to allocate resources: Job not run since it would not start within the requested time", lines)

    def test_other_failure(self):
        self.check(7, "signin", FAKE_SRUN="other")

    def test_no_answer(self):
        self.check(7, "signin", FAKE_SRUN="silentok")


class Keepalive(Base):
    def test_lines_while_the_computer_is_awaited_and_all_whole(self):
        # one second here for the 20 s of the real thing; srun silent for 3.5 s, then lines ending in CR LF as a pty sends them
        rc, out, err = self.connect("--login always", HPCW_KEEPALIVE_S="1", FAKE_SRUN_DELAY="3.5", FAKE_SRUN_CRLF="1")
        self.assertEqual(rc, 0, (out, err))
        self.assertNotIn("\r", out)
        self.assert_whole_lines(out)
        lines = out.splitlines()
        a = lines.index("HPCW-LOGIN: requesting a compute node")
        b = lines.index("HPCW-LOGIN: on node01; checking whether you are signed in already")
        self.assertGreaterEqual(lines[a + 1:b].count("HPCW-LOGIN: still waiting"), 2, lines)
        self.assertEqual(set(lines[a + 1:b]), {"HPCW-LOGIN: still waiting"})
        self.assertNotIn("still waiting", " ".join(lines[:a]), "no keepalive before the sign-in step")
        self.assertEqual(lines[-1], "HPCW-STEP done")


class RelayAlone(unittest.TestCase):
    RELAY = os.path.join(G.ROOT, "lib", "relay.py")

    def run_relay(self, feed, every="1"):
        with tempfile.TemporaryDirectory() as td:
            summary = os.path.join(td, "outcome")
            rc, out, err = G.bash("{ %s; } | \"$HPCW_PYTHON\" '%s' %s '%s'" % (feed, G.posix(self.RELAY), every, G.posix(summary)))
            self.assertEqual(rc, 0, err)
            with open(summary, "rb") as fh:
                return out, fh.read().decode("utf-8")

    def test_partial_line_is_held_until_its_end(self):
        out, summary = self.run_relay("printf 'SIGNED'; sleep 2.5; printf '%s\\r\\n' '-IN a@b.edu max'", every="1")
        lines = out.splitlines()
        self.assertIn("SIGNED-IN a@b.edu max", lines, "a split line arrives whole")
        self.assertNotIn("HPCW-LOGIN: still waiting", lines, "no keepalive while part of a line waits")
        self.assertEqual(summary, "SIGNED-IN a@b.edu max\n\n")

    def test_keepalive_and_outcome(self):
        out, summary = self.run_relay("echo one; sleep 2.6; echo 'HPCW-LOGIN-FAILED: no code arrived within 2 minutes; start the sign-in again'", every="1")
        lines = out.splitlines()
        self.assertEqual(lines[0], "one")
        self.assertGreaterEqual(lines.count("HPCW-LOGIN: still waiting"), 2, lines)
        self.assertEqual(lines[-1], "HPCW-LOGIN-FAILED: no code arrived within 2 minutes; start the sign-in again")
        self.assertEqual(summary, "\nHPCW-LOGIN-FAILED: no code arrived within 2 minutes; start the sign-in again\n")

    def test_last_line_without_newline(self):
        out, _ = self.run_relay("printf 'tail'", every="20")
        self.assertEqual(out, "tail\n")


if __name__ == "__main__":
    unittest.main()
