"""The site-literal lint (BEE-201): no line of the framework's code (bin/, lib/, jobs/) or of the
maintainer's tools (tools/, its tests aside) spells a site's host, path root, partition, QoS, link,
host key, runtime module, allocation account or a deployment's id. The forbidden list is built from
the modules under sites/ themselves, so a new university's values are forbidden the day its module
lands, and nothing here names one.

A whole comment line that records where something was measured may spell that site's values when it
carries the marker `measured at <site>:` (for example `# measured at wayne: ...`): the record
survives, and a new literal cannot hide behind an ordinary comment. Lines that spelled a site's value
when the lint landed are listed in site_literals_known.txt; each is fixed by BEE-202 (the framework)
or BEE-205 (the tools), and the list may only shrink: an entry whose line no longer trips the lint
fails until it is removed."""
import json
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REPO = os.path.dirname(ROOT)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import profile as P  # noqa: E402

KNOWN = os.path.join(HERE, "site_literals_known.txt")
# what the lint reads, relative to the repository: the framework's code and the maintainer's tools
SCANNED = ("framework/bin", "framework/lib", "framework/jobs", "tools")
SKIP_DIRS = {"__pycache__", ".pytest_cache", "tests"}

# fields whose value is a host name, a URL, or a path; the rest of a module is read by its key
HOST_KEYS = ("ssh_host", "vpn_portal", "submit_host", "ood_shell_host")
WORD_KEYS = ("partition_cpu", "partition_cpu_batch", "partitions_gpu", "account", "node")
QOS_KEYS = ("qos_cpu", "qos_batch")
LITERAL_KEYS = ("runtime_module", "ssh_host_key", "proxy_module")
ID_KEYS = ("site", "lab", "profile")
SKIP_KEYS = ("notes", "display_name", "session_title", "kind", "type", "class", "when", "ood_auth",
             "scheduler", "runtime", "permission_mode", "mem", "home_filesystem")
# first path components every Unix machine has: a path under one of them is site-specific only from
# its second component on (and not at all when that is a variable such as $USER)
GENERIC_ROOTS = ("tmp", "dev", "usr", "opt", "etc", "var", "home", "scratch", "proc", "sys", "bin", "sbin",
                 "lib", "lib64", "run", "srv", "mnt", "media", "root", "local", "data", "shared", "apps")
# a registrable domain is the last two labels of a host, or three under these second-level suffixes
SECOND_LEVEL = ("ac.uk", "co.uk", "edu.au", "ac.nz", "ac.jp", "edu.cn", "edu.sg", "ac.kr", "edu.hk", "ac.in", "ac.za")

WORD_BEFORE = r"(?<![\w-])"
WORD_AFTER = r"(?!\w)"


