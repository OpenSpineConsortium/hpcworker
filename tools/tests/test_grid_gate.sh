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
cat > "$S/tools/grid_runner.sh" <<'EOF'
#!/bin/bash
{ printf '%s\n' "$*"; printf 'HPCW_GATE=%s GH_TOKEN=%s BASH_ENV=%s\n' "${HPCW_GATE:-}" "${GH_TOKEN:-}" "${BASH_ENV:-}"; } >> "$STUB_CALLS"
[ -t 0 ] && echo "stdin is a terminal"
printf '%s\n' "${STUB_OUT:-}"
exit "${STUB_RC:-0}"
EOF
export STUB_CALLS="$T/stub.calls"; : > "$STUB_CALLS"

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
  if [ "$w" = -unset ]; then OUT=$(env -u SSH_ORIGINAL_COMMAND SSH_CONNECTION="192.0.2.7 50000 10.0.0.1 22" GH_TOKEN=gho_marker BASH_ENV="$T/bash_env" bash "$S/tools/grid_gate.sh" "$@" < /dev/null 2>&1)
  else OUT=$(env SSH_ORIGINAL_COMMAND="$w" SSH_CONNECTION="192.0.2.7 50000 10.0.0.1 22" GH_TOKEN=gho_marker BASH_ENV="$T/bash_env" bash "$S/tools/grid_gate.sh" "$@" < /dev/null 2>&1); fi
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
t "  with HPCW_GATE set, the client's GH_TOKEN and BASH_ENV gone, stdin no terminal" bash -c "tail -1 '$STUB_CALLS' | grep -qx 'HPCW_GATE=1 GH_TOKEN= BASH_ENV=' && ! grep -q 'terminal' <<< \"\$1\"" _ "$OUT"
gate start "${LINE_ARGS[@]}"
t "start runs --start with the line's size" bash -c "tail -2 '$STUB_CALLS' | head -1 | grep -qx -- '--start --repo $GH_REPO --runner-dir $RD --site wayne --hours 6 --gres gpu:1'"
t "  and exits 0" rc_is 0
gate stop "${LINE_ARGS[@]}"
t "stop runs --stop, never --now" bash -c "tail -2 '$STUB_CALLS' | head -1 | grep -qx -- '--stop --repo $GH_REPO --runner-dir $RD --site wayne'"
STUB_OUT="grid_runner: a chain for $GH_REPO is already queued or running (job 41 RUNNING); tools/grid_runner.sh --stop --repo $GH_REPO ends it" STUB_RC=1 gate start "${LINE_ARGS[@]}"
t "start on a chain already running is no failure" rc_is 0
t "  and says running" has '^HPCW-GRID-GATE running$'
STUB_OUT="grid_runner: sbatch refused the chain's first job: no partition" STUB_RC=1 gate start "${LINE_ARGS[@]}"
t "start that fails passes the failure on" rc_is 1
t "  with grid_runner's words" has 'sbatch refused'
t "  and the gate's" has '^HPCW-GRID-GATE start failed 1$'

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
chmod 700 "$T"
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
typed --gate-key "$KEY2" --repo OpenSpineConsortium/other --runner-dir "$RD"
t "another repository's gate is a line of its own" bash -c "[ \"\$(grep -c 'hpcw-grid-gate:' '$AK')\" = 2 ] && grep -q 'command=\"$GATE --runner-dir $RD --repo OpenSpineConsortium/other\"' '$AK'"
typed --gate-key "$KEY2" --repo OpenSpineConsortium/symphony-templateX --runner-dir "$RD"
typed --gate-off --repo "$GH_REPO" --runner-dir "$RD"
typed --gate-key "$KEY2" --repo "$GH_REPO" --site wayne --runner-dir "$RD"
t "a repository whose name extends another's is not taken for it" bash -c "grep -q 'hpcw-grid-gate:$GH_REPO\$' '$AK' && grep -q 'hpcw-grid-gate:OpenSpineConsortium/symphony-templateX\$' '$AK'"
typed --gate-off --repo OpenSpineConsortium/symphony-templateX --runner-dir "$RD"
t "  and --gate-off of the longer name leaves the shorter's" bash -c "grep -q 'hpcw-grid-gate:$GH_REPO\$' '$AK' && ! grep -q 'symphony-templateX' '$AK'"
OUT=$(cat "$AK"); OLD=$OUT
typed --gate-key "$KEY2" --repo "$GH_REPO" --site wayne --runner-dir "$RD"
t "the same line again changes nothing" bash -c "[ '$RC' = 0 ] && printf '%s' \"\$1\" | grep -q 'already'" _ "$OUT"
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
