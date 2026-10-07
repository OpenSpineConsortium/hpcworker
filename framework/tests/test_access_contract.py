"""The access service's published contract against the tool that reads it. interface/access/ is a
pinned copy of OpenSpineConsortium/beethoven-access's export http-api (interface/access/pull.sh writes
it with ORIGIN), and tools/grid_access.sh takes the approved list and the readers from the service's two
plain-text answers, GET /admin/roster.txt and GET /admin/readers.txt. Here: every line of the roster and
readers vectors' bodies passes the tool's own checks (the real script's parsing path, run with --dry-run
against an ssh that answers nothing, the bodies as its files), the bodies follow lines.json's rules, and
lines.json's two line patterns and the cap are the script's, agreeing on good and bad lines. Until the
copy is pulled there is nothing to compare, and the class is skipped with the command that pulls it,
never passed."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

import fakegrid as G

REPO = os.path.dirname(G.ROOT)
ACCESS = os.path.join(REPO, "interface", "access")
ORIGIN = os.path.join(ACCESS, "ORIGIN")
TOOL = os.path.join(REPO, "tools", "grid_access.sh")
PULL = "bash interface/access/pull.sh"


def vector(name):
    with open(os.path.join(ACCESS, "vectors", name + ".json"), encoding="utf-8") as fh:
        return json.load(fh)


def lines_json():
    with open(os.path.join(ACCESS, "lines.json"), encoding="utf-8") as fh:
        return json.load(fh)["texts"]


def script():
    with open(TOOL, encoding="utf-8") as fh:
        return fh.read()


def tool(roster, readers, *flags):
    """grid_access.sh on the two bodies as its files, dry run, with an ssh on PATH that records its
    call and ends 255 (one that could not connect): what comes back is the parse, then that refusal.
    -> (exit, stdout, stderr, the one ssh call or "")"""
    d = tempfile.mkdtemp(prefix="access_contract.")
    try:
        for name in ("home", "vendor", "bin"):
            os.mkdir(os.path.join(d, name))
        ssh = os.path.join(d, "bin", "ssh")
        with open(ssh, "w", newline="\n") as fh:
            fh.write('#!/bin/sh\nprintf "%s\\n" "$*" >> "$0.calls"\nexit 255\n')
        os.chmod(ssh, 0o755)
        rf, df = os.path.join(d, "roster.txt"), os.path.join(d, "readers.txt")
        with open(rf, "w", newline="") as fh:
            fh.write(roster)
        with open(df, "w", newline="") as fh:
            fh.write(readers)
        env = dict(os.environ, HOME=os.path.join(d, "home"), BEETHOVEN_VENDOR_DIR=os.path.join(d, "vendor"),
                   PATH=os.path.join(d, "bin") + os.pathsep + os.environ.get("PATH", ""))
        for k in ("BEETHOVEN_ROSTER_CMD", "BEETHOVEN_READERS_CMD", "BEETHOVEN_SERVICE_URL"):
            env.pop(k, None)
        p = subprocess.run([G.BASH, TOOL, "--site", "wayne", "--host", "nowhere", "--root", "/lab/volume",
                            "--roster-file", rf, "--readers-file", df, "--dry-run"] + list(flags),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, env=env)
        call = ""
        if os.path.exists(ssh + ".calls"):
            with open(ssh + ".calls", encoding="utf-8") as fh:
                call = fh.read().strip()
        return p.returncode, p.stdout, p.stderr, call
    finally:
        shutil.rmtree(d, ignore_errors=True)


# lines the two patterns must agree on: what the service gives, and what neither side may take
GOOD = ["ab1234 .", "ab1234 shared/data", "zq0006 lab", "zq0006 a_b/c-d.e/f9", "cd5678 x" + "/" + "y" * 190]
BAD = ["AB1234 x", "ab1234 ../x", "ab1234 /x", "ab1234 .hidden", "ab1234 x/", "ab1234 ./x", "ab1234 x/.",
       "ab1234", "ab1234 a b", "ab12345 x", "ab1234 -x", "ab1234 x//y", "ab1234 x:y", "ab1234 ..", "ab1234 /"]


@unittest.skipUnless(os.path.exists(ORIGIN), "interface/access/ORIGIN is not there yet: %s pulls the access service's "
                                               "contract (gh, signed in), then run the suite again" % PULL)
class AccessContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.roster = vector("admin-roster-txt")
        cls.readers = vector("admin-readers-txt")
        cls.empty = vector("admin-roster-txt-empty")
        cls.texts = lines_json()
        cls.code = script()

    def test_the_answers_the_tool_takes(self):
        # the tool accepts 200 and a content type starting text/plain and nothing else; each list vector is that
        for v in (self.roster, self.readers, self.empty):
            with self.subTest(vector=v["vector"]):
                self.assertEqual(v["answer"]["status"], 200)
                self.assertTrue(v["answer"]["headers"]["content-type"].startswith("text/plain"))
        self.assertIn("text/plain*) return 0", self.code)
        # the token refusals the auth answers with are the ones the tool names as the token not accepted
        with open(os.path.join(ACCESS, "routes.json"), encoding="utf-8") as fh:
            auth = json.load(fh)["auth"]["admin-token"]["answers"]
        self.assertEqual(sorted(auth), ["401", "403"])
        self.assertIn("401|403)", self.code)
        self.assertIn("404)", self.code)

    def test_the_bodies_follow_the_rules(self):
        roster, readers = self.roster["answer"]["body"], self.readers["answer"]["body"]
        self.assertEqual(self.empty["answer"]["body"], "")
        for body in (roster, readers):
            self.assertNotIn("\r", body)
            self.assertTrue(body.endswith("\n"))
        ids = roster.split("\n")[:-1]
        self.assertEqual(ids, sorted(set(ids)))
        for line in ids:
            self.assertRegex(line, self.texts["roster"]["line"])
        pairs = readers.split("\n")[:-1]
        self.assertEqual(pairs, sorted(set(pairs)))
        for line in pairs:
            self.assertRegex(line, self.texts["readers"]["line"])
            self.assertLessEqual(len(line), self.texts["readers"]["max_line"])

    def test_the_roster_vector_passes_the_tool(self):
        rc, out, err, call = tool(self.roster["answer"]["body"], "", "--force")
        self.assertEqual(rc, 1, out + err)
        self.assertIn("ssh to nowhere failed", err)
        self.assertRegex(out, r"^grid access: 2 ids from the file \S+ and 0 readers from the file \S+ -> nowhere:/lab/volume, dry run$")
        self.assertTrue(call.endswith(" /lab/volume ab1234 zz9999 2>&1"), call)

    def test_the_readers_vector_passes_the_tool(self):
        rc, out, err, call = tool(self.roster["answer"]["body"], self.readers["answer"]["body"], "--force")
        self.assertEqual(rc, 1, out + err)
        self.assertIn("ssh to nowhere failed", err)
        self.assertRegex(out, r"^grid access: 2 ids from the file \S+ and 3 readers from the file \S+ -> nowhere:/lab/volume, dry run$")
        self.assertIn(" --sweep-readers --read cd5678:shared/data --read rd5678:lab --read rd5678:shared/access --read zq0006:. /lab/volume ab1234 zz9999 2>&1", call)

    def test_the_empty_roster_vector(self):
        # an empty body is an empty list: refused without --force (it would shut every student out), applied with it
        rc, out, err, call = tool(self.empty["answer"]["body"], self.readers["answer"]["body"])
        self.assertEqual(rc, 1)
        self.assertIn("gave no AccessID; applying that would shut every student out of /lab/volume", err)
        self.assertEqual(call, "")
        rc, out, err, call = tool(self.empty["answer"]["body"], self.readers["answer"]["body"], "--force")
        self.assertEqual(rc, 1, out + err)
        self.assertIn("ssh to nowhere failed", err)
        self.assertRegex(out, r"^grid access: 0 ids from the file \S+ and 3 readers from the file \S+ -> ")
        # no id follows the root on the grid side's line, so two blanks stand where the list would be
        self.assertRegex(call, r" --read zq0006:\. /lab/volume\s+2>&1$")

    def patterns(self):
        """(lines.json's roster line, its readers line; the script's ID_RE, its READ_RE with the service's
        separator put back, since the script joins an id and a folder with ':' before matching)"""
        id_re = re.search(r"^ID_RE='(.*)'$", self.code, re.M).group(1)
        read_re = re.search(r"^READ_RE='(.*)'$", self.code, re.M).group(1)
        return self.texts["roster"]["line"], self.texts["readers"]["line"], id_re, read_re.replace("{4}:", "{4} ", 1)

    def test_the_patterns_are_the_script_s(self):
        roster, readers, id_re, read_re = self.patterns()
        self.assertEqual(id_re, roster)
        self.assertEqual(read_re, readers)
        self.assertEqual(len(re.findall(r"-le %d \]" % self.texts["readers"]["max_line"], self.code)), 2, "the cap on a readers line, on both sides")

    def test_good_and_bad_lines_agree(self):
        roster, readers, id_re, read_re = self.patterns()
        for line in GOOD:
            with self.subTest(line=line):
                self.assertTrue(re.match(readers, line) and re.match(read_re, line) and len(line) <= self.texts["readers"]["max_line"])
        for line in BAD:
            with self.subTest(line=line):
                self.assertFalse(re.match(readers, line) or re.match(read_re, line))
        for line in ("ab1234", "zz9999"):
            self.assertTrue(re.match(roster, line) and re.match(id_re, line))
        for line in ("AB1234", "ab12345", "ab1234 ", "a1234"):
            self.assertFalse(re.match(roster, line) or re.match(id_re, line))

    def test_the_tool_agrees_on_the_same_lines(self):
        rc, out, err, call = tool("ab1234\n", "\n".join(GOOD) + "\n", "--force")
        self.assertIn("ssh to nowhere failed", err)
        self.assertRegex(out, r"^grid access: 1 ids from the file \S+ and 3 readers from the file \S+ -> ")
        for line in BAD:
            with self.subTest(line=line):
                rc, out, err, call = tool("ab1234\n", "ab1234 shared/data\n" + line + "\n", "--force")
                self.assertEqual(rc, 1)
                self.assertRegex(err, r"line 2 of the file \S+ is not an AccessID and a folder under the root")
                self.assertEqual(call, "")


if __name__ == "__main__":
    unittest.main()
