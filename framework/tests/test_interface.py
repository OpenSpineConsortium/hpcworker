"""What this repository publishes (interface/INTERFACE.json) holds: the manifest is whole and lists
every file under interface/; the contract's schemas use only what every client's check can read; the
vectors are what the real writer produces now (vectors.py runs every scenario again) and each one
passes the schemas and the line grammar; lines.json knows every failure code connect prints, with its
exit status; rules.json is the strip list, the agent markers and the sign-in verdict the code applies;
and interface/sites/module-schema.json is what `profile.py module-schema` prints."""
import fnmatch
import json
import os
import re
import subprocess
import sys
import unittest

import fakegrid as G
import schemacheck
import vectors

REPO = os.path.dirname(G.ROOT)
IFACE = os.path.join(REPO, "interface")
CONTRACT = os.path.join(IFACE, "contract")
KINDS = {"contract", "schema", "data", "cli", "python", "files", "program", "text"}   # the standard's eight


def manifest():
    with open(os.path.join(IFACE, "INTERFACE.json"), encoding="utf-8") as fh:
        return json.load(fh)


def contract(name):
    with open(os.path.join(CONTRACT, name), encoding="utf-8") as fh:
        return json.load(fh)


def files_under(folder):
    out = []
    for d, dirs, names in os.walk(folder):
        dirs[:] = [x for x in dirs if x != "__pycache__"]
        out += [os.path.relpath(os.path.join(d, n), REPO).replace(os.sep, "/") for n in names if not n.endswith(".pyc")]
    return sorted(out)


def covered(rel, paths):
    """the standard's path rule: "dir/" every file under it, "*" within one part of the path"""
    for p in paths:
        if p.endswith("/") and rel.startswith(p):
            return True
        if not p.endswith("/") and fnmatch.fnmatchcase(rel, p) and rel.count("/") == p.count("/"):
            return True
    return False


class Manifest(unittest.TestCase):
    def test_shape(self):
        m = manifest()
        self.assertEqual((m["format"], m["name"], m["repository"]), (1, "hpcworker", "OpenSpineConsortium/hpcworker"))
        ids = [e["id"] for e in m["exports"]]
        self.assertEqual(len(ids), len(set(ids)), ids)
        for e in m["exports"]:
            with self.subTest(export=e["id"]):
                self.assertEqual(sorted(e), ["consumers", "id", "kind", "paths", "summary", "version"])
                self.assertIn(e["kind"], KINDS)
                self.assertTrue(isinstance(e["version"], int) and e["version"] >= 1)
                for c in e["consumers"]:
                    self.assertRegex(c, r"^OpenSpineConsortium/[a-z0-9.-]+$")
        for i in m["imports"]:
            self.assertEqual(sorted(i), ["export", "into", "origin", "repository", "version"])

    def test_every_path_names_files_and_interface_holds_nothing_unlisted(self):
        m = manifest()
        everything = files_under(REPO + os.sep + "framework") + files_under(IFACE) + files_under(os.path.join(REPO, "docs"))
        for e in m["exports"]:
            for p in e["paths"]:
                with self.subTest(export=e["id"], path=p):
                    self.assertTrue([f for f in everything if covered(f, [p])], "%s names no file" % p)
        paths = [p for e in m["exports"] for p in e["paths"]]
        # a pinned copy under interface/ is its import's (test_boundary.py checks it against its ORIGIN), not an export's
        imported = [i["into"].rstrip("/") + "/" for i in m["imports"]]
        loose = [f for f in files_under(IFACE) if f not in ("interface/INTERFACE.json", "interface/README.md")
                 and not covered(f, paths) and not covered(f, imported)]
        self.assertEqual(loose, [], "files under interface/ that no export lists")


class Schemas(unittest.TestCase):
    def test_only_known_keywords(self):
        for name in sorted(os.listdir(CONTRACT)):
            if name.endswith(".schema.json"):
                with self.subTest(schema=name):
                    self.assertEqual(schemacheck.keywords(contract(name)), [])

    def test_the_check_refuses_what_it_should(self):
        # a check that passes everything proves nothing: a made-up state and a missing job are both named
        errs = schemacheck.Checker(CONTRACT, "status.schema.json").errors({"version": 17, "run": "worker", "state": "asleep"})
        self.assertTrue(any("asleep" in e for e in errs), errs)
        self.assertTrue(any("job is missing" in e for e in errs), errs)
        errs = schemacheck.Checker(CONTRACT, "worker-status.schema.json").errors({"v": 1, "event": "keepalive", "at": "now"})
        self.assertTrue(errs)


