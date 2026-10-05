"""Site and lab modules (BEE-199): Wayne State's cluster (sites/wayne/site.json) and the oschome lab's
deployment on it (sites/wayne/labs/oschome.json) compose into profiles/wayne.json byte for byte; each
field is set only by the layers allowed to set it; a module refuses what it may not carry; and
`show --layers` names the layer and the file behind every value."""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import profile as P  # noqa: E402

SITE = os.path.join(ROOT, "sites", "wayne", "site.json")
LAB = os.path.join(ROOT, "sites", "wayne", "labs", "oschome.json")
WAYNE = os.path.join(ROOT, "profiles", "wayne.json")
PY = os.environ.get("HPCW_PYTHON") or sys.executable


def read(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def cli(*args):
    p = subprocess.run([PY, os.path.join(ROOT, "lib", "profile.py")] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    return p.returncode, p.stdout.decode("utf-8"), p.stderr.decode("utf-8")


class Wayne(unittest.TestCase):
    def test_the_two_modules_compose_todays_profile_byte_for_byte(self):
        prof = P.compose(read(SITE), read(LAB))
        self.assertEqual(prof, read(WAYNE))
        with open(WAYNE, encoding="utf-8", newline="") as fh:
            self.assertEqual(P.profile_text(prof), fh.read())

    def test_the_command_line_composes_the_same_bytes(self):
        rc, out, err = cli("compose", SITE, LAB)
        self.assertEqual(rc, 0, err)
        with open(WAYNE, encoding="utf-8", newline="") as fh:
            self.assertEqual(out, fh.read())

    def test_every_profile_in_the_checkout_is_what_its_modules_compose(self):
        self.assertEqual(P.compose_all(check=True), [])
        rc, out, _err = cli("compose-all", "--check")
        self.assertEqual((rc, out), (0, "ok: every profile is what its modules compose\n"))

    def test_the_lab_holds_the_deployment_and_the_site_the_cluster(self):
        site, lab = read(SITE), read(LAB)
        for key in ("shared_state_dir", "shared_install", "image_store", "claude_bin", "partition_cpu_batch", "qos_batch"):
            self.assertIn(key, lab)
            self.assertNotIn(key, site)
        for key in ("submit_host", "ssh_host_key", "node_tmp", "runtime_module", "ood_base_url", "egress"):
            self.assertIn(key, site)
            self.assertNotIn(key, lab)
        # the product's own values are in neither module
        for key in ("claude_config_dir", "consent_markers", "schema_version", "ipc_dir"):
            self.assertNotIn(key, site)
            self.assertNotIn(key, lab)
        self.assertNotIn("$HOME", site.get("binds", []) + lab.get("binds", []))
        self.assertEqual((lab["site"], lab["lab"], lab["profile"]), ("wayne", "oschome", "wayne"))


class Owners(unittest.TestCase):
    def test_every_schema_field_has_its_layers_and_nothing_else_does(self):
        self.assertEqual(set(P.FIELD_LAYERS), P.known_fields())
        for key, layers in P.FIELD_LAYERS.items():
            self.assertTrue(layers and set(layers) <= set(P.LAYERS), key)
            self.assertEqual(len(set(layers)), len(layers), key)

    def test_the_product_sets_every_field_it_owns_and_only_those_it_may(self):
        product = dict(P.PRODUCT)
        owned = set(k for k, layers in P.FIELD_LAYERS.items() if layers[0] == "product")
        self.assertEqual(owned, set(k for k in product if P.FIELD_LAYERS[k][0] == "product"))
        for key in product:
            self.assertIn("product", P.FIELD_LAYERS[key], key)

    def test_the_products_values_are_beethovens_and_carry_no_site(self):
        product = dict(P.PRODUCT)
        self.assertEqual(product["claude_config_dir"], "$HOME/.beethoven/claude")
        self.assertEqual(product["binds"], ["$HOME"])
        self.assertEqual(product["login_node_rules"], {"poll_floor_seconds": 60})
        self.assertNotIn("wayne", json.dumps(product).lower())
        self.assertNotIn("/rs/", json.dumps(product))

    def test_a_lab_may_not_set_what_the_site_owns(self):
        lab = read(LAB)
        lab["ssh_host_key"] = "SHA256:" + "A" * 43
        with self.assertRaises(ValueError) as cm:
            P.compose(read(SITE), lab)
        self.assertIn("ssh_host_key is set by the site module, not by a lab module", str(cm.exception))

    def test_a_site_may_not_set_what_the_lab_owns(self):
        site = read(SITE)
        site["shared_state_dir"] = "/somewhere/$USER/hpcworker"
        with self.assertRaises(ValueError) as cm:
            P.compose(site, read(LAB))
        self.assertIn("shared_state_dir is set by the lab module, not by a site module", str(cm.exception))

    def test_no_module_moves_the_students_sign_in(self):
        for which in ("site", "lab"):
            site, lab = read(SITE), read(LAB)
            (site if which == "site" else lab)["claude_config_dir"] = "$HOME/.claude"
            with self.assertRaises(ValueError) as cm:
                P.compose(site, lab)
            self.assertIn("claude_config_dir is the product's own value; no module sets it", str(cm.exception))
            (site if which == "site" else lab).pop("claude_config_dir")
            (site if which == "site" else lab)["consent_markers"] = []
            with self.assertRaises(ValueError):
                P.compose(site, lab)

    def test_a_field_the_product_shares_names_the_module_that_may_set_it(self):
        for which, key, value, words in (
                ("site", "login_abandon_s", 600, "login_abandon_s is set by the lab module, not by a site module"),
                ("site", "worker_defaults", {"hours": 4}, "worker_defaults is set by the lab module, not by a site module"),
                ("lab", "ipc_dir", "/dev/shm", "ipc_dir is set by the site module, not by a lab module"),
                ("lab", "login_node_rules", {"max_processes": 10}, "login_node_rules is set by the site module, not by a lab module")):
            site, lab = read(SITE), read(LAB)
            (site if which == "site" else lab)[key] = value
            with self.assertRaises(ValueError) as cm:
                P.compose(site, lab)
            self.assertIn(words, str(cm.exception))

    def test_the_login_nodes_process_cap_is_the_sites_to_state(self):
        site = read(SITE)
        del site["login_node_rules"]
        with self.assertRaises(ValueError) as cm:
            P.compose(site, read(LAB))
        self.assertIn("login_node_rules.max_processes must be an integer", str(cm.exception))


class Modules(unittest.TestCase):
    def refused(self, site, lab, words):
        with self.assertRaises(ValueError) as cm:
            P.compose(site, lab, "site.json", "lab.json")
        self.assertIn(words, str(cm.exception))

    def test_an_unknown_key_is_a_typo(self):
        site = read(SITE)
        site["submit_hots"] = "warrior"
        self.refused(site, read(LAB), "site.json: submit_hots is not a field of this version's profile")

    def test_a_wrong_type_is_refused(self):
        lab = read(LAB)
        lab["binds"] = "/rs/rs_grp_oschome/$USER"
        self.refused(read(SITE), lab, "lab.json: field binds: expected list")

    def test_a_key_inside_an_object_field_is_checked_too(self):
        """a misspelt key there would sit beside the product's value and leave it in force"""
        site = read(SITE)
        site["login_node_rules"] = {"max_proceses": 10}
        self.refused(site, read(LAB), "site.json: login_node_rules.max_proceses is not a key of login_node_rules "
                                      "(it has max_processes, poll_floor_seconds)")
        lab = read(LAB)
        lab["worker_defaults"] = {"hour": 12}
        self.refused(read(SITE), lab, "lab.json: worker_defaults.hour is not a key of worker_defaults")
        lab["worker_defaults"] = {"hours": "12"}
        self.refused(read(SITE), lab, "lab.json: field worker_defaults.hours: expected int, got '12'")
        lab = read(LAB)
        lab["image_store"] = {"type": "squashfs", "path": "/x"}
        self.refused(read(SITE), lab, "lab.json: field image_store.type: expected sandbox/sif, got 'squashfs'")
        # below egress.measured the keys are the site's own (host names)
        site = read(SITE)
        site["egress"]["measured"]["example.org"] = 200
        P.compose(site, read(LAB))

    def test_what_a_module_says_about_itself(self):
        site, lab = read(SITE), read(LAB)
        site["kind"] = "lab"
        self.refused(site, lab, "kind must be 'site' in a site module")
        lab["kind"] = "site"
        self.refused(read(SITE), lab, "lab.json: kind must be 'lab' in a lab module")
        for mv in (0, "1", True, None):
            lab = read(LAB)
            lab["module_version"] = mv
            self.refused(read(SITE), lab, "module_version must be a whole number from 1")
        for key, bad in (("lab", "OSC Home"), ("profile", ""), ("site", "../wayne"), ("profile", "wayne\n")):
            lab = read(LAB)
            lab[key] = bad
            self.refused(read(SITE), lab, "%s must be lower-case letters, digits and dashes" % key)

    def test_a_lab_belongs_to_its_site(self):
        lab = read(LAB)
        lab["site"] = "elsewhere"
        self.refused(read(SITE), lab, "lab.json: belongs to site 'elsewhere', not 'wayne'")

    def test_the_composed_profile_must_be_whole_and_valid(self):
        lab = read(LAB)
        del lab["shared_state_dir"]
        self.refused(read(SITE), lab, "missing required field: shared_state_dir")
        site = read(SITE)
        site["login_node_rules"] = {"poll_floor_seconds": 30}
        self.refused(site, read(LAB), "login_node_rules.poll_floor_seconds must be at least 60")

    def test_nothing_a_module_says_about_itself_reaches_the_profile(self):
        prof = P.compose(read(SITE), read(LAB))
        for key in ("kind", "module_version", "lab", "profile"):
            self.assertNotIn(key, prof)
        self.assertEqual(P.unknown_fields(prof), [])


class Layers(unittest.TestCase):
    def test_binds_add_up_product_then_site_then_lab(self):
        site = read(SITE)
        site["binds"] = ["/scratch/$USER", "$HOME"]
        lab = read(LAB)
        lab["binds"] = ["/rs/rs_grp_oschome/$USER", "/scratch/$USER"]
        prof, origin = P.compose_layers(site, lab, "s", "l")
        self.assertEqual(prof["binds"], ["$HOME", "/scratch/$USER", "/rs/rs_grp_oschome/$USER"])
        self.assertEqual([origin.get(("binds", i), origin.get(("binds",)))[0] for i in range(3)], ["product", "site", "lab"])

    def test_objects_merge_and_scalars_and_other_lists_replace(self):
        site = read(SITE)
        site["session_title"] = "The cluster"
        lab = read(LAB)
        lab["worker_defaults"] = {"hours": 12}
        lab["session_title"] = "Our lab workers"
        site["partitions_gpu"] = ["g1", "g2"]
        prof = P.compose(site, lab)
        self.assertEqual(prof["worker_defaults"], {"cpus": 2, "mem": "8G", "hours": 12, "permission_mode": "default", "capacity": 4})
        self.assertEqual(prof["session_title"], "Our lab workers")
        self.assertEqual(prof["partitions_gpu"], ["g1", "g2"])
        self.assertEqual(prof["login_node_rules"], {"max_processes": 20, "poll_floor_seconds": 60})

    def test_a_site_may_raise_the_poll_floor(self):
        site = read(SITE)
        site["login_node_rules"] = {"poll_floor_seconds": 120, "max_processes": 20}
        prof, origin = P.compose_layers(site, read(LAB), "s", "l")
        # the schema's order inside the object, whichever order the layers wrote it in
        self.assertEqual(list(prof["login_node_rules"].items()), [("max_processes", 20), ("poll_floor_seconds", 120)])
        self.assertEqual(origin[("login_node_rules", "poll_floor_seconds")], ("site", "s"))
        self.assertEqual(origin[("login_node_rules", "max_processes")], ("site", "s"))
        site["login_node_rules"] = {"max_processes": 20}
        _prof, origin = P.compose_layers(site, read(LAB), "s", "l")
        self.assertEqual(origin[("login_node_rules", "poll_floor_seconds")], ("product", "lib/profile.py"))

    def test_a_value_laid_over_another_takes_its_record_whole(self):
        prof, origin = {"a": 1, "b": {"c": 1, "d": 2}}, {("a",): ("product", "p"), ("b", "c"): ("product", "p"), ("b", "d"): ("product", "p")}
        P._lay(prof, origin, "a", {"x": 2, "y": 3}, ("lab", "l"))
        P._lay(prof, origin, "b", {"c": 5}, ("site", "s"))
        self.assertEqual(prof, {"a": {"x": 2, "y": 3}, "b": {"c": 5, "d": 2}})
        self.assertEqual(origin, {("a", "x"): ("lab", "l"), ("a", "y"): ("lab", "l"),
                                  ("b", "c"): ("site", "s"), ("b", "d"): ("product", "p")})

    def test_composing_leaves_the_modules_as_they_were(self):
        site, lab = read(SITE), read(LAB)
        lab["worker_defaults"] = {"hours": 12}
        before = (copy.deepcopy(site), copy.deepcopy(lab), copy.deepcopy(P.PRODUCT))
        prof = P.compose(site, lab)
        # the profile holds copies: changing it changes no module and not the product's values
        prof["binds"].append("/x")
        prof["worker_defaults"]["hours"] = 99
        prof["image_store"]["path"] = "/x"
        prof["egress"]["measured"]["x"] = 1
        prof["partitions_gpu"].append("x")
        self.assertEqual((site, lab, P.PRODUCT), before)

    def test_show_layers_names_the_layer_and_the_file_of_every_value(self):
        rc, out, err = cli("show", "--layers", "wayne")
        self.assertEqual(rc, 0, err)
        rows = dict((line.split()[0], line.split()[1:3]) for line in out.splitlines())
        self.assertEqual(rows["ssh_host_key"], ["site", "sites/wayne/site.json"])
        self.assertEqual(rows["shared_state_dir"], ["lab", "sites/wayne/labs/oschome.json"])
        self.assertEqual(rows["claude_config_dir"], ["product", "lib/profile.py"])
        self.assertEqual(rows["binds.0"], ["product", "lib/profile.py"])
        self.assertEqual(rows["binds.1"], ["lab", "sites/wayne/labs/oschome.json"])
        self.assertEqual(rows["login_node_rules.max_processes"], ["site", "sites/wayne/site.json"])
        self.assertEqual(rows["login_node_rules.poll_floor_seconds"], ["product", "lib/profile.py"])
        self.assertEqual(rows["egress.proxy_env"], ["site", "sites/wayne/site.json"])
        # a key that holds a dot is quoted, so two leaves never print under one name
        self.assertEqual(rows['egress.measured."api.anthropic.com"'], ["site", "sites/wayne/site.json"])
        self.assertEqual(len(rows), len(out.splitlines()))
        # what the profile leaves to the reader's defaults is shown as such, a null default included
        self.assertEqual(rows["restricted"], ["default", "lib/profile.py"])
        self.assertIn(["browser_key_days", "default", "lib/profile.py", "null"], [line.split() for line in out.splitlines()])
        # every field of the schema has a row
        self.assertEqual(set(line.split()[0].split(".")[0] for line in out.splitlines()), P.known_fields())
        # every leaf of the composed profile has its row, and nothing is unaccounted for
        self.assertNotIn("?", out.split())
        rc2, out2, err2 = cli("show", "--layers", SITE, LAB)
        self.assertEqual((rc2, err2), (0, ""))
        self.assertEqual(out2, out)

    def test_show_layers_reads_the_two_files_it_is_given(self):
        """outside the framework tree too, under a C locale, with a path that is not ASCII"""
        with tempfile.TemporaryDirectory() as tmp:
            folder = os.path.join(tmp, "caf\u00e9")
            os.makedirs(folder)
            site, lab = read(SITE), read(LAB)
            lab["claude_bin"] = "/elsewhere/bin/claude"
            for name, mod in (("site.json", site), ("lab.json", lab)):
                with open(os.path.join(folder, name), "w", encoding="utf-8") as fh:
                    json.dump(mod, fh)
            env = dict((k, v) for k, v in os.environ.items() if k not in ("LANG", "LC_CTYPE", "PYTHONIOENCODING", "PYTHONUTF8"))
            env["LC_ALL"] = "C"
            p = subprocess.run([PY, os.path.join(ROOT, "lib", "profile.py"), "show", "--layers",
                                os.path.join(folder, "site.json"), os.path.join(folder, "lab.json")],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=120)
            self.assertEqual(p.returncode, 0, p.stderr)
            row = [line.split() for line in p.stdout.decode("utf-8").splitlines() if line.startswith("claude_bin ")][0]
            self.assertEqual((row[1], row[3]), ("lab", '"/elsewhere/bin/claude"'))
            self.assertTrue(row[2].endswith("caf\u00e9/lab.json"), row)

    def test_show_layers_for_a_profile_no_module_composes(self):
        rc, _out, err = cli("show", "--layers", "nowhere")
        self.assertEqual(rc, 1)
        self.assertIn("no lab module", err)

    def test_show_layers_refuses_a_profile_two_labs_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            for d in ("lib", "sites", "profiles"):
                shutil.copytree(os.path.join(ROOT, d), os.path.join(tmp, d), ignore=shutil.ignore_patterns("__pycache__"))
            lab = read(LAB)
            lab.update(lab="aaa", shared_state_dir="/elsewhere/$USER/hpcworker")
            with open(os.path.join(tmp, "sites", "wayne", "labs", "aaa.json"), "w", encoding="utf-8") as fh:
                json.dump(lab, fh)
            p = subprocess.run([PY, os.path.join(tmp, "lib", "profile.py"), "show", "--layers", "wayne"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            self.assertEqual((p.returncode, p.stdout), (1, b""))
            self.assertIn("sites/wayne/labs/aaa.json, sites/wayne/labs/oschome.json all name the profile wayne",
                          p.stderr.decode("utf-8"))


class ComposeAll(unittest.TestCase):
    """compose-all over a copy of the framework's sites/ and profiles/ folders."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        shutil.copytree(os.path.join(ROOT, "sites"), os.path.join(self.root, "sites"))
        shutil.copytree(os.path.join(ROOT, "profiles"), os.path.join(self.root, "profiles"))

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def write(self, rel, obj):
        os.makedirs(os.path.dirname(self.path(rel)), exist_ok=True)
        with open(self.path(rel), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(obj if isinstance(obj, str) else json.dumps(obj, indent=1) + "\n")

    def test_a_drifted_profile_is_reported_and_then_rewritten(self):
        with open(self.path("profiles", "wayne.json"), encoding="utf-8") as fh:
            good = fh.read()
        self.write("profiles/wayne.json", good.replace('"secp"', '"other"'))
        self.assertEqual(P.compose_all(self.root, check=True),
                         ["profiles/wayne.json differs from what sites/wayne/labs/oschome.json composes (profile.py compose-all writes it)"])
        # the check only compares
        with open(self.path("profiles", "wayne.json"), encoding="utf-8", newline="") as fh:
            self.assertEqual(fh.read(), good.replace('"secp"', '"other"'))
        self.assertEqual(P.compose_all(self.root), [])
        with open(self.path("profiles", "wayne.json"), encoding="utf-8", newline="") as fh:
            self.assertEqual(fh.read(), good)

    def test_a_missing_profile_is_reported_and_then_written(self):
        os.remove(self.path("profiles", "wayne.json"))
        self.assertEqual(P.compose_all(self.root, check=True),
                         ["profiles/wayne.json is missing, what sites/wayne/labs/oschome.json composes (profile.py compose-all writes it)"])
        self.assertFalse(os.path.exists(self.path("profiles", "wayne.json")))
        self.assertEqual(P.compose_all(self.root), [])
        self.assertEqual(read(self.path("profiles", "wayne.json")), read(WAYNE))

    def test_a_profile_no_module_composes_is_named_and_kept(self):
        self.write("profiles/orphan.json", read(WAYNE))
        self.assertEqual(P.compose_all(self.root), ["profiles/orphan.json: no lab module composes it"])
        self.assertTrue(os.path.exists(self.path("profiles", "orphan.json")))

    def test_two_labs_may_not_name_one_profile(self):
        lab = read(LAB)
        lab["lab"] = "second"
        self.write("sites/wayne/labs/second.json", lab)
        problems = P.compose_all(self.root, check=True)
        self.assertEqual(problems, ["sites/wayne/labs/oschome.json and sites/wayne/labs/second.json both compose profiles/wayne.json"])

    def test_a_profile_two_labs_name_is_never_written_whichever_sorts_first(self):
        """another site's lab that names an existing profile must not replace it, host key and all"""
        with open(self.path("profiles", "wayne.json"), encoding="utf-8", newline="") as fh:
            before = fh.read()
        site = read(SITE)
        site.update(site="abc", ssh_host="login.abc.edu", ssh_host_key="SHA256:" + "B" * 43)
        self.write("sites/abc/site.json", site)
        lab = read(LAB)
        lab.update(site="abc", lab="x")
        self.write("sites/abc/labs/x.json", lab)
        lab = read(LAB)
        lab.update(lab="aaa", shared_state_dir="/elsewhere/$USER/hpcworker")
        self.write("sites/wayne/labs/aaa.json", lab)
        for check in (True, False):
            self.assertIn("sites/abc/labs/x.json and sites/wayne/labs/aaa.json and sites/wayne/labs/oschome.json "
                          "both compose profiles/wayne.json", P.compose_all(self.root, check=check))
            with open(self.path("profiles", "wayne.json"), encoding="utf-8", newline="") as fh:
                self.assertEqual(fh.read(), before)

    def test_a_second_lab_on_a_site_waits_for_accounts_that_name_their_profile(self):
        """the framework finds a deployment's profile by its site's id, so a second lab's own profile
        would be served the first lab's values: refused until BEE-208, and nothing is written"""
        lab = read(LAB)
        lab.update(lab="second", profile="wayne-second", shared_state_dir="/lab2/$USER/hpcworker", binds=["/lab2/$USER"])
        self.write("sites/wayne/labs/second.json", lab)
        self.assertEqual(P.compose_all(self.root), [
            "sites/wayne/labs/second.json: profile must be 'wayne', the site's id: the framework finds a deployment's "
            "profile by its site's id, so a site has one lab until BEE-208 (got 'wayne-second')"])
        self.assertFalse(os.path.exists(self.path("profiles", "wayne-second.json")))
        # once accounts name their profile, the same module composes a profile of its own
        self.addCleanup(setattr, P, "PROFILE_IS_SITE", P.PROFILE_IS_SITE)
        P.PROFILE_IS_SITE = False
        self.assertEqual(P.compose_all(self.root), [])
        second = read(self.path("profiles", "wayne-second.json"))
        self.assertEqual(second["site"], "wayne")
        self.assertEqual(second["binds"], ["$HOME", "/lab2/$USER"])
        self.assertEqual(second["ssh_host_key"], read(WAYNE)["ssh_host_key"])

    def test_a_module_must_sit_where_its_ids_say(self):
        self.write("sites/wayne/labs/misnamed.json", read(LAB))
        self.assertEqual(P.compose_all(self.root, check=True),
                         ["sites/wayne/labs/misnamed.json: its lab id must be 'misnamed' and its site 'wayne', as the path says"])
        site = read(SITE)
        self.write("sites/elsewhere/site.json", site)
        problems = P.compose_all(self.root, check=True)
        self.assertIn("sites/elsewhere/site.json: its site id must be 'elsewhere', the folder's name", problems)

    def test_a_module_that_is_not_json_is_named(self):
        self.write("sites/wayne/labs/oschome.json", "{ not json")
        problems = P.compose_all(self.root, check=True)
        self.assertEqual(len(problems), 1)
        self.assertIn("oschome.json: could not be read as JSON", problems[0])
        self.write("sites/wayne/labs/oschome.json", [1, 2])
        self.assertEqual(P.compose_all(self.root, check=True), ["sites/wayne/labs/oschome.json: the lab module is not a JSON object"])
        self.write("sites/wayne/site.json", [])
        self.assertEqual(P.compose_all(self.root, check=True), ["sites/wayne/site.json: the site module is not a JSON object"])

    def test_nothing_under_sites_is_passed_over_without_a_word(self):
        lab = read(LAB)
        lab.update(site="uni2", lab="lab1", profile="uni2")
        self.write("sites/uni2/labs/lab1.json", lab)
        self.write("sites/uni2/Site.json", read(SITE))
        self.assertEqual(P.compose_all(self.root, check=True), ["sites/uni2: no site.json"])
        self.assertFalse(os.path.exists(self.path("profiles", "uni2.json")))

    def test_a_site_module_with_no_lab_yet_is_checked_on_its_own(self):
        self.write("sites/abc/site.json", {"kind": "site", "module_version": 1, "site": "abc", "submit_hots": "x",
                                           "claude_config_dir": "$HOME/.claude"})
        self.assertEqual(P.compose_all(self.root, check=True),
                         ["sites/abc/site.json: submit_hots is not a field of this version's profile (hpcworker profile schema lists them)",
                          "sites/abc/site.json: claude_config_dir is the product's own value; no module sets it"])

    def test_a_root_with_no_sites_folder_is_refused_not_passed(self):
        for args in (["compose-all", "--check", "--root", self.path("nowhere")], ["compose-all", "--check", "--root", os.path.dirname(ROOT)]):
            rc, out, _err = cli(*args)
            self.assertEqual(rc, 1, args)
            self.assertIn("no sites folder here", out)
        rc, _out, err = cli("compose-all", "--root", "--check")
        self.assertEqual(rc, 1)
        self.assertIn("usage: profile.py compose-all", err)

    def test_the_profiles_folder_is_made_when_there_is_none(self):
        shutil.rmtree(self.path("profiles"))
        self.assertEqual(P.compose_all(self.root), [])
        self.assertEqual(read(self.path("profiles", "wayne.json")), read(WAYNE))

    def test_a_module_that_does_not_compose_fails_the_check(self):
        lab = read(LAB)
        lab["ssh_port"] = 2222
        self.write("sites/wayne/labs/oschome.json", lab)
        # its profile is still the one it names: no second line calls it an orphan
        self.assertEqual(P.compose_all(self.root, check=True),
                         ["sites/wayne/labs/oschome.json: ssh_port is set by the site module, not by a lab module"])
        rc, out, _err = cli("compose-all", "--check", "--root", self.root)
        self.assertEqual(rc, 1)
        self.assertIn("ERROR: sites/wayne/labs/oschome.json: ssh_port is set by the site module", out)


if __name__ == "__main__":
    unittest.main()
