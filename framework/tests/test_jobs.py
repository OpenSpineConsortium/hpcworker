"""`hpcworker job` (framework 25, 27; lib/jobs.sh), against the fake scheduler of fakegrid.py: a submit takes its
partition, QoS, account and GPU request from the site profile by class, never from the caller; its output goes
under the project's log folder with -D the folder named; --after becomes one --dependency; the job's id, name and
log land in the project's ledger; a refusal says the scheduler's own words and writes nothing; status reads the
ledger's jobs back with one squeue and one sacct; log tails only a ledger job; cancel cancels only ledger jobs.
Nothing reaches a real scheduler."""
import os
import shutil
import tempfile
import time
import unittest

import fakegrid as G


SINFO = "\n".join(["galhp|gpu:nvidia_l40s:4(S:0)", "gmsap|gpu:nvidia_h200:4(S:0-1)", "gvohp|gpu:tesla:4(S:0)",
                   "reqp*|gpu:nvidia_a30:10(S:0-7)", "reqp*|gpu:nvidia_a30_2g.12gb:20(S:0,3)", "reqp*|gpu:nvidia_l40s:4(S:0)",
                   "reqp*|gpu:nvidia_h200:4(S:0-1)", "reqp*|gpu:nvidia_rtx_pro_4500_blackwell:10(S:0-1)", "reqp*|gpu:tesla:2(S:2,7)",
                   "secp|(null)"])
# node by node, as sinfo -N gives it: alh1, msa1 and voh1 sit in their group's partition and in reqp, as at Wayne State;
# arw1 holds MIG slices alone and tta1 slices beside two whole A30s, so a generic request there could take a slice
SINFO_NODES = "\n".join(["alh1|galhp|gpu:nvidia_l40s:4(S:0)", "alh1|reqp*|gpu:nvidia_l40s:4(S:0)",
                         "msa1|gmsap|gpu:nvidia_h200:4(S:0-1)", "msa1|reqp*|gpu:nvidia_h200:4(S:0-1)",
                         "voh1|gvohp|gpu:tesla:4(S:0)", "voh1|reqp*|gpu:tesla:4(S:0)",
                         "arw4|reqp*|gpu:nvidia_a30:10(S:0-7)", "arw1|reqp*|gpu:nvidia_a30_2g.12gb:20(S:0,3)",
                         "tta1|reqp*|gpu:nvidia_a30_2g.12gb:4(S:0),gpu:nvidia_a30:2(S:0)",
                         "ymh1|reqp*|gpu:nvidia_rtx_pro_4500_blackwell:10(S:0-1)", "rom1|reqp*|gpu:tesla:2(S:2,7)",
                         "asx1|secp|(null)", "asx1|reqp*|(null)"])
# what reqp leaves out for a 24 GB Ampere, Ada or Hopper job: the slices, the mixed node, Blackwell, the tesla cards
REQP_OUT = "arw1,rom1,tta1,voh1,ymh1"


def own(*rows):
    """FAKE_SQUEUE_LIST rows: this account's jobs as job replace asks squeue for them"""
    return "\n".join("|".join(r) for r in rows)


class PlacementBase(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="hpcw_place_")
        self.addCleanup(shutil.rmtree, self.td, True)
        self.g = G.Grid(self.td, profile_edit=lambda p: p.update(qos_gpu="gpu"))
        self.g.setup()
        shutil.copy(os.path.join(self.g.shared, "profiles", "wayne.placement"), os.path.join(self.g.shared, "profiles", "testsite.placement"))
        self.work = os.path.join(self.td, "work")
        os.makedirs(self.work)
        with open(os.path.join(self.work, "run.sbatch"), "w", newline="\n") as fh:
            fh.write("#!/bin/bash\necho hi\n")
        self.ledger = os.path.join(self.g.state, "jobs", "demo", "jobs.tsv")

    def plan(self, *lines):
        with open(os.path.join(self.g.sched, "testonly"), "w", newline="\n") as fh:
            fh.write("\n".join(lines) + "\n")

    def run_tool(self, args, **env):
        e = {"FAKE_SINFO": SINFO, "FAKE_SINFO_NODES": SINFO_NODES}
        e.update(env)
        return self.g.run(args, **e)

    def submit(self, extra, cls="gpu", name="fit", **env):
        return self.run_tool("job submit --project demo --name %s --class %s --dir '%s' --time 4:00:00 --cpus 4 --mem 32G %s -- run.sbatch"
                             % (name, cls, G.posix(self.work), extra), **env)

    def submitted(self):
        return [c for c in self.g.calls() if c.startswith("sbatch ") and "--test-only" not in c]

    def asked(self):
        return [c for c in self.g.calls() if c.startswith("sbatch ") and "--test-only" in c]

    def updates(self):
        return [c for c in self.g.calls() if c.startswith("scontrol update")]

    def job_id(self, out):
        return [l for l in out.splitlines() if l.startswith("HPCW-JOB submitted")][0].split()[2]

    def job_log(self, out):
        return [l for l in out.splitlines() if l.startswith("HPCW-JOB submitted")][0].split(" log ")[1]


