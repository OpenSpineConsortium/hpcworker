#!/bin/bash
# hpcworker framework 11, end to end against a real OpenSSH sshd run by this account on 127.0.0.1 (never
# the grid): StrictModes on, the grid's algorithms (aes-ctr, hmac-sha1, an RSA host key), and the fake
# scheduler of tests/fakegrid.py on the sessions' PATH.
#
#   HPCW_E2E_SSHD=/path/to/sshd bash framework/tests/e2e_sshd.sh      (default: ~/sshd-test/root/usr/sbin/sshd, then sshd on PATH)
#
# A "session" key with no options stands in for the student's first sign-in (password and code, which an
# unprivileged sshd cannot check): over it, a plain exec with no terminal, Beethoven's lines run as they
# will over the real first sign-in: browser-key add, connect with the Claude sign-in (the code on standard
# input), claude login --plain. Then the browser's key: it signs in, sshd runs only the gate, and the gate
# allows only its eight verbs. Everything lives in one folder under ~/sshd-test (StrictModes refuses a
# path through the world-writable /tmp), removed at the end; the sessions' HOME is a test HOME (sshd's
# SetEnv), and the test copy of hpcworker refuses any other HOME, so nothing of this account's own ~/.ssh
# or ~/.hpcworker is touched (their checksums are compared before and after). No key or config of the
# account's is used: every ssh runs with -F /dev/null, its own key, no agent and its own known_hosts.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FW=$(cd "$HERE/.." && pwd)
SSHD="${HPCW_E2E_SSHD:-$HOME/sshd-test/root/usr/sbin/sshd}"
[ -x "$SSHD" ] || SSHD=$(command -v sshd 2>/dev/null) || { echo "SKIP no sshd (set HPCW_E2E_SSHD)"; exit 0; }
# HPCW_E2E_BASH: run the copy under this bash (its first line, and first on the sessions' PATH), e.g. EL7's 4.2.46
B="${HPCW_E2E_BASH:-$(command -v bash)}"
BDIR=$(cd "$(dirname "$B")" && pwd)
USER_NAME=$(id -un)
fail=0; n=0
ok() { n=$((n + 1)); if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
mine_sum() { { cat "$HOME/.ssh/authorized_keys" 2>/dev/null; ls -la "$HOME/.ssh" "$HOME/.hpcworker" 2>/dev/null; } | sha256sum | cut -c1-16; }
BEFORE=$(mine_sum)

mkdir -p "$HOME/sshd-test" && chmod 700 "$HOME/sshd-test"
E=$(mktemp -d "$HOME/sshd-test/fw11-e2e.XXXXXX") || exit 1
cleanup() { [ -s "$E/sshd.pid" ] && kill "$(cat "$E/sshd.pid")" 2>/dev/null; sleep 0.3; chmod -R u+rwx "$E" 2>/dev/null; rm -rf "$E"; }
trap cleanup EXIT
chmod 700 "$E"
mkdir -p "$E/shared" "$E/home" "$E/state" "$E/host" "$E/cli" "$E/fakebin" "$E/sched"
chmod 700 "$E/home"
V=$(cat "$FW/VERSION")
mkdir -p "$E/shared/v$V"
for p in bin lib jobs profiles VERSION README.md; do cp -r "$FW/$p" "$E/shared/v$V/"; done
rm -rf "$E/shared/v$V/lib/__pycache__"
# the test copy's one difference: it refuses any HOME but the test's, and leaves a mark if asked to
{ printf '#!%s\n' "$B"
  printf 'case "$HOME" in %q/home) ;; *) echo "E2E-GUARD refused HOME=$HOME" >&2; touch %q/GUARD-FIRED; exit 99;; esac\n' "$E" "$E"
  tail -n +2 "$FW/bin/hpcworker"; } > "$E/shared/v$V/bin/hpcworker"
ln -s "v$V" "$E/shared/current"
python3 - "$E" "$HERE" <<'EOF'
import json, os, sys
e, here = sys.argv[1], sys.argv[2]
sys.path.insert(0, here)
import fakegrid as G
p = json.load(open(os.path.join(e, "shared", "current", "profiles", "wayne.json")))
p.update(site="e2esite", shared_install=e + "/shared/current", shared_state_dir=e + "/state", binds=[], claude_config_dir="$HOME/cfg", consent_markers=[])
json.dump(p, open(os.path.join(e, "shared", "current", "profiles", "e2esite.json"), "w"), indent=1)
for name, text in (("sbatch", G.FAKE_SBATCH), ("squeue", G.FAKE_SQUEUE), ("scancel", G.FAKE_SCANCEL), ("scontrol", G.FAKE_SCONTROL), ("srun", G.FAKE_SRUN)):
    with open(os.path.join(e, "fakebin", name), "w") as fh:
        fh.write(text)
    os.chmod(os.path.join(e, "fakebin", name), 0o755)
EOF
chmod -R go-w "$E/shared" "$E/fakebin"
H="$E/shared/current/bin/hpcworker"

# --- the server ----------------------------------------------------------------------------------------
ssh-keygen -q -t rsa -b 3072 -N '' -f "$E/host/ssh_host_rsa_key"
PORT=$(( 22300 + RANDOM % 600 ))
printf '%s\n' "Port $PORT" "ListenAddress 127.0.0.1" "HostKey $E/host/ssh_host_rsa_key" "PidFile $E/sshd.pid" \
  "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256" \
  "HostKeyAlgorithms rsa-sha2-512,rsa-sha2-256" \
  "PubkeyAcceptedAlgorithms ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256" \
  "Ciphers aes128-ctr,aes192-ctr,aes256-ctr" "MACs hmac-sha1" \
  "AuthorizedKeysFile $E/home/.ssh/authorized_keys" "StrictModes yes" \
  "PasswordAuthentication no" "KbdInteractiveAuthentication no" "UsePAM no" "PrintMotd no" \
  "Subsystem sftp internal-sftp" "AcceptEnv LANG LC_*" \
  "SetEnv HOME=$E/home HPCW_HOME=$E/home/.hpcworker PATH=$E/fakebin:$BDIR:/usr/bin:/bin FAKE_SCHED_DIR=$E/sched FAKE_CODE=GOODCODE#0123456789abcdef HPCW_PYTHON=$(command -v python3) HPCW_STOP_WAIT_S=2 HPCW_STOP_POLL_S=1" \
  "LogLevel DEBUG1" > "$E/sshd_config"
# an sshd unpacked from a package (.../root/usr/sbin/sshd) finds its libraries under that root
sr="${SSHD%/usr/sbin/sshd}"; SLD="${LD_LIBRARY_PATH:-}"
[ "$sr" != "$SSHD" ] && SLD="$sr/lib/x86_64-linux-gnu:$sr/usr/lib/x86_64-linux-gnu${SLD:+:$SLD}"
LD_LIBRARY_PATH="$SLD" "$SSHD" -t -f "$E/sshd_config" || { echo "FAIL sshd -t"; exit 1; }
LD_LIBRARY_PATH="$SLD" "$SSHD" -f "$E/sshd_config" -E "$E/sshd.log" || { echo "FAIL sshd start"; exit 1; }
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$E/sshd.pid" ] && break; sleep 0.2; done
printf '[127.0.0.1]:%s %s\n' "$PORT" "$(cut -d' ' -f1-2 "$E/host/ssh_host_rsa_key.pub")" > "$E/known_hosts"
echo "== sshd $(LD_LIBRARY_PATH="$SLD" "$SSHD" -V 2>&1 | head -1) on 127.0.0.1:$PORT, StrictModes yes; $("$B" --version | head -1)"

c() { # KEY [ssh options...] [user@host] COMMAND: OpenSSH's client, nothing of this account's own config, keys or agent
  local k="$1"; shift
  timeout 60 ssh -F /dev/null -p "$PORT" -i "$k" -o IdentitiesOnly=yes -o IdentityAgent=none -o PreferredAuthentications=publickey \
    -o UserKnownHostsFile="$E/known_hosts" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o BatchMode=yes \
    -o LogLevel=ERROR "$@"
}
T="$USER_NAME@127.0.0.1"
ssh-keygen -q -t ed25519 -N '' -C session -f "$E/cli/session"
ssh-keygen -q -t ecdsa -N '' -C browser -f "$E/cli/browser"
ssh-keygen -q -t ed25519 -N '' -C browser2 -f "$E/cli/browser2"
read -r BT BB _ < "$E/cli/browser.pub"
BFP=$(ssh-keygen -l -E sha256 -f "$E/cli/browser.pub" | awk '{print $2}')
# the stand-in for the first sign-in: an unrestricted line, as a password session is
mkdir -p "$E/home/.ssh" && chmod 700 "$E/home/.ssh"
cut -d' ' -f1-2 "$E/cli/session.pub" > "$E/home/.ssh/authorized_keys"; chmod 600 "$E/home/.ssh/authorized_keys"
# an account whose ~/.bashrc prints something (sshd's bash may read it before any command)
printf 'echo "bashrc says hello"\n' > "$E/home/.bashrc"

# 1. before the paste the browser's key is refused
out=$(c "$E/cli/browser" "$T" version 2>&1); rc=$?
[ $rc = 255 ] && [[ "$out" == *"Permission denied"* ]]; ok $? "before enrolment the browser's key is refused ($rc)"

# 2. Beethoven's first sign-in: browser-key add over a plain exec (no terminal, an ssh connection)
out=$(c "$E/cli/session" "$T" "bash '$H' browser-key add $BT $BB" < /dev/null 2>&1); rc=$?
echo "     the session said: $(printf '%s' "$out" | tr '\n' '|')"
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | grep '^HPCW-KEY ')" = "HPCW-KEY added $BFP" ]; ok $? "browser-key add over a plain exec: HPCW-KEY added <the key's fingerprint>"
line=$(grep beethoven-browser "$E/home/.ssh/authorized_keys")
echo "     the line: $line"
[[ "$line" == "restrict,command=\"$E/shared/current/bin/hpcworker gate\" ecdsa-sha2-nistp256 $BB beethoven-browser $(date -u +%Y-%m-%d)" ]]; ok $? "the line is exactly the restricted one, naming the current link"
[ "$(grep -c . "$E/home/.ssh/authorized_keys")" = 2 ] && head -1 "$E/home/.ssh/authorized_keys" | grep -q "^ssh-ed25519 "; ok $? "the session's own line is kept, first"

