"""`hpcworker queue report` (greg, 2026-10-04 15:19Z: the requeue waits), against the fake scheduler of fakegrid.py:
records planted in its sacct cover waits of 30 s, 5 min, 4 h and 2 d on reqp/requeue, 20 s to 6 min on secp/secondary,
a job still pending, one preempted, one cancelled before it started, one that timed out, its chain successor (submitted
hours before it could run), the two attempts of a requeued job, one whose Start is before its Submit, and one running
with no End. Then the per-partition lines, the counts, the footer, the header's count and query, the one exact sacct
argv and its environment (and no sbatch, squeue or scancel), the sinfo `--limits` adds, the waits across a
daylight-saving change and under a caller's own time format, nearest-rank p90 against the maximum, the sort of a
partition whose name is a prefix of another's, a wait that ended before the window, jobs not started counted as
waiting at least so long (Kaplan-Meier, checked against the product-limit formula), a cancel before and after a
start, array tasks, the later attempts of a requeued job in both shapes Slurm may record, every refusal, a notice
with no record, diag's partition check on the five-field sinfo, and the days-from-civil formula alone against dates
python computes. The report's clock is the fake grid's date at FAKE_NOW. Nothing reaches a real scheduler."""
import calendar
import datetime
import os
import random
import re
import shutil
import tempfile
import unittest
from fractions import Fraction

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
    # one job requeued once (-D: each attempt its own record): 2 min then 3 h of running, requeued at 11:02; the second
    # attempt carries the requeue as its Submit and, two minutes and a second later (Slurm's hold after a requeue), its
    # Eligible; started at 12:04, ran 8 h. Two waits, 2 min and 1 h 2 min (from the End of the first attempt, the hold
    # included); its first run, cut short, is not a run in "median run"
    "40500015|reqp|requeue|2026-10-03T08:00:00|2026-10-03T08:00:00|2026-10-03T08:02:00|2026-10-03T11:02:00|REQUEUED|08:00:00|asx15",
    "40500015|reqp|requeue|2026-10-03T11:02:00|2026-10-03T11:04:01|2026-10-03T12:04:00|2026-10-03T20:04:00|COMPLETED|08:00:00|asx16",
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


def at(t):
    """seconds since 1970 of a UTC time written YYYY-MM-DDTHH:MM:SS"""
    return calendar.timegm(datetime.datetime.strptime(t, "%Y-%m-%dT%H:%M:%S").timetuple())


def iso(s):
    return (datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=s)).strftime("%Y-%m-%dT%H:%M:%S")


# the report's clock, through the date of the fake grid (DATE below): the window of 14 days opens 2026-09-20T12:00:00,
# and the job pending since 07:00 has waited 5 h so far
NOW = at("2026-10-04T12:00:00")
# date as the report reads its clock: FAKE_NOW, when set, for a call that names no time of its own (the fake sacct's
# date -d @SECONDS, and every call of every other verb, go to the real one)
DATE = r"""#!/bin/bash
if [ -n "${FAKE_NOW:-}" ]; then for a in "$@"; do case "$a" in -d*|--date*|-r*|--reference*) exec '%s' "$@";; esac; done; exec '%s' -d "@$FAKE_NOW" "$@"; fi
exec '%s' "$@"
"""


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


# the lines that say how to read the table, every report the same
HOW = ["one record per attempt of a requeued job; a wait runs from Eligible (Submit where Eligible is not a time; for a later attempt, the End of the one before) to Start; times in UTC",
       "a job not started (pending, or cancelled in line) counts as waiting at least as long as it had: median and p90 are Kaplan-Meier estimates, \">T\" where one lies beyond T, the longest wait seen",
       "gave up: cancelled before it started; cancelled: after it started; median run: End minus Start of the attempts not preempted or requeued",
       "not listed by sacct: a job held, or waiting on a dependency (the successor a worker queued), since it was submitted; pending is State PENDING, a job held later among them"]
