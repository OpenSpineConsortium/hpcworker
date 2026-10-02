"""The workspace guide: jobs/workspace-guide.md.tpl rendered from a profile is the CLAUDE.md a new
worker workspace gets. It renders for the Wayne State profile with every value in place, stays under
60 lines of plain ASCII with LF endings, carries no credential, and adapts to a site with other
facts. Through bin/hpcworker: `worker start` writes it into a workspace that has none, never over a
file already there (edited, or left empty on purpose), and `worker guide` prints it and writes nothing."""
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
sys.path.insert(0, HERE)
import profile as P  # noqa: E402
from test_cli import CURRENT_VERSION, bash, copy_framework, msys, posix, with_cli  # noqa: E402

TPL = os.path.join(ROOT, "jobs", "workspace-guide.md.tpl")
WAYNE = os.path.join(ROOT, "profiles", "wayne.json")
ENV = {"HOME": "/wsu/home/go/go24/go2432", "USER": "go2432"}
WORKSPACE = "/rs/rs_grp_oschome/go2432/hpcworker/workspaces/worker"


class GuideBase(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in ENV}
        os.environ.update(ENV)
        with open(TPL, encoding="utf-8") as fh:
            self.tpl = fh.read()
        self.prof = P.load(WAYNE)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def rendered(self, prof=None, run="worker"):
        return P.render(self.tpl, P.guide_mapping(prof or self.prof, {"RUN": run}))


