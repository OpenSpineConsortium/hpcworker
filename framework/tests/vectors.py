"""The contract's vectors (interface/contract/vectors/): what the real writer prints and writes, run
against the stand-ins of fakegrid.py and test_job.py and kept in the repository, so a client tests its
parser against output this framework actually produced instead of a hand-written copy of it.
test_interface.py runs every scenario again and fails when a vector moved; after a change to what the
framework prints or writes on purpose, `python3 framework/tests/vectors.py --write` rewrites them, and
the change is reviewed with the code that caused it.

A vector is one JSON file: a command's exit status and its lines ("kind": "command"), or a file the
framework wrote ("kind": "file", a JSON document as "json", a text file as "lines"). The scratch
folder becomes /scratch and every UTC time 2026-10-01T12:00:00Z, so a vector is the same on every
machine; a scenario that needs what this machine lacks (the job needs tmux or script) is left out of
the comparison and never deleted from the folder."""
import json
import os
import re
import subprocess
import sys
import tempfile

import fakegrid as G

ROOT = os.path.dirname(G.ROOT)
VECTORS = os.path.join(ROOT, "interface", "contract", "vectors")
SCRATCH = "/scratch"
UTC = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")
FIXED_UTC = "2026-10-01T12:00:00Z"
MINUTES = re.compile(r"\b[0-9]+ min (so far|after you asked)")
# values that belong to the machine the scenario ran on, not to the framework: the job's process id and the
# node it ran on (`hostname -s`); a non-empty value becomes a fixed one, an empty one stays empty
VOLATILE = {"pid": 4242, "node": "node01"}


def _text(s, scratch):
    s = s.replace("\\", "/").replace(scratch, SCRATCH)
    return MINUTES.sub(lambda m: "0 min " + m.group(1), UTC.sub(FIXED_UTC, s))


def normal(value, scratch):
    """the value with the scratch folder and every time made fixed, keys in the writer's order"""
    if isinstance(value, dict):
        return dict((k, VOLATILE[k] if k in VOLATILE and value[k] not in ("", None) else normal(value[k], scratch)) for k in value)
    if isinstance(value, list):
        return [normal(v, scratch) for v in value]
    if isinstance(value, str):
        return _text(value, scratch)
    return value


def command(name, summary, argv, rc, out, err, scratch, stdin=None):
    v = {"vector": name, "kind": "command", "summary": summary, "command": argv}
    if stdin is not None:
        v["stdin"] = stdin
    v.update(exit=rc, stdout=[_text(l, scratch) for l in out.splitlines()], stderr=[_text(l, scratch) for l in err.splitlines()])
    return v


def json_file(name, summary, path, scratch):
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    return {"vector": name, "kind": "file", "summary": summary, "file": os.path.basename(path), "json": normal(doc, scratch)}


def lines_file(name, summary, path, scratch):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    return {"vector": name, "kind": "file", "summary": summary, "file": os.path.basename(path), "lines": [_text(l, scratch) for l in lines]}


def _connect(g, flags, stdin=G.CODE + "\n", **env):
    return g.run("connect --profile testsite " + flags, stdin_text=stdin, **env)


