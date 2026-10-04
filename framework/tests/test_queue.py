"""`hpcworker queue report` (greg, 2026-10-04 15:19Z: the requeue waits), against the fake scheduler of fakegrid.py:
records planted in its sacct cover waits of 30 s, 5 min, 4 h and 2 d on reqp/requeue, 20 s to 6 min on secp/secondary,
a job still pending, one preempted, one cancelled before it started, one that timed out, its chain successor (submitted
hours before it could run), the two attempts of a requeued job, one whose Start is before its Submit, and one running
with no End. Then the per-partition lines, the counts, the footer, the header's count and query, the one exact sacct
argv and its environment (and no sbatch, squeue or scancel), the sinfo `--limits` adds, the waits across a
daylight-saving change and under a caller's own time format, nearest-rank p90 against the maximum, the sort of a
partition whose name is a prefix of another's, every refusal, diag's partition check on the five-field sinfo, and the
days-from-civil formula alone against dates python computes. Nothing reaches a real scheduler."""
import calendar
import datetime
import os
import re
import tempfile
import unittest

import fakegrid as G

# sacct -X -D -n -P --format=JobID,Partition,QOS,Submit,Eligible,Start,End,State,Timelimit,NodeList, as the comment in
# lib/adapters/slurm.sh describes the fields (UTC, as TZ=UTC0 makes sacct print them; Unknown and None where a job has not started)
RECORDS = [
    "40500001|reqp|requeue|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:00:30|2026-10-01T09:00:30|COMPLETED|08:00:00|asx10",   # 30 s, ran 1 h
    "40500002|reqp|requeue|2026-10-01T10:00:00|2026-10-01T10:00:00|2026-10-01T10:05:00|2026-10-01T12:05:00|COMPLETED|08:00:00|asx11",   # 5 min, 2 h
    "40500003|reqp|requeue|2026-10-01T12:00:00|2026-10-01T12:00:00|2026-10-01T16:00:00|2026-10-01T19:00:00|COMPLETED|08:00:00|asx12",   # 4 h, 3 h
    "40500004|reqp|requeue|2026-10-01T20:00:00|2026-10-01T20:00:00|2026-10-03T20:00:00|2026-10-03T20:30:00|PREEMPTED|08:00:00|asx13",   # 2 d, 30 min
    "40500005|reqp|requeue|2026-10-02T09:00:00|2026-10-02T09:00:00|2026-10-02T09:10:00|2026-10-02T17:10:00|TIMEOUT|08:00:00|asx14",     # 10 min, 8 h
    # its chain successor: submitted 5 s after it started, eligible when it ended, started 30 s later. A wait of 30 s,
    # where Start minus Submit would count 8 h 0 min 25 s of its predecessor's run; ran 8 h
    "40500014|reqp|requeue|2026-10-02T09:10:05|2026-10-02T17:10:00|2026-10-02T17:10:30|2026-10-03T01:10:30|COMPLETED|08:00:00|asx14",
    "40500006|reqp|requeue|2026-10-04T07:00:00|2026-10-04T07:00:00|Unknown|Unknown|PENDING|08:00:00|None assigned",
    "40500007|reqp|requeue|2026-10-03T07:00:00|2026-10-03T07:00:00|None|2026-10-03T07:05:00|CANCELLED by 1234|08:00:00|None assigned",
    # one job requeued once (-D: each attempt its own record): 2 min then 3 h of running, requeued; eligible again at
    # 11:04, started an hour later, ran 8 h. Two waits, 2 min and 1 h (from Submit the second would read 4 h 4 min)
    "40500015|reqp|requeue|2026-10-03T08:00:00|2026-10-03T08:00:00|2026-10-03T08:02:00|2026-10-03T11:02:00|REQUEUED|08:00:00|asx15",
    "40500015|reqp|requeue|2026-10-03T08:00:00|2026-10-03T11:04:00|2026-10-03T12:04:00|2026-10-03T20:04:00|COMPLETED|08:00:00|asx16",
    "40500008|secp|secondary|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:00:20|2026-10-01T08:10:20|COMPLETED|00:10:00|asx15",  # 20 s, 10 min
    "40500009|secp|secondary|2026-10-01T09:00:00|2026-10-01T09:00:00|2026-10-01T09:00:45|2026-10-01T09:20:45|COMPLETED|00:30:00|asx15",  # 45 s, 20 min
    "40500010|secp|secondary|2026-10-01T10:00:00|2026-10-01T10:00:00|2026-10-01T10:02:00|2026-10-01T10:32:00|COMPLETED|00:30:00|asx15",  # 2 min, 30 min
    "40500011|secp|secondary|2026-10-01T11:00:00|2026-10-01T11:00:00|2026-10-01T11:06:00|2026-10-01T11:46:00|COMPLETED|01:00:00|asx15",  # 6 min, 40 min
    "40500012|secp|secondary|2026-10-02T11:00:10|2026-10-02T11:00:10|2026-10-02T11:00:00|2026-10-02T11:50:00|COMPLETED|01:00:00|asx15",  # Start 10 s before Eligible: 0; 50 min
    "40500013|gvohp|gpu|2026-10-02T12:00:00|2026-10-02T12:00:00|2026-10-02T12:01:00|Unknown|RUNNING|08:00:00|gpu01",                     # 1 min, still running
]
SINFO = [
    "secp*|7-00:00:00|up|30|allocated", "secp*|7-00:00:00|up|12|idle", "secp*|7-00:00:00|up|2|drained",
    "reqp|14-00:00:00|up|100|allocated", "reqp|14-00:00:00|up|15|mixed",
    "gvohp|7-00:00:00|up|6|allocated", "gvohp|7-00:00:00|up|2|idle",
]
SACCT_FORMAT = "--format=JobID,Partition,QOS,Submit,Eligible,Start,End,State,Timelimit,NodeList"