class GuideRender(GuideBase):
    def test_template_is_plain(self):
        with open(TPL, "rb") as fh:
            raw = fh.read()
        self.assertNotIn(b"\r", raw)
        raw.decode("ascii")  # plain ASCII: a login node's python 3.6 without a locale reads it too
        self.assertTrue(raw.endswith(b"\n"))

    def test_wayne_renders_whole(self):
        text = self.rendered()
        self.assertEqual(P.PLACEHOLDER.findall(text), [])
        self.assertNotIn("\r", text)
        text.encode("ascii")
        self.assertLess(len(text.splitlines()), 60, "the guide stays under 60 lines")
        self.assertTrue(text.startswith("# This workspace: read this first\n"))
        self.assertIn("hpcworker %s wrote this file" % CURRENT_VERSION, text)
        self.assertIn("never replaces it", text)

    def test_wayne_values_land(self):
        text = self.rendered()
        for want in (
            "a Slurm job on a compute node of the Wayne State University HPC grid (site `wayne`, worker `worker`)",
            "This folder is your workspace: `%s`." % WORKSPACE,
            "`sbatch -D %s job.sh`" % WORKSPACE,
            "`command -v sbatch`",
            "(for example the shell in the portal, https://ondemand.grid.wayne.edu)",
            "the login node (`warrior`)",
            "at most once every 60 seconds",
            "- Short and test jobs: partition `secp`, QoS `secondary`.",
            "- Long jobs: partition `reqp`, QoS `requeue`; a job there can be stopped and started again",
            "- GPU jobs: partitions `gmsap` or `gvohp`, in that order of preference.",
            "name that folder with `-D`",
            "`--dependency=afterany:<id>`",
            "under `/dev/shm/go2432`, not `/tmp`",
            "- `/wsu/home/go/go24/go2432`: the person's home folder; keep it for small files.",
            "- `/rs/rs_grp_oschome/go2432`: the person's folder on the lab's storage, where this workspace is",
            "- `/rs/rs_grp_oschome/shared/beethoven`: the lab's shared folder for workers",
            "Connectors",
            "patient data (PHI)",
            "FERPA",
            "IRB",
            "export-controlled",
            "the Claude sign-in under `/wsu/home/go/go24/go2432/.beethoven/claude`: never read, copy or print anything there",
            # framework 9: Slurm inside the worker (the Wayne profile's scheduler_in_worker)
            "- The cluster's own Slurm commands work in here: `sbatch`, `squeue`, `sacct`, `scancel` and `sinfo` (also in `/opt/hpcw/slurm/bin`).",
            "keeps running when this worker's job ends",
            "- If `command -v sbatch` finds nothing, this node lacked a piece when the worker started",
            "never `scancel -u` or a name pattern, and never this worker's own job (`$HPCW_JOB`)",
            "(`APPTAINER_TMPDIR`, `APPTAINER_CACHEDIR`) on the node's local disk inside that job",
            "- A job you submitted: have it write its output and results under this workspace (`#SBATCH --output` too, submitted with `-D`), follow it with `squeue -j <id>` or `sacct -j <id>` at most once every 60 seconds",
        ):
            self.assertIn(want, text)
        self.assertNotIn("this container may not carry the scheduler's commands", text)
        self.assertNotIn("--account", text, "Wayne State names no account")
        self.assertNotIn("$USER", text, "the login side expands $USER")

    def test_flag_off_is_the_text_before_version_9(self):
        # a site without scheduler_in_worker keeps the one line every version since 8 wrote, and nothing else changes
        prof = json.loads(json.dumps(self.prof))
        prof["scheduler_in_worker"] = False
        off, on = self.rendered(prof), self.rendered()
        line = ("- Check first with `command -v sbatch`: this container may not carry the scheduler's commands. If it does not, write the job script "
                "into this workspace and ask the person to submit it from a terminal on the cluster (for example the shell in the portal, https://ondemand.grid.wayne.edu).")
        self.assertIn(line + "\n", off)
        for gone in ("/opt/hpcw", "$HPCW_JOB", "APPTAINER_TMPDIR", "A job you submitted", "Slurm commands work in here"):
            self.assertNotIn(gone, off)
        self.assertIn("- Save results under this workspace and give the person the full path.\n- To put a figure", off)
        # the two texts differ only in the running-work lines and the one results line
        extra = [l for l in on.splitlines() if l not in off.splitlines()]
        missing = [l for l in off.splitlines() if l not in on.splitlines()]
        self.assertEqual(missing, [line])
        self.assertEqual(len(extra), 5, extra)

    def test_no_credential_words(self):
        for text in (self.tpl, self.rendered()):
            for word in ("sk-ant-", "setup-token", "OAUTH_TOKEN", "API_KEY", "credentials.json", "ANTHROPIC_"):
                self.assertNotIn(word, text)

    def test_another_site(self):
        prof = json.loads(json.dumps(self.prof))
        prof.update({
            "display_name": "", "scheduler": "pbs", "submit_host": "", "ood_base_url": "", "account": "lab42",
            "partition_cpu_batch": "", "qos_cpu": "", "partitions_gpu": ["gpu"], "max_walltime": "48:00:00",
            "shared_state_dir": "$HOME/hpcworker", "binds": ["$HOME", "/scratch/$USER:/scratch"], "scheduler_in_worker": False,
        })
        self.assertEqual(P.validate(prof), [])
        text = self.rendered(prof, run="w2")
        self.assertEqual(P.PLACEHOLDER.findall(text), [])
        self.assertLess(len(text.splitlines()), 60)
        self.assertIn("a PBS job on a compute node of the wayne cluster", text)
        self.assertIn("`cd /wsu/home/go/go24/go2432/hpcworker/workspaces/w2 && qsub job.sh`", text)
        self.assertIn("`command -v qsub`", text)
        self.assertIn("- Short and test jobs: queue `secp`.", text)
        self.assertIn("- GPU jobs: queue `gpu`.", text)
        self.assertIn("- Every job names the account `lab42` (`-A lab42`).", text)
        self.assertIn("`48:00:00`", text)
        self.assertIn("the login node, and", text)
        self.assertIn("on the cluster.\n", text)
        self.assertIn("- `/wsu/home/go/go24/go2432`: the person's home folder, where this workspace is.", text)
        self.assertIn("- `/scratch`: a folder the site profile shares with workers.", text)
        for gone in ("sbatch", "SBATCH", "Long jobs", "afterany", "warrior", "ondemand"):
            self.assertNotIn(gone, text)

    def test_no_binds(self):
        prof = json.loads(json.dumps(self.prof))
        prof["binds"] = []
        self.assertIn("- only this workspace: the site profile shares no other folder with workers.", self.rendered(prof))

    def test_run_name_checked(self):
        with self.assertRaises(ValueError):
            P.guide_mapping(self.prof, {"RUN": "bad name"})

    def test_cli_prints_the_same_text(self):
        env = dict(os.environ)
        p = subprocess.run([sys.executable, "-X", "utf8", os.path.join(ROOT, "lib", "profile.py"), "guide", TPL, WAYNE, "RUN=worker"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.decode("utf-8").replace("\r\n", "\n"), self.rendered())


class GuideWrite(unittest.TestCase):
    """`worker start` against a stand-in scheduler (an sbatch that prints a job id, an squeue that
    knows no job) in a scratch home: the guide is written once and never over a file already there."""

    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="hpcw_guide_")
        self.home = os.path.join(self.td, "home")
        os.makedirs(self.home)
        fake = os.path.join(self.td, "fakebin")
        os.makedirs(fake)
        for name, body in (("sbatch", "echo 40500001"), ("squeue", "exit 0")):
            with open(os.path.join(fake, name), "w", newline="\n") as fh:
                fh.write("#!/bin/bash\n%s\n" % body)
            os.chmod(os.path.join(fake, name), 0o755)
        with open(WAYNE) as fh:
            prof = json.load(fh)
        # absolute and in bash's own spelling (/c/... on a Windows checkout): Git Bash hands a native
        # python $HOME in the backslash spelling, which a job's bind list may not carry
        prof["shared_state_dir"] = msys(self.home) + "/state"
        prof["binds"] = ["/rs/rs_grp_oschome/$USER", "/rs/rs_grp_oschome/shared/beethoven"]
        self.profile = os.path.join(self.td, "profile.json")
        with open(self.profile, "w") as fh:
            json.dump(prof, fh)
        self.fake = fake
        self.workspaces = os.path.join(self.home, "state", "workspaces")

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def hpcw(self, args, code=ROOT):
        env = {"HOME": posix(self.home), "USER": "go2432", "HPCW_HOME": posix(os.path.join(self.td, "hpcw")), "HPCW_PROFILE": posix(self.profile)}
        return bash("export PATH='%s':\"$PATH\"; bash '%s/bin/hpcworker' %s" % (msys(self.fake), posix(code), args), env=env)

    def guide_file(self, name):
        return os.path.join(self.workspaces, name, "CLAUDE.md")

    def read(self, path):
        with open(path, "rb") as fh:
            return fh.read()

    def test_written_once_then_kept(self):
        rc, out, err = self.hpcw("worker start --name w1")
        self.assertEqual(rc, 0, err)
        self.assertIn("submitted as job 40500001", out)
        self.assertIn("CLAUDE.md, the guide Claude Code reads there", out)
        f = self.guide_file("w1")
        first = self.read(f)
        self.assertNotIn(b"\r", first)
        self.assertIn(("hpcworker %s wrote this file" % CURRENT_VERSION).encode(), first)
        self.assertIn(b"/state/workspaces/w1`.", first)
        # what `worker guide` prints is what was written
        rc, printed, err = self.hpcw("worker guide --name w1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(printed.replace("\r\n", "\n") + "\n", first.decode("utf-8"))
        # the person's edit survives the next start
        with open(f, "wb") as fh:
            fh.write(b"# mine\n")
        rc, out, err = self.hpcw("worker start --name w1")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("CLAUDE.md, the guide", out)
        self.assertEqual(self.read(f), b"# mine\n")

    def test_empty_file_means_none_wanted(self):
        ws = os.path.join(self.workspaces, "w2")
        os.makedirs(ws)
        open(os.path.join(ws, "CLAUDE.md"), "w").close()
        rc, out, err = self.hpcw("worker start --name w2")
        self.assertEqual(rc, 0, err)
        self.assertIn("submitted as job", out)
        self.assertEqual(self.read(self.guide_file("w2")), b"")

    def test_existing_workspace_without_one_gets_it(self):
        ws = os.path.join(self.workspaces, "w3")
        os.makedirs(ws)
        with open(os.path.join(ws, "notes.txt"), "w") as fh:
            fh.write("kept\n")
        rc, out, err = self.hpcw("worker start --name w3")
        self.assertEqual(rc, 0, err)
        self.assertTrue(os.path.exists(self.guide_file("w3")))
        with open(os.path.join(ws, "notes.txt")) as fh:
            self.assertEqual(fh.read(), "kept\n")

    def test_guide_command_writes_nothing(self):
        rc, out, err = self.hpcw("worker guide --name w4")
        self.assertEqual(rc, 0, err)
        self.assertIn("# This workspace: read this first", out)
        self.assertFalse(os.path.exists(self.guide_file("w4")))

    def test_link_already_there_is_kept(self):
        ws = os.path.join(self.workspaces, "w5")
        os.makedirs(ws)
        try:
            os.symlink("elsewhere.md", os.path.join(ws, "CLAUDE.md"))  # dangling on purpose
        except (OSError, NotImplementedError):
            self.skipTest("no symlinks here")
        rc, out, err = self.hpcw("worker start --name w5")
        self.assertEqual(rc, 0, err)
        self.assertTrue(os.path.islink(self.guide_file("w5")))
        self.assertFalse(os.path.exists(os.path.join(ws, "elsewhere.md")), "the write never follows a link")

    def test_file_appearing_during_the_render_is_kept(self):
        # another start (or the person) writes CLAUDE.md after the check and before the write: the
        # noclobber write refuses the name, and theirs stays
        ws = os.path.join(self.td, "ws")
        os.makedirs(ws)
        # (framework 11: the guide is filled by hpcw_guide, lib/profile_sh.sh, which this stands in for)
        body = "hpcw_guide() { printf 'theirs\\n' > '%s/CLAUDE.md'; printf 'ours\\n'; }; write_workspace_guide '%s' w7" % (posix(ws), posix(ws))
        rc, out, err = bash(with_cli(body, os.path.join(self.td, "hpcw")))
        self.assertEqual((rc, out), (0, "kept"), err)
        self.assertEqual(self.read(os.path.join(ws, "CLAUDE.md")), b"theirs\n")

    def test_copy_without_template_still_starts(self):
        code = os.path.join(self.td, "code")
        copy_framework(code)
        os.remove(os.path.join(code, "jobs", "workspace-guide.md.tpl"))
        rc, out, err = self.hpcw("worker start --name w6", code=code)
        self.assertEqual(rc, 0, err)
        self.assertIn("submitted as job 40500001", out)
        self.assertIn("note: no workspace guide written (no template at", out)
        self.assertFalse(os.path.exists(self.guide_file("w6")))


if __name__ == "__main__":
    unittest.main()
