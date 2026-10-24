#!/usr/bin/env bash
# Tests for the grid runner's ssh gate: tools/grid_gate.sh (the forced command) and
# tools/grid_runner.sh --gate-key and --gate-off (its line in ~/.ssh/authorized_keys). Linux only, as
# an ordinary account (sshd's rules and the gate's own refuse root); nothing reaches GitHub, a
# scheduler or the grid. Everything happens in a temporary folder under /tmp: HOME is there, the gate
# runs from copies of the clone there, and the gate's own calls reach a stand-in grid_runner.sh that
# writes down its arguments and answers as the test says. --gate-key and --gate-off are typed at a
# terminal, which script(1) gives them. The checks: each word and what it runs; each refusal (another
# word, an argument, an injected ;, $(...), backquote and newline, an overlong word, no word, a line
# --gate-key did not write); the 60-second floor; the log; the clone that others may change; and the
# line --gate-key writes, replaces and --gate-off takes out, every other line kept. tools/tests/
# test_grid_runner.sh runs this file at its end. KEEP_T=1 keeps the temporary folder.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
# as root nothing here can hold (sshd's rules and --gate-key refuse it), so it says it skipped; CI runs as an ordinary account
[ "$(id -u)" != 0 ] || { echo "SKIPPED: run as an ordinary account; the gate's key line refuses root"; exit 0; }
command -v script >/dev/null 2>&1 || { echo "script (util-linux) is needed: --gate-key runs only at a terminal"; exit 1; }
T=$(mktemp -d /tmp/grid_gate_test.XXXXXX) || exit 1
T=$(cd "$T" && pwd -P)
cleanup() { chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
if [ -n "${KEEP_T:-}" ]; then echo "keeping $T"; else trap cleanup EXIT; fi
umask 022
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT AI_AGENT
unset SLURM_JOB_ID PBS_JOBID LSB_JOBID HPCW_GATE SSH_ORIGINAL_COMMAND HPCW_RUNNER_DIR HPCW_RUNNER_PARTITION HPCW_RUNNER_QOS
export HOME="$T/home" USER=${USER:-$(id -un)}
mkdir -p "$HOME" && chmod 700 "$HOME"
GH_REPO=OpenSpineConsortium/symphony-template
RD="$T/runner"; CH="$RD/OpenSpineConsortium-symphony-template"
AK="$HOME/.ssh/authorized_keys"
KEY1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCj/iayuSj3Fidk+gybZFVkRGUgZuPSuVKeM+iqcGM2 greg@dispatch"   # throwaway public keys; no private half was kept
KEY2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGbJxR6PcThbt1zKO5gTJpw8l2X1yMHnD0yqrpQAQAAa"
KEY3="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMD"
KEY4="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"

# the clone as a person keeps it: tools/ and the framework's reader and profiles
C="$T/clone"
mkdir -p "$C/tools" "$C/framework"
cp "$REPO"/tools/grid_gate.sh "$REPO"/tools/grid_runner.sh "$REPO"/tools/grid_runner.sbatch "$REPO"/tools/grid_runner_install.sbatch "$C/tools/"
cp -R "$REPO/framework/lib" "$REPO/framework/profiles" "$C/framework/"
chmod 755 "$C/tools/grid_gate.sh"
# a second clone whose grid_runner.sh stands in: it writes down its arguments and what of its
# environment matters, and answers with STUB_OUT and STUB_RC
S="$T/stub"
mkdir -p "$S/tools" "$S/framework/lib" "$S/framework/profiles"
cp "$REPO/tools/grid_gate.sh" "$S/tools/"; chmod 755 "$S/tools/grid_gate.sh"
# (the gate hands grid_runner.sh an environment of its own, so the stand-in reads its answer from files
# beside it: stub.out and stub.rc)
cat > "$S/tools/grid_runner.sh" <<'EOF'
#!/bin/bash
d=$(cd "$(dirname "$0")/.." && pwd)
{ printf '%s\n' "$*"; printf 'HPCW_GATE=%s GH_TOKEN=%s BASH_ENV=%s LANG=%s SSH=%s\n' "${HPCW_GATE:-}" "${GH_TOKEN:-}" "${BASH_ENV:-}" "${LANG:-}" "${SSH_CONNECTION:-}${SSH_ORIGINAL_COMMAND:-}"; } >> "$d/stub.calls"
[ -t 0 ] && echo "stdin is a terminal"
cat "$d/stub.out" 2>/dev/null
exit "$(cat "$d/stub.rc" 2>/dev/null || echo 0)"
EOF
STUB_CALLS="$S/stub.calls"; : > "$STUB_CALLS"
stub() { printf '%s\n' "$1" > "$S/stub.out"; echo "$2" > "$S/stub.rc"; }
unstub() { rm -f "$S/stub.out" "$S/stub.rc"; }

pass=0 fail=0 OUT="" RC=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }
t() { local d=$1; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
has() { printf '%s\n' "$OUT" | grep -E -- "$1" >/dev/null; }
lacks() { ! has "$1"; }
rc_is() { [ "$RC" = "$1" ]; }
calls() { cat "$STUB_CALLS"; }
n_calls() { grep -c -- '--repo' "$STUB_CALLS"; }
LINE_ARGS=(--site wayne --runner-dir "$RD" --repo "$GH_REPO" --hours 6 --gres gpu:1)
# the gate as sshd runs a forced command: the word in SSH_ORIGINAL_COMMAND, no terminal, the clock
# forgotten first unless KEEP_CLOCK is set
gate() { # WORD|-unset [ARGS...]
  local w=$1; shift
  [ -n "${KEEP_CLOCK:-}" ] || rm -f "$CH/gate.last"
  if [ "$w" = -unset ]; then OUT=$(env -u SSH_ORIGINAL_COMMAND SSH_CONNECTION="192.0.2.7 50000 10.0.0.1 22" GH_TOKEN=gho_marker BASH_ENV="$T/bash_env" LANG=xx_client bash "$S/tools/grid_gate.sh" "$@" < /dev/null 2>&1)
  else OUT=$(env SSH_ORIGINAL_COMMAND="$w" SSH_CONNECTION="192.0.2.7 50000 10.0.0.1 22" GH_TOKEN=gho_marker BASH_ENV="$T/bash_env" LANG=xx_client bash "$S/tools/grid_gate.sh" "$@" < /dev/null 2>&1); fi
  RC=$?
}
printf 'echo BASH_ENV_WAS_READ >> "%s/bash_env.read"\n' "$T" > "$T/bash_env"
# --gate-key or --gate-off as a person types them, at a terminal
# (the exit code through a file: util-linux 2.23's script, CentOS 7's, does not hand it back)
typed() { # ARGS...: grid_runner.sh from the real clone, through script(1)
  printf '#!/bin/bash\ncd %q && bash tools/grid_runner.sh' "$C" > "$T/typed.sh"
  printf ' %q' "$@" >> "$T/typed.sh"; printf '; echo $? > %q\n' "$T/typed.rc" >> "$T/typed.sh"
  typed_run
}
typed_run() { rm -f "$T/typed.rc"; OUT=$(script -qc "bash $T/typed.sh" /dev/null 2>&1 | tr -d '\r'); RC=$(cat "$T/typed.rc" 2>/dev/null || echo none); }

echo "== the words"
gate status "${LINE_ARGS[@]}"
t "status runs grid_runner.sh --status for the line's repository" bash -c "tail -2 '$STUB_CALLS' | head -1 | grep -qx -- '--status --repo $GH_REPO --runner-dir $RD --site wayne'"
t "  and says it ended well" has '^HPCW-GRID-GATE status ok$'
t "  with HPCW_GATE set, the client's GH_TOKEN, BASH_ENV, LANG and ssh variables gone, stdin no terminal" bash -c "tail -1 '$STUB_CALLS' | grep -qx 'HPCW_GATE=1 GH_TOKEN= BASH_ENV= LANG= SSH=' && ! grep -q 'terminal' <<< \"\$1\"" _ "$OUT"
gate start "${LINE_ARGS[@]}"
t "start runs --start with the line's size" bash -c "tail -2 '$STUB_CALLS' | head -1 | grep -qx -- '--start --repo $GH_REPO --runner-dir $RD --site wayne --hours 6 --gres gpu:1'"
t "  and exits 0" rc_is 0
gate stop "${LINE_ARGS[@]}"
t "stop runs --stop, never --now" bash -c "tail -2 '$STUB_CALLS' | head -1 | grep -qx -- '--stop --repo $GH_REPO --runner-dir $RD --site wayne'"
stub "grid_runner: a chain for $GH_REPO is already queued or running (job 41 RUNNING); tools/grid_runner.sh --stop --repo $GH_REPO ends it" 1; gate start "${LINE_ARGS[@]}"
t "start on a chain already running is no failure" rc_is 0
t "  and says running" has '^HPCW-GRID-GATE running$'
date > "$CH/STOP"; gate start "${LINE_ARGS[@]}"
t "start on a chain that is stopping is a failure, not a chain started" bash -c "[ '$RC' = 75 ] && printf '%s' \"\$1\" | grep -q 'the chain is stopping'" _ "$OUT"
rm -f "$CH/STOP"
stub "grid_runner: sbatch refused the chain's first job: no partition" 1; gate start "${LINE_ARGS[@]}"
t "start that fails passes the failure on" rc_is 1
t "  with grid_runner's words" has 'sbatch refused'
t "  and the gate's" has '^HPCW-GRID-GATE start failed 1$'
unstub

echo "== the accounts words (framework 21)"
# a stand-in hpcworker in the stub clone: it writes down its arguments, its stdin and what of its environment matters
mkdir -p "$S/framework/bin" "$S/framework/jobs"
cat > "$S/framework/bin/hpcworker" <<'EOF2'
#!/bin/bash
d=$(cd "$(dirname "$0")/../.." && pwd)
in=""; [ -t 0 ] || in=$(head -c 200)
printf '%s|stdin=%s|HPCW_GATE=%s GRID=%s SSH=%s\n' "$*" "$in" "${HPCW_GATE:-}" "${HPCW_GRID_GATE:-}" "${SSH_ORIGINAL_COMMAND:-}" >> "$d/hw.calls"
case "$*" in "accounts list --json") echo '{"v":1,"current":"1","accounts":[]}';; *) echo "HPCW-ACCOUNTS $2 done";; esac
EOF2
chmod 755 "$S/framework/bin/hpcworker"; HW_CALLS="$S/hw.calls"; : > "$HW_CALLS"
acct() { rm -f "$CH/accounts.last" "$CH/accounts.sched"; gate "$@"; }
acct accounts "${LINE_ARGS[@]}"
t "accounts runs hpcworker accounts list --json from the clone" bash -c "tail -1 '$HW_CALLS' | grep -q '^accounts list --json|stdin=|HPCW_GATE= GRID=1 SSH=\$'"
t "  and prints it as one HPCW-ACCOUNTS-JSON line" has '^HPCW-ACCOUNTS-JSON \{"v":1,"current":"1","accounts":\[\]\}$'
t "  and ends well" has '^HPCW-GRID-GATE accounts ok$'
acct "accounts use 2" "${LINE_ARGS[@]}"
t "use N runs accounts use N, then the list" bash -c "tail -2 '$HW_CALLS' | head -1 | grep -q '^accounts use 2|' && tail -1 '$HW_CALLS' | grep -q '^accounts list --json|'"
acct "accounts login 3" "${LINE_ARGS[@]}"
t "login N is the detached sitting" bash -c "tail -2 '$HW_CALLS' | head -1 | grep -q '^accounts login 3 --detach --wait 45|'"
OUT=$(rm -f "$CH/accounts.last"; printf 'AbCdEf123456_-#st9\n' | env SSH_ORIGINAL_COMMAND="accounts code 3" bash "$S/tools/grid_gate.sh" "${LINE_ARGS[@]}" 2>&1); RC=$?
t "code N takes the code on stdin and hands it on stdin, never in arguments" bash -c "[ '$RC' = 0 ] && grep -q '^accounts code 3 - --wait 25|stdin=AbCdEf123456_-#st9|' '$HW_CALLS'"
t "  and never into the log" bash -c "! grep -q AbCdEf '$CH/gate.log'"
OUT=$(rm -f "$CH/accounts.last"; printf 'bad code;id\n' | env SSH_ORIGINAL_COMMAND="accounts code 3" bash "$S/tools/grid_gate.sh" "${LINE_ARGS[@]}" 2>&1); RC=$?
t "a code that is not one is refused" bash -c "[ '$RC' = 126 ] && printf '%s' \"\$1\" | grep -q 'refused code'" _ "$OUT"
acct "accounts start 2 team-b" "${LINE_ARGS[@]}"
t "start N NAME runs accounts start N NAME (framework 22), then the list" bash -c "tail -2 '$HW_CALLS' | head -1 | grep -q '^accounts start 2 team-b|' && tail -1 '$HW_CALLS' | grep -q '^accounts list --json|'"
acct "accounts stop team-b" "${LINE_ARGS[@]}"
t "stop NAME runs accounts stop NAME" bash -c "tail -2 '$HW_CALLS' | head -1 | grep -q '^accounts stop team-b|'"
acct "accounts log login 2" "${LINE_ARGS[@]}"
t "log login N runs accounts log login N (framework 23)" bash -c "tail -2 '$HW_CALLS' | head -1 | grep -q '^accounts log login 2|'"
acct "accounts log worker team-b" "${LINE_ARGS[@]}"
t "log worker NAME runs accounts log worker NAME" bash -c "tail -2 '$HW_CALLS' | head -1 | grep -q '^accounts log worker team-b|'"
acct "accounts log usage" "${LINE_ARGS[@]}"
t "log usage runs accounts log usage" bash -c "tail -2 '$HW_CALLS' | head -1 | grep -q '^accounts log usage|'"
for w in 'accounts use 0' 'accounts use 33' 'accounts use 2 3' 'accounts auto maybe' 'accounts usage now' 'accounts code 3 ABCDEFGH123' 'accounts;id' 'accounts list' 'accounts  use 2' 'accounts use 02' 'accounts start 33' 'accounts start 2 a;b' 'accounts stop' 'accounts stop a b' 'accounts log' 'accounts log login 33' 'accounts log worker ../x' 'accounts log worker a b' 'accounts log rc.log'; do
  acct "$w" "${LINE_ARGS[@]}"
  t "the word $(printf '%q' "$w") is refused" bash -c "[ '$RC' = 126 ] && printf '%s\n' \"\$1\" | grep -q '^HPCW-GRID-GATE refused word'" _ "$OUT"
