"""A scratch grid account for the framework 10 tests: the lab's shared copy (a copy of this checkout
with a site profile, "testsite", that names it and keeps the state directory under a scratch home), and
a fake scheduler on PATH: sbatch, squeue, scancel and scontrol that keep their jobs in a file, an
srun that plays the plain sign-in sitting (lib/login_plain.sh's lines) instead of allocating anything,
and a sacct and sinfo that print what a test plants (FAKE_SACCT, FAKE_SINFO) for `queue report` and diag.
Every call is logged in <sched>/calls; sacct's and sinfo's also in <sched>/argv, each argument apart.
Nothing here reaches a real scheduler or the network."""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
with open(os.path.join(ROOT, "VERSION")) as _fh:
    CURRENT_VERSION = _fh.read().strip()
BASH = os.environ.get("HPCW_BASH") or "bash"
PY = os.environ.get("HPCW_PYTHON") or ("python" if os.name == "nt" else sys.executable)
CODE = "GOODCODE#0123456789abcdef"
INSTALL_ID = "0123456789abcdef0123456789abcdef"
AUTH_URL = "https://claude.ai/oauth/authorize?code=true&client_id=x&state=y"

# The fake scheduler: sbatch, squeue, scancel, scontrol, srun, sacct and sinfo, each a script of its own under
# interface/testbed/fakebin/, which the repository publishes (interface/INTERFACE.json, the export "testbed") so
# another repository's test stands the same scheduler up without reading this file. Each script's head says what
# it plays and which FAKE_* knobs it takes; every call is logged in <sched>/calls, sacct's and sinfo's also in
# <sched>/argv, each argument apart (Grid.argvs reads it back).
TESTBED = os.path.join(os.path.dirname(ROOT), "interface", "testbed", "fakebin")


def _fake(name):
    with open(os.path.join(TESTBED, name), encoding="utf-8", newline="") as fh:
        return fh.read()


FAKE_SBATCH, FAKE_SQUEUE, FAKE_SCANCEL, FAKE_SCONTROL, FAKE_SRUN, FAKE_SACCT, FAKE_SINFO = (
    _fake(n) for n in ("sbatch", "squeue", "scancel", "scontrol", "srun", "sacct", "sinfo"))


def posix(path):
    return path.replace("\\", "/")