class PlacementTest(PlacementBase):
    """--placement (framework 30, 31): the candidates of <site>.placement that fit, one QoS a placement, each of its
    partitions asked alone with sbatch --test-only, the job sent to all of them at once with a generic gres and the
    unfitting GPU nodes excluded; the earliest QoS taken, a tie to the QoS never preempted unless the job resumes."""

    def test_one_qos_is_one_placement_over_every_card_that_fits(self):
        self.plan("galhp * 3600", "gmsap * 21600", "reqp * 60")
        rc, out, err = self.submit("--placement auto --gpu-mem 24")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB placement fit chose reqp/requeue gpu:1 (preemptable, requeued)", out)
        self.assertRegex(out, r"HPCW-JOB submitted \d+ fit reqp/requeue log ")
        call = self.submitted()[-1]
        for want in ("--partition=reqp ", "--qos=requeue", "--gres=gpu:1 ", "--exclude=" + REQP_OUT + " ", "--requeue",
                     "--open-mode=append", "--time=4:00:00", "--cpus-per-task=4", "--mem=32G"):
            self.assertIn(want, call)
        # each partition was asked alone, with the job's resources; gvohp's Volta cards fit no candidate
        asked = self.asked()
        self.assertEqual(sorted(c.split("--partition=")[1].split()[0] for c in asked), ["galhp", "gmsap", "reqp"])
        for c in asked:
            self.assertIn("--time=4:00:00 --cpus-per-task=4 --mem=32G", c)
            self.assertIn("--gres=gpu:1", c)
        with open(self.job_log(out)) as fh:
            head = fh.read()
        self.assertIn("== hpcworker placement for fit", head)
        self.assertIn("reqp/requeue gpu:1 of nvidia_a30 nvidia_h200 nvidia_l40s start", head)
        self.assertIn("chose reqp requeue yes gpu:1 " + REQP_OUT, head)
        # what it was placed for, for job replace
        with open(os.path.join(self.g.state, "jobs", "demo", "placed", self.job_id(out))) as fh:
            self.assertEqual(fh.read().strip(), "class=gpu gpus=1 gpu_mem=24 gpu_arch=ampere,ada,hopper requeue=-")

    def test_the_gpu_qos_takes_both_its_partitions_earliest_first(self):
        self.plan("galhp * 3600", "gmsap * 0", "reqp * 7200")
        rc, out, err = self.submit("--placement auto --gpu-mem 24")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose gmsap,galhp/gpu gpu:1 (never preempted)", out)
        call = self.submitted()[-1]
        for want in ("--partition=gmsap,galhp ", "--qos=gpu", "--gres=gpu:1 ", "--no-requeue"):
            self.assertIn(want, call)
        self.assertNotIn("--exclude", call)

    def test_a_tie_goes_to_the_qos_never_preempted_unless_the_job_resumes(self):
        self.plan("galhp * 240", "gmsap * 9000", "reqp * 0")
        rc, out, err = self.submit("--placement auto --gpu-mem 24")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose galhp,gmsap/gpu gpu:1 (never preempted)", out)
        rc, out, err = self.submit("--placement auto --gpu-mem 24 --requeue", name="resumes")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose reqp/requeue gpu:1 (preemptable, requeued)", out)
        self.assertIn("--requeue", self.submitted()[-1])

    def test_a_far_earlier_requeue_start_beats_a_late_gpu_one(self):
        self.plan("galhp * 7200", "gmsap * 9000", "reqp * 0")
        rc, out, err = self.submit("--placement auto --gpu-mem 40")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose reqp/requeue gpu:1", out)
        # the 24 GB A30s and the nodes that hold them are out for a 40 GB need
        call = self.submitted()[-1]
        self.assertIn("--exclude=arw1,arw4,rom1,tta1,voh1,ymh1 ", call)

    def test_the_architectures_and_no_requeue_narrow_the_candidates(self):
        self.plan("gvohp * 0", "galhp * 600", "reqp * 0", "gmsap * 900")
        rc, out, err = self.submit("--placement auto --gpu-mem 16 --gpu-arch volta+ --no-requeue")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose gvohp,galhp,gmsap/gpu gpu:1 (never preempted)", out)
        self.assertFalse([c for c in self.asked() if "--partition=reqp" in c], "--no-requeue asks no preemptable partition")
        self.assertIn("--no-requeue", self.submitted()[-1])
        rc, out, err = self.submit("--placement auto --gpu-mem 24 --gpu-arch blackwell", name="bw")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose reqp/requeue gpu:1", out)
        self.assertIn("--exclude=alh1,arw1,arw4,msa1,rom1,tta1,voh1 ", self.submitted()[-1])

    def test_a_refused_candidate_is_passed_by_and_a_cpu_job_races_its_qos(self):
        self.plan("secp - refuse", "prip - 900", "reqp - 0")
        rc, out, err = self.submit("--placement auto", cls="batch", name="cpu")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB placement cpu secp/secondary cpu refused:", out)
        self.assertIn("chose reqp/requeue (preemptable, requeued)", out)
        self.assertNotIn("--gres", self.submitted()[-1])
        self.assertNotIn("--exclude", self.submitted()[-1])

    def test_report_submits_nothing(self):
        self.plan("galhp * 600", "reqp * 1200", "gmsap * 3600")
        rc, out, err = self.submit("--placement report --gpu-mem 24")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose galhp,gmsap/gpu gpu:1 (never preempted)", out)
        self.assertNotIn("HPCW-JOB submitted", out)
        self.assertEqual(self.submitted(), [])

    def test_what_placement_refuses(self):
        self.plan("galhp * 600")
        for extra, says in (("--placement auto --partition galhp", "leave out --partition and --gpu-type"),
                            ("--placement auto --gpu-arch maxwellx", "--gpu-arch is a list of"),
                            ("--placement sometimes", "--placement is auto or report"),
                            ("--gpu-mem 24", "--gpu-mem and --gpu-arch are --placement's"),
                            ("--placement auto --gpu-mem 500", "no partition of this site holds a card of 500 GB")):
            rc, out, err = self.submit(extra)
            self.assertNotEqual(rc, 0, extra)
            self.assertIn(says, out + err, extra)
        self.plan("galhp * refuse", "gmsap * refuse", "reqp * refuse")
        rc, out, err = self.submit("--placement auto --gpu-mem 24")
        self.assertNotEqual(rc, 0)
        self.assertIn("no candidate placement answered sbatch --test-only", out + err)
        self.assertEqual(self.submitted(), [])

    def test_place_prints_the_options_and_a_capped_qos_is_left_out_at_its_most(self):
        self.plan("reqp - 0 debug", "prip - 0 debug", "secp - 0 debug", "prip - 900 primary", "secp - 3600 secondary", "reqp - 2400 requeue")
        cmd = "job place --class runner --name hpcw_auto_o-r --time 2:00:00 --cpus 4 --mem 16G"
        rc, out, err = self.run_tool(cmd)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB placement hpcw_auto_o-r chose reqp,prip,secp/debug (never preempted)", out)
        opts = [l for l in out.splitlines() if l.startswith("HPCW-JOB options ")]
        self.assertEqual(len(opts), 1, out)
        self.assertRegex(opts[0], r"^HPCW-JOB options --partition=reqp,prip,secp --qos=debug( --account=\S+)? --no-requeue --open-mode=append$")
        self.assertEqual(self.submitted(), [])
        for c in self.asked():
            self.assertIn("--wrap=true", c)
            self.assertIn("--time=2:00:00 --cpus-per-task=4 --mem=16G", c)
        # one job of the account already holds the debug QoS, its most: the race passes it by
        held = own(("40970001", "hpcw_auto_o-r", "RUNNING", "reqp", "debug", "None", "4", "16G", "2:00:00", "N/A", "", "2026-11-04T10:00:00", "(null)"))
        rc, out, err = self.run_tool(cmd, FAKE_SQUEUE_LIST=held)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("reqp,prip,secp/debug held: 1 of this account's jobs hold it, its most at once 1", out)
        self.assertIn("chose prip/primary (never preempted)", out)
        rc, out, err = self.run_tool("job place --class sometimes")
        self.assertNotEqual(rc, 0)
        self.assertIn("--class is cpu, batch, gpu or runner", out + err)


