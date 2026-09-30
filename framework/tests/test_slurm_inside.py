"""Slurm inside the worker's container (framework 9, the profile's scheduler_in_worker).

hpcw_slurm_in_container (lib/adapters/common.sh) against a stand-in host tree (HPCW_HOST_ROOT: the
Slurm client, its library folder, the munge library and socket folder, /etc/slurm) and a stand-in
sandbox image: the bind list, the user and group lists, the wrappers, and a sentence naming what is
missing when a piece is not there. The wrappers are run with their last line pointed at `env`, to
see the environment a job submitted from inside would start from. Then the rendered worker job's own
lines (the Slurm block, the clean environment and the in_image.sh writer, lifted from the job text)
run against a stand-in runtime that prints what it was asked to do: the binds reach every container
start and the wrappers' folder is first on the container's PATH. What the tests cannot show is the
real client talking to a real controller from inside a real container; that is the grid check
(tests/grid/slurm_in_container.sbatch) and its captured output."""
import os
import re
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))
sys.path.insert(0, HERE)
import profile as P  # noqa: E402
from test_cli import bash, can_symlink, msys, posix  # noqa: E402

CMDS = ("sbatch", "squeue", "scancel", "sacct", "sinfo")
# what the stand-in getent knows: the host's slurm and munge users and the person
GETENT = r"""hpcw_getent() {
  local db="$1"; shift; local k rc=0
  for k in "$@"; do
    case "$db:$k" in
      passwd:slurm) echo 'slurm:x:202:202:Slurm:/var/lib/slurm:/sbin/nologin';;
      passwd:munge) echo 'munge:x:201:201:Munge:/var/run/munge:/sbin/nologin';;
      passwd:go2432) echo 'go2432:x:5001:5001:G:/wsu/home/go/go24/go2432:/bin/bash';;
      group:slurm) echo 'slurm:x:202:';;
      group:munge) echo 'munge:x:201:';;
      group:*) echo "$k:x:5001:";;
      *) rc=2;;
    esac
  done
  return $rc
}
"""


