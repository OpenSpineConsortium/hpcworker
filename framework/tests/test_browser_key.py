"""hpcworker browser-key and gate (framework 11), in scratch accounts. Linux only: it needs POSIX file
modes, a pseudo-terminal and ssh-keygen (run it under WSL from a Windows checkout).

The layout is the lab's: <td>/shared/v<N> (this checkout's framework), <td>/shared/current -> v<N>, a
site profile "testsite" whose shared_install is the `current` link and whose state directory is under
<td>, and the fake scheduler of fakegrid.py on PATH. Every run puts a stand-in for each program
warrior's banner bans first on PATH, and a test fails if one is run, except where it says otherwise.
The key line, its refusals, the copy's folders, remove and check; then the gate: every accepted line
and the exact argv it hands on (through a stand-in for bin/hpcworker), hostile lines, the version
line, the expiry, read, forget, the caps, the watch slots, and the real verbs behind it."""
import base64
import hashlib
import json
import os
import random
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

import fakegrid as G

LINUX = os.name != "nt" and shutil.which("ssh-keygen") and not (hasattr(os, "geteuid") and os.geteuid() == 0)
BANNED = ("bedtools conda CONVERGE_Studio fastq-dump gcc gfortran g++ icc ifort lsdyna make md5sum namd2 namd3 node pip "
          "python python2 python3 python-notebook R rsync zellij").split()
REFUSED = "HPCW-GATE refused\n"
IID = "0123456789abcdef0123456789abcdef"
REAL_PY = shutil.which(G.PY) or G.PY   # by its full path: the trip-wire puts a failing python3 first on PATH
# the bash the suite runs under (tests/run.sh hands it on: under the bash 4.2 run, EL7's bash), first on every PATH here too
BASH = shutil.which(G.BASH) or G.BASH
BASH_DIR = (os.path.dirname(BASH) + ":") if os.path.isabs(BASH) else ""