class ReplaceTest(PlacementBase):
    """job replace (31): this account's own pending jobs that hpcworker placed raced again, each moved in place with
    scontrol update when another placement starts it sooner by more than the margin; nothing else is touched."""

    OLD = "2026-01-01T00:00:00"

    def placed(self, name="fit", extra="--placement auto --gpu-mem 24"):
        self.plan("reqp * 0", "galhp * 3600", "gmsap * 3600")
        rc, out, err = self.submit(extra, name=name)
        self.assertEqual(rc, 0, (out, err))
        return self.job_id(out), self.job_log(out)

    def pending(self, jid, name="demo-fit", parts="reqp", qos="requeue", tres="gres:gpu:1", excl=REQP_OUT, sub=OLD, dep="(null)", reason="Priority"):
        return (jid, name, "PENDING", parts, qos, reason, "4", "32G", "4:00:00", tres, excl, sub, dep)

    def test_a_pending_job_moves_where_it_starts_much_sooner_and_once_in_the_hold(self):
        jid, log = self.placed()
        self.plan("reqp * 20000", "galhp * 0", "gmsap * 30000")
        rows = own(self.pending(jid))
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=rows)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB moved %s demo-fit reqp/requeue gpu:1 -> galhp,gmsap/gpu gpu:1 (never preempted), estimate " % jid, out)
        self.assertIn("moved 1", out)
        self.assertEqual(self.updates(), ["scontrol update jobid=%s partition=galhp,gmsap qos=gpu gres=gpu:1 excnodelist=" % jid])
        with open(log) as fh:
            self.assertIn("moved while pending from reqp/requeue gpu:1 to galhp,gmsap/gpu gpu:1", fh.read())
        with open(os.path.join(self.g.state, "jobs", "replace.log")) as fh:
            self.assertIn("moved %s demo-fit" % jid, fh.read())
        # moved within the hold: the next look leaves it alone
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=rows)
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(len(self.updates()), 1)

    def test_no_move_without_the_margin_or_where_it_is_about_to_start(self):
        # waiting for resources, at the head of its queue, where test-only's answer holds
        jid, _ = self.placed()
        rows = own(self.pending(jid, reason="Resources"))
        for plan in (("reqp * 700", "galhp * 600", "gmsap * 600"), ("reqp * 60", "galhp * 0", "gmsap * 0")):
            self.plan(*plan)
            rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=rows)
            self.assertEqual(rc, 0, (out, err))
            self.assertIn("moved 0", out)
        self.assertEqual(self.updates(), [])

    @staticmethod
    def ago(seconds):
        """squeue's submission time (local, as %V gives it) that many seconds ago"""
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - seconds))

    def test_a_job_waiting_behind_priority_is_not_about_to_start_where_test_only_says_so(self):
        # (32) 5 November: test-only said "now" on the requeue QoS while the account's jobs sat there for hours behind
        # others' priority; the job's own wait is the evidence, so a placement starting it within the half hour wins
        jid, _ = self.placed()
        self.plan("reqp * 60", "galhp * 1800", "gmsap * 30000")
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=own(self.pending(jid, sub=self.ago(3 * 3600))))
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB moved %s demo-fit reqp/requeue gpu:1 -> galhp,gmsap/gpu gpu:1 (never preempted)" % jid, out)
        with open(os.path.join(self.g.state, "placement.waits")) as fh:
            seen = fh.read().split()
        self.assertEqual(seen[1:6], ["reqp", "requeue", "4", "32768", "1"])
        self.assertGreaterEqual(int(seen[6]), 3 * 3600 - 60)
        # a short wait is the scheduler's own churn and no evidence: the job stays where test-only says it is about to start
        os.remove(os.path.join(self.g.state, "placement.waits"))
        jid2, _ = self.placed(name="young")
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=own(self.pending(jid2, name="demo-young", sub=self.ago(300))),
                                     HPCW_REPLACE_AGE="60")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("moved 0", out)

    def test_no_job_is_moved_where_one_no_larger_waits_behind_priority(self):
        jid, _ = self.placed()
        self.plan("reqp * 0", "galhp * 7200", "gmsap * 7200")
        mine = self.pending(jid, parts="galhp,gmsap", qos="gpu", excl="", reason="Resources")
        waiting = self.pending("40970003", name="demo-other", sub=self.ago(2 * 3600))
        rc, out, err = self.run_tool("job replace --dry-run", FAKE_SQUEUE_LIST=own(mine, waiting))
        self.assertEqual(rc, 0, (out, err))
        self.assertNotIn("would-move %s" % jid, out)
        self.assertIn("stays %s" % jid, out)
        # one waiting there that asks more cores than this job is no evidence for it (nor is the record the look above kept)
        os.remove(os.path.join(self.g.state, "placement.waits"))
        larger = waiting[:6] + ("16",) + waiting[7:]
        rc, out, err = self.run_tool("job replace --dry-run", FAKE_SQUEUE_LIST=own(mine, larger))
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("would-move %s demo-fit galhp,gmsap/gpu gpu:1 -> reqp/requeue gpu:1" % jid, out)

    def test_a_dry_run_says_and_moves_nothing(self):
        jid, _ = self.placed()
        self.plan("reqp * 20000", "galhp * 0", "gmsap * 0")
        rc, out, err = self.run_tool("job replace --dry-run", FAKE_SQUEUE_LIST=own(self.pending(jid)))
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB would-move %s demo-fit" % jid, out)
        self.assertEqual(self.updates(), [])

    def test_only_the_account_s_placed_waiting_jobs_are_looked_at(self):
        jid, _ = self.placed()
        rc, out, err = self.submit("", name="plain")   # submitted without --placement: no need is known
        self.assertEqual(rc, 0, (out, err))
        plain = self.job_id(out)
        self.plan("reqp * 20000", "galhp * 0", "gmsap * 0")
        before = len(self.asked())
        rows = own(self.pending("40999999", name="someone-else"), self.pending(plain, name="demo-plain"),
                   self.pending(jid, dep="afterok:1(unfulfilled)", reason="Dependency"),
                   self.pending(jid, sub="2099-01-01T00:00:00"), self.pending("40970002", name="hpcw_auto_o-r", tres="N/A"))
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=rows)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("looked at 0 pending job(s), moved 0", out)
        self.assertEqual(len(self.asked()), before, "nothing was raced")
        self.assertEqual(self.updates(), [])

    def test_a_job_framework_30_placed_is_read_from_its_log(self):
        logs = os.path.join(self.g.state, "jobs", "demo", "logs")
        os.makedirs(logs)
        log = os.path.join(logs, "old_40970001.out")
        with open(log, "w", newline="\n") as fh:
            fh.write("== hpcworker placement for old, 2026-11-04T13:58:22 UTC: the estimates sbatch --test-only gave, then the choice\n"
                     "   galhp/gpu nvidia_l40s 48GB ada start 2026-11-07T15:22:13Z in 4403 min\n"
                     "   reqp/requeue nvidia_a30 refused: Requested node configuration is not available\n"
                     "   reqp/requeue nvidia_h200 141GB hopper start 2026-11-06T00:28:47Z in 2070 min, preemptable\n"
                     "   reqp/requeue nvidia_l40s 48GB ada start 2026-11-07T10:35:22Z in 4117 min, preemptable\n"
                     "   chose reqp requeue yes nvidia_h200\n- code: the run's own lines\n")
        with open(self.ledger, "w", newline="\n") as fh:
            fh.write("\t".join(["40970001", "old", "gpu", "reqp", "requeue", "2026-11-04T13:58:22Z", G.posix(log), G.posix(self.work),
                                G.posix(os.path.join(self.work, "run.sbatch")), "", ""]) + "\n")
        self.plan("reqp nvidia_h200 90000", "reqp * 0", "galhp * 50000", "gmsap * 50000")
        rows = own(self.pending("40970001", name="demo-old", tres="gres:gpu:nvidia_h200:1", excl="", reason="Resources"))
        rc, out, err = self.run_tool("job replace --project demo", FAKE_SQUEUE_LIST=rows)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB moved 40970001 demo-old reqp/requeue gpu:nvidia_h200:1 -> reqp/requeue gpu:1 (preemptable, requeued)", out)
        # its race asked 48 GB or more of Ada or Hopper: the A30s and every card outside those stay out
        self.assertEqual(self.updates(), ["scontrol update jobid=40970001 partition=reqp qos=requeue gres=gpu:1 excnodelist=arw1,arw4,rom1,tta1,voh1,ymh1 requeue=1"])

    def test_a_refused_move_cancels_a_runner_job_and_keeps_any_other(self):
        jid, _ = self.placed()
        with open(os.path.join(self.g.sched, "scontrol_fail"), "w") as fh:
            fh.write("slurm_update error: Access/permission denied\n")
        self.plan("reqp * 20000", "galhp * 0", "gmsap * 0", "reqp - 20000 requeue", "prip - 0 primary", "secp - 9000 secondary",
                  "reqp - 9000 debug", "prip - 9000 debug", "secp - 9000 debug")
        runner = ("40970002", "hpcw_auto_o-r", "PENDING", "reqp", "requeue", "Priority", "4", "16G", "2:00:00", "N/A", "", self.OLD, "(null)")
        rc, out, err = self.run_tool("job replace --runners", FAKE_SQUEUE_LIST=own(self.pending(jid), runner))
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB kept %s demo-fit: Slurm refused the move to galhp,gmsap/gpu gpu:1 (never preempted): slurm_update error" % jid, out)
        self.assertIn("HPCW-JOB cancelled 40970002 hpcw_auto_o-r: Slurm refused the move to prip/primary", out)
        cancels = [c for c in self.g.calls() if c.startswith("scancel")]
        self.assertEqual(cancels, ["scancel 40970002"])


