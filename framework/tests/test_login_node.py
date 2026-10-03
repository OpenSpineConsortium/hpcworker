"""The login node's rules (framework 10, 2026-10-02). warrior's banner (/etc/motd): "The following programs
are banned from running on warrior and will be terminated on sight: bedtools, conda, CONVERGE_Studio,
fastq-dump, gcc, gfortran g++, icc, ifort, lsdyna, make, md5sum, namd2, namd3, node, pip, python, python2,
python3, python-notebook, R, rsync, zellij".

Every verb the extension types runs here against the fake scheduler of fakegrid.py, with each banned
name first on PATH as a stand-in that records the call and fails, and HPCW_PYTHON a stand-in that records
which profile.py command ran and for how long. Nothing banned is ever looked up on PATH, and since
framework 11 no line the extension types starts python3 at all (README.md, "The login node": the profile
is read and the job file and the guide are filled by lib/profile.awk and lib/profile_sh.sh, which
tests/test_profile_awk.py holds to profile.py's answers); the sign-in sitting, as long as srun's wait, is
relayed by bash (lib/relay.sh). Then the two JSON readers on this path, status_patch and prof_get,
against profile.py's answers."""
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

import fakegrid as G

BANNED = ["bedtools", "conda", "CONVERGE_Studio", "fastq-dump", "gcc", "gfortran", "g++", "icc", "ifort", "lsdyna", "make", "md5sum",
          "namd2", "namd3", "node", "pip", "python", "python2", "python3", "python-notebook", "R", "rsync", "zellij"]
# the profile.py commands each verb runs on the login node: since framework 11, none (warrior's banner
# bans python3, and Beethoven 12 reaches the login node over ssh by itself)
EXPECTED = {
    "install --shared": [],
    "claude consent --record": [],
    "connect, first": [],
    "worker status --json": [],
    "worker restrict": [],
    "worker stop": [],
    "connect, returning": [],
    "discover": [],
    "probe": [],
    "login-setup": [],
    "browser-key add": [],
    "gate version": [],
    "gate status": [],
    "gate read": [],
    "gate watch": [],
    "gate connect": [],
    "gate restrict": [],
    "gate stop": [],
    "gate forget": [],
    "profile changed, then status": [],
}
BROWSER_KEY_OK = os.name != "nt" and shutil.which("ssh-keygen")
SESSION = "203.0.113.7 51234 141.217.136.64 22"
PY_WRAP = r"""#!/bin/bash
t0=$(date +%s%N)
"$HPCW_REAL_PYTHON" "$@"; rc=$?
t1=$(date +%s%N)
case "$1" in *profile.py) what="$2";; *) what="python $1";; esac
printf '%s %s\n' "$(( (t1 - t0) / 1000000 ))" "$what" >> "$HPCW_PY_LOG"
exit $rc
"""
BANNED_SHIM = """#!/bin/bash
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$HPCW_BANNED_LOG"
exit 127
"""
LOGIN_SETUP_OK = os.name != "nt" and shutil.which("ssh-keygen") and not (hasattr(os, "geteuid") and os.geteuid() == 0)


