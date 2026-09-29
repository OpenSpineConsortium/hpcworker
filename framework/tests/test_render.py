"""The worker template renders for the Wayne State profile with no placeholder left, is valid
bash, and never carries a credential or the long-lived-token command as a value."""
import os
import re
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "lib"))
import profile as P  # noqa: E402

TPL = os.path.join(ROOT, "jobs", "worker.sbatch.tpl")
WAYNE = os.path.join(ROOT, "profiles", "wayne.json")
ENV = {"HOME": "/wsu/home/go/go24/go2432", "USER": "go2432"}


class RenderBase(unittest.TestCase):
    """setUp for the classes below: the template text and the Wayne State profile, rendered on demand."""

    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in ENV}
        os.environ.update(ENV)
        with open(TPL, encoding="utf-8") as fh:  # the template carries the "Connected ·" mark; no locale may be assumed
            self.tpl = fh.read()
        self.prof = P.load(WAYNE)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def rendered(self, **kw):
        o = {"RUN": "worker"}
        o.update(kw)
        return P.render(self.tpl, P.mapping(self.prof, o))


class Render(RenderBase):
    def test_no_placeholder_left(self):
        text = self.rendered()
        self.assertEqual(P.PLACEHOLDER.findall(text), [])

    def test_never_a_token_value(self):
        text = self.rendered()
        self.assertNotIn("setup-token", text)
        self.assertNotRegex(text, r"CLAUDE_CODE_OAUTH_TOKEN\s*=")
        self.assertNotRegex(text, r"ANTHROPIC_API_KEY\s*=")
        self.assertNotIn("sk-ant-", text)
        # the token variables appear only as things being unset
        for m in re.finditer(r"CLAUDE_CODE_OAUTH_TOKEN", text):
            self.assertEqual(text[m.start() - 3:m.start()], "-u ", text[m.start() - 20:m.end() + 5])

    def test_remote_control_needs_feature_flags(self):
        text = self.rendered()
        self.assertNotRegex(text, r"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\s*=")
        self.assertNotRegex(text, r"DISABLE_GROWTHBOOK\s*=")
        self.assertNotRegex(text, r"ANTHROPIC_BASE_URL\s*=")
        self.assertIn("DISABLE_AUTOUPDATER=1", text)
        self.assertIn('CLAUDE_CONFIG_DIR="$CCD"', text)

    def test_wayne_values_land(self):
        text = self.rendered(PARTITION="secp", QOS="secondary", HOURS="1")
        self.assertIn("#SBATCH --job-name=hpcw_worker", text)
        self.assertIn("#SBATCH --partition=secp", text)
        self.assertIn("#SBATCH --qos=secondary", text)
        self.assertIn("#SBATCH --time=0-01:00:00", text)
        self.assertIn("#SBATCH --signal=B:TERM@120", text)
        self.assertIn("HPCW_NODE_TMP_PATTERN='/tmp/go2432/hpcworker_$SLURM_JOB_ID'", text)
        self.assertIn("IMAGE='/rs/rs_grp_oschome/shared/ashley/containers/claude-node22'", text)
        self.assertIn("CLAUDE_CONFIG_DIR_VALUE='/wsu/home/go/go24/go2432/.ashley/claude'", text)
        self.assertIn("IPC_DIR='/dev/shm'", text)
        self.assertIn("remote-control", text)
        self.assertIn("--continue", text)
        self.assertIn("SCHEDULER='slurm'", text)
        self.assertIn("CHAIN=1", text)
        self.assertIn("afterany", text)
        self.assertIn("remoteDialogSeen", text)
        self.assertIn("hpcw_parse_registration", text)
        self.assertIn("hpcw_rm_own_tmp", text)
        self.assertNotIn("rm -rf", text)

    def test_code_comes_from_hpcw_code_not_the_home(self):
        # on a shared copy ~/.hpcworker has no lib/: every source line of the job goes through HPCW_CODE
        text = self.rendered(HPCW_CODE="/rs/rs_grp_oschome/shared/ashley/hpcworker/v5")
        self.assertIn("HPCW_HOME='/wsu/home/go/go24/go2432/.hpcworker'; HPCW_CODE='/rs/rs_grp_oschome/shared/ashley/hpcworker/v5';", text)
        self.assertIn('source "$HPCW_CODE/lib/adapters/common.sh"', text)
        self.assertIn('source "$HPCW_CODE/lib/adapters/$SCHEDULER.sh"', text)
        self.assertIn('echo "source $(printf %q "$HPCW_CODE/lib/adapters/common.sh")"', text)
        self.assertNotIn("$HPCW_HOME/lib", text)
        with open(os.path.join(ROOT, "jobs", "probe.sbatch"), encoding="utf-8") as fh:
            probe = fh.read()
        self.assertNotIn("$HPCW_HOME/lib", probe)
        self.assertIn('HPCW_CODE="${HPCW_CODE:-$HPCW_HOME}"', probe)

    def test_chain_off_renders(self):
        text = self.rendered(CHAIN="0")
        self.assertIn("CHAIN=0", text)

    def test_needs_hint_and_login_retries(self):
        # what the panel reads (needs, hint), the retries for a credential still being written, the
        # one-minute recheck while waiting for the sign-in, and the consent prompt's own words
        text = self.rendered()
        for s in ('"needs":%s,"hint":%s', 'hpcw_needs "$STATE" "$consent"', 'hpcw_hint "$STATE" "$needs" "$NEXT_JOB"', "LOGIN_RECHECK_S=60", "asking again in 10 s", 'if [ "$STATE" = need_login ] && [ $(( $(now_s) - LAST_AUTH )) -ge "$LOGIN_RECHECK_S" ]', "Enable Remote Control"):
            self.assertIn(s, text)
        self.assertIn("LOGIN_RECHECK_S=45", self.rendered(LOGIN_RECHECK_S="45"))
        # a stop that went through stays "stopped" when the CLI's scancel lands during the job's exit:
        # the trap stays armed and hands back to the stop path (StopPath below runs it)
        self.assertIn('if [ -e stop ] || [ -e stop.done ] || [ "$STOPPING" = 1 ]; then stop_and_leave', text)
        self.assertIn('if [ -e stop ]; then stop_and_leave "stop file"; fi', text)
        self.assertNotIn("then trap - TERM INT; rc_stop", text)

    def test_template_consent_source_accepts_the_panels_marker(self):
        # the function exactly as rendered, run on its own: a marker file of any content counts
        # (the panel writes "yes <time> <install id>"), and nothing on record reads none
        import shlex
        import shutil
        import tempfile
        text = self.rendered()
        m = re.search(r"\nconsent_source\(\) \{.*?\n\}\n", text, re.S)
        self.assertTrue(m, "consent_source() not found in the rendered job")
        bash = os.environ.get("HPCW_BASH") or "bash"
        env = dict(os.environ)
        env["MSYS_NO_PATHCONV"] = "1"
        with tempfile.TemporaryDirectory() as td:
            marker = os.path.join(td, "consent")
            # the list is colon-joined, so on a Windows checkout bash gets the /c/... spelling (a drive letter would split)
            marker_sh = subprocess.run(["cygpath", "-u", marker], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip() if os.name == "nt" and shutil.which("cygpath") else marker
            body = "hpcw_consent_seen() { return 1; }; CCD=/nowhere; CONSENT_MARKERS=%s; %s; consent_source" % (shlex.quote(marker_sh + ":/nonexistent/other"), m.group(0).strip())

            def run():
                p = subprocess.run([bash, "-c", body], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, encoding="utf-8", errors="replace", env=env)
                self.assertEqual(p.returncode, 0, p.stderr)
                return p.stdout.strip()

            self.assertEqual(run(), "none")
            with open(marker, "w") as fh:
                fh.write("yes 2026-09-29T05:13:00Z install-7f3a\n")
            self.assertEqual(run(), "marker")

    def test_rendered_is_valid_bash(self):
        text = self.rendered()
        # bytes, so Windows does not turn the newlines into CRLF on the way to bash
        bash = os.environ.get("HPCW_BASH") or "bash"
        p = subprocess.run([bash, "-n"], input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr.decode("utf-8", "replace"))

    def test_resume_launcher_drops_capacity(self):
        # write_launcher exactly as rendered: a fresh start passes --name, --capacity and
        # --permission-mode; a resume (--continue) leaves --capacity out, because Claude Code 2.1.283
        # refuses the pair (measured on job 40501175: "--session-id and --continue cannot be used
        # with --spawn, --capacity, or --create-session-in-dir")
        import tempfile
        text = self.rendered()
        m = re.search(r"\nwrite_launcher\(\) \{.*?\n\}\n", text, re.S)
        self.assertTrue(m, "write_launcher() not found in the rendered job")
        bash = os.environ.get("HPCW_BASH") or "bash"
        env = dict(os.environ)
        env["MSYS_NO_PATHCONV"] = "1"
        with tempfile.TemporaryDirectory() as td:
            rd = td.replace("\\", "/")
            head = "cd '%s' || exit 9; RUN_DIR='%s'; WORKSPACE=/ws/worker; CLAUDE_BIN=/usr/local/bin/claude; JOB=1; NODE=n; RC_ARGS=(--name wayne-1 --capacity 4 --permission-mode default); %s; " % (rd, rd, m.group(0).strip())

            def launch(extra):
                p = subprocess.run([bash, "-c", head + "write_launcher " + extra], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, encoding="utf-8", errors="replace", env=env)
                self.assertEqual(p.returncode, 0, p.stderr)
                with open(os.path.join(td, "launch.sh")) as fh:
                    return fh.read()

            fresh = launch("")
            self.assertIn("--name wayne-1 --capacity 4 --permission-mode default", fresh)
            self.assertNotIn("--continue", fresh)
            resumed = launch("--continue")
            self.assertIn("--continue", resumed)
            self.assertNotIn("--capacity", resumed)
            self.assertNotIn(" 4", resumed.split("remote-control", 1)[1], "the capacity's value goes with its flag")
            self.assertIn("--name wayne-1 --permission-mode default --continue", resumed)

    def test_unresolved_placeholder_raises(self):
        with self.assertRaises(KeyError):
            P.render("hello @NOT_A_KEY@", {"RUN": "x"})

    def test_template_has_no_credential_words(self):
        # the unrendered template too: a reviewer reading it should find no way to pass a token
        self.assertNotIn("setup-token", self.tpl)
        self.assertNotIn("credentials.json", self.tpl)


class StopPath(RenderBase):
    """The job's stop path and TERM trap, exactly as rendered (stop_and_leave, on_term and end_chain
    lifted from the job text), run in a scratch run directory with the session, the status writer
    and the scheduler stubbed, and a real SIGTERM sent from outside at a chosen moment. What is
    checked: a TERM that lands inside the stop path (the CLI's scancel) leaves the state stopped,
    "stopped" is the last status written, the trap stays armed for a second TERM, stop.done is the
    job's last act, the EXIT trap still runs, and a TERM without a stop still gives preempted."""

    HARNESS = r"""#!/bin/bash
set -u
cd "$1" || exit 9
LOG="$1/log"
log() { printf '%s\n' "$*" >> "$LOG"; }
say() { log "say $*"; }
write_status() { STATE="$1"; MESSAGE="$2"; log "status $1"; }
adapter_cancel() { log "scancel $*"; }
cleanup() { log cleanup; }
rc_stop() { log rc_stop; local i; for i in 1 2 3 4 5 6; do sleep 1; done; log rc_stop-done; }
JOB=40500019; RUN=worker; NODE=asx1; NEXT_JOB=""; CHAIN_NOTE=""; HAVE_ADAPTER=1; STATE=online; MESSAGE=""
@FUNCTIONS@
# the real on_term, wrapped so the log shows when the signal landed and what the path's state was
eval "$(declare -f on_term | sed '1s/^on_term/on_term_real/')"
on_term() { log "term-seen STOPPING=$STOPPING"; on_term_real; }
trap cleanup EXIT
trap on_term TERM INT
@BODY@
log unreachable
"""

    def functions(self):
        text = self.rendered()
        block = re.search(r"\nSTOPPING=0\nstop_and_leave\(\) \{.*?\n\}\non_term\(\) \{.*?\n\}\n", text, re.S)
        end_chain = re.search(r"\nend_chain\(\) \{.*?\n\}\n", text, re.S)
        self.assertTrue(block and end_chain, "the stop path is not in the rendered job in the expected shape")
        return end_chain.group(0) + block.group(0)

    def drive(self, body, kill_after, files=(), next_job=""):
        """Run the harness with BODY as its main part; send TERM after each delay in KILL_AFTER; return (rc, log lines, run dir listing)."""
        import shutil
        import tempfile
        bash = os.environ.get("HPCW_BASH") or "bash"
        td = tempfile.mkdtemp(prefix="hpcw_stop_")
        try:
            rd = os.path.join(td, "run")
            os.makedirs(rd)
            for name, content in files:
                with open(os.path.join(rd, name), "w") as fh:
                    fh.write(content)
            harness = os.path.join(td, "harness.sh")
            with open(harness, "w", newline="\n") as fh:
                fh.write(self.HARNESS.replace("@FUNCTIONS@", self.functions()).replace("@BODY@", ("NEXT_JOB=%s\n" % next_job if next_job else "") + body))
            kills = "".join("sleep %s; kill -TERM $pid; " % k for k in kill_after)
            outer = "bash '%s' '%s' & pid=$!; %swait $pid; echo rc=$?" % (harness.replace("\\", "/"), rd.replace("\\", "/"), kills)
            env = dict(os.environ)
            env["MSYS_NO_PATHCONV"] = "1"
            p = subprocess.run([bash, "-c", outer], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, encoding="utf-8", errors="replace", env=env, timeout=120)
            m = re.search(r"rc=(\d+)", p.stdout)
            self.assertTrue(m, (p.stdout, p.stderr))
            log = []
            if os.path.exists(os.path.join(rd, "log")):
                with open(os.path.join(rd, "log")) as fh:
                    log = fh.read().splitlines()
            return int(m.group(1)), log, sorted(os.listdir(rd)), p.stderr
        finally:
            shutil.rmtree(td, ignore_errors=True)

    def test_term_inside_the_stop_path_leaves_stopped(self):
        # the main loop found the stop file and is in rc_stop (6 s) when two TERMs land, 2 s apart:
        # both are seen (the trap stays armed), the path resumes, the successor is cancelled, stopped
        # is written, then stop.done, then the EXIT trap; never preempted
        body = 'while :; do if [ -e stop ]; then stop_and_leave "stop file"; fi; sleep 1; done'
        rc, log, files, err = self.drive(body, kill_after=(2, 2), files=(("stop", ""), ("next.id", "40500052 40500019\n")), next_job="40500052")
        self.assertEqual(rc, 0, (log, err))
        self.assertEqual(log.count("term-seen STOPPING=1"), 2, log)
        self.assertNotIn("term-seen STOPPING=0", log)
        self.assertIn("rc_stop-done", log)
        self.assertIn("scancel 40500052", log)
        statuses = [l for l in log if l.startswith("status ")]
        self.assertEqual(statuses, ["status stopped"], log)
        self.assertLess(log.index("term-seen STOPPING=1"), log.index("status stopped"))
        self.assertLess(log.index("rc_stop-done"), log.index("status stopped"))
        self.assertLess(log.index("scancel 40500052"), log.index("status stopped"))
        self.assertEqual(log[-1], "cleanup", "the EXIT trap ran: node-local temp would be removed")
        self.assertNotIn("unreachable", log)
        self.assertIn("stop.done", files)
        self.assertNotIn("stop", files)
        self.assertNotIn("next.id", files)

    def test_term_with_a_stop_file_waiting_is_a_stop(self):
        # the stop file is there but the loop has not reached it (STOPPING=0) when the TERM lands
        rc, log, files, err = self.drive("sleep 5; sleep 5", kill_after=(1.5,), files=(("stop", ""),))
        self.assertEqual(rc, 0, (log, err))
        self.assertIn("term-seen STOPPING=0", log)
        self.assertEqual([l for l in log if l.startswith("status ")], ["status stopped"], log)
        self.assertIn("stop.done", files)
        self.assertNotIn("stop", files)
        self.assertNotIn("unreachable", log)

    def test_term_after_stop_done_is_a_stop(self):
        # a stop.done from a stop that went through, then a late signal: still stopped, never preempted
        rc, log, files, err = self.drive("sleep 5; sleep 5", kill_after=(1.5,), files=(("stop.done", ""),))
        self.assertEqual(rc, 0, (log, err))
        self.assertEqual([l for l in log if l.startswith("status ")], ["status stopped"], log)
        self.assertIn("stop.done", files)

    def test_term_without_a_stop_is_preempted(self):
        # the wall time (or a preemption) with a successor queued: preempted, the successor kept
        rc, log, files, err = self.drive("sleep 5; sleep 5", kill_after=(1.5,), files=(("next.id", "40500052 40500019\n"),), next_job="40500052")
        self.assertEqual(rc, 0, (log, err))
        self.assertEqual([l for l in log if l.startswith("status ")], ["status preempted"], log)
        self.assertIn("say ending: successor 40500052 takes over", log)
        self.assertNotIn("scancel 40500052", log, "a preemption keeps the successor")
        self.assertNotIn("stop.done", files)
        self.assertIn("next.id", files)
        self.assertEqual(log[-1], "cleanup")


if __name__ == "__main__":
    unittest.main()
