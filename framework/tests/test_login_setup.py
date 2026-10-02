"""hpcworker login-setup (framework 10, AM2), in a scratch HOME: the key made once in a file of its own
name, the ~/.ssh/config block that ssh itself reads back for the login node's names, the one
authorized_keys line limited with from="" to the address the terminal came from (at most four, newest
kept), the right modes, what it refuses (not an ssh session, this same computer, an agent or no
terminal, a home others may write to, a key file that is not its own), an existing key of the
student's with and without a passphrase left byte for byte, a second run, and --remove.

UNPROVEN ON THE GRID: these tests and the mock portal are all it has met; no student without a key has
run it on the real grid. Needs POSIX file modes and ssh-keygen (Linux, WSL); skipped on a Windows
checkout. The terminal check is stood in for (hpcw_have_terminal), as the tests have none."""
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

import fakegrid as G

SSH_CONN = "10.0.0.1 52341 10.0.0.2 22"
DONE = "Done. The grid will not ask again."
LINE_RE = re.compile(r'^from="([^"]+)",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 (\S+) beethoven-login-setup st1234 \d{4}-\d\d-\d\d$')
POSIX = os.name != "nt" and shutil.which("ssh-keygen") and not (hasattr(os, "geteuid") and os.geteuid() == 0)


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