done
acct "accounts auto on" "${LINE_ARGS[@]}"
KEEP_CLOCK=1 gate "accounts use 1" "${LINE_ARGS[@]}"
t "the file words keep a floor of their own, a few seconds" bash -c "[ '$RC' = 123 ] && printf '%s' \"\$1\" | grep -q 'every 3 seconds'" _ "$OUT"
rm -f "$CH/accounts.last"; KEEP_CLOCK=1 gate "accounts usage" "${LINE_ARGS[@]}"
t "usage queues a job: a call a minute" rc_is 0
rm -f "$CH/accounts.last"; KEEP_CLOCK=1 gate "accounts login 2" "${LINE_ARGS[@]}"
t "  shared with login" bash -c "[ '$RC' = 123 ] && printf '%s' \"\$1\" | grep -q 'a minute'" _ "$OUT"
rm -f "$CH/accounts.sched"
chmod g+w "$S/framework/bin/hpcworker"; acct accounts "${LINE_ARGS[@]}"
t "an accounts word refuses a framework/bin/hpcworker the group may write" bash -c "[ '$RC' = 126 ] && ! grep -q . <(tail -n +99999 '$HW_CALLS')"
gate status "${LINE_ARGS[@]}"
t "  which start, status and stop never run, and so never judge" rc_is 0
chmod g-w "$S/framework/bin/hpcworker"

echo "== what the gate refuses"
n=$(n_calls)
for w in 'status --now' 'status;id' 'status$(id)' 'status`id`' $'status\nid' 'stop ' ' stop' 'Start' 'install' 'serve' 'restart' 'gatekey' "$(printf 's%.0s' {1..17})" ''; do
  gate "$w" "${LINE_ARGS[@]}"
  t "the word $(printf '%q' "$w") is refused" bash -c "[ '$RC' = 126 ] && printf '%s\n' \"\$1\" | grep -q '^HPCW-GRID-GATE refused word'" _ "$OUT"
done
gate -unset "${LINE_ARGS[@]}"
t "no word at all is refused, naming the three" bash -c "[ '$RC' = 126 ] && printf '%s' \"\$1\" | grep -q 'start, status or stop'" _ "$OUT"
for bad in "--repo a/b;id --runner-dir $RD" "--repo $GH_REPO --runner-dir relative" "--repo $GH_REPO" "--repo $GH_REPO --runner-dir $RD --now x" "--repo $GH_REPO --runner-dir $RD --hours" "--repo $GH_REPO --runner-dir $RD --hours \$(id)"; do
  # shellcheck disable=SC2086
  gate status $bad
  t "a line --gate-key never writes is refused: $bad" bash -c "[ '$RC' = 126 ] && printf '%s' \"\$1\" | grep -q 'refused line'" _ "$OUT"
done
t "nothing refused reached grid_runner.sh" [ "$(n_calls)" = "$n" ]

echo "== one call a minute"
rm -f "$CH/gate.last"; gate status "${LINE_ARGS[@]}"
n=$(n_calls)
KEEP_CLOCK=1 gate stop "${LINE_ARGS[@]}"
t "a second call within 60 seconds is refused" bash -c "[ '$RC' = 123 ] && printf '%s' \"\$1\" | grep -q 'HPCW-GRID-GATE limit: one call a minute'" _ "$OUT"
t "  and reaches nothing" [ "$(n_calls)" = "$n" ]
echo $(( $(date +%s) - 61 )) > "$CH/gate.last"; KEEP_CLOCK=1 gate stop "${LINE_ARGS[@]}"
t "a call 61 seconds after the last runs" bash -c "[ '$RC' = 0 ] && [ '$(n_calls)' != '$n' ]"
mkdir "$CH/gate.lock"; gate status "${LINE_ARGS[@]}"
t "a call while another holds the gate is refused" bash -c "[ '$RC' = 123 ] && printf '%s' \"\$1\" | grep -q 'another call'" _ "$OUT"
touch -d '5 minutes ago' "$CH/gate.lock"; gate status "${LINE_ARGS[@]}"
t "a lock older than two minutes is a leftover" rc_is 0
echo "99999999999999999999" > "$CH/gate.last"; KEEP_CLOCK=1 gate status "${LINE_ARGS[@]}"
t "a clock file that is no time does not lock the gate for good" rc_is 0
echo $(( $(date +%s) + 3600 )) > "$CH/gate.last"; KEEP_CLOCK=1 gate status "${LINE_ARGS[@]}"
t "a time in the future does not lock the gate for good" rc_is 0

echo "== the log"
OUT=$(cat "$CH/gate.log")
t "one line per call, with the word, the address and the end" has '^[0-9T:-]+Z status from 192\.0\.2\.7: ok$'
t "  refusals and limits too" bash -c "grep -q 'refused from 192.0.2.7: word' '$CH/gate.log' && grep -q 'stop from 192.0.2.7: limit$' '$CH/gate.log'"
t "  and a failure with its code" has 'start from 192\.0\.2\.7: failed 1$'
t "no key and no token in it" lacks 'AAAA|gho_marker'

