"""The plain sign-in sitting (lib/login_plain.sh): the link finder and the screen classifier
against terminal text with escape codes, a boxed link, a link wrapped over two lines and a redrawn
screen; and, where `script`, `setsid` and `mkfifo` exist (Linux: the grid's login node, WSL), the
whole sitting against a stand-in claude: the line contract, the pasted code never echoed (through a
pipe and through a real pseudo-terminal), wrong codes, the dry run the probe job uses, and the
already-signed-in short cut. Nothing here talks to Anthropic or reads a credential."""
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BASH = os.environ.get("HPCW_BASH") or "bash"
SITTING = os.path.join(ROOT, "lib", "login_plain.sh")
URL = (
    "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    "&response_type=code&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback"
    "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference"
    "&code_challenge=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&code_challenge_method=S256"
    "&state=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
)
CODE = "GOODCODE#state"
# A stand-in for Claude Code's CLI, drawing what the measured flow draws: a method menu (Enter takes
# it), the authorize link and the paste prompt, "Invalid code" for anything but CODE (drawn twice,
# 1.5 s apart, as a screen redrawn whole would show one rejection in two frames), "Login
# successful" and a state file on success; `auth status` answers from that state file.
FAKE_CLAUDE = r"""#!/bin/bash
STATE="${FAKE_CLAUDE_STATE:?}"
case "${1:-} ${2:-}" in
  "auth status")
    if [ -e "$STATE" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "student@wayne.edu", "subscriptionType": "max"}'
    else echo '{"loggedIn": false}'; fi; exit 0;;
  "auth login")
    printf '\033[2J\033[H\033[1mSelect login method:\033[22m\r\n  \033[36m> 1. Claude account with subscription\033[0m\r\n    2. Anthropic Console account\r\n\r\n  Enter to confirm \xc2\xb7 Esc to cancel\r\n'
    # a whole line, not `read -n 1`: on bash 4.2 (CentOS 7) `read -n` leaves the terminal so that the next read sees end-of-file
    IFS= read -r _ans
    printf '\033[2J\033[H\xe2\x94\x82 \033[1mBrowser didn'"'"'t open? Use the url below to sign in:\033[22m\r\n\r\n%s\r\n\r\nPaste code here if prompted > ' "$FAKE_URL"
    for _try in 1 2 3; do
      IFS= read -r code
      if [ "$code" = "$FAKE_CODE" ]; then printf '\r\n\033[32mLogin successful\033[0m\r\n'; touch "$STATE"; exit 0; fi
      printf '\r\n\033[31mInvalid code\033[0m\r\nPaste code here if prompted > '
      sleep 1.5
      printf '\033[2K\033[1A\033[2K\033[G\033[31mInvalid code\033[0m\r\nPaste code here if prompted > '
    done
    exit 1;;
  *) echo "fake claude: unexpected: $*" >&2; exit 2;;
esac
"""
HAVE_PTY_TOOLS = os.name != "nt" and all(shutil.which(t) for t in ("script", "setsid", "mkfifo"))


def posix(path):
    return path.replace("\\", "/")