@unittest.skipUnless(POSIX, "needs POSIX file modes and ssh-keygen, as a user (Linux, WSL)")
class LoginSetup(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="hpcw_ls_")
        self.home = os.path.join(self.td, "home")
        os.makedirs(self.home)
        os.chmod(self.home, 0o700)
        self.ssh = os.path.join(self.home, ".ssh")

    def tearDown(self):
        shutil.rmtree(self.td, ignore_errors=True)

    def run_ls(self, args="", ssh_connection=SSH_CONN, terminal=True, env=None):
        stand_in = "hpcw_have_terminal() { return 0; }; " if terminal else ""
        e = {"HOME": self.home, "HPCW_HOME": os.path.join(self.home, ".hpcworker"), "USER": "st1234", "SSH_CONNECTION": ssh_connection}
        e.update(env or {})
        script = "source '%s/bin/hpcworker' && %scmd_login_setup %s" % (G.ROOT, stand_in, args)
        return G.bash(script, env=e)

    def p(self, name):
        return os.path.join(self.ssh, name)

    def read(self, name):
        with open(self.p(name)) as fh:
            return fh.read()

    def our_lines(self):
        return [l for l in self.read("authorized_keys").splitlines() if " beethoven-login-setup " in l]

    def snapshot(self):
        out = {}
        if os.path.isdir(self.ssh):
            for n in sorted(os.listdir(self.ssh)):
                with open(self.p(n), "rb") as fh:
                    out[n] = fh.read()
        return out

    def assert_done(self, rc, out, err):
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out.splitlines()[-1], DONE)
        self.assertNotIn("PRIVATE KEY", out + err, "a private key is never printed")
        if os.path.exists(self.p("beethoven_ed25519.pub")):
            self.assertNotIn(self.read("beethoven_ed25519.pub").split()[1], out + err, "nor the public one")

    def test_no_key_at_all(self):
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        self.assertEqual(mode(self.ssh), 0o700)
        self.assertEqual(mode(self.p("beethoven_ed25519")), 0o600)
        self.assertEqual(mode(self.p("beethoven_ed25519.pub")), 0o644)
        self.assertEqual(mode(self.p("config")), 0o600)
        self.assertEqual(mode(self.p("authorized_keys")), 0o600)
        pub = self.read("beethoven_ed25519.pub").split()
        self.assertEqual(pub[0], "ssh-ed25519")
        self.assertEqual(pub[2:4], ["beethoven-login-setup", "st1234"])
        (line,) = self.our_lines()
        m = LINE_RE.match(line)
        self.assertTrue(m, line)
        self.assertEqual(m.group(1), "10.0.0.1")
        self.assertEqual(m.group(2), pub[1])
        cfg = self.read("config").splitlines()
        self.assertEqual(cfg[0], '# >>> beethoven login-setup (managed; "hpcworker login-setup --remove" removes this block) >>>')
        self.assertTrue(cfg[1].startswith("Host warrior warrior.* "), cfg[1])
        self.assertEqual(cfg[2:9], ["    IdentityFile ~/.ssh/beethoven_ed25519"] + ["    IdentityFile ~/.ssh/%s" % k for k in ("id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_dsa")])
        self.assertEqual(cfg[9], "# <<< beethoven login-setup <<<")
        # ssh itself reads the block for the host the portal's Shell names, and offers our key first
        for host in ("warrior", "warrior.nas.grid.wayne.edu"):
            g = subprocess.run(["ssh", "-G", "-F", self.p("config"), host], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True).stdout
            ids = [l.split(None, 1)[1] for l in g.splitlines() if l.lower().startswith("identityfile ")]
            self.assertEqual(ids[0], "~/.ssh/beethoven_ed25519", (host, ids))
        # nothing else under the home
        self.assertEqual(sorted(os.listdir(self.home)), [".ssh"])

    def test_existing_passwordless_and_passphrase_keys_are_untouched(self):
        os.makedirs(self.ssh, mode=0o700)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "mine", "-f", self.p("id_ed25519")], check=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "rsa", "-b", "2048", "-N", "a secret phrase", "-C", "mine2", "-f", self.p("id_rsa")], check=True)
        with open(self.p("authorized_keys"), "w") as fh:
            fh.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfMine me@laptop\n# a comment of mine\n")
        with open(self.p("config"), "w") as fh:
            fh.write("Host github.com\n    User git")  # no newline at the end
        os.chmod(self.p("config"), 0o644)
        before = {n: v for n, v in self.snapshot().items() if n.startswith("id_")}
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        after = {n: v for n, v in self.snapshot().items() if n.startswith("id_")}
        self.assertEqual(after, before, "the student's own keys, private and public, byte for byte")
        ak = self.read("authorized_keys").splitlines()
        self.assertEqual(ak[:2], ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfMine me@laptop", "# a comment of mine"], "the student's lines, in place")
        self.assertEqual(len(ak), 3)
        cfg = self.read("config")
        self.assertTrue(cfg.startswith("Host github.com\n    User git\n# >>> beethoven login-setup"), cfg)
        self.assertEqual(mode(self.p("config")), 0o644, "the mode it had")
        g = subprocess.run(["ssh", "-G", "-F", self.p("config"), "warrior"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True).stdout
        ids = [l.split(None, 1)[1] for l in g.splitlines() if l.lower().startswith("identityfile ")]
        self.assertEqual(ids[:5], ["~/.ssh/beethoven_ed25519", "~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk", "~/.ssh/id_ed25519"],
                         "the student's keys still offered, after ours")

    def test_twice_and_from_new_addresses(self):
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        first = self.snapshot()
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        self.assertIn("Kept the key made before", out)
        self.assertEqual(self.snapshot(), first, "a second run changes nothing")
        # the student adds a block of their own after ours; a later run rewrites ours in place
        with open(self.p("config"), "a") as fh:
            fh.write("Host other\n    User me\n")
        for i, addr in enumerate(("10.0.0.9", "10.0.0.10", "2001:db8::7", "10.0.0.12")):
            rc, out, err = self.run_ls(ssh_connection="%s 4000 10.0.0.2 22" % addr)
            self.assert_done(rc, out, err)
        (line,) = self.our_lines()
        self.assertEqual(LINE_RE.match(line).group(1).split(","), ["10.0.0.9", "10.0.0.10", "2001:db8::7", "10.0.0.12"], "at most four, newest kept")
        cfg = self.read("config")
        self.assertEqual(cfg.count("# >>> beethoven login-setup"), 1)
        self.assertTrue(cfg.rstrip("\n").endswith("Host other\n    User me"), "our block stays where it was")
        self.assertEqual(self.read("beethoven_ed25519.pub"), first["beethoven_ed25519.pub"].decode(), "the same key throughout")

    def test_wrong_modes_are_put_right(self):
        os.makedirs(self.ssh)
        os.chmod(self.ssh, 0o777)
        with open(self.p("authorized_keys"), "w") as fh:
            fh.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfMine me@laptop\n")
        os.chmod(self.p("authorized_keys"), 0o666)
        with open(self.p("config"), "w") as fh:
            fh.write("Host x\n")
        os.chmod(self.p("config"), 0o666)
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        self.assertEqual((mode(self.ssh), mode(self.p("authorized_keys")), mode(self.p("config"))), (0o700, 0o600, 0o644))

    def test_refusals(self):
        cases = [
            ("", True, {}, 2, "Stopped: this is not a session that came in through ssh, so there is no address to allow."),
            ("10.0.0.1 52341", True, {}, 2, "Stopped: this is not a session that came in through ssh, so there is no address to allow."),
            ('10.0.0.1",command="x 1 2 3', True, {}, 2, "Stopped: this is not a session that came in through ssh, so there is no address to allow."),
            ("127.0.0.1 52341 127.0.0.1 22", True, {}, 2, "Stopped: this session came from this same computer, not from the grid's website."),
            ("10.0.0.2 52341 10.0.0.2 22", True, {}, 2, "Stopped: this session came from this same computer, not from the grid's website."),
            (SSH_CONN, True, {"CLAUDECODE": "1"}, 2, "Stopped: this changes how your account signs in, so it runs only in the grid's own terminal, not under Claude Code or another program."),
            (SSH_CONN, False, {}, 2, "Stopped: this changes how your account signs in, so it runs only in the grid's own terminal, not under Claude Code or another program."),
        ]
        for conn, term, env, rc_want, line in cases:
            rc, out, err = self.run_ls(ssh_connection=conn, terminal=term, env=env)
            self.assertEqual((rc, out.strip().splitlines()[-1]), (rc_want, line), (conn, term, env))
            self.assertFalse(os.path.exists(self.ssh), "nothing was changed")
        os.chmod(self.home, 0o775)
        rc, out, err = self.run_ls()
        self.assertEqual((rc, out.strip()), (3, "Stopped: your home folder can be written by others, so the grid would ignore any key in it."))
        self.assertFalse(os.path.exists(self.ssh))

    def test_a_key_file_that_is_not_ours(self):
        os.makedirs(self.ssh, mode=0o700)
        with open(self.p("beethoven_ed25519"), "w") as fh:
            fh.write("something of the student's\n")
        before = self.snapshot()
        rc, out, err = self.run_ls()
        self.assertEqual((rc, out.strip().splitlines()[-1]), (6, "Stopped: ~/.ssh/beethoven_ed25519 is there but was not made by this tool; nothing was changed."))
        self.assertEqual(self.snapshot(), before)
        rc, out, err = self.run_ls("--remove")
        self.assertEqual((rc, out.strip()), (0, "Nothing to remove."))
        self.assertEqual(self.snapshot(), before, "--remove leaves a key file it did not make")

    def test_files_that_are_links_are_left_alone(self):
        os.makedirs(self.ssh, mode=0o755)
        dot = os.path.join(self.td, "dotfiles")
        os.makedirs(dot)
        with open(os.path.join(dot, "config"), "w") as fh:
            fh.write("Host github.com\n    User git\n")
        os.symlink(os.path.join(dot, "config"), self.p("config"))
        rc, out, err = self.run_ls()
        self.assertEqual((rc, out.strip().splitlines()[-1]), (7, "Stopped: ~/.ssh/config could not be updated safely; nothing was changed."))
        self.assertTrue(os.path.islink(self.p("config")), "the link stays a link")
        with open(os.path.join(dot, "config")) as fh:
            self.assertEqual(fh.read(), "Host github.com\n    User git\n")
        self.assertEqual(mode(self.ssh), 0o755, "nothing was changed, ~/.ssh's mode included")
        self.assertFalse(os.path.exists(self.p("beethoven_ed25519")))
        os.remove(self.p("config"))
        with open(os.path.join(dot, "ak"), "w") as fh:
            fh.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfMine me@laptop\n")
        os.symlink(os.path.join(dot, "ak"), self.p("authorized_keys"))
        rc, out, err = self.run_ls()
        self.assertEqual((rc, out.strip().splitlines()[-1]), (7, "Stopped: ~/.ssh/authorized_keys could not be updated; nothing was changed."))
        self.assertTrue(os.path.islink(self.p("authorized_keys")))

    def test_a_line_of_the_students_that_mentions_the_tag_is_kept(self):
        os.makedirs(self.ssh, mode=0o700)
        mine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfMine notes about beethoven-login-setup from my laptop"
        with open(self.p("authorized_keys"), "w") as fh:
            fh.write(mine + "\n")
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        ak = self.read("authorized_keys").splitlines()
        self.assertEqual(ak[0], mine, "the student's line, untouched")
        self.assertEqual(len(ak), 2)
        self.assertTrue(LINE_RE.match(ak[1]), ak[1])
        rc, out, err = self.run_ls("--remove")
        self.assertEqual((rc, out.strip()), (0, "Done. Removed Beethoven's grid key."))
        self.assertEqual(self.read("authorized_keys"), mine + "\n", "--remove takes only ours")

    def test_a_block_without_its_end_line_is_not_guessed_at(self):
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        cfg = self.read("config").replace("# <<< beethoven login-setup <<<\n", "") + "Host lab\n    User me\nHost github.com\n    User git\n"
        with open(self.p("config"), "w") as fh:
            fh.write(cfg)
        rc, out, err = self.run_ls()
        self.assertEqual((rc, out.strip().splitlines()[-1]), (7, "Stopped: ~/.ssh/config could not be updated safely; nothing was changed."))
        self.assertEqual(self.read("config"), cfg, "the student's later blocks stay")
        rc, out, err = self.run_ls("--remove")
        self.assertEqual(rc, 7)
        self.assertEqual(self.read("config"), cfg)

    def test_a_home_that_is_a_link(self):
        real = os.path.join(self.td, "real-home")
        os.rename(self.home, real)
        os.symlink(real, self.home)
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)

    def test_remove(self):
        os.makedirs(self.ssh, mode=0o700)
        with open(self.p("authorized_keys"), "w") as fh:
            fh.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfMine me@laptop\n")
        with open(self.p("config"), "w") as fh:
            fh.write("Host github.com\n    User git\n")
        rc, out, err = self.run_ls()
        self.assert_done(rc, out, err)
        rc, out, err = self.run_ls("--remove", ssh_connection="")
        self.assertEqual((rc, out.strip()), (0, "Done. Removed Beethoven's grid key."))
        self.assertEqual(sorted(os.listdir(self.ssh)), ["authorized_keys", "config"])
        self.assertEqual(self.read("authorized_keys"), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOfMine me@laptop\n")
        self.assertEqual(self.read("config"), "Host github.com\n    User git\n")
        rc, out, err = self.run_ls("--remove")
        self.assertEqual((rc, out.strip()), (0, "Nothing to remove."))
        rc, out, err = self.run_ls("--remove", env={"CLAUDECODE": "1"})
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