echo "== the clone others may change"
chmod g+w "$S/tools"; gate status "${LINE_ARGS[@]}"
t "a tools folder the group may write is refused" bash -c "[ '$RC' = 126 ] && printf '%s' \"\$1\" | grep -q 'refused copy'" _ "$OUT"
chmod g-w "$S/tools"; chmod o+w "$S/framework/lib"; gate status "${LINE_ARGS[@]}"
t "a framework/lib others may write is refused" rc_is 126
chmod o-w "$S/framework/lib"; touch "$S/framework/profiles/x.json"; chmod 666 "$S/framework/profiles/x.json"; gate status "${LINE_ARGS[@]}"
t "a profile others may write is refused" rc_is 126
rm -f "$S/framework/profiles/x.json"; ln -s /etc/passwd "$S/tools/link"; gate status "${LINE_ARGS[@]}"
t "a link among the tools is refused" rc_is 126
rm -f "$S/tools/link"; chmod 777 "$T"; chmod -t "$T"; gate status "${LINE_ARGS[@]}"
t "a folder above the clone others may write is refused" rc_is 126
chmod +t "$T"; gate status "${LINE_ARGS[@]}"
t "  unless it is sticky" rc_is 0
# a folder above that another account owns (the CephFS scaffold at Wayne State) is a note, as browser-key
# judges it: a stat in front of the real one says another uid owns $T, which no test can make unprivileged
mkdir -p "$T/fakebin"; REAL_STAT=$(command -v stat)
printf '#!/bin/bash\nif [ "$1 $2 $3" = "-L -c %%u" ] && [ "$4" = %q ]; then echo 99999; exit 0; fi\nexec %q "$@"\n' "$T" "$REAL_STAT" > "$T/fakebin/stat"
chmod 755 "$T/fakebin/stat"; chmod 777 "$T"; chmod -t "$T"
PATH="$T/fakebin:$PATH" gate status "${LINE_ARGS[@]}"
t "a folder above the clone that another account owns, though others may write it, refuses nothing" rc_is 0
OUT=$(PATH="$T/fakebin:$PATH" bash "$S/tools/grid_gate.sh" --check-copy 2>&1); RC=$?
t "  and --check-copy names it as a note for the university, then ok" bash -c "[ '$RC' = 0 ] && printf '%s' \"\$1\" | grep -q '^note for the university: $T (owner uid 99999)' && printf '%s' \"\$1\" | grep -q '^ok '" _ "$OUT"
chmod g+w "$S/tools"; OUT=$(PATH="$T/fakebin:$PATH" bash "$S/tools/grid_gate.sh" --check-copy 2>&1); RC=$?
t "  while one of the account's own beside it is still refused" bash -c "[ '$RC' = 8 ] && printf '%s' \"\$1\" | grep -q '^copy $S/tools'" _ "$OUT"
chmod g-w "$S/tools"; rm -rf "$T/fakebin"
chmod 700 "$T"
chmod g+w "$RD"; gate status "${LINE_ARGS[@]}"
t "a runner's folder the group may write is refused" bash -c "[ '$RC' = 126 ] && printf '%s' \"\$1\" | grep -q 'runner $RD'" _ "$OUT"
chmod g-w "$RD"; mkdir -p "$RD/bin"; touch "$RD/bin/grid_runner.sbatch"; chmod 666 "$RD/bin/grid_runner.sbatch"; gate status "${LINE_ARGS[@]}"
t "a script in the runner's bin others may write is refused" rc_is 126
chmod 644 "$RD/bin/grid_runner.sbatch"; chmod o+w "$CH"; gate status "${LINE_ARGS[@]}"
t "a chain's folder others may write is refused" rc_is 126
chmod o-w "$CH"; ln -s "$T/elsewhere" "$CH/gate.log.1"; gate status "${LINE_ARGS[@]}"
t "a link planted among the chain's files is refused" bash -c "[ '$RC' = 126 ] && [ ! -e '$T/elsewhere' ]"
unlink "$CH/gate.log.1"; mkdir -p "$T/real/r"; ln -s "$T/real" "$T/runlink"; chmod 777 "$T/real"; chmod -t "$T/real"
gate status --runner-dir "$T/runlink/r" --repo "$GH_REPO"
t "a folder others may change on the physical path behind a link is refused" rc_is 126
chmod 755 "$T/real"; gate status --runner-dir "$T/runlink/r" --repo "$GH_REPO"
t "  and the same path is taken once it is not" rc_is 0
mkdir -p "$T/open/inner/r"; chmod 777 "$T/open"; chmod -t "$T/open"; ln -s "$T/open/inner" "$T/lnk2"
gate status --runner-dir "$T/lnk2/r" --repo "$GH_REPO"
t "a folder others may change above where a link leads, though not on the path as named, is refused" bash -c "[ '$RC' = 126 ] && printf '%s' \"\$1\" | grep -q 'above $T/open'" _ "$OUT"
chmod 755 "$T/open"
head -c 1048600 /dev/zero | tr '\0' 'x' > "$CH/gate.log"; gate status "${LINE_ARGS[@]}"
t "a gate.log over 1 MB is turned over to gate.log.1" bash -c "[ \"\$(stat -c %s '$CH/gate.log.1')\" -gt 1048576 ] && [ \"\$(wc -l < '$CH/gate.log')\" = 1 ]"
OUT=$(bash "$S/tools/grid_gate.sh" --check-copy 2>&1); RC=$?
t "--check-copy says ok for a clone only its owner may change" bash -c "[ '$RC' = 0 ] && printf '%s' \"\$1\" | grep -q '^ok '" _ "$OUT"
chmod g+w "$S/tools/grid_runner.sh"; OUT=$(bash "$S/tools/grid_gate.sh" --check-copy 2>&1); RC=$?
t "--check-copy names what others may change" bash -c "[ '$RC' = 8 ] && printf '%s' \"\$1\" | grep -q 'copy $S/tools/grid_runner.sh'" _ "$OUT"
chmod g-w "$S/tools/grid_runner.sh"

echo "== the key's line"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOwnOwnOwnOwnOwnOwnOwnOwnOwnOwnOwnOwnOwnOwn mine' 'restrict,command="echo key-only sign-in works" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherOtherOtherOtherOtherOtherOtherOther grid-gate-test' > "$AK"
printf '%s' 'from="10.0.0.0/8" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINoNewlineNoNewlineNoNewlineNoNewlineNoN last' >> "$AK"
chmod 600 "$AK"; cp "$AK" "$T/ak.before"
typed --gate-key "$KEY1" --repo "$GH_REPO" --site wayne --runner-dir "$RD" --hours 6 --gres gpu:1
t "--gate-key at a terminal writes the line" rc_is 0
GATE=$(cd "$C/tools" && pwd -P)/grid_gate.sh
WANT="restrict,command=\"$GATE --site wayne --runner-dir $RD --repo $GH_REPO --hours 6 --gres gpu:1\" ${KEY1% *} hpcw-grid-gate:$GH_REPO"
t "  exactly, the key's own comment dropped" bash -c "[ \"\$(tail -1 '$AK')\" = \"\$1\" ]" _ "$WANT"
t "  every earlier line kept, the last one's missing newline given" bash -c "head -3 '$AK' | diff - <(cat '$T/ak.before'; echo) >/dev/null"
t "  the file 600" [ "$(stat -c %a "$AK")" = 600 ]
t "  and the chain's folder made for the log" [ -d "$CH" ]
typed --gate-key "$KEY2" --repo "$GH_REPO" --site wayne --runner-dir "$RD"
t "a second --gate-key replaces the first" bash -c "[ \"\$(grep -c 'hpcw-grid-gate:$GH_REPO\$' '$AK')\" = 1 ] && grep -q '${KEY2#* }' '$AK' && [ \"\$(wc -l < '$AK')\" = 4 ]"
typed --gate-key "$KEY3" --repo OpenSpineConsortium/other --runner-dir "$RD"
t "another repository's gate is a line of its own" bash -c "[ \"\$(grep -c 'hpcw-grid-gate:' '$AK')\" = 2 ] && grep -q 'command=\"$GATE --runner-dir $RD --repo OpenSpineConsortium/other\"' '$AK'"
typed --gate-key "$KEY4" --repo OpenSpineConsortium/symphony-templateX --runner-dir "$RD"
typed --gate-off --repo "$GH_REPO" --runner-dir "$RD"
typed --gate-key "$KEY2" --repo "$GH_REPO" --site wayne --runner-dir "$RD"
t "a repository whose name extends another's is not taken for it" bash -c "grep -q 'hpcw-grid-gate:$GH_REPO\$' '$AK' && grep -q 'hpcw-grid-gate:OpenSpineConsortium/symphony-templateX\$' '$AK'"
typed --gate-off --repo OpenSpineConsortium/symphony-templateX --runner-dir "$RD"
t "  and --gate-off of the longer name leaves the shorter's" bash -c "grep -q 'hpcw-grid-gate:$GH_REPO\$' '$AK' && ! grep -q 'symphony-templateX' '$AK'"
OUT=$(cat "$AK"); OLD=$OUT
typed --gate-key "$KEY2" --repo "$GH_REPO" --site wayne --runner-dir "$RD"
t "the same line again changes nothing" bash -c "[ '$RC' = 0 ] && printf '%s' \"\$1\" | grep -q 'already'" _ "$OUT"
typed --gate-key "$KEY2" --repo OpenSpineConsortium/other2 --runner-dir "$RD"
t "the gate's key already on another repository's line is refused" bash -c "[ '$RC' != 0 ] && printf '%s' \"\$1\" | grep -q 'on another line' && [ \"\$(cat '$AK')\" = \"\$2\" ]" _ "$OUT" "$OLD"
for k in "AAAAC3NzaC1lZDI1NTE5AAAAIBCj/iayuSj3Fidk+gybZFVkRGUgZuPSuVKeM+iqcGM2" "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ x" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCj/iayuSj3Fidk+gybZFVkRGUgZuPSuVKeM+iqcGM" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCj/iayuSj3Fidk+gybZFVkRGUgZuPSuVKeM+iqcGM2\" x" 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCj/iayuSj3Fidk+gyb"ZFVkRGUgZuPSuVKeM+iqcGM2' "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCj/iayuSj3Fidk+gybZFVkRGUgZuPSuVKeM+iqcGM2="; do
  typed --gate-key "$k" --repo "$GH_REPO" --runner-dir "$RD"
  t "not one whole ed25519 key is refused: ${k:0:40}..." bash -c "[ '$RC' != 0 ] && [ \"\$(cat '$AK')\" = \"\$1\" ]" _ "$OLD"