def bash(script, stdin_text=None, env=None, timeout=180):
    e = dict(os.environ)
    e["MSYS_NO_PATHCONV"] = "1"
    e["MSYS2_ARG_CONV_EXCL"] = "*"
    e.update(env or {})
    kw = {"input": stdin_text} if stdin_text is not None else {"stdin": subprocess.DEVNULL}
    p = subprocess.run([BASH, "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, encoding="utf-8", errors="replace", env=e, timeout=timeout, **kw)
    return p.returncode, p.stdout, p.stderr


def with_sitting(call):
    return "source '%s' && %s" % (posix(SITTING), call)


class LinkFinder(unittest.TestCase):
    def find(self, text):
        rc, out, err = bash(with_sitting("hpcw_login_strip | hpcw_login_url"), stdin_text=text)
        self.assertEqual(rc, 0, err)
        return out.strip()

    def test_plain_line(self):
        self.assertEqual(self.find("Browser didn't open? Use the url below to sign in:\n\n%s\n\nPaste code here if prompted > " % URL), URL)

    def test_codes_box_and_carriage_returns(self):
        text = "\x1b[2J\x1b[H│ \x1b[1m%s\x1b[22m │\r\n│ Paste code here if prompted > │\r\n" % URL
        self.assertEqual(self.find(text), URL)

    def test_wrapped_over_two_lines_is_joined(self):
        text = "%s\n%s\n\nPaste code here if prompted >\n" % (URL[:150], URL[150:])
        self.assertEqual(self.find(text), URL)

    def test_redrawn_screen_is_not_doubled(self):
        self.assertEqual(self.find("%s\n%s\nPaste code here\n" % (URL, URL)), URL)

    def test_only_an_authorize_link_counts(self):
        self.assertEqual(self.find("https://claude.ai/code?environment=env_01X\nhttps://docs.anthropic.com/en/x\nhttps://example.com/oauth/authorize?x=1\n"), "")

    def test_platform_domain(self):
        u = "https://platform.claude.com/oauth/authorize?client_id=x&state=y"
        self.assertEqual(self.find("Use the url below:\n%s\n" % u), u)

    def test_nothing_yet(self):
        self.assertEqual(self.find("Starting sign-in...\n"), "")


class Flags(unittest.TestCase):
    def flags(self, text):
        rc, out, err = bash(with_sitting("hpcw_login_strip | hpcw_login_flags"), stdin_text=text)
        self.assertEqual(rc, 0, err)
        return out.strip()

    def test_each_screen(self):
        self.assertEqual(self.flags("\x1b[1mPaste code here if prompted >\x1b[0m "), "prompt")
        self.assertEqual(self.flags("Select login method:\n> 1. Claude account with subscription\n  Enter to confirm · Esc to cancel\n"), "select")
        self.assertEqual(self.flags("\x1b[31mInvalid code\x1b[0m\n"), "invalid")
        self.assertEqual(self.flags("Login successful\n"), "success")
        self.assertEqual(self.flags("Enter to confirm\nPaste code here if prompted >"), "select prompt")
        self.assertEqual(self.flags("nothing of note\n"), "")

    def test_rejected_is_a_yes_or_no(self):
        # the sitting counts one rejection per code it sent, from the text drawn after that code; the
        # function only says whether such text shows one, however many frames repeat it
        self.assertEqual(bash(with_sitting("hpcw_login_rejected"), stdin_text="Invalid code\nPaste code here\nInvalid code\n")[0], 0)
        self.assertEqual(bash(with_sitting("hpcw_login_rejected"), stdin_text="The code is not valid\n")[0], 0)
        self.assertNotEqual(bash(with_sitting("hpcw_login_rejected"), stdin_text="Paste code here if prompted >\n")[0], 0)
        self.assertNotEqual(bash(with_sitting("hpcw_login_rejected"), stdin_text="")[0], 0)


@unittest.skipUnless(HAVE_PTY_TOOLS, "needs script, setsid and mkfifo (Linux)")
class Sitting(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="hpcw_sit_")
        self.claude = os.path.join(self.td, "claude")
        with open(self.claude, "w") as fh:
            fh.write(FAKE_CLAUDE)
        os.chmod(self.claude, 0o755)
        self.ws = os.path.join(self.td, "ws")
        os.makedirs(self.ws)
        self.state = os.path.join(self.td, "state")
        self.env = {"FAKE_CLAUDE_STATE": self.state, "FAKE_URL": URL, "FAKE_CODE": CODE}
        self.n = 0

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def sitting(self, stdin_text, budget=60, mode="live"):
        self.n += 1
        sd = os.path.join(self.td, "sit%d" % self.n)
        cmd = 'bash -c "$(cat %s)" _ %s %s %s "" %d %s' % (shlex.quote(SITTING), shlex.quote(self.ws), shlex.quote(self.claude), shlex.quote(sd), budget, mode)
        rc, out, err = bash(cmd, stdin_text=stdin_text, env=self.env)
        return rc, out, err, sd

    def test_good_code_through_a_pipe(self):
        rc, out, err, sd = self.sitting(CODE + "\n")
        lines = out.splitlines()
        self.assertEqual(rc, 0, (out, err))
        self.assertIn("AUTH-URL: " + URL, lines)
        self.assertIn("HPCW-LOGIN: paste the code from that page", lines)
        self.assertIn("HPCW-LOGIN: code received, checking", lines)
        self.assertEqual(lines[-1], "SIGNED-IN student@wayne.edu max")
        # the stand-in's method menu came before the link: the panel is told that Enter was pressed for it
        self.assertEqual(out.count("HPCW-LOGIN: a menu appeared; chose the first entry"), 1, out)
        self.assertLess(lines.index("HPCW-LOGIN: a menu appeared; chose the first entry"), lines.index("AUTH-URL: " + URL))
        self.assertNotIn(CODE, out, "the pasted code must never be echoed")
        self.assertNotIn("Select login method", out, "Claude Code's screen is never copied")
        self.assertTrue(os.path.exists(self.state))
        self.assertEqual(os.listdir(sd), [], "the transcript, the pipe and the launcher are removed")

    def test_wrong_codes(self):
        # three wrong codes, each rejection drawn in two frames by the stand-in: three lines, not six
        rc, out, err, _ = self.sitting("BAD1\nBAD2\nBAD3\n")
        self.assertEqual(rc, 3, (out, err))
        self.assertEqual(out.count("HPCW-LOGIN: that code was not accepted; paste it again"), 3, out)
        self.assertTrue(out.splitlines()[-1].startswith("HPCW-LOGIN-FAILED: Claude Code did not accept the code"))
        self.assertNotIn("BAD1", out)
        self.assertFalse(os.path.exists(self.state))

    def test_dry_run_reports_flags_never_the_link(self):
        rc, out, err, _ = self.sitting(None, budget=20, mode="dry")
        self.assertEqual(rc, 0, (out, err))
        dry = [l for l in out.splitlines() if l.startswith("HPCW-LOGIN-DRY: ")]
        self.assertEqual(len(dry), 1, out)
        for tok in ("url_seen=1", "prompt_seen=1", "select_seen=1", "enters=1", "script=1"):
            self.assertIn(tok, dry[0])
        self.assertNotIn("https://", out)
        self.assertNotIn("AUTH-URL", out)
        self.assertNotIn("menu appeared", out, "dry mode prints its one line only")

    def test_already_signed_in_short_cut(self):
        open(self.state, "w").close()
        rc, out, err, _ = self.sitting(None)
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines()[-1], "SIGNED-IN student@wayne.edu max")
        self.assertNotIn("AUTH-URL", out)

    def test_closed_shell_fails_in_words(self):
        rc, out, _, _ = self.sitting(None, budget=30)
        self.assertEqual(rc, 3)
        self.assertIn("HPCW-LOGIN-FAILED: the shell closed before a code arrived", out)

    @unittest.skipUnless(hasattr(os, "fork"), "needs a pseudo-terminal")
    def test_real_pty_never_echoes_the_code(self):
        import pty
        import select

        sd = os.path.join(self.td, "sit_pty")
        with open(SITTING) as fh:
            body = fh.read()
        env = dict(os.environ)
        env.update(self.env)
        pid, fd = pty.fork()
        if pid == 0:  # the sitting, as the portal shell would run it: stdin and stdout one terminal
            os.execvpe("bash", ["bash", "-c", body, "_", self.ws, self.claude, sd, "", "60"], env)
        out = b""
        typed = False
        t0 = time.time()
        while time.time() - t0 < 90:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            if not typed and b"AUTH-URL:" in out:
                time.sleep(0.5)
                os.write(fd, CODE.encode() + b"\n")
                typed = True
            if b"SIGNED-IN" in out or b"HPCW-LOGIN-FAILED" in out:
                time.sleep(1)
                break
        _, status = os.waitpid(pid, 0)
        text = out.decode("utf-8", "replace")
        self.assertTrue(typed, text)
        self.assertEqual(os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1, 0, text)
        self.assertIn("SIGNED-IN student@wayne.edu max", text)
        self.assertNotIn(CODE, text, "the terminal's echo is off: the code typed at the prompt never shows")


if __name__ == "__main__":
    unittest.main()
