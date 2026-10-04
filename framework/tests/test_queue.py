"""`hpcworker queue report` (greg, 2026-10-04 15:19Z: the requeue waits), against the fake scheduler of fakegrid.py:
records planted in its sacct cover waits of 30 s, 5 min, 4 h and 2 d on reqp/requeue, 20 s to 6 min on secp/secondary,
a job still pending, one preempted, one cancelled before it started, one that timed out, one whose Start is before its
Submit, and one running with no End. Then the per-partition lines, the counts, the footer, the header's count and
query, the one exact sacct argv (and no sbatch, squeue or scancel), the sinfo `--limits` adds, every refusal, and
the days-from-civil formula alone against dates python computes. Nothing reaches a real scheduler."""
import calendar
import datetime
import os
import re
import tempfile
import unittest

import fakegrid as G

# sacct -X -n -P --format=JobID,JobName,Partition,QOS,Submit,Start,End,State,Timelimit,NodeList, as the comment in
# lib/adapters/slurm.sh describes the fields (the cluster's local time, no zone; Unknown and None where a job has not started)
RECORDS = [
    "40500001|hpcw_worker|reqp|requeue|2026-10-01T08:00:00|2026-10-01T08:00:30|2026-10-01T09:00:30|COMPLETED|08:00:00|asx10",   # 30 s, ran 1 h
    "40500002|hpcw_worker|reqp|requeue|2026-10-01T10:00:00|2026-10-01T10:05:00|2026-10-01T12:05:00|COMPLETED|08:00:00|asx11",   # 5 min, 2 h
    "40500003|hpcw_worker|reqp|requeue|2026-10-01T12:00:00|2026-10-01T16:00:00|2026-10-01T19:00:00|COMPLETED|08:00:00|asx12",   # 4 h, 3 h
    "40500004|hpcw_worker|reqp|requeue|2026-10-01T20:00:00|2026-10-03T20:00:00|2026-10-03T20:30:00|PREEMPTED|08:00:00|asx13",   # 2 d, 30 min
    "40500005|hpcw_worker|reqp|requeue|2026-10-02T09:00:00|2026-10-02T09:10:00|2026-10-02T17:10:00|TIMEOUT|08:00:00|asx14",     # 10 min, 8 h
    "40500006|hpcw_worker|reqp|requeue|2026-10-04T07:00:00|Unknown|Unknown|PENDING|08:00:00|None assigned",
    "40500007|hpcw_worker|reqp|requeue|2026-10-03T07:00:00|None|2026-10-03T07:05:00|CANCELLED by 1234|08:00:00|None assigned",
    "40500008|hpcw_probe|secp|secondary|2026-10-01T08:00:00|2026-10-01T08:00:20|2026-10-01T08:10:20|COMPLETED|00:10:00|asx15",  # 20 s, 10 min
    "40500009|hpcw_probe|secp|secondary|2026-10-01T09:00:00|2026-10-01T09:00:45|2026-10-01T09:20:45|COMPLETED|00:30:00|asx15",  # 45 s, 20 min
    "40500010|hpcw_probe|secp|secondary|2026-10-01T10:00:00|2026-10-01T10:02:00|2026-10-01T10:32:00|COMPLETED|00:30:00|asx15",  # 2 min, 30 min
    "40500011|hpcw_probe|secp|secondary|2026-10-01T11:00:00|2026-10-01T11:06:00|2026-10-01T11:46:00|COMPLETED|01:00:00|asx15",  # 6 min, 40 min
    "40500012|hpcw_probe|secp|secondary|2026-10-02T11:00:10|2026-10-02T11:00:00|2026-10-02T11:50:00|COMPLETED|01:00:00|asx15",  # Start 10 s before Submit: 0; 50 min
    "40500013|hpcw_worker|gvohp|gpu|2026-10-02T12:00:00|2026-10-02T12:01:00|Unknown|RUNNING|08:00:00|gpu01",                     # 1 min, still running
]
SINFO = [
    "secp*|7-00:00:00|up|30|allocated", "secp*|7-00:00:00|up|12|idle", "secp*|7-00:00:00|up|2|drained",
    "reqp|14-00:00:00|up|100|allocated", "reqp|14-00:00:00|up|15|mixed",
    "gvohp|7-00:00:00|up|6|allocated", "gvohp|7-00:00:00|up|2|idle",
]
SACCT_ARGV = "sacct -u st1234 -S now-%ddays -X -n -P --format=JobID,JobName,Partition,QOS,Submit,Start,End,State,Timelimit,NodeList"
SINFO_ARGV = "sinfo -h -o %P|%l|%a|%D|%T"
ROWS = {
    # partition, qos, started, median wait, p90 wait, max wait, pending, preempted, cancelled, timed out, median run
    "gvohp": ["gvohp", "gpu", "1", "1m 0s", "1m 0s", "1m 0s", "0", "0", "0", "0", "-"],
    # waits 30, 300, 600, 14400, 172800: median 600, p90 (the value at ceil(0.9 * 5) = 5) 172800; runs 1800..28800: median 7200
    "reqp": ["reqp", "requeue", "5", "10m 0s", "2d 0h 0m", "2d 0h 0m", "1", "1", "1", "1", "2h 0m"],
    # waits 0, 20, 45, 120, 360: median 45; runs 600..3000: median 1800
    "secp": ["secp", "secondary", "5", "0m 45s", "6m 0s", "6m 0s", "0", "0", "0", "0", "30m 0s"],
}