class ArrayTest(PlacementBase):
    """Framework 32: an array is placed as a job is, and its waiting tasks are raced as one, each a worker that may start on
    any card that fits; the ones that have started stay."""

    OLD = ReplaceTest.OLD
    placed = ReplaceTest.placed
    pending = ReplaceTest.pending

    def test_an_array_is_placed_over_every_card_that_fits(self):
        self.plan("reqp * 0", "galhp * 3600", "gmsap * 3600")
        rc, out, err = self.submit("--placement auto --gpu-mem 24 --array 0-7%4", name="seg", cls="gpu")
        self.assertEqual(rc, 0, (out, err))
        call = self.submitted()[-1]
        self.assertIn("--partition=reqp ", call)
        self.assertIn("--gres=gpu:1 ", call)
        self.assertIn("--array=0-7%4", call)
        self.assertIn("--exclude=%s " % REQP_OUT, call)
        with open(os.path.join(self.g.state, "jobs", "demo", "placed", self.job_id(out))) as fh:
            self.assertIn("gpu_mem=24", fh.read())

    def test_an_array_s_waiting_tasks_move_as_one_and_the_started_stay(self):
        jid, _ = self.placed(name="seg", extra="--placement auto --gpu-mem 24 --array 0-7%4")
        self.plan("reqp * 20000", "galhp * 0", "gmsap * 30000")
        started = (jid + "_0", "demo-seg", "RUNNING", "reqp", "requeue", "None", "4", "32G", "4:00:00", "gres:gpu:1", REQP_OUT, self.OLD, "(null)")
        waiting = self.pending(jid + "_[1-2,5-7:2%4]", name="demo-seg")
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=own(started, waiting))
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("moved 1", out)
        tasks = ",".join("%s_%d" % (jid, i) for i in (1, 2, 5, 7))
        self.assertEqual(self.updates(), ["scontrol update jobid=%s partition=galhp,gmsap qos=gpu gres=gpu:1 excnodelist=" % tasks])
        # one look a hold: the array's record says when it last moved
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=own(started, waiting))
        self.assertEqual(len(self.updates()), 1)

    def test_an_array_hpcworker_did_not_place_is_left_alone(self):
        rc, out, err = self.submit("--array 0-3", name="plain", cls="gpu")
        self.assertEqual(rc, 0, (out, err))
        self.plan("reqp * 20000", "galhp * 0", "gmsap * 0")
        rc, out, err = self.run_tool("job replace", FAKE_SQUEUE_LIST=own(self.pending(self.job_id(out) + "_[0-3]", name="demo-plain", parts="gvohp")))
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(self.updates(), [])


class UsageTest(PlacementBase):
    def test_asked_against_used_per_name(self):
        rc, out, err = self.submit("", name="train")
        a = self.job_id(out)
        rc, out, err = self.submit("", name="train")
        b = self.job_id(out)
        acct = "\n".join(["%s|64G||8|02:51:55|02:04:28|COMPLETED" % a, "%s.batch||4539908K|8|02:51:50|02:04:28|COMPLETED" % a,
                          "%s|64G||8|05:00.000|01:00:00|OUT_OF_MEMORY" % b, "%s.batch||1972.50M|8|05:00.000|01:00:00|OUT_OF_MEMORY" % b])
        rc, out, err = self.run_tool("job usage --project demo", FAKE_SACCT=acct)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB usage train runs 2 mem asked 64G peak 4.3G fit 7G cores asked 8 used 1.4 card peak 0.0G out-of-memory", out)

    def test_the_peak_on_the_card_is_read_where_the_site_gathers_it(self):
        rc, out, err = self.submit("", name="seg")
        a = self.job_id(out)
        acct = "\n".join(["%s|96G||8|01:00:00|01:00:00|COMPLETED|" % a,
                          "%s.batch||31879756K|8|01:00:00|01:00:00|COMPLETED|cpu=01:04:17,gres/gpumem=16022M,gres/gpuutil=90,mem=31879756K" % a])
        rc, out, err = self.run_tool("job usage --project demo", FAKE_SACCT=acct)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("card peak 15.6G", out)


class ShareTest(PlacementBase):
    """job share and job pack (33): a kind's measured share of its card from the site's own job accounting, the runs that
    fit one card of each type, and N commands side by side in one job, under MPS where the job holds a card."""

    def test_a_kind_s_share_and_how_many_fit_each_card(self):
        ids = []
        for name in ("dg_rot_cios_base_s1", "dg_rot_cios_base_s2", "big_s1", "dg_rot_cios_base_s3"):
            rc, out, err = self.submit("", name=name)
            self.assertEqual(rc, 0, (out, err))
            ids.append(self.job_id(out))
        a, b, c, d = ids
        acct = "\n".join([
            "%s.batch|cpu=01:20:00,gres/gpumem=12960M,gres/gpuutil=80,mem=41825712K|cpu=01:00:00,gres/gpumem=9000M,gres/gpuutil=60|COMPLETED" % a,
            "%s.batch|cpu=01:20:00,gres/gpumem=13000M,gres/gpuutil=90|cpu=01:00:00,gres/gpuutil=70|COMPLETED" % b,
            "%s.batch|cpu=01:00:00,gres/gpumem=40000M,gres/gpuutil=95|cpu=01:00:00,gres/gpuutil=95|COMPLETED" % c,
            # a run under MPS: its card memory is gathered and its card use read as 0, which says nothing of its use
            "%s.batch|cpu=01:00:00,gres/gpumem=12000M,gres/gpuutil=0|cpu=01:00:00,gres/gpuutil=0|COMPLETED" % d,
            "%s|||COMPLETED" % a])
        rc, out, err = self.run_tool("job share --project demo", FAKE_SACCT=acct)
        self.assertEqual(rc, 0, (out, err))
        # three runs of one kind, one under MPS: peak 12.7 GB, mean use 65 per cent of the two that held a card alone
        line = [l for l in out.splitlines() if l.startswith("HPCW-JOB share dg_rot_cios_base ")][0]
        self.assertIn("runs 3 card peak 12.7G use 65%", line)
        self.assertIn("nvidia_h200:3", line)       # by compute: 100 / (65 x 0.5) = 3.07; by memory 9
        self.assertIn("nvidia_a30:1", line)        # by memory: 24 / (12.7 x 1.2) = 1.57
        big = [l for l in out.splitlines() if l.startswith("HPCW-JOB share big ")][0]
        self.assertIn("nvidia_h200:2", big)        # 100 / (95 x 0.5) = 2.1
        with open(os.path.join(self.g.state, "jobs", "demo", "share.tsv")) as fh:
            self.assertIn("dg_rot_cios_base\t3\t12.7\t65\t", fh.read())

    def pack(self, extra, command, **env):
        return self.run_tool("job pack %s -- bash -c %s" % (extra, G.shq(command)) if hasattr(G, "shq")
                             else "job pack %s -- bash -c '%s'" % (extra, command), **env)

    def test_pack_runs_each_item_side_by_side_and_keeps_the_worst_exit(self):
        rc, out, err = self.pack("--items 'a b c' --var PLAN --mps off", 'echo "item $PLAN packed $HPCW_PACK"; [ "$PLAN" != b ] || exit 3')
        self.assertEqual(rc, 3, (out, err))
        for item in ("a", "b", "c"):
            self.assertIn("[%s] item %s packed 1" % (item, item), out)
        self.assertIn("HPCW-JOB pack ended, worst exit 3", out)

    def test_pack_without_a_card_takes_turns_and_mps_on_is_refused(self):
        rc, out, err = self.pack("--items 'a'", "true", CUDA_VISIBLE_DEVICES="")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("taking turns on the card (no MPS here)", out)
        rc, out, err = self.pack("--items 'a' --mps on", "true", CUDA_VISIBLE_DEVICES="")
        self.assertNotEqual(rc, 0)
        self.assertIn("--mps on: no card in this job", out + err)
        for extra in ("--items ''", "--items 'a b' --var lower", "--items 'a/b'", "--items a --mps maybe"):
            rc, out, err = self.pack(extra, "true")
            self.assertNotEqual(rc, 0, extra)


