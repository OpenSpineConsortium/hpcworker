"""Adapter parser tests: each parser reads a captured scheduler output (tests/fixtures) on
stdin and must print STATE|NODE|RAW with STATE normalised. Slurm's fixtures were captured
on the Wayne State grid; the PBS and LSF fixtures follow the documented output formats
(no PBS or LSF cluster was available), which is exactly why the parsers are tested here."""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures")
ADAPTERS = os.path.join(ROOT, "lib", "adapters")
# on Windows the first "bash" on a native Python's PATH can be WSL's, which cannot read C:/ paths;
# tests/run.sh passes Git Bash in HPCW_BASH
BASH = os.environ.get("HPCW_BASH") or "bash"


def posix(path):
    # Git Bash on Windows understands C:/... paths inside quotes; pass forward slashes
    return path.replace("\\", "/")


def run(adapter, func, fixture=None, stdin_text=None):
    env = dict(os.environ)
    env["HPCW_PYTHON"] = os.environ.get("HPCW_PYTHON") or ("python" if os.name == "nt" else sys.executable)
    script = "source '%s/%s.sh' && %s" % (posix(ADAPTERS), adapter, func)
    data = stdin_text
    if fixture:
        with open(os.path.join(FIX, fixture)) as fh:
            data = fh.read()
    p = subprocess.run([BASH, "-c", script], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, env=env)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


class Slurm(unittest.TestCase):
    def test_submit_id_before_semicolon(self):
        rc, out, _ = run("slurm", "slurm_parse_submit", "sbatch_parsable.txt")
        self.assertEqual((rc, out), (0, "40496512"))

    def test_submit_bare_id(self):
        rc, out, _ = run("slurm", "slurm_parse_submit", stdin_text="12345\n")
        self.assertEqual((rc, out), (0, "12345"))

    def test_submit_error_text_is_not_an_id(self):
        rc, out, _ = run("slurm", "slurm_parse_submit", stdin_text="sbatch: error: Batch job submission failed: Invalid qos specification\n")
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, "")

    def test_squeue_running(self):
        rc, out, _ = run("slurm", "slurm_parse_squeue", "squeue_running.txt")
        self.assertEqual((rc, out), (0, "RUNNING|asx15|RUNNING"))

    def test_squeue_pending(self):
        rc, out, _ = run("slurm", "slurm_parse_squeue", "squeue_pending.txt")
        self.assertEqual((rc, out), (0, "PENDING||PENDING"))

    def test_squeue_empty_means_gone(self):
        rc, out, _ = run("slurm", "slurm_parse_squeue", stdin_text="")
        self.assertNotEqual(rc, 0)

    def test_sacct_completed(self):
        rc, out, _ = run("slurm", "slurm_parse_sacct", "sacct_completed.txt")
        self.assertEqual((rc, out), (0, "DONE|asx15|COMPLETED"))

    def test_sacct_cancelled_by_user(self):
        rc, out, _ = run("slurm", "slurm_parse_sacct", "sacct_cancelled.txt")
        self.assertEqual((rc, out), (0, "FAILED||CANCELLED by 12345"))

    def test_sacct_timeout(self):
        rc, out, _ = run("slurm", "slurm_parse_sacct", "sacct_timeout.txt")
        self.assertEqual((rc, out), (0, "FAILED|csc1|TIMEOUT"))

    def test_normalise_table(self):
        for raw, want in (("COMPLETING", "RUNNING"), ("CONFIGURING", "PENDING"), ("PREEMPTED", "FAILED"), ("REQUEUED", "PENDING"), ("OUT_OF_MEMORY", "FAILED"), ("BOGUS", "UNKNOWN")):
            rc, out, _ = run("slurm", "hpcw_normalise_state slurm %s" % raw)
            self.assertEqual(out, want, raw)


