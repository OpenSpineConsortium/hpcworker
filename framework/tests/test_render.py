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


class Render(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in ENV}
        os.environ.update(ENV)
        with open(TPL) as fh:
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
        self.assertNotIn("provenance", text)

    def test_rendered_is_valid_bash(self):
        text = self.rendered()
        # bytes, so Windows does not turn the newlines into CRLF on the way to bash
        bash = os.environ.get("HPCW_BASH") or "bash"
        p = subprocess.run([bash, "-n"], input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(p.returncode, 0, p.stderr.decode("utf-8", "replace"))

    def test_unresolved_placeholder_raises(self):
        with self.assertRaises(KeyError):
            P.render("hello @NOT_A_KEY@", {"RUN": "x"})

    def test_template_has_no_credential_words(self):
        # the unrendered template too: a reviewer reading it should find no way to pass a token
        self.assertNotIn("setup-token", self.tpl)
        self.assertNotIn("credentials.json", self.tpl)


if __name__ == "__main__":
    unittest.main()
