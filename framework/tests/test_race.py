"""Framework 18 (greg, 2026-10-04 23:26Z: "workers on all possible queues should be launched and the first to
get allocated should respond to the client to minimize wait time"): the site profile's worker_queues, the
queue groups a start makes of it (one job over a partition list for entries that share a QoS; one job per
QoS otherwise), the race between those jobs (the race file, the claim, the winner's one cancel, its sweep
and its second look; a loser that leaves having written nothing), and what each reader of a run (status,
stop, the start check, live_run, the queue report's race.log) makes of a worker that asks several queues.

Against the fake scheduler of fakegrid.py (sbatch records what each job asked for in <sched>/submitted;
FAKE_SINGLETON holds a job with singleton behind an earlier one of its name, as Slurm 23.02 does), and, for
the job body, the whole job run as Slurm would run it with test_job.py's stand-ins. Nothing reaches a real
scheduler. What only the grid can show (a QoS on two partitions, ln -s between two nodes on CephFS, squeue
from a compute node) is tools/grid_ci.sh --race and docs/OPEN_QUESTIONS.md, not here."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone

import fakegrid as G
import test_job as TJ
import test_profile_awk as TPA

sys.path.insert(0, os.path.join(G.ROOT, "lib"))
import profile as P  # noqa: E402

WAYNE_QUEUES = ["reqp/requeue", "secp/secondary"]
TOKEN = re.compile(r"^\d+-\d+$")
L, B = "40501234", "40501235"
# framework 17's job header for Wayne State's worker (lib/profile.py header_lines at 5492d4d), which a start that
# asks one queue still writes byte for byte
FW17_HEADER = ["#SBATCH --job-name=hpcw_worker", "#SBATCH --partition=reqp", "#SBATCH --qos=requeue", "#SBATCH --nodes=1", "#SBATCH --ntasks=1",
               "#SBATCH --cpus-per-task=2", "#SBATCH --mem=8G", "#SBATCH --time=0-08:00:00", "#SBATCH --output=slurm_%j.out",
               "#SBATCH --open-mode=append", "#SBATCH --signal=B:TERM@120", "#SBATCH --requeue", "#SBATCH --dependency=singleton"]
FW17_QUEUED_KEYS = ["version", "site", "run", "job", "node", "state", "message", "needs", "hint", "submitted_at", "updated_at", "title",
                    "requested_name", "renewal", "chain", "next_job", "consent", "consent_source", "scheduler_state", "reason",
                    "expected_start", "checked_at"]


def header(path):
    with open(path, encoding="utf-8") as fh:
        return [l for l in fh.read().splitlines() if l.startswith("#SBATCH ")]


def iso(seconds_from_now=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds_from_now)).strftime("%Y-%m-%dT%H:%M:%SZ")


def local(seconds_from_now=0):
    """a time as Slurm prints it: local, no zone"""
    return datetime.fromtimestamp(time.time() + seconds_from_now).strftime("%Y-%m-%dT%H:%M:%S")


def queues(entries):
    def edit(p):
        p["worker_queues"] = entries
    return edit


def wayne():
    with open(os.path.join(G.ROOT, "profiles", "wayne.json"), encoding="utf-8") as fh:
        return json.load(fh)


# ---- 1. the profile key ------------------------------------------------------------------------------
class ProfileKey(unittest.TestCase):
    def errs(self, **changes):
        p = wayne()
        for k, v in changes.items():
            if v is KeyError:
                p.pop(k, None)
            else:
                p[k] = v
        return P.validate(p)

    def test_accepted(self):
        for wq in (KeyError, [], ["reqp"], ["reqp/requeue"], WAYNE_QUEUES, ["reqp/requeue", "secp/requeue"], ["secp/secondary", "secp/primary"],
                   ["a.b-c_d/q.1", "x", "y/z", "w"], ["p" * 64 + "/" + "q" * 64]):
            self.assertEqual(self.errs(worker_queues=wq), [], wq)
        for sch, rt in (("pbs", "apptainer"), ("lsf", "singularity")):
            self.assertEqual(self.errs(scheduler=sch, runtime=rt, scheduler_in_worker=False, worker_queues=["batch"]), [], sch)
            self.assertEqual(self.errs(scheduler=sch, runtime=rt, scheduler_in_worker=False, worker_queues=[]), [], sch)

    def test_refused(self):
        shape = 'worker_queues entries must be "PARTITION" or "PARTITION/QOS" (letters, digits, _ . -) (got %r)'
        cases = [
            (["a", "b", "c", "d", "e"], ["worker_queues may name at most four queues (each group is one sbatch on the login node when a worker starts)"]),
            (["reqp,secp/requeue"], [shape % "reqp,secp/requeue"]),
            (["reqp /requeue"], [shape % "reqp /requeue"]),
            (["reqp/"], [shape % "reqp/"]),
            (["/requeue"], [shape % "/requeue"]),
            (["a/b/c"], [shape % "a/b/c"]),
            ([""], [shape % ""]),
            ([5], [shape % 5]),
            (["p" * 65], [shape % ("p" * 65)]),
            (["reqp/requeue", "reqp/requeue"], ["worker_queues names reqp/requeue twice"]),
        ]
        for wq, want in cases:
            self.assertEqual(self.errs(worker_queues=wq), want, wq)
        self.assertTrue(self.errs(worker_queues="reqp"), "not a list")
        self.assertEqual(self.errs(scheduler="pbs", scheduler_in_worker=False, worker_queues=["batch/high"]),
                         ["worker_queues: this framework sends no QoS on pbs; name the queue only"])
        self.assertEqual(self.errs(scheduler="lsf", runtime="singularity", scheduler_in_worker=False, worker_queues=["normal/q"]),
                         ["worker_queues: this framework sends no QoS on lsf; name the queue only"])
        self.assertEqual(self.errs(scheduler="pbs", scheduler_in_worker=False, worker_queues=["batch", "long"]),
                         ["worker_queues with more than one queue is built for Slurm only (this profile's scheduler is pbs)"])

    def test_awk_gives_the_same_verdicts(self):
        # lib/profile.awk's check against profile.py validate, word for word (test_profile_awk.ValidateSame's rule)
        class V(unittest.TestCase):
            setUp, tearDown, write, sh, awk = TPA.Base.setUp, TPA.Base.tearDown, TPA.Base.write, TPA.Base.sh, TPA.Base.awk
            verdict = TPA.ValidateSame.verdict

            def runTest(self):
                pass
        v = V()
        v.setUp()
        try:
            for wq in ([], ["reqp"], WAYNE_QUEUES, ["a", "b", "c", "d", "e"], ["x,y"], ["x y"], ["p/"], ["a/b/c"], ["q", "q"], [3], "reqp"):
                p = wayne()
                p["worker_queues"] = wq
                v.verdict(p)
            for sch, rt, wq in (("pbs", "apptainer", ["batch/high"]), ("pbs", "apptainer", ["a", "b"]), ("lsf", "singularity", ["n/q", "m"]),
                                ("lsf", "singularity", ["normal"])):
                p = wayne()
                p.update(scheduler=sch, runtime=rt, worker_queues=wq)
                v.verdict(p)
        finally:
            v.tearDown()

    def test_wayne_names_both_queues_and_an_older_account_takes_them(self):
        self.assertEqual(wayne()["worker_queues"], WAYNE_QUEUES, "reqp/requeue first: a caller that cannot follow a race gets today's worker")
        self.assertIn("worker_queues", P.FIELDS_FROM_SITE)
        self.assertEqual(P.site_values("wayne")["worker_queues"], WAYNE_QUEUES)
        with tempfile.TemporaryDirectory() as td:
            p = wayne()
            p.pop("worker_queues")
            path = os.path.join(td, "profile.json")
            with open(path, "w") as fh:
                json.dump(p, fh)
            self.assertEqual(P.load(path)["worker_queues"], WAYNE_QUEUES, "an account profile older than 18 takes the site's list")
        self.assertEqual(P.defaults()["worker_queues"], [])


# ---- 2. the two renderers ------------------------------------------------------------------------------
class Render(unittest.TestCase):
    setUp, tearDown, write, sh = TPA.Base.setUp, TPA.Base.tearDown, TPA.Base.write, TPA.Base.sh
    pair = TPA.Render.pair

    def test_race_drops_singleton_and_both_renderers_agree(self):
        base = dict(RUN="worker", HOURS="8", CPUS="2", MEM="8G", PERMISSION_MODE="default", CAPACITY="4", HPCW_HOME="/wsu/home/go/go24/go2432/.hpcworker", CHAIN="1")
        cand = self.pair(wayne(), PARTITION="reqp", QOS="requeue", RACE="1759620000-4321", RACE_K="1", **base)
        self.assertNotIn("--dependency", cand)
        self.assertIn("#SBATCH --partition=reqp\n#SBATCH --qos=requeue\n", cand)
        self.assertIn("#SBATCH --requeue\n", cand)
        self.assertIn("RACE='1759620000-4321'; RACE_K=1\n", cand)
        nxt = self.pair(wayne(), PARTITION="reqp", QOS="requeue", **base)
        self.assertIn("#SBATCH --dependency=singleton\n", nxt)
        self.assertIn("RACE=''; RACE_K=0\n", nxt)
        two = self.pair(wayne(), PARTITION="secp", QOS="secondary", RACE="1759620000-4321", RACE_K="2", **base)
        self.assertIn("#SBATCH --partition=secp\n#SBATCH --qos=secondary\n", two)
        self.assertIn("#SBATCH --no-requeue\n", two)
        lst = self.pair(wayne(), PARTITION="reqp,secp", QOS="requeue", **base)
        self.assertIn("#SBATCH --partition=reqp,secp\n#SBATCH --qos=requeue\n", lst)
        noq = self.pair(wayne(), PARTITION="secp", QOS="", **base)
        self.assertNotIn("--qos", noq, "an entry with no QoS asks none (the scheduler's default), not qos_cpu")
        self.assertIn("#SBATCH --dependency=singleton\n", noq)
        # with RACE empty the header is framework 17's
        self.assertEqual([l for l in self.pair(wayne(), **base).splitlines() if l.startswith("#SBATCH ")], FW17_HEADER)

    def test_bad_race_values_are_refused_by_both(self):
        path = self.write(wayne())
        for kv in ("RACE=a1", "RACE=1 2", "RACE=" + "1" * 33, "RACE_K=10", "RACE_K=x", "RACE_K="):
            rc, out, err = self.sh("load_profile && hpcw_render '%s' RUN=worker '%s'" % (G.posix(TPA.TPL), kv), path)
            self.assertNotEqual(rc, 0, kv)
            self.assertEqual(out, "", kv)
            k, v = kv.split("=", 1)
            with self.assertRaises(ValueError):
                P.mapping(P.load(path), {"RUN": "worker", k: v})


# ---- the account, with the fake scheduler ---------------------------------------------------------------
class Base(unittest.TestCase):
    QUEUES = WAYNE_QUEUES

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name, profile_edit=queues(self.QUEUES))
        self.g.setup()
        self.rd = self.g.rundir()

    def tearDown(self):
        self.tmp.cleanup()

    def connect(self, flags="", **env):
        rc, out, err = self.g.run("connect --profile testsite --login never " + flags, **env)
        return rc, out.replace("\\", "/"), err

    def p(self, name):
        return os.path.join(self.rd, name)

    def read(self, name):
        with open(self.p(name), encoding="utf-8") as fh:
            return fh.read()

    def race(self):
        parts = self.read("race").split()
        return parts[0], parts[1], parts[2:]

    def kinds(self, calls=None):
        return [c.split()[0] for c in (self.g.calls() if calls is None else calls)]

    def sbatches(self):
        return [c for c in self.g.calls() if c.startswith("sbatch ")]

    def race_files(self):
        """the race's files but race.log, which is kept (append-only, trimmed to 400 lines)"""
        return sorted(n for n in os.listdir(self.rd) if n == "race" or (n.startswith(("race.", "claim.")) and n != "race.log"))

    def rd_posix(self):
        return G.posix(self.rd)


