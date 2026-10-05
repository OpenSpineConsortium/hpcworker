"""A scratch grid account for the framework 10 tests: the lab's shared copy (a copy of this checkout
with a site profile, "testsite", that names it and keeps the state directory under a scratch home), and
a fake scheduler on PATH: sbatch, squeue, scancel and scontrol that keep their jobs in a file, an
srun that plays the plain sign-in sitting (lib/login_plain.sh's lines) instead of allocating anything,
and a sacct and sinfo that print what a test plants (FAKE_SACCT, FAKE_SINFO) for `queue report` and diag.
Every call is logged in <sched>/calls; sacct's and sinfo's also in <sched>/argv, each argument apart.
Framework 18: sbatch also records each job it takes in <sched>/submitted (ID|NAME|PARTITION|QOS|DEPENDENCY, from
the job file's #SBATCH lines and its own command line), so a test sees which queue each candidate asked; it
refuses one partition when FAKE_SBATCH_REFUSE_PARTITION names it, runs FAKE_SBATCH_HOOK once an id is given
(a candidate that gets a computer before the next sbatch), answers --test-only, and with FAKE_SINGLETON=1 holds
a job with singleton behind an earlier one of its name (Reason Dependency), as Slurm 23.02 does; squeue
answers -u/-n/-t (the winner's sweep) and the %i|%T|%r|%S|%N form; scancel forgets no id that
FAKE_SCANCEL_IGNORE names ("all" for every one: a cancel that was lost). Nothing here reaches a real scheduler or the network."""
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
# what the job asks: the job file's #SBATCH lines, then the command line (the job file is the last word)
script="" dep="" part="" qos="" testonly=0 prev=""
for a in "$@"; do
  case "$prev" in -p) part="$a";; -q) qos="$a";; esac
  case "$a" in --test-only) testonly=1;; --dependency=*) dep="${a#--dependency=}";; esac
  prev="$a"; script="$a"
done
if [ "$testonly" = 1 ]; then echo "sbatch: Job 99999999 to start at 2026-10-05T10:00:00 using 2 processors on nodes asx1 in partition ${part%%,*}" >&2; exit 0; fi
name=""; fdep=""
if [ -f "$script" ]; then
  name=$(sed -n 's/^#SBATCH --job-name=//p' "$script" | head -1); part=$(sed -n 's/^#SBATCH --partition=//p' "$script" | head -1)
  qos=$(sed -n 's/^#SBATCH --qos=//p' "$script" | head -1); fdep=$(sed -n 's/^#SBATCH --dependency=//p' "$script" | head -1)
fi
[ -n "$dep" ] || dep="$fdep"
if [ -n "${FAKE_SBATCH_REFUSE_PARTITION:-}" ] && [ "$part" = "$FAKE_SBATCH_REFUSE_PARTITION" ]; then
  echo "sbatch: error: Batch job submission failed: Invalid qos specification" >&2; exit 1
fi
n=$(cat "$d/next_id" 2>/dev/null || echo 40501234); echo $((n + 1)) > "$d/next_id"
reason="${FAKE_REASON:-Priority}"
# Slurm 23.02's singleton: held while any other job of the name is running or was submitted before it and is still in line
if [ "${FAKE_SINGLETON:-0}" = 1 ] && [ -n "$name" ] && case ",$dep," in *,singleton,*) true;; *) false;; esac; then
  while IFS='|' read -r oid oname _; do
    [ "$oname" = "$name" ] && grep -q -E "^$oid\|(PENDING|RUNNING)\|" "$d/jobs" 2>/dev/null && reason=Dependency
  done < <(cat "$d/submitted" 2>/dev/null)
fi
echo "$n|PENDING|$reason|N/A|" >> "$d/jobs"
echo "$n|$name|$part|$qos|$dep" >> "$d/submitted"
[ -n "${FAKE_SBATCH_HOOK:-}" ] && FAKE_ID="$n" bash -c "$FAKE_SBATCH_HOOK"
echo "$n"
"""

# jobs file: ID|STATE|REASON|START|NODE, one line per job the "scheduler" still lists
FAKE_SQUEUE = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "squeue $*" >> "$d/calls"
if [ -e "$d/squeue_fail" ]; then echo "slurm_load_jobs error: Socket timed out on send/recv operation" >&2; exit 1; fi
ids=""; fmt="%i|%T|%N"; jname=""; states=""
while [ $# -gt 0 ]; do case "$1" in -j) ids="$2"; shift 2;; -o) fmt="$2"; shift 2;; -n) jname="$2"; shift 2;; -t) states="$2"; shift 2;; -u) shift 2;; *) shift;; esac; done
# -n NAME [-t STATES]: this account's jobs of that name (framework 18's sweep), from what sbatch recorded
if [ -n "$jname" ] && [ -z "$ids" ]; then
  while IFS='|' read -r jid st re sta no; do
    grep -q -E "^$jid\|$jname\|" "$d/submitted" 2>/dev/null || continue
    [ -z "$states" ] || case ",$states," in *",$st,"*) ;; *) continue;; esac
    case "$fmt" in '%i') echo "$jid";; *) echo "$jid|$st|$no";; esac
  done < <(cat "$d/jobs" 2>/dev/null)
  exit 0
fi
found=0
for id in ${ids//,/ }; do
  line=$(grep "^$id|" "$d/jobs" 2>/dev/null | tail -1); [ -n "$line" ] || continue
  IFS='|' read -r jid st re sta no <<< "$line"
  found=1
  case "$fmt" in
    '%i|%T|%N') echo "$jid|$st|$no";;
    '%i|%T|%r|%S|%N') echo "$jid|$st|$re|$sta|$no";;
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
# FAKE_SCANCEL_IGNORE: ids (space-separated, or "all") whose cancel does not take, as a lost scancel
for id in "$@"; do
  case " ${FAKE_SCANCEL_IGNORE:-} " in *" all "*|*" $id "*) continue;; esac
  [ -s "$d/jobs" ] && grep -v "^$id|" "$d/jobs" > "$d/jobs.tmp"; mv -f "$d/jobs.tmp" "$d/jobs" 2>/dev/null
done
exit 0
"""

