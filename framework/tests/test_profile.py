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
        # the lab folder and the sign-in folder by their names since 2026-09-30 (the old names are links to them)
        self.assertEqual(prof["claude_config_dir"], "$HOME/.beethoven/claude")
        self.assertIn("$HOME/.beethoven/claude/.beethoven-remote-consent", prof["consent_markers"])
        # the marker the grid command wrote before its rename, still honoured
        self.assertIn("$HOME/.beethoven/claude/.ashley-remote-consent", prof["consent_markers"])
        self.assertEqual(prof["shared_install"], "/rs/rs_grp_oschome/shared/beethoven/hpcworker/current")
        self.assertEqual(prof["image_store"]["path"], "/rs/rs_grp_oschome/shared/beethoven/containers/claude-node22")
        self.assertEqual(prof["claude_bin"], "/rs/rs_grp_oschome/shared/beethoven/npm-claude-node22/bin/claude")
        self.assertIn("/rs/rs_grp_oschome/shared/beethoven", prof["binds"])

    def test_shared_install_is_optional_and_absolute(self):
        prof = P.load(WAYNE)
        del prof["shared_install"]
        self.assertEqual(P.validate(prof), [])
        self.assertEqual(P.defaults()["shared_install"], "")
        for bad in ("hpcworker/current", "$HOME/hpcworker", "/rs/with space/current", "/rs/it's"):
            prof = P.load(WAYNE)
            prof["shared_install"] = bad
            self.assertTrue(any("shared_install" in e for e in P.validate(prof)), bad)
        prof = P.load(WAYNE)
        prof["shared_install"] = ""
        self.assertEqual(P.validate(prof), [])
        self.assertIn("P_shared_install=/rs/rs_grp_oschome/shared/beethoven/hpcworker/current", P.shellenv(P.load(WAYNE)))

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
        self.assertEqual(m["CLAUDE_CONFIG_DIR"], "/wsu/home/go/go24/go2432/.beethoven/claude")
        self.assertIn("/wsu/home/go/go24/go2432/.beethoven/claude/.beethoven-remote-consent", m["CONSENT_MARKERS"].split(":"))
        self.assertIn("/wsu/home/go/go24/go2432/.beethoven/claude/.ashley-remote-consent", m["CONSENT_MARKERS"].split(":"))
        self.assertIn("/wsu/home/go/go24/go2432/.hpcworker/consent", m["CONSENT_MARKERS"].split(":"))
        self.assertEqual(m["SCHEDULER"], "slurm")
        self.assertEqual(m["CHAIN"], "1")
        self.assertEqual(m["BINDS"], "-B /wsu/home/go/go24/go2432 -B /rs/rs_grp_oschome/go2432 -B /rs/rs_grp_oschome/shared/beethoven")
        self.assertIn("#SBATCH --signal=B:TERM@120", m["HEADER"])
        self.assertIn("#SBATCH --requeue", m["HEADER"])
        self.assertIn("#SBATCH --dependency=singleton", m["HEADER"])

    def test_code_root_is_separate_from_the_home(self):
        # the job sources lib/ from HPCW_CODE: what `worker start` passes (a shared copy's numbered
        # directory), else the tree profile.py itself is in; HPCW_HOME stays the student's own folder
        m = P.mapping(self.prof, {"RUN": "worker"})
        self.assertEqual(m["HPCW_CODE"], ROOT.replace(os.sep, "/"))
        self.assertEqual(m["HPCW_HOME"], "/wsu/home/go/go24/go2432/.hpcworker")
        m = P.mapping(self.prof, {"RUN": "worker", "HPCW_CODE": "/rs/rs_grp_oschome/shared/beethoven/hpcworker/v7"})
        self.assertEqual(m["HPCW_CODE"], "/rs/rs_grp_oschome/shared/beethoven/hpcworker/v7")
        self.assertIn("/wsu/home/go/go24/go2432/.hpcworker/consent", m["CONSENT_MARKERS"].split(":"))

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


