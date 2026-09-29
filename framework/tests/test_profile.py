"""Unit tests for lib/profile.py: schema validation, expansion, the render mapping."""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import profile as P  # noqa: E402

WAYNE = os.path.join(ROOT, "profiles", "wayne.json")
ENV = {"HOME": "/wsu/home/go/go24/go2432", "USER": "go2432"}


class Expand(unittest.TestCase):
    def test_home_and_user_only(self):
        self.assertEqual(P.expand("$HOME/.hpcworker", ENV), "/wsu/home/go/go24/go2432/.hpcworker")
        self.assertEqual(P.expand("/rs/rs_grp_oschome/$USER/hpcworker", ENV), "/rs/rs_grp_oschome/go2432/hpcworker")
        self.assertEqual(P.expand("${USER}x", ENV), "go2432x")

    def test_job_vars_left_for_the_job(self):
        self.assertEqual(P.expand("/tmp/$USER/hpcworker_$SLURM_JOB_ID", ENV), "/tmp/go2432/hpcworker_$SLURM_JOB_ID")
        self.assertEqual(P.expand("$USERNAME", ENV), "$USERNAME")  # not a prefix match

    def test_non_strings_pass_through(self):
        self.assertEqual(P.expand(5, ENV), 5)
        self.assertIsNone(P.expand(None, ENV))


class Validate(unittest.TestCase):
    def test_wayne_profile_is_valid(self):
        prof = P.load(WAYNE)
        self.assertEqual(P.validate(prof), [])
        self.assertEqual(prof["site"], "wayne")
        self.assertEqual(prof["partition_cpu"], "secp")
        self.assertEqual(prof["qos_cpu"], "secondary")
        self.assertEqual(prof["partition_cpu_batch"], "reqp")
        self.assertEqual(prof["qos_batch"], "requeue")
        self.assertEqual(prof["partitions_gpu"], ["gmsap", "gvohp"])
        self.assertEqual(prof["node_tmp"], "/tmp/$USER/hpcworker_$SLURM_JOB_ID")
        self.assertFalse(prof["tmpdir_is_node_local"])
        self.assertEqual(prof["egress"]["class"], "direct")
        self.assertTrue(prof["vpn_required"])
        self.assertEqual(prof["login_node_rules"], {"max_processes": 20, "poll_floor_seconds": 60})
        self.assertEqual(prof["home_filesystem"], "panfs")
        self.assertEqual(prof["claude_config_dir"], "$HOME/.ashley/claude")
        self.assertIn("$HOME/.ashley/claude/.ashley-remote-consent", prof["consent_markers"])

    def test_consent_flags_read_two_booleans_only(self):
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, ".claude.json"), "w") as fh:
                json.dump({"remoteDialogSeen": True, "projects": {"/ws": {"hasTrustDialogAccepted": True}, "/other": {}}}, fh)
            self.assertEqual(P.consent_flags(td, "/ws"), (True, True))
            self.assertEqual(P.consent_flags(td, "/other"), (True, False))
            self.assertEqual(P.consent_flags(td), (True, False))
            with open(os.path.join(td, ".claude.json"), "w") as fh:
                fh.write("{not json")
            self.assertEqual(P.consent_flags(td, "/ws"), (False, False))
            self.assertEqual(P.consent_flags(os.path.join(td, "missing"), "/ws"), (False, False))

    def test_missing_required(self):
        prof = P.load(WAYNE)
        del prof["shared_state_dir"]
        self.assertIn("missing required field: shared_state_dir", P.validate(prof))

    def test_bad_enums(self):
        prof = P.load(WAYNE)
        prof["scheduler"] = "cobalt"
        prof["egress"]["class"] = "socks"
        prof["image_store"]["type"] = "dir"
        errs = P.validate(prof)
        self.assertTrue(any("scheduler" in e for e in errs))
        self.assertTrue(any("egress.class" in e for e in errs))
        self.assertTrue(any("image_store.type" in e for e in errs))

    def test_unknown_field_is_ignored_with_a_note_not_rejected(self):
        # a profile.json written by another release keeps working: the field is named once and left out
        prof = P.load(WAYNE)
        prof["origin_of_image"] = "x"
        self.assertEqual(P.validate(prof), [])
        self.assertEqual(P.unknown_fields(prof), ["origin_of_image"])
        self.assertIn("origin_of_image", P.unknown_note(prof))
        self.assertNotIn("P_origin_of_image", P.shellenv(prof))
        self.assertEqual(P.unknown_note(P.load(WAYNE)), "")

    def test_older_profile_with_email_domain_still_loads(self):
        # releases up to framework 2 wrote "email_domain" into profile.json; it is not a field any more
        self.assertNotIn("email_domain", [row[0] for row in P.SCHEMA])
        prof = P.load(WAYNE)
        prof["email_domain"] = "wayne.edu"
        self.assertEqual(P.validate(prof), [])
        self.assertEqual(P.unknown_fields(prof), ["email_domain"])
        self.assertNotIn("email_domain", P.shellenv(prof))
        os.environ.update(ENV)
        try:
            self.assertEqual(P.mapping(prof, {"RUN": "worker"})["SITE"], "wayne")
        finally:
            for k in ENV:
                os.environ.pop(k, None)

    def test_set_refuses_a_new_unknown_field(self):
        prof = P.load(WAYNE)
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "p.json")
            P.save(prof, path)
            self.assertEqual(P.main(["profile.py", "set", path, "partition_cpu_batc", "reqp"]), 1)
            self.assertNotIn("partition_cpu_batc", P.load(path))
            self.assertEqual(P.main(["profile.py", "set", path, "partition_cpu_batch", "reqp"]), 0)

    def test_tmpdir_trap(self):
        prof = P.load(WAYNE)
        prof["node_tmp"] = "$TMPDIR/$USER/x"
        self.assertTrue(any("tmpdir_is_node_local" in e for e in P.validate(prof)))
        prof["tmpdir_is_node_local"] = True
        self.assertEqual(P.validate(prof), [])

    def test_poll_floor(self):
        prof = P.load(WAYNE)
        prof["login_node_rules"]["poll_floor_seconds"] = 10
        self.assertTrue(any("at least 60" in e for e in P.validate(prof)))

    def test_profile_never_carries_a_credential(self):
        prof = P.load(WAYNE)
        prof["notes"] = "sk-ant-abc"
        self.assertTrue(any("credential" in e for e in P.validate(prof)))
        prof["notes"] = "CLAUDE_CODE_OAUTH_TOKEN=abc"
        self.assertTrue(any("credential" in e for e in P.validate(prof)))

    def test_proxy_env_keys(self):
        prof = P.load(WAYNE)
        prof["egress"]["proxy_env"] = {"ANTHROPIC_BASE_URL": "http://x"}
        self.assertTrue(any("proxy_env may only set" in e for e in P.validate(prof)))


