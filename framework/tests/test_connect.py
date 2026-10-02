"""hpcworker connect (framework 10), against a scratch account and the fake scheduler of fakegrid.py:
the HPCW-STEP lines in each order the contract allows (a first run, a returning run, a job already in
line, a refusal, a restricted workspace, a usage error, a setup that cannot be done), the four --login
modes, each sign-in failure code with its exit status, the keepalive while the sign-in computer is
awaited, the pasted code never echoed, and the relay (lib/relay.sh, with its ticker) on its own."""
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
        # the account is set up for the shared copy, without the ~/.bashrc block (profile.env: framework 11's
        # copy of the profile as shell variables, which spares the next commands their python3)
        self.assertEqual(sorted(os.listdir(self.g.hpcw)), ["bin", "consent", "log", "profile.env", "profile.json", "shared"])
        self.assertEqual(os.listdir(os.path.join(self.g.hpcw, "log")), [], "the sitting's outcome file is removed")
        self.assertFalse(os.path.exists(os.path.join(self.g.home, ".bashrc")))
        with open(os.path.join(self.g.hpcw, "consent")) as fh:
            self.assertRegex(fh.read(), r"^yes \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ %s\n$" % G.INSTALL_ID)
        # one sbatch, one srun with the framework 10 flags: keepalive 20 s, the 840 s deadline, 600 s for the computer
        calls = self.g.calls()
        self.assertEqual([c.split()[0] for c in calls], ["sbatch", "srun"], calls)
        srun = calls[1]
        self.assertIn("-p secp -q secondary -t 00:20:00", srun)
        # framework 11: run with no terminal (a pipe on stdin, as Beethoven's plain ssh exec runs it), srun gets no --pty
        self.assertIn("-J hpcw_claude -I600 ", srun)
        self.assertNotIn("--pty", srun)
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


class PlainExec(Base):
    """framework 11: Beethoven's own ssh session, a plain exec with no pseudo-terminal: the code arrives on
    standard input, srun is asked for no --pty, and the code is never written back; `claude login --plain`
    for an account that was never set up; and nothing reached through the browser key's gate signs in."""

    def test_connect_without_a_terminal(self):
        rc, out, err = self.connect("--consent %s --login always" % G.INSTALL_ID)
        self.assertEqual(rc, 0, (out, err))
        self.assert_whole_lines(out)
        self.assertNotIn(G.CODE, out + err, "the code is never written back")
        self.assertIn("HPCW-STEP signed-in st1234@wayne.edu max", out)
        srun = [c for c in self.g.calls() if c.startswith("srun ")]
        self.assertEqual(len(srun), 1, self.g.calls())
        self.assertNotIn("--pty", srun[0].split())
        self.assertIn("_exec login --plain --keepalive 20 --deadline", srun[0])

    def test_claude_login_plain_for_an_account_never_set_up(self):
        for args in ("claude login --plain --profile testsite", "claude login --profile testsite --plain", "claude login --plain"):
            with self.subTest(args=args):
                if os.path.exists(self.g.hpcw):
                    import shutil
                    shutil.rmtree(self.g.hpcw)
                rc, out, err = self.g.run(args, stdin_text=G.CODE + "\n")
                self.assertEqual(rc, 0, (out, err))
                lines = fwd(out).splitlines()
                self.assertEqual(lines[0], "HPCW-LOGIN: this account is set up for the lab's copy at %s" % G.posix(self.g.shared_spelled))
                self.assertEqual(lines[1], "HPCW-LOGIN: requesting a compute node")
                self.assertEqual(lines[-1], "SIGNED-IN st1234@wayne.edu max")
                self.assertNotIn(G.CODE, out)
                self.assertTrue(os.path.exists(os.path.join(self.g.hpcw, "profile.json")))
                self.assertTrue(os.path.exists(os.path.join(self.g.hpcw, "shared")))
                srun = [c for c in self.g.calls() if c.startswith("srun ")][-1]
                self.assertNotIn("--pty", srun.split())
        # set up already: no setup line, the sitting as in framework 10
        rc, out, err = self.g.run("claude login --plain", stdin_text=G.CODE + "\n")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines()[0], "HPCW-LOGIN: requesting a compute node")

    def test_claude_login_plain_that_cannot_set_up(self):
        rc, out, err = self.g.run("claude login --plain --profile nosuch", stdin_text="")
        self.assertEqual(rc, 1, (out, err))
        self.assertTrue(out.startswith("HPCW-LOGIN-FAILED: "), out)
        self.assertEqual(len(out.splitlines()), 1, out)
        self.assertFalse(os.path.exists(os.path.join(self.g.hpcw, "profile.json")))
        self.assertNotIn("srun", " ".join(self.g.calls()))
        rc, out, err = self.g.run("claude login --plain --bogus", stdin_text="")
        self.assertNotEqual(rc, 0)

    def test_never_a_sign_in_under_the_gate(self):
        for env in ({"HPCW_GATE": "1"}, {"SSH_ORIGINAL_COMMAND": "connect worker testsite - default chain"}):
            with self.subTest(env=env):
                for login in ("always", "fresh", "auto"):
                    rc, out, err = self.connect("--login %s" % login, **env)
                    self.assertEqual(rc, 0, (out, err))
                    self.assertEqual(steps(out)[-1], "done")
                    self.assertNotIn("signin", steps(out))
                self.assertNotIn("srun", " ".join(self.g.calls()))
                rc, out, err = self.g.run("claude login --plain", stdin_text=G.CODE + "\n", **env)
                self.assertEqual((rc, out), (1, "HPCW-LOGIN-FAILED: the Claude sign-in never runs through Beethoven's browser key\n"))
                rc, out, err = self.g.run("_exec login --plain", **env)
                self.assertNotEqual(rc, 0)
                self.assertNotIn("srun", " ".join(self.g.calls()))


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


