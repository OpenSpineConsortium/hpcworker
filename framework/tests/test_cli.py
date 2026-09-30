"""bin/hpcworker and the shared adapter functions, exercised through bash: the registration
parser against the exact text `claude remote-control` prints, consent read from Claude Code's own
record with the marker as fallback, the already-has-job wording, the guarded remove, the
destructive-command guard (install --force under an agent marker or without a terminal), the cheap
discover's JSON, and a full install into a temporary HPCW_HOME."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
with open(os.path.join(ROOT, "VERSION")) as _fh:
    CURRENT_VERSION = _fh.read().strip()  # the framework version the install writes (an integer; bumps move this file, not the tests)
BASH = os.environ.get("HPCW_BASH") or "bash"
PY = os.environ.get("HPCW_PYTHON") or ("python" if os.name == "nt" else sys.executable)

REGISTRATION = (
    "\x1b[2J\x1b[H\x1b[?25l"  # a cleared screen and a hidden cursor, as the TUI emits them
    "·✔︎· Connected · phone · HEAD\r\n"
    "    Capacity: 1/32 · New sessions will be created in the current directory\r\n"
    "    \x1b[1masx10-hazy-meadow\x1b[22m\r\n"
    "Continue coding in the Claude mobile app or https://claude.ai/code?environment=env_01XzAN32jsbL8W1PAFSvitBt\r\n"
    "Or ask Claude to work in this folder from your projects on claude.ai\r\n"
)


def posix(path):
    return path.replace("\\", "/")


def msys(path):
    """A path bash can put in a colon-joined list: on a Windows checkout the /c/... spelling (a drive letter would split)."""
    import shutil
    if os.name == "nt" and shutil.which("cygpath"):
        return subprocess.run(["cygpath", "-u", path], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
    return posix(path)


def bash(script, stdin_text=None, env=None, cwd=None):
    e = dict(os.environ)
    e["HPCW_PYTHON"] = PY
    # Git Bash rewrites POSIX-looking arguments (a workspace such as /ws/worker) into C:/Program Files/Git/...
    # before a native python sees them; the real tool never runs under that conversion
    e["MSYS_NO_PATHCONV"] = "1"
    e["MSYS2_ARG_CONV_EXCL"] = "*"
    e.update(env or {})
    # stdin is a pipe or /dev/null, never the terminal the suite was launched from: "no terminal" must be the same everywhere
    kw = {"input": stdin_text} if stdin_text is not None else {"stdin": subprocess.DEVNULL}
    # explicit UTF-8: a login shell without LANG (a plain ssh) would make python 3.6 encode the pipes as ASCII
    p = subprocess.run([BASH, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, encoding="utf-8", errors="replace", env=e, cwd=cwd, **kw)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


CODE_PARTS = ("bin", "lib", "jobs", "profiles")


def copy_framework(dest, version_file=True):
    """The framework's code (what a shared copy and an upload carry) copied into DEST."""
    import shutil
    os.makedirs(dest, exist_ok=True)
    for part in CODE_PARTS:
        target = os.path.join(dest, part)
        if os.path.isdir(target):
            shutil.rmtree(target)
        shutil.copytree(os.path.join(ROOT, part), target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy(os.path.join(ROOT, "README.md"), dest)
    if version_file:
        shutil.copy(os.path.join(ROOT, "VERSION"), dest)


def can_symlink(td):
    try:
        os.symlink("x", os.path.join(td, ".linktest"))
    except (OSError, NotImplementedError, AttributeError):
        return False  # Windows without the privilege
    os.unlink(os.path.join(td, ".linktest"))
    return True


def make_shared(td, link=False):
    """A lab's shared copy under TD the way tools/deploy_shared.sh lays it out: shared/v<N>, and with
    LINK a `current` link to it. Returns (the directory to name, the numbered directory)."""
    vdir = os.path.join(td, "shared", "v" + CURRENT_VERSION)
    copy_framework(vdir)
    if not link:
        return vdir, vdir
    cur = os.path.join(td, "shared", "current")
    os.symlink("v" + CURRENT_VERSION, cur)
    return cur, vdir


def with_common(func_call):
    return "source '%s/lib/adapters/common.sh' && %s" % (posix(ROOT), func_call)


def with_cli(body, hpcw_home):
    # the CLI can be sourced for its functions; HPCW_HOME points at a scratch directory so nothing of the user's is read
    return "export HPCW_HOME='%s'; source '%s/bin/hpcworker' && %s" % (posix(hpcw_home), posix(ROOT), body)


class Registration(unittest.TestCase):
    def test_exact_output_parses(self):
        rc, out, err = bash(with_common("hpcw_strip_codes | hpcw_parse_registration"), stdin_text=REGISTRATION)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, "asx10-hazy-meadow|https://claude.ai/code?environment=env_01XzAN32jsbL8W1PAFSvitBt|env_01XzAN32jsbL8W1PAFSvitBt")

    def test_redrawn_block_last_wins(self):
        text = REGISTRATION.replace("asx10-hazy-meadow", "asx10-old-name").replace("env_01XzAN32jsbL8W1PAFSvitBt", "env_first") + REGISTRATION
        rc, out, _ = bash(with_common("hpcw_strip_codes | hpcw_parse_registration"), stdin_text=text)
        self.assertEqual((rc, out), (0, "asx10-hazy-meadow|https://claude.ai/code?environment=env_01XzAN32jsbL8W1PAFSvitBt|env_01XzAN32jsbL8W1PAFSvitBt"))

    def test_nothing_yet(self):
        rc, out, _ = bash(with_common("hpcw_parse_registration"), stdin_text="Starting Remote Control...\nYou must be logged in to use Remote Control\n")
        self.assertEqual((rc, out), (0, "||"))

    def test_prose_after_capacity_is_not_a_name(self):
        rc, out, _ = bash(with_common("hpcw_parse_registration"), stdin_text="Capacity: 1/32\nSomething Else Entirely\n")
        self.assertEqual((rc, out), (0, "||"))