# 3. the browser's key signs in, and sshd runs the gate
out=$(c "$E/cli/browser" "$T" version 2>/dev/null); rc=$?
echo "     version -> $(printf '%s' "$out" | tr '\n' '|') (exit $rc)"
[ $rc = 0 ] && [ "$(printf '%s\n' "$out" | grep '^HPCW-GATE ')" = "HPCW-GATE ok $V never $USER_NAME claude=unknown" ]; ok $? "the key signs in; the gate answers version"
if printf '%s\n' "$out" | grep -q "bashrc says hello"; then echo "     (this bash read ~/.bashrc before the forced command: its line came first)"; fi
grep -q "Accepted publickey for $USER_NAME .*ECDSA $BFP" "$E/sshd.log"; ok $? "sshd: Accepted publickey for the browser's key"
grep -q "Starting session: forced-command (key-option) '$H gate'" "$E/sshd.log"; ok $? "sshd: forced-command (key-option) '<current>/bin/hpcworker gate'"
# our line is the file's second (the session's unrestricted line is the first, with every option sshd grants)
opts=$(grep -o 'authorized_keys:2: key options: .*' "$E/sshd.log" | sort -u)
echo "     sshd: $(printf '%s' "$opts" | tr '\n' '|')"
[ -n "$opts" ] && [[ "$opts" == *"key options: command"* ]] && ! printf '%s\n' "$opts" | grep -q -E 'agent-forwarding|port-forwarding|pty|user-rc|x11-forwarding'
ok $? "restrict as sshd reads our line: command only; no agent or port forwarding, no pty, no user-rc, no X11"