COLUMNS = ["partition", "qos", "started", "median wait", "p90 wait", "max wait", "pending", "gave up", "preempted", "requeued", "cancelled", "timed out", "median run"]
ROWS = {
    # partition, qos, started, median wait, p90 wait, max wait, pending, gave up, preempted, requeued, cancelled, timed out, median run
    "gvohp": ["gvohp", "gpu", "1", "1m 0s", "1m 0s", "1m 0s", "0", "0", "0", "0", "0", "0", "-"],
    # started 30, 30, 120, 300, 600, 3720, 14400, 172800, and two not started: 300 (cancelled in line) and 18000 (pending
    # since 07:00). Kaplan-Meier: the share still waiting 9/10, 8/10, 7/10, 6/10, then at 600, with 5 still in line,
    # 6/10 * 4/5 = 0.48: the median is 600 (the plain median of the eight starts would be 450); then 0.36, 0.24, and 0
    # at 172800: p90 172800, here the maximum too (the p90 case is its own test). Runs of the attempts neither
    # preempted nor requeued, 3600 .. 28800: median (10800 + 28800) / 2
    "reqp": ["reqp", "requeue", "8", "10m 0s", "2d 0h 0m", "2d 0h 0m", "1", "1", "1", "1", "0", "1", "5h 30m"],
    # waits 0, 20, 45, 120, 360: median 45; runs 600..3000: median 1800
    "secp": ["secp", "secondary", "5", "0m 45s", "6m 0s", "6m 0s", "0", "0", "0", "0", "0", "0", "30m 0s"],
}
LATER = "1 of the starts above is a later attempt of a requeued job"
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
    return "@%d" % at(t)


def km(obs, q, avg):
    """the q-quantile of the Kaplan-Meier estimate from the product-limit formula, in exact fractions: obs [(seconds,
    started)]; at each distinct time, d starts among the r still in line make S = S * (r - d) / r, and every job seen
    there leaves the line after. The first time S <= 1 - q; with avg, where S = 1 - q exactly, the mean of it and the
    next start. None when S never gets there"""
    starts = sorted(set(t for t, ran in obs if ran))
    s, r, thr = Fraction(1), len(obs), 1 - Fraction(q).limit_denominator(10)
    for t in sorted(set(t for t, _ in obs)):
        d = sum(1 for o in obs if o == (t, True))
        if d:
            s = s * (r - d) / r
            if s <= thr:
                after = [x for x in starts if x > t]
                return (t + after[0]) // 2 if avg and s == thr and after else t
        r -= sum(1 for o in obs if o[0] == t)
    return None


def dur(s):
    d, s = divmod(int(s), 86400)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    return "%dd %dh %dm" % (d, h, m) if d else ("%dh %dm" % (h, m) if h else "%dm %ds" % (m, s))


def with_date(g):
    """the fake grid's date, whose now is FAKE_NOW when a test sets it"""
    real = G.posix(shutil.which("date"))
    path = os.path.join(g.bin, "date")
    with open(path, "w", newline="\n") as fh:
        fh.write(DATE % (real, real, real))
    os.chmod(path, 0o755)