class CheckpointMoveTest(PlacementBase):
    """The checkpoint-boundary move (34): a job marks its checkpoints with job mark, and job replace moves a running placed
    GPU job whose marker is fresh to a card free now that runs its kind faster by the project's measured rates, by
    requeuehold, update and release, never while a waiting job fits that card, and sends it back where it ran when it
    has not started there within the return time."""

    A30_NODE = ("NodeName=arw4 CPUAlloc=32 CPUEfctv=32 CPUTot=32 RealMemory=257300 AllocMem=200000 State=ALLOCATED "
                "Partitions=reqp CfgTRES=cpu=32,mem=257300M,gres/gpu=10,gres/gpu:nvidia_a30=10 "
                "AllocTRES=cpu=32,mem=200000M,gres/gpu=10,gres/gpu:nvidia_a30=10")
    H200_NODE = ("NodeName=msa1 CPUAlloc=8 CPUEfctv=128 CPUTot=128 RealMemory=769600 AllocMem=100000 State=MIXED "
                 "Partitions=gmsap,reqp CfgTRES=cpu=128,mem=769600M,gres/gpu=4,gres/gpu:nvidia_h200=4 "
                 "AllocTRES=cpu=8,mem=100000M,gres/gpu=3,gres/gpu:nvidia_h200=3")

    def setUp(self):
        super().setUp()
        self.marks = os.path.join(self.g.state, "jobs", "demo", "checkpoints")

    def running_job(self, rates=("nvidia_a30 1000", "nvidia_h200 1400"), marked=60):
        """a placed job running on an A30, its checkpoint MARKED seconds ago (None for none), and the project's rates"""
        self.plan("reqp * 0", "galhp * 3600", "gmsap * 3600")
        rc, out, err = self.submit("--placement auto --gpu-mem 24")
        self.assertEqual(rc, 0, (out, err))
        jid = self.job_id(out)
        with open(os.path.join(self.g.state, "jobs", "demo", "speeds"), "w", newline="\n") as fh:
            fh.write("# NAME_REGEX CARD_TYPE STEPS_AN_HOUR\n" + "".join("^demo-fit$ %s\n" % r for r in rates))
        if marked is not None:
            os.makedirs(self.marks, exist_ok=True)
            marker = os.path.join(self.marks, jid)
            open(marker, "w").close()
            os.utime(marker, (time.time() - marked, time.time() - marked))
        return jid

    def replace(self, jid, extra="", nodes=None, waiting="", **env):
        row = "%s|demo-fit|reqp|requeue|4|32G|gres:gpu:nvidia_a30:1|arw4|10:00:00|(null)" % jid
        e = {"FAKE_SQUEUE_RUNNING": row, "FAKE_SCONTROL_NODES": "\n".join(nodes or (self.A30_NODE, self.H200_NODE)),
             "FAKE_SQUEUE_WAITING": waiting, "HPCW_CHECKPOINT_TRIES": "1"}
        e.update(env)
        return self.run_tool("job replace " + extra, **e)

    def scontrols(self):
        # the calls a move makes: not the node read, nor the host lists the submission compressed
        return [c for c in self.g.calls() if c.startswith("scontrol ") and not c.startswith(("scontrol -o show", "scontrol show hostlist"))]

    def test_mark_sets_the_marker_to_the_oldest_checkpoint_and_waits_for_a_missing_one(self):
        old, new = os.path.join(self.work, "a.npz"), os.path.join(self.work, "b.npz")
        for path, ago in ((old, 500), (new, 100)):
            open(path, "w").close()
            os.utime(path, (time.time() - ago, time.time() - ago))
        env = {"SLURM_JOB_ID": "4242", "HPCW_CHECKPOINTS": G.posix(self.marks)}
        rc, out, err = self.run_tool("job mark -- '%s' '%s'" % (G.posix(old), G.posix(new)), **env)
        self.assertEqual(rc, 0, (out, err))
        marker = os.path.join(self.marks, "4242")
        self.assertAlmostEqual(os.path.getmtime(marker), os.path.getmtime(old), delta=2)
        os.utime(marker, (1000, 1000))
        gone = os.path.join(self.work, "gone.npz")
        rc, out, err = self.run_tool("job mark -- '%s' '%s'" % (G.posix(old), G.posix(gone)), **env)
        self.assertEqual(rc, 0, (out, err))
        # one run has no checkpoint yet: the marker is left as it was
        self.assertAlmostEqual(os.path.getmtime(marker), 1000, delta=1)
        rc, out, err = self.run_tool("job mark", **env)
        self.assertAlmostEqual(os.path.getmtime(marker), time.time(), delta=30)
        rc, out, err = self.run_tool("job mark")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("not inside a job hpcworker submitted", out)

    def test_submit_hands_every_job_its_checkpoint_folder(self):
        rc, out, err = self.submit("")
        self.assertEqual(rc, 0, (out, err))
        with open(os.path.join(self.g.sched, "checkpoints_env")) as fh:
            self.assertEqual(fh.read().split("\n")[-2], G.posix(self.marks))
        self.assertTrue(os.path.isdir(self.marks))

    def test_a_running_job_just_after_a_checkpoint_moves_to_a_faster_free_card(self):
        jid = self.running_job()
        rc, out, err = self.replace(jid)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB moved-running %s demo-fit reqp/requeue nvidia_a30 on arw4 -> gmsap/gpu nvidia_h200 on msa1" % jid, out)
        self.assertIn("looked at 1 running job(s) just after a checkpoint, moved 1", out)
        # its requeue flag read, made requeueable for the move, held, moved, released, and set back for a QoS never preempted
        self.assertEqual(self.scontrols(), ["scontrol show job %s" % jid, "scontrol update jobid=%s requeue=1" % jid,
                                            "scontrol requeuehold %s" % jid,
                                            "scontrol update jobid=%s partition=gmsap qos=gpu gres=gpu:nvidia_h200:1 excnodelist=" % jid,
                                            "scontrol release %s" % jid, "scontrol update jobid=%s requeue=0" % jid])
        with open(os.path.join(self.g.state, "jobs", ".checkpoint-moves", jid)) as fh:
            self.assertEqual(fh.read().split()[1:], ["demo", "reqp", "requeue", "gpu:nvidia_a30:1", "-", "0"])
        with open(os.path.join(self.g.state, "jobs", "replace.log")) as fh:
            self.assertIn("moved-running %s demo-fit" % jid, fh.read())
        # moved once: the next look leaves it to start where it was sent
        rc, out, err = self.replace(jid)
        self.assertEqual(len([c for c in self.scontrols() if "requeuehold" in c]), 1)

    def test_no_move_without_a_fresh_marker_both_rates_or_the_gain(self):
        cases = (({"marked": 3600}, None), ({"marked": None}, None),
                 ({"rates": ("nvidia_h200 1400",)}, "no measured rate for it on nvidia_a30"),
                 ({"rates": ("nvidia_a30 1000",)}, "no measured rate for it on the free nvidia_h200 card"),
                 ({"rates": ("nvidia_a30 1000", "nvidia_h200 1030")}, "would not run it faster by the time it has left"),
                 ({"rates": ("nvidia_a30 1000", "nvidia_h200 1060")}, " s, not more than 300 s"))
        for kw, said in cases:
            jid = self.running_job(**kw)
            rc, out, err = self.replace(jid, "--dry-run")
            self.assertEqual(rc, 0, (out, err))
            if said is None:
                self.assertIn("looked at 0 running job(s)", out, kw)
            else:
                self.assertIn("HPCW-JOB stays %s demo-fit on arw4 nvidia_a30: " % jid, out, kw)
                self.assertIn(said, out, kw)
        self.assertEqual([c for c in self.scontrols() if "update" in c or "requeue" in c or "release" in c], [])

    def test_a_waiting_job_that_fits_the_free_card_comes_first(self):
        jid = self.running_job()
        waiting = "\n".join(["gmsap|777|8|64G|gres:gpu:1|Priority", "reqp|777|8|64G|gres:gpu:1|Priority"])
        rc, out, err = self.replace(jid, "--dry-run", waiting=waiting)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("a waiting job fits the free nvidia_h200 card on msa1 first", out)
        # one waiting only for a dependency, or too large for the node's idle cores, takes nothing from it
        waiting = "\n".join(["gmsap|777|8|64G|gres:gpu:1|Dependency", "gmsap|778|200|64G|gres:gpu:1|Priority"])
        rc, out, err = self.replace(jid, "--dry-run", waiting=waiting)
        self.assertIn("HPCW-JOB would-move-running %s demo-fit" % jid, out)

    def test_a_node_short_of_cores_or_memory_holds_no_free_card(self):
        jid = self.running_job()
        for short in (self.H200_NODE.replace("CPUAlloc=8 ", "CPUAlloc=126 "), self.H200_NODE.replace("AllocMem=100000", "AllocMem=750000")):
            rc, out, err = self.replace(jid, "--dry-run", nodes=(self.A30_NODE, short))
            self.assertIn("no other card it fits is free now", out)

    def test_a_refused_requeue_leaves_the_job_where_it_runs(self):
        jid = self.running_job()
        with open(os.path.join(self.g.sched, "requeue_fail"), "w") as fh:
            fh.write("slurm_requeue error: Requested operation is presently disabled\n")
        rc, out, err = self.replace(jid)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("kept %s demo-fit: Slurm refused the requeue: slurm_requeue error" % jid, out)
        self.assertNotIn("partition=", " ".join(self.scontrols()))
        self.assertEqual(self.scontrols()[-1], "scontrol update jobid=%s requeue=0" % jid)

    def test_a_moved_job_not_started_in_time_goes_back_and_a_started_one_is_let_be(self):
        jid = self.running_job()
        records = os.path.join(self.g.state, "jobs", ".checkpoint-moves")
        os.makedirs(records, exist_ok=True)
        with open(os.path.join(records, jid), "w", newline="\n") as fh:
            fh.write("%d demo reqp requeue gpu:nvidia_a30:1 - 0\n" % (time.time() - 1000))
        with open(os.path.join(records, "40999999"), "w", newline="\n") as fh:
            fh.write("%d demo reqp requeue gpu:1 - 1\n" % (time.time() - 100))
        self.g.jobs(["%s|PENDING|Resources|N/A|" % jid, "40999999|RUNNING|None|N/A|msa1"])
        rc, out, err = self.replace(jid, FAKE_SQUEUE_RUNNING="")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("returned %s to reqp/requeue gpu:nvidia_a30:1: not started within 900 s of its move" % jid, out)
        self.assertIn("started 40999999 after its move at a checkpoint (RUNNING)", out)
        self.assertIn("scontrol update jobid=%s partition=reqp qos=requeue gres=gpu:nvidia_a30:1 excnodelist=" % jid, self.scontrols())
        self.assertEqual(os.listdir(records), [])

    def test_the_switch_turns_the_running_moves_off(self):
        jid = self.running_job()
        rc, out, err = self.replace(jid, HPCW_CHECKPOINT_MOVES="off")
        self.assertEqual(rc, 0, (out, err))
        self.assertNotIn("running job(s)", out)
        self.assertEqual(self.scontrols(), [])