class Mapping(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in ENV}
        os.environ.update(ENV)
        self.prof = P.load(WAYNE)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_defaults_batch_partition(self):
        m = P.mapping(self.prof, {"RUN": "worker"})
        self.assertEqual(m["JOB_NAME"], "hpcw_worker")
        self.assertEqual(m["PARTITION"], "reqp")
        self.assertEqual(m["QOS"], "requeue")
        self.assertEqual(m["REQUEUE"], "1")
        self.assertEqual(m["TIME"], "0-08:00:00")
        self.assertEqual(m["RUN_DIR"], "/rs/rs_grp_oschome/go2432/hpcworker/worker")
        self.assertEqual(m["WORKSPACE"], "/rs/rs_grp_oschome/go2432/hpcworker/workspaces/worker")
        self.assertEqual(m["NODE_TMP"], "/tmp/go2432/hpcworker_$SLURM_JOB_ID")
        self.assertEqual(m["CLAUDE_CONFIG_DIR"], "/wsu/home/go/go24/go2432/.ashley/claude")
        self.assertIn("/wsu/home/go/go24/go2432/.ashley/claude/.ashley-remote-consent", m["CONSENT_MARKERS"].split(":"))
        self.assertIn("/wsu/home/go/go24/go2432/.hpcworker/consent", m["CONSENT_MARKERS"].split(":"))
        self.assertEqual(m["SCHEDULER"], "slurm")
        self.assertEqual(m["CHAIN"], "1")
        self.assertEqual(m["BINDS"], "-B /wsu/home/go/go24/go2432 -B /rs/rs_grp_oschome/go2432 -B /rs/rs_grp_oschome/shared/ashley")
        self.assertIn("#SBATCH --signal=B:TERM@120", m["HEADER"])
        self.assertIn("#SBATCH --requeue", m["HEADER"])
        self.assertIn("#SBATCH --dependency=singleton", m["HEADER"])

    def test_marker_follows_hpcw_home(self):
        # the job honours the marker `hpcworker claude consent` writes, wherever HPCW_HOME points
        m = P.mapping(self.prof, {"RUN": "worker", "HPCW_HOME": "/rs/group/me/.hpcw"})
        self.assertIn("/rs/group/me/.hpcw/consent", m["CONSENT_MARKERS"].split(":"))
        self.assertNotIn("/wsu/home/go/go24/go2432/.hpcworker/consent", m["CONSENT_MARKERS"].split(":"))
        self.assertEqual(m["HPCW_HOME"], "/rs/group/me/.hpcw")

    def test_chain_flag(self):
        self.assertEqual(P.mapping(self.prof, {"RUN": "worker", "CHAIN": "0"})["CHAIN"], "0")
        with self.assertRaises(ValueError):
            P.mapping(self.prof, {"RUN": "worker", "CHAIN": "yes"})

    def test_interactive_partition_no_requeue(self):
        m = P.mapping(self.prof, {"RUN": "worker", "PARTITION": "secp", "QOS": "secondary", "HOURS": "1"})
        self.assertEqual(m["TIME"], "0-01:00:00")
        self.assertIn("#SBATCH --no-requeue", m["HEADER"])
        self.assertIn("#SBATCH --qos=secondary", m["HEADER"])

    def test_hours_to_time(self):
        self.assertEqual(P.hours_to_time(30, "slurm"), "1-06:00:00")
        self.assertEqual(P.hours_to_time(30, "pbs"), "30:00:00")
        self.assertEqual(P.hours_to_time(30, "lsf"), "30:00")

    def test_bad_run_name(self):
        with self.assertRaises(ValueError):
            P.mapping(self.prof, {"RUN": "bad name"})

    def test_pbs_and_lsf_headers_render(self):
        for sch, marker in (("pbs", "#PBS -l walltime="), ("lsf", "#BSUB -W ")):
            prof = dict(self.prof)
            prof["scheduler"] = sch
            m = P.mapping(prof, {"RUN": "worker"})
            self.assertIn(marker, m["HEADER"])

    def test_egress_exports_never_set_a_base_url(self):
        prof = dict(self.prof)
        prof["egress"] = {"class": "http-proxy-auto", "proxy_env": {"https_proxy": "http://proxy.example.edu:3128", "no_proxy": "localhost"}, "proxy_module": "", "ca_bundle": "/etc/pki/ca.pem"}
        text = P.egress_exports(prof)
        self.assertIn("export https_proxy=http://proxy.example.edu:3128 HTTPS_PROXY=http://proxy.example.edu:3128", text)
        self.assertIn("NODE_EXTRA_CA_CERTS=/etc/pki/ca.pem", text)
        self.assertNotIn("ANTHROPIC_BASE_URL", text)

    def test_shellenv_quotes_and_flattens(self):
        text = P.shellenv(self.prof)
        self.assertIn("P_partition_cpu=secp", text)
        self.assertIn("P_image_store_type=sandbox", text)
        self.assertIn("P_login_node_rules_max_processes=20", text)
        self.assertIn("P_binds=", text)
        self.assertIn("P_vpn_required=true", text)