done
typed --gate-key "$KEY1" --repo "a/b;id" --runner-dir "$RD"
t "a repository that is no OWNER/NAME is refused" bash -c "[ '$RC' != 0 ] && [ \"\$(cat '$AK')\" = \"\$1\" ]" _ "$OLD"
OUT=$(cd "$C" && bash tools/grid_runner.sh --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD" < /dev/null 2>&1); RC=$?
t "--gate-key with no terminal is refused" bash -c "[ '$RC' != 0 ] && printf '%s' \"\$1\" | grep -q 'only when you type it' && [ \"\$(cat '$AK')\" = \"\$2\" ]" _ "$OUT" "$OLD"
for v in CLAUDECODE=1 AI_AGENT=claude BEETHOVEN_REQUEST_ID=r SLURM_JOB_ID=7 HPCW_GATE=1 SSH_ORIGINAL_COMMAND=status; do
  printf '#!/bin/bash\ncd %q && env %q bash tools/grid_runner.sh --gate-key %q --repo %q --runner-dir %q; echo $? > %q\n' "$C" "$v" "$KEY1" "$GH_REPO" "$RD" "$T/typed.rc" > "$T/typed.sh"
  typed_run
  t "--gate-key with $v is refused" bash -c "[ '$RC' != 0 ] && [ \"\$(cat '$AK')\" = \"\$1\" ]" _ "$OLD"
done
chmod g+w "$C/tools"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"
t "--gate-key refuses a clone others may change" bash -c "[ '$RC' != 0 ] && printf '%s' \"\$1\" | grep -q 'others may change the clone' && [ \"\$(cat '$AK')\" = \"\$2\" ]" _ "$OUT" "$OLD"
chmod g-w "$C/tools"; chmod g+w "$AK"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"
t "--gate-key refuses an authorized_keys others may write, which sshd would ignore" bash -c "[ '$RC' != 0 ] && [ \"\$(cat '$AK')\" = \"\$1\" ]" _ "$OLD"
chmod 600 "$AK"; mv "$AK" "$T/ak.real"; ln -s "$T/ak.real" "$AK"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"
t "--gate-key refuses an authorized_keys that is a link" bash -c "[ '$RC' != 0 ] && [ -L '$AK' ]"
rm -f "$AK"; mv "$T/ak.real" "$AK"
mkdir "$HOME/.ssh/.beethoven-browser.lock"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"
t "--gate-key waits for Beethoven's own key writer, then gives up with nothing changed" bash -c "[ '$RC' != 0 ] && [ \"\$(cat '$AK')\" = \"\$1\" ]" _ "$OLD"
rmdir "$HOME/.ssh/.beethoven-browser.lock"
rm -f "$AK"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"
t "--gate-key makes authorized_keys when there is none" bash -c "[ '$RC' = 0 ] && [ \"\$(wc -l < '$AK')\" = 1 ] && [ \"\$(stat -c %a '$AK')\" = 600 ]"
typed --gate-off --repo "$GH_REPO" --runner-dir "$RD"
t "--gate-off takes the line out" bash -c "[ '$RC' = 0 ] && [ ! -s '$AK' ]"
typed --gate-off --repo "$GH_REPO" --runner-dir "$RD"
t "  and says so when there is none" has "no gate key for $GH_REPO"
printf '%s\n' "${KEY1% *} plain" > "$AK"; chmod 600 "$AK"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"
t "the gate's key already on a plain line, which sshd would use first, is refused" bash -c "[ '$RC' != 0 ] && [ \"\$(wc -l < '$AK')\" = 1 ]"
: > "$AK"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"; sed -i 's/symphony-template$/symphony-template\r/' "$AK"
typed --gate-key "$KEY2" --repo openspineconsortium/SYMPHONY-template --runner-dir "$RD"
t "a gate line with a carriage return, and the name in another case, is replaced, not kept beside" bash -c "[ \"\$(grep -c hpcw-grid-gate '$AK')\" = 1 ] && grep -q '${KEY2#* }' '$AK'"
cp "$T/ak.before" "$AK"; typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"; typed --gate-off --repo "$GH_REPO" --runner-dir "$RD"
t "--gate-off keeps every other line" bash -c "diff '$AK' <(cat '$T/ak.before'; echo) >/dev/null"
t "no temporary file is left in ~/.ssh" bash -c "[ -z \"\$(ls -A '$HOME/.ssh' | grep -v '^authorized_keys\$')\" ]"

echo "== the gate from the line --gate-key wrote, as sshd would run it"
typed --gate-key "$KEY1" --repo "$GH_REPO" --runner-dir "$RD"
CMD=$(sed -n "s/^restrict,command=\"\\([^\"]*\\)\" .* hpcw-grid-gate:${GH_REPO//\//\\/}\$/\\1/p" "$AK")
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "squeue $*" >> "%s/sq.calls"\n' "$T" > "$T/fakebin/squeue"; chmod 755 "$T/fakebin/squeue"
rm -f "$CH/gate.last"
OUT=$(env -i HOME="$HOME" USER="$USER" PATH="$T/fakebin:/usr/bin:/bin" SSH_ORIGINAL_COMMAND=status SSH_CONNECTION="192.0.2.9 1 2 22" bash -c "$CMD" 2>&1); RC=$?
t "the forced command runs the real --status for the line's chain" bash -c "[ '$RC' = 0 ] && printf '%s' \"\$1\" | grep -q '^runner folder: $RD\$' && grep -q '^squeue ' '$T/sq.calls'" _ "$OUT"

echo "== --gate-setup: the whole setup typed in the grid's shell, against a stand-in gh"
# a stand-in site whose recorded host key is one made here, as the grid's own is in its profile
HK="$T/hostkeys"; mkdir -p "$HK"
ssh-keygen -q -t rsa -b 2048 -N '' -C '' -f "$HK/ssh_host_rsa_key" </dev/null >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -C '' -f "$HK/ssh_host_ed25519_key" </dev/null >/dev/null 2>&1
HKFP=$(ssh-keygen -lf "$HK/ssh_host_rsa_key.pub" | awk '{ print $2 }')
sed -e "s|\"ssh_host_key\": \"[^\"]*\"|\"ssh_host_key\": \"$HKFP\"|" -e 's|"ssh_host": "[^"]*"|"ssh_host": "grid.example.edu"|' \
  "$C/framework/profiles/wayne.json" > "$C/framework/profiles/testgrid.json"
# gh as GitHub would answer an admin of a private repository; its state is files under $G
G="$T/gh"; mkdir -p "$G/bin"
cat > "$G/bin/gh" <<'GH'
#!/bin/bash
g=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$*" >> "$g/calls"
r=OpenSpineConsortium/symphony-template e="repos/$r/environments/grid"
case "$*" in
  "variable --help") exit 0;;
  "api repos/$r --jq .visibility") cat "$g/visibility";;
  "api repos/$r --jq .permissions.admin") cat "$g/admin";;
  "api repos/$r/contents/.github/workflows/grid-gate.yml?ref=main --silent") [ -f "$g/workflow" ];;
  "api $e --jq .deployment_branch_policy.custom_branch_policies")
    [ -f "$g/env-lost" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
    [ -f "$g/env" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$g/env";;
  "api -X PUT $e --input -") cat > "$g/env.put"; echo true > "$g/env";;
  "api --paginate $e/deployment-branch-policies --jq .branch_policies[] | select(.type == \"branch\") | .name") cat "$g/policies" 2>/dev/null; true;;
  "api -X POST $e/deployment-branch-policies -f name=main -f type=branch") echo main >> "$g/policies";;
  "variable set "*) [ ! -f "$g/refuse-variable" ];;
  "secret set GRID_GATE_KEY --env grid --repo $r") [ ! -f "$g/refuse-secret" ] && ( umask 077; cat > "$g/secret" );;
  "workflow run grid-gate.yml --repo $r --ref main -f word=status") exit 0;;
  *) echo "unexpected gh $*" >&2; exit 9;;
esac
GH
chmod 755 "$G/bin/gh"
gh_reset() { rm -f "$G"/calls "$G"/env "$G"/env.put "$G"/policies "$G"/secret "$G"/refuse-* "$G"/env-lost; echo private > "$G/visibility"; echo true > "$G/admin"; : > "$G/workflow"; }
setup() { # ARGS...: --gate-setup typed at a terminal, with the stand-in gh and host keys
  PATH="$G/bin:$PATH" HPCW_HOST_KEY_DIR="$HK" typed --gate-setup --repo "$GH_REPO" --site testgrid --runner-dir "$RD" "$@"
}
gh_wrote() { grep -E -- '^(api -X|variable set|secret set|workflow run)' "$G/calls" 2>/dev/null; }
SHM="$T/shm"; mkdir -p "$SHM"; export HPCW_GATE_TMP="$SHM"
no_key_left() { [ -z "$(ls -A "$HOME/.ssh" "$SHM" | grep '^grid-gate\.')" ]; }

gh_reset; : > "$AK"; chmod 600 "$AK"; chmod -R g+w "$C/tools"
setup --hours 6
t "--gate-setup ends well" rc_is 0
LINE=$(grep 'hpcw-grid-gate:' "$AK")
t "  writes the gate's line, the chain's options in it" bash -c "printf '%s' \"\$1\" | grep -q -- '--site testgrid --runner-dir $RD --repo $GH_REPO --hours 6\" ssh-ed25519 '" _ "$LINE"
t "  hands gh the private key whose public half is on that line" bash -c "[ -s '$G/secret' ] && k=\$(ssh-keygen -y -f '$G/secret' | cut -d' ' -f2) && printf '%s' \"\$1\" | grep -q -- \" \$k hpcw-grid-gate:\"" _ "$LINE"
t "  on gh's standard input only, never in an argument or the output" bash -c "b=\$(sed -n 2p '$G/secret'); [ -n \"\$b\" ] && ! grep -qF -- \"\$b\" '$G/calls' && ! printf '%s' \"\$1\" | grep -qF -- \"\$b\" && ! printf '%s' \"\$1\" | grep -q 'PRIVATE KEY'" _ "$OUT"
t "  leaves no copy of the key in ~/.ssh" no_key_left
t "  makes the environment deployable from main alone" bash -c "grep -q '\"custom_branch_policies\":true' '$G/env.put' && [ \"\$(cat '$G/policies')\" = main ]"
t "  sets GRID_ACCESS_ID to this account" grep -qx -- "variable set GRID_ACCESS_ID --env grid --repo $GH_REPO --body $USER" "$G/calls"
t "  and GRID_HOST_KEY to the host key whose fingerprint the profile recorded" grep -qx -- "variable set GRID_HOST_KEY --env grid --repo $GH_REPO --body grid.example.edu $(cut -d' ' -f1,2 "$HK/ssh_host_rsa_key.pub")" "$G/calls"
t "  starts grid-gate.yml with status" grep -qx -- "workflow run grid-gate.yml --repo $GH_REPO --ref main -f word=status" "$G/calls"
t "  closes the clone to others" bash -c "[ -z \"\$(find '$C/tools' -perm -g+w)\" ]"
FIRST=$(ssh-keygen -y -f "$G/secret" | cut -d' ' -f2)

rm -f "$G/calls" "$G/env.put"; setup
t "run again: a new key replaces the old on the line" bash -c "[ '$RC' = 0 ] && [ \"\$(grep -c hpcw-grid-gate: '$AK')\" = 1 ] && ! grep -q '$FIRST' '$AK'"
t "  and the environment that exists is not written over" bash -c "[ ! -f '$G/env.put' ] && ! grep -q 'POST' '$G/calls'"

