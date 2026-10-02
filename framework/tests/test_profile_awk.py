"""lib/profile.awk and lib/profile_sh.sh against lib/profile.py (framework 11): the login node reads the site
profile, fills the job file and writes the workspace guide without python3, and must give python's
answers. Each test runs the same profile through both: the P_ lines `profile.py shellenv` printed, the
verdict and the words of `profile.py validate`, the job file `profile.py render` wrote and the workspace
guide `profile.py guide` wrote, byte for byte, for Wayne State's profile and for profiles bent to reach
every branch (escapes, other schedulers, a proxy, binds, a profile from an older account)."""
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import fakegrid as G

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import profile as P  # noqa: E402

WAYNE = os.path.join(ROOT, "profiles", "wayne.json")
TPL = os.path.join(ROOT, "jobs", "worker.sbatch.tpl")
GUIDE = os.path.join(ROOT, "jobs", "workspace-guide.md.tpl")
ENV = {"HOME": "/wsu/home/go/go24/go2432", "USER": "go2432"}
TOOL = G.posix(os.path.join(ROOT, "bin", "hpcworker"))


def wayne():
    with open(WAYNE, encoding="utf-8") as fh:
        return json.load(fh)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.n = 0
        self.saved = {k: os.environ.get(k) for k in ENV}
        os.environ.update(ENV)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def write(self, prof):
        """a profile file: an object as JSON, or a string written as it is"""
        self.n += 1
        p = os.path.join(self.tmp.name, "p%d.json" % self.n)
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(prof if isinstance(prof, str) else json.dumps(prof, indent=1, ensure_ascii=False))
        return p

    def sh(self, body, path=None):
        """BODY with the checkout's hpcworker sourced -> (rc, stdout, stderr), stdout's bytes as they came (a CR stays a CR)"""
        env = dict(os.environ)
        env.update(ENV, HPCW_PYTHON=G.PY, MSYS_NO_PATHCONV="1", MSYS2_ARG_CONV_EXCL="*")
        env["HPCW_HOME"] = G.posix(os.path.join(self.tmp.name, "no-such-home"))   # no profile.env is kept
        script = "source '%s' && %s" % (TOOL, body)
        if path:
            script = "source '%s' && PROFILE='%s' && %s" % (TOOL, G.posix(path), body)
        p = subprocess.run([G.BASH, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL, env=env, timeout=300)
        return p.returncode, p.stdout.decode("utf-8"), p.stderr.decode("utf-8", "replace")

    def awk(self, mode, path, key=""):
        return self.sh("hpcw_prof_awk %s '%s' '%s'" % (mode, G.posix(path), key))

    def py_env(self, path):
        return P.shellenv(P.load(path))


class Schema(unittest.TestCase):
    def test_the_awk_schema_is_profile_py_schema(self):
        with open(os.path.join(ROOT, "lib", "profile.awk"), encoding="utf-8") as fh:
            text = fh.read()
        rows = re.findall(r'^  sadd\("([a-z0-9_]+)", "([^"]+)", ([01]), "((?:[^"\\]|\\.)*)"\)$', text, re.M)

        def ty(t):
            if isinstance(t, tuple):
                return "enum:" + ",".join(t)
            return t if isinstance(t, str) else t.__name__
        want = [(k, ty(t), "1" if r else "0", "" if d is None else json.dumps(d, separators=(",", ":")).replace('"', '\\"'))
                for k, t, r, d, _ in P.SCHEMA]
        self.assertEqual(rows, want)
        m = re.search(r'NFS = split\("([a-z0-9_ ]+)", FSK, " "\)', text)
        self.assertEqual(m.group(1).split(" "), list(P.FIELDS_FROM_SITE))


class ShellEnv(Base):
    def same(self, prof):
        path = self.write(prof)
        rc, out, err = self.awk("env", path)
        self.assertEqual(rc, 0, err)
        mine = out[:out.index("HPCW_PV_errors=")]
        self.assertEqual(mine, self.py_env(path))
        return out

    def test_wayne(self):
        out = self.same(wayne())
        self.assertIn("HPCW_PV_errors=''\n", out)
        self.assertIn("HPCW_M_STATE_DIR=/rs/rs_grp_oschome/go2432/hpcworker\n", out)

    def test_an_older_account_takes_the_site_fields(self):
        p = wayne()
        for k in P.FIELDS_FROM_SITE:
            p.pop(k, None)
        out = self.same(p)
        self.assertIn("P_ssh_host=grid.wayne.edu\n", out)
        self.assertIn("P_session_title='Wayne State grid'\n", out)

    def test_a_site_that_is_not_this_one_supplies_nothing(self):
        p = wayne()
        p["site"] = "nosuch"
        for k in P.FIELDS_FROM_SITE:
            p.pop(k, None)
        self.same(p)

    def test_escapes_unicode_and_quotes(self):
        p = wayne()
        p["display_name"] = "Universit\u00e9 \"Q\" \\ it's\ttabbed\nand two lines \U0001F600 \u20ac"
        p["notes"] = "${HOME}/a $HOMEX $USER_x ${USER} $HOME"
        p["account"] = "a b'c\"d"
        p["partitions_gpu"] = ["g1", "", "g'3", "$USER-gpu"]
        self.same(p)

    def test_odd_values_no_key_hpcworker_reads(self):
        p = wayne()
        p["egress"]["measured"] = {"n": 1.5, "m": 2.50, "e": 1e3, "z": -0.0, "neg": -7, "b": True, "x": None, "l": [1, "a", False]}
        p["worker_defaults"] = {"cpus": 4, "mem": "16G", "hours": 12, "permission_mode": "plan", "capacity": 2, "x": [1, 2]}
        p["login_node_rules"]["extra"] = {"deep": "v"}
        p["unknown_one"] = {"a": 1}
        p["restricted_workspaces"] = ["*", "lab"]
        self.same(p)

    def test_raw_text_escapes_and_a_repeated_key(self):
        text = json.dumps(wayne(), indent=1)
        text = text.replace('"site": "wayne"', '"site": "wa\\u0079ne", "submit_host": "first"', 1)
        text = text.replace('"display_name": "Wayne State University HPC grid"', '"display_name": "W\\u00e9\\/\\b\\f\\r \\ud83d\\ude00"', 1)
        self.same(text)

    def test_not_json_is_refused(self):
        for bad in ("", "{", "{\"a\": 1,}", "{\"a\": 01}", "[1] 2", "{\"a\": \"x\ty\"}", "{'a': 1}", "nul"):
            rc, out, err = self.awk("env", self.write(bad))
            self.assertEqual(rc, 3, (bad, out, err))
            self.assertIn("not JSON", err, bad)


class ValidateSame(Base):
    """the same verdict and the same words as profile.py validate, for every problem it names"""
    def verdict(self, prof):
        path = self.write(prof)
        rc, out, err = self.awk("check", path)
        loaded = P.load(path)
        errs = P.validate(loaded)
        if errs:
            want = "".join("ERROR: " + e + "\n" for e in errs)
        else:
            note = P.unknown_note(loaded)
            want = "ok: %s (%s, %s)%s\n" % (loaded.get("site"), loaded.get("scheduler"), loaded.get("runtime"), "; " + note if note else "")
        self.assertEqual(sorted(out.splitlines()), sorted(want.splitlines()), (prof if isinstance(prof, str) else json.dumps(prof)[:300], err))
        self.assertEqual(rc, 1 if errs else 0)
        return errs

    def bent(self, **changes):
        p = wayne()
        for k, v in changes.items():
            if v is KeyError:
                p.pop(k, None)
            else:
                p[k] = v
        return p

    def test_wayne_is_valid(self):
        self.assertEqual(self.verdict(wayne()), [])

    def test_unknown_fields_are_named(self):
        self.assertEqual(self.verdict(self.bent(old_field=1, other={"a": 1})), [])

    def test_missing_required(self):
        for k in ("site", "scheduler", "partition_cpu", "node_tmp", "shared_state_dir", "runtime", "image_store", "claude_bin", "egress", "claude_config_dir"):
            self.assertTrue(self.verdict(self.bent(**{k: KeyError})), k)

    def test_wrong_types(self):
        cases = [("site", 5), ("scheduler", "cron"), ("partitions_gpu", "gmsap"), ("tmpdir_is_node_local", "no"), ("ssh_port", "22"),
                 ("ssh_port", True), ("ssh_port", 22.0), ("fakeroot_rung", "1"), ("ood_rnode_enabled", 1), ("ssh_relay", 5),
                 ("ood_auth", "basic"), ("image_store", []), ("login_abandon_s", 1200.5), ("binds", "$HOME"), ("notes", None),
                 ("runtime", "docker"), ("worker_defaults", [1])]
        for k, v in cases:
            self.assertTrue(self.verdict(self.bent(**{k: v})), (k, v))

    def test_each_named_rule(self):
        w = wayne()
        cases = [
            dict(image_store={"type": "zip", "path": ""}),
            dict(egress={"class": "proxy", "proxy_env": [], "measured": {}}),
            dict(egress={"class": "direct", "proxy_env": {"https_proxy": "h", "FTP_PROXY": "f"}}),
            dict(egress={"class": "direct", "proxy_env": None}),
            dict(login_node_rules={"max_processes": "20", "poll_floor_seconds": 30}),
            dict(login_node_rules={"max_processes": True, "poll_floor_seconds": True}),
            dict(login_node_rules={"max_processes": 20}),
            dict(site="Wayne_State"), dict(site="-wayne"), dict(site="a" * 33),
            dict(node_tmp="$TMPDIR/x/$USER"), dict(node_tmp="/tmp/x"), dict(node_tmp="$TMPDIR/$USER", tmpdir_is_node_local=True),
            dict(shared_state_dir="rel/$USER"), dict(claude_config_dir="~/.claude"), dict(claude_config_dir="${HOME}/c"),
            dict(scheduler="pbs"), dict(runtime="podman"), dict(scheduler="lsf", runtime="singularity"),
            dict(shared_install="rel"), dict(shared_install="/a b"), dict(shared_install="/a'b"), dict(shared_install="/a\u00a0b"), dict(shared_install=""),
            dict(session_title="x" * 65), dict(session_title="\u00e9" * 64), dict(session_title="a$b"), dict(session_title="a`b"), dict(session_title="tab\there"),
            dict(vpn_help_url="http://x"), dict(grid_2fa_help_url="https://"), dict(grid_account_help_url="https://a b"), dict(vpn_help_url=""),
            dict(vpn_portal="bad host!"), dict(ssh_host="a" * 254), dict(ssh_host="grid.wayne.edu"),
            dict(ssh_port=0), dict(ssh_port=65536), dict(ssh_port=65535),
            dict(ssh_host_key="SHA256:short"), dict(ssh_host_key="MD5:" + "a" * 46), dict(ssh_host_key=w["ssh_host_key"]),
            dict(ssh_relay=""), dict(ssh_relay="ftp://x"), dict(ssh_relay="wss://relay.example.org/ssh"), dict(ssh_relay=None),
            dict(browser_key_days=0), dict(browser_key_days=3651), dict(browser_key_days=30), dict(browser_key_days=None),
            dict(login_abandon_s=100), dict(login_abandon_s=0), dict(login_abandon_s=300),
            dict(restricted_workspaces=["ok", "bad name", 3, "*"]),
            dict(binds=["", "/a b", 5, "/ok"]),
            dict(notes="paste sk-ant-abc here"), dict(egress={"class": "direct", "proxy_env": {}, "x": {"t": ["setup-token"]}}),
        ]
        for c in cases:
            self.verdict(self.bent(**c))

    def test_not_an_object(self):
        rc, out, err = self.awk("check", self.write("[1, 2]"))
        self.assertEqual(rc, 1)
        self.assertTrue(out.startswith("ERROR: "), out)


class Get(Base):
    def test_profile_py_get(self):
        p = wayne()
        p["display_name"] = "W\u00e9 \"q\""
        p["shared_state_dir"] = "$HOME/state"
        path = self.write(p)
        for key in ("site", "shared_state_dir", "display_name", "ssh_port", "vpn_required", "fakeroot_rung", "nosuch",
                    "image_store.path", "partitions_gpu.1", "partitions_gpu.9", "egress.measured.node", "ssh_relay"):
            rc, out, err = self.awk("get", path, key)
            v = P.get(P.load(path), key)
            if isinstance(v, bool):
                want = "true" if v else "false"
            elif v is None:
                want = ""
            else:
                want = P.expand(str(v))
            self.assertEqual(out, want + "\n", key)


class Render(Base):
    """the job file: hpcw_render after load_profile, against profile.py render(mapping())"""
    def pair(self, prof, **o):
        path = self.write(prof)
        o.setdefault("HPCW_CODE", "/code/v11")
        kv = " ".join("'%s=%s'" % (k, v) for k, v in o.items())
        rc, out, err = self.sh("load_profile && hpcw_render '%s' %s" % (G.posix(TPL), kv), path)
        with open(TPL, encoding="utf-8") as fh:
            want = P.render(fh.read(), P.mapping(P.load(path), o))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, want)
        return out

    def test_wayne_as_worker_start_calls_it(self):
        out = self.pair(wayne(), RUN="worker", HOURS="8", CPUS="2", MEM="8G", PERMISSION_MODE="default", CAPACITY="4",
                        HPCW_HOME="/wsu/home/go/go24/go2432/.hpcworker", CHAIN="1")
        self.assertIn("#SBATCH --partition=reqp\n#SBATCH --qos=requeue\n", out)
        self.assertIn("#SBATCH --requeue\n", out)

    def test_wayne_defaults_and_overrides(self):
        self.pair(wayne())
        self.pair(wayne(), RUN="gpu", PARTITION="secp", QOS="secondary", HOURS="1")
        self.pair(wayne(), RUN="w-2", HOURS="30", CPUS="4", MEM="16G", CHAIN="0", REQUEUE="0", HPCW_HOME="$HOME/.hw",
                  PERMISSION_MODE="plan", CAPACITY="2", TIME="1-00:00:00", HEARTBEAT_S="5", LOGIN_ABANDON_S="0")
        self.pair(wayne(), RUN="x", PARTITION="reqp", HOURS="049")
        self.pair(wayne(), RUN="y", QOS="", HOURS="0")

    def test_other_schedulers_proxies_and_binds(self):
        p = wayne()
        p.update(scheduler="pbs", scheduler_in_worker=False, account="lab1", partition_cpu_batch="", qos_cpu="")
        p["egress"] = {"class": "http-proxy-module", "proxy_module": "proxy/1 x", "proxy_env": {"https_proxy": "http://p:3128", "NO_PROXY": "a,b"},
                       "ca_bundle": "/etc/ca bundle.pem"}
        p["binds"] = ["$HOME", "/data/$USER:/data:ro", "/scratch"]
        p["consent_markers"] = []
        p["worker_defaults"] = {"cpus": 3, "mem": "4g"}
        self.pair(p)
        p.update(scheduler="lsf")
        p["egress"] = {"class": "none"}
        self.pair(p, MEM="12G", HOURS="26")
        p.update(scheduler="slurm", account="", partition_cpu_batch="long", qos_batch="")
        p["egress"] = {"class": "http-proxy-auto", "proxy_env": {"http_proxy": "x'y"}}
        self.pair(p, RUN="w")

    def test_an_older_account_with_the_site_fields(self):
        p = wayne()
        for k in P.FIELDS_FROM_SITE:
            p.pop(k, None)
        p["session_title"] = ""
        self.pair(p, RUN="other")

    def test_refusals(self):
        path = self.write(wayne())
        for kv in ("RUN=bad.name", "CHAIN=2", "PARTITION=a'b", "HOURS=x", "MEM=8G'", "noequals"):
            rc, out, err = self.sh("load_profile && hpcw_render '%s' '%s'" % (G.posix(TPL), kv), path)
            self.assertNotEqual(rc, 0, kv)
            self.assertEqual(out, "", kv)
        p = wayne()
        p["site"] = "Bad Site"
        rc, out, err = self.sh("load_profile && hpcw_render '%s' RUN=worker" % G.posix(TPL), self.write(p))
        self.assertNotEqual(rc, 0)
        self.assertIn("profile invalid:\n  site must be", err)

    def test_nothing_from_the_environment_fills_a_placeholder(self):
        path = self.write(wayne())
        tpl = os.path.join(self.tmp.name, "t.tpl")
        with open(tpl, "w", newline="\n") as fh:
            fh.write("a @RUN@ b @NOT_A_KEY@ c\n")
        rc, out, err = self.sh("export HPCW_R_NOT_A_KEY=injected; load_profile && hpcw_render '%s' RUN=w" % G.posix(tpl), path)
        self.assertNotEqual(rc, 0)
        self.assertIn("unresolved placeholder @NOT_A_KEY@", err)
        self.assertNotIn("injected", out)