class SlurmBase(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="hpcw_slurm_")
        self.root = os.path.join(self.td, "host")
        self.image = os.path.join(self.td, "image")
        self.links = can_symlink(self.td)
        # scontrol is on the host but gets no wrapper (the host's needs a readline the image lacks)
        for c in CMDS + ("scontrol",):
            self.write(os.path.join(self.root, "usr", "bin", c), "#!/bin/sh\necho host %s\n" % c, 0o755)
        os.makedirs(os.path.join(self.root, "usr", "lib64", "slurm"))
        self.write(os.path.join(self.root, "usr", "lib64", "slurm", "libslurmfull.so"), "lib\n")
        self.write(os.path.join(self.root, "usr", "lib64", "libmunge.so.2.0.0"), "lib\n")
        if self.links:
            os.symlink("libmunge.so.2.0.0", os.path.join(self.root, "usr", "lib64", "libmunge.so.2"))
        else:
            self.write(os.path.join(self.root, "usr", "lib64", "libmunge.so.2"), "lib\n")
        self.write(os.path.join(self.root, "etc", "slurm", "slurm.conf"), "ClusterName=wsu\nSlurmUser=slurm\nSlurmdUser=root\n")
        os.makedirs(os.path.join(self.root, "var", "run", "munge"))
        self.write(os.path.join(self.image, "etc", "passwd"), "root:x:0:0:root:/root:/bin/bash\nnode:x:1000:1000::/home/node:/bin/bash\n")
        self.write(os.path.join(self.image, "etc", "group"), "root:x:0:\nnode:x:1000:\n")
        os.makedirs(os.path.join(self.image, "usr", "local", "bin"))
        self.dir = os.path.join(self.td, "ipc", "slurm")

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def write(self, path, text, mode=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", newline="\n") as fh:
            fh.write(text)
        if mode:
            os.chmod(path, mode)

    def read(self, *parts):
        with open(os.path.join(*parts), encoding="utf-8") as fh:
            return fh.read()

    def call(self, extra="", tmpdir="/wsu/tmp/go2432", ld="/hostlib:/wsu/el7/lib"):
        """Run the function in bash; returns rc, NOTE, BINDS (the three lines it prints)."""
        body = (GETENT + extra + "\nexport USER=go2432 HPCW_HOST_ROOT='%s'; PATH=\"/hostmarker:$PATH\"; LD_LIBRARY_PATH='%s'\n"
                "HPCW_HOST_TMPDIR='%s' hpcw_slurm_in_container '%s' '%s' sandbox; rc=$?\n"
                "printf 'RC=%%s\\nNOTE=%%s\\nBINDS=%%s\\n' \"$rc\" \"$HPCW_SLURM_NOTE\" \"$HPCW_SLURM_BINDS\"\n") % (
                    msys(self.root), ld, tmpdir, msys(self.dir), msys(self.image))
        rc, out, err = bash("source '%s/lib/adapters/common.sh' && %s" % (posix(ROOT), body))
        self.assertEqual(rc, 0, err)
        got = dict(line.split("=", 1) for line in out.splitlines() if "=" in line and line.split("=", 1)[0] in ("RC", "NOTE", "BINDS"))
        return int(got["RC"]), got.get("NOTE", ""), got.get("BINDS", "")


class BindSet(SlurmBase):
    def test_every_piece_is_bound(self):
        rc, note, binds = self.call()
        self.assertEqual(rc, 0, note)
        r, d = msys(self.root), msys(self.dir)
        lib = r + "/usr/lib64/" + ("libmunge.so.2.0.0" if self.links else "libmunge.so.2")
        want = ["-B %s/usr/bin:/opt/host/bin:ro" % r,
                "-B %s/usr/lib64/slurm:/usr/lib64/slurm:ro" % r,
                "-B %s:/usr/lib/libmunge.so.2:ro" % lib,
                "-B %s/etc/slurm:/etc/slurm:ro" % r,
                "-B %s/var/run/munge:/var/run/munge" % r,
                "-B %s/etc/passwd:/etc/passwd:ro" % d,
                "-B %s/etc/group:/etc/group:ro" % d,
                "-B %s/bin:/opt/hpcw/slurm/bin:ro" % d]
        self.assertEqual(binds, " ".join(want))
        # never all of the host's /usr/bin over the container's own, never the host's libraries as a whole
        self.assertNotIn(":/usr/bin", binds)
        self.assertNotIn("/usr/lib64:", binds)
        self.assertIn("sbatch squeue scancel sacct sinfo", note)
        self.assertIn("/opt/hpcw/slurm/bin", note)

    def test_user_and_group_lists(self):
        rc, note, _ = self.call()
        self.assertEqual(rc, 0, note)
        passwd = self.read(self.dir, "etc", "passwd").splitlines()
        self.assertEqual([l.split(":")[0] for l in passwd], ["root", "node", "slurm", "munge", "go2432"])
        group = self.read(self.dir, "etc", "group").splitlines()
        self.assertEqual([l.split(":")[0] for l in group][:4], ["root", "node", "slurm", "munge"])

    def test_a_name_the_container_has_keeps_its_entry(self):
        with open(os.path.join(self.image, "etc", "passwd"), "a", newline="\n") as fh:
            fh.write("munge:x:999:999:image's own:/nonexistent:/usr/sbin/nologin\n")
        rc, note, _ = self.call()
        self.assertEqual(rc, 0, note)
        passwd = self.read(self.dir, "etc", "passwd").splitlines()
        munge = [l for l in passwd if l.startswith("munge:")]
        self.assertEqual(munge, ["munge:x:999:999:image's own:/nonexistent:/usr/sbin/nologin"])

    def test_wrappers(self):
        rc, note, _ = self.call()
        self.assertEqual(rc, 0, note)
        for c in CMDS:
            text = self.read(self.dir, "bin", c)
            self.assertTrue(text.startswith("#!/bin/bash\n"), c)
            self.assertTrue(text.rstrip("\n").endswith('exec /opt/host/bin/%s "$@"' % c), text)
            self.assertIn("export PATH=/hostmarker:", text)
            self.assertIn("export TMPDIR=/wsu/tmp/go2432", text)
            self.assertIn("export LD_LIBRARY_PATH=/hostlib:/wsu/el7/lib", text)
            self.assertNotIn("\r", text)
            self.assertTrue(os.access(os.path.join(self.dir, "bin", c), os.X_OK), c)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "bin", "scontrol")), "scontrol gets no wrapper")
        # a host without one of the five: that wrapper is not written, the others are
        os.remove(os.path.join(self.root, "usr", "bin", "sinfo"))
        shutil.rmtree(self.dir)
        rc, note, _ = self.call()
        self.assertEqual(rc, 0, note)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "bin", "sinfo")))
        self.assertIn("(sbatch squeue scancel sacct, in", note)

    def test_a_submitted_job_starts_from_the_hosts_environment(self):
        # the sbatch wrapper with its last line pointed at `env`: what sbatch (and so the new job) would be given
        rc, note, _ = self.call()
        self.assertEqual(rc, 0, note)
        text = self.read(self.dir, "bin", "sbatch").replace('exec /opt/host/bin/sbatch "$@"', 'exec env')
        probe = os.path.join(self.td, "envprobe")
        self.write(probe, text, 0o755)
        env = {"APPTAINER_CONTAINER": "/image", "APPTAINER_NAME": "claude", "SINGULARITY_BIND": "/x", "APPTAINERENV_PREPEND_PATH": "/opt/hpcw/slurm/bin",
               "SLURM_JOB_ID": "40500077", "SLURM_CPUS_PER_TASK": "2", "SLURM_MEM_PER_NODE": "8192", "SLURM_CONF": "/etc/slurm/slurm.conf",
               "XDG_RUNTIME_DIR": "/dev/shm/go2432/xdg", "TMPDIR": "/tmp", "HPCW_JOB": "40500077", "CLAUDECODE": "1",
               # what check job 40518457 saw inside the container
               "LD_LIBRARY_PATH": "/.singularity.d/libs"}
        rc, out, err = bash("PATH=\"/containermarker:$PATH\"; bash '%s'" % posix(probe), env=env)
        self.assertEqual(rc, 0, err)
        seen = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
        for gone in ("APPTAINER_CONTAINER", "APPTAINER_NAME", "SINGULARITY_BIND", "APPTAINERENV_PREPEND_PATH", "SLURM_JOB_ID", "SLURM_CPUS_PER_TASK", "SLURM_MEM_PER_NODE", "XDG_RUNTIME_DIR"):
            self.assertNotIn(gone, seen, gone)
        self.assertEqual(seen.get("SLURM_CONF"), "/etc/slurm/slurm.conf")
        self.assertEqual(seen.get("TMPDIR"), "/wsu/tmp/go2432")
        self.assertEqual(seen.get("LD_LIBRARY_PATH"), "/hostlib:/wsu/el7/lib")
        self.assertTrue(seen.get("PATH", "").startswith("/hostmarker:"), seen.get("PATH"))
        self.assertNotIn("/containermarker", seen.get("PATH", ""))
        # the agent markers stay: under them the tool's destructive commands refuse in the new job too
        self.assertEqual(seen.get("CLAUDECODE"), "1")

    def test_no_tmpdir_or_library_path_on_the_host_means_none(self):
        rc, note, _ = self.call(tmpdir="", ld="")
        self.assertEqual(rc, 0, note)
        text = self.read(self.dir, "bin", "sbatch")
        self.assertIn("\nunset TMPDIR\n", text)
        self.assertIn("\nunset LD_LIBRARY_PATH\n", text)