class Consent(unittest.TestCase):
    def test_claude_config_record_counts(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = os.path.join(td, "claude")
            os.makedirs(cfg)
            with open(os.path.join(cfg, ".claude.json"), "w") as fh:
                json.dump({"remoteDialogSeen": True, "remoteControlMachineId": "m1", "projects": {"/ws/worker": {"hasTrustDialogAccepted": True}}}, fh)
            rc, _, _ = bash(with_common("hpcw_consent_seen '%s'" % posix(cfg)))
            self.assertEqual(rc, 0)
            rc, _, _ = bash(with_common("hpcw_workspace_trusted '%s' /ws/worker" % posix(cfg)))
            self.assertEqual(rc, 0)
            rc, _, _ = bash(with_common("hpcw_workspace_trusted '%s' /ws/other" % posix(cfg)))
            self.assertNotEqual(rc, 0)
            # profile.py reads the same two booleans and prints nothing else
            p = subprocess.run([PY, "-X", "utf8", os.path.join(ROOT, "lib", "profile.py"), "consent", cfg, "/ws/worker"], stdout=subprocess.PIPE, universal_newlines=True)
            self.assertEqual(p.stdout.strip(), "remote_dialog_seen=true workspace_trusted=true")
            self.assertNotIn("m1", p.stdout)

    def test_false_or_missing_does_not_count(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = os.path.join(td, "claude")
            os.makedirs(cfg)
            rc, _, _ = bash(with_common("hpcw_consent_seen '%s'" % posix(cfg)))
            self.assertNotEqual(rc, 0)
            with open(os.path.join(cfg, ".claude.json"), "w") as fh:
                json.dump({"remoteDialogSeen": False}, fh)
            rc, _, _ = bash(with_common("hpcw_consent_seen '%s'" % posix(cfg)))
            self.assertNotEqual(rc, 0)
            rc, _, _ = bash(with_common("hpcw_consent_seen ''"))
            self.assertNotEqual(rc, 0)

    def test_cli_consent_source_order(self):
        with tempfile.TemporaryDirectory() as td:
            cfg = os.path.join(td, "claude")
            os.makedirs(cfg)
            home = os.path.join(td, "hpcw")
            os.makedirs(home)
            body = "CCD='%s'; P_consent_markers=''; consent_source" % posix(cfg)
            self.assertEqual(bash(with_cli(body, home))[1], "none")
            # the panel writes "yes <time> <install id>" through the Files API; any content counts
            with open(os.path.join(home, "consent"), "w") as fh:
                fh.write("yes 2026-09-29T05:13:00Z install-7f3a\n")
            self.assertEqual(bash(with_cli(body, home))[1], "marker")
            with open(os.path.join(cfg, ".claude.json"), "w") as fh:
                fh.write('{"remoteDialogSeen":true}')
            self.assertEqual(bash(with_cli(body, home))[1], "claude_config")


class NeedsAndHint(unittest.TestCase):
    CASES = [("need_login", "true", "login"), ("need_consent", "true", "consent"), ("starting", "false", "consent"), ("starting", "true", "nothing"),
             ("running", "false", "consent"), ("running", "true", "nothing"), ("online", "false", "nothing"), ("stopped", "false", "nothing"),
             ("preempted", "true", "nothing"), ("error", "false", "nothing")]

    def test_needs_table(self):
        rc, out, err = bash(with_common("; ".join("hpcw_needs %s %s" % (s, c) for s, c, _ in self.CASES)))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.splitlines(), [n for _, _, n in self.CASES])

    def test_hint_is_one_plain_sentence(self):
        for state, _, needs in self.CASES:
            for nxt in ("", "40500052"):
                rc, out, err = bash(with_common("hpcw_hint %s %s '%s'" % (state, needs, nxt)))
                self.assertEqual(rc, 0, err)
                self.assertEqual(out.count("\n"), 0, out)
                self.assertTrue(out.endswith("."), out)
                self.assertNotRegex(out, r"need_login|need_consent|status\.json|\$|_", "plain words only in the panel's line: " + out)
        self.assertIn("takes over", bash(with_common("hpcw_hint preempted nothing 40500052"))[1])
        self.assertIn("start the worker again", bash(with_common("hpcw_hint preempted nothing ''"))[1])
        self.assertIn("Sign in", bash(with_common("hpcw_hint need_login login ''"))[1])
        self.assertIn("Allow Remote Control", bash(with_common("hpcw_hint starting consent ''"))[1])


class PlainLogin(unittest.TestCase):
    def test_outcome_codes(self):
        # 0 signed in; 3 the sitting already printed its own failure line; anything else is the scheduler's
        with tempfile.TemporaryDirectory() as td:
            rc, out, err = bash(with_cli("plain_login_outcome 0; echo rc=$?; plain_login_outcome 3; echo rc=$?; plain_login_outcome 1; echo rc=$?", td))
            self.assertEqual(rc, 0, err)
            lines = out.splitlines()
            self.assertEqual(lines[0], "rc=0")
            self.assertEqual(lines[1], "rc=1")
            self.assertTrue(lines[2].startswith("HPCW-LOGIN-FAILED: "), lines)
            self.assertEqual(lines[3], "rc=1")

    def test_interactive_sitting_skips_remote_control_when_consent_is_on_record(self):
        # the sitting for a person at a terminal, run against a stand-in claude: with a marker file
        # (or Claude Code's own record) it never starts `claude remote-control`; without either it does
        with tempfile.TemporaryDirectory() as td:
            fake = os.path.join(td, "claude")
            with open(fake, "w") as fh:
                fh.write('#!/bin/bash\ncase "$1" in auth) echo \'{"loggedIn": true}\';; remote-control) touch "$FAKE_WITNESS";; esac\n')
            os.chmod(fake, 0o755)
            cfg = os.path.join(td, "cfg")
            ws = os.path.join(td, "ws")
            os.makedirs(cfg)
            os.makedirs(ws)
            marker = os.path.join(td, "consent")
            witness = os.path.join(td, "rc-started")
            env = {"CLAUDE_CONFIG_DIR": posix(cfg), "FAKE_WITNESS": posix(witness)}
            call = "bash -c \"$LOGIN_SITTING\" _ '%s' '%s' '' consent '%s:/nonexistent/other'" % (posix(ws), posix(fake), msys(marker))
            with open(marker, "w") as fh:
                fh.write("yes 2026-09-29T05:13:00Z install-7f3a\n")
            rc, out, err = bash(with_cli(call, td), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("already on record", out)
            self.assertFalse(os.path.exists(witness), "remote-control must not run when the marker exists")
            os.remove(marker)
            rc, out, err = bash(with_cli(call, td), env=env)
            self.assertEqual(rc, 0, err)
            self.assertTrue(os.path.exists(witness), "without a record the question is asked once: " + out)
            os.remove(witness)
            with open(os.path.join(cfg, ".claude.json"), "w") as fh:
                fh.write('{"remoteDialogSeen": true}')
            rc, out, err = bash(with_cli(call, td), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("already on record with Claude Code", out)
            self.assertFalse(os.path.exists(witness))


class WorkerStop(unittest.TestCase):
    """`worker stop` as the CLI runs it (stop_worker_run, sourced with the scheduler stubbed): the
    stop file first, a wait for the job's own stop.done, then one status call and a cancel only
    for what the scheduler still holds. HPCW_STOP_WAIT_S/HPCW_STOP_POLL_S shorten the wait here."""

    def run_stop(self, rd, home, squeue_lines, done_after=None):
        # squeue_lines: what adapter_status_many answers; done_after: seconds until a stand-in job touches stop.done
        stubs = ("adapter_status_many() { echo \"queried $1\" >> '%s/calls'; printf '%%s\\n' %s; }; "
                 "adapter_cancel() { echo \"scancel $*\" >> '%s/calls'; }; ") % (posix(rd), " ".join("'%s'" % l for l in squeue_lines) or "''", posix(rd))
        job = ""
        if done_after is not None:
            job = "( sleep %d; echo '{\"state\": \"stopped\"}' > '%s/status.json'; touch '%s/stop.done' ) & " % (done_after, posix(rd), posix(rd))
        body = stubs + job + "HPCW_STOP_WAIT_S=4 HPCW_STOP_POLL_S=1 stop_worker_run '%s' worker; wait" % posix(rd)
        rc, out, err = bash(with_cli(body, home))
        calls = ""
        if os.path.exists(os.path.join(rd, "calls")):
            with open(os.path.join(rd, "calls")) as fh:
                calls = fh.read()
        return rc, out, err, calls

    def test_job_leaves_on_its_own_no_cancel(self):
        with tempfile.TemporaryDirectory() as td:
            rd = os.path.join(td, "worker")
            os.makedirs(rd)
            with open(os.path.join(rd, "job.id"), "w") as fh:
                fh.write("40500019\n")
            with open(os.path.join(rd, "next.id"), "w") as fh:
                fh.write("40500052 40500019\n")
            # the job (stand-in) touches stop.done after 2 s; the scheduler then knows neither id
            rc, out, err, calls = self.run_stop(rd, td, ["40500019|UNKNOWN||ended or unknown", "40500052|UNKNOWN||ended or unknown"], done_after=2)
            self.assertEqual(rc, 0, err)
            self.assertTrue(os.path.exists(os.path.join(rd, "stop")), "the stop file is the job's signal and stays until the next start")
            self.assertIn("the job left on its own within", out)
            self.assertIn("the chain ended", out)
            self.assertEqual(calls.count("queried 40500019,40500052"), 1, calls)
            self.assertNotIn("scancel", calls, "nothing alive at the scheduler: no cancel")
            self.assertFalse(os.path.exists(os.path.join(rd, "next.id")))

    def test_silent_job_is_cancelled_once_with_its_successor(self):
        with tempfile.TemporaryDirectory() as td:
            rd = os.path.join(td, "worker")
            os.makedirs(rd)
            with open(os.path.join(rd, "job.id"), "w") as fh:
                fh.write("40500019\n")
            with open(os.path.join(rd, "next.id"), "w") as fh:
                fh.write("40500052 40500019\n")
            rc, out, err, calls = self.run_stop(rd, td, ["40500019|RUNNING|asx1|RUNNING", "40500052|PENDING||PENDING"])
            self.assertEqual(rc, 0, err)
            self.assertIn("no word from job 40500019 within 4s", out)
            self.assertIn("cancelled at the scheduler: 40500019 40500052", out)
            self.assertEqual(calls.strip().splitlines(), ["queried 40500019,40500052", "scancel 40500019 40500052"])

    def test_leaving_job_is_not_cancelled_again(self):
        # stop.done seen, and the scheduler already shows the job completing: no cancel lands on it
        with tempfile.TemporaryDirectory() as td:
            rd = os.path.join(td, "worker")
            os.makedirs(rd)
            with open(os.path.join(rd, "job.id"), "w") as fh:
                fh.write("40500019\n")
            rc, out, err, calls = self.run_stop(rd, td, ["40500019|RUNNING|asx1|COMPLETING"], done_after=1)
            self.assertEqual(rc, 0, err)
            self.assertIn("the job left on its own", out)
            self.assertNotIn("scancel", calls)

    def test_no_job_on_record(self):
        with tempfile.TemporaryDirectory() as td:
            rd = os.path.join(td, "worker")
            os.makedirs(rd)
            rc, out, err, calls = self.run_stop(rd, td, [])
            self.assertEqual(rc, 0, err)
            self.assertIn("no job on record", out)
            self.assertEqual(calls, "", "no scheduler call without an id")


class Wording(unittest.TestCase):
    def test_already_has_job_state(self):
        with tempfile.TemporaryDirectory() as td:
            rc, out, err = bash(with_cli("fmt_job_state 'RUNNING|asx15|RUNNING'; echo; fmt_job_state 'PENDING||PENDING'; echo; fmt_job_state 'UNKNOWN||'", td))
            self.assertEqual(rc, 0, err)
            self.assertEqual(out.splitlines(), ["RUNNING on asx15", "PENDING", "UNKNOWN"])

    def test_status_many_fallback_and_slurm_parser(self):
        rc, out, _ = bash("source '%s/lib/adapters/slurm.sh' && slurm_parse_squeue_many" % posix(ROOT), stdin_text="40496523|RUNNING|asx15\n40496600|PENDING|\n")
        self.assertEqual((rc, out), (0, "40496523|RUNNING|asx15|RUNNING\n40496600|PENDING||PENDING"))


class GuardedRemove(unittest.TestCase):
    def test_only_per_job_directories_go(self):
        with tempfile.TemporaryDirectory() as td:
            keep = os.path.join(td, "claude")
            gone = os.path.join(td, "hpcworker_123")
            gone2 = os.path.join(td, "hpcw_probe_9")
            for d in (keep, gone, gone2):
                os.makedirs(d)
            rc, _, err = bash(with_common("hpcw_rm_own_tmp '%s' '%s' '%s' '' /" % (posix(keep), posix(gone), posix(gone2))))
            self.assertEqual(rc, 0)
            self.assertTrue(os.path.isdir(keep), "a directory that is not per-job must survive")
            self.assertFalse(os.path.exists(gone))
            self.assertFalse(os.path.exists(gone2))
            self.assertIn("REFUSING", err)

    def test_agent_marker(self):
        self.assertEqual(bash(with_common("hpcw_agent_marker"), env={"CLAUDECODE": "1"})[0], 0)
        # a Beethoven for VS Code worker's request, under its names since 2026-09-30 and the older ones
        for var in ("BEETHOVEN_REQUEST_ID", "BEETHOVEN_WORKER", "ASHLEY_REQUEST_ID", "ASHLEY_WORKER"):
            self.assertEqual(bash(with_common("hpcw_agent_marker"), env={var: "r1"})[0], 0, var)
        # no terminal on stdin under subprocess: that alone counts as "not a person"
        self.assertEqual(bash(with_common("hpcw_agent_marker"))[0], 0)


class InstallAndGuard(unittest.TestCase):
    def test_install_puts_the_command_on_path_for_terminals(self):
        # the default install location gets ONE managed block in ~/.bashrc, kept across reinstalls,
        # appended after what was there; a custom HPCW_HOME (every other test here) never touches it
        begin = '# >>> hpcworker (managed; "hpcworker install" rewrites this block) >>>'
        with tempfile.TemporaryDirectory() as td:
            fake_home = os.path.join(td, "home")
            os.makedirs(fake_home)
            rc_path = os.path.join(fake_home, ".bashrc")
            with open(rc_path, "w") as fh:
                fh.write("# mine\nexport EDITOR=vi")  # no trailing newline on purpose
            env = {"HOME": posix(fake_home), "HPCW_HOME": posix(os.path.join(fake_home, ".hpcworker"))}
            for _ in range(2):
                rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
                self.assertEqual(rc, 0, err)
                self.assertIn("managed block in ~/.bashrc", out)
                with open(rc_path) as fh:
                    text = fh.read()
                self.assertEqual(text.count(begin), 1, text)
                self.assertEqual(text.count("# <<< hpcworker <<<"), 1)
                self.assertIn('export PATH="$HOME/.hpcworker/bin:$PATH"', text)
                self.assertTrue(text.startswith("# mine\nexport EDITOR=vi\n"), "what was there is kept, with a newline restored")
            # the block works: a new shell that reads ~/.bashrc finds the command
            # (the /c/... spelling on a Windows checkout: a drive letter inside a colon-joined PATH would split)
            rc, out, _ = bash("HOME='%s'; export HOME; . \"$HOME/.bashrc\"; command -v hpcworker && hpcworker version" % msys(fake_home), env={"HOME": msys(fake_home)})
            self.assertEqual(rc, 0, out)
            self.assertTrue(out.endswith(CURRENT_VERSION), out)
            # opting out leaves ~/.bashrc alone
            other = os.path.join(td, "home2")
            os.makedirs(other)
            rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne --no-shell-path" % posix(ROOT), env={"HOME": posix(other), "HPCW_HOME": posix(os.path.join(other, ".hpcworker"))})
            self.assertEqual(rc, 0, err)
            self.assertFalse(os.path.exists(os.path.join(other, ".bashrc")))
            self.assertIn("add it to your PATH", out)

    def test_install_then_force_refused_under_agent(self):
        with tempfile.TemporaryDirectory() as td:
            home = os.path.join(td, "hpcw")
            env = {"HPCW_HOME": posix(home)}
            rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("profile.json written from 'wayne'", out)
            prof = os.path.join(home, "profile.json")
            self.assertTrue(os.path.exists(prof))
            with open(prof) as fh:
                before = fh.read()
            for marker in ({"CLAUDECODE": "1"}, {"BEETHOVEN_REQUEST_ID": "x"}, {"ASHLEY_REQUEST_ID": "x"}, {}):
                e = dict(env)
                e.update(marker)
                rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne --force" % posix(ROOT), env=e)
                self.assertEqual(rc, 1, (marker, out, err))
                self.assertIn("Nothing was changed", err)
                with open(prof) as fh:
                    self.assertEqual(fh.read(), before)
            # without --force the profile is kept and nothing is refused
            rc, out, _ = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0)
            self.assertIn("kept", out)
            # the installed copy has LF endings and the tool answers from there; the sign-in sitting travels with it
            with open(os.path.join(home, "bin", "hpcworker"), "rb") as fh:
                self.assertNotIn(b"\r", fh.read())
            with open(os.path.join(home, "lib", "login_plain.sh"), "rb") as fh:
                data = fh.read()
            self.assertIn(b"hpcw_login_main", data)
            self.assertNotIn(b"\r", data)
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env=env)
            self.assertEqual((rc, out), (0, CURRENT_VERSION))
            with open(os.path.join(home, "VERSION")) as fh:
                self.assertEqual(fh.read().strip(), CURRENT_VERSION)

    def test_install_again_is_an_upgrade_or_a_refresh(self):
        # over version 1 (an older copy of the command and its VERSION file): the files are replaced and
        # the line says so; over the same version: refreshed, same wording every time; the profile stays
        with tempfile.TemporaryDirectory() as td:
            home = os.path.join(td, "hpcw")
            env = {"HPCW_HOME": posix(home)}
            os.makedirs(os.path.join(home, "bin"))
            with open(os.path.join(home, "VERSION"), "w") as fh:
                fh.write("1\n")
            with open(os.path.join(home, "bin", "hpcworker"), "w") as fh:
                fh.write("#!/bin/bash\necho 1\n")
            with open(os.path.join(home, "profile.json"), "w") as fh:
                with open(os.path.join(ROOT, "profiles", "wayne.json")) as src:
                    fh.write(src.read().replace('"display_name": "Wayne State University"', '"display_name": "Wayne State University (edited)"'))
            with open(os.path.join(home, "profile.json")) as fh:
                before = fh.read()
            rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("upgraded 1 -> %s" % CURRENT_VERSION, out)
            self.assertIn("profile.json exists; kept", out)
            with open(os.path.join(home, "VERSION")) as fh:
                self.assertEqual(fh.read().strip(), CURRENT_VERSION)
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env=env)
            self.assertEqual((rc, out), (0, CURRENT_VERSION))
            with open(os.path.join(home, "profile.json")) as fh:
                self.assertEqual(fh.read(), before, "an upgrade never touches the profile")
            rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("files refreshed (same version)", out)
            self.assertNotIn("upgraded", out)
            # a third run says the same again: nothing accumulates
            rc, out2, _ = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual((rc, out2), (0, out))

    def test_install_again_from_its_own_copy_leaves_a_shared_marker(self):
        # the extension's fallback: a full copy uploaded over the launcher, then `install` run from it;
        # the account now has its own copy, and the marker is moved aside (never deleted)
        with tempfile.TemporaryDirectory() as td:
            shared, _ = make_shared(td)
            home = os.path.join(td, "hpcw")
            env = {"HPCW_HOME": posix(home)}
            rc, out, err = bash("bash '%s/bin/hpcworker' install --shared '%s' --profile wayne" % (posix(shared), posix(shared)), env=env)
            self.assertEqual(rc, 0, err)
            copy_framework(home)  # what the upload writes: bin/, lib/, jobs/, profiles/, VERSION over the launcher
            rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(home), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("this account now uses its own copy; the shared copy at %s is no longer used" % posix(shared), out)
            self.assertFalse(os.path.exists(os.path.join(home, "shared")))
            moved = [os.path.join(home, "replaced", d, "shared") for d in os.listdir(os.path.join(home, "replaced"))]
            self.assertTrue(any(os.path.exists(m) for m in moved), moved)
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env=env)
            self.assertEqual((rc, out), (0, CURRENT_VERSION))

    def test_discover_is_json_and_cheap_by_default(self):
        with tempfile.TemporaryDirectory() as td:
            rc, out, err = bash("bash '%s/bin/hpcworker' discover" % posix(ROOT), env={"HPCW_HOME": posix(td)})
            self.assertEqual(rc, 0, err)
            d = json.loads(out)
            self.assertIs(d["full"], False)
            for k in ("scheduler", "runtime", "partitions", "env", "tools", "home_fs", "process_count"):
                self.assertIn(k, d)
            self.assertEqual(d["runtime"]["modules_from"], "modulepath")
            self.assertIsInstance(d["partitions"], list)