# 4. hostile lines through the real sshd: every one refused by the gate, exit 126
for cmd in 'version; id' 'version && id' '$(id)' '`id`' 'id' 'sh' 'bash -i' 'claude login' 'claude login --plain' 'login-setup' \
           'browser-key add x' 'browser-key remove' 'connect worker e2esite - default chain --login always' 'connect worker e2esite - default --login' \
           'read worker ../../.ssh/authorized_keys' 'read worker rc.log' 'read worker job.token' 'status worker|id' $'version\nid' \
           'cat .ssh/authorized_keys' 'scp -t /tmp' 'rsync --server . /tmp' 'internal-sftp' 'gate version' "worker status --name worker"; do
  out=$(c "$E/cli/browser" "$T" "$cmd" < /dev/null 2>/dev/null); rc=$?
  [ $rc = 126 ] && [ "$(printf '%s\n' "$out" | grep -v 'bashrc says')" = "HPCW-GATE refused" ]; ok $? "refused: $(printf '%q' "$cmd")"
done
out=$(c "$E/cli/browser" "$T" < /dev/null 2>/dev/null); rc=$?
[ $rc = 126 ]; ok $? "no command at all (a shell asked for): refused ($rc)"
out=$(timeout 30 sftp -F /dev/null -P "$PORT" -i "$E/cli/browser" -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile="$E/known_hosts" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o BatchMode=yes "$T" < /dev/null 2>&1); rc=$?
[ $rc != 0 ]; ok $? "sftp: refused ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80))"
out=$(c "$E/cli/browser" -tt "$T" version 2>&1 < /dev/null | tr -d '\r')
grep -q "Allocating a pty not permitted for this connection" "$E/sshd.log"; ok $? "a pty is refused by restrict"
n0=$(grep -c "refused local port forward" "$E/sshd.log")
c "$E/cli/browser" -W "127.0.0.1:$PORT" "$T" < /dev/null > /dev/null 2>&1
[ "$(grep -c "refused local port forward" "$E/sshd.log")" -gt "$n0" ]; ok $? "stdio forwarding (-W) refused, and sshd logs it"
out=$(LC_ALL=C.UTF-8 c "$E/cli/browser" -o SendEnv=LC_ALL "$T" $'status w\xc3\xb6rker' 2>/dev/null); rc=$?
[ $rc = 126 ]; ok $? "LC_ALL from the client, a non-ASCII name: refused"