def keygen(td, kind, name):
    p = os.path.join(td, name)
    subprocess.run(["ssh-keygen", "-q", "-t", kind, "-N", "", "-C", "test", "-f", p], check=True, stdin=subprocess.DEVNULL)
    with open(p + ".pub") as fh:
        t, b, _ = fh.read().split(" ", 2)
    fp = subprocess.run(["ssh-keygen", "-l", "-E", "sha256", "-f", p + ".pub"], stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout.split()[1]
    return t, b, fp


def mode(p):
    return stat.S_IMODE(os.lstat(p).st_mode)


def today():
    return time.strftime("%Y-%m-%d", time.gmtime())


@unittest.skipUnless(LINUX, "needs POSIX modes, a pseudo-terminal and ssh-keygen (Linux; not as root)")
class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.kd = tempfile.mkdtemp(prefix="bk_keys_")
        cls.ed1 = keygen(cls.kd, "ed25519", "ed1")
        cls.ed2 = keygen(cls.kd, "ed25519", "ed2")
        cls.ec1 = keygen(cls.kd, "ecdsa", "ec1")
        cls.trip = os.path.join(cls.kd, "trip")
        os.makedirs(cls.trip)
        cls.triplog = os.path.join(cls.kd, "trip.log")
        for b in BANNED:
            p = os.path.join(cls.trip, b)
            with open(p, "w") as fh:
                fh.write("#!/bin/sh\necho %s \"$@\" >> %s\nexit 1\n" % (b, cls.triplog))
            os.chmod(p, 0o755)
        # a stand-in for bin/hpcworker: what the gate hands on, word by word, and the variables it set
        cls.stub = os.path.join(cls.kd, "argv-stub")
        with open(cls.stub, "w") as fh:
            fh.write('#!/bin/bash\nfor a in "$@"; do printf "ARG:%s\\n" "$a"; done\n'
                     'printf "ENV:HPCW_GATE=%s\\n" "${HPCW_GATE:-}"; printf "ENV:SLOT=%s\\n" "${HPCW_GATE_SLOT:-}"\n'
                     'printf "ENV:BASH_ENV=%s\\n" "${BASH_ENV:-}"\nexit 42\n')
        os.chmod(cls.stub, 0o755)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.kd, ignore_errors=True)

    def setUp(self):
        self.td = tempfile.mkdtemp(prefix="bk_")
        cur = os.path.join(self.td, "shared", "current")
        self.g = G.Grid(self.td, profile_edit=lambda p: p.update(shared_install=cur, shared_state_dir=os.path.join(self.td, "state")))
        os.symlink("v" + G.CURRENT_VERSION, cur)
        self.current = cur
        self.tool = os.path.join(cur, "bin", "hpcworker")
        self.state = os.path.join(self.td, "state")
        self.g.state = self.state   # fakegrid's run-folder helpers read the state directory the profile names
        # the lab's copy as deploy_shared.sh leaves it: nothing in it writable by group or others
        for root, dirs, files in os.walk(os.path.join(self.td, "shared")):
            for n in dirs + files:
                p = os.path.join(root, n)
                if not os.path.islink(p):
                    os.chmod(p, mode(p) & ~0o022)
        os.chmod(self.g.home, 0o700)
        self.home = self.g.home
        if os.path.exists(self.triplog):
            os.remove(self.triplog)

    def tearDown(self):
        for root, dirs, files in os.walk(self.td):
            for d in dirs:
                try:
                    os.chmod(os.path.join(root, d), 0o700)
                except OSError:
                    pass
        os.chmod(self.td, 0o700)
        shutil.rmtree(self.td, ignore_errors=True)

    # ---- running it ----------------------------------------------------------------------------
    def env(self, extra=None):
        e = {"HOME": self.home, "HPCW_HOME": self.g.hpcw, "USER": "st1234", "LOGNAME": "st1234", "FAKE_SCHED_DIR": self.g.sched,
             "FAKE_CODE": G.CODE, "PATH": self.trip + ":" + self.g.bin + ":" + BASH_DIR + "/usr/bin:/bin"}
        e.update(extra or {})
        return e

    def person(self, *args, env=None, tool=None):
        """hpcworker as a person at a terminal: stdin is a pseudo-terminal"""
        import pty
        m, s = pty.openpty()
        try:
            r = subprocess.run([BASH, tool or self.tool] + list(args), stdin=s, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, env=self.env(env), timeout=60)
        finally:
            os.close(m)
            os.close(s)
        return r

    def session(self, *args, env=None, tool=None):
        """hpcworker as Beethoven runs it over the student's first ssh sign-in: no terminal, an ssh connection"""
        e = {"SSH_CONNECTION": "203.0.113.7 51234 141.217.136.64 22"}
        e.update(env or {})
        return subprocess.run([BASH, tool or self.tool] + list(args), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, env=self.env(e), timeout=120)

    def gate(self, cmd, env=None, args=(), stub=False, binary=False):
        """the forced command as sshd runs it: no terminal, SSH_ORIGINAL_COMMAND (None: unset)"""
        e = self.env(env)
        e["SSH_CONNECTION"] = "203.0.113.7 51234 141.217.136.64 22"
        if cmd is not None:
            e["SSH_ORIGINAL_COMMAND"] = cmd
        if stub:
            argv = [BASH, "-c", 'source "$1"; SELF="$2"; shift 2; cmd_gate "$@"', "bash", self.tool, self.stub] + list(args)
        else:
            argv = [BASH, self.tool, "gate"] + list(args)
        if binary:
            return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e, timeout=120)
        return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, env=e, timeout=120)

    def handed(self, r):
        return [l[4:] for l in r.stdout.splitlines() if l.startswith("ARG:")]

    def set_up_account(self):
        r = subprocess.run([BASH, self.tool, "install", "--shared", self.current, "--profile", "testsite", "--no-shell-path"],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           env=self.env({"PATH": self.g.bin + ":" + BASH_DIR + "/usr/bin:/bin"}), timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # ---- files -----------------------------------------------------------------------------------
    @property
    def ak(self):
        return os.path.join(self.home, ".ssh", "authorized_keys")

    def read_ak(self):
        with open(self.ak, "rb") as fh:
            return fh.read()

    def cmd(self):
        return 'command="%s/bin/hpcworker gate"' % self.current

    def ours(self):
        return [l for l in self.read_ak().decode().split("\n") if l.startswith("restrict," + self.cmd())]

    def seed(self, data, dmode=0o700, fmode=0o600):
        sd = os.path.join(self.home, ".ssh")
        os.makedirs(sd, exist_ok=True)
        os.chmod(sd, dmode)
        with open(self.ak, "wb") as fh:
            fh.write(data)
        os.chmod(self.ak, fmode)

    def our_line(self, key, date=None):
        return "restrict,%s %s %s beethoven-browser %s" % (self.cmd(), key[0], key[1], date or today())

    def no_trip(self):
        self.assertFalse(os.path.exists(self.triplog), "a banned program ran: " + (open(self.triplog).read() if os.path.exists(self.triplog) else ""))

    def site_profile(self, **changes):
        p = os.path.join(self.td, "shared", "v" + G.CURRENT_VERSION, "profiles", "testsite.json")
        os.chmod(p, 0o644)
        with open(p) as fh:
            d = json.load(fh)
        d.update(changes)
        with open(p, "w") as fh:
            json.dump(d, fh, indent=1)


class Add(Base):
    def test_from_beethovens_session(self):
        r = self.session("browser-key", "add", self.ec1[0], self.ec1[1])
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "HPCW-KEY added %s\n" % self.ec1[2], ""))
        self.assertEqual(mode(os.path.join(self.home, ".ssh")), 0o700)
        self.assertEqual(mode(self.ak), 0o600)
        self.assertEqual(self.read_ak().decode(), self.our_line(self.ec1) + "\n")
        self.assertFalse(os.path.exists(self.ak + ".beethoven-prev"))
        self.assertEqual(os.listdir(os.path.join(self.home, ".ssh")), ["authorized_keys"])
        self.assertFalse(os.path.exists(self.g.hpcw), "nothing else of the account's is touched")
        self.no_trip()

    def test_from_a_person_at_a_terminal(self):
        r = self.person("browser-key", "add", self.ed1[0], self.ed1[1])
        self.assertEqual((r.returncode, r.stdout), (0, "HPCW-KEY added %s\n" % self.ed1[2]), r.stderr)
        self.assertEqual(self.ours(), [self.our_line(self.ed1)])
        self.no_trip()

    def test_set_up_account_and_line_names_the_profiles_copy(self):
        self.set_up_account()
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # the line names the copy as the site profile spells it (the `current` link), never the numbered directory
        self.assertIn('command="%s/bin/hpcworker gate"' % self.current, self.read_ak().decode())
        self.assertNotIn("/v%s/" % G.CURRENT_VERSION, self.read_ak().decode())
        self.no_trip()

    def test_forms_of_the_key(self):
        ed, ec = self.ed1, self.ec1
        for args, k in (([ed[1]], ed), ([ed[0], ed[1], "test"], ed), ([ed[0], ed[1], ed[2][:14]], ed), ([ed[1], ed[2]], ed),
                        ([ec[1]], ec), ([ec[0], ec[1], ec[2][:13]], ec), ([ec[0], ec[1], "beethoven-browser"], ec), ([ec[0], ec[1], "a@b.c"], ec)):
            with self.subTest(args=args):
                if os.path.exists(self.ak):
                    os.remove(self.ak)
                r = self.session("browser-key", "add", *args)
                self.assertEqual((r.returncode, r.stdout), (0, "HPCW-KEY added %s\n" % k[2]), r.stderr)
                self.assertEqual(self.ours(), [self.our_line(k)])
        self.no_trip()

    def test_fingerprint_check(self):
        good = self.ed1[2]
        bad = "SHA256:" + ("A" if good[7] != "A" else "B") + good[8:14]
        r = self.session("browser-key", "add", self.ed1[0], self.ed1[1], bad)
        self.assertEqual((r.returncode, r.stdout), (2, "HPCW-KEY refused key the key does not match the fingerprint it came with. Nothing was changed.\n"))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".ssh")))
        b = self.ed1[1]
        typo = b[:40] + ("A" if b[40] != "A" else "B") + b[41:]
        r = self.session("browser-key", "add", "ssh-ed25519", typo, good[:14])
        self.assertEqual(r.returncode, 2)
        self.assertTrue(r.stdout.startswith("HPCW-KEY refused key "), r.stdout)

    def test_keeps_every_other_line(self):
        other = (b"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 st1234@warrior\n"
                 b"# a comment of the student's\n"
                 b"\n"
                 b'from="10.3.136.24",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample beethoven-login-setup st1234 2026-10-01\n'
                 b"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwn beethoven-browser 2026-01-01\n"
                 b'command="/bin/true" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther beethoven-browser 2026-01-01\n'
                 b'restrict,command="/elsewhere/bin/hpcworker gate" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINot beethoven-browser 2026-01-01 extra\n'
                 b"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICrlf crlf-line\r\n"
                 b"ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= last-line-without-newline")
        self.seed(other)
        r = self.session("browser-key", "add", self.ed1[0], self.ed1[1])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read_ak(), other + b"\n" + self.our_line(self.ed1).encode() + b"\n")
        with open(self.ak + ".beethoven-prev", "rb") as fh:
            self.assertEqual(fh.read(), other)
        self.assertEqual(mode(self.ak + ".beethoven-prev"), 0o600)
        self.no_trip()

    def test_again_and_replace(self):
        self.seed(b"ssh-rsa AAAAB3Nza mine\n")
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 0)
        st = os.stat(self.ak)
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual((r.returncode, r.stdout), (0, "HPCW-KEY added %s\n" % self.ed1[2]))
        self.assertEqual(os.stat(self.ak).st_ino, st.st_ino, "rewritten although nothing changed")
        r = self.session("browser-key", "add", self.ed2[1])
        self.assertEqual((r.returncode, r.stdout), (0, "HPCW-KEY added %s\n" % self.ed2[2]))
        self.assertEqual(self.read_ak().decode(), "ssh-rsa AAAAB3Nza mine\n" + self.our_line(self.ed2) + "\n")
        # the copy kept of the file it replaced holds the student's own lines and never the key it replaced
        with open(self.ak + ".beethoven-prev", "rb") as fh:
            self.assertEqual(fh.read(), b"ssh-rsa AAAAB3Nza mine\n")
        # an older line of ours (another date) for the same key: replaced by today's
        self.seed(("ssh-rsa AAAAB3Nza mine\n" + self.our_line(self.ed2, "2026-01-02") + "\n").encode())
        self.assertEqual(self.session("browser-key", "add", self.ed2[1]).returncode, 0)
        self.assertEqual(self.ours(), [self.our_line(self.ed2)])

    def test_two_of_ours_become_one(self):
        self.seed(("a-line 1\n" + self.our_line(self.ed1, "2026-01-01") + "\nb-line 2\n" + self.our_line(self.ec1, "2026-02-01") + "\nc-line 3\n").encode())
        self.assertEqual(self.session("browser-key", "add", self.ed2[1]).returncode, 0)
        self.assertEqual(self.read_ak().decode(), "a-line 1\nb-line 2\nc-line 3\n" + self.our_line(self.ed2) + "\n")

    def test_umask_000(self):
        r = subprocess.run([BASH, "-c", 'umask 000; exec bash "$0" browser-key add "$1"', self.tool, self.ed1[1]], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           env=self.env({"SSH_CONNECTION": "203.0.113.7 1 141.217.136.64 22"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(mode(os.path.join(self.home, ".ssh")), 0o700)
        self.assertEqual(mode(self.ak), 0o600)
        self.session("browser-key", "add", self.ed2[1])
        self.assertEqual(mode(self.ak + ".beethoven-prev"), 0o600)


class AddRefusals(Base):
    WHOLE = "HPCW-KEY refused key the key Beethoven sent did not come through whole. Nothing was changed.\n"

    def nothing_changed(self, before):
        if before is None:
            self.assertFalse(os.path.exists(self.ak))
        else:
            self.assertEqual(self.read_ak(), before)

    def test_hostile_keys(self):
        ed = self.ed1[1]
        ec = self.ec1[1]
        rnd = random.Random(7)
        blob = base64.b64decode(ec)
        bad_point = base64.b64encode(blob[:39] + b"\x04" + bytes(rnd.getrandbits(8) for _ in range(64))).decode()
        cases = [
            [], ["ssh-ed25519"], [""], ["AAAA"], [ed[:-1]], [ed + "A"], [ed[:-2] + "=="], [ed.replace("A", "!", 1)],
            ["ssh-rsa", "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7"], ["sk-ssh-ed25519@openssh.com", ed], ["ssh-ed25519", ec], ["ecdsa-sha2-nistp256", ed],
            ["ssh-dss", ed], [ed, "x", "y"], [ed, 'beethoven"'], [ed, "SHA256:abc"], [ed, "SHA256:" + "A" * 44],
            ['ssh-ed25519 %s x" ,command="/bin/sh' % ed], [ed + '",command="/bin/sh'], ['restrict,command="/bin/sh" ssh-ed25519', ed],
            [ed + "\nssh-ed25519 " + self.ed2[1]], ["ssh-ed25519\n", ed], [ed, "comment\nssh-ed25519 " + self.ed2[1]],
            [ed, "$(id)"], [ed, "`id`"], [ed, "a;b"], [bad_point], ["AAAA" + "B" * 64], ["A" * 5000],
            ["ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAI" + "é" * 43], [ed.lower()], ["--force", ed], [ed, "--login"],
        ]
        for before in (None, b"ssh-rsa AAAAB3Nza mine\n"):
            if before is not None:
                self.seed(before)
            for args in cases:
                with self.subTest(args=args, before=before is not None):
                    r = self.session("browser-key", "add", *args)
                    self.assertEqual((r.returncode, r.stdout), (2, self.WHOLE), r.stderr)
                    self.nothing_changed(before)
            if before is None:
                self.assertFalse(os.path.exists(os.path.join(self.home, ".ssh")))
        self.no_trip()

    def test_not_for_an_agent_a_job_a_pipeline_or_the_gate(self):
        for env in ({"CLAUDECODE": "1"}, {"BEETHOVEN_WORKER": "1"}, {"HPCW_AGENT": "1"}, {"CLAUDE_CODE_ENTRYPOINT": "cli"},
                    {"SLURM_JOB_ID": "40501234"}, {"HPCW_GATE": "1"}, {"HPCW_GATE": "1", "SSH_ORIGINAL_COMMAND": "version"}):
            with self.subTest(env=env):
                for run in (self.person, self.session):
                    r = run("browser-key", "add", self.ed1[1], env=env)
                    self.assertEqual(r.returncode, 2)
                    self.assertTrue(r.stdout.startswith("HPCW-KEY refused agent "), r.stdout)
        # no terminal and no ssh connection: a pipeline
        r = subprocess.run([BASH, self.tool, "browser-key", "add", self.ed1[1]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, universal_newlines=True, env=self.env())
        self.assertEqual(r.returncode, 2)
        self.assertTrue(r.stdout.startswith("HPCW-KEY refused agent "), r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".ssh")))
        self.no_trip()

    def test_home(self):
        os.chmod(self.home, 0o770)
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual((r.returncode, r.stdout), (3, "HPCW-KEY refused home other people can change your home folder, so the grid would ignore Beethoven's key. Ask your lab lead. Nothing was changed.\n"))
        os.chmod(self.home, 0o702)
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 3)
        os.chmod(self.home, 0o755)   # readable by others is fine: sshd's StrictModes asks only that no one else may write
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 0)
        real = os.path.join(self.td, "realhome")
        shutil.move(self.home, real)
        os.symlink(real, self.home)
        r = self.session("browser-key", "add", self.ed2[1])
        self.assertEqual(r.returncode, 3)
        self.assertIn("is a link to another folder", r.stdout)
        os.remove(self.home)
        shutil.move(real, self.home)

    def test_ssh_dir(self):
        sd = os.path.join(self.home, ".ssh")
        os.makedirs(sd)
        for m in (0o770, 0o707, 0o777):
            os.chmod(sd, m)
            with self.subTest(mode=oct(m)):
                r = self.session("browser-key", "add", self.ed1[1])
                self.assertEqual(r.returncode, 4)
                self.assertTrue(r.stdout.startswith("HPCW-KEY refused ssh-dir "), r.stdout)
                self.assertFalse(os.path.exists(self.ak))
                self.assertEqual(mode(sd), m, "the mode was changed")
        os.chmod(sd, 0o755)
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 0)
        self.assertEqual(mode(sd), 0o755, "an acceptable mode of the student's was changed")
        shutil.rmtree(sd)
        elsewhere = os.path.join(self.td, "elsewhere")
        os.makedirs(elsewhere, mode=0o700)
        os.symlink(elsewhere, sd)
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual(r.returncode, 4)
        self.assertEqual(os.listdir(elsewhere), [])

    def test_authorized_keys(self):
        before = b"ssh-rsa AAAAB3Nza mine\n"
        stuck = "HPCW-KEY refused authorized-keys your ~/.ssh/authorized_keys file could not be changed safely. Ask your lab lead. Nothing was changed.\n"
        for m in (0o620, 0o602, 0o666):
            self.seed(before, fmode=m)
            with self.subTest(mode=oct(m)):
                r = self.session("browser-key", "add", self.ed1[1])
                self.assertEqual((r.returncode, r.stdout), (7, stuck))
                self.assertEqual(self.read_ak(), before)
                self.assertEqual(mode(self.ak), m)
        os.remove(self.ak)
        target = os.path.join(self.td, "keys-elsewhere")
        with open(target, "wb") as fh:
            fh.write(before)
        os.chmod(target, 0o600)
        os.symlink(target, self.ak)
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 7)
        with open(target, "rb") as fh:
            self.assertEqual(fh.read(), before)
        self.assertTrue(os.path.islink(self.ak))
        os.remove(self.ak)
        os.makedirs(self.ak)
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 7)
        os.rmdir(self.ak)
        self.seed(b"ssh-rsa AAAA\x00B3Nza mine\n")
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 7)
        self.assertEqual(self.read_ak(), b"ssh-rsa AAAA\x00B3Nza mine\n")
        self.assertEqual(sorted(os.listdir(os.path.join(self.home, ".ssh"))), ["authorized_keys"], "a temporary file was left")

    def test_prev_is_a_link(self):
        before = b"ssh-rsa AAAAB3Nza mine\n"
        self.seed(before)
        target = os.path.join(self.td, "precious")
        with open(target, "wb") as fh:
            fh.write(b"do not touch\n")
        os.symlink(target, self.ak + ".beethoven-prev")
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 0)
        with open(target, "rb") as fh:
            self.assertEqual(fh.read(), b"do not touch\n")
        self.assertFalse(os.path.islink(self.ak + ".beethoven-prev"))
        with open(self.ak + ".beethoven-prev", "rb") as fh:
            self.assertEqual(fh.read(), before)

    def test_lock(self):
        sd = os.path.join(self.home, ".ssh")
        os.makedirs(sd, mode=0o700)
        lk = os.path.join(sd, ".beethoven-browser.lock")
        os.makedirs(lk)
        t0 = time.time()
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual(r.returncode, 7)
        self.assertGreaterEqual(time.time() - t0, 5)
        self.assertFalse(os.path.exists(self.ak))
        old = time.time() - 600
        os.utime(lk, (old, old))   # a leftover from a run that died: taken over
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 0)
        self.assertFalse(os.path.exists(lk))