# ---- 3. no worker_queues: framework 17 --------------------------------------------------------------------
class NoQueues(Base):
    QUEUES = []

    def test_a_start_is_framework_17s(self):
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("worker worker submitted as job %s (reqp, 8 h" % L, out)
        self.assertEqual(header(self.p("job.sbatch")), FW17_HEADER)
        self.assertEqual(self.kinds(), ["sbatch"])
        self.assertEqual(self.race_files(), [])
        self.assertEqual(list(self.g.status()), FW17_QUEUED_KEYS)
        self.assertNotIn("RACE=", self.read("params"))

    def test_connect_is_sbatch_then_srun(self):
        rc, out, err = self.g.run("connect --profile testsite --race --consent %s" % G.INSTALL_ID, stdin_text=G.CODE + "\n")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(self.kinds(), ["sbatch", "srun"], "--race with one queue group is a start of one job")
        self.assertNotIn("HPCW-STEP candidates", out)
        self.assertEqual(header(self.p("job.sbatch")), FW17_HEADER)


# ---- 4. one QoS: one job over a partition list ---------------------------------------------------------------
class Collapse(Base):
    QUEUES = ["reqp/requeue", "secp/requeue"]

    def test_one_job_for_every_caller(self):
        for flags in ("", "--race"):
            with self.subTest(flags=flags):
                if os.path.isdir(self.rd):
                    shutil.rmtree(self.rd)
                open(os.path.join(self.g.sched, "calls"), "w").close()
                self.g.jobs([])
                rc, out, err = self.connect(flags)
                self.assertEqual(rc, 0, (out, err))
                self.assertNotIn("HPCW-STEP candidates", out)
                self.assertEqual(self.kinds(), ["sbatch"])
                h = header(self.p("job.sbatch"))
                self.assertIn("#SBATCH --partition=reqp,secp", h)
                self.assertIn("#SBATCH --qos=requeue", h)
                self.assertIn("#SBATCH --requeue", h)
                self.assertIn("#SBATCH --dependency=singleton", h)
                self.assertEqual(self.race_files(), [])
                self.assertNotIn("candidates", self.g.status())
        rc, out, err = self.g.run("worker stop")
        rc, out, err = self.g.run("worker start")
        self.assertIn("submitted as job", out)
        self.assertNotIn("asking", out)