# 5. Beethoven's first sign-in again: connect with the Claude sign-in, the code on standard input, no terminal
out=$(printf 'GOODCODE#0123456789abcdef\n' | c "$E/cli/session" "$T" "exec bash '$H' connect --profile e2esite --consent 0123456789abcdef0123456789abcdef --login always" 2>&1); rc=$?
echo "     connect over the session -> exit $rc: $(printf '%s' "$out" | grep -E '^HPCW-STEP|^SIGNED' | tr '\n' '|')"
[ $rc = 0 ] && printf '%s\n' "$out" | grep -qx "HPCW-STEP signed-in st1234@wayne.edu max" && printf '%s\n' "$out" | grep -qx "HPCW-STEP done"; ok $? "connect over a plain exec: the sitting signs in with the code from standard input"
! printf '%s' "$out" | grep -q "GOODCODE"; ok $? "the code is never written back"
grep '^srun ' "$E/sched/calls" | tail -1 | grep -qv -- '--pty'; ok $? "srun was asked for no --pty ($(grep '^srun ' "$E/sched/calls" | tail -1 | cut -c1-90))"

# 6. the gate's own verbs, through the browser's key
out=$(c "$E/cli/browser" "$T" "status worker" 2>/dev/null); rc=$?
st=$(printf '%s\n' "$out" | grep '^{"v":1' | head -1)
[ $rc = 0 ] && printf '%s' "$st" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["run"]=="worker" and d["status"]["state"]=="queued"'; ok $? "status worker: one JSON line, queued"
out=$(c "$E/cli/browser" "$T" "read worker progress.log" 2>/dev/null); rc=$?
[ $rc = 0 ] && printf '%s\n' "$out" | grep -q "Asked the grid for a computer"; ok $? "read worker progress.log"
ln -s "$E/home/.ssh/authorized_keys" "$E/state/worker/node"
out=$(c "$E/cli/browser" "$T" "read worker node" 2>/dev/null); rc=$?
[ $rc = 3 ] && [ -z "$(printf '%s\n' "$out" | grep -v 'bashrc says')" ]; ok $? "read of a planted link to authorized_keys: nothing ($rc)"
rm -f "$E/state/worker/node"
n_srun=$(grep -c '^srun ' "$E/sched/calls")
out=$(c "$E/cli/browser" "$T" "connect worker e2esite - default chain" 2>/dev/null); rc=$?
echo "     connect through the gate -> exit $rc: $(printf '%s' "$out" | grep '^HPCW-STEP' | tr '\n' '|')"
[ $rc = 0 ] && printf '%s\n' "$out" | grep -qx "HPCW-STEP done" && ! printf '%s' "$out" | grep -q "signin"; ok $? "connect through the gate: done, no sign-in step"
[ "$(grep -c '^srun ' "$E/sched/calls")" = "$n_srun" ]; ok $? "connect through the gate: no srun"
for nm in gpu third; do c "$E/cli/browser" "$T" "connect $nm e2esite - default no-chain" > /dev/null 2>&1; done
out=$(c "$E/cli/browser" "$T" "connect fourth e2esite - default chain" 2>/dev/null); rc=$?
[ $rc = 123 ] && printf '%s\n' "$out" | grep -qx "HPCW-GATE limit names"; ok $? "the fourth worker name: HPCW-GATE limit names ($rc)"
# a watch of a worker that comes online: its lines, then the end, and its slot given back
python3 - "$E/state/worker/status.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.update(state="online", node="asx15", environment_url="https://claude.ai/code?environment=env_01X")
open(p + ".t", "w").write(json.dumps(d) + "\n")
import os; os.replace(p + ".t", p)
EOF
out=$(c "$E/cli/browser" "$T" "watch worker" 2>/dev/null); rc=$?
last=$(printf '%s\n' "$out" | grep '^{"v":1' | tail -1)
[ $rc = 0 ] && printf '%s' "$last" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["event"]=="status" and d["final"] is True and d["status"]["state"]=="online"'; ok $? "watch worker: ends online, final"
[ ! -e "$E/state/.gate/watch.1" ] && [ ! -e "$E/state/.gate/watch.2" ]; ok $? "the watch slot is given back"
# a watch whose reader goes away: the channel closed after the first line; the watch ends and its slot comes back
python3 - "$E/state/worker/status.json" <<'EOF'
import json, sys, os
p = sys.argv[1]
d = json.load(open(p)); d.update(state="running", environment_url="")
open(p + ".t", "w").write(json.dumps(d) + "\n"); os.replace(p + ".t", p)
EOF
c "$E/cli/browser" "$T" "watch worker" 2>/dev/null | head -c 1 > /dev/null
for _ in $(seq 1 30); do [ -e "$E/state/.gate/watch.1" ] || break; sleep 1; done
[ ! -e "$E/state/.gate/watch.1" ]; ok $? "a watch whose channel closed ends, and gives its slot back"
pgrep -f "$E/shared/.*hpcworker.* worker watch" > /dev/null; [ $? != 0 ]; ok $? "no watch of this test left running (a watch of another session's copy is not this test's)"
out=$(c "$E/cli/browser" "$T" "stop worker" 2>/dev/null); rc=$?
[ $rc = 0 ] && printf '%s\n' "$out" | grep -q "^worker worker: stopped"; ok $? "stop worker"