class SchedulerInWorker(unittest.TestCase):
    """scheduler_in_worker (framework 9): Wayne State asks for it, every other site starts without it,
    it is refused where it cannot work, and an account's profile.json written before version 9 (a copy
    of the site profile, kept since) takes the site's value until the account sets its own."""

    def older_copy(self, td, **fields):
        """An account's profile.json as an install before version 9 left it: the Wayne profile without the field."""
        with open(WAYNE) as fh:
            prof = json.load(fh)
        prof.pop("scheduler_in_worker", None)
        prof.update(fields)
        path = os.path.join(td, "profile.json")
        with open(path, "w") as fh:
            json.dump(prof, fh)
        return path

    def test_wayne_asks_for_it_and_others_start_without(self):
        self.assertIs(P.load(WAYNE)["scheduler_in_worker"], True)
        self.assertIs(P.defaults()["scheduler_in_worker"], False)
        d = {"host": "login01", "scheduler": {"family": "slurm"}, "partitions": [{"name": "compute", "avail": "up", "default": True}],
             "runtime": {"candidates": [{"name": "apptainer", "path": "/usr/bin/apptainer"}], "modules": [], "pyxis": False}, "env": {}, "home_fs": "nfs"}
        self.assertIs(P.from_discovery(d, "example")["scheduler_in_worker"], False)
        self.assertIn("P_scheduler_in_worker=true", P.shellenv(P.load(WAYNE)))

    def test_refused_where_it_cannot_work(self):
        prof = P.load(WAYNE)
        prof["scheduler"] = "pbs"
        self.assertTrue(any("Slurm only" in e for e in P.validate(prof)))
        prof = P.load(WAYNE)
        prof["runtime"] = "podman"
        self.assertTrue(any("apptainer or singularity" in e for e in P.validate(prof)))
        prof["scheduler_in_worker"] = False
        self.assertEqual(P.validate(prof), [])
        prof = P.load(WAYNE)
        prof["runtime"] = "singularity"
        self.assertEqual(P.validate(prof), [])
        prof["scheduler_in_worker"] = "yes"
        self.assertTrue(any("scheduler_in_worker" in e for e in P.validate(prof)))

    def test_render_flag(self):
        os.environ.update(ENV)
        try:
            prof = P.load(WAYNE)
            self.assertEqual(P.mapping(prof, {"RUN": "worker"})["SCHED_IN_WORKER"], "1")
            prof["scheduler_in_worker"] = False
            self.assertEqual(P.mapping(prof, {"RUN": "worker"})["SCHED_IN_WORKER"], "0")
        finally:
            for k in ENV:
                os.environ.pop(k, None)

    def test_older_account_profile_takes_the_site_value(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertIs(P.load(self.older_copy(td))["scheduler_in_worker"], True)
            # the account's own value wins, either way
            self.assertIs(P.load(self.older_copy(td, scheduler_in_worker=False))["scheduler_in_worker"], False)
            # a site this copy has no profile for: the schema's default
            self.assertIs(P.load(self.older_copy(td, site="elsewhere"))["scheduler_in_worker"], False)
            self.assertEqual(P.site_values("elsewhere"), {})
            self.assertEqual(P.site_values("../wayne"), {})
            # framework 10 adds the extension's keys to what a site supplies; framework 11 the ssh path's
            # (browser_key_days is not set at Wayne State, so it is not supplied)
            self.assertEqual(P.site_values("wayne"), {"scheduler_in_worker": True, "session_title": "Wayne State grid", "login_abandon_s": 1200,
                                                      "ood_auth": "http-basic", "vpn_portal": "protect.wayne.edu", "vpn_app": "GlobalProtect",
                                                      "vpn_help_url": "https://services.wayne.edu/TDClient/277/Portal/KB/Article/20314/Wayne-State-VPN-and-the-Global-Protect-client",
                                                      "grid_account_help_url": "https://services.wayne.edu/TDClient/277/Portal/KB/ArticleDet?ID=20199",
                                                      "grid_2fa_help_url": "https://services.wayne.edu/TDClient/277/Portal/KB/Article/20242/How-do-I-set-up-and-use-Google-Authenticator-for-the-Grid",
                                                      "ssh_host": "grid.wayne.edu", "ssh_port": 22,
                                                      "ssh_host_key": "SHA256:kLTz1xK6anQ1denM+31kDEryQtgan2P76r9aLno+K3s", "ssh_relay": None})

    def test_framework11_keys_validated(self):
        prof = P.load(WAYNE)
        self.assertEqual(P.validate(prof), [])
        for key, bad in (("ssh_host", "grid wayne"), ("ssh_host", "a;b"), ("ssh_port", 0), ("ssh_port", 70000), ("ssh_port", "22"),
                         ("ssh_host_key", "kLTz1xK6anQ1denM+31kDEryQtgan2P76r9aLno+K3s"), ("ssh_host_key", "SHA256:short"),
                         ("ssh_relay", "http://relay.example"), ("ssh_relay", "wss://a b"), ("ssh_relay", 5),
                         ("grid_2fa_help_url", "http://services.wayne.edu/x"), ("browser_key_days", 0), ("browser_key_days", 5000),
                         ("browser_key_days", "30")):
            with self.subTest(key=key, value=bad):
                p = dict(prof)
                p[key] = bad
                self.assertTrue(any(key in e for e in P.validate(p)), (key, bad, P.validate(p)))
        for key, good in (("ssh_relay", None), ("ssh_relay", "wss://relay.example/ssh"), ("ssh_host", ""), ("ssh_host_key", ""),
                          ("browser_key_days", None), ("browser_key_days", 30)):
            p = dict(prof)
            p[key] = good
            self.assertEqual(P.validate(p), [], (key, good))
        # absent, every one of them: an older site profile is still valid
        p = dict(prof)
        for key in ("ssh_host", "ssh_port", "ssh_host_key", "ssh_relay", "grid_2fa_help_url", "browser_key_days"):
            p.pop(key, None)
        self.assertEqual(P.validate(p), [])

    def test_set_never_writes_the_site_value_into_the_account_file(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.older_copy(td)
            self.assertEqual(P.main(["profile.py", "set", path, "partition_cpu_batch", "reqp"]), 0)
            with open(path) as fh:
                self.assertNotIn("scheduler_in_worker", json.load(fh))
            self.assertIs(P.load(path)["scheduler_in_worker"], True)
            self.assertEqual(P.main(["profile.py", "set", path, "scheduler_in_worker", "false"]), 0)
            with open(path) as fh:
                self.assertIs(json.load(fh)["scheduler_in_worker"], False)
            self.assertIs(P.load(path)["scheduler_in_worker"], False)


class Framework10Keys(unittest.TestCase):
    """The keys the 11.0.0 extension and framework 10's job read (V11_CONTRACT.md 13): Wayne State's
    values, their checks, an account profile from before framework 10 taking the site's values, the
    session title in the render mapping, the 4-hour resume window, and a render that does not depend
    on the login shell's locale."""

    def test_wayne_values(self):
        prof = P.load(WAYNE)
        self.assertEqual(prof["ood_base_url"], "https://ondemand.grid.wayne.edu")
        self.assertEqual(prof["vpn_portal"], "protect.wayne.edu")
        self.assertEqual(prof["vpn_app"], "GlobalProtect")
        self.assertEqual(prof["vpn_help_url"], "https://services.wayne.edu/TDClient/277/Portal/KB/Article/20314/Wayne-State-VPN-and-the-Global-Protect-client")
        self.assertTrue(prof["grid_account_help_url"].startswith("https://services.wayne.edu/") and "20199" in prof["grid_account_help_url"])
        self.assertEqual(prof["ood_auth"], "http-basic")
        self.assertEqual(prof["session_title"], "Wayne State grid")
        self.assertEqual(prof["login_abandon_s"], 1200)
        self.assertEqual((prof["restricted"], prof["restricted_workspaces"]), (False, []))
        self.assertEqual(prof["worker_defaults"]["capacity"], 4)
        self.assertEqual(P.unknown_fields(prof), [])
        # absent keys are no error: a site without them still validates
        for k in ("vpn_portal", "vpn_app", "vpn_help_url", "grid_account_help_url", "ood_auth", "session_title", "login_abandon_s"):
            p = P.load(WAYNE)
            del p[k]
            self.assertEqual(P.validate(p), [], k)

    def test_checks(self):
        bad = [("session_title", "Wayne's grid"), ("session_title", "x" * 65), ("session_title", "a\nb"), ("session_title", "$HOME"),
               ("vpn_help_url", "http://example.edu"), ("grid_account_help_url", "javascript:alert(1)"), ("vpn_portal", "protect wayne"),
               ("login_abandon_s", 30), ("login_abandon_s", "1200"), ("ood_auth", "saml"), ("restricted", "yes"), ("restricted_workspaces", ["a b"])]
        for key, value in bad:
            p = P.load(WAYNE)
            p[key] = value
            self.assertNotEqual(P.validate(p), [], (key, value))
        for key, value in [("login_abandon_s", 0), ("login_abandon_s", 300), ("ood_auth", "cookie"), ("ood_auth", ""), ("restricted_workspaces", ["*", "gpu"]),
                           ("session_title", "Grid · lab"), ("vpn_help_url", "")]:
            p = P.load(WAYNE)
            p[key] = value
            self.assertEqual(P.validate(p), [], (key, value))

    def test_an_account_profile_from_framework_9_takes_the_site_values(self):
        with open(WAYNE) as fh:
            old = json.load(fh)
        for k in ("session_title", "login_abandon_s", "ood_auth", "vpn_portal", "vpn_app", "vpn_help_url", "grid_account_help_url"):
            old.pop(k)
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "profile.json")
            with open(path, "w") as fh:
                json.dump(old, fh)
            prof = P.load(path)
            self.assertEqual((prof["session_title"], prof["login_abandon_s"], prof["vpn_portal"]), ("Wayne State grid", 1200, "protect.wayne.edu"))
            self.assertIn("P_session_title='Wayne State grid'", P.shellenv(prof))

    def test_mapping(self):
        os.environ.update(ENV)
        try:
            prof = P.load(WAYNE)
            m = P.mapping(prof, {"RUN": "worker"})
            self.assertEqual((m["TITLE"], m["LOGIN_ABANDON_S"], m["RESUME_WINDOW_S"], m["AUTH_RETRY_S"], m["HOURS"]), ("Wayne State grid", "1200", "14400", "10", "8"))
            self.assertEqual(P.mapping(prof, {"RUN": "gpu"})["TITLE"], "Wayne State grid · gpu")
            self.assertEqual(P.mapping(prof, {"RUN": "worker", "LOGIN_ABANDON_S": "5"})["LOGIN_ABANDON_S"], "5")
            prof["session_title"] = ""
            self.assertEqual(P.mapping(prof, {"RUN": "worker"})["TITLE"], "Grid worker", "the extension's sessionTitleFor says the same")
            self.assertEqual(P.mapping(prof, {"RUN": "lab"})["TITLE"], "Grid worker · lab")
        finally:
            for k in ENV:
                os.environ.pop(k, None)

    @unittest.skipIf(os.name == "nt", "a POSIX locale")
    def test_render_whatever_the_locale(self):
        # a plain ssh leaves LANG unset; python 3.6 then writes stdout as ASCII. The title of a worker not
        # named worker carries a middle dot: render writes UTF-8 bytes all the same
        import subprocess
        env = {k: v for k, v in os.environ.items() if not k.startswith(("LC_", "LANG", "PYTHONIOENCODING", "PYTHONUTF8"))}
        # as python 3.6 on the login node would be: no C-locale coercion and no UTF-8 mode (3.7+ do both by themselves)
        env.update(ENV, LC_ALL="C", PYTHONCOERCECLOCALE="0", PYTHONUTF8="0")
        p = subprocess.run([sys.executable, os.path.join(ROOT, "lib", "profile.py"), "render", os.path.join(ROOT, "jobs", "worker.sbatch.tpl"), WAYNE, "RUN=gpu"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("TITLE='Wayne State grid · gpu'".encode("utf-8"), p.stdout)


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