class Guide(Base):
    def pair(self, prof, run="worker"):
        path = self.write(prof)
        rc, out, err = self.sh("load_profile && hpcw_guide '%s' RUN=%s" % (G.posix(GUIDE), run), path)
        with open(GUIDE, encoding="utf-8") as fh:
            want = P.render(fh.read(), P.guide_mapping(P.load(path), {"RUN": run}))
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, want)

    def test_wayne(self):
        self.pair(wayne())
        self.pair(wayne(), run="gpu")

    def test_branches(self):
        p = wayne()
        p.update(display_name="The Big Cluster", scheduler_in_worker=False, partitions_gpu=["only"], account="acct",
                 max_walltime="7-00:00:00", ood_base_url="", submit_host="", qos_batch="", partition_cpu_batch="secp", qos_cpu="")
        p["binds"] = ["$HOME", "/home/x:/home/y:ro", "/rs/rs_grp_oschome/$USER", "/elsewhere", "/rs/rs_grp_oschome/shared/beethoven/"]
        self.pair(p)
        p.update(scheduler="pbs", partitions_gpu=["a", "", "b", "c"], display_name="", runtime="podman")
        p["binds"] = []
        self.pair(p)
        p.update(scheduler="lsf", account="", partitions_gpu=[], shared_state_dir="$HOME/state")
        p["binds"] = ["$HOME", "/home/../wsu/home/go/go24/go2432/"]
        self.pair(p)
        p.update(scheduler="slurm", runtime="singularity", scheduler_in_worker=True, login_node_rules={"max_processes": 5, "poll_floor_seconds": 120})
        self.pair(p, run="w9")


if __name__ == "__main__":
    unittest.main()