def msys(path):
    """A path bash can put in a colon-joined list: on a Windows checkout the /c/... spelling (a drive letter would split)."""
    if os.name == "nt" and shutil.which("cygpath"):
        return subprocess.run(["cygpath", "-u", path], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
    return posix(path)


def bash(script, stdin_text=None, env=None, cwd=None, timeout=300):
    e = dict(os.environ)
    # every stand-in plays a login-node call, so what the suite's own surroundings would add is dropped:
    # a run inside a compute-node job carried SLURM_JOB_ID into `browser-key add`, which rightly refuses
    # a batch job (job 40554683, 2026-10-03), and a run under Claude Code carried its agent markers into
    # every verb with a person's refusal. A test that wants one sets it through env=, which wins below.
    for k in ("SLURM_JOB_ID", "PBS_JOBID", "LSB_JOBID", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "AI_AGENT",
              "BEETHOVEN_REQUEST_ID", "BEETHOVEN_WORKER", "ASHLEY_REQUEST_ID", "ASHLEY_WORKER", "ASHLEY_JOB",
              "HPCW_AGENT", "HPCW_GATE", "HPCW_GATE_SLOT", "SSH_ORIGINAL_COMMAND", "SSH_CONNECTION"):
        e.pop(k, None)
    e["HPCW_PYTHON"] = PY
    e["MSYS_NO_PATHCONV"] = "1"
    e["MSYS2_ARG_CONV_EXCL"] = "*"
    e.update(env or {})
    kw = {"input": stdin_text} if stdin_text is not None else {"stdin": subprocess.DEVNULL}
    p = subprocess.run([BASH, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, encoding="utf-8",
                       errors="replace", env=e, cwd=cwd, timeout=timeout, **kw)
    return p.returncode, p.stdout, p.stderr


def copy_framework(dest):
    os.makedirs(dest, exist_ok=True)
    for part in ("bin", "lib", "jobs", "profiles"):
        target = os.path.join(dest, part)
        if os.path.isdir(target):
            shutil.rmtree(target)
        shutil.copytree(os.path.join(ROOT, part), target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy(os.path.join(ROOT, "README.md"), dest)
    shutil.copy(os.path.join(ROOT, "VERSION"), dest)


class Grid(object):
    """One scratch account under TD: home (HOME), ~/.hpcworker (HPCW_HOME, empty until set up), the lab's
    shared copy at TD/shared/v<N> with profiles/testsite.json naming it, and the fake scheduler."""

    def __init__(self, td, profile_edit=None):
        self.td = td
        self.home = os.path.join(td, "home")
        os.makedirs(self.home)
        self.hpcw = os.path.join(self.home, ".hpcworker")
        self.shared = os.path.join(td, "shared", "v" + CURRENT_VERSION)
        copy_framework(self.shared)
        # the shared copy as the profile names it: an absolute POSIX path, which on a Windows checkout is
        # Git Bash's /c/... spelling (profile validate refuses a drive letter, as it would on a cluster)
        self.shared_spelled = msys(self.shared)
        with open(os.path.join(self.shared, "profiles", "wayne.json"), encoding="utf-8") as fh:
            p = json.load(fh)
        p["site"] = "testsite"
        p["shared_install"] = self.shared_spelled
        p["shared_state_dir"] = "$HOME/state"
        # no binds: no job runs in these tests, and on a Windows checkout Git Bash hands a native python
        # a backslashed HOME, which the render would rightly refuse inside a bind list
        p["binds"] = []
        p["claude_config_dir"] = "$HOME/cfg"
        p["consent_markers"] = []
        if profile_edit:
            profile_edit(p)
        with open(os.path.join(self.shared, "profiles", "testsite.json"), "w", encoding="utf-8") as fh:
            json.dump(p, fh, indent=1)
        self.state = os.path.join(self.home, "state")
        self.sched = os.path.join(td, "sched")
        os.makedirs(self.sched)
        self.bin = os.path.join(td, "fakebin")
        os.makedirs(self.bin)
        for name, text in (("sbatch", FAKE_SBATCH), ("squeue", FAKE_SQUEUE), ("scancel", FAKE_SCANCEL), ("scontrol", FAKE_SCONTROL), ("srun", FAKE_SRUN),
                           ("sacct", FAKE_SACCT), ("sinfo", FAKE_SINFO)):
            path = os.path.join(self.bin, name)
            with open(path, "w", newline="\n") as fh:
                fh.write(text)
            os.chmod(path, 0o755)

    @property
    def tool(self):
        return posix(os.path.join(self.shared, "bin", "hpcworker"))

    def env(self, **extra):
        e = {"HOME": posix(self.home), "HPCW_HOME": posix(self.hpcw), "FAKE_SCHED_DIR": posix(self.sched), "FAKE_CODE": CODE, "USER": "st1234"}
        e.update(extra)
        return e

    def run(self, args, stdin_text=None, timeout=300, **extra):
        """bash <shared>/bin/hpcworker ARGS with the fake scheduler first on PATH -> (rc, stdout, stderr)"""
        script = "export PATH='%s':\"$PATH\"; bash '%s' %s" % (msys(self.bin), self.tool, args)
        return bash(script, stdin_text=stdin_text, env=self.env(**extra), timeout=timeout)

    def source(self, body, stdin_text=None, **extra):
        """BODY with the shared copy's CLI sourced for its functions (HPCW_HOME the scratch one)"""
        script = "export PATH='%s':\"$PATH\"; source '%s' && %s" % (msys(self.bin), self.tool, body)
        return bash(script, stdin_text=stdin_text, env=self.env(**extra))

    def calls(self):
        p = os.path.join(self.sched, "calls")
        if not os.path.exists(p):
            return []
        with open(p) as fh:
            return fh.read().splitlines()

    def argvs(self):
        """the calls the fake sacct and sinfo logged with each argument kept apart, in order:
        [{"cmd": NAME, "argv": [ARG, ...], "TZ": ..., "SLURM_TIME_FORMAT": ...}]"""
        p = os.path.join(self.sched, "argv")
        if not os.path.exists(p):
            return []
        with open(p, newline="") as fh:
            lines = fh.read().split("\n")[:-1]
        out, i = [], 0
        while i < len(lines):
            n = int(lines[i + 3])
            out.append({"cmd": lines[i], "TZ": lines[i + 1], "SLURM_TIME_FORMAT": lines[i + 2], "argv": lines[i + 4:i + 4 + n]})
            i += 4 + n
        return out

    def jobs(self, lines=None):
        p = os.path.join(self.sched, "jobs")
        if lines is not None:
            with open(p, "w", newline="\n") as fh:
                fh.write("".join(l + "\n" for l in lines))
        if not os.path.exists(p):
            return []
        with open(p) as fh:
            return fh.read().splitlines()

    def rundir(self, name="worker"):
        return os.path.join(self.state, name)

    def status(self, name="worker"):
        with open(os.path.join(self.rundir(name), "status.json"), encoding="utf-8") as fh:
            return json.load(fh)

    def write_status(self, obj, name="worker", mtime=None):
        rd = self.rundir(name)
        os.makedirs(rd, exist_ok=True)
        p = os.path.join(rd, "status.json")
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(obj) + "\n")
        if mtime is not None:
            os.utime(p, (mtime, mtime))

    def progress(self, name="worker"):
        p = os.path.join(self.rundir(name), "progress.log")
        if not os.path.exists(p):
            return []
        with open(p, encoding="utf-8") as fh:
            return fh.read().splitlines()

    def setup(self):
        """the account set up for the shared copy, as moment 6's install line leaves it"""
        rc, out, err = bash("bash '%s' install --shared '%s' --profile testsite --no-shell-path" % (self.tool, self.shared_spelled), env=self.env())
        assert rc == 0, (out, err)