def read(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def leaves(obj, key=""):
    """(the key a value sits under, the value) for every string or list-of-strings leaf"""
    if isinstance(obj, dict):
        for k, v in obj.items():
            for item in leaves(v, k):
                yield item
    elif isinstance(obj, list):
        for v in obj:
            for item in leaves(v, key):
                yield item
    elif isinstance(obj, str) and obj:
        yield key, obj


def host_patterns(host):
    host = host.lower().strip(".")
    out = []
    if "." not in host:
        return [("host", WORD_BEFORE + re.escape(host) + WORD_AFTER)]
    out.append(("host", r"(?<![\w.-])" + re.escape(host) + r"(?![\w-])"))
    labels = host.split(".")
    n = 3 if ".".join(labels[-2:]) in SECOND_LEVEL else 2
    if len(labels) > n:
        out.append(("domain", r"(?<![\w-])" + re.escape(".".join(labels[-n:])) + r"(?![\w-])"))
    return out


# a path starts a word, a quoted string or a shell default (${X:-/rs/...}); after a word, a dot or a
# tilde it is part of a relative or home path, which names nothing of a site
PATH_BEFORE = r"(?<![\w.~])"


def path_patterns(path):
    parts = path.split("/")
    if not path.startswith("/") or len(parts) < 2 or not parts[1] or parts[1].startswith("$"):
        return []
    if parts[1] not in GENERIC_ROOTS:
        return [("path", PATH_BEFORE + "/" + re.escape(parts[1]) + r"(?![\w-])")]
    if len(parts) > 2 and parts[2] and not parts[2].startswith("$"):
        return [("path", PATH_BEFORE + "/" + re.escape(parts[1]) + "/" + re.escape(parts[2]) + r"(?![\w-])")]
    return []


def site_literals(sites_dir=None):
    """[(site id, kind, value as found in its module, compiled pattern)] for every module under
    sites/, each pattern searching a line for that value where it would name the site."""
    sites_dir = sites_dir or os.path.join(ROOT, "sites")
    found = []
    for site_path, lab_path in P.modules(os.path.dirname(sites_dir)):
        for path in (site_path, lab_path):
            mod = read(path)
            site = mod["site"]
            for key, value in leaves(mod):
                pats = []
                if key in SKIP_KEYS:
                    continue
                if re.match(r"^(https?|wss)://", value):
                    pats.append(("link", re.escape(value)))
                    pats += host_patterns(re.match(r"^[a-z]+://([^/:?#]+)", value).group(1))
                elif key in HOST_KEYS:
                    pats += host_patterns(value)
                elif key in WORD_KEYS:
                    pats.append(("word", WORD_BEFORE + re.escape(value) + WORD_AFTER))
                elif key in QOS_KEYS:
                    v = re.escape(value)
                    pats.append(("qos", r"(?:(?i:\bqos)[\s\"':=]{1,4}|(?<![\w-])-q\s+)" + v + r"(?![\w-])"))
                elif key in LITERAL_KEYS:
                    pats.append(("literal", re.escape(value)))
                elif key in ID_KEYS:
                    pats.append(("id", WORD_BEFORE + re.escape(value) + WORD_AFTER))
                elif value.startswith("/"):
                    pats += path_patterns(value)
                for kind, pat in pats:
                    found.append((site, kind, value, re.compile(pat)))
    seen, out = set(), []
    for item in found:
        if (item[0], item[3].pattern) not in seen:
            seen.add((item[0], item[3].pattern))
            out.append(item)
    return out


def code_files():
    for top in SCANNED:
        base = os.path.join(REPO, top)
        for d, dirs, names in os.walk(base):
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
            for n in sorted(names):
                if not n.endswith(".pyc"):
                    yield os.path.join(d, n)


def is_comment(line):
    s = line.strip()
    return s.startswith("#") or s.startswith("//")


def trips(line, literals):
    """the (site, kind, value) a line spells, leaving out what a marked comment records"""
    hits = []
    for site, kind, value, pat in literals:
        if pat.search(line) and not (is_comment(line) and ("measured at %s:" % site) in line):
            hits.append((site, kind, value))
    return hits


def scan(literals):
    """{(path relative to the repository, the line stripped): [(site, kind, value)]}"""
    out = {}
    for path in code_files():
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().split("\n")
        except UnicodeDecodeError:
            continue
        rel = os.path.relpath(path, REPO).replace(os.sep, "/")
        for line in lines:
            hits = trips(line, literals)
            if hits:
                out[(rel, line.strip())] = hits
    return out


def known():
    entries = set()
    with open(KNOWN, encoding="utf-8") as fh:
        for raw in fh.read().split("\n"):
            if "\t" in raw:
                rel, line = raw.split("\t", 1)
                entries.add((rel, line))
    return entries


class Literals(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.literals = site_literals()

    def test_every_module_value_that_names_a_site_is_forbidden(self):
        """each literal, written into a line of code the way code would write it, trips its own pattern"""
        self.assertTrue(self.literals)
        for site, kind, value, pat in self.literals:
            host = re.sub(r"^[a-z]+://", "", value).split("/")[0]
            lines = {"qos": ['sbatch --qos=%s job.sh' % value, "#SBATCH -q %s" % value, '"qos": "%s",' % value],
                     "path": ['cd "%s" || exit 1' % value, 'D="${HPCW_D:-%s}"' % value, "ls %s" % value],
                     "domain": ['curl -s https://other.%s/' % host],
                     "host": ['ssh %s' % host, 'x="%s"' % value]}.get(kind, ['x="%s"' % value, "x=%s" % value])
            for line in lines:
                self.assertTrue(pat.search(line), "%s %s %r is not caught in: %s" % (site, kind, value, line))
                self.assertIn((site, kind, value), trips(line, self.literals), line)

    def test_each_kind_of_value_is_read_from_the_modules(self):
        kinds = set(k for _s, k, _v, _p in self.literals)
        for kind in ("host", "domain", "path", "word", "qos", "literal", "id", "link"):
            self.assertIn(kind, kinds)
        for site_path, lab_path in P.modules():
            site, lab = read(site_path), read(lab_path)
            values = set(v for s, _k, v, _p in self.literals if s == site["site"])
            for key in ("partition_cpu", "ssh_host", "ssh_host_key", "runtime_module", "submit_host", "ood_base_url"):
                if site.get(key):
                    self.assertIn(site[key], values, key)
            for key in ("partition_cpu_batch", "qos_batch", "shared_state_dir", "lab", "profile"):
                if lab.get(key):
                    self.assertIn(lab[key], values, key)

    def test_neutral_lines_pass(self):
        for line in ('sbatch --partition="$P_partition_cpu" --qos="$P_qos_cpu" job.sh',
                     'scontrol requeue "$job"',
                     '#SBATCH --requeue',
                     'tmp="/tmp/$USER/hpcworker_$SLURM_JOB_ID"',
                     'module load "$P_runtime_module"',
                     'cp ~/rs/notes ./rs/x "$HOME/rs"',
                     'echo "the site profile names the login node"'):
            self.assertEqual(trips(line, self.literals), [], line)

    def test_a_marked_comment_may_record_a_measurement(self):
        site, _kind, value, _pat = next(x for x in self.literals if x[1] == "word")
        other = "another-site"
        self.assertTrue(trips("# measured on %s" % value, self.literals))
        self.assertEqual(trips("# measured at %s: %s answered in 9 ms" % (site, value), self.literals), [])
        # the marker names the site whose value the line records, and only a whole comment line carries it
        self.assertTrue(trips("# measured at %s: %s" % (other, value), self.literals))
        self.assertTrue(trips('p="%s"  # measured at %s: on the login node' % (value, site), self.literals))

    def test_no_core_line_spells_a_site_value(self):
        """a line not in site_literals_known.txt that spells a site's value fails here"""
        new = sorted("%s: %s  <- %s" % (rel, line, ", ".join("%s %s %r" % h for h in hits))
                     for (rel, line), hits in scan(self.literals).items() if (rel, line) not in known())
        self.assertEqual(new, [], "these lines spell a site's value; read it from the profile, or mark a measured "
                                  "comment with 'measured at <site>:'")

    def test_the_known_list_only_shrinks(self):
        flagged = set(scan(self.literals))
        stale = sorted("%s\t%s" % k for k in known() if k not in flagged)
        self.assertEqual(stale, [], "these lines no longer spell a site's value: remove them from site_literals_known.txt")

    def test_the_lines_the_inventory_found_are_on_the_list(self):
        """the lines BEE-201 named when it was filed (fixed by BEE-202 and BEE-205): found by their path
        and a fragment that names no site, so the list cannot lose them by accident"""
        entries = known()
        for rel, fragment in (("framework/jobs/probe.sbatch", 'case "$TMPDIR_DEV" in'),
                              ("framework/bin/hpcworker", "no profile at $PROFILE"),
                              ("tools/grid_ci.sbatch", "#SBATCH --partition="),
                              ("tools/grid_ci.sbatch", "#SBATCH --qos="),
                              ("tools/grid_ci.sh", "CIROOT="),
                              ("tools/deploy_shared.sh", "site="),
                              ("tools/grid_access.sh", "site="),
                              ("tools/grid_access_task.ps1", "$Site = ")):
            self.assertTrue(any(r == rel and fragment in line for r, line in entries), (rel, fragment))


if __name__ == "__main__":
    unittest.main()