# ---- 5. connect without --race: the first group, as framework 17 ------------------------------------------------
class ConnectWithoutRace(Base):
    def test_first_group_only(self):
        rc, out, err = self.connect()
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines(), ["HPCW-STEP setup ready", "HPCW-STEP queued %s new %s" % (L, self.rd_posix()), "HPCW-STEP done"])
        self.assertEqual(self.kinds(), ["sbatch"])
        self.assertEqual([(s["partition"], s["qos"], s["dependency"]) for s in self.g.submitted()], [("reqp", "requeue", "singleton")])
        self.assertEqual(header(self.p("job.sbatch")), FW17_HEADER, "today's job header, byte for byte")
        s = self.g.status()
        self.assertEqual(list(s), FW17_QUEUED_KEYS, "no candidates key")
        self.assertEqual(self.race_files(), [])
        rc, out, err = self.g.run("worker status --json")
        self.assertEqual(json.loads(out)["candidates"], "")


# ---- 6, 8. connect --race ---------------------------------------------------------------------------------------
class ConnectRace(Base):
    def test_two_candidates(self):
        rc, out, err = self.connect("--race")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(err.strip(), "")
        self.assertEqual(out.splitlines(), ["HPCW-STEP setup ready", "HPCW-STEP candidates %s,%s" % (L, B), "HPCW-STEP queued %s new %s" % (L, self.rd_posix()),
                                            "HPCW-STEP done"])
        self.assertEqual(self.kinds(), ["sbatch", "sbatch"], "no squeue on a fresh run directory, no scancel")
        self.assertEqual([(s["id"], s["partition"], s["qos"], s["dependency"]) for s in self.g.submitted()],
                         [(L, "reqp", "requeue", ""), (B, "secp", "secondary", "")], "group order, no singleton on a candidate")
        h1, h2 = header(self.p("race.1.sbatch")), header(self.p("race.2.sbatch"))
        self.assertTrue({"#SBATCH --partition=reqp", "#SBATCH --qos=requeue", "#SBATCH --requeue"} <= set(h1), h1)
        self.assertTrue({"#SBATCH --partition=secp", "#SBATCH --qos=secondary", "#SBATCH --no-requeue"} <= set(h2), h2)
        for h in (h1, h2):
            self.assertNotIn("#SBATCH --dependency=singleton", h)
        for k in (1, 2):
            self.assertIn("#SBATCH --dependency=singleton", header(self.p("race.%d.next.sbatch" % k)))
        self.assertEqual(header(self.p("race.1.next.sbatch")), FW17_HEADER)
        self.assertEqual(self.read("job.sbatch"), self.read("race.1.next.sbatch"), "job.sbatch is the first group's until a winner puts its own")
        tok, st, ent = self.race()
        self.assertRegex(tok, TOKEN)
        self.assertEqual((st, ent), ("done", ["1:" + L, "2:" + B]))
        self.assertIn("RACE='%s'; RACE_K=1" % tok, self.read("race.1.sbatch"))
        self.assertIn("RACE='%s'; RACE_K=2" % tok, self.read("race.2.sbatch"))
        self.assertIn("RACE=''; RACE_K=0", self.read("race.2.next.sbatch"))
        self.assertIn("RACE=%s" % tok, self.read("params").splitlines())
        self.assertEqual(self.read("job.id").strip(), L)
        s = self.g.status()
        self.assertEqual(list(s), FW17_QUEUED_KEYS + ["candidates"])
        self.assertEqual((s["job"], s["state"], s["candidates"]), (L, "queued", "%s,%s" % (L, B)))
        self.assertEqual([l.split(" ", 1)[1] for l in self.g.progress()], ["Asked the grid for a computer"])
        log = self.read("race.log").splitlines()
        self.assertEqual(len(log), 1)
        self.assertRegex(log[0], r"^\S+ %s start asked 2: 1:%s reqp/requeue, 2:%s secp/secondary \(\d+ ms\)$" % (tok, L, B))
        rc, out, err = self.g.run("worker status --json")
        self.assertEqual(json.loads(out)["candidates"], "%s,%s" % (L, B))

    def test_one_group_refused(self):
        rc, out, err = self.connect("--race", FAKE_SBATCH_REFUSE_PARTITION="secp")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines(), ["HPCW-STEP setup ready", "HPCW-STEP queued %s new %s" % (L, self.rd_posix()), "HPCW-STEP done"],
                         "one candidate: no candidates line")
        self.assertEqual(self.g.status()["candidates"], L)
        self.assertEqual(self.race()[1:], ("done", ["1:" + L]))
        self.assertIn("2:refused secp/secondary", self.read("race.log"))
        # at a terminal, the sentence says which queue was refused and why
        shutil.rmtree(self.rd)
        self.g.jobs([])
        rc, out, err = self.g.run("worker start", FAKE_SBATCH_REFUSE_PARTITION="secp")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("secp/secondary was refused: sbatch: error: Batch job submission failed: Invalid qos specification; the worker waits in reqp/requeue only", out)

    def test_every_group_refused(self):
        with open(os.path.join(self.g.sched, "sbatch_fail"), "w") as fh:
            fh.write("sbatch: error: Batch job submission failed: Invalid qos specification\n")
        rc, out, err = self.connect("--race")
        self.assertEqual(rc, 5, (out, err))
        self.assertEqual(out.splitlines()[-1], "HPCW-STEP failed refused sbatch: error: Batch job submission failed: Invalid qos specification")
        self.assertFalse(os.path.exists(self.p("status.json")), "no queued file")
        self.assertFalse(os.path.exists(self.p(".start.lock")))
        self.assertEqual(self.race()[1:], ("done", []), "nothing can claim it")
        self.assertIn("every queue refused", self.read("race.log"))
        rc, out, err = self.g.run("worker start")
        self.assertNotEqual(rc, 0)
        self.assertIn("the scheduler refused every queue: reqp/requeue was refused: sbatch: error", err)


