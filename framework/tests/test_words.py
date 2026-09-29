"""House rules that a grep enforces better than a reviewer: the one banned word appears nowhere in
the framework tree (not in code, comments, tests or fixtures), and no fractional version string
does either. The banned word is assembled from parts here so that this file does not carry it."""
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BANNED = "".join(chr(c) for c in (112, 114, 111, 118, 101, 110, 97, 110, 99, 101))  # built at run time so no compiled file carries it
SKIP_DIRS = {"__pycache__", ".pytest_cache"}


def files():
    for base, dirs, names in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for n in names:
            if n.endswith(".pyc"):
                continue
            yield os.path.join(base, n)


class Words(unittest.TestCase):
    def test_banned_word_absent_everywhere(self):
        hits = []
        for path in files():
            with open(path, "rb") as fh:
                data = fh.read()
            if BANNED.encode() in data.lower():
                hits.append(os.path.relpath(path, ROOT))
        self.assertEqual(hits, [])

    def test_versions_are_integers(self):
        # "version 1", "VERSION=1", "hpcworker 2": never "version 1.5" or "v0.9"
        bad = []
        pat = re.compile(rb"(?i)\b(hpcworker|framework|schema)\s+(version\s+)?v?\d+\.\d+\b")
        for path in files():
            with open(path, "rb") as fh:
                for i, line in enumerate(fh, 1):
                    if pat.search(line):
                        bad.append("%s:%d" % (os.path.relpath(path, ROOT), i))
        self.assertEqual(bad, [])
        with open(os.path.join(ROOT, "VERSION")) as fh:
            self.assertRegex(fh.read().strip(), r"^\d+$")


if __name__ == "__main__":
    unittest.main()
