"""`hpcworker job` (framework 24, lib/jobs.sh), against the fake scheduler of fakegrid.py: a submit takes its
partition, QoS, account and GPU request from the site profile by class, never from the caller; its output goes
under the project's log folder with -D the folder named; --after becomes one --dependency; the job's id, name and
log land in the project's ledger; a refusal says the scheduler's own words and writes nothing; status reads the
ledger's jobs back with one squeue and one sacct; log tails only a ledger job; cancel cancels only ledger jobs.
Nothing reaches a real scheduler."""
import os
import shutil
import tempfile
import unittest

import fakegrid as G


class JobTest(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="hpcw_jobs_")
        self.addCleanup(shutil.rmtree, self.td, True)
        self.g = G.Grid(self.td, profile_edit=lambda p: p.update(qos_gpu="gpu"))
        self.g.setup()
        self.work = os.path.join(self.td, "work")
        os.makedirs(self.work)
        self.script = os.path.join(self.work, "run.sbatch")
        with open(self.script, "w", newline="\n") as fh:
            fh.write("#!/bin/bash\n#SBATCH --partition=wrong\necho hi\n")
        self.ledger = os.path.join(self.g.state, "jobs", "demo", "jobs.tsv")

    def submit(self, extra="", cls="cpu", name="one", args=""):
        return self.g.run("job submit --project demo --name %s --class %s --dir '%s' %s -- run.sbatch %s"
                          % (name, cls, G.posix(self.work), extra, args))

    def sbatch_calls(self):
        return [c for c in self.g.calls() if c.startswith("sbatch ")]

    def test_cpu_job_takes_the_profile_partition_and_qos(self):
        rc, out, err = self.submit(args="a b")
        self.assertEqual(rc, 0, (out, err))
        self.assertRegex(out, r"^HPCW-JOB submitted \d+ one secp/secondary log .*/jobs/demo/logs/one_\d+\.out$")
        call = self.sbatch_calls()[-1]
        for want in ("--partition=secp", "--qos=secondary", "--job-name=demo-one", "--time=04:00:00", "--cpus-per-task=1",
                     "--mem=4G", "-D " + G.posix(self.work), "/jobs/demo/logs/one_%j.out", "run.sbatch a b"):
            self.assertIn(want, call)
        self.assertNotIn("--gres", call)
        self.assertIn("--signal=B:TERM@120", call)
        self.assertNotIn("--requeue", call)

    def test_batch_and_gpu_classes(self):
        self.assertEqual(self.submit(cls="batch", name="long")[0], 0)
        self.assertIn("--partition=reqp --qos=requeue --requeue --open-mode=append", self.sbatch_calls()[-1])
        rc, out, err = self.submit(cls="gpu", name="train", extra="--gpus 2 --time 1-00:00:00 --cpus 8 --mem 64G")
        self.assertEqual(rc, 0, (out, err))
        call = self.sbatch_calls()[-1]
        for want in ("--partition=gmsap,gvohp", "--qos=gpu", "--gres=gpu:2", "--time=1-00:00:00", "--cpus-per-task=8", "--mem=64G"):
            self.assertIn(want, call)

    def test_after_becomes_one_dependency(self):
        rc, out, err = self.submit(extra="--after 41 --after 42:ok --after 43:any")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("--dependency=afterany:41,afterok:42,afterany:43", self.sbatch_calls()[-1])

    def test_the_ledger_and_status(self):
        self.submit(name="one")
        self.submit(name="two")
        with open(self.ledger) as fh:
            rows = [line.rstrip("\n").split("\t") for line in fh]
        self.assertEqual([r[1] for r in rows], ["one", "two"])
        self.assertEqual(rows[0][2:5], ["cpu", "secp", "secondary"])
        first, second = rows[0][0], rows[1][0]
        # the first has ended (squeue no longer lists it), the second is still in line
        jobs = os.path.join(self.g.sched, "jobs")
        with open(jobs) as fh:
            kept = [line for line in fh if not line.startswith(first + "|")]
        with open(jobs, "w") as fh:
            fh.writelines(kept)
        rc, out, err = self.g.run("job status --project demo", FAKE_SACCT="%s|COMPLETED|0:0|asx10" % first)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB %s one COMPLETED on asx10 exit 0:0 log " % first, out)
        self.assertIn("HPCW-JOB %s two PENDING log " % second, out)
        rc, out, err = self.g.run("job status --project demo --json", FAKE_SACCT="%s|COMPLETED|0:0|asx10" % first)
        self.assertEqual(rc, 0, (out, err))
        import json
        doc = json.loads(out)
        self.assertEqual([(j["name"], j["state"]) for j in doc["jobs"]], [("one", "COMPLETED"), ("two", "PENDING")])
        self.assertEqual(sum(1 for c in self.g.calls() if c.startswith("squeue ")), 2)

    def test_status_with_no_jobs(self):
        rc, out, err = self.g.run("job status --project demo")
        self.assertEqual((rc, out.strip()), (0, "HPCW-JOB none for demo"))

    def test_a_refusal_says_why_and_records_nothing(self):
        with open(os.path.join(self.g.sched, "sbatch_fail"), "w") as fh:
            fh.write("sbatch: error: Invalid qos specification\n")
        rc, out, err = self.submit(cls="gpu", name="train")
        self.assertEqual(rc, 1)
        self.assertEqual(out.strip(), "HPCW-JOB refused train gmsap,gvohp/gpu: sbatch: error: Invalid qos specification")
        self.assertFalse(os.path.exists(self.ledger))

    def test_check_queues_nothing(self):
        rc, out, err = self.submit(extra="--check")
        self.assertEqual(rc, 0, (out, err))
        self.assertTrue(out.startswith("HPCW-JOB would-run one secp/secondary"))
        self.assertIn("--test-only", self.sbatch_calls()[-1])
        self.assertFalse(os.path.exists(self.ledger))

    def test_bad_values_are_refused_before_any_call(self):
        for extra, cls, name in (("", "huge", "one"), ("", "cpu", "a b"), ("", "cpu", "-x"), ("--time 4h", "cpu", "one"),
                                 ("--mem lots", "cpu", "one"), ("--gpus 0", "gpu", "one"), ("--after x", "cpu", "one"),
                                 ("--after 4:maybe", "cpu", "one"), ("--cpus 0", "cpu", "one")):
            rc, out, err = self.submit(extra=extra, cls=cls, name="'%s'" % name)
            self.assertNotEqual(rc, 0, (extra, cls, name))
        self.assertEqual(self.sbatch_calls(), [])
        rc, out, err = self.g.run("job submit --project Demo --name one --class cpu -- '%s'" % G.posix(self.script))
        self.assertNotEqual(rc, 0)
        rc, out, err = self.g.run("job submit --project demo --name one --class cpu --dir relative -- run.sbatch")
        self.assertNotEqual(rc, 0)

    def test_no_gpu_partition_refuses_gpu(self):
        g = G.Grid(os.path.join(self.td, "nogpu"), profile_edit=lambda p: p.update(partitions_gpu=[], qos_gpu=""))
        os.makedirs(os.path.join(self.td, "nogpu"), exist_ok=True)
        g.setup()
        rc, out, err = g.run("job submit --project demo --name t --class gpu --dir '%s' -- run.sbatch" % G.posix(self.work))
        self.assertNotEqual(rc, 0)
        self.assertIn("no GPU partition", err)

    def test_log_and_cancel_touch_only_ledger_jobs(self):
        out = self.submit(name="one")[1]
        jid = out.split()[2]
        log = out.split(" log ")[1].strip()
        rc, out, err = self.g.run("job log --project demo %s" % jid)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("no output yet", out)
        with open(log, "w") as fh:
            fh.write("line1\nline2\x1b[31m\n")
        rc, out, err = self.g.run("job log --project demo %s --lines 1" % jid)
        self.assertEqual(out, "line2[31m\n")
        rc, out, err = self.g.run("job log --project demo 999")
        self.assertNotEqual(rc, 0)
        rc, out, err = self.g.run("job cancel --project demo 999")
        self.assertNotEqual(rc, 0)
        self.assertFalse(any(c.startswith("scancel") for c in self.g.calls()))
        rc, out, err = self.g.run("job cancel --project demo %s" % jid)
        self.assertEqual((rc, out.strip()), (0, "HPCW-JOB cancelled %s" % jid))
        self.assertIn("scancel %s" % jid, self.g.calls())


if __name__ == "__main__":
    unittest.main()