# ---- 9, 10, 11. a start beside an earlier one ------------------------------------------------------------------
class Kept(Base):
    def first(self):
        rc, out, err = self.connect("--race")
        self.assertEqual(rc, 0, (out, err))
        self.n0 = len(self.g.calls())
        return self.race()[0]

    def new_calls(self):
        return self.g.calls()[self.n0:]

    def test_raced_caller_keeps_every_candidate(self):
        tok = self.first()
        rc, out, err = self.connect("--race")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(self.new_calls(), ["squeue -h -j %s,%s -o %%i|%%T|%%N" % (L, B)], "one squeue over both, nothing submitted or cancelled")
        self.assertEqual(out.splitlines()[1:], ["HPCW-STEP candidates %s,%s" % (L, B), "HPCW-STEP queued %s kept %s" % (L, self.rd_posix()), "HPCW-STEP done"])
        self.assertEqual(self.race(), (tok, "done", ["1:" + L, "2:" + B]))

    def test_caller_of_one_queue_keeps_one(self):
        tok = self.first()
        rc, out, err = self.connect()
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(self.new_calls(), ["squeue -h -j %s,%s -o %%i|%%T|%%N" % (L, B), "scancel %s" % B])
        self.assertEqual(out.splitlines()[1:], ["HPCW-STEP queued %s kept %s" % (L, self.rd_posix()), "HPCW-STEP done"])
        self.assertEqual(self.race(), (tok, "done", ["1:" + L]), "the cancelled candidate can no longer claim")
        self.assertIn("%s stray %s cancelled by a start that kept job %s" % (tok, B, L), self.read("race.log"))

    def test_a_terminal_start_keeps_the_10_sentence(self):
        self.first()
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.strip(), "worker worker already has job %s (PENDING); nothing submitted" % L)
        self.assertEqual(self.kinds(self.new_calls()), ["squeue"])

    def test_a_silent_scheduler_refuses(self):
        self.first()
        open(os.path.join(self.g.sched, "squeue_fail"), "w").close()
        rc, out, err = self.connect("--race")
        self.assertEqual(rc, 5, (out, err))
        self.assertEqual(out.splitlines()[-1], "HPCW-STEP failed refused the scheduler did not answer, so nothing was submitted; try again in a minute")
        self.assertEqual(self.kinds(self.new_calls()), ["squeue"])

    def test_after_a_winner_the_other_is_cancelled(self):
        tok = self.first()
        # B got a computer: its claim, job.id, node; L is still in line
        os.symlink(B, self.p("claim." + tok))
        with open(self.p("job.id"), "w") as fh:
            fh.write(B + "\n")
        with open(self.p("node"), "w") as fh:
            fh.write("asx15\n")
        self.g.jobs(["%s|PENDING|Priority|N/A|" % L, "%s|RUNNING|None|N/A|asx15" % B])
        rc, out, err = self.connect("--race")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines()[1:], ["HPCW-STEP queued %s kept %s" % (B, self.rd_posix()), "HPCW-STEP done"])
        self.assertEqual(self.new_calls(), ["squeue -h -j %s,%s -o %%i|%%T|%%N" % (B, L), "scancel %s" % L])

    def test_a_first_job_that_ended_hands_job_id_to_the_one_in_line(self):
        self.first()
        self.g.jobs(["%s|PENDING|Resources|N/A|" % B])   # L is gone, B still in line, nobody claimed
        rc, out, err = self.connect()
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-STEP queued %s kept" % B, out)
        self.assertEqual(self.read("job.id").strip(), B)
        s = self.g.status()
        self.assertEqual((s["job"], s["state"], s["candidates"]), (B, "queued", B))

    def test_two_raced_starts_at_once_make_two_sbatches(self):
        results = []

        def go():
            results.append(self.connect("--race", FAKE_SBATCH_DELAY="2"))
        threads = [threading.Thread(target=go) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(self.sbatches()), 2, (results, self.g.calls()))
        outs = "\n".join(r[1] for r in results)
        self.assertEqual(outs.count("HPCW-STEP queued %s new" % L), 1, outs)
        self.assertTrue("HPCW-STEP queued %s kept" % L in outs or "another start of this worker is under way" in outs, outs)
        self.assertFalse(os.path.exists(self.p(".start.lock")))