cp "$AK" "$T/ak.setup"
refused_clean() { [ "$RC" != 0 ] && [ "$RC" != none ] && cmp -s "$AK" "$T/ak.setup" && [ -z "$(gh_wrote)" ] && no_key_left; }
gh_reset; echo public > "$G/visibility"; setup
t "a public repository is refused, nothing changed" refused_clean
gh_reset; echo false > "$G/admin"; setup
t "an account that is no admin is refused, nothing changed" refused_clean
gh_reset; rm -f "$G/workflow"; setup
t "a repository without grid-gate.yml is refused, nothing changed" refused_clean
gh_reset; echo false > "$G/env"; setup
t "an environment that may deploy from any branch is refused, nothing changed" refused_clean
t "  saying where to fix it" has "settings/environments"
gh_reset; mv "$HK/ssh_host_rsa_key.pub" "$HK/rsa.away"; setup
t "no host key with the recorded fingerprint is refused, nothing changed" refused_clean
mv "$HK/rsa.away" "$HK/ssh_host_rsa_key.pub"
gh_reset; touch "$G/env-lost"; setup
t "an environment gh could not read is not made afresh over it" refused_clean
gh_reset; echo true > "$G/env"; printf 'main\nrelease/*\n' > "$G/policies"; setup
t "an environment that deploys from a pattern is refused, nothing changed" refused_clean
gh_reset; touch "$G/refuse-variable"; setup
t "refused variables fail the command, leave no key and store no secret" bash -c "[ '$RC' != 0 ] && [ ! -e '$G/secret' ] && [ -z \"\$(ls -A '$HOME/.ssh' '$SHM' | grep '^grid-gate\.')\" ]"
t "  saying the gate is down until it runs again" has "gate is down"
gh_reset; mkdir -m 700 "$SHM/grid-gate.$USER.left"; : > "$SHM/grid-gate.$USER.left/key"; setup
t "a key folder an earlier run left behind is cleared" bash -c "[ '$RC' = 0 ] && [ ! -e '$SHM/grid-gate.$USER.left' ]"
gh_reset; chmod g+w "$C/tools"; mkdir -p "$RD/OpenSpineConsortium-symphony-template"; chmod o+w "$RD"; setup
t "a refusal inside the line's writing leaves no key behind" bash -c "[ '$RC' != 0 ] && [ -z \"\$(ls -A '$HOME/.ssh' '$SHM' | grep '^grid-gate\.')\" ] && [ ! -e '$G/secret' ]"
chmod o-w "$RD"
gh_reset; touch "$G/refuse-secret"; setup
t "a refused secret fails the command and leaves no key behind" bash -c "[ '$RC' != 0 ] && [ -z \"\$(ls -A '$HOME/.ssh' '$SHM' | grep '^grid-gate\.')\" ] && ! grep -q 'workflow run' '$G/calls'"
gh_reset
OUT=$(cd "$C" && PATH="$G/bin:$PATH" HPCW_HOST_KEY_DIR="$HK" bash tools/grid_runner.sh --gate-setup --repo "$GH_REPO" --site testgrid --runner-dir "$RD" < /dev/null 2>&1); RC=$?
t "--gate-setup not typed at a terminal is refused, nothing asked of gh" bash -c "[ '$RC' != 0 ] && [ ! -s '$G/calls' ]"
gh_reset; setup_nosite() { PATH="$G/bin:$PATH" HPCW_HOST_KEY_DIR="$HK" typed --gate-setup --repo "$GH_REPO" --runner-dir "$RD"; }; setup_nosite
t "--gate-setup without --site is refused" bash -c "[ '$RC' != 0 ] && [ ! -s '$G/calls' ]"

echo "== the job words: update, the promoter and SchwingNet (the owner's choice of 2026-10-21)"
JB="$T/jobbin"; mkdir -p "$JB"; JOBS_CALLS="$T/jobs.calls"; : > "$JOBS_CALLS"
SHA=0123456789abcdef0123456789abcdef01234567
for c in sbatch squeue; do printf '#!/bin/bash\necho "%s $*" >> "%s"\necho "%s answered"\n' "$c" "$JOBS_CALLS" "$c" > "$JB/$c"; done
cat > "$JB/gh" <<EOF2
#!/bin/bash
echo "gh \$*" >> "$JOBS_CALLS"
case "\$*" in
  *commits/main*) echo $SHA;;
  "repo clone OpenSpineConsortium/SchwingNet "*) git clone -q "$T/sn-origin.git" "\$4"; exit \$?;;
  *contents/grid/promote.sh?ref=$SHA*) printf '#!/bin/bash\necho "promote.sh \$*" >> "$JOBS_CALLS"\necho "promote said \$1"\n';;
  *contents/tools/promote.py?ref=$SHA*) echo "# promote.py at $SHA";;
  *contents/grid/freeze.sh?ref=$SHA*) printf '#!/bin/bash\necho "freeze.sh \$* FREEZE_HOME=\$FREEZE_HOME" >> "$JOBS_CALLS"\necho "freeze said \$1"\n';;
  *contents/tools/freeze.py?ref=$SHA*) echo "# freeze.py at $SHA";;
  *contents/tools/lineage.py?ref=$SHA*) echo "# lineage.py at $SHA";;
  *contents/grid/freeze-plan.tsv?ref=$SHA*) printf 'amos22\t/data/amos22\t102600000000\n';;
  *) exit 1;;