@unittest.skipIf(os.name == "nt", "needs a pseudo-terminal and /proc")
class CutShell(Base):
    """The portal's shell cut while the sitting waits for its computer: connect runs as the extension types
    it (`exec bash <tool> connect ...`, the session leader of a pseudo-terminal), the terminal hangs up,
    and nothing of the sitting (connect, srun, the relay, its ticker, a sleep) is left running."""

    def members(self, sid):
        out = []
        for p in os.listdir("/proc"):
            if not p.isdigit():
                continue
            try:
                with open("/proc/%s/stat" % p) as fh:
                    st = fh.read()
                with open("/proc/%s/cmdline" % p, "rb") as fh:
                    cmd = fh.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
            except OSError:
                continue
            fields = st[st.rindex(")") + 2:].split()   # state ppid pgrp session ...
            if int(fields[3]) == sid and fields[0] != "Z":
                out.append((int(p), int(fields[1]), int(fields[2]), cmd))
        return out

    def test_a_cut_shell_leaves_nothing_behind(self):
        import pty
        import select
        self.g.setup()
        env = dict(os.environ)
        env.update(self.g.env(FAKE_SRUN_DELAY="60", HPCW_KEEPALIVE_S="1", HPCW_PYTHON=G.PY))
        env["PATH"] = G.msys(self.g.bin) + ":" + env.get("PATH", "")
        pid, fd = pty.fork()
        if pid == 0:  # pragma: no cover (the child)
            os.execvpe(G.BASH, [G.BASH, "-c", "exec bash '%s' connect --profile testsite --login always" % self.g.tool], env)
        buf = b""
        deadline = time.time() + 60
        while buf.count(b"still waiting") < 2 and time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    buf += os.read(fd, 4096)
                except OSError:
                    break
        self.assertGreaterEqual(buf.count(b"still waiting"), 2, buf)
        before = self.members(pid)
        cmds = " | ".join(c for _, _, _, c in before)
        self.assertIn("--ticks", cmds)
        self.assertIn("relay.sh", cmds)
        self.assertEqual(len(set(g for _, _, g, _ in before)), 1, "one process group, the terminal's: %s" % before)
        tickers = set(p for p, _, _, c in before if "--ticks" in c)
        # (a child the ticker has just forked for its sleep shows the ticker's command line for a moment)
        ticker = [(pp, c) for _, pp, _, c in before if "--ticks" in c and pp not in tickers]
        self.assertEqual(len(ticker), 1, before)
        self.assertEqual(int(ticker[0][1].split()[-1]), ticker[0][0], "the ticker watches connect's side of the pipe, its parent")
        self.assertNotIn("python", cmds, "nothing of python's runs during the sitting")
        # with the portal's terminal, srun is asked for a pseudo-terminal, as in framework 10
        self.assertTrue(any("/srun " in c and "--pty" in c.split() for _, _, _, c in before), cmds)
        os.close(fd)  # the portal's shell is cut: the terminal hangs up
        deadline = time.time() + 10
        while self.members(pid) and time.time() < deadline:
            time.sleep(0.2)
        self.assertEqual(self.members(pid), [], "nothing of the sitting is left")
        os.waitpid(pid, 0)