def connect_vectors():
    """connect's HPCW-STEP lines in each order the contract allows, and each failure code"""
    out = []
    shown = "hpcworker connect --profile testsite "
    code = "<the code pasted from Claude's page>"

    def one(name, summary, flags, prepare=None, stdin=G.CODE + "\n", shown_stdin=code, profile_edit=None, **env):
        with tempfile.TemporaryDirectory() as td:
            g = G.Grid(td, profile_edit=profile_edit)
            if prepare:
                prepare(g)
            rc, o, e = _connect(g, flags, stdin=stdin, **env)
            out.append(command(name, summary, shown + flags.replace(G.INSTALL_ID, "<install id>"), rc, o, e, td, stdin=shown_stdin))
            return g, td

    def returning(g):
        g.setup()
        g.write_status({"version": 17, "run": "worker", "job": "40500019", "state": "stopped",
                        "claude_login": {"loggedIn": True, "email": "alex@wayne.edu", "subscriptionType": "max", "checked_at": FIXED_UTC}})

    def kept(g):
        g.setup()
        os.makedirs(g.rundir())
        with open(os.path.join(g.rundir(), "job.id"), "w") as fh:
            fh.write("40500019\n")
        with open(os.path.join(g.rundir(), "next.id"), "w") as fh:
            fh.write("40500052 40500019\n")
        g.jobs(["40500019|RUNNING|None|2026-10-01T08:00:00|node03", "40500052|PENDING|Dependency|N/A|"])

    def refused(g):
        with open(os.path.join(g.sched, "sbatch_fail"), "w") as fh:
            fh.write("sbatch: error: Batch job submission failed: Invalid qos specification\n")

    def restricted(g):
        g.setup()
        ws = os.path.join(g.state, "workspaces", "worker")
        os.makedirs(ws)
        open(os.path.join(ws, ".restricted"), "w").close()

    def signed_in_elsewhere(g):
        g.setup()

    one("connect-first-run", "A first run: the account set up, the answer recorded, the worker queued, the sign-in sitting", "--consent %s" % G.INSTALL_ID)
    one("connect-returning", "A returning run signed in on the grid: no sitting", "--consent %s" % G.INSTALL_ID, prepare=returning, shown_stdin=None, stdin="")
    one("connect-kept", "A job already in line is kept and nothing is submitted", "--login never", prepare=kept, shown_stdin=None, stdin="")
    one("connect-never", "--login never: queued and done", "--login never", prepare=signed_in_elsewhere, shown_stdin=None, stdin="")
    one("connect-failed-usage", "A flag connect does not take", "--login fresh", shown_stdin=None, stdin="")
    one("connect-failed-setup", "The lab's copy cannot be used from this account", "--login never", shown_stdin=None, stdin="",
        profile_edit=lambda p: p.update(shared_install="/nonexistent/beethoven/hpcworker/current"))
    one("connect-failed-restricted", "The workspace is marked restricted", "--consent %s" % G.INSTALL_ID, prepare=restricted, shown_stdin=None, stdin="")
    one("connect-failed-refused", "The scheduler refused the job", "--consent %s" % G.INSTALL_ID, prepare=refused, shown_stdin=None, stdin="")
    one("connect-failed-signin-code", "Claude Code did not accept the pasted code", "--login always", stdin="WRONGCODE12345\n", shown_stdin="<a code Claude Code refuses>")
    one("connect-failed-signin-node", "No computer for the sign-in in time", "--login always", shown_stdin=None, stdin="", FAKE_SRUN="nonode")
    one("connect-failed-signin-timeout", "No code arrived in time", "--login always", shown_stdin=None, stdin="", FAKE_SRUN="timeout")
    one("connect-failed-signin-billed", "Claude Code offered a sign-in that bills by use; nothing was opened", "--login always", shown_stdin=None, stdin="", FAKE_SRUN="billed")
    one("connect-failed-signin-method", "Claude Code on the grid is signed in, not with a Claude subscription", "--login always", shown_stdin=None, stdin="", FAKE_SRUN="othersignin")
    one("connect-failed-signin", "The sitting ended without saying why", "--login always", shown_stdin=None, stdin="", FAKE_SRUN="silentok")
    return out


def queued_vectors():
    """what `worker start` leaves while the worker waits in line, and `worker status --json` then"""
    with tempfile.TemporaryDirectory() as td:
        g = G.Grid(td)
        rc, o, e = _connect(g, "--login never", stdin="")
        assert rc == 0, (o, e)
        rd = g.rundir()
        vs = [json_file("status-queued", "status.json as `worker start` writes it, the worker in line", os.path.join(rd, "status.json"), td),
              lines_file("progress-queued", "progress.log after `worker start`", os.path.join(rd, "progress.log"), td)]
        rc, o, e = g.run("worker status --name worker --json")
        vs.append(command("worker-status-queued", "`worker status --json` while queued: one scheduler call, its answer in `scheduler`",
                          "hpcworker worker status --name worker --json", rc, o, e, td))
        rc, o, e = g.run("worker status --name nosuch --json")
        vs.append(command("worker-status-missing", "`worker status --json` for a worker that was never started",
                          "hpcworker worker status --name nosuch --json", rc, o, e, td))
        return vs