esac
EOF2
chmod 755 "$JB"/*
export HPCW_LAB_ROOT="$T/lab"; mkdir -p "$HPCW_LAB_ROOT"; chmod 755 "$HPCW_LAB_ROOT"
P="$HPCW_LAB_ROOT/spine-datasets-promoter"
job() { rm -f "$CH/jobs.last" "$CH/jobs.sched"; PATH="$JB:$PATH" gate "$@"; }

job "promoter start" "${LINE_ARGS[@]}"
t "promoter start reads main's head with gh and fetches promote.sh at it" bash -c "grep -q 'commits/main' '$JOBS_CALLS' && grep -q 'contents/grid/promote.sh?ref=$SHA' '$JOBS_CALLS' && [ -f '$P/code/promote.sh' ]"
t "  then runs promote.sh start at that commit" bash -c "grep -qx 'promote.sh start $SHA' '$JOBS_CALLS'"
t "  and says so" has "^HPCW-GRID-GATE promoter start ok at ${SHA:0:12}$"
t "  its folder kept to the account" bash -c "[ -z \"\$(find '$P/code' -maxdepth 0 -perm -g+w)\" ]"
job "promoter status" "${LINE_ARGS[@]}"
t "promoter status runs promote.sh status and shows its output" bash -c "grep -qx 'promote.sh status' '$JOBS_CALLS'" && t "  its output" has '^promote said status$'
job "promoter stop" "${LINE_ARGS[@]}"
t "promoter stop runs promote.sh stop" bash -c "grep -qx 'promote.sh stop' '$JOBS_CALLS'"
F="$HPCW_LAB_ROOT/spine-datasets-freeze"
: > "$JOBS_CALLS"; job "freeze status" "${LINE_ARGS[@]}"
t "freeze status before any freeze says none has started, and fetches nothing" bash -c "[ '$RC' = 0 ] && ! grep -q contents '$JOBS_CALLS'" && t "  says so" has '^HPCW-GRID-GATE freeze status: no freeze has been started$'
: > "$JOBS_CALLS"; job "freeze pilot" "${LINE_ARGS[@]}"
t "freeze pilot fetches freeze.py, lineage.py, freeze.sh and the plan at main's head" bash -c "for f in tools/freeze.py tools/lineage.py grid/freeze.sh grid/freeze-plan.tsv; do grep -q \"contents/\$f?ref=$SHA\" '$JOBS_CALLS' || exit 1; done; grep -qx '# freeze.py at $SHA' '$F/code/freeze.py'"
t "  then runs freeze.sh pilot in its own folder" bash -c "grep -qx 'freeze.sh pilot FREEZE_HOME=$F' '$JOBS_CALLS'" && t "  and says so" has "^HPCW-GRID-GATE freeze pilot ok at ${SHA:0:12}$"
: > "$JOBS_CALLS"; job "freeze start" "${LINE_ARGS[@]}"
t "freeze start runs freeze.sh start, its count fixed in the repository" bash -c "grep -qx 'freeze.sh start FREEZE_HOME=$F' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "freeze report" "${LINE_ARGS[@]}"
t "freeze report fetches the code at main's head and runs freeze.sh report" bash -c "grep -q 'contents/grid/freeze.sh?ref=$SHA' '$JOBS_CALLS' && grep -qx 'freeze.sh report FREEZE_HOME=$F' '$JOBS_CALLS'" && t "  and says so" has "^HPCW-GRID-GATE freeze report ok at ${SHA:0:12}$"
: > "$JOBS_CALLS"; job "freeze overlap" "${LINE_ARGS[@]}"
t "freeze overlap fetches lineage.py at main's head and runs freeze.sh overlap" bash -c "grep -q 'contents/tools/lineage.py?ref=$SHA' '$JOBS_CALLS' && grep -qx 'freeze.sh overlap FREEZE_HOME=$F' '$JOBS_CALLS'" && t "  and says so" has "^HPCW-GRID-GATE freeze overlap ok at ${SHA:0:12}$"
: > "$JOBS_CALLS"; job "freeze overlap now" "${LINE_ARGS[@]}"
t "freeze overlap takes no argument" bash -c "! grep -q 'freeze.sh' '$JOBS_CALLS'"
chmod g+w "$F/code/lineage.py"; : > "$JOBS_CALLS"; job "freeze status" "${LINE_ARGS[@]}"
t "a lineage.py the group may write is refused and freeze.sh never run" bash -c "[ '$RC' = 126 ] && ! grep -q freeze.sh '$JOBS_CALLS'"
chmod g-w "$F/code/lineage.py"
: > "$JOBS_CALLS"; job "freeze status" "${LINE_ARGS[@]}"
t "freeze status runs freeze.sh status and fetches nothing" bash -c "grep -qx 'freeze.sh status FREEZE_HOME=$F' '$JOBS_CALLS' && ! grep -q contents '$JOBS_CALLS'"
chmod g+w "$F/code/freeze.sh"; : > "$JOBS_CALLS"; job "freeze status" "${LINE_ARGS[@]}"
t "a freeze.sh the group may write is refused and never run" bash -c "[ '$RC' = 126 ] && ! grep -q freeze.sh '$JOBS_CALLS'"
chmod g-w "$F/code/freeze.sh"
chmod g+w "$P/code/promote.sh"; : > "$JOBS_CALLS"; job "promoter status" "${LINE_ARGS[@]}"
t "a promote.sh the group may write is refused and never run" bash -c "[ '$RC' = 126 ] && ! grep -q promote.sh '$JOBS_CALLS'"
chmod g-w "$P/code/promote.sh"

# restart: a squeue of its own, which lists the chain's jobs for as many polls as $T/sq.left says
RB="$T/restartbin"; mkdir -p "$RB"
printf '#!/bin/bash\necho "squeue $*" >> "%s"\nn=$(cat "%s/sq.left" 2>/dev/null || echo 0)\n[ "$n" -gt 0 ] && echo 41001 && echo $((n - 1)) > "%s/sq.left"\nexit 0\n' "$JOBS_CALLS" "$T" "$T" > "$RB/squeue"; chmod 755 "$RB/squeue"
restart() { rm -f "$CH/jobs.last" "$CH/jobs.sched"; HPCW_GATE_POLL=0 PATH="$RB:$JB:$PATH" gate "promoter restart" "${LINE_ARGS[@]}"; }
echo old > "$P/code/promote.py"; echo 2 > "$T/sq.left"; : > "$JOBS_CALLS"; restart
t "promoter restart fetches promote.py and promote.sh at main's head" bash -c "grep -q 'contents/tools/promote.py?ref=$SHA' '$JOBS_CALLS' && grep -q 'contents/grid/promote.sh?ref=$SHA' '$JOBS_CALLS' && grep -qx '# promote.py at $SHA' '$P/code/promote.py'"
t "  stops the chain, waits until squeue lists none of it, then starts it at that commit" bash -c "[ \"\$(grep -E '^(promote.sh|squeue)' '$JOBS_CALLS' | tr '\n' '|')\" = 'promote.sh stop|squeue -h -u $(id -un) -n spine-datasets-promoter -o %i|squeue -h -u $(id -un) -n spine-datasets-promoter -o %i|squeue -h -u $(id -un) -n spine-datasets-promoter -o %i|promote.sh start $SHA|' ]"
t "  leaves no .gate.tmp behind" bash -c "[ -z \"\$(ls '$P/code' | grep tmp)\" ]"
t "  and says so" has "^HPCW-GRID-GATE promoter restart ok at ${SHA:0:12}$"
printf '#!/bin/bash\necho "promote.sh $* HPCWORKER=$HPCWORKER" >> "%s"\n' "$JOBS_CALLS" > "$P/code/promote.sh"; chmod go-w "$P/code/promote.sh"; : > "$JOBS_CALLS"; job "promoter status" "${LINE_ARGS[@]}"
t "every promoter word gives promote.sh this clone's hpcworker" bash -c "grep -qx 'promote.sh status HPCWORKER=$S/framework/bin/hpcworker' '$JOBS_CALLS'"
echo kept > "$P/code/promote.py"; echo 99 > "$T/sq.left"; : > "$JOBS_CALLS"; restart
t "a chain still ending after the polls is not started again, 75" bash -c "[ '$RC' = 75 ] && ! grep -q 'promote.sh start' '$JOBS_CALLS' && grep -qx kept '$P/code/promote.py'"
t "  says the chain may still run, and to read its status" has 'may still run on its old code; send promoter status'
t "  having stopped it again while the queue still listed it" bash -c "[ \"\$(grep -c '^promote.sh stop' '$JOBS_CALLS')\" = 4 ]"
rm -f "$T/sq.left"; cp "$JB/gh" "$T/gh.keep"; sed -i 's|\*contents/tools/promote.py?ref=|*nothing-matches|' "$JB/gh"; : > "$JOBS_CALLS"; restart
t "a fetch that fails stops nothing and changes nothing" bash -c "[ '$RC' = 1 ] && ! grep -q '^promote.sh' '$JOBS_CALLS' && grep -qx kept '$P/code/promote.py' && [ -z \"\$(ls '$P/code' | grep tmp)\" ]"
cp "$T/gh.keep" "$JB/gh"
printf '#!/bin/bash\nexit 1\n' > "$RB/squeue.err"; cp "$RB/squeue" "$RB/squeue.keep"; cp "$RB/squeue.err" "$RB/squeue"; : > "$JOBS_CALLS"; restart
t "a squeue that never answers starts nothing, 75" bash -c "[ '$RC' = 75 ] && ! grep -q 'promote.sh start' '$JOBS_CALLS' && grep -qx kept '$P/code/promote.py'"
cp "$RB/squeue.keep" "$RB/squeue"
printf '#!/bin/bash\necho "promote.sh $* HPCWORKER=$HPCWORKER" >> "%s"\n[ "$1" = stop ] && exit 123\nexit 0\n' "$JOBS_CALLS" > "$P/code/promote.sh"; chmod go-w "$P/code/promote.sh"
echo self > "$P/code/promote.py.tmp"; : > "$JOBS_CALLS"; restart
t "a stop that fails part way still restarts once the queue is empty" bash -c "[ '$RC' = 0 ] && grep -q '^promote.sh start $SHA' '$JOBS_CALLS'" && t "  saying what stop answered" has 'promote.sh stop answered 123'
t "  with this clone's hpcworker given to stop and start alike" bash -c "grep -qx 'promote.sh stop HPCWORKER=$S/framework/bin/hpcworker' '$JOBS_CALLS'"
t "  and a self-update's own .tmp left alone" bash -c "grep -qx self '$P/code/promote.py.tmp'"
rm -f "$P/code/promote.py.tmp"
chmod g+w "$P/code"; : > "$JOBS_CALLS"; restart
t "a code folder the group may write is refused before anything is fetched" bash -c "[ '$RC' = 126 ] && [ ! -s '$JOBS_CALLS' ]"
chmod g-w "$P/code"
mv "$P/code/promote.sh" "$T/promote.away"; rm -f "$P/code/promote.py"; : > "$JOBS_CALLS"; restart
t "a restart with no copy yet fetches both and starts, with nothing to stop" bash -c "[ '$RC' = 0 ] && [ \"\$(grep '^promote.sh' '$JOBS_CALLS')\" = 'promote.sh start $SHA' ] && [ -f '$P/code/promote.py' ]"
chmod g+w "$P/code/promote.sh"; : > "$JOBS_CALLS"; restart
t "a promote.sh the group may write is refused before anything is fetched or run" bash -c "[ '$RC' = 126 ] && [ ! -s '$JOBS_CALLS' ] && [ -z \"\$(ls '$P/code' | grep tmp)\" ]"
chmod g-w "$P/code/promote.sh"; rm -f "$T/promote.away"

SN="$HOME/SchwingNet"; SNE=(env GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t)
git init -q -b main "$T/snwork" && mkdir -p "$T/snwork/grid"
printf '#!/bin/bash\necho "gate.sh v1 $* SCHWINGNET=$SCHWINGNET" >> "%s"\necho "gate said $1"\n[ "$1" = leaks ] && exit 64\nexit 0\n' "$JOBS_CALLS" > "$T/snwork/grid/gate.sh"
"${SNE[@]}" git -C "$T/snwork" add grid && "${SNE[@]}" git -C "$T/snwork" commit -q -m one && git clone -q --bare "$T/snwork" "$T/sn-origin.git"
git -C "$T/snwork" remote add origin "$T/sn-origin.git"
: > "$JOBS_CALLS"; job "schwingnet status" "${LINE_ARGS[@]}"
t "schwingnet with no ~/SchwingNet clones it with gh" bash -c "grep -q '^gh repo clone OpenSpineConsortium/SchwingNet $SN' '$JOBS_CALLS' && [ -d '$SN/.git' ]"
t "  kept to the account" bash -c "[ -z \"\$(find '$SN' -maxdepth 0 -perm -g+w -o -maxdepth 0 -perm -o+w)\" ]"
t "  then runs grid/gate.sh with the word" bash -c "grep -qx 'gate.sh v1 status SCHWINGNET=$SN' '$JOBS_CALLS'"
t "  shows its output" has '^gate said status$' && t "  and says so" has '^HPCW-GRID-GATE schwingnet status ok$'
: > "$JOBS_CALLS"; job "schwingnet fetch vindr_pcxr" "${LINE_ARGS[@]}"
t "schwingnet fetch passes its one id to gate.sh" bash -c "grep -qx 'gate.sh v1 fetch vindr_pcxr SCHWINGNET=$SN' '$JOBS_CALLS' && ! grep -q 'repo clone' '$JOBS_CALLS'"
sed -i 's/gate.sh v1/gate.sh v2/' "$T/snwork/grid/gate.sh" && "${SNE[@]}" git -C "$T/snwork" commit -q -am two && git -C "$T/snwork" push -q origin main
: > "$JOBS_CALLS"; job "schwingnet start" "${LINE_ARGS[@]}"
t "schwingnet fast-forwards the clone to main before it runs gate.sh" bash -c "grep -qx 'gate.sh v2 start SCHWINGNET=$SN' '$JOBS_CALLS'"
t "  saying how far" has '^HPCW-GRID-GATE schwingnet pull ok '
sed -i 's/gate.sh v2/gate.sh v3/' "$T/snwork/grid/gate.sh" && "${SNE[@]}" git -C "$T/snwork" commit -q -am three && git -C "$T/snwork" push -q origin main
mkdir -p "$SN/grid/logs" && echo "41000 abc123" > "$SN/grid/logs/HOLD"; : > "$JOBS_CALLS"; job "schwingnet status" "${LINE_ARGS[@]}"
t "a HOLD keeps the checkout where it is" bash -c "grep -qx 'gate.sh v2 status SCHWINGNET=$SN' '$JOBS_CALLS'"
t "  and says whose" has '^HPCW-GRID-GATE schwingnet checkout held by grid/logs/HOLD: 41000 abc123$'
rm -f "$SN/grid/logs/HOLD"; : > "$JOBS_CALLS"; job "schwingnet status" "${LINE_ARGS[@]}"
t "  and once it is gone the next word moves it on" bash -c "grep -qx 'gate.sh v3 status SCHWINGNET=$SN' '$JOBS_CALLS'"
job "schwingnet leaks" "${LINE_ARGS[@]}"
t "a word gate.sh refuses keeps its answer, 64" bash -c "[ '$RC' = 64 ]" && t "  and says so" has '^HPCW-GRID-GATE schwingnet leaks failed 64$'
chmod o+w "$SN/grid"; : > "$JOBS_CALLS"; job "schwingnet status" "${LINE_ARGS[@]}"
t "a SchwingNet grid/ others may write is refused and gate.sh never runs" bash -c "[ '$RC' = 126 ] && ! grep -q gate.sh '$JOBS_CALLS'"
chmod o-w "$SN/grid"
mv "$SN" "$SN.away"; mkdir -m 700 "$SN"; : > "$JOBS_CALLS"; job "schwingnet status" "${LINE_ARGS[@]}"
t "a ~/SchwingNet that is no clone is refused, nothing cloned over it" bash -c "[ '$RC' = 126 ] && [ ! -s '$JOBS_CALLS' ]"
rmdir "$SN"; mv "$SN.away" "$SN"
: > "$JOBS_CALLS"; job "schwingnet census vindr_spinexr" "${LINE_ARGS[@]}"
t "schwingnet census passes its one id to gate.sh" bash -c "grep -Eqx 'gate.sh v[0-9]+ census vindr_spinexr SCHWINGNET=$SN' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "schwingnet explore kaggle_scoliosis_yolov5" "${LINE_ARGS[@]}"
t "schwingnet explore passes its one id to gate.sh" bash -c "grep -Eqx 'gate.sh v[0-9]+ explore kaggle_scoliosis_yolov5 SCHWINGNET=$SN' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "schwingnet dropzip rsna_rspect_pe" "${LINE_ARGS[@]}"
t "schwingnet dropzip passes its one id to gate.sh" bash -c "grep -Eqx 'gate.sh v[0-9]+ dropzip rsna_rspect_pe SCHWINGNET=$SN' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "schwingnet unpack rsna_rspect_pe" "${LINE_ARGS[@]}"
t "schwingnet unpack passes its one id to gate.sh" bash -c "grep -Eqx 'gate.sh v[0-9]+ unpack rsna_rspect_pe SCHWINGNET=$SN' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "schwingnet cancel 40704982" "${LINE_ARGS[@]}"
t "schwingnet cancel passes its one job to gate.sh" bash -c "grep -Eqx 'gate.sh v[0-9]+ cancel 40704982 SCHWINGNET=$SN' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "schwingnet chain_eval" "${LINE_ARGS[@]}"
t "schwingnet chain_eval goes to gate.sh with no id" bash -c "grep -Eqx 'gate.sh v[0-9]+ chain_eval SCHWINGNET=$SN' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "schwingnet samples" "${LINE_ARGS[@]}"
t "schwingnet samples goes to gate.sh with no id" bash -c "grep -Eqx 'gate.sh v[0-9]+ samples SCHWINGNET=$SN' '$JOBS_CALLS'"
: > "$JOBS_CALLS"; job "schwingnet nodequota" "${LINE_ARGS[@]}"
t "schwingnet nodequota goes to gate.sh with no id" bash -c "grep -Eqx 'gate.sh v[0-9]+ nodequota SCHWINGNET=$SN' '$JOBS_CALLS'"

for w in 'freeze start 9' 'freeze pilot amos22' 'freeze stop' 'freeze report now' 'promoter start abc' 'promoter restart now' 'promoter-restart' 'schwingnet xray-chain' 'schwingnet pull' 'schwingnet fetch VinDr' 'schwingnet fetch a b' 'schwingnet fetch' 'schwingnet census' 'schwingnet prior x' 'schwingnet samples x' 'schwingnet nodequota x' 'schwingnet chain-eval' 'schwingnet census a-b' 'schwingnet explore' 'schwingnet explore a b' 'schwingnet explore Kaggle-Set' 'schwingnet dropzip' 'schwingnet dropzip a b' 'schwingnet dropzip ../x' 'schwingnet unpack' 'schwingnet unpack a b' 'schwingnet unpack ../x' 'schwingnet cancel' 'schwingnet cancel 1 2' 'schwingnet status x' 'update now' 'update;id' 'schwingnet'; do
  : > "$JOBS_CALLS"; job "$w" "${LINE_ARGS[@]}"
  t "refuses the word '$w'" bash -c "[ '$RC' = 126 ] && [ ! -s '$JOBS_CALLS' ]"
done

# update: the stub clone made a git checkout of an origin in the test folder
GE=(env GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t)
"${GE[@]}" git -C "$S" init -q -b main && "${GE[@]}" git -C "$S" add tools framework && "${GE[@]}" git -C "$S" commit -q -m one
git clone -q --bare "$S" "$T/origin.git" && git -C "$S" remote add origin "$T/origin.git"
git clone -q "$T/origin.git" "$T/work" && echo 23 > "$T/work/framework/VERSION" && "${GE[@]}" git -C "$T/work" add framework/VERSION && "${GE[@]}" git -C "$T/work" commit -q -m two && git -C "$T/work" push -q origin main
chmod -R go-w "$S/tools" "$S/framework"
job update "${LINE_ARGS[@]}"
t "update fast-forwards the clone to origin's main" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$S/framework/VERSION')\" = 23 ]"
t "  and says from where to where, and the framework" has '^HPCW-GRID-GATE update ok [0-9a-f]{12}\.\.[0-9a-f]{12}$' && t "  the framework's version" has '^HPCW-GRID-GATE framework 23$'
t "  leaving tools/ and framework/ to the account alone" bash -c "[ -z \"\$(find '$S/tools' '$S/framework' -perm -g+w)\" ]"
job update "${LINE_ARGS[@]}"
t "update again says the clone is current" has '^HPCW-GRID-GATE update current [0-9a-f]{12}$'
"${GE[@]}" git -C "$S" commit -q --allow-empty -m local; job update "${LINE_ARGS[@]}"
git -C "$T/work" commit -q --allow-empty -m three 2>/dev/null || "${GE[@]}" git -C "$T/work" commit -q --allow-empty -m three; git -C "$T/work" push -q origin main
job update "${LINE_ARGS[@]}"
t "a clone holding a commit main has not is refused, never merged" bash -c "[ '$RC' = 126 ] && [ \"\$(git -C '$S' log -1 --format=%s)\" = local ]"
"${GE[@]}" git -C "$S" reset -q --hard HEAD~1; git -C "$S" checkout -q -b other; job update "${LINE_ARGS[@]}"
t "a clone on another branch is refused" bash -c "[ '$RC' = 126 ]" && t "  saying so" has 'refused branch'
git -C "$S" checkout -q main; echo 99 > "$S/framework/VERSION"; job update "${LINE_ARGS[@]}"
t "a clone with changed files is refused" bash -c "[ '$RC' = 126 ] && [ \"\$(cat '$S/framework/VERSION')\" = 99 ]"
git -C "$S" checkout -q -- framework/VERSION
KEEP_CLOCK=1 job update "${LINE_ARGS[@]}"; rm -f "$CH/jobs.last"; KEEP_CLOCK=1 PATH="$JB:$PATH" gate update "${LINE_ARGS[@]}"
t "update keeps the minute" has '^HPCW-GRID-GATE limit: one call a minute'

echo "== the job word artifacts: both repositories' artifacts/ kept in ~/claude-artifacts"
AE=(env GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t)
for r in symphony-template SchwingNet; do
  git init -q -b main "$T/aw-$r" && mkdir -p "$T/aw-$r/artifacts/one" "$T/aw-$r/tools"
  echo "# $r" > "$T/aw-$r/artifacts/README.md"; echo page > "$T/aw-$r/artifacts/one/index.html"; echo code > "$T/aw-$r/tools/x.py"
  echo "claim every issue" > "$T/aw-$r/CLAUDE.md"; echo "# top" > "$T/aw-$r/README.md"
  "${AE[@]}" git -C "$T/aw-$r" add . && "${AE[@]}" git -C "$T/aw-$r" commit -q -m one && git clone -q --bare "$T/aw-$r" "$T/ao-$r.git"
  # a server that serves a partial clone and the files it fetches later, as GitHub does
  git -C "$T/ao-$r.git" config uploadpack.allowFilter true && git -C "$T/ao-$r.git" config uploadpack.allowAnySHA1InWant true
  git -C "$T/aw-$r" remote add origin "$T/ao-$r.git"
done
# gh clones from the bare repositories with the options the gate gives git after --
cat > "$JB/gh" <<EOF2
#!/bin/bash
echo "gh \$*" >> "$JOBS_CALLS"
case "\$*" in
  "repo clone OpenSpineConsortium/symphony-template "*) d=\$4; shift 5; git clone "\$@" "file://$T/ao-symphony-template.git" "\$d"; exit \$?;;
  "repo clone OpenSpineConsortium/SchwingNet "*) d=\$4; shift 5; git clone "\$@" "file://$T/ao-SchwingNet.git" "\$d"; exit \$?;;
  *) exit 1;;
esac
EOF2
# git as it is, but as an old login node's when \$T/git-old is there, and failing its checkout when
# \$T/git-no-checkout is
REALGIT=$(command -v git)
cat > "$JB/git" <<EOF2
#!/bin/bash
[ -e "$T/git-old" ] && [ "\$1" = --version ] && { echo "git version 1.8.3.1"; exit 0; }
if [ -e "$T/git-no-checkout" ]; then for a in "\$@"; do [ "\$a" = read-tree ] && exit 1; done; fi
exec "$REALGIT" "\$@"
EOF2
chmod 755 "$JB/gh" "$JB/git"
AD="$HOME/claude-artifacts"
: > "$JOBS_CALLS"; job artifacts "${LINE_ARGS[@]}"
t "artifacts clones both repositories with gh into ~/claude-artifacts" bash -c "[ '$RC' = 0 ] && grep -q '^gh repo clone OpenSpineConsortium/symphony-template $AD/symphony-template' '$JOBS_CALLS' && grep -q '^gh repo clone OpenSpineConsortium/SchwingNet $AD/SchwingNet' '$JOBS_CALLS'"
t "  as partial clones with nothing checked out by the clone" bash -c "[ \$(grep -c -- '--no-checkout --filter=blob:none' '$JOBS_CALLS') = 2 ] && [ -n \"\$(git -C '$AD/SchwingNet' rev-list --objects --missing=print HEAD | grep '^?')\" ]"
t "  checking out artifacts/ alone, no top-level file and no other folder" bash -c "[ -f '$AD/SchwingNet/artifacts/one/index.html' ] && [ ! -e '$AD/SchwingNet/tools' ] && [ ! -e '$AD/SchwingNet/CLAUDE.md' ] && [ ! -e '$AD/symphony-template/README.md' ]"
t "  every fetch there through gh's sign-in" bash -c "git -C '$AD/SchwingNet' config --get-all credential.helper | grep -q 'gh auth git-credential\$' && [ \"\$(git -C '$AD/SchwingNet' config --get-all credential.helper | head -1)\" = '' ]"
t "  in a folder kept to the account" bash -c "[ \"\$(stat -c %a '$AD')\" = 700 ]"
t "  with its CLAUDE.md" bash -c "grep -q 'patent material' '$AD/CLAUDE.md'"
t "  and says how many folders each holds" has '^HPCW-GRID-GATE artifacts SchwingNet 1 folders at [0-9a-f]{12}$' && t "  and that it is done" has '^HPCW-GRID-GATE artifacts ok '
mkdir -p "$T/aw-SchwingNet/artifacts/two" && echo doc > "$T/aw-SchwingNet/artifacts/two/index.md"
"${AE[@]}" git -C "$T/aw-SchwingNet" add . && "${AE[@]}" git -C "$T/aw-SchwingNet" commit -q -m two && git -C "$T/aw-SchwingNet" push -q origin main
: > "$JOBS_CALLS"; job artifacts "${LINE_ARGS[@]}"
t "artifacts again fast-forwards each clone, fetching the new file, cloning nothing" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$AD/SchwingNet/artifacts/two/index.md')\" = doc ] && ! grep -q 'repo clone' '$JOBS_CALLS'"
t "  saying how far" has '^HPCW-GRID-GATE artifacts pull SchwingNet ok [0-9a-f]{12}\.\.[0-9a-f]{12}$' && t "  and the other is current" has '^HPCW-GRID-GATE artifacts pull symphony-template current '
git -C "$AD/SchwingNet" remote set-url origin "file://$T/no-such-three.git"; job artifacts "${LINE_ARGS[@]}"
t "a pull git cannot make fails" bash -c "[ '$RC' = 1 ]" && t "  saying so" has '^HPCW-GRID-GATE artifacts pull SchwingNet failed'
t "  without git's own words, which may name the artifacts' files" bash -c "! printf '%s\n' \"\$OUT\" | grep -q 'no-such-three'"
t "  the other's count still given" has '^HPCW-GRID-GATE artifacts symphony-template 1 folders'
git -C "$AD/SchwingNet" remote set-url origin "file://$T/ao-SchwingNet.git"; job artifacts "${LINE_ARGS[@]}"
t "  and the next call pulls again" bash -c "[ '$RC' = 0 ]"
echo edited > "$AD/SchwingNet/artifacts/one/index.html"; job artifacts "${LINE_ARGS[@]}"
t "a clone with a changed file is refused, the other still pulled" bash -c "[ '$RC' = 126 ]" && t "  saying so" has 'refused changes' && t "  the other's count still given" has '^HPCW-GRID-GATE artifacts symphony-template 1 folders'
git -C "$AD/SchwingNet" checkout -q -- artifacts/one/index.html
chmod g+w "$AD/SchwingNet"; job artifacts "${LINE_ARGS[@]}"
t "a clone the group may write is refused" bash -c "[ '$RC' = 126 ]" && t "  saying so" has "refused copy: others may change $AD/SchwingNet"
chmod g-w "$AD/SchwingNet"
mv "$AD/symphony-template" "$T/st.away"; touch "$T/git-no-checkout"
: > "$JOBS_CALLS"; job artifacts "${LINE_ARGS[@]}"
t "a clone whose checkout fails is not left half made" bash -c "[ '$RC' = 1 ] && [ ! -e '$AD/symphony-template' ]" && t "  saying so" has '^HPCW-GRID-GATE artifacts failed: git could not check out'
rm -f "$T/git-no-checkout"; job artifacts "${LINE_ARGS[@]}"
t "  and the next call clones it whole" bash -c "[ '$RC' = 0 ] && [ -f '$AD/symphony-template/artifacts/one/index.html' ]"
rm -rf "$AD/symphony-template"; touch "$T/git-old"
: > "$JOBS_CALLS"; job artifacts "${LINE_ARGS[@]}"
t "an older git clones the whole history, with no filter" bash -c "[ '$RC' = 0 ] && grep -q -- '--no-checkout\$' '$JOBS_CALLS' && ! grep -q -- '--filter' '$JOBS_CALLS'"
t "  and still checks out artifacts/ alone" bash -c "[ -f '$AD/symphony-template/artifacts/one/index.html' ] && [ ! -e '$AD/symphony-template/CLAUDE.md' ] && [ ! -e '$AD/symphony-template/tools' ]"
rm -f "$T/git-old"
"${AE[@]}" git -C "$T/aw-SchwingNet" rm -q -r artifacts && "${AE[@]}" git -C "$T/aw-SchwingNet" commit -q -m gone && git -C "$T/aw-SchwingNet" push -q origin main
job artifacts "${LINE_ARGS[@]}"
t "a main with no artifacts/ fails, never says ok" bash -c "[ '$RC' = 1 ]" && t "  saying so" has 'could not check out the artifacts/' && t "  and not ok" bash -c "! printf '%s\n' \"\$OUT\" | grep -q '^HPCW-GRID-GATE artifacts ok'"
for w in 'artifacts now' 'artifacts;id' 'artifacts SchwingNet'; do
  : > "$JOBS_CALLS"; job "$w" "${LINE_ARGS[@]}"
  t "refuses the word '$w'" bash -c "[ '$RC' = 126 ] && [ ! -s '$JOBS_CALLS' ]"
done
rm -f "$JB/git"
unset HPCW_LAB_ROOT

echo "== the key word: one service key from stdin into its file"
kw() { # WORD STDIN: the gate with its clock for keys forgotten
  rm -f "$CH/keys.last"
  OUT=$(printf '%s' "$2" | env SSH_ORIGINAL_COMMAND="$1" SSH_CONNECTION="192.0.2.7 50000 10.0.0.1 22" bash "$S/tools/grid_gate.sh" "${LINE_ARGS[@]}" 2>&1); RC=$?
}
mode() { stat -c %a "$1"; }
KG=KGAT_0123456789abcdefTESTONLY
kw "key kaggle" "$KG"$'\n'
t "key kaggle writes ~/.fluorocap/credentials.env" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$HOME/.fluorocap/credentials.env')\" = 'KAGGLE_API_TOKEN=$KG' ]"
t "  the file 0600 and its folder 0700" bash -c "[ \"\$(stat -c %a '$HOME/.fluorocap/credentials.env')\" = 600 ] && [ \"\$(stat -c %a '$HOME/.fluorocap')\" = 700 ]"
t "  says ok and names the file" has '^HPCW-GRID-GATE key kaggle ok ~/.fluorocap/credentials.env \(0600\)$'
t "  and the key is in neither the answer nor the log" bash -c "! printf '%s' \"\$1\" | grep -q TESTONLY && ! grep -q TESTONLY '$CH/gate.log'" _ "$OUT"
printf 'OTHER=keep\nexport KAGGLE_API_TOKEN=old\nKAGGLE_USERNAME=me\n' > "$HOME/.fluorocap/credentials.env"; chmod 644 "$HOME/.fluorocap/credentials.env"
kw "key kaggle" "${KG}2"$'\n'
t "a second key replaces only its own line, every other kept, and the file is 0600 again" bash -c "[ \"\$(cat '$HOME/.fluorocap/credentials.env')\" = \"\$(printf 'OTHER=keep\nKAGGLE_USERNAME=me\nKAGGLE_API_TOKEN=${KG}2')\" ] && [ \"\$(stat -c %a '$HOME/.fluorocap/credentials.env')\" = 600 ]"
for kv in "hf .hf/token.env HF_TOKEN" "zenodo .zenodo/token.env ZENODO_TOKEN" "redivis .redivis/token.env REDIVIS_API_TOKEN" "wandb .wandb/token.env WANDB_API_KEY"; do
  set -- $kv
  kw "key $1" "tok_${1}_0123456789"$'\n'
  t "key $1 writes ~/$2 as $3=" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$HOME/$2')\" = '$3=tok_${1}_0123456789' ]"
done
printf 'machine api.wandb.ai\n  login user\n  password wb\nmachine physionet.org login old password old\n' > "$HOME/.netrc"; chmod 600 "$HOME/.netrc"
kw "key physionet" 'greg pass#Word!1'$'\n'
t "key physionet replaces the physionet.org line of ~/.netrc, the others kept" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$HOME/.netrc')\" = \"\$(printf 'machine api.wandb.ai\n  login user\n  password wb\nmachine physionet.org login greg password pass#Word!1')\" ]"
printf 'machine physionet.org\n  login old\n  password old\n' > "$HOME/.netrc"
kw "key physionet" 'greg newpass'$'\n'
t "  and refuses an entry over several lines, the file untouched" bash -c "[ '$RC' = 126 ] && grep -q 'password old' '$HOME/.netrc' && ! grep -q newpass '$HOME/.netrc'"
LINK='https://example-bucket.s3.amazonaws.com/ratic.zip?X-Amz-Algorithm=AWS4&X-Amz-Signature=ab%2Fcd'
kw "key ratic" "$LINK"$'\n'
t "key ratic writes the link as ~/.rsna/ratic_link's one line" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$HOME/.rsna/ratic_link')\" = '$LINK' ]"
for bad in "" "short" "has space in it" 'semi;colon_token' 'quote"token123' $'line\nbreak_and_more'; do
  kw "key hf" "$bad"
  t "a key not of its shape ($(printf '%q' "$bad")) is refused and the file kept" bash -c "[ '$RC' = 126 ] && printf '%s' \"\$1\" | grep -q 'refused key' && [ \"\$(cat '$HOME/.hf/token.env')\" = 'HF_TOKEN=tok_hf_0123456789' ]" _ "$OUT"
done
kw "key physionet" 'greg pass"word'$'\n'
t "a netrc password with a quote is refused" rc_is 126
kw "key ratic" 'http://plain.example/x.zip'$'\n'
t "a link that is not https is refused" rc_is 126
for w in 'key' 'key kaggle extra' 'key foo' 'key ../x' 'key  hf' 'key hf;id'; do
  kw "$w" "tok_0123456789"$'\n'
  t "the word $(printf '%q' "$w") is refused" bash -c "[ '$RC' = 126 ] && printf '%s\n' \"\$1\" | grep -q '^HPCW-GRID-GATE refused word'" _ "$OUT"
done
printf 'other\n' > "$T/elsewhere"; rm -f "$HOME/.zenodo/token.env"; ln -s "$T/elsewhere" "$HOME/.zenodo/token.env"
kw "key zenodo" "tok_zenodo_new0123"$'\n'
t "a key file that is a link is refused and what it points at untouched" bash -c "[ '$RC' = 126 ] && [ \"\$(cat '$T/elsewhere')\" = other ]"
rm -f "$HOME/.zenodo/token.env"
rm -rf "$HOME/.redivis"; ln -s "$T" "$HOME/.redivis"
kw "key redivis" "tok_redivis_0123"$'\n'
t "a key folder that is a link is refused" bash -c "[ '$RC' = 126 ] && [ ! -e '$T/token.env' ]"
rm -f "$HOME/.redivis"
kw "key wandb" "tok_wandb_0123456789"$'\n'
OUT=$(printf 'tok_wandb_9876543210\n' | env SSH_ORIGINAL_COMMAND="key wandb" bash "$S/tools/grid_gate.sh" "${LINE_ARGS[@]}" 2>&1); RC=$?
t "keys keep a floor of a few seconds of their own" bash -c "[ '$RC' = 123 ] && printf '%s' \"\$1\" | grep -q 'every 3 seconds'" _ "$OUT"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