class Missing(SlurmBase):
    def assertMissing(self, what):
        rc, note, binds = self.call()
        self.assertEqual(rc, 1)
        self.assertEqual(binds, "")
        self.assertTrue(note.startswith("not available: missing on "), note)
        self.assertIn(what, note)
        self.assertFalse(os.path.exists(os.path.join(self.dir, "bin")), "nothing is written when a piece is missing")

    def test_no_client(self):
        os.remove(os.path.join(self.root, "usr", "bin", "sbatch"))
        self.assertMissing("/usr/bin/sbatch")

    def test_no_munge_library(self):
        os.remove(os.path.join(self.root, "usr", "lib64", "libmunge.so.2"))
        self.assertMissing("/usr/lib64/libmunge.so.2")

    def test_no_munge_socket_folder(self):
        shutil.rmtree(os.path.join(self.root, "var", "run", "munge"))
        self.assertMissing("/var/run/munge")

    def test_no_config(self):
        shutil.rmtree(os.path.join(self.root, "etc", "slurm"))
        self.assertMissing("/etc/slurm")

    def test_no_slurm_user_on_the_host(self):
        rc, note, _ = self.call(extra="eval \"$(declare -f hpcw_getent | sed 's/passwd:slurm)/passwd:nobody-here)/')\"")
        self.assertEqual(rc, 1)
        self.assertIn("the slurm user", note)

    def test_slurm_user_named_in_the_config(self):
        # SlurmUser=root needs no extra entry; another name is looked up by that name
        self.write(os.path.join(self.root, "etc", "slurm", "slurm.conf"), "SlurmUser=root\n")
        rc, note, _ = self.call()
        self.assertEqual(rc, 0, note)
        self.write(os.path.join(self.root, "etc", "slurm", "slurm.conf"), "slurmuser = slurmadm # the daemons' account\n")
        shutil.rmtree(self.dir)
        rc, note, _ = self.call()
        self.assertEqual(rc, 1)
        self.assertIn("the slurmadm user", note)

    def test_a_space_in_the_folder_is_refused(self):
        self.dir = os.path.join(self.td, "ipc dir", "slurm")
        rc, note, binds = self.call()
        self.assertEqual((rc, binds), (1, ""))
        self.assertIn("space", note)


