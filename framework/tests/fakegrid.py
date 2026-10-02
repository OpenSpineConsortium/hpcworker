"""A scratch grid account for the framework 10 tests: the lab's shared copy (a copy of this checkout
with a site profile, "testsite", that names it and keeps the state directory under a scratch home), and
a fake scheduler on PATH: sbatch, squeue, scancel and scontrol that keep their jobs in a file, and an
srun that plays the plain sign-in sitting (lib/login_plain.sh's lines) instead of allocating anything.
Every call is logged in <sched>/calls. Nothing here reaches a real scheduler or the network."""
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

FAKE_SBATCH = r"""#!/bin/bash
# fake sbatch: logs, refuses when <sched>/sbatch_fail holds a message, else prints the next id and lists the job PENDING
d="${FAKE_SCHED_DIR:?}"
echo "sbatch $*" >> "$d/calls"
sleep "${FAKE_SBATCH_DELAY:-0}"
if [ -s "$d/sbatch_fail" ]; then cat "$d/sbatch_fail" >&2; exit 1; fi
n=$(cat "$d/next_id" 2>/dev/null || echo 40501234); echo $((n + 1)) > "$d/next_id"
echo "$n|PENDING|${FAKE_REASON:-Priority}|N/A|" >> "$d/jobs"
echo "$n"
"""

# jobs file: ID|STATE|REASON|START|NODE, one line per job the "scheduler" still lists
FAKE_SQUEUE = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "squeue $*" >> "$d/calls"
if [ -e "$d/squeue_fail" ]; then echo "slurm_load_jobs error: Socket timed out on send/recv operation" >&2; exit 1; fi
ids=""; fmt="%i|%T|%N"
while [ $# -gt 0 ]; do case "$1" in -j) ids="$2"; shift 2;; -o) fmt="$2"; shift 2;; *) shift;; esac; done
found=0
for id in ${ids//,/ }; do
  line=$(grep "^$id|" "$d/jobs" 2>/dev/null | tail -1); [ -n "$line" ] || continue
  IFS='|' read -r jid st re sta no <<< "$line"
  found=1
  case "$fmt" in
    '%i|%T|%N') echo "$jid|$st|$no";;
    '%T|%r|%S|%N') echo "$st|$re|$sta|$no";;
    '%T|%N') echo "$st|$no";;
    *) echo "$st";;
  esac
done
if [ $found = 0 ] && [ -n "$ids" ]; then echo "slurm_load_jobs error: Invalid job id specified" >&2; exit 1; fi
exit 0
"""

FAKE_SCANCEL = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "scancel $*" >> "$d/calls"
for id in "$@"; do [ -s "$d/jobs" ] && grep -v "^$id|" "$d/jobs" > "$d/jobs.tmp"; mv -f "$d/jobs.tmp" "$d/jobs" 2>/dev/null; done
exit 0
"""

FAKE_SCONTROL = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "scontrol $*" >> "$d/calls"
[ "$1 $2" = "show job" ] && echo "JobId=$3 JobName=hpcw_worker UserId=st1234 SubmitTime=${FAKE_SUBMIT_TIME:-2026-10-01T08:00:00} StartTime=Unknown"
exit 0
"""

# srun as the sign-in sitting plays out. FAKE_SRUN: signin (the link, a code read from stdin, SIGNED-IN
# or a refusal), already (signed in at once), nonode (no computer in time), timeout (no code arrived),
# other (an unexplained failure). FAKE_SRUN_DELAY: seconds of silence first (the wait for a computer).
# FAKE_SRUN_CRLF=1: lines end in CR LF, as a pseudo-terminal sends them.
FAKE_SRUN = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "srun $*" >> "$d/calls"
e=$'\n'; [ "${FAKE_SRUN_CRLF:-0}" = 1 ] && e=$'\r\n'
p() { printf '%s%s' "$1" "$e"; }
sleep "${FAKE_SRUN_DELAY:-0}"
case "${FAKE_SRUN:-signin}" in
  nonode) echo "srun: error: Unable to allocate resources: Job not run since it would not start within the requested time" >&2; exit 1;;
esac
p "HPCW-LOGIN: on node01; checking whether you are signed in already"
case "${FAKE_SRUN:-signin}" in
  already) p "SIGNED-IN st1234@wayne.edu max"; exit 0;;
  timeout) p "HPCW-LOGIN: starting Claude Code's sign-in; waiting for the sign-in link"; p "HPCW-LOGIN-FAILED: no code arrived within 10 minutes; start the sign-in again"; exit 3;;
  other) p "HPCW-LOGIN-FAILED: the sign-in did not complete; start it again"; exit 3;;
  silentok) exit 0;;
esac
p "HPCW-LOGIN: starting Claude Code's sign-in; waiting for the sign-in link"
p "AUTH-URL: ${FAKE_AUTH_URL:-https://claude.ai/oauth/authorize?code=true}"
p "HPCW-LOGIN: paste the code from that page"
IFS= read -r -t 20 code || code=""
code="${code%$'\r'}"
if [ "$code" = "${FAKE_CODE:?}" ]; then p "HPCW-LOGIN: code received, checking"; p "SIGNED-IN st1234@wayne.edu ${FAKE_PLAN:-max}"; exit 0; fi
p "HPCW-LOGIN: code received, checking"
p "HPCW-LOGIN-FAILED: Claude Code did not accept the code; start the sign-in again and paste the whole code"
exit 3
"""


def posix(path):
    return path.replace("\\", "/")


def msys(path):
    """A path bash can put in a colon-joined list: on a Windows checkout the /c/... spelling (a drive letter would split)."""
    if os.name == "nt" and shutil.which("cygpath"):
        return subprocess.run(["cygpath", "-u", path], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
    return posix(path)


def bash(script, stdin_text=None, env=None, cwd=None, timeout=300):
    e = dict(os.environ)
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
        for name, text in (("sbatch", FAKE_SBATCH), ("squeue", FAKE_SQUEUE), ("scancel", FAKE_SCANCEL), ("scontrol", FAKE_SCONTROL), ("srun", FAKE_SRUN)):
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