class ClaimBeforeTheLastSbatch(Base):
    QUEUES = ["reqp/requeue", "secp/secondary", "secp/primary"]

    def test_the_start_stops_submitting_and_cancels_what_it_sent_since(self):
        # the first candidate gets a computer while the second sbatch is out: it claims the start and writes its node file
        hook = ("[ \"$FAKE_ID\" = %s ] || exit 0; cd '%s' || exit 0; read -r t _ < race; ln -s %s \"claim.$t\"; echo asx15 > node"
                % (B, self.rd_posix(), L))
        rc, out, err = self.connect("--race", FAKE_SBATCH_HOOK=hook)
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(len(self.sbatches()), 2, "no third sbatch once a candidate has a computer")
        self.assertEqual(self.g.calls()[-1], "scancel %s" % B)
        self.assertEqual(out.splitlines()[1:], ["HPCW-STEP queued %s new %s" % (L, self.rd_posix()), "HPCW-STEP done"])
        self.assertFalse(os.path.exists(self.p("status.json")), "no queued file over a job that has its computer")
        tok, st, ent = self.race()
        self.assertEqual((st, ent), ("done", ["1:" + L, "2:" + B]))
        self.assertIn("%s start: job %s had a computer before the last sbatch went out; cancelled %s (lost)" % (tok, L, B), self.read("race.log"))