class FromDiscovery(unittest.TestCase):
    def test_seed_is_valid(self):
        d = {"host": "login01", "scheduler": {"family": "slurm"}, "partitions": [{"name": "compute", "timelimit": "2-00:00:00", "avail": "up", "default": True}, {"name": "gpu", "avail": "up"}],
             "runtime": {"candidates": [{"name": "apptainer", "path": "/usr/bin/apptainer"}], "modules": [], "pyxis": False}, "env": {"SLURM_TMPDIR": "/local/tmp"}, "home_fs": "lustre"}
        prof = P.from_discovery(d, "example")
        self.assertEqual(P.validate(prof), [])
        self.assertEqual(prof["partition_cpu"], "compute")
        self.assertEqual(prof["partitions_gpu"], ["gpu"])
        self.assertEqual(prof["image_store"]["type"], "sif")
        self.assertEqual(prof["node_tmp_var"], "SLURM_TMPDIR")


class SetAndSave(unittest.TestCase):
    def test_set_roundtrip(self):
        prof = P.load(WAYNE)
        P.set_key(prof, "egress.class", "http-proxy-auto")
        P.set_key(prof, "worker_defaults.hours", 4)
        self.assertEqual(prof["egress"]["class"], "http-proxy-auto")
        self.assertEqual(prof["worker_defaults"]["hours"], 4)
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "p.json")
            P.save(prof, path)
            again = P.load(path)
            self.assertEqual(again["egress"]["class"], "http-proxy-auto")
            self.assertFalse(os.path.exists(path + ".part"))


if __name__ == "__main__":
    unittest.main()