class Report(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.g = G.Grid(self.tmp.name)
        self.g.setup()
        with_date(self.g)

    def tearDown(self):
        self.tmp.cleanup()

    def report(self, args="", records=None, **extra):
        extra.setdefault("FAKE_NOW", str(NOW))
        rc, out, err = self.g.run("queue report " + args, FAKE_SACCT="\n".join(RECORDS if records is None else records), **extra)
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(err, "")
        return out.splitlines()

    def rows(self, lines):
        got = {}
        for line in lines:
            c = cells(line)
            if len(c) == 13 and c[0] != "partition":
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
        self.assertEqual(lines[1:5], HOW, "how to read it, in the report itself")
        self.assertEqual(lines[5], "")
        self.assertEqual(cells(lines[6]), COLUMNS)
        self.assertEqual([cells(l)[0] for l in lines[7:10]], ["gvohp", "reqp", "secp"], "sorted by partition, then QoS")
        self.assertEqual(self.rows(lines), ROWS)
        self.assertEqual(lines[10], "")
        self.assertEqual(lines[11:13], [LATER, BEFORE])
        self.assertEqual(lines[13], "shortest median wait: secp secondary (0m 45s)", "the one sentence the maintainer asked for")
        self.assertEqual(len(lines), 14, "no recommendation beyond it")

    def test_a_chained_successor_waits_from_eligible(self):
        # submitted at 08:00:05 while its predecessor ran; eligible at 16:00:00, when that one ended; started 30 s later
        succ = "40600001|reqp|requeue|2026-10-01T08:00:05|2026-10-01T16:00:00|2026-10-01T16:00:30|2026-10-02T00:00:30|COMPLETED|08:00:00|asx10"
        lines = self.report(records=[succ])
        self.assertEqual(self.table(lines), [["reqp", "requeue", "1", "0m 30s", "0m 30s", "0m 30s", "0", "0", "0", "0", "0", "0", "8h 0m"]], "Start minus Eligible, not minus Submit")
        self.assertEqual(lines[-1], "shortest median wait: reqp requeue (0m 30s)")
        # Eligible not a time: Submit stands in, and the wait is the 8 h 0 min 25 s since it
        lines = self.report(records=[succ.replace("|2026-10-01T16:00:00|", "|Unknown|")])
        self.assertEqual(self.table(lines)[0][3:6], ["8h 0m", "8h 0m", "8h 0m"])

    def test_each_attempt_of_a_requeued_job_waits_from_the_end_of_the_one_before(self):
        # one job, three attempts: preempted at 11:02, requeued at 12:34, then completed. As Slurm's source reads, a
        # requeue moves Submit to its own moment and Eligible two minutes and a second past it (its hold); a Slurm that
        # did not would leave both at the first attempt's, and Eligible would count the earlier runs as wait. Either
        # way each later attempt waits from the End of the one before, its hold included
        reset = ["40600010|reqp|requeue|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:02:00|2026-10-01T11:02:00|PREEMPTED|08:00:00|asx10",
                 "40600010|reqp|requeue|2026-10-01T11:02:00|2026-10-01T11:04:01|2026-10-01T11:34:00|2026-10-01T12:34:00|REQUEUED|08:00:00|asx11",
                 "40600010|reqp|requeue|2026-10-01T12:34:00|2026-10-01T12:36:01|2026-10-01T14:36:00|2026-10-01T22:36:00|COMPLETED|08:00:00|asx12"]
        kept = [r.replace("|2026-10-01T11:02:00|2026-10-01T11:04:01|", "|2026-10-01T08:00:00|2026-10-01T08:00:00|")
                 .replace("|2026-10-01T12:34:00|2026-10-01T12:36:01|", "|2026-10-01T08:00:00|2026-10-01T08:00:00|") for r in reset]
        self.assertNotEqual(kept, reset)
        for shape, rec in (("reset", reset), ("kept", kept)):
            lines = self.report(records=rec)
            self.assertEqual(lines[0], header(3), "three records of one job id: sacct -D keeps every attempt")
            # waits 120, 1920, 7320: median 32 min, p90 at ceil(2.7) = 3; the runs cut short by the preemption and the
            # requeue are not runs: the one of 8 h
            self.assertEqual(self.table(lines), [["reqp", "requeue", "3", "32m 0s", "2h 2m", "2h 2m", "0", "0", "1", "1", "0", "0", "8h 0m"]], shape)
            self.assertEqual(lines[-2:], ["2 of the starts above are later attempts of a requeued job", "shortest median wait: reqp requeue (32m 0s)"], shape)
        # the verifier's case: eligible at 08:00, two preemptions, then a run of 8 h; a secp job waited 20 min. Waits
        # 5, 7 and 7 min, the requeue holds (2 min each) included, in both shapes
        rec = ["43000001|reqp|requeue|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:05:00|2026-10-01T08:35:00|PREEMPTED|08:00:00|asx10",
               "43000001|reqp|requeue|2026-10-01T08:35:00|2026-10-01T08:37:01|2026-10-01T08:42:00|2026-10-01T09:02:00|PREEMPTED|08:00:00|asx11",
               "43000001|reqp|requeue|2026-10-01T09:02:00|2026-10-01T09:04:01|2026-10-01T09:09:00|2026-10-01T17:09:00|COMPLETED|08:00:00|asx12",
               "43000002|secp|secondary|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:20:00|2026-10-01T16:20:00|COMPLETED|08:00:00|asx13"]
        for r in (rec, [x.replace("|2026-10-01T08:35:00|2026-10-01T08:37:01|", "|2026-10-01T08:00:00|2026-10-01T08:00:00|")
                         .replace("|2026-10-01T09:02:00|2026-10-01T09:04:01|", "|2026-10-01T08:00:00|2026-10-01T08:00:00|") for x in rec]):
            self.assertEqual(self.table(self.report(records=r))[0], ["reqp", "requeue", "3", "7m 0s", "7m 0s", "7m 0s", "0", "0", "2", "0", "0", "0", "8h 0m"])
        # a later attempt still in line waits from the End of the one before, so far
        rec = ["40600011|reqp|requeue|2026-10-04T08:00:00|2026-10-04T08:00:00|2026-10-04T08:10:00|2026-10-04T11:00:00|PREEMPTED|08:00:00|asx10",
               "40600011|reqp|requeue|2026-10-04T11:00:00|2026-10-04T11:02:01|Unknown|Unknown|PENDING|08:00:00|None assigned"]
        self.assertEqual(self.table(self.report(records=rec)), [["reqp", "requeue", "1", "10m 0s", ">1h 0m", ">1h 0m", "1", "0", "1", "0", "0", "0", "-"]])

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
        self.assertEqual(self.table(lines), [["sec", "normal", "11", "6m 0s", "10m 0s", "11m 0s", "0", "0", "0", "0", "0", "0", "1h 0m"],
                                             ["secp", "normal", "10", "5m 30s", "9m 0s", "10m 0s", "0", "0", "0", "0", "0", "0", "1h 0m"]])

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
        lines = self.report(TMPDIR=tmpd, TZ="America/Detroit", SLURM_TIME_FORMAT="relative", FAKE_NOW="")
        self.assertEqual(lines[0], header(16), "the real clock: a report made now, whatever the records say")
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
            lines = self.report(records=rec, TZ="America/Detroit", SLURM_TIME_FORMAT=fmt, FAKE_NOW=str(at("2026-11-02T00:00:00")))
            # waits 1200 and 30: median 615; runs 9 h and 9 h
            self.assertEqual(self.table(lines), [["reqp", "requeue", "2", "10m 15s", "20m 0s", "20m 0s", "0", "0", "0", "0", "0", "0", "9h 0m"]], fmt)
            self.assertNotIn(BEFORE, lines, fmt)
        self.assertEqual({(a["TZ"], a["SLURM_TIME_FORMAT"]) for a in self.g.argvs()}, {("UTC0", "standard")})

    def test_times_in_a_form_the_report_does_not_read_are_said_not_dropped(self):
        # what a sacct whose time format nobody pinned would print: the records count by state, and the report says so
        rec = ["40600030|reqp|requeue|01 Oct 08:00|01 Oct 08:00|01 Oct 08:05|01 Oct 09:05|COMPLETED|08:00:00|asx10",
               "40600031|reqp|requeue|01 Oct 10:00|01 Oct 10:00|Unknown|Unknown|PENDING|08:00:00|None assigned"]
        lines = self.report(records=rec)
        self.assertEqual(lines[0], header(2))
        self.assertEqual(self.table(lines), [["reqp", "requeue", "0", "-", "-", "-", "1", "0", "0", "0", "0", "0", "-"]])
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
        self.assertIn("from Eligible (or Submit where Eligible", out)
        self.assertIn("a job not started counted as", out)

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

    def test_no_job_started_yet(self):
        # every record pending or cancelled before a start: each waited at least its time in line, and no median is
        # reached (pending since 00:00, 01:00 and 02:00, 12, 11 and 10 h at noon; one cancelled after 5 min in line)
        pend = ["4050010%d|reqp|requeue|2026-10-04T0%d:00:00|2026-10-04T0%d:00:00|Unknown|Unknown|PENDING|08:00:00|None assigned" % (i, i, i) for i in range(3)]
        canc = ["40500110|secp|secondary|2026-10-03T07:00:00|2026-10-03T07:00:00|None|2026-10-03T07:05:00|CANCELLED by 1234|00:10:00|None assigned"]
        lines = self.report(records=pend + canc)
        self.assertEqual(self.table(lines), [["reqp", "requeue", "0", ">12h 0m", ">12h 0m", ">12h 0m", "3", "0", "0", "0", "0", "0", "-"],
                                             ["secp", "secondary", "0", ">5m 0s", ">5m 0s", ">5m 0s", "0", "1", "0", "0", "0", "0", "-"]])
        self.assertEqual(lines[-1], "shortest median wait: not known (no median is reached: in each row more than half of the jobs were still waiting at its longest wait)")
        # nothing in the window at all to wait on (every job started before it): a footer that says so
        early = "40400002|reqp|requeue|2026-09-10T08:00:00|2026-09-10T08:00:00|2026-09-12T08:00:00|Unknown|RUNNING|14-00:00:00|asx10"
        self.assertEqual(self.report(records=[early])[-1], "shortest median wait: none (no job in the window has started)")

    def test_a_wait_that_ended_before_the_window_is_left_out(self):
        # sacct lists a job running when the window opened (2026-09-20T12:00:00 for 14 days at noon of 2026-10-04): its
        # wait of 2 days ended on 2026-09-12, outside the report. A wait that began before the window and ended in it
        # (eligible 09-18, started 09-21) counts whole
        rec = ["40400001|reqp|requeue|2026-09-10T08:00:00|2026-09-10T08:00:00|2026-09-12T08:00:00|2026-09-25T08:00:00|COMPLETED|14-00:00:00|asx10",
               "40500001|reqp|requeue|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:00:30|2026-10-01T09:00:30|COMPLETED|08:00:00|asx10"]
        lines = self.report(records=rec)
        self.assertEqual(lines[0], header(2), "both are records sacct listed")
        self.assertEqual(self.table(lines), [["reqp", "requeue", "1", "0m 30s", "0m 30s", "0m 30s", "0", "0", "0", "0", "0", "0", "1h 0m"]])
        self.assertEqual(lines[-2:], ["1 record of jobs that started before the window began (running when it opened): its wait and run left out",
                                      "shortest median wait: reqp requeue (0m 30s)"])
        rec.append("40450001|reqp|requeue|2026-09-18T12:00:00|2026-09-18T12:00:00|2026-09-21T12:00:00|2026-09-21T13:00:00|COMPLETED|08:00:00|asx10")
        self.assertEqual(self.table(self.report(records=rec))[0][2:6], ["2", "1d 12h 0m", "3d 0h 0m", "3d 0h 0m"])
        # the edge is the report's own clock: one second later the same job is in, one second before it is out
        edge = ["40450002|reqp|requeue|2026-09-20T11:00:00|2026-09-20T11:00:00|2026-09-20T12:00:00|2026-09-20T13:00:00|COMPLETED|08:00:00|asx10"]
        self.assertEqual(self.table(self.report(records=edge))[0][2:4], ["1", "1h 0m"])
        self.assertEqual(self.table(self.report(records=edge, FAKE_NOW=str(NOW + 1)))[0][2:4], ["0", "-"])

    def test_jobs_not_started_count_as_waiting_at_least_so_long(self):
        # the verifier's case: on reqp three jobs waited 5 min, one is pending since 09-28T08:00 (6 d 4 h at noon of
        # 10-04), three were cancelled after 2 days in line; on secp three waited 30 min. Four of seven reqp jobs never
        # got a node: its median is not reached, and secp is the shorter
        rec = ["4100000%d|reqp|requeue|2026-10-01T%02d:00:00|2026-10-01T%02d:00:00|2026-10-01T%02d:05:00|2026-10-01T%02d:05:00|COMPLETED|08:00:00|asx10" % (i, 8 + i, 8 + i, 8 + i, 9 + i) for i in range(3)]
        rec += ["41000004|reqp|requeue|2026-09-28T08:00:00|2026-09-28T08:00:00|Unknown|Unknown|PENDING|08:00:00|None assigned"]
        rec += ["4100001%d|reqp|requeue|2026-09-29T0%d:00:00|2026-09-29T0%d:00:00|None|2026-10-01T0%d:00:00|CANCELLED by 1234|08:00:00|None assigned" % (i, 7 + i, 7 + i, 7 + i) for i in range(3)]
        rec += ["4100002%d|secp|secondary|2026-10-01T%02d:00:00|2026-10-01T%02d:00:00|2026-10-01T%02d:30:00|2026-10-01T%02d:30:00|COMPLETED|08:00:00|asx10" % (i, 8 + i, 8 + i, 8 + i, 9 + i) for i in range(3)]
        lines = self.report(records=rec)
        self.assertEqual(self.table(lines), [["reqp", "requeue", "3", ">6d 4h 0m", ">6d 4h 0m", ">6d 4h 0m", "1", "3", "0", "0", "0", "0", "1h 0m"],
                                             ["secp", "secondary", "3", "30m 0s", "30m 0s", "30m 0s", "0", "0", "0", "0", "0", "0", "1h 0m"]])
        self.assertEqual(lines[-1], "shortest median wait: secp secondary (30m 0s)")
        # a job submitted a minute ago is not a one-minute wait: three waits of 1 h and one pending for 1 min, median 1 h
        rec = ["4110000%d|secp|secondary|2026-10-03T0%d:00:00|2026-10-03T0%d:00:00|2026-10-03T0%d:00:00|2026-10-03T0%d:30:00|COMPLETED|08:00:00|asx10" % (i, i, i, i + 1, i + 1) for i in range(3)]
        rec += ["41100009|secp|secondary|2026-10-04T11:59:00|2026-10-04T11:59:00|Unknown|Unknown|PENDING|08:00:00|None assigned"]
        self.assertEqual(self.table(self.report(records=rec))[0][2:7], ["3", "1h 0m", "1h 0m", "1h 0m", "1"])
        # a median not reached below the shortest one is not ranked: one start at 1 min and three pending 10 min on reqp
        rec += ["4120000%d|reqp|requeue|2026-10-04T11:50:00|2026-10-04T11:50:00|Unknown|Unknown|PENDING|08:00:00|None assigned" % i for i in range(3)]
        rec += ["41200009|reqp|requeue|2026-10-04T11:00:00|2026-10-04T11:00:00|2026-10-04T11:01:00|2026-10-04T11:30:00|COMPLETED|08:00:00|asx10"]
        lines = self.report(records=rec)
        self.assertEqual(self.table(lines)[0][2:7], ["1", ">10m 0s", ">10m 0s", ">10m 0s", "3"])
        self.assertEqual(lines[-1], "shortest median wait: secp secondary (1h 0m); not known against reqp requeue (more than 10m 0s), whose median is not reached")

    def test_kaplan_meier_against_the_product_limit_formula(self):
        # rows of 1 to 12 jobs, waits drawn with ties, about two in five not started (cancelled in line): median and p90
        # as the formula in exact fractions gives them, "> longest" where it is not reached
        rnd = random.Random(20261004)
        rec, want = [], {}
        el = NOW - 2 * 86400
        for row in range(40):
            part, obs = "p%02d" % row, []
            for i in range(rnd.randint(1, 12)):
                t, ran = rnd.choice([0, 30, 60, 60, 120, 300, 600, 600, 3600, 7200]), rnd.random() < 0.6
                obs.append((t, ran))
                if ran:
                    rec.append("5%02d%04d|%s|q|%s|%s|%s|%s|COMPLETED|01:00:00|asx1" % (row, i, part, iso(el), iso(el), iso(el + t), iso(el + t + 60)))
                else:
                    rec.append("5%02d%04d|%s|q|%s|%s|None|%s|CANCELLED by 1|01:00:00|None assigned" % (row, i, part, iso(el), iso(el), iso(el + t)))
            longest = ">" + dur(max(t for t, _ in obs))
            m, p = km(obs, 0.5, True), km(obs, 0.9, False)
            want[part] = [dur(m) if m is not None else longest, dur(p) if p is not None else longest]
        got = {c[0]: c[3:5] for c in self.table(self.report(records=rec))}
        self.assertEqual(got, want)
        # by hand: a start at 1 and 3 min, one cancelled at 2: the share 3/4, then 3/4 * 1/2 at 3 min, the median 3 min
        # (taken as four starts it would be 2 min 30 s); and at one time a start comes before a job leaving the line,
        # so the share falls exactly to 1/2 at 2 min and the median is the mean of 2 and 3 min (taken the other way, 2 min)
        self.assertEqual(km([(60, True), (120, False), (180, True), (240, True)], 0.5, True), 180)
        self.assertEqual(km([(60, True), (120, True), (120, False), (180, True)], 0.5, True), 150)
        for obs, median in (([(60, True), (120, False), (180, True), (240, True)], "3m 0s"), ([(60, True), (120, True), (120, False), (180, True)], "2m 30s")):
            rec = []
            for i, (t, ran) in enumerate(obs):
                rec.append("6000%d|r|q|%s|%s|%s|%s|%s|01:00:00|%s" % (i, iso(el), iso(el), iso(el + t) if ran else "None", iso(el + t + (60 if ran else 0)),
                                                                     "COMPLETED" if ran else "CANCELLED by 1", "asx1" if ran else "None assigned"))
            self.assertEqual(self.table(self.report(records=rec))[0][3], median)

    def test_cancelled_before_and_after_a_start(self):
        # one job ran 55 min and was cancelled (a worker taken down); one sat 2 days in line and was cancelled; one ran
        # 8 h. "gave up" and "cancelled" apart, and the 2 days in line are a wait known to be at least that long
        rec = ["42000001|reqp|requeue|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:05:00|2026-10-01T09:00:00|CANCELLED by 1234|08:00:00|asx10",
               "42000002|reqp|requeue|2026-09-29T08:00:00|2026-09-29T08:00:00|None|2026-10-01T08:00:00|CANCELLED by 1234|08:00:00|None assigned",
               "42000003|reqp|requeue|2026-10-01T10:00:00|2026-10-01T10:00:00|2026-10-01T10:10:00|2026-10-01T18:10:00|COMPLETED|08:00:00|asx11"]
        want = [["reqp", "requeue", "2", "10m 0s", ">2d 0h 0m", ">2d 0h 0m", "0", "1", "0", "0", "1", "0", "4h 27m"]]
        self.assertEqual(self.table(self.report(records=rec)), want)
        # where Slurm records a cancel in line as Start and End both, or names no node, it is still a cancel before a start
        both = rec[1].replace("|None|", "|2026-10-01T08:00:00|")
        self.assertEqual(self.table(self.report(records=[rec[0], both, rec[2]])), want, "Start = End")
        self.assertEqual(self.table(self.report(records=[rec[0], both.replace("|None assigned", "|"), rec[2]])), want, "Start = End, the node field empty")
        self.assertEqual(self.table(self.report(records=[rec[0], both.replace("|CANCELLED by 1234|", "|FAILED|"), rec[2]]))[0][2:8],
                         ["2", "10m 0s", ">2d 0h 0m", ">2d 0h 0m", "0", "0"], "no node: not started, whatever the state")
        # and a pending record with an expected Start is still in line
        pend = "42000004|reqp|requeue|2026-10-04T10:00:00|2026-10-04T10:00:00|2026-10-04T14:00:00|Unknown|PENDING|08:00:00|asx12"
        self.assertEqual(self.table(self.report(records=[pend]))[0][2:7], ["0", ">2h 0m", ">2h 0m", ">2h 0m", "1"])

    def test_array_tasks_are_left_out(self):
        # an --array=0-19%2 of 1 h tasks: every task eligible at 08:00, two at a time by the array's own limit, the last
        # two not yet split off; three workers on reqp waited 5 min, three on secp 30 min. The array would read as reqp's
        # waits of up to 8 h, and its unsplit record as one pending job for two
        rec = ["41100000_%d|reqp|requeue|2026-10-02T08:00:00|2026-10-02T08:00:00|2026-10-02T%02d:00:00|2026-10-02T%02d:00:00|COMPLETED|01:00:00|asx1%d" % (i, 8 + i // 2, 9 + i // 2, i % 2) for i in range(18)]
        rec += ["41100000_[18-19%2]|reqp|requeue|2026-10-02T08:00:00|2026-10-02T08:00:00|Unknown|Unknown|PENDING|01:00:00|None assigned"]
        rec += ["4120000%d|reqp|requeue|2026-10-01T0%d:00:00|2026-10-01T0%d:00:00|2026-10-01T0%d:05:00|2026-10-01T0%d:05:00|COMPLETED|08:00:00|asx10" % (i, i, i, i, i + 1) for i in range(1, 4)]
        rec += ["4130000%d|secp|secondary|2026-10-01T0%d:00:00|2026-10-01T0%d:00:00|2026-10-01T0%d:30:00|2026-10-01T0%d:30:00|COMPLETED|08:00:00|asx10" % (i, i, i, i, i + 1) for i in range(1, 4)]
        lines = self.report(records=rec)
        self.assertEqual(lines[0], header(25))
        self.assertEqual([c[:7] for c in self.table(lines)], [["reqp", "requeue", "3", "5m 0s", "5m 0s", "5m 0s", "0"], ["secp", "secondary", "3", "30m 0s", "30m 0s", "30m 0s", "0"]])
        self.assertEqual(lines[-2:], ["19 records of array tasks (20 tasks) left out: a task waits on the limit of its array (%N) as well as for a node",
                                      "shortest median wait: reqp requeue (5m 0s)"])
        # the tasks of an unsplit record, counted from its brackets
        for ids, n in ((["7_[0-199%10]"], 200), (["7_[1,3,5-7]"], 5), (["7_[4]"], 1), (["7_1", "7_[2-3]"], 3)):
            rec = ["%s|reqp|requeue|2026-10-02T08:00:00|2026-10-02T08:00:00|Unknown|Unknown|PENDING|01:00:00|None assigned" % i for i in ids]
            self.assertIn("%d record%s of array tasks (%d task%s) left out: a task waits on the limit of its array (%%N) as well as for a node"
                          % (len(ids), "s" if len(ids) > 1 else "", n, "s" if n > 1 else ""), self.report(records=rec), ids)

    def test_a_line_that_is_not_a_record_is_left_out(self):
        # a notice sacct printed first, and a line with one field too many (a '|' where none belongs): left out and
        # counted, never read one column off
        shifted = "40500030|secp|x|secondary|2026-10-01T08:00:00|2026-10-01T08:00:00|2026-10-01T08:00:20|2026-10-01T08:10:20|COMPLETED|00:10:00|asx15"
        lines = self.report(records=["sacct: a notice the site prints first"] + RECORDS + [shifted, "", "\r"])
        self.assertEqual(lines[0], header(16))
        self.assertEqual(self.rows(lines), ROWS)
        self.assertIn("2 lines that were not a record left out, the first: sacct: a notice the site prints first", lines)

    def test_a_notice_and_no_record_is_no_jobs(self):
        # a site whose sacct prints a notice first (or a warning on stderr, which adapter_history keeps): an account with
        # no jobs is still one line, the notice said, and exit 0
        rc, out, err = self.g.run("queue report", FAKE_SACCT="sacct: a notice the site prints first", FAKE_NOW=str(NOW))
        self.assertEqual((rc, err), (0, ""), out)
        self.assertEqual(out.splitlines(), ["no jobs of st1234 eligible or running at any time in the last 14 days, in the history the scheduler keeps (%s)" % query(14),
                                            "1 line that was not a record left out, the first: sacct: a notice the site prints first"])

    def test_lines_shaped_like_records_of_another_form_are_a_failure(self):
        rc, out, err = self.g.run("queue report", FAKE_SACCT="sacct: a notice the site prints first\nsomething|else", FAKE_NOW=str(NOW))
        self.assertEqual((rc, out), (1, ""))
        self.assertEqual(err.splitlines(), ["hpcworker: none of the lines sacct printed is a record this report reads (ten fields between '|'); the first shaped like one: something|else"])


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