class RelayAlone(unittest.TestCase):
    """lib/relay.sh on its own, run as connect runs it: the ticker (relay.sh --ticks) beside the feed,
    which stands in for srun, both writing into the relay's pipe, and the relay with an empty PATH. On
    the login node the relay must start no program at all (warrior's banner bans python3, which relayed
    the sitting in the first framework 10 build), so anything but a bash builtin would fail here with
    "command not found"; the ticker starts one, coreutils sleep, once a second."""
    RELAY = os.path.join(G.ROOT, "lib", "relay.sh")
    KEEPALIVE = "HPCW-LOGIN: still waiting"

    def script(self, feed, every, summary, after=""):
        r = G.posix(self.RELAY)
        # as connect: the ticker watching this side's pid, stopped by a kill after the feed (bash 4.2 runs no EXIT trap here)
        return ("B=$(command -v bash); { side=$BASHPID; BASH_ENV= \"$B\" '%s' --ticks \"$side\" 2>/dev/null & tk=$!; ( %s ); s=$?; kill $tk 2>/dev/null; exit $s; } "
                "| PATH= BASH_ENV= \"$B\" '%s' %s '%s'%s") % (r, feed, r, every, G.posix(summary), after)

    def run_relay(self, feed, every="1", after=""):
        with tempfile.TemporaryDirectory() as td:
            summary = os.path.join(td, "outcome")
            rc, out, err = G.bash(self.script(feed, every, summary, after), timeout=120)
            self.assertEqual(rc, 0, err)
            self.assertEqual(err, "", "nothing on stderr: no program was looked for")
            with open(summary, "rb") as fh:
                return out, fh.read().decode("utf-8")

    def timed(self, feed, every):
        """[(seconds since the start, line)] as the relay wrote them, and the summary"""
        with tempfile.TemporaryDirectory() as td:
            summary = os.path.join(td, "outcome")
            e = dict(os.environ, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
            t0 = time.monotonic()
            p = subprocess.Popen([G.BASH, "-c", self.script(feed, every, summary)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=e)
            got = []
            for raw in iter(p.stdout.readline, b""):
                got.append((time.monotonic() - t0, raw.decode("utf-8").rstrip("\n")))
            err = p.stderr.read().decode("utf-8", "replace")
            p.wait(60)
            p.stdout.close()
            p.stderr.close()
            self.assertEqual((p.returncode, err), (0, ""))
            with open(summary, "rb") as fh:
                return got, fh.read().decode("utf-8")

    def test_whole_lines(self):
        # several lines in one write, carriage returns (a pty's CR LF), an empty line, each written as its own line
        out, summary = self.run_relay("printf 'a\\r\\nb\\n\\r\\nHPCW-STEP x\\n'", every="20")
        self.assertEqual(out, "a\nb\n\nHPCW-STEP x\n")
        self.assertEqual(summary, "\n\n")

    def test_partial_line_is_held_until_its_end(self):
        # bash 4.2's `read -t` lost the "SIGNED" here (the relay therefore never reads with a timer)
        out, summary = self.run_relay("printf 'SIGNED'; sleep 2.5; printf '%s\\r\\n' '-IN a@b.edu max'", every="1")
        self.assertEqual(out.splitlines(), ["SIGNED-IN a@b.edu max"], "a split line arrives whole, and no keepalive while part of a line waits")
        self.assertEqual(summary, "SIGNED-IN a@b.edu max\n\n")

    def test_partial_line_alone_after_five_seconds(self):
        # written at the fifth tick after the one that brought it: 5 to 6 s after its last byte (later on a
        # loaded Windows checkout, where a fork for the ticker's sleep can take seconds)
        got, _ = self.timed("printf 'part'; sleep 12; printf 'rest\\n'", every="20")
        self.assertEqual([l for _, l in got], ["part", "rest"])
        self.assertGreaterEqual(got[0][0], 4.9, "held five seconds")
        self.assertLess(got[0][0], 11.9, "and written as a line of its own before the rest arrives")
        if os.name != "nt":
            self.assertLess(got[0][0], 7.0)

    def test_partial_line_waits_in_ticks_not_on_the_clock(self):
        # the relay kept from running (a busy login node) while the ticks queue up: the queued ticks, written a
        # second apart, measure the wait, so a part of a line followed by its rest within the ticks' five
        # seconds is never cut early. Stood in for by writing the queue at once: part, three ticks, the rest
        r = G.posix(self.RELAY)
        with tempfile.TemporaryDirectory() as td:
            summary = os.path.join(td, "outcome")
            rc, out, err = G.bash("B=$(command -v bash); { printf 'SIGNED\\001tick\\n'; sleep 6; printf '\\001tick\\n\\001tick\\n\\001tick\\n'; "
                                  "printf '%%s\\n' '-IN a@b.edu max'; } | PATH= \"$B\" '%s' 20 '%s'" % (r, G.posix(summary)), timeout=60)
            self.assertEqual((rc, err), (0, ""))
            self.assertEqual(out, "SIGNED-IN a@b.edu max\n", "six seconds on the relay's clock, three ticks: not cut")
            rc, out, err = G.bash("B=$(command -v bash); { printf 'part\\001tick\\n'; printf '\\001tick\\n%%.0s' 1 2 3 4 5; printf 'rest\\n'; } "
                                  "| PATH= \"$B\" '%s' 20 ''" % r, timeout=60)
            self.assertEqual(out, "part\nrest\n", "five ticks after the one that brought it: written alone, however fast they came")

    def test_keepalive_timing(self):
        got, _ = self.timed("echo one; sleep 3.6; echo two", every="1")
        lines = [l for _, l in got]
        self.assertEqual((lines[0], lines[-1]), ("one", "two"))
        self.assertEqual(set(lines[1:-1]), {self.KEEPALIVE})
        kas = [t for t, l in got if l == self.KEEPALIVE]
        self.assertIn(len(kas), (2, 3, 4), got)
        self.assertGreaterEqual(kas[0] - got[0][0], 0.5, "not before half an interval")
        for a, b in zip(kas, kas[1:]):
            self.assertGreaterEqual(b - a, 0.5, got)
            self.assertLessEqual(b - a, 1.9, got)
        # and none while the silence is shorter than the interval
        out, _ = self.run_relay("echo one; sleep 2; echo two", every="20")
        self.assertEqual(out, "one\ntwo\n")

    def test_keepalive_and_outcome(self):
        out, summary = self.run_relay("echo one; sleep 2.6; echo 'HPCW-LOGIN-FAILED: no code arrived within 2 minutes; start the sign-in again'", every="1")
        lines = out.splitlines()
        self.assertEqual(lines[0], "one")
        self.assertGreaterEqual(lines.count(self.KEEPALIVE), 2, lines)
        self.assertEqual(lines[-1], "HPCW-LOGIN-FAILED: no code arrived within 2 minutes; start the sign-in again")
        self.assertEqual(summary, "\nHPCW-LOGIN-FAILED: no code arrived within 2 minutes; start the sign-in again\n")

    def test_summary_keeps_the_last_of_each(self):
        feed = ("printf '%s\\n' 'SIGNED-IN old@b.edu pro' '  HPCW-LOGIN-FAILED: first  ' 'HPCW-LOGIN: code received, checking' "
                "' SIGNED-IN a@b.edu max ' 'HPCW-LOGIN-FAILED: second'; printf 'x\\r\\n'")
        out, summary = self.run_relay(feed, every="20")
        self.assertEqual(summary, "SIGNED-IN a@b.edu max\nHPCW-LOGIN-FAILED: second\n", "the last of each, without the spaces around it")
        self.assertIn(" SIGNED-IN a@b.edu max \n", out, "the line itself is written as it came")
        if os.name != "nt":
            with tempfile.TemporaryDirectory() as td:
                summary = os.path.join(td, "outcome")
                G.bash(self.script("echo SIGNED-IN a@b.edu max", "20", summary))
                self.assertEqual(os.stat(summary).st_mode & 0o777, 0o600, "the outcome file is the account's alone")

    def test_last_line_without_newline(self):
        out, _ = self.run_relay("printf 'tail'", every="20")
        self.assertEqual(out, "tail\n")

    def test_closed_reader(self):
        # the terminal went away after the first line: the relay reads on to the end, so the writer is never
        # blocked by a full pipe or ended by it; all three exit 0, and the outcome is still recorded
        feed = "i=0; while [ $i -lt 20000 ]; do echo \"line $i of the sitting, long enough to fill a pipe\"; i=$((i + 1)); done; echo 'SIGNED-IN a@b.edu max'"
        out, summary = self.run_relay(feed, every="20", after=" | head -n 1; echo \"status ${PIPESTATUS[*]}\"")
        self.assertEqual(out, "line 0 of the sitting, long enough to fill a pipe\nstatus 0 0 0\n")
        self.assertEqual(summary, "SIGNED-IN a@b.edu max\n\n")

    def test_exit_status(self):
        # the relay always ends 0; connect takes srun's status from PIPESTATUS[0] (the failure codes in SigninFailures)
        out, summary = self.run_relay("echo 'HPCW-LOGIN-FAILED: x'; exit 3", every="20", after="; echo \"status ${PIPESTATUS[*]}\"")
        self.assertEqual(out, "HPCW-LOGIN-FAILED: x\nstatus 3 0\n")
        self.assertEqual(summary, "\nHPCW-LOGIN-FAILED: x\n")

    @unittest.skipIf(os.name == "nt", "the login node is Linux; a Windows fork costs what it costs")
    def test_little_cpu_while_waiting(self):
        # four quiet seconds with a keepalive due every second: a blocking read woken once a second, never a spin
        rc, out, err = G.bash("TIMEFORMAT='%%3U %%3S'; time { %s; }" % self.script("sleep 4", "1", "/dev/null"))
        self.assertEqual(rc, 0, err)
        self.assertIn(out.count(self.KEEPALIVE), (3, 4), out)
        user, sys_ = (float(x) for x in err.strip().split()[-2:])
        self.assertLess(user + sys_, 0.5, "CPU seconds over four seconds of waiting, the ticker's sleeps included: %s" % err)

    def test_ticker_ends_with_what_it_ticks_for(self):
        # its process gone: at most a tick later the ticker is gone too (connect's side of the pipe was killed)
        r = G.posix(self.RELAY)
        t0 = time.monotonic()
        rc, out, err = G.bash("sleep 2 & w=$!; bash '%s' --ticks $w | od -c | head -3" % r, timeout=30)
        self.assertEqual(rc, 0, err)
        self.assertLess(time.monotonic() - t0, 6, "the ticker stopped by itself")
        self.assertIn("001   t   i   c   k  \\n", out)
        # its reader gone: the next tick finds no one and it ends
        t0 = time.monotonic()
        rc, out, err = G.bash("bash '%s' --ticks $$ | head -c 6 | od -c | head -1; echo \"status ${PIPESTATUS[0]}\"" % r, timeout=30)
        self.assertLess(time.monotonic() - t0, 6, "the ticker stopped by itself")
        self.assertRegex(out, r"status (0|141)\n$")

    @unittest.skipIf(os.name == "nt", "reads /proc")
    def test_nothing_left_behind(self):
        # after a sitting, no ticker, no sleep of its and no relay is still running
        with tempfile.TemporaryDirectory() as td:
            mark = os.path.join(td, "outcome-unique")
            rc, out, err = G.bash(self.script("echo one; sleep 1.5; echo two", "1", mark))
            self.assertEqual(rc, 0, err)
            time.sleep(1.2)  # a sleep of the ticker's own ends within its second at the latest
            left = []
            for pid in os.listdir("/proc"):
                if pid.isdigit():
                    try:
                        with open("/proc/%s/cmdline" % pid, "rb") as fh:
                            cmd = fh.read().replace(b"\0", b" ").decode("utf-8", "replace")
                    except OSError:
                        continue
                    if "relay.sh" in cmd and (mark in cmd or "--ticks" in cmd and G.posix(self.RELAY) in cmd):
                        left.append(cmd)
            self.assertEqual(left, [])

    def test_relay_starts_no_program(self):
        # the source itself, comments aside: no command substitution, no backquote, and `sleep` once (the ticker's)
        with open(self.RELAY, encoding="utf-8") as fh:
            code = "\n".join(re.sub(r"(^|\s)#.*$", "", l) for l in fh.read().splitlines()[1:])
        self.assertIsNone(re.search(r"\$\((?!\()", code), "no command substitution (arithmetic is fine): it would fork")
        self.assertNotIn("`", code, "no backquote")
        self.assertEqual(len(re.findall(r"\bsleep\b", code)), 1, "sleep only in the ticker")
        for banned in ("python", "python3", "node", "make", "md5sum", "rsync", "awk", "sed", "cat", "date"):
            self.assertIsNone(re.search(r"(^|[;&|{(]|\s)%s(\s|$)" % banned, code, re.M), "%s is not run" % banned)


if __name__ == "__main__":
    unittest.main()