def cells(line):
    """the table's columns: two or more spaces apart, so a duration's own single spaces stay inside its cell"""
    return re.split(r" {2,}", line.strip())


def tree(root):
    out = []
    for base, dirs, names in os.walk(root):
        for n in dirs + names:
            p = os.path.join(base, n)
            out.append((os.path.relpath(p, root), os.lstat(p).st_mtime if os.path.isfile(p) else None))
    return sorted(out)


class Report(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.g.setup()

    def tearDown(self):
        self.tmp.cleanup()

    def report(self, args="", **extra):
        rc, out, err = self.g.run("queue report " + args, FAKE_SACCT="\n".join(RECORDS), **extra)
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(err, "")
        return out.splitlines()

    def rows(self, lines):
        got = {}
        for line in lines:
            c = cells(line)
            if len(c) == 11 and c[0] in ROWS:
                got[c[0]] = c
        return got

    def test_the_table(self):
        lines = self.report()
        self.assertEqual(lines[0], "queue report for st1234, the last 14 days: 13 records read by `%s`" % (SACCT_ARGV % 14), "the header: account, window, count, query")
        self.assertEqual(lines[1], "")
        self.assertEqual(cells(lines[2]), ["partition", "qos", "started", "median wait", "p90 wait", "max wait", "pending", "preempted", "cancelled", "timed out", "median run"])
        self.assertEqual([cells(l)[0] for l in lines[3:6]], ["gvohp", "reqp", "secp"], "sorted by partition, then QoS")
        self.assertEqual(self.rows(lines), ROWS)
        self.assertEqual(lines[6], "")
        self.assertEqual(lines[7], "1 job started before being submitted, by the clocks the scheduler recorded; each counts as no wait")
        self.assertEqual(lines[8], "shortest median wait: secp secondary (0m 45s)", "the one sentence the maintainer asked for")
        self.assertEqual(len(lines), 9, "no recommendation beyond it")

    def test_two_qos_on_one_partition_are_two_rows(self):
        extra = ["40500020|hpcw_worker|secp|primary|2026-10-01T08:00:00|2026-10-01T08:30:00|2026-10-01T09:30:00|COMPLETED|08:00:00|asx16",
                 "40500021|hpcw_worker|secp|primary|2026-10-01T09:00:00|2026-10-01T09:40:00|2026-10-01T10:40:00|COMPLETED|08:00:00|asx16"]
        rc, out, err = self.g.run("queue report", FAKE_SACCT="\n".join(RECORDS + extra))
        self.assertEqual(rc, 0, (out, err))
        lines = out.splitlines()
        self.assertIn("15 records read", lines[0])
        table = [cells(l) for l in lines[3:7]]
        self.assertEqual([(c[0], c[1]) for c in table], [("gvohp", "gpu"), ("reqp", "requeue"), ("secp", "primary"), ("secp", "secondary")])
        # waits 1800 and 2400: an even count averages the two middle values
        self.assertEqual(table[2][2:6], ["2", "35m 0s", "40m 0s", "40m 0s"])
        self.assertEqual(lines[-1], "shortest median wait: secp secondary (0m 45s)")

    def test_one_sacct_and_nothing_else_and_nothing_written(self):
        lines = self.report()
        self.assertEqual(self.g.calls(), [SACCT_ARGV % 14], "one sacct: -X -n -P, the format, -S now-14days; no sbatch, squeue, scancel, srun or scontrol")
        self.assertIn("`%s`" % self.g.calls()[0], lines[0], "the header names the line that was run, word for word")
        # the profile reader keeps its cache (~/.hpcworker/profile.env) from the first load after an install; the report itself writes nothing
        before = tree(self.g.home)
        self.report("--limits", FAKE_SINFO="\n".join(SINFO))
        self.assertEqual(tree(self.g.home), before, "the report writes nothing")
        self.assertFalse(os.path.exists(self.g.state), "no run directory is made")

    def test_days(self):
        self.report("--days 1")
        self.report("--days 90")
        self.assertEqual(self.g.calls(), [SACCT_ARGV % 1, SACCT_ARGV % 90])
        self.assertIn("the last 1 days", self.report("--days 1")[0])
        for bad in ("400", "0", "91", "7.5", "abc", "-3"):
            rc, out, err = self.g.run("queue report --days %s" % bad, FAKE_SACCT="\n".join(RECORDS))
            self.assertEqual((rc, out), (1, ""), bad)
            self.assertEqual(err.splitlines(), ["hpcworker: --days must be a whole number from 1 to 90"], bad)
        self.assertEqual(len(self.g.calls()), 3, "a refused --days asks the scheduler nothing")

    def test_usage(self):
        for args in ("queue", "queue bogus", "queue report --what", "queue report --days", "queue report 7"):
            rc, out, err = self.g.run(args)
            self.assertEqual((rc, out), (2, ""), args)
            self.assertEqual(err.splitlines(), ["usage: hpcworker queue report [--days N] [--limits]   (N from 1 to 90; 14 when not given)"], args)
        self.assertEqual(self.g.calls(), [])
        rc, out, err = self.g.run("help")
        self.assertEqual(rc, 0, err)
        self.assertIn("hpcworker queue report [--days N] [--limits]", out, "the usage header at the top of the file")

    def test_limits_adds_one_sinfo(self):
        lines = self.report("--limits", FAKE_SINFO="\n".join(SINFO))
        self.assertEqual(self.g.calls(), [SACCT_ARGV % 14, SINFO_ARGV], "two queries, in this order")
        self.assertEqual(self.rows(lines), ROWS, "the table is the same")
        i = lines.index("partitions now (sinfo -h -o '%P|%l|%a|%D|%T'):")
        self.assertEqual(lines[i - 2], "shortest median wait: secp secondary (0m 45s)")
        self.assertEqual(lines[i - 1], "")
        self.assertRegex(lines[i + 1], r"^  gvohp +time limit 7-00:00:00 +up +8 nodes: 6 allocated, 2 idle$")
        self.assertRegex(lines[i + 2], r"^  reqp +time limit 14-00:00:00 +up +115 nodes: 100 allocated, 15 mixed$")
        self.assertRegex(lines[i + 3], r"^  secp \(default\) +time limit 7-00:00:00 +up +44 nodes: 30 allocated, 2 drained, 12 idle$")
        self.assertEqual(len(lines), i + 4)
        # without the flag, no sinfo; with it and nothing from sinfo, one line says so
        self.report()
        self.assertEqual(self.g.calls()[2:], [SACCT_ARGV % 14])
        lines = self.report("--limits")
        self.assertEqual(lines[-1], "partitions now: nothing from sinfo -h -o '%P|%l|%a|%D|%T'")

    def test_empty_history(self):
        rc, out, err = self.g.run("queue report")
        self.assertEqual((rc, err), (0, ""), out)
        self.assertEqual(out.splitlines(), ["no jobs of st1234 in the history the scheduler keeps for the last 14 days (%s)" % (SACCT_ARGV % 14)])
        self.assertEqual(self.g.calls(), [SACCT_ARGV % 14])

    def test_failed_query(self):
        rc, out, err = self.g.run("queue report", FAKE_SACCT_FAIL="sacct: error: Problem talking to the database: Connection refused")
        self.assertEqual((rc, out), (1, ""))
        self.assertEqual(err.splitlines(), ["hpcworker: the scheduler's history could not be read: sacct: error: Problem talking to the database: Connection refused"])
        rc, out, err = self.g.run("queue report", FAKE_SACCT_FAIL="line one\nline two")
        self.assertEqual(err.splitlines(), ["hpcworker: the scheduler's history could not be read: line one line two"], "one line")

    def test_only_started_jobs_have_waits(self):
        # every record pending or cancelled before a start: rows with counts and dashes, and a footer that says so
        pend = ["4050010%d|hpcw_worker|reqp|requeue|2026-10-04T0%d:00:00|Unknown|Unknown|PENDING|08:00:00|None assigned" % (i, i) for i in range(3)]
        canc = ["40500110|hpcw_worker|secp|secondary|2026-10-03T07:00:00|None|2026-10-03T07:05:00|CANCELLED by 1234|00:10:00|None assigned"]
        rc, out, err = self.g.run("queue report", FAKE_SACCT="\n".join(pend + canc))
        self.assertEqual(rc, 0, (out, err))
        lines = out.splitlines()
        self.assertEqual(cells(lines[3]), ["reqp", "requeue", "0", "-", "-", "-", "3", "0", "0", "0", "-"])
        self.assertEqual(cells(lines[4]), ["secp", "secondary", "0", "-", "-", "-", "0", "0", "1", "0", "-"])
        self.assertEqual(lines[-1], "shortest median wait: none (no job in the window has started)")

    def test_a_notice_among_the_records_is_left_out(self):
        rc, out, err = self.g.run("queue report", FAKE_SACCT="\n".join(["sacct: a notice the site prints first"] + RECORDS + ["", "\r"]))
        self.assertEqual(rc, 0, (out, err))
        lines = out.splitlines()
        self.assertIn("13 records read", lines[0])
        self.assertEqual(self.rows(lines), ROWS)
        self.assertIn("1 line that was not a record left out", lines)


class OtherSchedulers(unittest.TestCase):
    def test_a_pbs_site_is_told_the_report_is_for_slurm(self):
        def pbs(p):
            p["scheduler"] = "pbs"
            p["scheduler_in_worker"] = False

        with tempfile.TemporaryDirectory() as td:
            g = G.Grid(td, profile_edit=pbs)
            g.setup()
            rc, out, err = g.run("queue report", FAKE_SACCT="\n".join(RECORDS))
            self.assertEqual((rc, out), (1, ""))
            self.assertEqual(err.splitlines(), ["hpcworker: the queue report reads Slurm's history (sacct); this site's scheduler is pbs"])
            self.assertEqual(g.calls(), [], "nothing is asked")

    def test_every_adapter_defines_the_calls(self):
        for fam in ("slurm", "pbs", "lsf"):
            rc, out, err = G.bash("source '%s/lib/adapters/%s.sh' && declare -F adapter_history adapter_history_query adapter_partitions adapter_partitions_query >/dev/null && echo defined" % (G.posix(G.ROOT), fam))
            self.assertEqual((rc, out.strip()), (0, "defined"), (fam, err))
        for fam in ("pbs", "lsf"):
            rc, out, err = G.bash("source '%s/lib/adapters/%s.sh' && adapter_history 14; echo \"rc=$?\"; adapter_history_query 14; echo \"q=$?\"" % (G.posix(G.ROOT), fam))
            self.assertEqual(out.splitlines(), ["rc=2", "q=0"], (fam, err))
        rc, out, err = G.bash("source '%s/lib/adapters/slurm.sh' && adapter_history_query 14 && adapter_partitions_query" % G.posix(G.ROOT), env={"USER": "st1234"})
        self.assertEqual(out.splitlines(), [SACCT_ARGV % 14, "sinfo -h -o '%P|%l|%a|%D|%T'"], err)


class Arithmetic(unittest.TestCase):
    """the awk alone (HPCW_Q_MODE=epoch), the formula checked against python's calendar, which never ran in the tool"""

    def epochs(self, times):
        with tempfile.TemporaryDirectory() as td:
            script = "export HPCW_HOME='%s'; source '%s/bin/hpcworker' && HPCW_Q_MODE=epoch LC_ALL=C awk \"$HPCW_QUEUE_AWK\"" % (G.posix(td), G.posix(G.ROOT))
            rc, out, err = G.bash(script, stdin_text="".join(t + "\n" for t in times))
        self.assertEqual(rc, 0, err)
        return out.split("\n")[:-1]

    def test_days_from_civil_against_known_dates(self):
        # 2026-10-04T00:00:00 is 1791072000 were the clock UTC; the report takes differences only, so the zone never matters
        self.assertEqual(self.epochs(["1970-01-01T00:00:00", "2000-02-29T12:00:00", "2026-10-04T00:00:00"]), ["0", "951825600", "1791072000"])

    def test_the_formula_over_a_sweep_of_dates(self):
        times, want = [], []
        for day in list(range(0, 366 * 131, 97)) + [11016, 11017, 19782, 19783, 47541]:   # every 97th day of 1970..2100, the leap days 2000-02-29 and 2024-02-29 with the day after, and one past 2100-02-28
            s = day * 86400 + (day % 24) * 3600 + (day % 60) * 60 + (day % 7)
            t = datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=s)
            times.append(t.strftime("%Y-%m-%dT%H:%M:%S"))
            want.append(str(calendar.timegm(t.timetuple())))
        self.assertEqual(self.epochs(times), want)

    def test_anything_but_a_time_is_empty(self):
        self.assertEqual(self.epochs(["Unknown", "None", "N/A", "", "2026-10-04 00:00:00", "2026-10-04T00:00", "now", "2026-10-04T00:00:00Z"]), [""] * 8)


if __name__ == "__main__":
    unittest.main()
