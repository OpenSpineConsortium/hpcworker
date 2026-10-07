"""The interface standard's rules 1 and 3 for this repository (interface/README.md): nothing here
reads, runs or copies a file of another Beethoven repository's checkout, and what it takes from one is
a pinned copy that matches its ORIGIN. A line that reaches a sibling checkout fails unless it is on the
known list below with its reason, and an entry that no longer matches fails too, so the list only
shrinks."""
import hashlib
import json
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SELF = "hpcworker"
# every repository of the ecosystem and the names their checkouts had (the Desktop folders ashley and
# ashley-bridge), and the website's
OTHERS = ("beethoven", "beethoven-extension", "beethoven-desktop", "beethoven-qa", "beethoven-agents", "beethoven-research",
          "beethoven-sites", "beethoven-base", "beethoven-vscode", "ashley", "ashley-bridge", "openspineconsortium.github.io",
          "spinesurg-ct-nnunet", "u251-xenograft-rat-rnaseq-study")
_names = "|".join(re.escape(n) for n in sorted(OTHERS, key=len, reverse=True))
# a path made from this checkout's parent: "../<repo>", or "$(dirname ...)/<repo>" and the like
SIBLING_PATH = re.compile(r"(?:\.\./|\)/|\}/)(%s)(?![A-Za-z0-9_.-])" % _names)
# a variable whose value is another repository's checkout
CHECKOUT_VAR = re.compile(r"\b((?:HPCWORKER|ASHLEY|SITES|QA|BEETHOVEN_(?:SERVICE|QA|AGENTS|RESEARCH|SITES|EXTENSION|DESKTOP|VSCODE|BASE|HUB))_DIR)\b")
# a clone of another repository of the organisation (this repository's own push route clones a bundle of itself)
CLONE = re.compile(r"\b(?:git clone|gh repo clone)\b[^\n]*?OpenSpineConsortium/(%s)\b" % _names, re.I)
CHECKOUT_ACTION_REPO = re.compile(r"^\s*repository:\s*\S+", re.M)

# (file, what matched) -> why it is still here and who removes it
KNOWN = {
    ("tools/grid_access.sh", "ashley"): "the roster's default source is a beethoven-vscode checkout beside this one "
                                        "(admin.mjs roster); the access thread owns the file (2026-10-07) and is asked to take "
                                        "the roster only from --roster-file or BEETHOVEN_ROSTER_CMD",
    ("tools/grid_access.sh", "BEETHOVEN_SERVICE_DIR"): "the same default: a variable naming that checkout",
    ("tools/tests/test_grid_access.sh", "BEETHOVEN_SERVICE_DIR"): "the test of that default, which goes with it",
}


def tracked():
    """the repository's files: git's list where git is at hand, else the tree without .git and caches"""
    try:
        out = subprocess.run(["git", "-C", REPO, "ls-files", "-z"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True).stdout
        files = [f for f in out.decode("utf-8").split("\0") if f]
        if files:
            return files
    except (OSError, subprocess.CalledProcessError):
        pass
    found = []
    for d, dirs, names in os.walk(REPO):
        dirs[:] = [x for x in dirs if x not in (".git", "__pycache__", "node_modules")]
        found += [os.path.relpath(os.path.join(d, n), REPO).replace(os.sep, "/") for n in names if not n.endswith(".pyc")]
    return found


def text(rel):
    try:
        with open(os.path.join(REPO, rel), encoding="utf-8") as fh:
            return fh.read()
    except (UnicodeDecodeError, OSError):
        return ""


class SealedTree(unittest.TestCase):
    """Rule 1: the repository builds, tests and runs from its own tree."""

    def test_nothing_reaches_a_sibling_checkout(self):
        found = {}
        for rel in tracked():
            if rel.endswith(".md") or rel == "framework/tests/test_boundary.py":
                continue   # prose may name another repository; this file names them to look for them
            body = text(rel)
            for n, line in enumerate(body.split("\n"), 1):
                for rx in (SIBLING_PATH, CHECKOUT_VAR, CLONE):
                    for m in rx.finditer(line):
                        found.setdefault((rel, m.group(1)), "%s:%d: %s" % (rel, n, line.strip()[:160]))
        new = dict((k, v) for k, v in found.items() if k not in KNOWN)
        self.assertEqual(new, {}, "these lines reach another repository's checkout; take what is needed from that "
                                  "repository's interface instead (interface/README.md)")
        stale = sorted(k for k in KNOWN if k not in found)
        self.assertEqual(stale, [], "fixed: remove these from KNOWN in test_boundary.py")

    def test_no_submodule_and_no_other_repository_checked_out_in_ci(self):
        self.assertFalse(os.path.exists(os.path.join(REPO, ".gitmodules")))
        for rel in tracked():
            if rel.startswith(".github/workflows/"):
                self.assertIsNone(CHECKOUT_ACTION_REPO.search(text(rel)), "%s checks out another repository" % rel)


class PinnedImports(unittest.TestCase):
    """Rule 3: each import is a folder of exactly the files its ORIGIN lists, byte for byte."""

    def test_each_import_matches_its_origin(self):
        with open(os.path.join(REPO, "interface", "INTERFACE.json"), encoding="utf-8") as fh:
            imports = json.load(fh)["imports"]
        self.assertTrue(imports)
        for imp in imports:
            with self.subTest(into=imp["into"]):
                folder = os.path.join(REPO, imp["into"])
                with open(os.path.join(REPO, imp["origin"]), encoding="utf-8") as fh:
                    lines = [l for l in fh.read().split("\n") if l]
                self.assertEqual(lines[0], "repository " + imp["repository"])
                self.assertRegex(lines[1], r"^commit [0-9a-f]{40}$")
                exports = [l.split(" ")[1:] for l in lines if l.startswith("export ")]
                # a copy taken before its provider published INTERFACE.json has no export line; the next pull writes one
                for e in exports:
                    self.assertEqual(e, [imp["export"], str(imp["version"])])
                recorded = dict((l.split(" ", 2)[2], l.split(" ")[1]) for l in lines if l.startswith("sha256 "))
                own = {"ORIGIN", "README.md", "pull.sh"}
                present = {}
                for d, dirs, names in os.walk(folder):
                    dirs[:] = [x for x in dirs if x != "__pycache__"]
                    for n in names:
                        rel = os.path.relpath(os.path.join(d, n), folder).replace(os.sep, "/")
                        if rel in own:
                            continue
                        with open(os.path.join(d, n), "rb") as fh:
                            present[rel] = hashlib.sha256(fh.read()).hexdigest()
                self.assertEqual(present, recorded, "%s differs from %s: take a new copy with its pull.sh" % (imp["into"], imp["origin"]))


if __name__ == "__main__":
    unittest.main()