def sacct_argv(days):
    return ["-u", "st1234", "-S", "now-%ddays" % days, "-X", "-D", "-n", "-P", SACCT_FORMAT]


SINFO_ARGV = ["-h", "-o", "%P|%l|%a|%D|%T"]
# what sacct runs under, in its environment only: every time UTC, in the one form the report reads
SACCT_ENV = {"TZ": "UTC0", "SLURM_TIME_FORMAT": "standard"}


def query(days):
    """the line the header names: the two assignments, then sacct's argv as a person types it (no argument holds a space)"""
    return "TZ=UTC0 SLURM_TIME_FORMAT=standard " + " ".join(["sacct"] + sacct_argv(days))


def header(n, days=14):
    return "queue report for st1234: %d record%s of jobs eligible or running at any time in the last %d days, read by `%s`" % (n, "s" if n > 1 else "", days, query(days))


SECOND = "one record per attempt of a requeued job; a wait is Start minus Eligible (minus Submit where Eligible is not a time); times in UTC"
COLUMNS = ["partition", "qos", "started", "median wait", "p90 wait", "max wait", "pending", "preempted", "requeued", "cancelled", "timed out", "median run"]
ROWS = {
    # partition, qos, started, median wait, p90 wait, max wait, pending, preempted, requeued, cancelled, timed out, median run
    "gvohp": ["gvohp", "gpu", "1", "1m 0s", "1m 0s", "1m 0s", "0", "0", "0", "0", "0", "-"],
    # waits 30, 30, 120, 300, 600, 3600, 14400, 172800: median (300 + 600) / 2 = 450; p90 (the value at ceil(0.9 * 8) = 8)
    # 172800, here the maximum too (the p90 case is its own test); runs 1800 .. 28800: median (10800 + 10800) / 2
    "reqp": ["reqp", "requeue", "8", "7m 30s", "2d 0h 0m", "2d 0h 0m", "1", "1", "1", "1", "1", "3h 0m"],
    # waits 0, 20, 45, 120, 360: median 45; runs 600..3000: median 1800
    "secp": ["secp", "secondary", "5", "0m 45s", "6m 0s", "6m 0s", "0", "0", "0", "0", "0", "30m 0s"],
}
BEFORE = "1 record whose Start is before its Eligible (or Submit) time, by the clocks the scheduler recorded; each counts as no wait"


