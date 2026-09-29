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
    p = subprocess.run([BASH, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, env=e, cwd=cwd, **kw)
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
            with open(os.path.join(home, "consent"), "w") as fh:
                fh.write("2026-09-29T00:00:00Z\n")
            self.assertEqual(bash(with_cli(body, home))[1], "marker")
            with open(os.path.join(cfg, ".claude.json"), "w") as fh:
                fh.write('{"remoteDialogSeen":true}')
            self.assertEqual(bash(with_cli(body, home))[1], "claude_config")


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
            # the installed copy has LF endings and the tool answers from there
            with open(os.path.join(home, "bin", "hpcworker"), "rb") as fh:
                self.assertNotIn(b"\r", fh.read())
            rc, out, _ = bash("bash '%s/bin/hpcworker' version" % posix(home), env=env)
            self.assertEqual((rc, out), (0, "1"))

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
