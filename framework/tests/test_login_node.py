"""The login node's rules (framework 10, 2026-10-02). warrior's banner (/etc/motd): "The following programs
are banned from running on warrior and will be terminated on sight: bedtools, conda, CONVERGE_Studio,
fastq-dump, gcc, gfortran g++, icc, ifort, lsdyna, make, md5sum, namd2, namd3, node, pip, python, python2,
python3, python-notebook, R, rsync, zellij".

Every verb the extension types runs here against the fake scheduler of fakegrid.py, with each banned
name first on PATH as a stand-in that records the call and fails, and HPCW_PYTHON a stand-in that records
which profile.py command ran and for how long. Nothing banned is ever looked up on PATH; the system
python3 runs only the short profile.py commands in EXPECTED (README.md, "The login node": reading the
site profile and filling the job file, which have no shell replacement yet), each well under a second;
and the sign-in sitting, as long as srun's wait, is relayed by bash (lib/relay.sh). Then the two JSON
readers that took python's place on this path, status_patch and prof_get, against profile.py's answers."""
import json
import os
import shutil
import stat
import tempfile
import time
import unittest

import fakegrid as G

BANNED = ["bedtools", "conda", "CONVERGE_Studio", "fastq-dump", "gcc", "gfortran", "g++", "icc", "ifort", "lsdyna", "make", "md5sum",
          "namd2", "namd3", "node", "pip", "python", "python2", "python3", "python-notebook", "R", "rsync", "zellij"]
# the profile.py commands each verb still runs on the login node, in order (none of them for more than a moment)
EXPECTED = {
    "install --shared": ["validate"],
    "claude consent --record": [],
    "connect, first": ["shellenv", "guide", "render"],
    "worker status --json": ["shellenv"],
    "worker restrict": ["shellenv"],
    "worker stop": ["shellenv"],
    "connect, returning": ["shellenv", "render"],
    "discover": [],
    "probe": ["shellenv"],
    "login-setup": [],
}
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
        # keepalives; no python call lasted a fraction of it
        r = self.ran["connect, first"]
        self.assertGreaterEqual(r["wall"], 3)
        self.assertGreaterEqual(r["out"].count("HPCW-LOGIN: still waiting"), 2, r["out"])
        self.assertLess(max(ms for ms, _ in r["python"]), 2000)


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