class CopyTree(Base):
    """The forced command runs from the lab's copy: browser-key add refuses unless the copy's own folders
    and files can be changed by their owner alone, and every folder above it too (or is sticky)."""

    def refused_for(self, path, how):
        os.chmod(path, mode(path) | how)
        try:
            r = self.session("browser-key", "add", self.ed1[1])
            self.assertEqual(r.returncode, 8, r.stdout + r.stderr)
            self.assertEqual(r.stdout, "HPCW-KEY refused copy other people can change %s in the lab's copy of the grid tool, which your key would run. Ask your lab lead. Nothing was changed.\n" % path)
            self.assertFalse(os.path.exists(os.path.join(self.home, ".ssh")))
            c = self.session("browser-key", "check")
            self.assertEqual(c.returncode, 8)
            self.assertIn("copy: others than its owner may change %s\n" % path, c.stdout)
            self.assertTrue(c.stdout.endswith("HPCW-KEY check refused %s\n" % self.current), c.stdout)
        finally:
            os.chmod(path, mode(path) & ~how)

    def test_each_part_of_the_copy(self):
        v = os.path.join(self.td, "shared", "v" + G.CURRENT_VERSION)
        for path in (os.path.join(self.td, "shared"), v, os.path.join(v, "bin"), os.path.join(v, "lib"), os.path.join(v, "lib", "adapters"),
                     os.path.join(v, "jobs"), os.path.join(v, "profiles"), os.path.join(v, "bin", "hpcworker"), os.path.join(v, "lib", "browser_key.sh"),
                     os.path.join(v, "lib", "profile.py"), os.path.join(v, "lib", "adapters", "slurm.sh"), os.path.join(v, "jobs", "worker.sbatch.tpl"),
                     os.path.join(v, "profiles", "testsite.json"), os.path.join(v, "VERSION")):
            for how in (0o020, 0o002):
                with self.subTest(path=path, how=oct(how)):
                    self.refused_for(path, how)
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 0, "every mode put back: accepted")
        self.no_trip()

    def test_a_link_inside_the_copy(self):
        v = os.path.join(self.td, "shared", "v" + G.CURRENT_VERSION)
        os.symlink(os.path.join(self.td, "nowhere.sh"), os.path.join(v, "lib", "extra.sh"))
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual(r.returncode, 8)
        self.assertIn(os.path.join(v, "lib", "extra.sh"), r.stdout)

    def test_above_the_copy_is_refused_unless_sticky(self):
        # a group that may rename things in a folder above the copy could put another current/bin/hpcworker
        # there, which every enrolled key's forced command would run: refused, and said by check and diag
        os.chmod(self.td, 0o770)
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual(r.returncode, 8, r.stdout)
        self.assertEqual(r.stdout, "HPCW-KEY refused copy other people can rename things in %s, which holds the lab's copy of the grid tool your key would run. "
                                   "Ask your lab lead (hpcworker browser-key check says what to change). Nothing was changed.\n" % self.td)
        self.assertFalse(os.path.exists(os.path.join(self.home, ".ssh")))
        c = self.session("browser-key", "check")
        self.assertEqual((c.returncode, c.stdout), (8, "above the copy: others than its owner may rename things in %s (chmod +t or chmod go-w on it, by its owner)\n"
                                                       "HPCW-KEY check refused %s\n" % (self.td, self.current)))
        os.chmod(self.td, 0o1770)   # sticky: only an entry's owner may rename or remove it
        c = self.session("browser-key", "check")
        self.assertEqual((c.returncode, c.stdout), (0, "HPCW-KEY check ok %s\n" % self.current))
        self.assertEqual(self.session("browser-key", "add", self.ed1[1]).returncode, 0)
        os.chmod(self.td, 0o700)
        c = self.session("browser-key", "check")
        self.assertEqual((c.returncode, c.stdout), (0, "HPCW-KEY check ok %s\n" % self.current))

    def test_run_from_another_copy_than_the_profile_names(self):
        other = os.path.join(self.td, "other")
        G.copy_framework(other)
        for root, dirs, files in os.walk(other):
            for n in dirs + files:
                os.chmod(os.path.join(root, n), mode(os.path.join(root, n)) & ~0o022)
        self.set_up_account()
        r = self.session("browser-key", "add", self.ed1[1], tool=os.path.join(other, "bin", "hpcworker"))
        self.assertEqual((r.returncode, r.stdout), (8, "HPCW-KEY refused copy this must run from the lab's copy of the grid tool at %s. Nothing was changed.\n" % self.current))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".ssh")))

    def test_a_site_without_a_shared_copy(self):
        self.site_profile(shared_install="")
        v = os.path.join(self.td, "shared", "v" + G.CURRENT_VERSION)
        r = self.session("browser-key", "add", self.ed1[1], tool=os.path.join(v, "bin", "hpcworker"))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn('restrict,command="%s/bin/hpcworker gate" ' % v, self.read_ak().decode())