def job_vectors():
    """the job's own files while it is online and after a stop (needs what test_job.py needs)"""
    import test_job as J
    if not J.LINUX:
        return None
    j = J.Job("test_online_then_stopped")
    j.setUp()
    try:
        s, c, progress, _ = j.run_online(J.ENV_URL)
        td = j.td
        online_s = {"vector": "status-online", "kind": "file", "summary": "status.json as the job writes it once Remote Control registered",
                    "file": "status.json", "json": normal(s, td)}
        online_c = {"vector": "connection-online", "kind": "file", "summary": "connection.json as the job writes it at registration",
                    "file": "connection.json", "json": normal(c, td)}
        stopped = json_file("status-stopped", "status.json after a stop request", os.path.join(j.rd, "status.json"), td)
        plog = lines_file("progress-stopped", "progress.log from the request to the stop", os.path.join(j.rd, "progress.log"), td)
        return [online_s, online_c, stopped, plog]
    finally:
        j.tearDown()


def gate_vectors():
    """the gate as sshd runs it for the browser key's line, on an account set up for the lab's copy"""
    import getpass
    import shutil
    import test_browser_key as B
    kd = tempfile.mkdtemp(prefix="hpcw_vectors_")
    # the key pairs test_browser_key.py makes are not needed here: no line of ours is added or read
    B.Base.kd, B.Base.trip, B.Base.triplog = kd, os.path.join(kd, "trip"), os.path.join(kd, "trip.log")
    os.makedirs(B.Base.trip)
    b = B.Base()
    b.setUp()
    me = getpass.getuser()
    try:
        b.set_up_account()
        vs = []
        for name, summary, line in (
                ("gate-version", "The gate's version line; the account is this machine's, shown as st1234", "version"),
                ("gate-connect", "The gate's connect: the step lines, never a sign-in", "connect worker testsite - default chain"),
                ("gate-status", "The gate's status: `worker status --json`'s one line", "status worker"),
                ("gate-read-progress", "The gate's read of progress.log", "read worker progress.log"),
                ("gate-read-missing", "The gate's read of a file the run does not have yet", "read worker node"),
                ("gate-refused", "Any line the gate does not accept, rc.log among them", "read worker rc.log")):
            r = b.gate(line)
            out = re.sub(r"^(HPCW-GATE ok \S+ \S+ )%s( )" % re.escape(me), r"\1st1234\2", r.stdout, flags=re.M)
            vs.append(command(name, summary, "SSH_ORIGINAL_COMMAND='%s' hpcworker gate" % line, r.returncode, out, r.stderr, b.td))
        r = subprocess.run(["bash", b.tool, "version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, env=b.env())
        vs.append(command("version-shared", "`hpcworker version` from an account that runs the lab's shared copy", "hpcworker version",
                          r.returncode, r.stdout, r.stderr, b.td))
        return vs
    finally:
        b.tearDown()
        shutil.rmtree(kd, ignore_errors=True)


SCENARIOS = (connect_vectors, queued_vectors, job_vectors, gate_vectors)


def produce():
    """-> {file name: vector} for every scenario this machine can run, and the names of those it cannot"""
    made, skipped = {}, []
    for scenario in SCENARIOS:
        vs = scenario()
        if vs is None:
            skipped.append(scenario.__name__)
            continue
        for v in vs:
            made[v["vector"] + ".json"] = v
    return made, skipped


def dump(v):
    return json.dumps(v, indent=1, ensure_ascii=False) + "\n"


def main(argv):
    if argv[1:] != ["--write"]:
        sys.stderr.write("usage: python3 framework/tests/vectors.py --write\n")
        return 2
    made, skipped = produce()
    os.makedirs(VECTORS, exist_ok=True)
    for name, v in sorted(made.items()):
        with open(os.path.join(VECTORS, name), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(dump(v))
    print("%d vector(s) written to interface/contract/vectors/" % len(made))
    for name in skipped:
        print("not run on this machine: %s (its vectors were left as they are)" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
