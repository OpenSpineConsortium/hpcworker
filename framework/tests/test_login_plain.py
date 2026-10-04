"""The plain sign-in sitting (lib/login_plain.sh): the link finder and the screen classifier
against terminal text with escape codes, a boxed link, a link wrapped over two lines and a redrawn
screen; and, where `script`, `setsid` and `mkfifo` exist (Linux: the grid's login node, WSL), the
whole sitting against a stand-in claude: the line contract, the pasted code never echoed (through a
pipe and through a real pseudo-terminal), wrong codes, the dry run the probe job uses, and the
already-signed-in short cut. Framework 17 (greg, 2026-10-04: no API key anywhere): the sitting signs
in with a Claude subscription only, so a link on the Console's host, a menu with the Console
highlighted and a sign-in Claude Code reports as anything but the subscription all end it in words,
and --claudeai is asked for when Claude Code's help lists it. Nothing here talks to Anthropic or
reads a credential."""
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
# the Console's authorize page (API usage billing): framework 17 never shows it
CONSOLE_URL = "https://platform.claude.com/oauth/authorize?code=true&client_id=x&response_type=code&state=y"
SUBSCRIPTION_MENU = ("\x1b[1mSelect login method:\x1b[22m\r\n\r\n  \x1b[36m\u276f 1. Claude account with subscription \u00b7 Pro, Max, Team, or Enterprise\x1b[0m\r\n"
                     "    2. Anthropic Console account \u00b7 API usage billing\r\n    3. 3rd-party platform \u00b7 Amazon Bedrock, Microsoft Foundry, or Vertex AI\r\n\r\n"
                     "  Enter to confirm \u00b7 Esc to cancel\r\n")
CONSOLE_MENU = ("\x1b[1mSelect login method:\x1b[22m\r\n\r\n    1. Claude account with subscription \u00b7 Pro, Max, Team, or Enterprise\r\n"
                "  \x1b[36m\u276f 2. Anthropic Console account \u00b7 API usage billing\x1b[0m\r\n    3. 3rd-party platform \u00b7 Amazon Bedrock, Microsoft Foundry, or Vertex AI\r\n\r\n"
                "  Enter to confirm \u00b7 Esc to cancel\r\n")
# the first-run theme screen with the code preview Claude Code draws under it (2.1.42 and 2.1.289 both build
# this diff of demo.js): its console.log must not read as the Anthropic Console
THEME_MENU = ("\x1b[1mChoose the text style that looks best with your terminal\x1b[22m\r\n\r\n  \x1b[36m\u276f 1. Dark mode\x1b[0m\r\n    2. Light mode\r\n"
              "    3. Dark mode (colorblind-friendly)\r\n\r\n"
              "    1  function greet() {\r\n    2 -  console.log(\"Hello, World!\");\r\n    2 +  console.log(\"Hello, Claude!\");\r\n    3  }\r\n"
              "  Syntax highlighting enabled (ctrl+t to disable)\r\n\r\n  Enter to confirm \u00b7 Esc to cancel\r\n")