class Remove(Base):
    def test_remove(self):
        self.seed(("mine 1\n" + self.our_line(self.ed1) + "\nmine 2\n").encode())
        r = self.session("browser-key", "remove")
        self.assertEqual((r.returncode, r.stdout), (0, "HPCW-KEY removed\n"))
        self.assertEqual(self.read_ak(), b"mine 1\nmine 2\n")
        self.assertEqual(self.session("browser-key", "remove").stdout, "HPCW-KEY none\n")
        self.assertEqual(self.person("browser-key", "remove").stdout, "HPCW-KEY none\n")
        r = self.session("browser-key", "remove", "x")
        self.assertEqual(r.returncode, 2)
        r = self.session("browser-key", "remove", env={"CLAUDECODE": "1"})
        self.assertEqual(r.returncode, 2)
        self.no_trip()

    def test_only_ours_left(self):
        self.seed((self.our_line(self.ed1) + "\n").encode())
        self.assertEqual(self.session("browser-key", "remove").returncode, 0)
        self.assertEqual(self.read_ak(), b"")
        self.assertEqual(mode(self.ak), 0o600)


class GateLines(Base):
    def test_accepted_lines_and_exact_argv(self):
        self.set_up_account()
        cases = {
            "status worker": ["worker", "status", "--name", "worker", "--json", "--poll-floor", "60"],
            "watch w-2_x": ["worker", "watch", "--name", "w-2_x", "--json", "--minutes", "30", "--poll-floor", "60"],
            "stop worker": ["worker", "stop", "--name", "worker"],
            "restrict worker": ["worker", "restrict", "--name", "worker"],
            "connect worker testsite - default chain": ["connect", "--name", "worker", "--profile", "testsite", "--permission-mode", "default", "--login", "never"],
            "connect worker testsite %s plan no-chain" % IID: ["connect", "--name", "worker", "--profile", "testsite", "--permission-mode", "plan", "--consent", IID, "--no-chain", "--login", "never"],
            "connect a1 site-2 - acceptEdits chain": ["connect", "--name", "a1", "--profile", "site-2", "--permission-mode", "acceptEdits", "--login", "never"],
        }
        os.makedirs(os.path.join(self.state, "w-2_x"), exist_ok=True)   # a watch takes its slot only for a run that exists
        for cmd, want in cases.items():
            with self.subTest(cmd=cmd):
                r = self.gate(cmd, stub=True, env={"BASH_ENV": "/nonexistent/bashrc"})
                self.assertEqual(r.returncode, 42, r.stdout + r.stderr)
                got = self.handed(r)
                self.assertEqual(got, want)
                self.assertIn("ENV:HPCW_GATE=1", r.stdout)
                self.assertIn("ENV:BASH_ENV=\n", r.stdout, "the verb starts without BASH_ENV")
                for word in ("claude", "login-setup", "browser-key", "install", "--plain", "always", "fresh", "auto"):
                    self.assertNotIn(word, got)
                if got[0] == "connect":
                    self.assertEqual(got.count("--login"), 1)
                    self.assertEqual(got[-2:], ["--login", "never"], "never, and last")
                if got[:2] == ["worker", "watch"]:
                    self.assertRegex(r.stdout, r"ENV:SLOT=.*/state/\.gate/watch\.1\n")
        self.no_trip()

    def test_refusals(self):
        bad = [
            None, "", " ", "  ", "version ", " version", "version  x", "\tversion", "version\n", "version\nid", "version;id",
            "version && id", "version|id", "version $(id)", "version `id`", "version 'x'", 'version "x"', "version *", "version ?",
            "version [a]", "version ~", "version x", "status", "status worker extra", "status -worker", "status --name",
            "status ../x", "status w/x", "status " + "a" * 33, "status " + "a" * 65, "x" * 201, "claude login", "claude",
            "claude login --plain", "login", "login-setup", "browser-key add x", "browser-key remove", "install", "sh", "bash", "exec id", "id",
            "VERSION", "Version", "gate", "gate version", "worker status --name worker",
            "connect worker testsite - default", "connect worker testsite - default chain --login", "connect worker testsite - always chain",
            "connect worker testsite - default chain x", "connect worker Testsite - default chain", "connect worker testsite x default chain",
            "connect worker testsite %s0 default chain" % IID, "connect worker testsite - default chain-", "connect -worker testsite - default chain",
            "connect worker -testsite - default chain", "connect worker testsite -- default chain", "connect worker testsite - --login chain",
            "connect worker testsite --login default chain", "connect --login never worker testsite - default", "connect worker testsite - default --no-chain",
            "connect worker testsite - default-login chain", "connect worker testsite - bypassPermissions chain",
            "read worker", "read worker job.token", "read worker stop", "read worker rc.log", "read worker ../../.ssh/id_rsa", "read worker .ssh",
            "read worker status.json x", "read -x status.json", "read worker STATUS.JSON", "read worker job.sbatch", "forget x", "forget now",
            "status wé", "status ｗorker", "status worker\r", "status\x00worker", "watch", "watch -", "stop -", "restrict -",
        ]
        for cmd in bad:
            for env in ({}, {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}, {"LANG": "en_US.UTF-8"}):
                with self.subTest(cmd=cmd, env=env):
                    if cmd is not None and "\x00" in cmd:
                        continue   # an environment cannot carry a NUL byte; sshd would cut the command there
                    r = self.gate(cmd, env=env, stub=True)
                    self.assertEqual((r.returncode, r.stdout), (126, REFUSED), r.stderr)
        r = self.gate("version", args=("version",))
        self.assertEqual((r.returncode, r.stdout), (126, REFUSED))
        r = self.gate("version", args=("--anything",))
        self.assertEqual((r.returncode, r.stdout), (126, REFUSED))
        self.no_trip()

    def test_hostile_environment(self):
        # what an account's own ~/.bashrc or a client might leave: none of it changes what the gate accepts or hands on
        for env in ({"SHELLOPTS": "xtrace"}, {"BASHOPTS": "extglob"}, {"BASH_ENV": "/etc/passwd"}, {"ENV": "/etc/passwd"},
                    {"CDPATH": "/"}, {"GLOBIGNORE": "*"}, {"PROMPT_COMMAND": "id"}, {"IFS": "o"}, {"HPCW_GATE_SLOT": "/tmp/x"}):
            with self.subTest(env=env):
                r = self.gate("status worker", stub=True, env=env)
                self.assertEqual(self.handed(r), ["worker", "status", "--name", "worker", "--json", "--poll-floor", "60"], r.stdout + r.stderr)
                r = self.gate("version;id", stub=True, env=env)
                self.assertEqual((r.returncode, r.stdout), (126, REFUSED))

    def test_version(self):
        r = self.gate("version")
        self.assertEqual(r.returncode, 0, r.stderr)
        user = subprocess.run(["id", "-un"], stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()
        self.assertEqual(r.stdout, "HPCW-GATE ok %s never %s claude=unknown\n" % (G.CURRENT_VERSION, user))
        self.set_up_account()
        os.makedirs(os.path.join(self.state, "worker"))
        with open(os.path.join(self.state, "worker", "status.json"), "w") as fh:
            fh.write('{"state":"online","claude_login":{"loggedIn": true,"email":"a@b.c","subscriptionType":"max"}}\n')
        self.assertEqual(self.gate("version").stdout, "HPCW-GATE ok %s never %s claude=yes\n" % (G.CURRENT_VERSION, user))
        with open(os.path.join(self.state, "worker", "status.json"), "w") as fh:
            fh.write('{"state":"stopped","claude_login":{"loggedIn": false}}\n')
        self.assertTrue(self.gate("version").stdout.endswith(" claude=no\n"))
        self.site_profile(browser_key_days=30)
        self.seed((self.our_line(self.ed1, "2026-10-01") + "\n").encode())
        r = self.gate("version")
        self.assertEqual(r.stdout.split()[:4], ["HPCW-GATE", "ok", G.CURRENT_VERSION, "2026-10-31"], r.stdout + r.stderr)
        self.no_trip()

    def test_expiry(self):
        self.set_up_account()
        self.site_profile(browser_key_days=30)
        old = time.strftime("%Y-%m-%d", time.gmtime(time.time() - 31 * 86400 - 3600))
        edge = time.strftime("%Y-%m-%d", time.gmtime(time.time() - 30 * 86400))
        for date, expired in ((today(), False), (edge, False), (old, True), ("2026-02-30", True), ("0000-00-00", True)):
            with self.subTest(date=date):
                self.seed(("mine 1\n" + self.our_line(self.ed1, date) + "\nmine 2\n").encode())
                r = self.gate("version")
                if expired:
                    self.assertEqual((r.returncode, r.stdout), (125, "HPCW-KEY expired\n"))
                    self.assertEqual(self.read_ak(), b"mine 1\nmine 2\n")
                else:
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                    self.assertEqual(len(self.ours()), 1)
        self.seed((self.our_line(self.ed1, old) + "\n").encode())
        r = self.gate("connect worker testsite - default chain", stub=True)
        self.assertEqual((r.returncode, r.stdout), (125, "HPCW-KEY expired\n"))
        self.site_profile(browser_key_days=None)
        self.seed((self.our_line(self.ed1, "2020-01-01") + "\n").encode())
        self.assertEqual(self.gate("version").returncode, 0)
        self.no_trip()

    def test_read(self):
        self.set_up_account()
        wd = os.path.join(self.state, "worker")
        os.makedirs(wd)
        files = {"status.json": b'{"state":"online"}\n', "connection.json": b'{"job":"1"}\n', "node": b"asx15\n", "progress.log": b"one\ntwo\n"}
        for n, b in files.items():
            with open(os.path.join(wd, n), "wb") as fh:
                fh.write(b)
        with open(os.path.join(wd, "rc.log"), "wb") as fh:
            fh.write(b"Claude Code's own screen\n")
        for n, b in files.items():
            with self.subTest(file=n):
                r = self.gate("read worker " + n, binary=True)
                self.assertEqual((r.returncode, r.stdout), (0, b))
        self.assertEqual((self.gate("read worker rc.log").returncode, self.gate("read worker rc.log").stdout), (126, REFUSED))
        os.remove(os.path.join(wd, "node"))
        r = self.gate("read worker node")
        self.assertEqual((r.returncode, r.stdout, r.stderr), (1, "", "HPCW-GATE missing\n"))
        secret = os.path.join(self.td, "id_rsa")
        with open(secret, "w") as fh:
            fh.write("-----BEGIN OPENSSH PRIVATE KEY-----\n")
        os.symlink(secret, os.path.join(wd, "node"))
        r = self.gate("read worker node")
        self.assertEqual((r.returncode, r.stdout), (3, ""))
        os.remove(os.path.join(wd, "connection.json"))
        os.makedirs(os.path.join(wd, "connection.json"))
        self.assertEqual(self.gate("read worker connection.json").returncode, 3)
        with open(os.path.join(wd, "status.json"), "wb") as fh:
            fh.write(b"x" * 262145)
        r = self.gate("read worker status.json")
        self.assertEqual((r.returncode, r.stdout, r.stderr), (3, "", "HPCW-GATE too-large\n"))
        big = bytes(random.Random(1).getrandbits(8) for _ in range(300000))
        with open(os.path.join(wd, "progress.log"), "wb") as fh:
            fh.write(big)
        r = self.gate("read worker progress.log", binary=True)
        self.assertEqual((r.returncode, r.stdout), (0, big[-262144:]))
        os.symlink(self.home, os.path.join(self.state, "linked"))
        self.assertEqual(self.gate("read linked status.json").returncode, 3)
        self.assertEqual(self.gate("read nosuch status.json").returncode, 1)
        os.remove(os.path.join(self.g.hpcw, "profile.json"))
        self.assertEqual(self.gate("read worker status.json").returncode, 1)
        self.no_trip()

    def test_an_account_never_set_up(self):
        # nothing to watch, restrict or stop: each verb says so itself (not a refusal of the line), and no state is made
        for cmd in ("status worker", "watch worker", "restrict worker", "stop worker"):
            with self.subTest(cmd=cmd):
                r = self.gate(cmd)
                self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
                self.assertNotEqual(r.stdout, REFUSED)
                self.assertIn("no profile at", r.stderr)
        self.assertFalse(os.path.exists(self.state))
        r = self.gate("connect worker nosuchsite - default chain")
        self.assertEqual((r.returncode, r.stdout.splitlines()[-1].split()[:3]), (3, ["HPCW-STEP", "failed", "setup"]), r.stdout + r.stderr)
        self.assertFalse(os.path.exists(self.state))
        self.no_trip()

    def test_forget(self):
        self.seed(("mine 1\n" + self.our_line(self.ed1) + "\nmine 2\n").encode())
        r = self.gate("forget")
        self.assertEqual((r.returncode, r.stdout), (0, "HPCW-KEY forgotten\n"))
        self.assertEqual(self.read_ak(), b"mine 1\nmine 2\n")
        with open(self.ak + ".beethoven-prev", "rb") as fh:
            self.assertEqual(fh.read(), b"mine 1\nmine 2\n", "a forgotten key is not kept in the copy either")
        self.assertEqual(self.gate("forget").stdout, "HPCW-KEY none\n")
        shutil.rmtree(os.path.join(self.home, ".ssh"))
        elsewhere = os.path.join(self.td, "elsewhere")
        os.makedirs(elsewhere, mode=0o700)
        with open(os.path.join(elsewhere, "authorized_keys"), "w") as fh:
            fh.write(self.our_line(self.ed1) + "\n")
        os.symlink(elsewhere, os.path.join(self.home, ".ssh"))
        r = self.gate("forget")
        self.assertEqual((r.returncode, r.stdout), (7, "HPCW-KEY stuck\n"))
        with open(os.path.join(elsewhere, "authorized_keys")) as fh:
            self.assertEqual(fh.read(), self.our_line(self.ed1) + "\n")
        self.no_trip()


class GateCaps(Base):
    def caps(self):
        with open(os.path.join(self.state, ".gate", "caps")) as fh:
            return fh.read().splitlines()

    def test_three_names(self):
        self.set_up_account()
        for n in ("worker", "gpu", "x-1"):
            r = self.gate("connect %s testsite - default chain" % n, stub=True)
            self.assertEqual(r.returncode, 42, r.stdout)
        r = self.gate("connect fourth testsite - default chain", stub=True)
        self.assertEqual((r.returncode, r.stdout), (123, "HPCW-GATE limit names\n"))
        # a restrict of a name with no run takes no name (it is one of the hour's actions instead)
        self.assertEqual(self.gate("restrict fourth", stub=True).returncode, 42)
        self.assertEqual(self.gate("connect gpu testsite - default chain", stub=True).returncode, 42, "a name already used is fine")
        # a run that exists already may be marked restricted without taking a name
        os.makedirs(os.path.join(self.state, "made-by-hand"))
        self.assertEqual(self.gate("restrict made-by-hand", stub=True).returncode, 42)
        self.assertEqual([l.split()[:2] for l in self.caps() if l.startswith("name ")], [["name", "worker"], ["name", "gpu"], ["name", "x-1"]])
        for l in self.caps():
            if l.startswith("name "):
                self.assertLessEqual(abs(int(l.split()[2]) - time.time()), 120, l)
        self.assertEqual(mode(os.path.join(self.state, ".gate")), 0o700)
        self.assertEqual(mode(os.path.join(self.state, ".gate", "caps")), 0o600)
        # status, stop and read never take a name
        for c in ("status other", "stop other", "read other status.json"):
            self.assertNotEqual(self.gate(c, stub=True).stdout, "HPCW-GATE limit names\n")
        self.no_trip()

    def test_twelve_connects_an_hour(self):
        self.set_up_account()
        for i in range(12):
            self.assertEqual(self.gate("connect worker testsite - default chain", stub=True).returncode, 42, i)
        r = self.gate("connect worker testsite - default chain", stub=True)
        self.assertEqual((r.returncode, r.stdout), (123, "HPCW-GATE limit hourly\n"))
        self.assertEqual(len([l for l in self.caps() if l.startswith("connect ")]), 12)
        # an hour later they are forgotten
        now = int(time.time())
        with open(os.path.join(self.state, ".gate", "caps"), "w") as fh:
            fh.write("name worker\n" + "".join("connect %d\n" % (now - 3700 - i) for i in range(12)) + "connect garbage\nother line\n")
        self.assertEqual(self.gate("connect worker testsite - default chain", stub=True).returncode, 42)
        caps = self.caps()
        self.assertEqual([l.split()[:2] for l in caps], [["name", "worker"], ["connect", caps[1].split()[1]]])
        self.no_trip()

    def test_names_age_out_and_the_students_sign_in_clears_them(self):
        self.set_up_account()
        now = int(time.time())
        os.makedirs(os.path.join(self.state, ".gate"), mode=0o700)
        with open(os.path.join(self.state, ".gate", "caps"), "w") as fh:
            fh.write("name old1 %d\nname a %d\nname b %d\n" % (now - 8 * 86400, now - 60, now - 60))
        # a name last used more than seven days ago no longer counts: a third one fits
        self.assertEqual(self.gate("connect c testsite - default chain", stub=True).returncode, 42)
        self.assertEqual([l.split()[1] for l in self.caps() if l.startswith("name ")], ["a", "b", "c"])
        r = self.gate("connect d testsite - default chain", stub=True)
        self.assertEqual((r.returncode, r.stdout), (123, "HPCW-GATE limit names\n"))
        # the student's own sign-in (password and code) adds the key again: the names are forgotten, the hour's actions kept
        r = self.session("browser-key", "add", self.ed1[1])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual([l for l in self.caps() if l.startswith("name ")], [])
        self.assertEqual(len([l for l in self.caps() if l.startswith("connect ")]), 1)
        self.assertEqual(self.gate("connect d testsite - default chain", stub=True).returncode, 42)
        self.no_trip()

    def test_a_watch_of_no_run_takes_no_slot(self):
        self.set_up_account()
        for _ in range(3):
            r = self.gate("watch nosuch")
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn("no worker named nosuch", r.stderr)
        g = os.path.join(self.state, ".gate")
        self.assertEqual([n for n in (os.listdir(g) if os.path.isdir(g) else []) if n.startswith("watch.")], [])
        self.no_trip()

    def test_a_caps_file_that_is_a_link(self):
        self.set_up_account()
        os.makedirs(os.path.join(self.state, ".gate"), mode=0o700)
        target = os.path.join(self.td, "elsewhere")
        with open(target, "w") as fh:
            fh.write("keep\n")
        os.symlink(target, os.path.join(self.state, ".gate", "caps"))
        r = self.gate("connect worker testsite - default chain", stub=True)
        self.assertEqual((r.returncode, r.stdout), (123, "HPCW-GATE limit busy\n"))
        with open(target) as fh:
            self.assertEqual(fh.read(), "keep\n")

    def test_two_watches_at_once(self):
        self.set_up_account()
        os.makedirs(os.path.join(self.state, "worker"))   # a slot is taken only for a run that exists
        a = self.gate("watch worker", stub=True)
        b = self.gate("watch worker", stub=True)
        self.assertEqual((a.returncode, b.returncode), (42, 42))
        r = self.gate("watch worker", stub=True)
        self.assertEqual((r.returncode, r.stdout), (123, "HPCW-GATE limit watch\n"))
        # a slot older than the longest watch is a leftover, and is taken over
        old = time.time() - 40 * 60
        os.utime(os.path.join(self.state, ".gate", "watch.1"), (old, old))
        self.assertEqual(self.gate("watch worker", stub=True).returncode, 42)


@unittest.skipUnless(LINUX, "needs POSIX modes (Linux)")
class GateReal(Base):
    """The real verbs behind the gate, against the fake scheduler; nothing banned runs once the account's
    profile.env is there, and a watch gives its slot back when it ends."""

    def warm(self):
        self.set_up_account()
        e = self.env({"PATH": self.g.bin + ":" + BASH_DIR + "/usr/bin:/bin", "HPCW_PYTHON": REAL_PY})
        r = subprocess.run([BASH, self.tool, "worker", "list"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True, env=e)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.exists(os.path.join(self.g.hpcw, "profile.env")))

    def test_connect_status_watch_stop_without_python(self):
        self.warm()
        # the first submission renders the job file and writes the workspace guide, in bash: no python3
        r = self.gate("connect worker testsite %s default chain" % IID, env={"HPCW_PYTHON": REAL_PY})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], "HPCW-STEP setup ready")
        self.assertEqual(lines[1], "HPCW-STEP consent")
        self.assertTrue(lines[2].startswith("HPCW-STEP queued 40501234 new "), lines)
        self.assertEqual(lines[-1], "HPCW-STEP done")
        self.assertNotIn("signin", r.stdout)
        self.assertEqual([c.split()[0] for c in self.g.calls()], ["sbatch"], "no srun: never a sign-in")
        self.assertTrue(os.path.exists(os.path.join(self.state, "worker", "job.sbatch")))
        self.assertFalse(os.path.exists(os.path.join(self.state, "worker", "job.key")), "framework 11 renders afresh: no job.key")
        # from here on, the trip-wire's python3 is the only one on PATH: nothing may look for it
        st = self.gate("status worker")
        self.assertEqual(st.returncode, 0, st.stderr)
        j = json.loads(st.stdout)
        self.assertEqual((j["v"], j["run"], j["status"]["state"]), (1, "worker", "queued"))
        # a second status within the minute asks the scheduler nothing (the floor)
        n = len(self.g.calls())
        self.gate("status worker")
        self.assertEqual(len(self.g.calls()), n, self.g.calls())
        # the worker online: a watch ends at once, with its line, and gives the slot back
        s = self.g.status()
        s.update(state="online", environment_url="https://claude.ai/code?environment=env_01X", node="asx15")
        self.g.write_status(s)
        w = self.gate("watch worker")
        self.assertEqual(w.returncode, 0, w.stderr)
        last = json.loads(w.stdout.splitlines()[-1])
        self.assertEqual((last["event"], last["final"], last["status"]["state"]), ("status", True, "online"))
        self.assertEqual(os.listdir(os.path.join(self.state, ".gate")), ["caps"], "the watch slot is given back")
        sp = self.gate("stop worker", env={"HPCW_STOP_WAIT_S": "1", "HPCW_STOP_POLL_S": "1"})
        self.assertEqual(sp.returncode, 0, sp.stderr)
        self.assertIn("worker worker: stopped", sp.stdout)
        self.assertEqual(self.gate("restrict worker").returncode, 0)
        self.no_trip()

    def test_returning_connect_runs_no_python(self):
        self.warm()
        e = {"HPCW_PYTHON": REAL_PY}
        self.assertEqual(self.gate("connect worker testsite - default chain", env=e).returncode, 0)
        os.remove(self.triplog) if os.path.exists(self.triplog) else None
        self.g.jobs([])   # the job ended; the next connect submits again, from the job file kept
        r = self.gate("connect worker testsite - default chain")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("HPCW-STEP queued 40501235 new", r.stdout)
        self.no_trip()

    def test_signin_never_reached(self):
        self.warm()
        # whatever reaches connect under the gate, there is no sitting: --login always given by hand is overruled
        r = subprocess.run([BASH, self.tool, "connect", "--profile", "testsite", "--login", "always"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                           env=self.env({"HPCW_GATE": "1", "HPCW_PYTHON": REAL_PY, "PATH": self.g.bin + ":" + BASH_DIR + "/usr/bin:/bin"}))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("signin", r.stdout)
        self.assertNotIn("srun", " ".join(self.g.calls()))
        for args in (["claude", "login", "--plain"], ["claude", "login"], ["claude", "consent"]):
            r = subprocess.run([BASH, self.tool] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               universal_newlines=True, env=self.env({"SSH_ORIGINAL_COMMAND": "version", "HPCW_PYTHON": REAL_PY}))
            self.assertEqual(r.returncode, 1, args)
            self.assertIn("never runs through Beethoven's browser key", r.stdout + r.stderr)
        self.assertNotIn("srun", " ".join(self.g.calls()))


@unittest.skipUnless(LINUX, "needs ssh-keygen (Linux)")
class Fingerprint(Base):
    def test_matches_ssh_keygen(self):
        """bk_fp (coreutils) against ssh-keygen -l for 100 keys of both kinds, including digests with NUL bytes"""
        n = 0
        for i in range(50):
            for kind in ("ed25519", "ecdsa"):
                t, b, fp = keygen(self.td, kind, "k%d%s" % (i, kind))
                r = subprocess.run([BASH, "-c", 'source "$1"; bk_fp "$2"', "bash", self.tool, b], stdout=subprocess.PIPE, universal_newlines=True, env=self.env())
                self.assertEqual(r.stdout.strip(), fp)
                n += 1 if b"\x00" in hashlib.sha256(base64.b64decode(b)).digest() else 0

    def test_known_good_key_is_valid(self):
        r = subprocess.run([BASH, "-c", 'source "$1"; bk_keygen_fp "$BK_KNOWN_GOOD"', "bash", self.tool], stdout=subprocess.PIPE, universal_newlines=True, env=self.env())
        self.assertRegex(r.stdout.strip(), r"^SHA256:[A-Za-z0-9+/]{43}$")


if __name__ == "__main__":
    unittest.main()