def cells(line):
    """the table's columns: two or more spaces apart, so a duration's own single spaces stay inside its cell"""
    return re.split(r" {2,}", line.strip())


def tree(root, leave_out=()):
    out = []
    for base, dirs, names in os.walk(root):
        for n in dirs + names:
            p = os.path.join(base, n)
            rel = os.path.relpath(p, root)
            if rel in leave_out:
                continue
            st = os.lstat(p)
            out.append((rel, st.st_mtime if os.path.isfile(p) else None, st.st_size if os.path.isfile(p) else None))
    return sorted(out)


def utc(t):
    """an instant the fake sacct prints in its own zone: @SECONDS"""
    return "@%d" % calendar.timegm(datetime.datetime.strptime(t, "%Y-%m-%dT%H:%M:%S").timetuple())


class Report(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.g.setup()

    def tearDown(self):
        self.tmp.cleanup()

    def report(self, args="", records=None, **extra):
        rc, out, err = self.g.run("queue report " + args, FAKE_SACCT="\n".join(RECORDS if records is None else records), **extra)
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(err, "")
        return out.splitlines()

    def rows(self, lines):
        got = {}
        for line in lines:
            c = cells(line)
            if len(c) == 12 and c[0] != "partition":
                got[c[0] if c[0] in ROWS else (c[0], c[1])] = c
        return got

    def table(self, lines):
        """the rows between the column line and the blank line after them"""
        i = [cells(l) for l in lines].index(COLUMNS)
        j = lines.index("", i)
        return [cells(l) for l in lines[i + 1:j]]

    def test_the_table(self):
        lines = self.report()
        self.assertEqual(lines[0], header(16), "the header: account, count, window as sacct reads it, query")
        self.assertEqual(lines[1], SECOND)
        self.assertEqual(lines[2], "")
        self.assertEqual(cells(lines[3]), COLUMNS)
        self.assertEqual([cells(l)[0] for l in lines[4:7]], ["gvohp", "reqp", "secp"], "sorted by partition, then QoS")
        self.assertEqual(self.rows(lines), ROWS)
        self.assertEqual(lines[7], "")
        self.assertEqual(lines[8], BEFORE)
        self.assertEqual(lines[9], "shortest median wait: secp secondary (0m 45s)", "the one sentence the maintainer asked for")
        self.assertEqual(len(lines), 10, "no recommendation beyond it")

    def test_a_chained_successor_waits_from_eligible(self):
        # submitted at 08:00:05 while its predecessor ran; eligible at 16:00:00, when that one ended; started 30 s later
        succ = "40600001|reqp|requeue|2026-10-01T08:00:05|2026-10-01T16:00:00|2026-10-01T16:00:30|2026-10-02T00:00:30|COMPLETED|08:00:00|asx10"
        lines = self.report(records=[succ])
        self.assertEqual(self.table(lines), [["reqp", "requeue", "1", "0m 30s", "0m 30s", "0m 30s", "0", "0", "0", "0", "0", "8h 0m"]], "Start minus Eligible, not minus Submit")
        self.assertEqual(lines[-1], "shortest median wait: reqp requeue (0m 30s)")
        # Eligible not a time: Submit stands in, and the wait is the 8 h 0 min 25 s since it
        lines = self.report(records=[succ.replace("|2026-10-01T16:00:00|", "|Unknown|")])
        self.assertEqual(self.table(lines)[0][3:6], ["8h 0m", "8h 0m", "8h 0m"])

    def test_each_attempt_of_a_requeued_job_is_its_own_record_and_wait(self):
        # one job, three attempts: preempted, requeued, then completed; each waited for a node from its own Eligible
        rec = ["40600010|reqp|requeue|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:02:00|2026-10-01T11:02:00|PREEMPTED|08:00:00|asx10",
               "40600010|reqp|requeue|2026-10-01T08:00:00|2026-10-01T11:04:00|2026-10-01T11:34:00|2026-10-01T12:34:00|REQUEUED|08:00:00|asx11",
               "40600010|reqp|requeue|2026-10-01T08:00:00|2026-10-01T12:36:00|2026-10-01T14:36:00|2026-10-01T22:36:00|COMPLETED|08:00:00|asx12"]
        lines = self.report(records=rec)
        self.assertEqual(lines[0], header(3), "three records of one job id: sacct -D keeps every attempt")
        # waits 120, 1800, 7200: median 30 min, p90 at ceil(2.7) = 3; runs 3 h, 1 h, 8 h: median 3 h
        self.assertEqual(self.table(lines), [["reqp", "requeue", "3", "30m 0s", "2h 0m", "2h 0m", "0", "1", "1", "0", "0", "3h 0m"]])

    def test_p90_is_the_nearest_rank_not_the_maximum_and_a_prefix_partition_sorts_first(self):
        # "sec": 11 waits of 1 .. 11 min (p90 at ceil(9.9) = 10: 10 min, the maximum 11); "secp": 10 waits of 1 .. 10 min
        # (p90 at ceil(9.0) = 9: 9 min, not rounded up to the 10th). "sec" before "secp": the key's separator sorts
        # before every printable byte, so a shorter name that is a prefix of another comes first
        rec = []
        for part, n in (("secp", 10), ("sec", 11)):
            for i in range(1, n + 1):
                rec.append("4060%02d%02d|%s|normal|2026-10-01T%02d:00:00|2026-10-01T%02d:00:00|2026-10-01T%02d:%02d:00|2026-10-01T%02d:%02d:00|COMPLETED|01:00:00|asx1"
                           % (n, i, part, i, i, i, i, i + 1, i))
        lines = self.report(records=rec)
        self.assertEqual(self.table(lines), [["sec", "normal", "11", "6m 0s", "10m 0s", "11m 0s", "0", "0", "0", "0", "0", "1h 0m"],
                                             ["secp", "normal", "10", "5m 30s", "9m 0s", "10m 0s", "0", "0", "0", "0", "0", "1h 0m"]])

    def test_two_qos_on_one_partition_are_two_rows(self):
        extra = ["40500020|secp|primary|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:30:00|2026-10-01T09:30:00|COMPLETED|08:00:00|asx16",
                 "40500021|secp|primary|2026-10-01T09:00:00|2026-10-01T09:00:00|2026-10-01T09:40:00|2026-10-01T10:40:00|COMPLETED|08:00:00|asx16"]
        lines = self.report(records=RECORDS + extra)
        self.assertEqual(lines[0], header(18))
        table = self.table(lines)
        self.assertEqual([(c[0], c[1]) for c in table], [("gvohp", "gpu"), ("reqp", "requeue"), ("secp", "primary"), ("secp", "secondary")])
        # waits 1800 and 2400: an even count averages the two middle values
        self.assertEqual(table[2][2:6], ["2", "35m 0s", "40m 0s", "40m 0s"])
        self.assertEqual(lines[-1], "shortest median wait: secp secondary (0m 45s)")

    def test_one_sacct_and_nothing_else_and_nothing_written(self):
        # every folder the fake grid owns (the home, the shared copy, the scheduler's and its programs) and an empty
        # TMPDIR, looked at before the first report; only the stand-ins' own logs and load_profile's cache may change
        tmpd = os.path.join(self.tmp.name, "tmpdir")
        os.makedirs(tmpd)
        cache = os.path.join("home", ".hpcworker", "profile.env")
        leave_out = (os.path.join("sched", "calls"), os.path.join("sched", "argv"), cache)
        system_tmp = (lambda: sorted(n for n in os.listdir("/tmp") if n.startswith("hpcw"))) if os.path.isdir("/tmp") else (lambda: [])
        before, before_tmp = tree(self.tmp.name, leave_out), system_tmp()
        # a caller's own zone and time format are not what sacct runs under
        lines = self.report(TMPDIR=tmpd, TZ="America/Detroit", SLURM_TIME_FORMAT="relative")
        self.assertEqual(self.g.argvs(), [dict(cmd="sacct", argv=sacct_argv(14), **SACCT_ENV)],
                         "one sacct with exactly these arguments (-X -D -n -P, the format, -S now-14days), TZ=UTC0 and SLURM_TIME_FORMAT=standard")
        self.assertEqual(self.g.calls(), [" ".join(["sacct"] + sacct_argv(14))], "no sbatch, squeue, scancel, srun or scontrol")
        a = self.g.argvs()[0]
        self.assertIn("`TZ=%s SLURM_TIME_FORMAT=%s %s`" % (a["TZ"], a["SLURM_TIME_FORMAT"], " ".join([a["cmd"]] + a["argv"])), lines[0],
                      "the header names the line that ran, its environment first, word for word")
        self.report("--limits", FAKE_SINFO="\n".join(SINFO), TMPDIR=tmpd)
        self.assertEqual(tree(self.tmp.name, leave_out), before, "the report writes nothing")
        self.assertTrue(os.path.isfile(os.path.join(self.tmp.name, cache)), "load_profile's cache, as for every verb, is the one file written")
        self.assertEqual(os.listdir(tmpd), [], "nothing under TMPDIR")
        self.assertEqual(system_tmp(), before_tmp, "nothing of ours under /tmp")
        self.assertFalse(os.path.exists(self.g.state), "no run directory is made")

    def test_waits_across_a_daylight_saving_change_and_a_callers_time_format(self):
        # The fake sacct prints an instant in the zone and the form of its own environment, as sacct does. On
        # 2026-11-01 Detroit's clocks went from 02:00 EDT back to 01:00 EST: a job submitted 01:50 EDT and started 01:10
        # EST waited 20 min; one that ran from 00:00:30 EDT to 08:00:30 EST ran 9 h. Under the caller's zone they would
        # read as a Start before its Submit and an 8 h run, and under the caller's time format as no time at all.
        rc, out, err = G.bash("TZ=America/Detroit date -d %s +%%H:%%M" % utc("2026-11-01T05:50:00"))
        if out.strip() != "01:50":
            self.skipTest("this machine has no America/Detroit zone for the stand-in to print in")
        rec = ["40600020|reqp|requeue|%s|%s|%s|%s|COMPLETED|10:00:00|asx10" % (utc("2026-11-01T05:50:00"), utc("2026-11-01T05:50:00"), utc("2026-11-01T06:10:00"), utc("2026-11-01T15:10:00")),
               "40600021|reqp|requeue|%s|%s|%s|%s|COMPLETED|10:00:00|asx11" % (utc("2026-11-01T04:00:00"), utc("2026-11-01T04:00:00"), utc("2026-11-01T04:00:30"), utc("2026-11-01T13:00:30"))]
        for fmt in ("standard", "%F %T", "relative"):
            lines = self.report(records=rec, TZ="America/Detroit", SLURM_TIME_FORMAT=fmt)
            # waits 1200 and 30: median 615; runs 9 h and 9 h
            self.assertEqual(self.table(lines), [["reqp", "requeue", "2", "10m 15s", "20m 0s", "20m 0s", "0", "0", "0", "0", "0", "9h 0m"]], fmt)
            self.assertNotIn(BEFORE, lines, fmt)
        self.assertEqual({(a["TZ"], a["SLURM_TIME_FORMAT"]) for a in self.g.argvs()}, {("UTC0", "standard")})

    def test_times_in_a_form_the_report_does_not_read_are_said_not_dropped(self):
        # what a sacct whose time format nobody pinned would print: the records count by state, and the report says so
        rec = ["40600030|reqp|requeue|01 Oct 08:00|01 Oct 08:00|01 Oct 08:05|01 Oct 09:05|COMPLETED|08:00:00|asx10",
               "40600031|reqp|requeue|01 Oct 10:00|01 Oct 10:00|Unknown|Unknown|PENDING|08:00:00|None assigned"]
        lines = self.report(records=rec)
        self.assertEqual(lines[0], header(2))
        self.assertEqual(self.table(lines), [["reqp", "requeue", "0", "-", "-", "-", "1", "0", "0", "0", "0", "-"]])
        self.assertEqual(lines[-2:], ["2 records whose times are not in the form this report reads (YYYY-MM-DDTHH:MM:SS): counted by state, their wait and run time left out",
                                      "shortest median wait: not known (the times of 2 records could not be read)"])

    def test_days(self):
        self.report("--days 1")
        self.report("--days 90")
        self.assertEqual([a["argv"] for a in self.g.argvs()], [sacct_argv(1), sacct_argv(90)])
        self.assertEqual(self.report("--days 1")[0], header(16, 1))
        for bad in ("400", "0", "91", "7.5", "abc", "-3"):
            rc, out, err = self.g.run("queue report --days %s" % bad, FAKE_SACCT="\n".join(RECORDS))
            self.assertEqual((rc, out), (1, ""), bad)
            self.assertEqual(err.splitlines(), ["hpcworker: --days must be a whole number from 1 to 90"], bad)
        self.assertEqual(len(self.g.argvs()), 3, "a refused --days asks the scheduler nothing")

    def test_usage(self):
        for args in ("queue", "queue bogus", "queue report --what", "queue report --days", "queue report 7"):
            rc, out, err = self.g.run(args)
            self.assertEqual((rc, out), (2, ""), args)
            self.assertEqual(err.splitlines(), ["usage: hpcworker queue report [--days N] [--limits]   (N from 1 to 90; 14 when not given)"], args)
        self.assertEqual(self.g.calls(), [])
        rc, out, err = self.g.run("help")
        self.assertEqual(rc, 0, err)
        self.assertIn("hpcworker queue report [--days N] [--limits]", out, "the usage header at the top of the file")
        self.assertIn("Start minus Eligible", out)

    def test_limits_adds_one_sinfo(self):
        lines = self.report("--limits", FAKE_SINFO="\n".join(SINFO))
        self.assertEqual([(a["cmd"], a["argv"]) for a in self.g.argvs()], [("sacct", sacct_argv(14)), ("sinfo", SINFO_ARGV)], "two queries, in this order")
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
        self.assertEqual([a["cmd"] for a in self.g.argvs()[2:]], ["sacct"])
        lines = self.report("--limits")
        self.assertEqual(lines[-1], "partitions now: nothing from sinfo -h -o '%P|%l|%a|%D|%T'")

    def test_empty_history(self):
        rc, out, err = self.g.run("queue report")
        self.assertEqual((rc, err), (0, ""), out)
        self.assertEqual(out.splitlines(), ["no jobs of st1234 eligible or running at any time in the last 14 days, in the history the scheduler keeps (%s)" % query(14)])
        self.assertEqual(self.g.calls(), [" ".join(["sacct"] + sacct_argv(14))])

    def test_failed_query(self):
        rc, out, err = self.g.run("queue report", FAKE_SACCT_FAIL="sacct: error: Problem talking to the database: Connection refused")
        self.assertEqual((rc, out), (1, ""))
        self.assertEqual(err.splitlines(), ["hpcworker: the scheduler's history could not be read: sacct: error: Problem talking to the database: Connection refused"])
        rc, out, err = self.g.run("queue report", FAKE_SACCT_FAIL="line one\nline two")
        self.assertEqual(err.splitlines(), ["hpcworker: the scheduler's history could not be read: line one line two"], "one line")

    def test_only_started_jobs_have_waits(self):
        # every record pending or cancelled before a start: rows with counts and dashes, and a footer that says so
        pend = ["4050010%d|reqp|requeue|2026-10-04T0%d:00:00|2026-10-04T0%d:00:00|Unknown|Unknown|PENDING|08:00:00|None assigned" % (i, i, i) for i in range(3)]
        canc = ["40500110|secp|secondary|2026-10-03T07:00:00|2026-10-03T07:00:00|None|2026-10-03T07:05:00|CANCELLED by 1234|00:10:00|None assigned"]
        lines = self.report(records=pend + canc)
        self.assertEqual(self.table(lines), [["reqp", "requeue", "0", "-", "-", "-", "3", "0", "0", "0", "0", "-"],
                                             ["secp", "secondary", "0", "-", "-", "-", "0", "0", "0", "1", "0", "-"]])
        self.assertEqual(lines[-1], "shortest median wait: none (no job in the window has started)")

    def test_a_line_that_is_not_a_record_is_left_out(self):
        # a notice sacct printed first, and a line with one field too many (a '|' where none belongs): left out and
        # counted, never read one column off
        shifted = "40500030|secp|x|secondary|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:00:20|2026-10-01T08:10:20|COMPLETED|00:10:00|asx15"
        lines = self.report(records=["sacct: a notice the site prints first"] + RECORDS + [shifted, "", "\r"])
        self.assertEqual(lines[0], header(16))
        self.assertEqual(self.rows(lines), ROWS)
        self.assertIn("2 lines that were not a record left out", lines)

    def test_nothing_but_lines_that_are_not_records_is_a_failure(self):
        rc, out, err = self.g.run("queue report", FAKE_SACCT="sacct: a notice the site prints first\nsomething|else")
        self.assertEqual((rc, out), (1, ""))
        self.assertEqual(err.splitlines(), ["hpcworker: none of the lines sacct printed is a record this report reads; the first: sacct: a notice the site prints first"])


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
        self.assertEqual(out.splitlines(), [query(14), "sinfo -h -o '%P|%l|%a|%D|%T'"], err)


class DiagPartitions(unittest.TestCase):
    """diag's partition check on the five-field sinfo: one line per partition and node state, each name once"""
    SINFO = ["secp|2-00:00:00|up|10|idle", "secp|2-00:00:00|up|5|mixed", "secp|2-00:00:00|up|1|drained",
             "reqp*|7-00:00:00|up|4|idle", "reqp*|7-00:00:00|up|2|mixed", "gvohp|7-00:00:00|up|3|allocated", "gvohp|7-00:00:00|up|1|idle"]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.g.setup()

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_missing_partition_names_the_rest_once_each(self):
        # the site profile wants secp, reqp, gmsap and gvohp; gmsap is not there
        rc, out, err = self.g.source("load_profile && diag_partitions", FAKE_SINFO="\n".join(self.SINFO))
        self.assertEqual(out.splitlines(), ["%-5s %-24s %s" % ("FAIL", "hpcw.partitions", "not in sinfo: gmsap (have: gvohp reqp secp )")], err)
        self.assertEqual([(a["cmd"], a["argv"]) for a in self.g.argvs()], [("sinfo", SINFO_ARGV)])

    def test_every_partition_there(self):
        rc, out, err = self.g.source("load_profile && diag_partitions", FAKE_SINFO="\n".join(self.SINFO + ["gmsap|7-00:00:00|up|2|idle", "gmsap|7-00:00:00|up|2|mixed"]))
        self.assertEqual(out.splitlines(), ["%-5s %-24s %s" % ("ok", "hpcw.partitions", "profile partitions exist: secp reqp gmsap gvohp")], err)

    def test_diag_runs_it(self):
        rc, out, err = self.g.run("diag", FAKE_SINFO="\n".join(self.SINFO))
        self.assertIn("%-5s %-24s %s" % ("FAIL", "hpcw.partitions", "not in sinfo: gmsap (have: gvohp reqp secp )"), out.splitlines(), (out, err))


class Arithmetic(unittest.TestCase):
    """the awk alone (HPCW_Q_MODE=epoch), the formula checked against python's calendar, which never ran in the tool"""

    def epochs(self, times):
        with tempfile.TemporaryDirectory() as td:
            script = "export HPCW_HOME='%s'; source '%s/bin/hpcworker' && HPCW_Q_MODE=epoch LC_ALL=C awk \"$HPCW_QUEUE_AWK\"" % (G.posix(td), G.posix(G.ROOT))
            rc, out, err = G.bash(script, stdin_text="".join(t + "\n" for t in times))
        self.assertEqual(rc, 0, err)
        return out.split("\n")[:-1]

    def test_days_from_civil_against_known_dates(self):
        # 2026-10-04T00:00:00 UTC is 1791072000; sacct prints UTC for the report (TZ=UTC0), so these are true epochs
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
