"""Framework 21, several Claude accounts on the grid: lib/accounts_read.py (what Claude Code's own
answers say about one account, and the account auto mode moves to) and `hpcworker accounts` through
bash, with the profile and the scheduler stood in for: the plain folder made account 1 by a rename and a
link, the list as JSON, use, auto, forget (moved aside, never deleted), the code's shape, the sign-in as
a job and the link it printed, the load_profile switch to one account's folder, and the backstop that
keeps Beethoven's browser key away from every verb."""
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from test_cli import ROOT, bash, posix, with_cli

sys.path.insert(0, os.path.join(ROOT, "lib"))
import accounts_read as A  # noqa: E402

LINK = "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&state=abc"


def event(kind="five_hour", used=0.42, status="allowed", resets="2026-10-21T18:00:00Z", unified=True):
    info = {"status": status, "rateLimitType": kind, "utilization": used, "resetsAt": resets}
    if unified:
        info["unifiedWindows"] = {"five_hour": {"utilization": used, "resetsAt": resets},
                                  "seven_day": {"utilization": 0.1, "resetsAt": "2026-10-25T00:00:00Z"}}
    return json.dumps({"type": "rate_limit_event", "rate_limit_info": info})


class Reader(unittest.TestCase):
    def test_who_keeps_four_keys_and_the_subscription_rule(self):
        sub = json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "a@b.edu", "subscriptionType": "max", "orgId": "x"})
        w = A.who_of("2", sub)
        self.assertEqual((w["signed_in"], w["sign_in"], w["email"], w["plan"], w["slot"]), (True, "subscription", "a@b.edu", "max", "2"))
        self.assertNotIn("orgId", w)
        key = json.dumps({"loggedIn": True, "authMethod": "claude.ai", "apiKeySource": "ANTHROPIC_API_KEY", "email": "a@b.edu"})
        w = A.who_of("2", key)
        self.assertEqual((w["signed_in"], w["sign_in"]), (False, "other"))
        self.assertNotIn("email", w, "nothing of a sign-in Beethoven never runs on is kept")
        self.assertEqual(A.who_of("2", "not json")["sign_in"], "none")

    def test_use_reads_the_last_event_with_windows(self):
        text = "\n".join(['{"type":"system"}', event(used=0.2), event(used=0.55), '{"type":"result","result":"ok"}'])
        r = A.reading_of("1", text)
        self.assertEqual(r["windows"]["five_hour"], {"utilization": 0.55, "resetsAt": "2026-10-21T18:00:00Z"})
        self.assertEqual(r["windows"]["seven_day"]["utilization"], 0.1)
        self.assertEqual(r["status"], "allowed")

    def test_a_refused_call_counts_as_full(self):
        r = A.reading_of("1", event(status="rejected", used=None, unified=False))
        self.assertEqual(r["windows"]["five_hour"]["utilization"], 1.0)
        self.assertEqual(r["status"], "rejected")

    def test_no_reading_says_why_in_claude_codes_words_only(self):
        r = A.reading_of("1", '{"type":"result","is_error":true,"result":"Not logged in \\u00b7 Please run /login"}')
        self.assertEqual(r["error"], "Claude Code said: Not logged in · Please run /login")
        self.assertNotIn("windows", r)

    def test_pick(self):
        now = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)
        later = (now + timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        past = (now - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        with tempfile.TemporaryDirectory() as td:
            def put(n, used, resets=later, signed=True):
                os.makedirs(os.path.join(td, n), exist_ok=True)
                A.write(os.path.join(td, n + ".who.json"), {"signed_in": signed})
                A.write(os.path.join(td, n + ".use.json"), {"windows": {"five_hour": {"utilization": used, "resetsAt": resets}}})
            put("1", 0.5)
            put("2", 0.1)
            self.assertEqual(A.pick(td, "1", now=now), "", "the account in use has room: stay")
            put("1", 0.95)
            put("3", 0.05, signed=False)
            put("4", 0.3)
            self.assertEqual(A.pick(td, "1", now=now), "2", "the signed-in account with the least used")
            put("2", 0.97)
            self.assertEqual(A.pick(td, "1", now=now), "4")
            put("1", 0.95, resets=past)
            self.assertEqual(A.pick(td, "1", now=now), "", "a window that has reset holds nothing")

    def test_main_writes_files_0600(self):
        with tempfile.TemporaryDirectory() as td:
            src = os.path.join(td, "probe")
            with open(src, "w") as fh:
                fh.write(event() + "\n")
            out = os.path.join(td, "1.use.json")
            self.assertEqual(A.main(["use", "1", src, out]), 0)
            self.assertEqual(os.stat(out).st_mode & 0o777, 0o600)
            self.assertEqual(A.main(["use", "33", src, out]), 2, "a slot outside 1 to 32 is refused")


class Cli(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory()
        self.td = posix(self.t.name)
        self.cfg = os.path.join(self.td, "beethoven", "claude")
        os.makedirs(self.cfg)
        with open(os.path.join(self.cfg, ".claude.json"), "w") as fh:
            fh.write("{}\n")
        os.makedirs(os.path.join(self.td, "state"))

    def tearDown(self):
        self.t.cleanup()

    def run_cli(self, body, env=None, stdin_text=None):
        stubs = ("load_profile() { P_partition_cpu=secp; P_qos_cpu=secondary; P_ipc_dir='%(td)s/ipc'; CCD='%(cfg)s'; CCD_LINK='%(cfg)s'; STATE_DIR='%(td)s/state'; WORKSPACES=\"$STATE_DIR/workspaces\"; }; "
                 "adapter_submit() { echo \"$*\" >> '%(td)s/submits'; echo 777; }; " % {"td": self.td, "cfg": self.cfg})
        return bash(with_cli(stubs + body, os.path.join(self.td, "hpcw")), env=env, stdin_text=stdin_text)

    def listing(self):
        rc, out, err = self.run_cli("cmd_accounts list --json")
        self.assertEqual(rc, 0, err)
        return json.loads(out.splitlines()[-1])

    def accounts(self):
        return os.path.join(self.td, "beethoven", "accounts")

    def test_the_plain_folder_becomes_account_1_by_a_rename_and_a_link(self):
        d = self.listing()
        self.assertTrue(os.path.islink(self.cfg))
        self.assertEqual(os.readlink(self.cfg), "accounts/1")
        self.assertTrue(os.path.isfile(os.path.join(self.accounts(), "1", ".claude.json")), "moved, nothing copied or lost")
        self.assertEqual((d["current"], d["auto"], [a["slot"] for a in d["accounts"]]), ("1", False, ["1"]))
        self.assertEqual(d["accounts"][0]["login"]["state"], "none")
        self.assertEqual(self.listing()["current"], "1", "a second look changes nothing")

    def test_use_moves_the_link_and_refuses_what_is_not_there(self):
        self.listing()
        rc, out, err = self.run_cli("cmd_accounts use 2")
        self.assertNotEqual(rc, 0)
        self.assertIn("no account 2", err)
        os.makedirs(os.path.join(self.accounts(), "2"))
        rc, out, err = self.run_cli("cmd_accounts use 2")
        self.assertEqual(rc, 0, err)
        self.assertEqual(os.readlink(self.cfg), "accounts/2")
        with open(os.path.join(self.accounts(), "3.who.json"), "w") as fh:
            fh.write('{"signed_in":false,"slot":"3","v":1}\n')
        os.makedirs(os.path.join(self.accounts(), "3"))
        rc, out, err = self.run_cli("cmd_accounts use 3")
        self.assertNotEqual(rc, 0)
        self.assertIn("not signed in", err)
        self.assertEqual(os.readlink(self.cfg), "accounts/2")
        rc, out, err = self.run_cli("cmd_accounts use 33")
        self.assertNotEqual(rc, 0)

    def test_use_waits_for_a_worker_too_old_to_move(self):
        self.listing()
        os.makedirs(os.path.join(self.accounts(), "2"))
        rd = os.path.join(self.td, "state", "worker")
        os.makedirs(rd)
        with open(os.path.join(rd, "status.json"), "w") as fh:
            fh.write('{"version":20,"state":"online","message":"x"}\n')
        rc, out, err = self.run_cli("cmd_accounts use 2")
        self.assertNotEqual(rc, 0)
        self.assertIn("framework 20", err)
        self.assertEqual(os.readlink(self.cfg), "accounts/1", "nothing was changed")
        with open(os.path.join(rd, "status.json"), "w") as fh:
            fh.write('{"version":21,"state":"online","message":"x"}\n')
        self.assertEqual(self.run_cli("cmd_accounts use 2")[0], 0)

    def test_the_sign_in_job_carries_nothing_of_a_gate(self):
        self.listing()
        rc, out, err = self.run_cli("adapter_submit() { echo \"gate=${HPCW_GATE:-} ssh=${SSH_ORIGINAL_COMMAND:-}\" >> '%s/submits'; echo 1; }; cmd_accounts login 2 --detach" % self.td,
                                    env={"SSH_ORIGINAL_COMMAND": "accounts login 2"})
        self.assertEqual(rc, 0, err)
        with open(os.path.join(self.td, "submits")) as fh:
            self.assertIn("gate= ssh=", fh.read())

    def test_auto_and_forget(self):
        self.listing()
        self.assertEqual(self.run_cli("cmd_accounts auto on")[0], 0)
        self.assertTrue(self.listing()["auto"])
        self.assertEqual(self.run_cli("cmd_accounts auto off")[0], 0)
        self.assertFalse(self.listing()["auto"])
        rc, out, err = self.run_cli("cmd_accounts forget 1")
        self.assertNotEqual(rc, 0, "the account in use is never forgotten")
        os.makedirs(os.path.join(self.accounts(), "2"))
        with open(os.path.join(self.accounts(), "2", "marker"), "w") as fh:
            fh.write("kept\n")
        rc, out, err = self.run_cli("cmd_accounts forget 2")
        self.assertEqual(rc, 0, err)
        self.assertFalse(os.path.exists(os.path.join(self.accounts(), "2")))
        kept = [os.path.join(r, f) for r, _, fs in os.walk(os.path.join(self.accounts(), ".forgotten")) for f in fs]
        self.assertTrue(any(k.endswith("claude/marker") for k in kept), "moved aside, nothing deleted")

    def test_the_sign_in_as_a_job_its_link_and_its_code(self):
        self.listing()
        rc, out, err = self.run_cli("cmd_accounts login 2 --detach")
        self.assertEqual(rc, 0, err)
        self.assertIn("HPCW-ACCOUNTS login 2: job 777", out)
        with open(os.path.join(self.td, "submits")) as fh:
            sub = fh.read()
        self.assertIn("-J hpcw_acct_login", sub)
        self.assertIn("-t 00:25:00", sub)
        w = os.path.join(self.td, "state", ".accounts", "login-2")
        with open(os.path.join(w, "job.sh")) as fh:
            self.assertIn("accounts _login-job 2", fh.read())
        self.assertEqual(self.listing()["accounts"][1]["login"]["state"], "waiting")
        self.assertEqual(self.run_cli("cmd_accounts link 2")[0], 3, "no link yet")
        with open(os.path.join(w, "out"), "a") as fh:
            fh.write("2026-10-21T02:00:00Z AUTH-URL: %s\n" % LINK)
        rc, out, err = self.run_cli("cmd_accounts link 2")
        self.assertEqual((rc, out), (0, "AUTH-URL: " + LINK))
        self.assertEqual(self.listing()["accounts"][1]["login"]["state"], "link")
        rc, out, err = self.run_cli("cmd_accounts code 2 'not a code'")
        self.assertNotEqual(rc, 0)
        rc, out, err = self.run_cli("cmd_accounts code 2 -", stdin_text="AbCdEf123456_-#state99\n")
        self.assertEqual(rc, 0, err)
        self.assertNotIn("AbCdEf", out + err, "the code is never printed")
        with open(os.path.join(w, "code")) as fh:
            self.assertEqual(fh.read(), "AbCdEf123456_-#state99\n")
        self.assertEqual(os.stat(os.path.join(w, "code")).st_mode & 0o077, 0)
        with open(os.path.join(w, "out"), "a") as fh:
            fh.write("2026-10-21T02:01:00Z HPCW-LOGIN: code received, checking\n2026-10-21T02:01:05Z SIGNED-IN b@c.edu pro\n")
        a = self.listing()["accounts"][1]
        self.assertEqual((a["login"]["state"], a["login"]["line"]), ("signed-in", "Signed in as b@c.edu pro"))

    def test_a_link_that_is_not_anthropics_is_never_given(self):
        self.listing()
        self.run_cli("cmd_accounts login 2 --detach")
        with open(os.path.join(self.td, "state", ".accounts", "login-2", "out"), "a") as fh:
            fh.write("2026-10-21T02:00:00Z AUTH-URL: https://evil.example/claude.ai\n")
        self.assertEqual(self.run_cli("cmd_accounts link 2")[0], 3)

    def test_a_worker_of_its_own_on_one_account(self):
        # framework 22: accounts start N [NAME] is worker start --account N; the listing names every worker
        # and the account each runs on, and an account a live worker is kept to is never forgotten
        self.listing()
        os.makedirs(os.path.join(self.accounts(), "2"))
        calls = os.path.join(self.td, "calls")
        stub = "cmd_worker() { echo \"$*\" >> '%s'; local rd='%s/state/team-b'; mkdir -p \"$rd\"; echo 2 > \"$rd/account.pin\"; echo 2 > \"$rd/account\"; echo '{\"state\":\"online\",\"node\":\"asx1\"}' > \"$rd/status.json\"; }; " % (calls, self.td)
        rc, out, err = self.run_cli(stub + "cmd_accounts start 2 team-b")
        self.assertEqual(rc, 0, err)
        self.assertIn("HPCW-ACCOUNTS start 2", out)
        with open(calls) as fh:
            self.assertEqual(fh.read().strip(), "start --name team-b --account 2")
        w = self.listing()["workers"]
        self.assertEqual([(x["name"], x["account"], x["pinned"], x["state"]) for x in w], [("team-b", "2", "2", "online")])
        self.assertNotEqual(self.run_cli("cmd_accounts forget 2")[0], 0, "a pinned worker's account stays")
        self.assertNotEqual(self.run_cli(stub + "cmd_accounts start 3")[0], 0, "no account 3")
        self.assertNotEqual(self.run_cli(stub + "cmd_accounts start 2 'bad name'")[0], 0)
        rc, out, err = self.run_cli(stub + "cmd_accounts stop team-b")
        self.assertEqual(rc, 0, err)
        with open(calls) as fh:
            self.assertEqual(fh.read().strip().splitlines()[-1], "stop --name team-b")
        self.assertNotEqual(self.run_cli(stub + "cmd_accounts stop nobody")[0], 0)

    def test_never_through_beethovens_browser_key(self):
        rc, out, err = self.run_cli("cmd_accounts list --json", env={"HPCW_GATE": "1"})
        self.assertNotEqual(rc, 0)
        self.assertFalse(os.path.islink(self.cfg), "nothing was changed")


class LoadProfile(unittest.TestCase):
    def test_a_slot_names_that_accounts_folder(self):
        with tempfile.TemporaryDirectory() as td:
            prof = os.path.join(ROOT, "profiles", "wayne.json")
            rc, out, err = bash(with_cli("PROFILE='%s'; load_profile; echo \"$CCD|$CCD_LINK\"" % posix(prof), posix(td)), env={"HPCW_ACCOUNT_SLOT": "3", "HOME": "/home/st"})
            self.assertEqual(rc, 0, err)
            ccd, link = out.splitlines()[-1].split("|")
            self.assertEqual(ccd, os.path.join(os.path.dirname(link), "accounts", "3"))
            rc, out, err = bash(with_cli("PROFILE='%s'; load_profile; echo \"$CCD|$CCD_LINK\"" % posix(prof), posix(td)), env={"HPCW_ACCOUNT_SLOT": "x", "HOME": "/home/st"})
            ccd, link = out.splitlines()[-1].split("|")
            self.assertEqual(ccd, link)


if __name__ == "__main__":
    unittest.main()