class SharedInstall(unittest.TestCase):
    """install --shared: the lab's copy on shared storage, a launcher and a marker in the home, no code copied."""

    def install_shared(self, shared, home, extra="--profile wayne", fake_home=None, via=None):
        env = {"HPCW_HOME": posix(home)}
        if fake_home:
            env["HOME"] = posix(fake_home)
        cmd = "bash '%s/bin/hpcworker' install --shared '%s' %s" % (posix(via or shared), posix(shared), extra)
        return bash(cmd, env=env)

    def test_launcher_marker_and_profile_only(self):
        with tempfile.TemporaryDirectory() as td:
            shared, _ = make_shared(td)
            fake_home = os.path.join(td, "home")
            os.makedirs(fake_home)
            home = os.path.join(fake_home, ".hpcworker")
            rc, out, err = self.install_shared(shared, home, fake_home=fake_home)
            self.assertEqual(rc, 0, err)
            self.assertIn("installed: this account uses the shared copy of hpcworker %s at %s (nothing copied into" % (CURRENT_VERSION, posix(shared)), out)
            self.assertIn("profile.json written from 'wayne'", out)
            # the home holds the launcher, the marker, the profile and the log folder: none of the code
            self.assertEqual(sorted(os.listdir(home)), ["bin", "log", "profile.json", "shared"])
            self.assertEqual(os.listdir(os.path.join(home, "bin")), ["hpcworker"])
            launcher = os.path.join(home, "bin", "hpcworker")
            self.assertFalse(os.path.islink(launcher), "the launcher is a file: a copy onto a link would reach the shared tree")
            with open(launcher, "rb") as fh:
                text = fh.read().decode("utf-8")
            self.assertNotIn("\r", text)
            lines = text.splitlines()
            self.assertEqual(lines[0], "#!/bin/bash")
            self.assertEqual(lines[1], '# hpcworker launcher for a shared copy (managed: "hpcworker install" rewrites this file)')
            self.assertIn("HPCW_SHARED_ROOT=%s" % posix(shared), lines)
            self.assertIn('[ -n "${HPCW_HOME:-}" ] || HPCW_HOME="$HOME/.hpcworker"', lines)
            self.assertEqual(lines[-1], 'exec "${BASH:-bash}" "$HPCW_SHARED_ROOT/bin/hpcworker" "$@"')
            with open(os.path.join(home, "shared")) as fh:
                self.assertEqual(fh.read(), posix(shared) + "\n")
            with open(os.path.join(home, "profile.json")) as fh, open(os.path.join(shared, "profiles", "wayne.json")) as src:
                self.assertEqual(fh.read(), src.read())
            # the launcher runs the shared copy, which says so
            rc, out, err = bash("bash '%s' version" % posix(launcher), env={"HPCW_HOME": posix(home)})
            self.assertEqual((rc, out), (0, "%s (shared copy at %s)" % (CURRENT_VERSION, posix(shared))), err)
            rc, out, _ = bash("bash '%s' help" % posix(launcher), env={"HPCW_HOME": posix(home)})
            self.assertEqual(rc, 0)
            self.assertIn("install --shared", out)
            # and a terminal finds it through the managed block, like a copy of one's own
            with open(os.path.join(fake_home, ".bashrc")) as fh:
                self.assertIn('export PATH="$HOME/.hpcworker/bin:$PATH"', fh.read())
            rc, out, _ = bash("HOME='%s'; export HOME; unset HPCW_HOME; . \"$HOME/.bashrc\"; hpcworker version" % msys(fake_home), env={"HOME": msys(fake_home)})
            self.assertEqual(rc, 0, out)
            self.assertTrue(out.startswith(CURRENT_VERSION + " (shared copy at "), out)

    def test_install_again_refreshes_and_changes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            shared, _ = make_shared(td)
            home = os.path.join(td, "hpcw")
            env = {"HPCW_HOME": posix(home)}
            rc, _, err = self.install_shared(shared, home)
            self.assertEqual(rc, 0, err)

            def snapshot():
                out = {}
                for name in ("bin/hpcworker", "shared", "profile.json"):
                    with open(os.path.join(home, name), "rb") as fh:
                        out[name] = fh.read()
                return out

            first = snapshot()
            # through the launcher, with and without naming the copy again: a refresh, the same words every time
            outs = []
            for cmd in ("bash '%s/bin/hpcworker' install --profile wayne" % posix(home),
                        "bash '%s/bin/hpcworker' install --profile wayne" % posix(home),
                        "bash '%s/bin/hpcworker' install --shared '%s' --profile wayne" % (posix(home), posix(shared))):
                rc, out, err = bash(cmd, env=env)
                self.assertEqual(rc, 0, err)
                self.assertIn("hpcworker %s: shared copy at %s; launcher and marker refreshed (nothing copied)" % (CURRENT_VERSION, posix(shared)), out)
                self.assertIn("profile.json exists; kept", out)
                outs.append(out)
                self.assertEqual(snapshot(), first)
            self.assertEqual(outs[0], outs[1])
            self.assertEqual(outs[1], outs[2])
            self.assertEqual(sorted(os.listdir(home)), ["bin", "log", "profile.json", "shared"])
            # run from a checkout, install keeps a shared account on its shared copy
            rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("launcher and marker refreshed", out)
            self.assertFalse(os.path.exists(os.path.join(home, "lib")))

    def test_conversion_moves_the_own_copy_aside_and_keeps_the_rest(self):
        with tempfile.TemporaryDirectory() as td:
            shared, _ = make_shared(td)
            home = os.path.join(td, "hpcw")
            env = {"HPCW_HOME": posix(home)}
            rc, _, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0, err)
            prof = os.path.join(home, "profile.json")
            with open(prof) as fh:
                edited = fh.read().replace('"display_name": "Wayne State University HPC grid"', '"display_name": "edited by me"')
            with open(prof, "w") as fh:
                fh.write(edited)
            with open(os.path.join(home, "consent"), "w") as fh:
                fh.write("yes\n")
            rc, out, err = self.install_shared(shared, home)
            self.assertEqual(rc, 0, err)
            self.assertIn("switched to the shared copy of hpcworker %s at %s; your own copy (version %s) was moved to " % (CURRENT_VERSION, posix(shared), CURRENT_VERSION), out)
            self.assertIn("(nothing deleted)", out)
            self.assertIn("profile.json exists; kept", out)
            for gone in ("lib", "jobs", "profiles", "VERSION", "README.md"):
                self.assertFalse(os.path.exists(os.path.join(home, gone)), gone)
            aside = os.path.join(home, "replaced")
            (stamp,) = os.listdir(aside)
            for kept in ("bin/hpcworker", "lib/profile.py", "lib/adapters/common.sh", "jobs/worker.sbatch.tpl", "profiles/wayne.json", "VERSION", "README.md"):
                self.assertTrue(os.path.exists(os.path.join(aside, stamp, kept)), kept)
            with open(prof) as fh:
                self.assertEqual(fh.read(), edited, "the profile is the student's: kept byte for byte")
            with open(os.path.join(home, "consent")) as fh:
                self.assertEqual(fh.read(), "yes\n")
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env=env)
            self.assertEqual((rc, out), (0, "%s (shared copy at %s)" % (CURRENT_VERSION, posix(shared))))

    def test_conversion_waits_while_a_worker_runs_from_the_own_copy(self):
        with tempfile.TemporaryDirectory() as td:
            shared, _ = make_shared(td)
            fake_home = os.path.join(td, "home")
            os.makedirs(fake_home)
            home = os.path.join(td, "hpcw")
            env = {"HPCW_HOME": posix(home), "HOME": posix(fake_home)}
            rc, _, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0, err)
            prof = os.path.join(home, "profile.json")
            with open(prof) as fh:
                p = json.load(fh)
            p["shared_state_dir"] = "$HOME/state"
            with open(prof, "w") as fh:
                json.dump(p, fh)
            rd = os.path.join(fake_home, "state", "worker")
            os.makedirs(rd)

            def attempt():
                return self.install_shared(shared, home, fake_home=fake_home)

            def still_own_copy():
                self.assertTrue(os.path.isdir(os.path.join(home, "lib")))
                self.assertFalse(os.path.exists(os.path.join(home, "shared")))

            # a queued successor
            with open(os.path.join(rd, "next.id"), "w") as fh:
                fh.write("40500020 40500019\n")
            rc, out, err = attempt()
            self.assertEqual(rc, 1, (out, err))
            self.assertIn("your worker worker (job 40500020 is queued to take over) still runs from the copy in", err)
            self.assertIn("Nothing was changed", err)
            still_own_copy()
            os.remove(os.path.join(rd, "next.id"))
            # a fresh heartbeat
            with open(os.path.join(rd, "status.json"), "w") as fh:
                fh.write('{"state": "online", "job": "40500019"}\n')
            rc, out, err = attempt()
            self.assertEqual(rc, 1, (out, err))
            self.assertIn("(job 40500019, online)", err)
            still_own_copy()
            # stopped on record: the conversion goes ahead
            with open(os.path.join(rd, "status.json"), "w") as fh:
                fh.write('{"state": "stopped", "job": "40500019"}\n')
            rc, out, err = attempt()
            self.assertEqual(rc, 0, err)
            self.assertIn("switched to the shared copy", out)

    def test_refusals_change_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            home = os.path.join(td, "hpcw")
            env = {"HPCW_HOME": posix(home)}
            # a folder that is not there (what a student outside the lab's group also gets): exit 3, nothing written
            rc, out, err = bash("bash '%s/bin/hpcworker' install --shared '%s/nope' --profile wayne" % (posix(ROOT), posix(td)), env=env)
            self.assertEqual(rc, 3, (out, err))
            self.assertIn("the shared copy at %s/nope cannot be used from this account: this account cannot open it" % posix(td), err)
            self.assertIn("Nothing was changed.", err)
            self.assertFalse(os.path.exists(home))
            # a copy without its VERSION file
            nov = os.path.join(td, "noversion")
            copy_framework(nov, version_file=False)
            rc, out, err = bash("bash '%s/bin/hpcworker' install --shared '%s' --profile wayne" % (posix(ROOT), posix(nov)), env=env)
            self.assertEqual(rc, 3, (out, err))
            self.assertIn("it has no readable VERSION file. Nothing was changed.", err)
            self.assertFalse(os.path.exists(home))
            # not an absolute path
            rc, out, err = bash("bash '%s/bin/hpcworker' install --shared shared/current" % posix(ROOT), env=env)
            self.assertEqual(rc, 3, (out, err))
            self.assertIn("it is not an absolute path", err)
            # no folder named anywhere
            rc, out, err = bash("bash '%s/bin/hpcworker' install --shared" % posix(ROOT), env=env)
            self.assertEqual(rc, 1, (out, err))
            self.assertIn("no shared copy is named here", err)
            self.assertFalse(os.path.exists(home))
            # a profile the shared copy does not have
            shared, _ = make_shared(td)
            rc, out, err = self.install_shared(shared, home, extra="--profile nosuchsite")
            self.assertEqual(rc, 1, (out, err))
            self.assertIn("has no profile named 'nosuchsite'", err)
            self.assertFalse(os.path.exists(home))
            # --shared and --own together
            rc, out, err = bash("bash '%s/bin/hpcworker' install --shared '%s' --own" % (posix(ROOT), posix(shared)), env=env)
            self.assertEqual(rc, 1)
            self.assertIn("do not go together", err)

    @unittest.skipIf(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0), "POSIX permissions (not on a Windows checkout, not as root)")
    def test_unreadable_root_is_refused(self):
        with tempfile.TemporaryDirectory() as td:
            shared, _ = make_shared(td)
            home = os.path.join(td, "hpcw")
            os.chmod(shared, 0)
            try:
                rc, out, err = bash("bash '%s/bin/hpcworker' install --shared '%s' --profile wayne" % (posix(ROOT), posix(shared)), env={"HPCW_HOME": posix(home)})
            finally:
                os.chmod(shared, 0o755)
            self.assertEqual(rc, 3, (out, err))
            self.assertIn("this account cannot open it", err)
            self.assertFalse(os.path.exists(home))

    def test_launcher_says_so_when_the_shared_copy_goes_away(self):
        with tempfile.TemporaryDirectory() as td:
            shared, _ = make_shared(td)
            home = os.path.join(td, "hpcw")
            rc, _, err = self.install_shared(shared, home)
            self.assertEqual(rc, 0, err)
            os.rename(shared, shared + ".moved")
            rc, out, err = bash("bash '%s/bin/hpcworker' version" % posix(home), env={"HPCW_HOME": posix(home)})
            self.assertEqual(rc, 3, (out, err))
            self.assertIn("the shared copy at %s cannot be read from this account" % posix(shared), err)

    def test_profile_names_the_shared_copy(self):
        # --shared with no folder: the one the site profile names (here a copy of wayne.json pointing at the test's copy)
        with tempfile.TemporaryDirectory() as td:
            shared, vdir = make_shared(td)
            site = os.path.join(vdir, "profiles", "wayne.json")
            with open(site) as fh:
                p = json.load(fh)
            self.assertEqual(p["shared_install"], "/rs/rs_grp_oschome/shared/beethoven/hpcworker/current")
            p["shared_install"] = posix(shared)
            with open(os.path.join(vdir, "profiles", "testsite.json"), "w") as fh:
                json.dump(p, fh)
            home = os.path.join(td, "hpcw")
            rc, out, err = bash("bash '%s/bin/hpcworker' install --shared --profile testsite" % posix(vdir), env={"HPCW_HOME": posix(home)})
            self.assertEqual(rc, 0, (out, err))
            with open(os.path.join(home, "shared")) as fh:
                self.assertEqual(fh.read().strip(), posix(shared))

    def test_renamed_folder_named_by_its_old_link_changes_nothing(self):
        # a lab renames its shared folder and leaves the old name as a link (Wayne State, 2026-09-30:
        # shared/ashley -> shared/beethoven); an extension built before (Beethoven 4.0.0 to 7.0.0) still runs
        # install --shared with the old spelling. The spelling on record is kept, byte for byte.
        with tempfile.TemporaryDirectory() as td:
            if not can_symlink(td):
                self.skipTest("this system cannot make symbolic links")
            new_parent = os.path.join(td, "lab", "beethoven", "hpcworker")
            os.makedirs(new_parent)
            vdir = os.path.join(new_parent, "v" + CURRENT_VERSION)
            copy_framework(vdir)
            os.symlink("v" + CURRENT_VERSION, os.path.join(new_parent, "current"))
            os.symlink("beethoven", os.path.join(td, "lab", "ashley"))
            new = posix(os.path.join(new_parent, "current"))
            old = posix(os.path.join(td, "lab", "ashley", "hpcworker", "current"))
            home = os.path.join(td, "hpcw")
            rc, out, err = self.install_shared(new, home)
            self.assertEqual(rc, 0, err)

            def snapshot():
                out = {}
                for name in ("bin/hpcworker", "shared", "profile.json"):
                    with open(os.path.join(home, name), "rb") as fh:
                        out[name] = fh.read()
                return out

            first = snapshot()
            self.assertEqual(first["shared"].decode().strip(), new)
            rc, out, err = self.install_shared(old, home, via=old)
            self.assertEqual(rc, 0, err)
            self.assertEqual(snapshot(), first, "the old spelling changed the launcher, the marker or the profile")
            # the words name the folder as it was given (an older panel hides that path), and say what was kept
            self.assertIn("hpcworker %s: shared copy at %s; launcher and marker refreshed (nothing copied) (recorded under the folder's new name)" % (CURRENT_VERSION, old), out)
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env={"HPCW_HOME": posix(home)})
            self.assertEqual(out, "%s (shared copy at %s)" % (CURRENT_VERSION, new))
            # an account first installed under the old spelling moves to the one this copy's site profile
            # names, when that is the same folder (here a copy of wayne.json pointing at the new spelling)
            with open(os.path.join(vdir, "profiles", "wayne.json")) as fh:
                p = json.load(fh)
            p["shared_install"] = new
            with open(os.path.join(vdir, "profiles", "lab.json"), "w") as fh:
                json.dump(p, fh)
            home2 = os.path.join(td, "hpcw2")
            rc, out, err = self.install_shared(old, home2, extra="--profile lab", via=old)
            self.assertEqual(rc, 0, err)
            with open(os.path.join(home2, "shared")) as fh:
                self.assertEqual(fh.read().strip(), new)
            # an account whose marker holds the old spelling (installed before the rename) moves to the new
            # one when install names it, and an older command run afterwards does not move it back
            home3 = os.path.join(td, "hpcw3")
            rc, out, err = self.install_shared(old, home3, via=old)
            self.assertEqual(rc, 0, err)
            with open(os.path.join(home3, "shared")) as fh:
                self.assertEqual(fh.read().strip(), old, "no profile names the folder: the spelling given is kept")
            rc, out, err = self.install_shared(new, home3, extra="--profile lab")
            self.assertEqual(rc, 0, err)
            self.assertIn("this account now uses the shared copy of hpcworker %s at %s (it used %s)" % (CURRENT_VERSION, new, old), out)
            with open(os.path.join(home3, "shared")) as fh:
                self.assertEqual(fh.read().strip(), new)
            rc, out, err = self.install_shared(old, home3, via=old)
            self.assertEqual(rc, 0, err)
            with open(os.path.join(home3, "shared")) as fh:
                self.assertEqual(fh.read().strip(), new)
            # a different folder under the same last name is not taken for it
            other = os.path.join(td, "other", "hpcworker")
            copy_framework(os.path.join(other, "v" + CURRENT_VERSION))
            os.symlink("v" + CURRENT_VERSION, os.path.join(other, "current"))
            rc, out, err = self.install_shared(os.path.join(other, "current"), home)
            self.assertEqual(rc, 0, err)
            with open(os.path.join(home, "shared")) as fh:
                self.assertEqual(fh.read().strip(), posix(os.path.join(other, "current")))

    def test_current_link_is_followed_one_level(self):
        # the code root is the numbered directory the link names, spelled through the same parents:
        # a job started on it keeps it, and a volume link above (/rs/... at Wayne State) is not rewritten
        with tempfile.TemporaryDirectory() as td:
            if not can_symlink(td):
                self.skipTest("this system cannot make symbolic links")
            shared, vdir = make_shared(td, link=True)
            home = os.path.join(td, "hpcw")
            rc, out, err = self.install_shared(shared, home)
            self.assertEqual(rc, 0, err)
            with open(os.path.join(home, "shared")) as fh:
                self.assertEqual(fh.read().strip(), posix(shared), "the marker names the link, not the numbered directory")
            rc, out, err = bash("export HPCW_HOME='%s'; source '%s/bin/hpcworker' && echo \"$SRC_ROOT\"" % (posix(home), posix(shared)))
            self.assertEqual((rc, out), (0, posix(vdir)), err)
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env={"HPCW_HOME": posix(home)})
            self.assertEqual(out, "%s (shared copy at %s)" % (CURRENT_VERSION, posix(shared)))
            # probe.env and the worker job name the numbered directory for the code, the home for the rest
            body = "load_profile; probe_env | grep -E '^HPCW_(HOME|CODE)='"
            rc, out, err = bash("export HPCW_HOME='%s'; source '%s/bin/hpcworker' && %s" % (posix(home), posix(shared), body))
            self.assertEqual(rc, 0, err)
            self.assertIn("HPCW_CODE=%s" % posix(vdir), out)
            self.assertIn("HPCW_HOME=%s" % posix(home), out)


if __name__ == "__main__":
    unittest.main()