class RenderedJob(SlurmBase):
    """The worker job's own lines, as rendered for Wayne State, run against the stand-in host and a
    stand-in runtime that prints its arguments and the PATH it was asked to prepend."""
    ENV = {"HOME": "/wsu/home/go/go24/go2432", "USER": "go2432"}

    def setUp(self):
        super().setUp()
        self.saved = {k: os.environ.get(k) for k in self.ENV}
        os.environ.update(self.ENV)
        with open(os.path.join(ROOT, "jobs", "worker.sbatch.tpl"), encoding="utf-8") as fh:
            self.tpl = fh.read()
        self.write(os.path.join(self.td, "apptainer"), '#!/bin/bash\necho "PREPEND=${APPTAINERENV_PREPEND_PATH:-}"\nprintf "ARG %s\\n" "$@"\n', 0o755)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        super().tearDown()

    def rendered(self, prof):
        return P.render(self.tpl, P.mapping(prof, {"RUN": "worker", "HPCW_CODE": posix(ROOT)}))

    def lifted(self, text):
        sched = re.search(r"\nSCHED_PATH=\"\"\nif \[ \"\$SCHED_IN_WORKER\" = 1 \]; then\n.*?\nfi\n", text, re.S)
        clean = re.search(r"\nCLEAN_ENV=\(.*?HPCW_SITE=\"\$SITE\"\)\n", text, re.S)
        writer = re.search(r"\n\{ echo '#!/bin/bash'; echo \"# written by hpcworker job \$JOB on \$NODE: one command.*?\nchmod 700 in_image\.sh\.part && mv -f in_image\.sh\.part in_image\.sh\n", text, re.S)
        flag = re.search(r"SCHED_IN_WORKER=([01])", text)
        self.assertTrue(sched and clean and writer and flag, "the Slurm block, CLEAN_ENV or the in_image.sh writer is not in the rendered job in the expected shape")
        return flag.group(1), sched.group(0) + clean.group(0) + writer.group(0)

    def run_job_lines(self, prof, scheduler="slurm"):
        flag, lines = self.lifted(self.rendered(prof))
        rd = os.path.join(self.td, "run")
        os.makedirs(rd)
        # the stand-in getent after common.sh, which defines the real one
        head = (
            "set -u\nsource '%s/lib/adapters/common.sh'\n" + GETENT + "say() { echo \"say $*\"; }\n"
            "export USER=go2432 HPCW_HOST_ROOT='%s'\ncd '%s' || exit 9\n"
            "JOB=40500077; NODE=asx1; SITE=wayne; SCHEDULER=%s; SCHED_IN_WORKER=%s; SCHED_INSIDE=false; SCHED_NOTE='off in the site profile'\n"
            "IMAGE='%s'; IMAGE_TYPE=sandbox; BINDS='-B /wsu/home/go/go24/go2432'; IPC='%s'; ORIG_TMPDIR=/wsu/tmp/go2432\n"
            "RUNTIME=apptainer; RUNTIME_BIN='%s'; RUNTIME_MODULE=''; HPCW_NODE_TMP='%s'; HPCW_CODE='%s'; RUN_DIR='%s'; CCD=/wsu/home/go/go24/go2432/.beethoven/claude; XDG=''\n"
        ) % (posix(ROOT), msys(self.root), msys(rd), scheduler, flag, msys(self.image), msys(os.path.join(self.td, "ipc")),
             msys(os.path.join(self.td, "apptainer")), msys(os.path.join(self.td, "nt", "hpcworker_40500077")), posix(ROOT), msys(rd))
        tail = "\necho \"SCHED_INSIDE=$SCHED_INSIDE\"; echo \"SCHED_NOTE=$SCHED_NOTE\"\n\"$RUN_DIR/in_image.sh\" /usr/local/bin/claude --version\n"
        rc, out, err = bash(head + lines + tail)
        self.assertEqual(rc, 0, (out, err))
        return flag, out

    def test_wayne_binds_reach_every_container_start(self):
        prof = P.load(os.path.join(ROOT, "profiles", "wayne.json"))
        self.assertTrue(prof["scheduler_in_worker"])
        flag, out = self.run_job_lines(prof)
        self.assertEqual(flag, "1")
        self.assertIn("SCHED_INSIDE=true", out)
        self.assertIn("say scheduler inside the container: the host's Slurm client is in the container", out)
        self.assertIn("PREPEND=/opt/hpcw/slurm/bin", out)
        args = [l[4:] for l in out.splitlines() if l.startswith("ARG ")]
        self.assertEqual(args[0], "exec")
        r = msys(self.root)
        for bind in ("/wsu/home/go/go24/go2432", r + "/usr/bin:/opt/host/bin:ro", r + "/etc/slurm:/etc/slurm:ro", r + "/var/run/munge:/var/run/munge"):
            self.assertIn(bind, args)
            self.assertEqual(args[args.index(bind) - 1], "-B")
        self.assertTrue(any(a.endswith("/ipc/slurm/bin:/opt/hpcw/slurm/bin:ro") for a in args), args)
        # the image, then the clean environment, then the command, as before
        i = args.index(msys(self.image))
        self.assertEqual(args[i + 1], "env")
        self.assertEqual(args[-2:], ["/usr/local/bin/claude", "--version"])
        with open(os.path.join(self.td, "run", "in_image.sh"), encoding="utf-8") as fh:
            self.assertIn("export APPTAINERENV_PREPEND_PATH=/opt/hpcw/slurm/bin SINGULARITYENV_PREPEND_PATH=/opt/hpcw/slurm/bin", fh.read())

    def test_flag_off_changes_nothing(self):
        prof = P.load(os.path.join(ROOT, "profiles", "wayne.json"))
        prof["scheduler_in_worker"] = False
        flag, out = self.run_job_lines(prof)
        self.assertEqual(flag, "0")
        self.assertIn("SCHED_INSIDE=false", out)
        self.assertIn("SCHED_NOTE=off in the site profile", out)
        self.assertIn("PREPEND=\n", out + "\n")
        self.assertNotIn("/opt/host/bin", out)
        self.assertNotIn("say scheduler inside", out)
        self.assertFalse(os.path.exists(os.path.join(self.td, "ipc", "slurm")))
        with open(os.path.join(self.td, "run", "in_image.sh"), encoding="utf-8") as fh:
            self.assertNotIn("PREPEND_PATH", fh.read())

    def test_a_missing_piece_starts_the_worker_without_it(self):
        os.remove(os.path.join(self.root, "usr", "lib64", "libmunge.so.2"))
        prof = P.load(os.path.join(ROOT, "profiles", "wayne.json"))
        flag, out = self.run_job_lines(prof)
        self.assertIn("SCHED_INSIDE=false", out)
        self.assertIn("SCHED_NOTE=not available: missing on ", out)
        self.assertIn("/usr/lib64/libmunge.so.2", out)
        self.assertNotIn("/opt/host/bin", out)
        self.assertIn("ARG /usr/local/bin/claude", out, "the container still starts")

    def test_status_carries_the_two_fields(self):
        text = self.rendered(P.load(os.path.join(ROOT, "profiles", "wayne.json")))
        self.assertIn('"chain_note":%s,"scheduler_in_worker":%s,"scheduler_note":%s,"workspace":%s', text)
        self.assertIn('"$SCHED_INSIDE" "$(json_str "$SCHED_NOTE")" "$(json_str "$WORKSPACE")"', text)