class PBS(unittest.TestCase):
    def test_submit(self):
        rc, out, _ = run("pbs", "pbs_parse_submit", "qsub_submit.txt")
        self.assertEqual((rc, out), (0, "7890123.pbsserver01"))

    def test_running_first_host_only(self):
        rc, out, err = run("pbs", "pbs_parse_qstat_json", "qstat_running.json")
        self.assertEqual((rc, out), (0, "RUNNING|cn042|R"), err)

    def test_finished_ok(self):
        rc, out, err = run("pbs", "pbs_parse_qstat_json", "qstat_finished.json")
        self.assertEqual((rc, out), (0, "DONE|cn042|F"), err)

    def test_finished_nonzero(self):
        rc, out, err = run("pbs", "pbs_parse_qstat_json", "qstat_failed.json")
        self.assertEqual((rc, out), (0, "FAILED|cn044|F"), err)

    def test_queued(self):
        rc, out, err = run("pbs", "pbs_parse_qstat_json", "qstat_queued.json")
        self.assertEqual((rc, out), (0, "PENDING||Q"), err)

    def test_garbage(self):
        rc, out, _ = run("pbs", "pbs_parse_qstat_json", stdin_text="qstat: Unknown Job Id 1.x\n")
        self.assertNotEqual(rc, 0)
        self.assertTrue(out.startswith("UNKNOWN|"))


class LSF(unittest.TestCase):
    def test_submit(self):
        rc, out, _ = run("lsf", "lsf_parse_submit", "bsub_submit.txt")
        self.assertEqual((rc, out), (0, "4471203"))

    def test_run_strips_slot_count(self):
        rc, out, _ = run("lsf", "lsf_parse_bjobs", "bjobs_run.txt")
        self.assertEqual((rc, out), (0, "RUNNING|c1n07|RUN"))

    def test_pend(self):
        rc, out, _ = run("lsf", "lsf_parse_bjobs", "bjobs_pend.txt")
        self.assertEqual((rc, out), (0, "PENDING||PEND"))

    def test_done(self):
        rc, out, _ = run("lsf", "lsf_parse_bjobs", "bjobs_done.txt")
        self.assertEqual((rc, out), (0, "DONE|c1n07|DONE"))

    def test_exit(self):
        rc, out, _ = run("lsf", "lsf_parse_bjobs", "bjobs_exit.txt")
        self.assertEqual((rc, out), (0, "FAILED|c1n09|EXIT"))

    def test_not_found(self):
        rc, out, _ = run("lsf", "lsf_parse_bjobs", stdin_text="Job <1> is not found\n")
        self.assertNotEqual(rc, 0)


class Common(unittest.TestCase):
    def test_node_tmp_pattern_expands_job_vars_only(self):
        rc, out, _ = run("slurm", "USER=stu SLURM_JOB_ID=99 HPCW_NODE_TMP_PATTERN='/tmp/$USER/hpcworker_$SLURM_JOB_ID' hpcw_node_tmp")
        self.assertEqual((rc, out), (0, "/tmp/stu/hpcworker_99"))

    def test_node_tmp_does_not_trust_tmpdir_by_default(self):
        rc, out, _ = run("slurm", "USER=stu SLURM_JOB_ID=7 TMPDIR=/rs/ceph/tmp HPCW_NODE_TMP_PATTERN= HPCW_NODE_TMP_VAR= hpcw_node_tmp")
        self.assertEqual(rc, 0)
        self.assertFalse(out.startswith("/rs/ceph"), out)

    def test_node_tmp_uses_site_var_when_set(self):
        rc, out, _ = run("slurm", "USER=stu SLURM_JOB_ID=7 SLURM_TMPDIR=/local/7 HPCW_NODE_TMP_PATTERN= HPCW_NODE_TMP_VAR=SLURM_TMPDIR hpcw_node_tmp")
        self.assertEqual((rc, out), (0, "/local/7/stu/hpcworker_7"))

    def test_runtime_exec_refuses_outside_a_job(self):
        rc, out, err = run("slurm", "unset SLURM_JOB_ID PBS_JOBID LSB_JOBID JOB_ID HPCW_JOB_ID; hpcw_runtime_exec /img true")
        self.assertEqual(rc, 97)
        self.assertIn("REFUSING", err)

    def test_json_str_escapes(self):
        rc, out, _ = run("slurm", 'hpcw_json_str "a\\"b\\\\c"')
        self.assertEqual((rc, out), (0, '"a\\"b\\\\c"'))


if __name__ == "__main__":
    unittest.main()
