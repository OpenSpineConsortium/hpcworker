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
        self.assertEqual(bash(with_common("hpcw_agent_marker"), env={"ASHLEY_REQUEST_ID": "r1"})[0], 0)
        # no terminal on stdin under subprocess: that alone counts as "not a person"
        self.assertEqual(bash(with_common("hpcw_agent_marker"))[0], 0)


class InstallAndGuard(unittest.TestCase):
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
            for marker in ({"CLAUDECODE": "1"}, {"ASHLEY_REQUEST_ID": "x"}, {}):
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
            self.assertEqual((rc, out), (0, "2"))
            with open(os.path.join(home, "VERSION")) as fh:
                self.assertEqual(fh.read().strip(), "2")

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
            self.assertIn("upgraded 1 -> 2", out)
            self.assertIn("profile.json exists; kept", out)
            with open(os.path.join(home, "VERSION")) as fh:
                self.assertEqual(fh.read().strip(), "2")
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env=env)
            self.assertEqual((rc, out), (0, "2"))
            with open(os.path.join(home, "profile.json")) as fh:
                self.assertEqual(fh.read(), before, "an upgrade never touches the profile")
            rc, out, err = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual(rc, 0, err)
            self.assertIn("files refreshed (same version)", out)
            self.assertNotIn("upgraded", out)
            # a third run says the same again: nothing accumulates
            rc, out2, _ = bash("bash '%s/bin/hpcworker' install --profile wayne" % posix(ROOT), env=env)
            self.assertEqual((rc, out2), (0, out))

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


if __name__ == "__main__":
    unittest.main()