class DiagLine(unittest.TestCase):
    """`hpcworker diag`'s hpcw.slurm-in-worker line, from the newest worker heartbeat."""

    def diag(self, flag, statuses):
        from test_cli import with_cli
        import time
        td = tempfile.mkdtemp(prefix="hpcw_diag_")
        try:
            state = os.path.join(td, "state")
            for i, (name, text) in enumerate(statuses):
                os.makedirs(os.path.join(state, name))
                p = os.path.join(state, name, "status.json")
                with open(p, "w", newline="\n") as fh:
                    fh.write(text)
                t = time.time() - 600 + i * 60
                os.utime(p, (t, t))
            rc, out, err = bash(with_cli("STATE_DIR='%s'; P_scheduler_in_worker=%s; diag_slurm_in_worker" % (msys(state), flag), os.path.join(td, "hpcw")))
            self.assertEqual(rc, 0, err)
            return out
        finally:
            shutil.rmtree(td, ignore_errors=True)

    def test_lines(self):
        on = '{"version":9,"job":"40500077","node":"asx1","state":"online","scheduler_in_worker":true,"scheduler_note":"the host\'s Slurm client is in the container (sbatch squeue scancel sacct sinfo, in /opt/hpcw/slurm/bin)"}'
        off = '{"version":9,"job":"40500078","node":"asx2","state":"online","scheduler_in_worker":false,"scheduler_note":"not available: missing on asx2: /var/run/munge"}'
        old = '{"version":8,"job":"40500079","node":"asx3","state":"stopped"}'
        out = self.diag("true", [("a", off), ("b", on)])
        self.assertTrue(out.startswith("ok    hpcw.slurm-in-worker"), out)
        self.assertIn("job 40500077 on asx1: the host's Slurm client is in the container", out)
        out = self.diag("true", [("a", on), ("b", off)])
        self.assertTrue(out.startswith("FAIL  hpcw.slurm-in-worker"), out)
        self.assertIn("went without it: not available: missing on asx2: /var/run/munge", out)
        self.assertTrue(self.diag("true", [("a", old)]).startswith("warn  hpcw.slurm-in-worker"))
        self.assertIn("no worker has reported yet", self.diag("true", []))
        self.assertTrue(self.diag("false", [("a", on)]).startswith("skip  hpcw.slurm-in-worker"))


if __name__ == "__main__":
    unittest.main()