# 7. a second computer: its key replaces the first (added over the session, as Beethoven would)
read -r B2T B2B _ < "$E/cli/browser2.pub"
c "$E/cli/session" "$T" "bash '$H' browser-key add $B2T $B2B" < /dev/null > /dev/null 2>&1
c "$E/cli/browser" "$T" version > /dev/null 2>&1; [ $? = 255 ]; ok $? "the first browser's key is refused once the second is added"
out=$(c "$E/cli/browser2" "$T" version 2>/dev/null); printf '%s\n' "$out" | grep -q "^HPCW-GATE ok "; ok $? "the second browser's key (ed25519) signs in"

# 8. forget, through the key itself
out=$(c "$E/cli/browser2" "$T" forget 2>/dev/null)
printf '%s\n' "$out" | grep -qx "HPCW-KEY forgotten"; ok $? "forget"
c "$E/cli/browser2" "$T" version > /dev/null 2>&1; [ $? = 255 ]; ok $? "after forget the key is refused"
[ "$(grep -c . "$E/home/.ssh/authorized_keys")" = 1 ]; ok $? "only the session's own line is left"

# 9. guards
[ ! -e "$E/GUARD-FIRED" ]; ok $? "the HOME guard never fired (sshd's SetEnv HOME reached every command)"
AFTER=$(mine_sum)
[ "$BEFORE" = "$AFTER" ]; ok $? "this account's own ~/.ssh and ~/.hpcworker unchanged ($BEFORE)"
echo "== sshd log, counts"
grep -E "Accepted publickey|forced-command|refused|Failed publickey|Authentication refused|bad ownership|pty not permitted" "$E/sshd.log" \
  | sed -E -e 's/^.*sshd\[[0-9]+\]: //' -e 's/ port [0-9]+/ port N/g' -e 's/fw11-e2e\.[A-Za-z0-9]+/fw11-e2e.X/g' -e 's/ id [0-9]+$//' -e 's/SHA256:[A-Za-z0-9+\/]+/SHA256:.../' | sort | uniq -c | sort -rn | head -12
echo "== $n checks"
[ $fail = 0 ] && echo "E2E ALL OK" || echo "E2E FAILURES"
exit $fail