# what `claude auth status` prints for a sign-in that is not a Claude subscription, in the shapes the local Claude
# Code 2.1.289 binary and 2.1.42 npm package build (read from their code, 2026-10-04): the Console's own key, as
# 2.1.289 and as 2.1.42 report it, and a token from the environment
NOT_A_SUBSCRIPTION = (
    '{\n  "loggedIn": true,\n  "authMethod": "api_key",\n  "apiProvider": "firstParty",\n  "apiKeySource": "/login managed key",\n  "email": "student@wayne.edu"\n}',
    '{\n  "loggedIn": true,\n  "authMethod": "claude.ai",\n  "apiProvider": "firstParty",\n  "apiKeySource": "/login managed key",\n  "email": "student@wayne.edu",\n  "subscriptionType": null\n}',
    '{\n  "loggedIn": true,\n  "authMethod": "oauth_token",\n  "apiProvider": "firstParty"\n}',
)
# A stand-in for Claude Code's CLI, drawing what the measured flow draws: a method menu (Enter takes
# it), the authorize link and the paste prompt, "Invalid code" for anything but CODE (drawn twice,
# 1.5 s apart, as a screen redrawn whole would show one rejection in two frames), "Login
# successful" and a state file on success; `auth status` answers from that state file. Framework 17:
# FAKE_MENU picks the screen before the link (the menus above, as files), FAKE_CLAUDEAI lists
# --claudeai in `auth login --help` (a call that names it draws no menu: the way is chosen; what a
# real Claude Code draws then is not measured), FAKE_ARGS records the arguments `auth login` got, and
# FAKE_AUTH is what `auth status` prints once signed in (a Claude subscription when unset).
FAKE_CLAUDE = r"""#!/bin/bash
STATE="${FAKE_CLAUDE_STATE:?}"
case "${1:-} ${2:-}" in
  "auth status")
    if [ -e "$STATE" ] && [ -n "${FAKE_AUTH:-}" ]; then printf '%s\n' "$FAKE_AUTH"
    elif [ -e "$STATE" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "student@wayne.edu", "subscriptionType": "max"}'
    else echo '{"loggedIn": false}'; fi; exit 0;;
  "auth login")
    if [ "${3:-}" = --help ]; then
      echo "Usage: claude auth login [options]"
      if [ -n "${FAKE_CLAUDEAI:-}" ]; then echo "  --claudeai  Use Claude subscription (default)"; echo "  --console   Use Anthropic Console (API usage billing) instead of Claude subscription"; fi
      echo "  -h, --help  display help for command"; exit 0
    fi
    [ -n "${FAKE_ARGS:-}" ] && echo "$*" > "$FAKE_ARGS"
    if [ "${3:-}" != --claudeai ]; then
      printf '\033[2J\033[H'; cat "${FAKE_MENU:?}"
      # a whole line, not `read -n 1`: on bash 4.2 (CentOS 7) `read -n` leaves the terminal so that the next read sees end-of-file
      IFS= read -r _ans
    fi
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
    def find(self, text, rc_want=0):
        rc, out, err = bash(with_sitting("hpcw_login_strip | hpcw_login_url"), stdin_text=text)
        self.assertEqual(rc, rc_want, err)
        return out.strip()

    def test_plain_line(self):
        self.assertEqual(self.find("Browser didn't open? Use the url below to sign in:\n\n%s\n\nPaste code here if prompted > " % URL), URL)

    def test_codes_box_and_carriage_returns(self):
        text = "\x1b[2J\x1b[H│ \x1b[1m%s\x1b[22m │\r\n│ Paste code here if prompted > │\r\n" % URL
        self.assertEqual(self.find(text), URL)

    def test_an_erase_code_right_before_the_link_takes_nothing_with_it(self):
        # framework 14: the CSI intermediates are space to slash. Framework 13's [ -\/] was space to backslash in GNU
        # sed, so ESC[K right before the link (or before a space and the link) took the link's h, and none was found
        for code in ("\x1b[K", "\x1b[2K", "\x1b[1C", "\x1b[G"):
            for gap in ("", " "):
                text = "Browser didn't open? Use the url below to sign in:\r\n\r\n%s%s%s\r\n\r\nPaste code here if prompted > " % (code, gap, URL)
                self.assertEqual(self.find(text), URL, repr(code + gap))

    def test_wrapped_over_two_lines_is_joined(self):
        text = "%s\n%s\n\nPaste code here if prompted >\n" % (URL[:150], URL[150:])
        self.assertEqual(self.find(text), URL)

    def test_redrawn_screen_is_not_doubled(self):
        self.assertEqual(self.find("%s\n%s\nPaste code here\n" % (URL, URL)), URL)

    def test_only_an_authorize_link_counts(self):
        self.assertEqual(self.find("https://claude.ai/code?environment=env_01X\nhttps://docs.anthropic.com/en/x\nhttps://example.com/oauth/authorize?x=1\n"), "")

    def test_the_consoles_hosts_are_refused(self):
        # framework 17: the Anthropic Console's sign-in (API usage billing), on its host of today and of before;
        # status 2 and nothing printed, so the sitting ends instead of showing it
        for u in (CONSOLE_URL, "https://console.anthropic.com/oauth/authorize?client_id=x&state=y", "https://PLATFORM.claude.com/oauth/authorize?x=1"):
            self.assertEqual(self.find("Use the url below:\n%s\n" % u, rc_want=2), "", u)
        # wrapped over two lines, judged once joined
        self.assertEqual(self.find("%s\n%s\n\nPaste code here\n" % (CONSOLE_URL[:40], CONSOLE_URL[40:]), rc_want=2), "")

    def test_the_host_decides_never_a_substring(self):
        # a subscription link names platform.claude.com in its query (where the code comes back), plainly or encoded
        for u in ("https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=https://platform.claude.com/oauth/code/callback&state=y",
                  "https://claude.com/cai/oauth/authorize?code=true&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=y", URL):
            self.assertEqual(self.find("Use the url below:\n%s\n" % u), u)
        # and a host that only ends in a subscription host's name is not one
        self.assertEqual(self.find("https://evilclaude.ai/oauth/authorize?x=1\n", rc_want=2), "")

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

    def billed(self, text):
        rc, _, err = bash(with_sitting("hpcw_login_strip | hpcw_login_billed"), stdin_text=text)
        self.assertIn(rc, (0, 1), err)
        return rc == 0

    def test_a_menu_with_the_subscription_highlighted_takes_enter(self):
        # framework 17: the pointer (U+276F here, ">" in older fixtures) on the Claude subscription: Enter is allowed
        self.assertFalse(self.billed(SUBSCRIPTION_MENU))
        self.assertFalse(self.billed("Select login method:\n> 1. Claude account with subscription\n  2. Anthropic Console account\n  Enter to confirm\n"))

    def test_a_menu_with_anything_else_highlighted_is_refused(self):
        self.assertTrue(self.billed(CONSOLE_MENU))
        self.assertTrue(self.billed(CONSOLE_MENU.replace("\u276f 2.", "  2.").replace("    3. 3rd", "  \u276f 3. 3rd")))
        # the subscription drawn earlier and the Console highlighted now: the last pointer line is the one up
        self.assertTrue(self.billed(SUBSCRIPTION_MENU + CONSOLE_MENU))
        # a screen offering an API key with no pointer this file knows: no subscription is highlighted, refused
        self.assertTrue(self.billed("Detected a custom API key in your environment\nDo you want to use this API key?\n  1. Yes\n  2. No (recommended)\n  Enter to confirm\n"))

    def test_a_first_run_screen_without_sign_in_words_takes_enter_as_before(self):
        self.assertFalse(self.billed(THEME_MENU))
        self.assertFalse(self.billed("Press Enter to continue\n"))

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
        self.menus = {}
        for name, text in (("subscription", SUBSCRIPTION_MENU), ("console", CONSOLE_MENU), ("theme", THEME_MENU)):
            self.menus[name] = os.path.join(self.td, "menu_" + name)
            with open(self.menus[name], "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
        self.args = os.path.join(self.td, "login_args")
        self.env = {"FAKE_CLAUDE_STATE": self.state, "FAKE_URL": URL, "FAKE_CODE": CODE, "FAKE_MENU": self.menus["subscription"], "FAKE_ARGS": self.args}
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

    def test_a_first_run_menu_still_takes_enter(self):
        # framework 17 leaves a screen with no sign-in words as it was: Enter, and the line that says so
        self.env["FAKE_MENU"] = self.menus["theme"]
        rc, out, err, _ = self.sitting(CODE + "\n")
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.count("HPCW-LOGIN: a menu appeared; chose the first entry"), 1, out)
        self.assertEqual(out.splitlines()[-1], "SIGNED-IN student@wayne.edu max")

    def test_the_console_highlighted_ends_the_sitting_without_enter(self):
        # framework 17: no Enter on a menu whose highlighted entry bills by use; no digit or arrow is sent either
        self.env["FAKE_MENU"] = self.menus["console"]
        rc, out, err, sd = self.sitting(CODE + "\n")
        self.assertEqual(rc, 3, (out, err))
        last = out.splitlines()[-1]
        self.assertTrue(last.startswith("HPCW-LOGIN-FAILED: Claude Code offered a sign-in that bills by use"), out)
        self.assertIn("Beethoven signs in only with a Claude subscription", last)
        self.assertNotIn("menu appeared", out, "Enter was never pressed")
        self.assertNotIn("AUTH-URL", out)
        self.assertNotIn("SIGNED-IN", out)
        self.assertFalse(os.path.exists(self.state))
        self.assertEqual(os.listdir(sd), [], "the sitting's own files are removed")

    def test_a_link_on_the_consoles_host_is_never_shown(self):
        # framework 17: the subscription highlighted, and still the Console's page came up: it is not handed on
        self.env["FAKE_URL"] = CONSOLE_URL
        rc, out, err, _ = self.sitting(CODE + "\n")
        self.assertEqual(rc, 3, (out, err))
        self.assertTrue(out.splitlines()[-1].startswith("HPCW-LOGIN-FAILED: Claude Code offered a sign-in that bills by use"), out)
        self.assertNotIn("AUTH-URL", out)
        self.assertNotIn("platform.claude.com", out)
        self.assertNotIn("code received", out, "no code went in")

    def test_claudeai_is_asked_for_when_the_help_lists_it(self):
        self.env["FAKE_CLAUDEAI"] = "1"
        rc, out, err, _ = self.sitting(CODE + "\n")
        self.assertEqual(rc, 0, (out, err))
        with open(self.args) as fh:
            self.assertEqual(fh.read().split(), ["auth", "login", "--claudeai"])
        self.assertNotIn("menu appeared", out, "the method named on the command line: no menu")
        self.assertEqual(out.splitlines()[-1], "SIGNED-IN student@wayne.edu max")

    def test_claudeai_is_not_given_when_the_help_does_not_list_it(self):
        rc, out, err, _ = self.sitting(CODE + "\n")
        self.assertEqual(rc, 0, (out, err))
        with open(self.args) as fh:
            self.assertEqual(fh.read().split(), ["auth", "login"])

    def test_a_sign_in_that_is_not_a_subscription_is_never_signed_in(self):
        # framework 17: Claude Code says loggedIn, but by the Console or a token: never SIGNED-IN, never a sign-out
        for method in NOT_A_SUBSCRIPTION:
            self.env["FAKE_AUTH"] = method
            rc, out, err, _ = self.sitting(CODE + "\n")
            self.assertEqual(rc, 3, (method, out, err))
            self.assertNotIn("SIGNED-IN", out)
            self.assertEqual(out.splitlines()[-1], "HPCW-LOGIN-FAILED: Claude Code on the grid is signed in in a way that bills by use or is not a Claude subscription, "
                             "and Beethoven never runs on that; ask your lead to help you sign in again with your Claude subscription", out)
            self.assertTrue(os.path.exists(self.state), "nothing signed out: the stand-in's sign-in is still there")
            # and the short cut for a sign-in already there refuses it the same way
            rc, out, err, _ = self.sitting(None)
            self.assertEqual(rc, 3, (method, out, err))
            self.assertNotIn("SIGNED-IN", out)
            self.assertNotIn("AUTH-URL", out)
            self.assertIn("is not a Claude subscription", out.splitlines()[-1])
            os.remove(self.state)

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
        for tok in ("url_seen=1", "prompt_seen=1", "select_seen=1", "enters=1", "billed=0", "claudeai=0", "script=1"):
            self.assertIn(tok, dry[0])
        self.assertNotIn("https://", out)
        self.assertNotIn("AUTH-URL", out)
        self.assertNotIn("menu appeared", out, "dry mode prints its one line only")

    def test_dry_run_reports_a_way_that_bills_by_use(self):
        # framework 17: the Console highlighted, then (subscription highlighted) a Console link: billed=1 on the one
        # dry line, no Enter on the first, never the link and never a failure line
        self.env["FAKE_MENU"] = self.menus["console"]
        rc, out, err, _ = self.sitting(None, budget=20, mode="dry")
        self.assertEqual(rc, 0, (out, err))
        dry = [l for l in out.splitlines() if l.startswith("HPCW-LOGIN-DRY: ")]
        self.assertEqual(len(dry), 1, out)
        for tok in ("url_seen=0", "select_seen=1", "enters=0", "billed=1"):
            self.assertIn(tok, dry[0])
        self.assertNotIn("HPCW-LOGIN-FAILED", out)
        self.env.update(FAKE_MENU=self.menus["subscription"], FAKE_URL=CONSOLE_URL)
        rc, out, err, _ = self.sitting(None, budget=20, mode="dry")
        self.assertEqual(rc, 0, (out, err))
        for tok in ("url_seen=0", "enters=1", "billed=1"):
            self.assertIn(tok, out)
        self.assertNotIn("https://", out)
        self.env.update(FAKE_URL=URL, FAKE_CLAUDEAI="1")
        rc, out, err, _ = self.sitting(None, budget=20, mode="dry")
        for tok in ("url_seen=1", "enters=0", "billed=0", "claudeai=1"):
            self.assertIn(tok, out)

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