class AvoidTest(PlacementBase):
    """Nodes every job is kept off (31): the ones placement.exclude lists, the ones that end the jobs of two users or
    more within a minute, and the ones whose probe could not read the account's home; and --prefer, a word's own
    partition, honoured while it costs the job less than HPCW_PLACEMENT_PREFER seconds."""

    def write_exclude(self, text):
        os.makedirs(self.g.state, exist_ok=True)
        with open(os.path.join(self.g.state, "placement.exclude"), "w", newline="\n") as fh:
            fh.write(text)

    def test_a_listed_node_is_left_out_of_every_placement_and_every_job(self):
        self.write_exclude("# kept in service without the home file system\nmsa1\n")
        self.plan("galhp * 3600", "gmsap * 0", "reqp * 7200")
        rc, out, err = self.submit("--placement auto --gpu-mem 24")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("--partition=gmsap,galhp ", self.submitted()[-1])
        self.assertIn("--exclude=msa1 ", self.submitted()[-1])
        for c in self.asked():
            if "--partition=gmsap" in c or "--partition=reqp" in c:
                self.assertIn("msa1", c)
        # a job sent with no placement is kept off it too
        rc, out, err = self.submit("", cls="batch", name="plain")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("--exclude=msa1 ", self.submitted()[-1])
        rc, out, err = self.submit("", cls="batch", name="plain2", HPCW_PLACEMENT_EXCLUDE="tta1")
        self.assertIn("--exclude=msa1,tta1 ", self.submitted()[-1])

    def test_a_node_that_ends_the_jobs_of_two_users_at_once_is_left_out(self):
        acct = "\n".join(["msa1|u1|1", "msa1|u2|0", "msa1|u1|3", "alh1|u1|2", "alh1|u1|2", "alh1|u1|2", "arw4|u1|900", "arw4|u2|900", "arw4|u3|900"])
        self.plan("galhp * 3600", "gmsap * 0", "reqp * 7200")
        rc, out, err = self.submit("--placement auto --gpu-mem 24", FAKE_SACCT=acct)
        self.assertEqual(rc, 0, (out, err))
        call = self.submitted()[-1]
        self.assertIn("--exclude=msa1 ", call)
        self.assertNotIn("alh1", call)   # one user's own failures mark nothing
        self.assertNotIn("arw4", call)   # nor do jobs that ran a while

    def test_a_node_whose_probe_fails_is_left_out_for_an_hour(self):
        srun = os.path.join(self.g.bin, "srun")
        with open(srun, "w", newline="\n") as fh:
            fh.write('#!/bin/bash\necho "srun $*" >> "$FAKE_SCHED_DIR/calls"\nnode=""\n'
                     'while [ $# -gt 0 ]; do case "$1" in -w) node=$2; shift 2;; stat) shift 3; break;; *) shift;; esac; done\n'
                     'case "$node" in\n  msa1) echo "stat: cannot stat $1: No such file or directory" >&2; exit 1;;\n'
                     '  alh1) echo "srun: error: Unable to allocate resources: Immediate execution impossible" >&2; exit 1;;\n'
                     '  *) printf "%s\\n" "$@";;\nesac\n')
        os.chmod(srun, 0o755)
        rc, out, err = self.run_tool("job probe --max 20")
        self.assertNotEqual(rc, 0)
        self.assertIn("run it inside a Slurm job", out + err)
        rc, out, err = self.run_tool("job probe --max 20", SLURM_JOB_ID="40970000")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB probe msa1 fail: stat: cannot stat", out)
        self.assertIn("HPCW-JOB probe alh1 unknown", out)
        self.assertIn("HPCW-JOB probe arw4 ok", out)
        probes = [c for c in self.g.calls() if c.startswith("srun ")]
        self.assertTrue(all("--immediate=10" in c and "-t 1" in c for c in probes), probes)
        # asked within the hour, a node is not asked again
        rc, out, err = self.run_tool("job probe --max 20", SLURM_JOB_ID="40970000")
        self.assertIn("HPCW-JOB probe asked 0 node(s)", out)
        self.plan("galhp * 3600", "gmsap * 0", "reqp * 7200")
        rc, out, err = self.submit("--placement auto --gpu-mem 24")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("--exclude=msa1 ", self.submitted()[-1])

    def test_a_preferred_partition_is_honoured_unless_another_starts_the_job_ten_minutes_sooner(self):
        self.plan("galhp * 400", "gmsap * 0", "reqp * 0")
        rc, out, err = self.submit("--placement auto --gpu-mem 24 --prefer galhp")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose galhp/gpu gpu:1 (never preempted)", out)
        self.assertIn("--partition=galhp ", self.submitted()[-1])
        with open(os.path.join(self.g.state, "jobs", "demo", "placed", self.job_id(out))) as fh:
            self.assertIn(" prefer=galhp", fh.read())
        self.plan("galhp * 1800", "gmsap * 0", "reqp * 0")
        rc, out, err = self.submit("--placement auto --gpu-mem 24 --prefer galhp", name="late")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("chose gmsap,galhp/gpu gpu:1 (never preempted)", out)
        rc, out, err = self.submit("--prefer galhp", name="bare")
        self.assertNotEqual(rc, 0)
        self.assertIn("--prefer is --placement's", out + err)


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
        for want in ("--partition=gmsap,gvohp,galhp", "--qos=gpu", "--gres=gpu:2", "--time=1-00:00:00", "--cpus-per-task=8", "--mem=64G"):
            self.assertIn(want, call)

    def test_after_becomes_one_dependency(self):
        rc, out, err = self.submit(extra="--after 41 --after 42:ok --after 43:any")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("--dependency=afterany:41,afterok:42,afterany:43 --kill-on-invalid-dep=yes", self.sbatch_calls()[-1])

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

    def test_an_array_logs_per_task_and_counts_its_tasks(self):
        rc, out, err = self.submit(name="scan", extra="--array 0-63%32 --after 41:ok")
        self.assertEqual(rc, 0, (out, err))
        call = self.sbatch_calls()[-1]
        self.assertIn("--array=0-63%32", call)
        self.assertIn("/jobs/demo/logs/scan_%A_%a.out", call)
        jid = out.split()[2]
        self.assertTrue(out.rstrip().endswith("scan_%s_%%a.out" % jid), out)
        with open(self.ledger) as fh:
            row = fh.readline().rstrip("\n").split("\t")
        self.assertEqual(row[9:], ["0-63%32", "41"])
        jobs = os.path.join(self.g.sched, "jobs")
        open(jobs, "w").close()
        sacct = "\n".join(["%s_0|COMPLETED|0:0|asx1" % jid, "%s_1|RUNNING|0:0|asx2" % jid, "%s_[2-63%%32]|PENDING|0:0|None assigned" % jid])
        rc, out, err = self.g.run("job status --project demo --json", FAKE_SACCT=sacct)
        self.assertEqual(rc, 0, (out, err))
        import json
        job = json.loads(out)["jobs"][0]
        self.assertEqual((job["state"], job["array"], job["after"]), ("ARRAY COMPLETED:1,RUNNING:1,PENDING:62", "0-63%32", "41"))
        rc, out, err = self.g.run("job log --project demo %s" % jid)
        self.assertNotEqual(rc, 0)
        with open(os.path.join(self.g.state, "jobs", "demo", "logs", "scan_%s_7.out" % jid), "w") as fh:
            fh.write("task seven\n")
        rc, out, err = self.g.run("job log --project demo %s --task 7" % jid)
        self.assertEqual(out, "task seven\n")
        for bad in ("0-", "a", "1%0", "0-63%32%2", "1;2"):
            self.assertNotEqual(self.submit(name="x", extra="--array '%s'" % bad)[0], 0, bad)

    def test_status_with_no_jobs(self):
        rc, out, err = self.g.run("job status --project demo")
        self.assertEqual((rc, out.strip()), (0, "HPCW-JOB none for demo"))

    def test_a_refusal_says_why_and_records_nothing(self):
        with open(os.path.join(self.g.sched, "sbatch_fail"), "w") as fh:
            fh.write("sbatch: error: Invalid qos specification\n")
        rc, out, err = self.submit(cls="gpu", name="train")
        self.assertEqual(rc, 1)
        self.assertEqual(out.strip(), "HPCW-JOB refused train gmsap,gvohp,galhp/gpu: sbatch: error: Invalid qos specification")
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

    def test_a_card_asked_of_a_class_that_gets_none_is_refused_aloud(self):
        # (32) a batch job sent with --gpus 1 started on a node with no card, and nothing said why
        for cls in ("batch", "cpu"):
            rc, out, err = self.submit(extra="--gpus 1", cls=cls)
            self.assertNotEqual(rc, 0, cls)
            self.assertIn("--gpus is for the gpu class; a %s job gets no card" % cls, out + err)
        self.assertEqual(self.sbatch_calls(), [])

    def test_the_project_s_admission_may_refuse_a_job_before_anything_is_asked(self):
        # (32) <state>/jobs/<project>/admit, handed the class, the script and the options, refuses aloud; --check meets it too
        jd = os.path.join(self.g.state, "jobs", "demo")
        os.makedirs(jd, exist_ok=True)
        admit = os.path.join(jd, "admit")
        with open(admit, "w", newline="\n") as fh:
            fh.write('#!/bin/bash\ncase "$1" in gpu) echo "a GPU job runs on a launched pipeline: $(basename "$2")" >&2; exit 1;; esac\nexit 0\n')
        os.chmod(admit, 0o755)
        for extra in ("", "--check"):
            rc, out, err = self.submit(extra=extra, cls="gpu")
            self.assertNotEqual(rc, 0, extra)
            self.assertIn("HPCW-JOB refused one: the project's admission: a GPU job runs on a launched pipeline: run.sbatch", out)
        self.assertEqual(self.sbatch_calls(), [])
        rc, out, err = self.submit(cls="cpu")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB submitted", out)

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

    def write_script(self, text):
        with open(self.script, "w", newline="\n") as fh:
            fh.write(text)

    def test_a_scripts_own_resources_stand_when_no_flag_names_them(self):
        self.write_script("#!/bin/bash\n#SBATCH --time=2-00:00:00\n#SBATCH -c 16\n#SBATCH --mem-per-cpu=2G\necho hi\n#SBATCH --mem=1G\n")
        self.assertEqual(self.submit()[0], 0)
        call = self.sbatch_calls()[-1]
        for gone in ("--time=", "--cpus-per-task=", "--mem="):
            self.assertNotIn(gone, call)
        # a flag still wins, and an #SBATCH line after the first command is not the header (Slurm reads none there)
        self.write_script("#!/bin/bash\n#SBATCH --time=2-00:00:00\necho hi\n#SBATCH --mem=1G\n")
        self.assertEqual(self.submit(extra="--time 0:30:00")[0], 0)
        call = self.sbatch_calls()[-1]
        self.assertIn("--time=0:30:00", call)
        self.assertIn("--mem=4G", call)
        self.assertIn("--cpus-per-task=1", call)

    def test_placement_follows_the_deployments_profile_not_a_stale_account_copy(self):
        import json
        acct = os.path.join(self.g.hpcw, "profile.json")
        with open(acct, encoding="utf-8") as fh:
            p = json.load(fh)
        # as an account installed before the site gained galhp and its GPU QoS, and before its batch pair
        p.update(partitions_gpu=["gmsap", "gvohp"], qos_gpu="", partition_cpu_batch="", qos_batch="")
        with open(acct, "w", encoding="utf-8") as fh:
            json.dump(p, fh, indent=1)
        self.assertEqual(self.submit(cls="gpu", name="train")[0], 0)
        self.assertIn("--partition=gmsap,gvohp,galhp --qos=gpu", self.sbatch_calls()[-1])
        self.assertEqual(self.submit(cls="batch", name="long")[0], 0)
        self.assertIn("--partition=reqp --qos=requeue --requeue", self.sbatch_calls()[-1])

    def test_several_partitions_of_the_class_start_on_whichever_frees_first(self):
        rc, out, err = self.submit(cls="gpu", name="train", extra="--partition galhp,gmsap --no-requeue")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("--partition=galhp,gmsap --qos=gpu --gres=gpu:1 --no-requeue", self.sbatch_calls()[-1])
        self.assertIn(" galhp,gmsap/gpu ", out)

    def test_one_partition_of_the_class_and_requeue_by_the_job(self):
        rc, out, err = self.submit(cls="gpu", name="train", extra="--partition gvohp --requeue")
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("--partition=gvohp --qos=gpu --gres=gpu:1 --requeue --open-mode=append", self.sbatch_calls()[-1])
        self.assertEqual(self.submit(cls="batch", name="long", extra="--no-requeue")[0], 0)
        self.assertIn("--qos=requeue --no-requeue", self.sbatch_calls()[-1])
        n = len(self.sbatch_calls())
        for extra, cls in (("--partition secp", "gpu"), ("--partition gmsap", "cpu"), ("--partition 'a b'", "cpu"),
                           ("--partition galhp,secp", "gpu"), ("--partition galhp,", "gpu"), ("--partition ,galhp", "gpu"),
                           ("--partition 'galhp,*'", "gpu")):
            rc, out, err = self.submit(cls=cls, name="x", extra=extra)
            self.assertNotEqual(rc, 0, extra)
        self.assertEqual(len(self.sbatch_calls()), n)

    def test_a_gpu_job_on_the_batch_partition_takes_its_qos_and_a_card_by_type(self):
        rc, out, err = self.submit(cls="gpu", name="flux", extra="--partition reqp --gpu-type nvidia_rtx_pro_4500_blackwell")
        self.assertEqual(rc, 0, (out, err))
        self.assertRegex(out, r"^HPCW-JOB submitted \d+ flux reqp/requeue log ")
        self.assertIn("--partition=reqp --qos=requeue --gres=gpu:nvidia_rtx_pro_4500_blackwell:1 --requeue --open-mode=append",
                      self.sbatch_calls()[-1])
        self.assertEqual(self.submit(cls="gpu", name="det", extra="--partition reqp --gpus 2 --no-requeue")[0], 0)
        self.assertIn("--partition=reqp --qos=requeue --gres=gpu:2 --no-requeue", self.sbatch_calls()[-1])
        self.assertEqual(self.submit(cls="gpu", name="train", extra="--gpu-type nvidia_l40s")[0], 0)
        self.assertIn("--partition=gmsap,gvohp,galhp --qos=gpu --gres=gpu:nvidia_l40s:1 --no-requeue", self.sbatch_calls()[-1])
        n = len(self.sbatch_calls())
        # the batch partition goes alone: one job carries one QoS, and the batch partition takes only its own
        for extra, cls in (("--gpu-type nvidia_a30", "batch"), ("--gpu-type 'a b'", "gpu"), ("--partition reqp,galhp", "gpu"),
                           ("--partition secp", "gpu")):
            rc, out, err = self.submit(cls=cls, name="x", extra=extra)
            self.assertNotEqual(rc, 0, extra)
        self.assertIn("or the batch partition reqp", err)
        self.assertEqual(len(self.sbatch_calls()), n)

    def test_the_job_gets_the_callers_environment_and_none_of_hpcworkers(self):
        # This grid is the test's own, so its fake sbatch is swapped for one that writes its environment down.
        dump = os.path.join(self.td, "env.txt")
        with open(os.path.join(self.g.bin, "sbatch"), "w", newline="\n") as fh:
            fh.write("#!/bin/bash\nenv > '%s'\necho 4242\n" % G.posix(dump))
        os.chmod(os.path.join(self.g.bin, "sbatch"), 0o755)
        rc, out, err = self.g.run("job submit --project demo --name one --class cpu --dir '%s' -- run.sbatch" % G.posix(self.work),
                                  SEED="caller-seed", MY_VAR="kept",
                                  HPCW_GATE="1", SSH_ORIGINAL_COMMAND="x")
        self.assertEqual(rc, 0, (out, err))
        with open(dump) as fh:
            env = dict(line.rstrip("\n").split("=", 1) for line in fh if "=" in line)
        self.assertEqual(env.get("SEED"), "caller-seed")
        self.assertEqual(env.get("MY_VAR"), "kept")
        for gone in ("HPCW_GATE", "SSH_ORIGINAL_COMMAND", "RUNTIME", "RUNTIME_BIN", "HPCW_NODE_TMP"):
            self.assertNotIn(gone, env)
        self.assertFalse([k for k in env if k.startswith("P_")])

    def test_cancel_names_ids_outside_the_ledger_and_cancels_the_rest(self):
        jid = self.submit(name="one")[1].split()[2]
        rc, out, err = self.g.run("job cancel --project demo 999 %s" % jid)
        self.assertEqual(rc, 1)
        self.assertEqual(out.splitlines(), ["HPCW-JOB not-in-ledger 999", "HPCW-JOB cancelled %s" % jid])
        self.assertIn("scancel %s" % jid, self.g.calls())

    def test_status_reads_sacct_alone_when_squeue_is_silent(self):
        jid = self.submit(name="one")[1].split()[2]
        open(os.path.join(self.g.sched, "squeue_fail"), "w").close()
        rc, out, err = self.g.run("job status --project demo --last 2000", FAKE_SACCT="%s|RUNNING|0:0|asx3" % jid)
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("HPCW-JOB %s one RUNNING on asx3" % jid, out)

    def test_a_long_name_and_the_version(self):
        name = "fetch-" + "x" * 58
        self.assertEqual(self.submit(name=name)[0], 0)
        self.assertNotEqual(self.submit(name=name + "y")[0], 0)
        rc, out, err = self.g.run("job version")
        self.assertEqual((rc, out.strip()), (0, "HPCW-JOB version %s interface 2" % G.CURRENT_VERSION))


if __name__ == "__main__":
    unittest.main()