class BannedPrograms(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        td = cls.tmp.name
        cls.g = G.Grid(os.path.join(td, "grid"))
        cls.shims = os.path.join(td, "banned")
        os.makedirs(cls.shims)
        for name in BANNED:
            p = os.path.join(cls.shims, name)
            with open(p, "w", newline="\n") as fh:
                fh.write(BANNED_SHIM)
            os.chmod(p, 0o755)
        cls.wrap = os.path.join(td, "pywrap")
        with open(cls.wrap, "w", newline="\n") as fh:
            fh.write(PY_WRAP)
        os.chmod(cls.wrap, 0o755)
        cls.real_py = G.posix(shutil.which(G.PY) or G.PY)
        cls.py_log = os.path.join(td, "python.log")
        cls.banned_log = os.path.join(td, "banned.log")
        cls.ran = {}
        os.chmod(cls.g.home, 0o700)

        def run(label, args, stdin_text=None, source=None, **extra):
            for p in (cls.py_log, cls.banned_log):
                open(p, "w").close()
            env = cls.g.env(HPCW_PYTHON=G.posix(cls.wrap), HPCW_REAL_PYTHON=cls.real_py, HPCW_PY_LOG=G.posix(cls.py_log),
                            HPCW_BANNED_LOG=G.posix(cls.banned_log), **extra)
            if source:
                script = "export PATH='%s':'%s':\"$PATH\"; source '%s' && %s" % (G.msys(cls.shims), G.msys(cls.g.bin), cls.g.tool, source)
            else:
                script = "export PATH='%s':'%s':\"$PATH\"; bash '%s' %s" % (G.msys(cls.shims), G.msys(cls.g.bin), cls.g.tool, args)
            t0 = time.monotonic()
            rc, out, err = G.bash(script, stdin_text=stdin_text, env=env)
            wall = time.monotonic() - t0
            with open(cls.py_log) as fh:
                py = [l.split(" ", 1) for l in fh.read().splitlines()]
            with open(cls.banned_log) as fh:
                banned = fh.read().splitlines()
            cls.ran[label] = {"rc": rc, "out": out, "err": err, "wall": wall, "python": [(int(ms), what) for ms, what in py], "banned": banned}

        g = cls.g
        run("install --shared", "install --shared '%s' --profile testsite --no-shell-path" % g.shared_spelled)
        run("claude consent --record", "claude consent --record %s" % G.INSTALL_ID)
        run("connect, first", "connect --profile testsite --consent %s --login always" % G.INSTALL_ID, stdin_text=G.CODE + "\n",
            HPCW_KEEPALIVE_S="1", FAKE_SRUN_DELAY="3")
        run("worker status --json", "worker status --name worker --json")
        run("worker restrict", "worker restrict --name other")
        run("worker stop", "worker stop --name worker")
        g.write_status({"state": "stopped", "job": "1", "claude_login": {"loggedIn": True, "email": "a@b.edu", "subscriptionType": "max"}}, name="old")
        run("connect, returning", "connect --profile testsite --login auto")
        run("discover", "discover")
        run("probe", "probe")
        if LOGIN_SETUP_OK:
            # in the student's own terminal (stood in for, as test_login_setup.py does), with no profile.json: every site profile is read
            os.rename(os.path.join(g.hpcw, "profile.json"), os.path.join(g.hpcw, "profile.json.aside"))
            run("login-setup", None, source="hpcw_have_terminal() { return 0; }; cmd_login_setup", SSH_CONNECTION="10.0.0.1 52341 10.0.0.2 22")
            os.rename(os.path.join(g.hpcw, "profile.json.aside"), os.path.join(g.hpcw, "profile.json"))
        # framework 11: the browser key, as Beethoven adds it over the student's first ssh sign-in, then each of
        # the gate's verbs as sshd runs the forced command (no terminal, SSH_ORIGINAL_COMMAND)
        if BROWSER_KEY_OK:
            for root, dirs, files in os.walk(os.path.dirname(g.shared)):
                for n in dirs + files:
                    p = os.path.join(root, n)
                    if not os.path.islink(p):
                        os.chmod(p, stat.S_IMODE(os.lstat(p).st_mode) & ~0o022)
            kd = os.path.join(td, "key")
            subprocess.run(["ssh-keygen", "-q", "-t", "ecdsa", "-N", "", "-C", "t", "-f", kd], check=True, stdin=subprocess.DEVNULL)
            with open(kd + ".pub") as fh:
                kt, kb, _ = fh.read().split(" ", 2)
            run("browser-key add", "browser-key add %s %s" % (kt, kb), SSH_CONNECTION=SESSION)
        g.write_status({"state": "online", "job": "7", "node": "asx15", "environment_url": "https://claude.ai/code?environment=env_01X"}, name="w2")
        run("gate version", "gate", SSH_ORIGINAL_COMMAND="version", SSH_CONNECTION=SESSION)
        run("gate status", "gate", SSH_ORIGINAL_COMMAND="status worker", SSH_CONNECTION=SESSION)
        run("gate read", "gate", SSH_ORIGINAL_COMMAND="read worker status.json", SSH_CONNECTION=SESSION)
        run("gate watch", "gate", SSH_ORIGINAL_COMMAND="watch w2", SSH_CONNECTION=SESSION)
        run("gate connect", "gate", SSH_ORIGINAL_COMMAND="connect worker testsite %s default chain" % G.INSTALL_ID, SSH_CONNECTION=SESSION)
        run("gate restrict", "gate", SSH_ORIGINAL_COMMAND="restrict worker", SSH_CONNECTION=SESSION)
        run("gate stop", "gate", SSH_ORIGINAL_COMMAND="stop worker", SSH_CONNECTION=SESSION)
        if BROWSER_KEY_OK:
            run("gate forget", "gate", SSH_ORIGINAL_COMMAND="forget", SSH_CONNECTION=SESSION)
        # a profile changed by a person (profile set, an install, a new version published): shellenv once more
        with open(os.path.join(g.hpcw, "profile.json"), "a") as fh:
            fh.write("\n")
        run("profile changed, then status", "worker status --name worker --json")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_each_verb_ran(self):
        for label, r in self.ran.items():
            self.assertEqual(r["rc"], 0, (label, r["out"], r["err"]))
        self.assertIn("HPCW-STEP signed-in st1234@wayne.edu max", self.ran["connect, first"]["out"])
        self.assertIn("HPCW-STEP signed-in a@b.edu max", self.ran["connect, returning"]["out"])
        if LOGIN_SETUP_OK:
            self.assertTrue(self.ran["login-setup"]["out"].endswith("Done. The grid will not ask again.\n"), self.ran["login-setup"])
        if BROWSER_KEY_OK:
            self.assertTrue(self.ran["browser-key add"]["out"].startswith("HPCW-KEY added SHA256:"), self.ran["browser-key add"])
            self.assertEqual(self.ran["gate forget"]["out"], "HPCW-KEY forgotten\n")
        self.assertTrue(self.ran["gate version"]["out"].startswith("HPCW-GATE ok %s " % G.CURRENT_VERSION), self.ran["gate version"])
        self.assertEqual(json.loads(self.ran["gate status"]["out"])["run"], "worker")
        self.assertEqual(json.loads(self.ran["gate read"]["out"])["run"], "worker")
        self.assertTrue(json.loads(self.ran["gate watch"]["out"].splitlines()[-1])["final"])
        self.assertIn("HPCW-STEP done", self.ran["gate connect"]["out"])
        self.assertNotIn("signin", self.ran["gate connect"]["out"])
        self.assertIn("worker worker: stopped", self.ran["gate stop"]["out"])

    def test_nothing_banned_is_looked_for(self):
        for label, r in self.ran.items():
            self.assertEqual(r["banned"], [], label)

    def test_python_only_for_the_profile_and_only_for_a_moment(self):
        for label, r in self.ran.items():
            self.assertEqual([what for _, what in r["python"]], EXPECTED[label], label)
            for ms, what in r["python"]:
                self.assertLess(ms, 3000, (label, what))

    def test_the_sitting_is_not_python(self):
        # the sitting lasted as long as srun's wait (3 s here, up to fourteen minutes on the grid), with
        # keepalives; and since framework 11 no python call at all, before it or during it
        r = self.ran["connect, first"]
        self.assertGreaterEqual(r["wall"], 3)
        self.assertGreaterEqual(r["out"].count("HPCW-LOGIN: still waiting"), 2, r["out"])
        self.assertEqual(r["python"], [])


class StatusPatch(unittest.TestCase):
    """status_patch: awk in python's place, the same answers (the guard, the values, the order of keys)."""
    QUEUED = {"version": 10, "site": "testsite", "run": "worker", "job": "40501234", "node": "", "state": "queued",
              "title": "Wayne State grid · gpu", "renewal": False, "next_job": "", "n": -1.5e3, "z": None}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.rd = self.g.rundir()
        os.makedirs(self.rd)
        self.f = os.path.join(self.rd, "status.json")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, obj):
        with open(self.f, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(obj if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")

    def patch(self, guard, *kv):
        # the values travel in a file, one a line: a Windows command line would change a backslash before a quote
        args = os.path.join(self.tmp.name, "kv")
        with open(args, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("".join(a + "\n" for a in kv))
        rc, out, err = self.g.source("mapfile -t kv < '%s'; status_patch '%s' '%s' \"${kv[@]}\"" % (G.posix(args), G.posix(self.f), guard))
        return rc

    def text(self):
        with open(self.f, encoding="utf-8") as fh:
            return fh.read()

    def raw(self):
        with open(self.f, "rb") as fh:
            return fh.read()

    def read(self):
        text = self.text()
        self.assertTrue(text.endswith("}\n") and text.count("\n") == 1, text)
        return json.loads(text, object_pairs_hook=lambda pairs: pairs)

    def test_values_and_order(self):
        self.write(self.QUEUED)
        self.assertEqual(self.patch("queued=40501234", 'scheduler_state="PENDING"', 'reason="Priority"', 'state="queued"',
                                    'message="a \\"quoted\\" \\\\ word"', "restarts=0", "flag=true", "gone=null"), 0)
        got = self.read()
        want = list(self.QUEUED.items()) + [("scheduler_state", "PENDING"), ("reason", "Priority"), ("message", 'a "quoted" \\ word'),
                                             ("restarts", 0), ("flag", True), ("gone", None)]
        self.assertEqual(got, want, "keys keep their places, new ones last")
        self.assertEqual([n for n in os.listdir(self.rd) if ".cli." in n], [], "no temporary file left")

    def test_guard(self):
        self.write(self.QUEUED)
        before = self.raw()
        self.assertEqual(self.patch("queued=40509999", 'state="stopped"'), 1, "another job")
        open(os.path.join(self.rd, "node"), "w").close()
        self.assertEqual(self.patch("queued=40501234", 'state="stopped"'), 1, "the job has a computer")
        self.assertEqual(self.patch("queued-or-none=40501234", 'state="error"'), 1)
        os.remove(os.path.join(self.rd, "node"))
        self.write(dict(self.QUEUED, state="online"))
        self.assertEqual(self.patch("queued-or-none=40501234", 'state="error"'), 1, "the job wrote its own")
        self.write(self.QUEUED)
        self.assertEqual(self.raw(), before)
        # a job id written as a number is the same job
        self.write(dict(self.QUEUED, job=40501234))
        self.assertEqual(self.patch("queued=40501234", 'state="stopped"'), 0)
        self.assertEqual(json.loads(self.text())["state"], "stopped")

    def test_absent_or_empty(self):
        self.assertEqual(self.patch("queued=40501234", 'state="stopped"'), 1, "nothing to patch")
        self.assertFalse(os.path.exists(self.f))
        self.assertEqual(self.patch("queued-or-none=40501234", 'state="error"', 'job="40501234"'), 0)
        self.assertEqual(json.loads(self.text()), {"state": "error", "job": "40501234"})
        self.write("")
        self.assertEqual(self.patch("queued-or-none=40501234", 'state="error"'), 0)
        self.assertEqual(json.loads(self.text()), {"state": "error"})

    def test_refuses_what_it_did_not_write(self):
        # a nested file (the job's own shape) and values that are not one JSON scalar: nothing written
        nested = '{"state":"queued","job":"40501234","claude_login":{"loggedIn":true}}\n'
        self.write(nested)
        self.assertEqual(self.patch("queued=40501234", 'state="stopped"'), 1)
        self.assertEqual(self.text(), nested)
        self.write(self.QUEUED)
        for bad in ('state={"a":1}', "state=[1]", "state=stopped", 'state="a"b"', "bad key=1", "=1", "noequals"):
            self.assertEqual(self.patch("queued=40501234", bad), 1, bad)
        self.assertEqual(self.read(), list(self.QUEUED.items()))
        self.write('{"state":"queued","job":"40501234"')
        self.assertEqual(self.patch("queued=40501234", 'state="stopped"'), 1, "not well formed")

    def test_preempted_guard(self):
        # framework 13: the job's own last file, objects and all, for that job and its successor, while job.id names the job
        ended = '{"version":12,"job":"40501234","state":"preempted","claude_login":{"loggedIn":true,"email":"a@b.edu","checked_at":"2026-10-03T00:40:00Z"},"tags":[1, "x"],"next_job":"40501300","updated_at":"2026-10-03T00:42:21Z"}\n'
        with open(os.path.join(self.rd, "job.id"), "w", newline="\n") as fh:
            fh.write("40501234\n")
        for guard, why in (("preempted=40501234", "no successor named in the guard"), ("preempted=40509999,40501300", "another job"),
                           ("preempted=40501234,40509999", "another successor"), ("queued=40501234", "the queued guard never takes an object")):
            self.write(ended)
            self.assertEqual(self.patch(guard, 'state="stopped"'), 1, why)
            self.assertEqual(self.text(), ended, why)
        self.write(ended.replace('"preempted"', '"online"'))
        self.assertEqual(self.patch("preempted=40501234,40501300", 'state="stopped"'), 1, "the job is not the one that ended")
        # a successor that started writes job.id first: never written over
        with open(os.path.join(self.rd, "job.id"), "w", newline="\n") as fh:
            fh.write("40501300\n")
        self.write(ended)
        self.assertEqual(self.patch("preempted=40501234,40501300", 'state="stopped"'), 1, "job.id names the successor")
        with open(os.path.join(self.rd, "job.id"), "w", newline="\n") as fh:
            fh.write("40501234\n")
        self.assertEqual(self.patch("preempted=40501234,40501300", 'state="stopped"', 'next_job=""', 'stop_reason="successor_gone"'), 0)
        got = self.read()
        self.assertEqual([k for k, _ in got], ["version", "job", "state", "claude_login", "tags", "next_job", "updated_at", "stop_reason"])
        d = json.loads(self.text())
        self.assertEqual((d["state"], d["next_job"], d["stop_reason"]), ("stopped", "", "successor_gone"))
        self.assertEqual(d["claude_login"], {"loggedIn": True, "email": "a@b.edu", "checked_at": "2026-10-03T00:40:00Z"}, "kept as written")
        self.assertEqual(d["tags"], [1, "x"])
        self.assertIn('"claude_login":{"loggedIn":true,"email":"a@b.edu","checked_at":"2026-10-03T00:40:00Z"}', self.text(), "the object's own text")
        # a file that names no successor itself (next.id did) is the job's too; one printed over lines is kept on one
        self.write('{"job": "40501234", "state": "preempted",\n "claude_login": {\n  "loggedIn": false\n }\n}\n')
        self.assertEqual(self.patch("preempted=40501234,40501300", 'state="stopped"'), 0)
        self.assertEqual(json.loads(self.text()), {"job": "40501234", "state": "stopped", "claude_login": {"loggedIn": False}})
        self.read()

    def test_top_field_reads_the_top_level_only(self):
        # framework 13: a job's claude_login has a checked_at of its own; read_field takes the first, top_field the top-level one
        self.write('{"job":"40501234","claude_login":{"checked_at":"2026-10-03T00:00:00Z"},"checked_at":"2026-10-03T01:00:00Z","n":5}\n')
        f = G.posix(self.f)
        self.assertEqual(self.g.source("read_field '%s' checked_at" % f)[1].strip(), "2026-10-03T00:00:00Z", "the trap top_field avoids")
        self.assertEqual(self.g.source("top_field '%s' checked_at" % f)[1], "2026-10-03T01:00:00Z")
        self.assertEqual(self.g.source("top_field '%s' job" % f)[1], "40501234")
        self.assertEqual(self.g.source("top_field '%s' next_job" % f)[1], "", "absent")
        self.assertEqual(self.g.source("top_field '%s' n" % f)[1], "", "not a string")
        self.assertEqual(self.g.source("top_field '%s' claude_login" % f)[1], "", "an object")


class ProfileGet(unittest.TestCase):
    """prof_get: awk for the six plain top-level strings on the way to a worker, profile.py's answer every time."""
    KEYS = ("site", "shared_install", "shared_state_dir", "submit_host", "ood_shell_host", "ood_base_url")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def same_home(self, text):
        """bash's spelling of HOME as python is handed it: on a Windows checkout Git Bash gives a native python
        C:/... for its /tmp/..., the same folder (on Linux the two are one string and nothing changes)"""
        _, bh, _ = self.g.source("printf %s \"$HOME\"")
        _, ph, _ = self.g.source("\"$HPCW_PYTHON\" -c 'import os, sys; sys.stdout.write(os.environ[\"HOME\"])'")
        return text.replace(bh, ph) if bh else text

    def both(self, path, key):
        p = G.posix(path)
        rc1, awk, err1 = self.g.source("PY=/nonexistent/python3; prof_get '%s' %s" % (p, key))
        rc2, py, err2 = self.g.source("\"$HPCW_PYTHON\" \"$LIB/profile.py\" get '%s' %s" % (p, key))
        return (rc1, self.same_home(awk)), (rc2, py)

    def test_site_profiles_without_python(self):
        # python made unreachable: the answers come from awk alone, and they are profile.py's
        for prof in ("wayne.json", "testsite.json"):
            for key in self.KEYS:
                a, p = self.both(os.path.join(self.g.shared, "profiles", prof), key)
                self.assertEqual(a, p, (prof, key))
                self.assertEqual(a[0], 0)

    def test_nesting_escapes_and_expansion(self):
        f = os.path.join(self.tmp.name, "p.json")
        with open(f, "w", encoding="utf-8", newline="\n") as fh:
            fh.write('{"x": {"site": "inner", "l": [1, {"a": [2, 3]}, "s\\"q"]}, "site": "outer", "shared_install": "/a\\/b",\n'
                     ' "submit_host": "h$USER-${HOME}x$USERNAME", "ood_base_url": null, "schema_version": 1}\n')
        for key in self.KEYS:
            rc, py, err = self.g.source("prof_get '%s' %s" % (G.posix(f), key))
            rc2, want, err2 = self.g.source("\"$HPCW_PYTHON\" \"$LIB/profile.py\" get '%s' %s" % (G.posix(f), key))
            self.assertEqual((rc, self.same_home(py)), (rc2, want), key)
        rc, out, err = self.g.source("prof_get '%s' submit_host" % G.posix(f))
        self.assertTrue(out.startswith("hst1234-"), out)
        self.assertTrue(out.rstrip("\n").endswith("x$USERNAME"), out)


if __name__ == "__main__":
    unittest.main()