class Vectors(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.made, cls.skipped = vectors.produce()
        cls.kept = {}
        for name in sorted(os.listdir(vectors.VECTORS)):
            with open(os.path.join(vectors.VECTORS, name), encoding="utf-8") as fh:
                cls.kept[name] = fh.read()

    def test_the_writer_still_writes_the_vectors(self):
        for name, v in sorted(self.made.items()):
            with self.subTest(vector=name):
                self.assertIn(name, self.kept, "a new vector: python3 framework/tests/vectors.py --write")
                self.assertEqual(vectors.dump(v), self.kept[name],
                                 "the framework's output moved; if on purpose, python3 framework/tests/vectors.py --write and "
                                 "raise the contract export's version when a client must change (interface/README.md)")
        if not self.skipped:
            self.assertEqual(sorted(self.kept), sorted(self.made), "a vector no scenario produces")

    def test_files_pass_their_schema(self):
        schemas = {"status.json": "status.schema.json", "connection.json": "connection.schema.json"}
        for name, raw in sorted(self.kept.items()):
            v = json.loads(raw)
            if v["kind"] == "file" and "json" in v:
                with self.subTest(vector=name):
                    self.assertEqual(schemacheck.Checker(CONTRACT, schemas[v["file"]]).errors(v["json"]), [])

    def test_json_lines_pass_the_worker_status_schema(self):
        c = schemacheck.Checker(CONTRACT, "worker-status.schema.json")
        n = 0
        for name, raw in sorted(self.kept.items()):
            for line in json.loads(raw).get("stdout", []):
                if line.startswith('{"v":1'):
                    n += 1
                    with self.subTest(vector=name):
                        self.assertEqual(c.errors(json.loads(line)), [])
        self.assertGreaterEqual(n, 2)

    def test_lines_follow_the_grammar(self):
        fams = contract("lines.json")["families"]
        step, login, gate = fams["step"], fams["login"], fams["gate"]
        line_res = [re.compile(l["pattern"]) for f in (step, login, gate, fams["version"]) for l in f["lines"]]
        for name, raw in sorted(self.kept.items()):
            v = json.loads(raw)
            if v["kind"] != "command":
                continue
            with self.subTest(vector=name):
                for line in v["stdout"] + v["stderr"]:
                    if line.startswith(("HPCW-", "AUTH-URL", "SIGNED-IN")):
                        self.assertTrue(any(r.search(line) for r in line_res), line)
                steps = [l.split(" ")[1] for l in v["stdout"] if l.startswith("HPCW-STEP ")]
                if not steps:
                    continue
                order = [s for s in steps if s != "failed"]
                self.assertEqual(order, sorted(order, key=step["order"].index))
                if "failed" in steps:
                    self.assertEqual(steps[-1], "failed")
                    code = re.match(step["lines"][-1]["pattern"], [l for l in v["stdout"] if l.startswith("HPCW-STEP failed")][0]).group(1)
                    self.assertEqual(v["exit"], step["failure_codes"][code], code)
                else:
                    self.assertEqual((steps[-1], v["exit"]), ("done", 0))

    def test_progress_sentences(self):
        prog = contract("lines.json")["families"]["progress"]
        texts = [s["text"] for s in prog["sentences"]]
        for name, raw in sorted(self.kept.items()):
            v = json.loads(raw)
            if v.get("file") == "progress.log":
                for line in v["lines"]:
                    with self.subTest(vector=name, line=line):
                        m = re.match(prog["line_pattern"], line)
                        self.assertTrue(m)
                        self.assertTrue(any(m.group(2) == t or m.group(2).startswith(t + ": ") for t in texts), line)


class Lines(unittest.TestCase):
    def test_patterns_compile(self):
        for fam, f in contract("lines.json")["families"].items():
            for l in f.get("lines", []):
                with self.subTest(family=fam, line=l["id"]):
                    r = re.compile(l["pattern"])
                    self.assertEqual(r.groups, len(l.get("groups", [])))

    def test_the_gate_ok_line_reads_every_due_form(self):
        # gate_version prints bk_due's date when the site sets browser_key_days, never when it does not, and - when
        # no line of ours is there; the vectors only show never, so the other two are written out here
        ok = [l for l in contract("lines.json")["families"]["gate"]["lines"] if l["id"] == "ok"][0]
        for due in ("2026-10-31", "never", "-"):
            with self.subTest(due=due):
                m = re.match(ok["pattern"], "HPCW-GATE ok 17 %s st1234 claude=yes" % due)
                self.assertEqual(m.group(2) if m else None, due)
        self.assertIsNone(re.match(ok["pattern"], "HPCW-GATE ok 17 due st1234 claude=yes"))

    def test_every_failure_code_connect_prints_is_listed_with_its_exit(self):
        with open(os.path.join(G.ROOT, "bin", "hpcworker"), encoding="utf-8") as fh:
            code = fh.read()
        printed = set(re.findall(r"step_fail ([a-z-]+) .*? ([0-9])\b", code)) | set(re.findall(r"connect_usage\(\) \{ step_fail (usage) \"\$1\" ([0-9])", code))
        printed.add(("other", "1"))   # the die() of CONNECT_MODE
        codes = contract("lines.json")["families"]["step"]["failure_codes"]
        self.assertEqual(sorted((c, int(e)) for c, e in printed), sorted(codes.items()))


class Rules(unittest.TestCase):
    def setUp(self):
        self.rules = contract("rules.json")

    def strip_lists(self):
        with open(os.path.join(G.ROOT, "jobs", "worker.sbatch.tpl"), encoding="utf-8") as fh:
            tpl = fh.read()
        with open(os.path.join(G.ROOT, "bin", "hpcworker"), encoding="utf-8") as fh:
            cli = fh.read()
        job = re.search(r"^CLEAN_ENV=\(env (.*?)\n\s*HOME=", tpl, re.S | re.M).group(1)
        own = re.search(r"^clean_env_args\(\) \{.*?printf '%s\\n' env (.*?) HOME=", cli, re.S | re.M).group(1)
        return [re.findall(r"-u ([A-Z_]+)", t) for t in (job, own)]

    def test_strip_list_is_the_code_s(self):
        want = self.rules["credential_variables"] + self.rules["remote_control_variables"]["names"]
        for found in self.strip_lists():
            self.assertEqual(found, want)

    def test_agent_markers_are_the_code_s(self):
        with open(os.path.join(G.ROOT, "lib", "adapters", "common.sh"), encoding="utf-8") as fh:
            body = re.search(r"^hpcw_agent_env\(\) \{(.*?)^\}", fh.read(), re.S | re.M).group(1)
        self.assertEqual(re.findall(r"\$\{([A-Z_]+):-\}", body), self.rules["agent_markers"]["names"])

    def test_signin_cases_are_the_code_s_verdicts(self):
        adapters = os.path.join(G.ROOT, "lib", "adapters")
        for case in self.rules["signin_cases"]:
            with self.subTest(input=case["input"]):
                p = subprocess.run([G.BASH, "-c", "source '%s/slurm.sh' && hpcw_claude_signin" % G.posix(adapters)], input=case["input"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
                self.assertEqual((p.returncode, p.stdout.strip()), (0, case["verdict"]))


class ModuleSchema(unittest.TestCase):
    def test_the_published_schema_is_what_profile_py_prints(self):
        p = subprocess.run([G.PY, os.path.join(G.ROOT, "lib", "profile.py"), "module-schema"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr)
        with open(os.path.join(IFACE, "sites", "module-schema.json"), "rb") as fh:
            self.assertEqual(fh.read(), p.stdout, "the module rules changed: python3 framework/lib/profile.py module-schema "
                                                   "> interface/sites/module-schema.json, and raise the export's version when a module must change")


if __name__ == "__main__":
    sys.exit(unittest.main())