FAKE_SCONTROL = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "scontrol $*" >> "$d/calls"
[ "$1 $2" = "show job" ] && echo "JobId=$3 JobName=hpcw_worker UserId=st1234 SubmitTime=${FAKE_SUBMIT_TIME:-2026-10-01T08:00:00} StartTime=Unknown"
exit 0
"""

# Both also log each call to <sched>/argv with its arguments kept apart, which "calls" (joined by spaces) cannot: a
# record is the name, TZ and SLURM_TIME_FORMAT as the program saw them ("(unset)" when not set), the number of
# arguments, then each argument on a line of its own (Grid.argvs reads it back).
FAKE_ARGV_LOG = r"""{ printf '%s\n%s\n%s\n%d\n' "${0##*/}" "${TZ-(unset)}" "${SLURM_TIME_FORMAT-(unset)}" $#; [ $# -gt 0 ] && printf '%s\n' "$@"; } >> "$d/argv"
"""

# the account's history, for `queue report`: FAKE_SACCT holds the records sacct prints (its -P lines, planted by
# the test; nothing when unset, as for an account with no jobs), FAKE_SACCT_FAIL the message it fails with instead.
# A field written @SECONDS is an instant, printed the way sacct prints a time: in the zone of its own environment's TZ
# and in the form SLURM_TIME_FORMAT names (standard or unset: YYYY-MM-DDTHH:MM:SS; relative: a short day and time;
# anything else: a date format), so a test sees what a caller's zone and format would do to the report
FAKE_SACCT = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "sacct $*" >> "$d/calls"
""" + FAKE_ARGV_LOG + r"""if [ -n "${FAKE_SACCT_FAIL:-}" ]; then echo "$FAKE_SACCT_FAIL" >&2; exit 1; fi
[ -n "${FAKE_SACCT:-}" ] || exit 0
case "${SLURM_TIME_FORMAT:-standard}" in standard) f='+%Y-%m-%dT%H:%M:%S';; relative) f='+%d %b %H:%M';; *) f="+$SLURM_TIME_FORMAT";; esac
while IFS= read -r line; do
  out=""
  while [[ "$line" =~ ^([^@]*)@([0-9]+)(.*)$ ]]; do out="$out${BASH_REMATCH[1]}$(date -d "@${BASH_REMATCH[2]}" "$f")"; line="${BASH_REMATCH[3]}"; done
  printf '%s%s\n' "$out" "$line"
done <<< "$FAKE_SACCT"
exit 0
"""

# the partitions, for `queue report --limits` and diag's partition check: FAKE_SINFO holds the lines sinfo prints (nothing when unset)
FAKE_SINFO = r"""#!/bin/bash
d="${FAKE_SCHED_DIR:?}"
echo "sinfo $*" >> "$d/calls"
""" + FAKE_ARGV_LOG + r"""[ -n "${FAKE_SINFO:-}" ] && printf '%s\n' "$FAKE_SINFO"
exit 0
"""

# srun as the sign-in sitting plays out. FAKE_SRUN: signin (the link, a code read from stdin, SIGNED-IN
# or a refusal), already (signed in at once), nonode (no computer in time), timeout (no code arrived),
# other (an unexplained failure), billed (framework 17: Claude Code offered a sign-in that bills by use),
# othersignin (framework 17: already signed in, not with a Claude subscription). FAKE_SRUN_DELAY:
# seconds of silence first (the wait for a computer).
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
  billed) p "HPCW-LOGIN: starting Claude Code's sign-in; waiting for the sign-in link"; p "HPCW-LOGIN-FAILED: Claude Code offered a sign-in that bills by use instead of your Claude subscription, and Beethoven signs in only with a Claude subscription; start the sign-in again, and if it repeats ask your lead"; exit 3;;
  othersignin) p "HPCW-LOGIN-FAILED: Claude Code on the grid is signed in in a way that bills by use or is not a Claude subscription, and Beethoven never runs on that; ask your lead to help you sign in again with your Claude subscription"; exit 3;;
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

    def submitted(self):
        """framework 18: what sbatch took, in order: [{"id", "name", "partition", "qos", "dependency"}]"""
        p = os.path.join(self.sched, "submitted")
        if not os.path.exists(p):
            return []
        with open(p) as fh:
            rows = [l.split("|") for l in fh.read().splitlines()]
        return [dict(zip(("id", "name", "partition", "qos", "dependency"), r)) for r in rows]

    def start(self, jid, node="node01"):
        """the scheduler gives job JID a computer: RUNNING on NODE. With singleton, refused (AssertionError) while
        another job of its name is running or was submitted before it and is still in line, as Slurm 23.02 holds it"""
        jid = str(jid)
        sub = dict((r["id"], r) for r in self.submitted())
        jobs = self.jobs()
        mine = sub.get(jid)
        if mine and "singleton" in mine["dependency"].split(","):
            for line in jobs:
                oid, st = line.split("|")[:2]
                if oid != jid and sub.get(oid, {}).get("name") == mine["name"] and (st == "RUNNING" or (st == "PENDING" and int(oid) < int(jid))):
                    raise AssertionError("singleton holds job %s behind job %s (%s)" % (jid, oid, st))
        self.jobs([("%s|RUNNING|None|N/A|%s" % (jid, node)) if l.split("|")[0] == jid else l for l in jobs])

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