# ---- 12, 13, 14. status, stop and live_run while the candidates are in line --------------------------------------
class InLine(Base):
    def setUp(self):
        super().setUp()
        rc, out, err = self.connect("--race")
        self.assertEqual(rc, 0, (out, err))
        self.n0 = len(self.g.calls())

    def status_json(self, floor=""):
        rc, out, err = self.g.run("worker status --json" + floor)
        self.assertEqual(rc, 0, (out, err))
        return json.loads(out)

    def test_status_reads_the_candidates_as_one_worker(self):
        self.g.jobs(["%s|PENDING|Priority|%s|" % (L, local(1200)), "%s|PENDING|Resources|%s|" % (B, local(300))])
        j = self.status_json(" --poll-floor 60")
        self.assertEqual(self.g.calls()[self.n0:], ["squeue -h -j %s,%s -o %%i|%%T|%%r|%%S|%%N" % (L, B)], "ONE squeue")
        st = j["status"]
        self.assertEqual((st["state"], st["scheduler_state"], st["reason"]), ("queued", "PENDING", "Resources"), "the candidate expected soonest speaks")
        exp = datetime.strptime(st["expected_start"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
        self.assertLess(abs(exp - (time.time() + 300)), 120)
        self.assertEqual(j["candidates"], "%s,%s" % (L, B))
        self.assertEqual(list(j)[-1], "candidates")
        # within the floor: nothing asked
        self.status_json(" --poll-floor 60")
        self.assertEqual(len(self.g.calls()), self.n0 + 1)
        # L gone, B in line: still in line
        self.g.jobs(["%s|PENDING|Priority|N/A|" % B])
        j = self.status_json()
        self.assertEqual((j["status"]["state"], j["status"]["reason"]), ("queued", "Priority"))
        # one running: the scheduler says so
        self.g.jobs(["%s|PENDING|Priority|N/A|" % L, "%s|RUNNING|None|N/A|asx15" % B])
        j = self.status_json()
        self.assertEqual(j["status"]["scheduler_state"], "RUNNING")
        self.assertTrue(j["status"]["got_computer_at"])
        # both gone: the request ended
        self.g.jobs([])
        j = self.status_json()
        self.assertEqual((j["status"]["state"], j["status"]["message"], j["scheduler"]["state"]), ("error", "the grid ended the request before it started", "GONE"))
        self.assertEqual(j["candidates"], "", "candidates only while queued")

    def test_a_silent_scheduler_changes_nothing(self):
        before = self.read("status.json")
        open(os.path.join(self.g.sched, "squeue_fail"), "w").close()
        j = self.status_json()
        self.assertIsNone(j["scheduler"])
        self.assertEqual(self.read("status.json"), before)

    def test_stop_in_line_cancels_every_candidate_at_once(self):
        t0 = time.time()
        rc, out, err = self.g.run("worker stop")
        self.assertEqual(rc, 0, (out, err))
        self.assertLess(time.time() - t0, 30, "no wait for a job that never ran")
        self.assertEqual(self.g.calls()[self.n0:], ["squeue -h -j %s,%s -o %%i|%%T|%%N" % (L, B), "scancel %s %s" % (L, B)])
        self.assertEqual(out.strip(), "worker worker: stopped (it was still in line for a computer; cancelled at the scheduler: %s %s; the chain ended)" % (L, B))
        s = self.g.status()
        self.assertEqual((s["state"], s["stop_reason"]), ("stopped", "request"))
        self.assertTrue(os.path.exists(self.p("stop.done")))
        self.assertTrue(os.path.exists(self.p("stop")), "a candidate that gets a computer after this leaves through it")
        self.assertTrue(self.g.progress()[-1].endswith(" Stopped"))
        self.assertEqual(self.race()[1:], ("done", ["1:" + L, "2:" + B]), "stop leaves the race file to its one writer")

    def test_stop_after_a_winner_takes_the_loser_too(self):
        tok = self.race()[0]
        os.symlink(B, self.p("claim." + tok))
        with open(self.p("job.id"), "w") as fh:
            fh.write(B + "\n")
        with open(self.p("node"), "w") as fh:
            fh.write("asx15\n")
        self.g.jobs(["%s|PENDING|Priority|N/A|" % L, "%s|RUNNING|None|N/A|asx15" % B])
        rc, out, err = self.g.run("worker stop", HPCW_STOP_WAIT_S="1", HPCW_STOP_POLL_S="1")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(self.g.calls()[self.n0:], ["squeue -h -j %s,%s -o %%i|%%T|%%N" % (B, L), "scancel %s %s" % (B, L)])
        self.assertIn("cancelled at the scheduler: %s %s;" % (B, L), out)

    def test_details_and_list(self):
        rc, out, err = self.g.run("worker status --details")
        self.assertIn("  candidate: job %s on reqp/requeue" % L, out)
        self.assertIn("  candidate: job %s on secp/secondary" % B, out)
        rc, out, err = self.g.run("worker list")
        self.assertIn("job %s (+1 queue)" % L, out)
        for word in ("reqp", "secp", "requeue", B):
            self.assertNotIn(word, self.g.run("worker status")[1].splitlines()[0], "the student's line names no queue or job")

    def test_live_run_holds_an_install_back(self):
        # a run of this home's own copy (its params name it) in line with two candidates: install's conversion waits
        with open(self.p("params"), "a") as fh:
            fh.write("HPCW_CODE=%s\n" % G.posix(self.g.hpcw))
        rc, out, err = self.g.source("live_run")
        self.assertEqual(out.strip(), "worker (job %s, in line for a computer)" % L)


# ---- 15. what singleton would have done --------------------------------------------------------------------------
class Singleton(Base):
    def test_candidates_can_both_start_and_singleton_jobs_cannot(self):
        rc, out, err = self.connect("--race", FAKE_SINGLETON="1")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual([l.split("|")[2] for l in self.g.jobs()], ["Priority", "Priority"], "no candidate is held behind another")
        self.g.start(B)
        self.g.start(L)   # both may start; the claim keeps the worker to one
        # two jobs of the same name with singleton (what candidates would be with framework 17's header): the second waits
        script = "export PATH='%s':\"$PATH\"; cd '%s' && sbatch race.1.next.sbatch && sbatch race.1.next.sbatch" % (G.msys(self.g.bin), self.rd_posix())
        self.g.jobs([])
        rc, out, err = G.bash(script, env=self.g.env(FAKE_SINGLETON="1"))
        self.assertEqual(rc, 0, err)
        first, second = out.split()
        self.assertEqual([l.split("|")[2] for l in self.g.jobs()], ["Priority", "Dependency"])
        with self.assertRaises(AssertionError):
            self.g.start(second)
        self.g.start(first)


# ---- the terminal --------------------------------------------------------------------------------------------
class Terminal(Base):
    def test_a_terminal_start_races_and_no_race_does_not(self):
        rc, out, err = self.g.run("worker start")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("worker worker submitted as job %s (reqp/requeue) and job %s (secp/secondary), asking 2 queues for a computer at once: "
                      "the first to get one runs the worker and the other is cancelled (8 h, always on" % (L, B), out)
        self.assertEqual(len(self.sbatches()), 2)
        self.g.run("worker stop")
        rc, out, err = self.g.run("worker start --no-race")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("worker worker submitted as job 40501236 (reqp, 8 h", out)
        self.assertEqual(self.race_files(), [], "the stopped start's race files go with the next start")
        self.g.run("worker stop")
        rc, out, err = self.g.run("worker start --partition secp --qos secondary")
        self.assertIn("submitted as job 40501237 (secp/secondary, 8 h", out)
        self.assertEqual(len(self.sbatches()), 4)

    def test_diag_queues_asks_without_submitting(self):
        rc, out, err = self.g.run("diag --queues")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual([c for c in self.g.calls() if c.startswith("sbatch")],
                         ["sbatch --test-only -p reqp -q requeue -t 8:00:00 --wrap=true", "sbatch --test-only -p secp -q secondary -t 8:00:00 --wrap=true"])
        self.assertEqual(self.g.submitted(), [], "nothing submitted")
        self.assertIn("in partition reqp", out)
        rc, out, err = self.g.run("diag --queues", HPCW_GATE="1")
        self.assertNotEqual(rc, 0)


# ---- 18-27. the job body ------------------------------------------------------------------------------------
@unittest.skipUnless(TJ.LINUX, "runs the whole job: needs tmux or script, mkfifo and timeout (Linux, WSL)")
class RaceJob(unittest.TestCase):
    """Each candidate's job file run as Slurm would run it (SLURM_JOB_ID its own id), with test_job.py's stand-ins"""
    TOKEN = "1759620000-4321"
    QUEUES = (("reqp", "requeue"), ("secp", "secondary"))
    setUp = TJ.Job.setUp
    tearDown = TJ.Job.tearDown
    status = TJ.Job.status
    wait_for = TJ.Job.wait_for
    rc_form = "environment"
    JOB = "4242"

    def env_for(self, jid, k):
        e = TJ.Job.env(self)
        part, qos = self.QUEUES[int(k) - 1]
        e.update(SLURM_JOB_ID=jid, SLURM_JOB_PARTITION=part, SLURM_JOB_QOS=qos)
        return e

    def render_to(self, name, **over):
        kv = dict(RUN="worker", HPCW_HOME=os.path.join(self.home, ".hpcworker"), HPCW_CODE=G.ROOT, LOGIN_ABANDON_S="2", AUTH_RETRY_S="0", HEARTBEAT_S="5")
        kv.update(over)
        p = subprocess.run([sys.executable, os.path.join(G.ROOT, "lib", "profile.py"), "render", os.path.join(G.ROOT, "jobs", "worker.sbatch.tpl"), self.profile]
                           + ["%s=%s" % i for i in kv.items()], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=TJ.Job.env(self))
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(os.path.join(self.rd, name), "wb") as fh:
            fh.write(p.stdout)

    def p(self, name):
        return os.path.join(self.rd, name)

    def read(self, name):
        with open(self.p(name), encoding="utf-8") as fh:
            return fh.read()

    def write(self, name, text):
        with open(self.p(name), "w", newline="\n") as fh:
            fh.write(text)

    def start_files(self, ids=("4242", "4243"), state="done", **over):
        """what a raced `worker start` leaves: the four job files, job.sbatch, the race file, job.id, the queued file with
        its candidates, progress.log; and the scheduler holding each candidate in line under the worker's name"""
        for k, (part, qos) in enumerate(self.QUEUES, 1):
            self.render_to("race.%d.sbatch" % k, PARTITION=part, QOS=qos, RACE=self.TOKEN, RACE_K=str(k), **over)
            self.render_to("race.%d.next.sbatch" % k, PARTITION=part, QOS=qos, **over)
        shutil.copy(self.p("race.1.next.sbatch"), self.p("job.sbatch"))
        self.write("race", "%s %s %s\n" % (self.TOKEN, state, " ".join("%d:%s" % (k, i) for k, i in enumerate(ids, 1))))
        self.write("job.id", ids[0] + "\n")
        self.submitted_at = iso(-90)
        q = {"version": 18, "site": "testsite", "run": "worker", "job": ids[0], "node": "", "state": "queued", "message": "waiting for a computer",
             "needs": "nothing", "hint": "Your worker is in line for a computer.", "submitted_at": self.submitted_at, "updated_at": self.submitted_at,
             "title": "Wayne State grid", "requested_name": "Wayne State grid", "renewal": False, "chain": True, "next_job": "", "consent": True,
             "consent_source": "marker", "scheduler_state": "PENDING", "reason": "Priority", "expected_start": "", "checked_at": self.submitted_at,
             "candidates": ",".join(ids)}
        self.write("status.json", json.dumps(q) + "\n")
        self.write("progress.log", "%s Asked the grid for a computer\n" % self.submitted_at)
        self.g.jobs(["%s|PENDING|Priority|N/A|" % i for i in ids])
        with open(os.path.join(self.g.sched, "submitted"), "w") as fh:
            for k, i in enumerate(ids, 1):
                part, qos = self.QUEUES[k - 1]
                fh.write("%s|hpcw_worker|%s|%s|\n" % (i, part, qos))

    def run_job(self, jid, k, wait=True, **extra):
        e = self.env_for(jid, k)
        e.update(extra)
        self.g.start(jid, "asx15")
        proc = subprocess.Popen(["bash", self.p("race.%s.sbatch" % k)], cwd=self.rd, env=e, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, universal_newlines=True, encoding="utf-8", errors="replace")
        if not wait:
            return proc
        try:
            out, _ = proc.communicate(timeout=120)
        finally:
            if proc.poll() is None:
                proc.kill()
        return proc.returncode, out

    def snapshot(self):
        snap = {}
        for n in sorted(os.listdir(self.rd)):
            p = self.p(n)
            st = os.lstat(p)
            if os.path.islink(p):
                body = "->" + os.readlink(p)
            elif os.path.isdir(p):
                body = "dir"
            else:
                with open(p, "rb") as fh:
                    body = fh.read()
            snap[n] = (st.st_size, st.st_mtime_ns, body)
        return snap

    def claim(self):
        p = self.p("claim." + self.TOKEN)
        return os.readlink(p) if os.path.islink(p) else None

    def calls(self):
        return self.g.calls()

    # 18
    def test_the_winner(self):
        self.start_files()
        rc, out = self.run_job("4242", 1)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.claim(), "4242")
        self.assertEqual(self.read("job.id").strip(), "4242")
        self.assertEqual(self.read("node").strip(), subprocess.run(["hostname", "-s"], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip())
        s = self.status()
        self.assertEqual((s["job"], s["renewal"], s["submitted_at"]), ("4242", False, self.submitted_at))
        self.assertNotIn("candidates", s, "the job's own files carry no new key")
        self.assertEqual(self.read("job.sbatch"), self.read("race.1.next.sbatch"))
        calls = self.calls()
        self.assertIn("scancel 4243", calls)
        sweep = calls.index("squeue -h -u st1234 -n hpcw_worker -t PENDING -o %i")
        chain = [i for i, c in enumerate(calls) if c.startswith("sbatch ")]
        self.assertEqual(len(chain), 1, calls)
        self.assertLess(calls.index("scancel 4243"), sweep)
        self.assertLess(sweep, chain[0])
        self.assertIn("--dependency=afterany:4242,singleton", calls[chain[0]])
        self.assertNotIn("scontrol", " ".join(calls))
        log = self.read("race.log").splitlines()
        self.assertRegex(log[0], r"^\S+ %s won 1:4242 on \S+ \(reqp/requeue\), \d+ s after submitted_at; cancelled 4243 \(lost\)$" % self.TOKEN)
        self.assertEqual(len(log), 1, "no stray to sweep")
        self.assertEqual(self.read("race").split()[1:], ["done", "1:4242", "2:4243"], "the job never writes the race file")

    # 19
    def test_a_winner_that_was_not_the_first(self):
        self.start_files()
        rc, out = self.run_job("4243", 2)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.claim(), "4243")
        s = self.status()
        self.assertEqual((s["job"], s["submitted_at"], s["renewal"]), ("4243", self.submitted_at, False), "the wait counts from the student's start")
        self.assertNotIn("scontrol", " ".join(self.calls()))
        self.assertIn("scancel 4242", self.calls())
        self.assertEqual(self.read("job.sbatch"), self.read("race.2.next.sbatch"), "its own queue's chain file")
        self.assertIn("won 2:4243", self.read("race.log"))
        self.assertIn("(secp/secondary)", self.read("race.log"))

    # 20
    def test_a_late_loser_leaves_having_written_nothing(self):
        self.start_files()
        os.symlink("4242", self.p("claim." + self.TOKEN))
        before = self.snapshot()
        time.sleep(1.1)
        rc, out = self.run_job("4243", 2)
        self.assertEqual(rc, 0, out)
        self.assertIn("another queue's job has the worker, or this start is over: leaving", out)
        self.assertEqual(self.snapshot(), before, "names, sizes, contents and times as they were")
        self.assertEqual(self.calls(), [], "no scheduler call at all")

    # 21
    def test_two_at_once_one_claim(self):
        self.start_files()
        a = self.run_job("4242", 1, wait=False)
        b = self.run_job("4243", 2, wait=False)
        outs = {}
        for jid, proc in (("4242", a), ("4243", b)):
            try:
                outs[jid], _ = proc.communicate(timeout=120)
            finally:
                if proc.poll() is None:
                    proc.kill()
        w = self.claim()
        self.assertIn(w, ("4242", "4243"))
        loser = "4243" if w == "4242" else "4242"
        self.assertEqual([n for n in os.listdir(self.rd) if n.startswith("claim.")], ["claim." + self.TOKEN])
        self.assertEqual(self.read("job.id").strip(), w)
        s = self.status()
        self.assertEqual((s["job"], s["pid"]), (w, (a if w == "4242" else b).pid), "the winner wrote status.json")
        self.assertEqual(outs[loser].strip().count("\n"), 0, outs[loser])
        self.assertIn("leaving", outs[loser])
        self.assertNotIn("scancel %s" % w, self.calls())
        self.assertIn("scancel %s" % loser, self.calls())

    # 22
    def test_a_start_that_is_over(self):
        for case in ("stale", "missing", "unlisted"):
            with self.subTest(case=case):
                for n in os.listdir(self.rd):
                    p = self.p(n)
                    os.remove(p) if not os.path.isdir(p) or os.path.islink(p) else shutil.rmtree(p)
                open(os.path.join(self.g.sched, "calls"), "w").close()
                self.start_files()
                if case == "stale":
                    self.write("race", "1759629999-77 open 1:4300\n")
                elif case == "missing":
                    os.remove(self.p("race"))
                else:
                    self.write("race", "%s done 1:4242\n" % self.TOKEN)   # 4243 was cancelled as a stray
                before = self.snapshot()
                time.sleep(1.1)
                rc, out = self.run_job("4243", 2)
                self.assertEqual(rc, 0, out)
                self.assertIn("leaving", out)
                self.assertIsNone(self.claim())
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(self.calls(), [])

    # 23
    def test_a_stop_found_at_start(self):
        self.start_files()
        self.write("stop", "")
        rc, out = self.run_job("4242", 1)
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.claim(), "4242")
        s = self.status()
        self.assertEqual((s["state"], s["stop_reason"], s["job"]), ("stopped", "request", "4242"))
        self.assertTrue(os.path.exists(self.p("stop.done")))
        self.assertIn("scancel 4243", self.calls())
        self.assertNotIn("sbatch", " ".join(self.calls()), "no successor")
        self.assertEqual(self.read("progress.log").splitlines()[-1].split(" ", 1)[1], "Stopped")

    # 24
    def test_a_requeued_winner_carries_on(self):
        self.start_files()
        os.symlink("4242", self.p("claim." + self.TOKEN))
        self.write("job.id", "4242\n")
        self.write("next.id", "4300 4242\n")
        self.write("race.log", "2026-10-05T10:00:00Z %s won 1:4242 on asx15 (reqp/requeue), 30 s after submitted_at; cancelled 4243 (lost)\n" % self.TOKEN)
        st = json.loads(self.read("status.json"))
        st.update(state="preempted", node="asx15", next_job="4300")
        del st["candidates"]
        self.write("status.json", json.dumps(st) + "\n")
        self.g.jobs(["4242|PENDING|BeginTime|N/A|", "4300|PENDING|Dependency|N/A|"])
        rc, out = self.run_job("4242", 1)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("leaving", out)
        self.assertEqual(self.status()["job"], "4242")
        self.assertEqual(self.status()["submitted_at"], self.submitted_at)
        self.assertEqual(len(self.read("race.log").splitlines()), 1, "no second won line")
        # its successor is the one already queued; the only cancel is the sign-in abandon's, of that successor
        self.assertEqual(self.calls(), ["scancel 4300"])

    # 25
    def test_a_chain_successor_runs_no_race_code(self):
        self.start_files()
        os.symlink("4242", self.p("claim." + self.TOKEN))
        self.write("job.id", "4242\n")
        self.write("next.id", "4300 4242\n")
        log = "2026-10-05T10:00:00Z %s won 1:4242 on asx15 (reqp/requeue), 30 s after submitted_at; cancelled 4243 (lost)\n" % self.TOKEN
        self.write("race.log", log)
        self.write("status.json", json.dumps({"version": 18, "job": "4242", "state": "preempted", "submitted_at": "2026-10-01T04:00:00Z", "next_job": "4300"}) + "\n")
        shutil.copy(self.p("race.1.next.sbatch"), self.p("job.sbatch"))
        e = self.env_for("4300", 1)
        e["FAKE_SUBMIT_TIME"] = "2026-10-01T08:30:00"
        proc = subprocess.Popen(["bash", self.p("job.sbatch")], cwd=self.rd, env=e, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                universal_newlines=True, encoding="utf-8", errors="replace")
        out, _ = proc.communicate(timeout=120)
        s = self.status()
        self.assertEqual((s["job"], s["renewal"]), ("4300", True), out)
        self.assertEqual(self.read("race.log"), log)
        self.assertEqual(self.claim(), "4242")
        calls = self.calls()
        self.assertIn("scontrol show job 4300 -o", calls)
        self.assertNotIn("squeue -h -u", " ".join(calls), "no sweep")
        self.assertFalse([c for c in calls if c in ("scancel 4243", "scancel 4242")], calls)

    # 26
    def test_the_sweep_before_the_successor(self):
        self.start_files()
        # a lost cancel leaves 4243 in line, and 4250 (a candidate whose id never reached the race file) is in line too
        self.g.jobs(["4242|PENDING|Priority|N/A|", "4243|PENDING|Priority|N/A|", "4250|PENDING|Priority|N/A|"])
        with open(os.path.join(self.g.sched, "submitted"), "a") as fh:
            fh.write("4250|hpcw_worker|secp|secondary|\n")
        rc, out = self.run_job("4242", 1, FAKE_SCANCEL_IGNORE="4243")
        self.assertEqual(rc, 0, out)
        calls = self.calls()
        first_sbatch = [i for i, c in enumerate(calls) if c.startswith("sbatch ")][0]
        self.assertIn("scancel 4243 4250", calls[:first_sbatch])
        self.assertIn("%s stray 4243 4250 cancelled by the sweep of 4242" % self.TOKEN, self.read("race.log"))

    def test_a_sweep_the_scheduler_does_not_answer(self):
        self.start_files()
        open(os.path.join(self.g.sched, "squeue_fail"), "w").close()
        rc, out = self.run_job("4242", 1)
        self.assertEqual(rc, 0, out)
        self.assertIn("sweep from 4242: the scheduler did not answer; nothing cancelled", self.read("race.log"))
        self.assertTrue([c for c in self.calls() if c.startswith("sbatch ")], "the chain goes on")

    # 27
    def test_the_second_look_of_an_open_race(self):
        self.start_files(ids=("4242",), state="open", LOGIN_ABANDON_S="90")
        proc = self.run_job("4242", 1, wait=False, HPCW_RACE_SECOND_S="8")
        try:
            self.assertTrue(self.wait_for(lambda: " won 1:4242 " in self.read("race.log"), 30), "settled")
            self.assertIn("no other candidate to cancel", self.read("race.log"))
            # the start sends its second sbatch after the winner looked
            self.write("race.part", "%s done 1:4242 2:4243\n" % self.TOKEN)
            os.rename(self.p("race.part"), self.p("race"))
            self.assertTrue(self.wait_for(lambda: "second look" in self.read("race.log"), 40), self.read("race.log"))
            self.assertIn("%s second look from 4242: cancelled 4243 (lost)" % self.TOKEN, self.read("race.log"))
            self.assertEqual(self.calls().count("scancel 4243"), 1)
            open(self.p("stop"), "w").close()
            out, _ = proc.communicate(timeout=90)
        finally:
            if proc.poll() is None:
                proc.kill()
        self.assertEqual(self.calls().count("scancel 4243"), 1, "once")


if __name__ == "__main__":
    unittest.main()
