#!/usr/bin/env bash
# Tests for the grid's CI lane: tools/grid_ci.sh (one run, --deploy, and the watcher: --watch,
# --unwatch and each tick), tools/grid_ci_watch.sbatch, tools/grid_deploy.sbatch and
# tools/version_check.sh. Linux only; nothing reaches GitHub, a scheduler or the grid. Everything
# happens in a temporary folder under /tmp: GitHub's repository is a local bare one (git's
# url.<base>.insteadOf in a HOME of the test's own), gh is tests/shim/gh (statuses and check runs as
# files; --jq through the real jq), sbatch, squeue, sacct and scancel are tests/shim/slurm (a scheduler
# that runs nothing and refuses a path outside the test's folder or a job with no wall time), and sleep
# is tests/shim/nosleep (it records the wait and returns). A job "runs" when the test runs its copied
# script the way Slurm would (its -D folder, its arguments, SLURM_JOB_ID), or, for the suite and the
# install, when the test writes its state and its log (or, for an install that must refuse before
# deploy_shared, runs its copied script). The install's logs are tools/deploy_shared.sh's own output,
# made here with --here into a temporary root. Every sbatch that takes a job also writes a warning to
# stderr, as a site's submit plugin may, so every job number is read from among other words. GITHUB_TOKEN and GH_TOKEN are set to marker
# values the whole time, and no stand-in may ever see them. KEEP_T=1 keeps the temporary folder.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
GC="$REPO/tools/grid_ci.sh"
SHIMS="$REPO/tools/tests/shim"
command -v jq >/dev/null 2>&1 || { echo "jq is needed: the gh stand-in runs grid_ci.sh's --jq expression through it"; exit 1; }
T=$(mktemp -d /tmp/grid_ci_test.XXXXXX) || exit 1
T=$(cd "$T" && pwd -P)
cleanup() { chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
if [ -n "${KEEP_T:-}" ]; then echo "keeping $T"; else trap cleanup EXIT; fi

# git: nothing of this machine's configuration or of a hook that started us, and https://github.com/
# is the local remote
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null)
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 USER=${USER:-$(id -un)}
mkdir -p "$HOME" "$T/bin" "$T/remote/OpenSpineConsortium" "$T/tmp"
git config --global user.name "grid ci test"; git config --global user.email test@example.invalid
git config --global url."$T/remote/".insteadOf https://github.com/
for s in slurm gh nosleep; do cp "$SHIMS/$s" "$T/bin/$s.shim" && chmod 755 "$T/bin/$s.shim"; done
for s in sbatch squeue sacct scancel; do ln -s slurm.shim "$T/bin/$s"; done
ln -s gh.shim "$T/bin/gh"; ln -s nosleep.shim "$T/bin/sleep"
export PATH="$T/bin:$PATH" SHIM_SLURM="$T/slurm" SHIM_SLURM_ROOT="$T" SHIM_GH="$T/gh" SHIM_SLEEPS="$T/sleeps"
export HPCW_CI_DIR="$T/ci"   # never the lab volume's default
unset HPCW_CI_PARTITION HPCW_CI_QOS SLURM_JOB_ID
export GITHUB_TOKEN=ghp_testtoken_must_not_leak GH_TOKEN=gho_testtoken_must_not_leak
mkdir -p "$T/slurm" "$T/gh"; : > "$T/slurm/calls"; : > "$T/gh/calls"; : > "$T/gh/statuses"; : > "$T/sleeps"
echo "sbatch: Warning: this job may be preempted and requeued" > "$T/slurm/warn"
# getfacl and setfacl for an install job the test runs (it refuses without them)
ACL="$T/aclbin"; mkdir -p "$ACL"
for b in getfacl setfacl; do printf '#!/bin/sh\nexit 0\n' > "$ACL/$b"; chmod 755 "$ACL/$b"; done
CI="$T/ci/OpenSpineConsortium-hpcworker"; WATCH="$T/ci/watch"
VER=$(tr -d '[:space:]' < "$REPO/framework/VERSION")
DEF_PART=$(sed -n 's/^#SBATCH --partition=//p' "$REPO/tools/grid_ci.sbatch"); DEF_QOS=$(sed -n 's/^#SBATCH --qos=//p' "$REPO/tools/grid_ci.sbatch")

pass=0 fail=0 OUT="" RC=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }
t() { local d=$1; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
# grep without -q after a pipe: under pipefail, grep -q leaving early fails the writer with SIGPIPE
has() { printf '%s\n' "$OUT" | grep -E -- "$1" >/dev/null; }
lacks() { ! has "$1"; }
rc_is() { [ "$RC" = "$1" ]; }
# a person's run waits on its jobs in a loop: a job number misread would make it wait for ever
TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout 120)
gc() { OUT=$(${TO[@]+"${TO[@]}"} bash "$GC" "$@" 2>&1); RC=$?; }
J() { cat "$T/slurm/jobs/$1/$2" 2>/dev/null; }
ids() { local j; for j in $(ls "$T/slurm/jobs" 2>/dev/null | sort -n); do [[ "$(J "$j" name)" =~ $1 ]] && echo "$j"; done; return 0; }
count() { ids "$1" | grep -c . ; }
newest() { ids "$1" | tail -1; }
pending_watch() { local j; for j in $(ids '^hpcw_ci_watch$'); do [ "$(J "$j" state)" = PENDING ] && echo "$j"; done; return 0; }
calls() { grep -c "^$1 " "$T/slurm/calls"; }
set_state() { echo "$2" > "$T/slurm/jobs/$1/state"; }
write_log() { printf '%s\n' "$2" > "$(J "$1" out)"; }
run_tick() { # ID: the job as Slurm runs it: in its -D folder, its copied script, its arguments, its id
  local id=$1 args=()
  mapfile -t args < "$T/slurm/jobs/$id/args"
  set_state "$id" RUNNING
  OUT=$(cd "$(J "$id" dir)" && SLURM_JOB_ID=$id bash "$T/slurm/jobs/$id/script" "${args[@]}" 2>&1); RC=$?
  if [ "$RC" = 0 ]; then set_state "$id" COMPLETED; else set_state "$id" FAILED; fi
}
tick() { run_tick "$(pending_watch | head -1)"; }
run_job() { # ID [VAR=VALUE...]: a submitted job's copied script as Slurm runs it, its output in its log
  local id=$1 args=(); shift
  mapfile -t args < "$T/slurm/jobs/$id/args"
  set_state "$id" RUNNING
  ( cd "$(J "$id" dir)" && env "$@" SLURM_JOB_ID="$id" bash "$T/slurm/jobs/$id/script" ${args[@]+"${args[@]}"} ) > "$(J "$id" out)" 2>&1; RC=$?
  OUT=$(cat "$(J "$id" out)")
  if [ "$RC" = 0 ]; then set_state "$id" COMPLETED; else set_state "$id" FAILED; fi
}
last_st() { awk -F'\t' -v s="$1" -v c="$2" '$1 == s && $2 == c { st = $3 } END { print st }' "$T/gh/statuses"; }
st() { awk -F'\t' -v s="$1" -v c="$2" -v t="$3" '$1 == s && $2 == c && $3 == t { print $4 }' "$T/gh/statuses"; }
st_is() { st "$1" "$2" "$3" | grep -E -- "$4" >/dev/null; }
n_posted() { awk -F'\t' -v s="$1" '$1 == s' "$T/gh/statuses" | grep -c . ; }

# the remote: the files a run checks out (the scripts, the container check), one commit per change
BARE="$T/remote/OpenSpineConsortium/hpcworker.git"; W="$T/work"
git init -q --bare "$BARE" && git -C "$BARE" symbolic-ref HEAD refs/heads/main
git init -q "$W" && git -C "$W" symbolic-ref HEAD refs/heads/main
mkdir -p "$W/tools" "$W/framework/tests/grid"
for f in grid_ci.sh grid_ci.sbatch grid_ci_watch.sbatch grid_deploy.sbatch deploy_shared.sh; do cp "$REPO/tools/$f" "$W/tools/"; done
cp "$REPO/framework/tests/grid/slurm_in_container.sbatch" "$W/framework/tests/grid/"
echo "# as in the test's first commit" >> "$W/tools/grid_ci.sh"   # the watcher's refresh shows by this line
commit() { echo "$1" > "$W/note"; git -C "$W" add -A && git -C "$W" commit -q -m "$1" && git -C "$W" push -q "$BARE" HEAD:main && git -C "$W" rev-parse HEAD; }
checks() { # SHA NAME:STATUS:CONCLUSION... -> GitHub's check runs on the commit
  local sha=$1 c n s k first=1; shift
  { printf '{"total_count":%d,"check_runs":[' $#
    for c in "$@"; do IFS=: read -r n s k <<< "$c"; [ $first = 1 ] || printf ','; first=0
      printf '{"name":"%s","status":"%s","conclusion":%s}' "$n" "$s" "$([ -n "$k" ] && printf '"%s"' "$k" || printf null)"; done
    printf ']}'; } > "$T/gh/checks/$sha"
}
mkdir -p "$T/gh/checks"
green() { checks "$1" "suite (ubuntu, current python):completed:success" "suite (centos 7, python 3.6, bash 4.2):completed:success" "framework version:completed:skipped"; }
SUITE_OK=$'host n042 2026-10-07T12:00:00Z python Python 3.6.8 bash 4.2.46(2)-release\n== python unittest\nRan 412 tests in 530.204s\n\nOK\nALL OK\nexit 0'
SUITE_BAD=$'host n042 2026-10-07T12:00:00Z python Python 3.6.8 bash 4.2.46(2)-release\nRan 412 tests in 530.204s\nFAILED (failures=1)\nFAILURES\nexit 1'

# the install's logs: tools/deploy_shared.sh --here's own words, into a temporary root (no ACLs there)
PUB="$T/pub/hpcworker"; mkdir -p "$T/pub"
dlog() { ( cd "$REPO" && TMPDIR="$T/tmp" bash tools/deploy_shared.sh --here --root "$PUB" 2>&1 ); }
LOG_NEW=$(dlog); r1=$?
LOG_SAME=$(dlog); r2=$?
chmod u+w "$PUB/v$VER/README.md" && echo "a line a person added" >> "$PUB/v$VER/README.md"
LOG_README=$(dlog); r3=$?
chmod u+w "$PUB/v$VER/lib/profile.py" && echo "# a line a person added" >> "$PUB/v$VER/lib/profile.py"
LOG_DIFF=$(dlog); r4=$?
OUT="$LOG_NEW"$'\n'"$LOG_SAME"$'\n'"$LOG_README"$'\n'"$LOG_DIFF"
t "fixture: deploy_shared --here published v$VER, then same, then README in place, then refused other files" eval '[ "$r1$r2$r3$r4" = 0001 ] && has "is published with different files:$" && has "^   published v$VER$" && has "README.md updated in place"'

echo "== bash -n"
for f in tools/grid_ci.sh tools/grid_ci_watch.sbatch tools/grid_deploy.sbatch tools/grid_ci.sbatch tools/version_check.sh tools/tests/shim/slurm tools/tests/shim/gh tools/tests/shim/nosleep; do
  OUT=$(bash -n "$REPO/$f" 2>&1); t "bash -n $f" [ -z "$OUT" ]
done

C1=$(commit one)

echo "== --watch, on the login node"
gc --watch --every 4
t "--every under 5 minutes: refused, the scheduler not asked" eval 'rc_is 1 && has "5 to 1440" && [ ! -s "$T/slurm/calls" ]'
gc --watch --ref main
t "--watch with --ref: refused (the watcher follows main)" eval 'rc_is 1 && has "no --ref, no --deploy"'
gc --watch --every 5 --container --site testsite
W1=$(newest '^hpcw_ci_watch$')
t "--watch: one squeue and one sbatch, and nothing else (no clone, no gh)" eval 'rc_is 0 && [ "$(grep -c . "$T/slurm/calls")" = 2 ] && [ "$(calls squeue)" = 1 ] && [ "$(calls sbatch)" = 1 ] && [ ! -e "$CI" ] && [ ! -s "$T/gh/calls" ]'
t "--watch: the squeue asks for this account's hpcw_ci_watch jobs" eval 'grep -q "^squeue -h -u $USER -n hpcw_ci_watch " "$T/slurm/calls"'
same_bin() { local f; for f in grid_ci.sh grid_ci_watch.sbatch grid_ci.sbatch; do cmp -s "$WATCH/bin/$f" "$1/$f" || return 1; done; }
t "--watch: the watcher's own copy of its three scripts in watch/bin" same_bin "$REPO/tools"
t "--watch: the tick runs from that copy, in the watcher's folder, singleton, at once" eval '[ "$(J $W1 dir)" = "$WATCH" ] && cmp -s "$T/slurm/jobs/$W1/script" "$REPO/tools/grid_ci_watch.sbatch" && [ "$(J $W1 dependency)" = singleton ] && [ -z "$(J $W1 begin)" ]'
t "--watch: on grid_ci.sbatch's own partition and QoS" eval '[ -n "$DEF_PART" ] && [ "$(J $W1 partition)" = "$DEF_PART" ] && [ "$(J $W1 qos)" = "$DEF_QOS" ]'
t "--watch: the tick's arguments carry the watcher's settings" eval '[ "$(J $W1 args | tr "\n" " ")" = "--tick --repo OpenSpineConsortium/hpcworker --every 5 --ci-dir $T/ci --container --site testsite " ]'
gc --watch
t "--watch again: refused while a tick is queued, names it; one more squeue, no sbatch" eval 'rc_is 1 && has "already queued or running \(job $W1 PENDING" && [ "$(calls squeue)" = 2 ] && [ "$(calls sbatch)" = 1 ]'

echo "== a tick: GitHub's checks not finished"
checks "$C1" "suite (ubuntu, current python):in_progress:"
tick
W2=$(newest '^hpcw_ci_watch$')
t "tick: clones on the compute node, waits for GitHub, submits nothing for the commit, posts nothing" eval 'rc_is 0 && [ -d "$CI/src/.git" ] && has "main is $C1" && has "checks are not finished" && [ "$(count "^hpcw_ci_(suite|check|deploy)")" = 0 ] && [ ! -s "$T/gh/statuses" ]'
t "tick: exactly one successor, in 5 minutes, singleton, the same arguments" eval '[ "$(pending_watch)" = "$W2" ] && [ "$(J $W2 begin)" = now+5minutes ] && [ "$(J $W2 dependency)" = singleton ] && [ "$(J $W2 args)" = "$(J $W1 args)" ] && [ "$(J $W2 partition)" = "$DEF_PART" ]'
t "tick: the successor is queued before main is fetched" eval 'printf "%s\n" "$OUT" | awk "/next tick: job/ && !n { n = NR } /^main is / && !m { m = NR } END { exit !(n && m && n < m) }"'
n=$(calls sbatch)
run_tick "$W1"
t "the same tick run again (a requeue): no second successor" eval 'rc_is 0 && has "queued by an earlier run of this job" && [ "$(calls sbatch)" = $n ] && [ "$(pending_watch)" = "$W2" ]'
echo "$W1" > "$WATCH/next.submitting"; rm -f "$WATCH/next"
nq=$(calls squeue)
run_tick "$W1"
t "stopped between its successor's sbatch and writing it down: one squeue finds it, no second" eval 'rc_is 0 && [ "$(calls sbatch)" = $n ] && [ "$(calls squeue)" = $((nq + 1)) ] && [ "$(pending_watch)" = "$W2" ] && [ ! -e "$WATCH/next.submitting" ]'
t "the tick's log names its job and its node" eval 'has "^== tick $W1 on " && [ -s "$WATCH/last-tick" ]'
t "sbatch's warning beside the number: the successor's record is the two job numbers alone" eval '[ "$(cat "$WATCH/next")" = "$W1 $W2" ]'

echo "== GitHub's checks green: the suite and the container check"
green "$C1"
tick
S1=$(newest "^hpcw_ci_suite_${C1:0:12}$"); K1=$(newest "^hpcw_ci_check_${C1:0:12}$"); R1="$CI/auto-$C1"
t "main's head written down beside the clone, for the install job" eval '[ "$(cat "$CI/main-head")" = "$C1" ]'
t "the suite: one job named by the commit, from the commit's own worktree, in its run folder" eval '[ "$(count "^hpcw_ci_suite_")" = 1 ] && [ "$(J $S1 dir)" = "$R1" ] && cmp -s "$T/slurm/jobs/$S1/script" "$R1/src/tools/grid_ci.sbatch" && [ "$(cat "$R1/suite.job")" = $S1 ]'
t "the suite keeps its own header's queue (no override given)" eval '[ -z "$(J $S1 partition)" ] && [ -z "$(J $S1 qos)" ]'
t "the container check: one job, handed the commit's framework" eval '[ "$(count "^hpcw_ci_check_")" = 1 ] && [ "$(J $K1 args)" = "$R1/src/framework" ]'
t "posted: suite pending, container pending, deploy pending" eval 'st_is $C1 grid/framework-suite-py36 pending "suite queued" && st_is $C1 grid/slurm-in-container pending queued && st_is $C1 grid/deploy pending "waiting for the grid suite"'
tick
t "the next tick: no second suite or container check for the commit" eval '[ "$(count "^hpcw_ci_suite_")" = 1 ] && [ "$(count "^hpcw_ci_check_")" = 1 ] && has "suite: job $S1 PENDING"'
mv "$R1/suite.job" "$T/suite.job.kept"; date +%s > "$R1/suite.submitting"
n=$(calls sbatch)
tick
t "a suite submitted but never written down: found by its name in one sacct, not submitted again" eval '[ "$(cat "$R1/suite.job" 2>/dev/null)" = $S1 ] && [ ! -e "$R1/suite.submitting" ] && [ "$(count "^hpcw_ci_suite_")" = 1 ] && [ "$(calls sbatch)" = $((n + 1)) ] && grep -q "^sacct .*-S .*--name .*hpcw_ci_suite_${C1:0:12}" "$T/slurm/calls"'
rm -f "$R1/suite.job"; echo $(( $(date +%s) - 120 )) > "$R1/suite.submitting"
mv "$T/slurm/jobs/$S1" "$T/slurm/hidden"   # the accounting has not seen it yet
n=$(calls sbatch)
tick
t "a submission the accounting has not seen yet, two minutes old: wait, never a second" eval '[ "$(calls sbatch)" = $((n + 1)) ] && has "not yet in the scheduler.s accounting; waiting" && [ -e "$R1/suite.submitting" ]'
mv "$T/slurm/hidden" "$T/slurm/jobs/$S1"; set_state "$S1" RUNNING
tick
t "once the accounting has it: written down, still one suite" eval '[ "$(cat "$R1/suite.job" 2>/dev/null)" = $S1 ] && [ "$(count "^hpcw_ci_suite_")" = 1 ]'

echo "== the suite running, then passed"
n=$(calls sbatch); np=$(n_posted "$C1")
tick
t "suite running: nothing posted, nothing but the successor submitted" eval '[ "$(calls sbatch)" = $((n + 1)) ] && [ "$(n_posted $C1)" = $np ] && has "suite: job $S1 RUNNING"'
set_state "$S1" COMPLETED; write_log "$S1" "$SUITE_OK"; set_state "$K1" COMPLETED
tick
D1=$(newest "^hpcw_ci_deploy_${C1:0:12}$")
t "suite passed: its verdict posted as grid_ci.sh always posted it" eval 'st_is $C1 grid/framework-suite-py36 success "^412 tests, ALL OK on n042 under python 3.6$" && st_is $C1 grid/slurm-in-container success "answered every scheduler call"'
t "then the install: one job, from the commit's worktree, --site handed on, never --replace" eval '[ "$(count "^hpcw_ci_deploy_")" = 1 ] && cmp -s "$T/slurm/jobs/$D1/script" "$R1/src/tools/grid_deploy.sbatch" && [ "$(J $D1 args | tr "\n" " ")" = "--site testsite " ] && ! grep -q -- --replace "$T/slurm/jobs/$D1/args"'
t "the install names no queue of its own: grid_ci.sbatch's partition and QoS" eval '[ "$(J $D1 partition)" = "$DEF_PART" ] && [ "$(J $D1 qos)" = "$DEF_QOS" ]'
t "posted: deploy pending, installing" eval 'st_is $C1 grid/deploy pending "^installing on the grid$"'
tick
t "the next tick: no second install" eval '[ "$(count "^hpcw_ci_deploy_")" = 1 ] && has "deploy: job $D1 PENDING"'

echo "== installed"
set_state "$D1" COMPLETED; write_log "$D1" "$LOG_NEW"$'\n'"exit 0"
tick
t "grid/deploy success, in plain words with the version" eval 'st_is $C1 grid/deploy success "^installed as the lab.s shared copy, version $VER$"'
t "the commit is done, its worktree gone, its logs kept" eval '[ -s "$R1/done" ] && [ ! -e "$R1/src" ] && [ -s "$R1/deploy-$D1.log" ] && [ -s "$R1/ci-$S1.log" ]'
t "the watcher's scripts now come from the commit it installed" eval '[ "$(tail -1 "$WATCH/bin/grid_ci.sh")" = "# as in the test'"'"'s first commit" ] && [ -z "$(git -C "$CI/src" worktree list --porcelain | grep "^worktree $R1")" ]'
ng=$(grep -c check-runs "$T/gh/calls"); np=$(n_posted "$C1")
tick
t "main's head done: the next tick asks GitHub nothing and posts nothing" eval 'rc_is 0 && [ "$(grep -c check-runs "$T/gh/calls")" = $ng ] && [ "$(n_posted $C1)" = $np ] && has "${C1:0:12} \(main\): success"'

echo "== GitHub's checks failed, then run again and passed; the grid suite failed"
C2=$(commit two); R2="$CI/auto-$C2"
checks "$C2" "suite (ubuntu, current python):completed:failure" "suite (centos 7, python 3.6, bash 4.2):completed:success"
tick
t "GitHub's checks failed: grid/deploy failure, nothing submitted" eval 'st_is $C2 grid/deploy failure "^GitHub.s checks failed; not installed$" && [ "$(count "_${C2:0:12}$")" = 0 ]'
tick
t "posted once, not at every tick" eval '[ "$(st $C2 grid/deploy failure | grep -c .)" = 1 ]'
green "$C2"; tick
S2=$(newest "^hpcw_ci_suite_${C2:0:12}$"); K2=$(newest "^hpcw_ci_check_${C2:0:12}$")
t "the checks run again and passed: the suite goes" eval '[ -n "$S2" ] && [ ! -e "$R2/github.failed" ] && st_is $C2 grid/deploy pending "waiting for the grid suite"'
set_state "$S2" FAILED; write_log "$S2" "$SUITE_BAD"; set_state "$K2" COMPLETED
tick
t "suite failed: its failure posted, grid/deploy failure, no install, done" eval 'st_is $C2 grid/framework-suite-py36 failure "suite failed on the grid \(FAILED\)" && st_is $C2 grid/deploy failure "^the grid suite failed; not installed$" && [ "$(count "^hpcw_ci_deploy_${C2:0:12}")" = 0 ] && [ -s "$R2/done" ] && [ ! -e "$R2/src" ]'
C2b=$(commit two-b); R2b="$CI/auto-$C2b"; green "$C2b"; tick
S2b=$(newest "^hpcw_ci_suite_${C2b:0:12}$"); K2b=$(newest "^hpcw_ci_check_${C2b:0:12}$")
set_state "$S2b" COMPLETED; write_log "$S2b" "$SUITE_OK"; set_state "$K2b" FAILED
tick
t "the container check failed: not installed" eval 'st_is $C2b grid/slurm-in-container failure "container check failed \(FAILED\)" && st_is $C2b grid/deploy failure "^the container check failed on the grid; not installed$" && [ "$(count "^hpcw_ci_deploy_${C2b:0:12}")" = 0 ]'

echo "== a newer head while an older commit is in flight"
C3=$(commit three); R3="$CI/auto-$C3"; green "$C3"; tick
S3=$(newest "^hpcw_ci_suite_${C3:0:12}$"); K3=$(newest "^hpcw_ci_check_${C3:0:12}$")
echo "# from commit four" >> "$W/tools/grid_ci.sh"   # the watcher takes this line only from an install that succeeded
C4=$(commit four); R4="$CI/auto-$C4"; checks "$C4" "suite (ubuntu, current python):queued:"
set_state "$S3" COMPLETED; write_log "$S3" "$SUITE_OK"; set_state "$K3" COMPLETED
tick
t "the older commit's suite verdict is still posted" eval 'st_is $C3 grid/framework-suite-py36 success "ALL OK"'
t "but it is never installed: grid/deploy error, done, no install job" eval 'st_is $C3 grid/deploy error "^not installed: main has moved on to a newer commit$" && [ -s "$R3/done" ] && [ "$(count "^hpcw_ci_deploy_${C3:0:12}")" = 0 ]'
t "the new head waits for its own checks" eval 'has "main is $C4" && [ "$(count "_${C4:0:12}$")" = 0 ]'

echo "== an install deploy_shared refuses"
green "$C4"; tick
S4=$(newest "^hpcw_ci_suite_${C4:0:12}$"); K4=$(newest "^hpcw_ci_check_${C4:0:12}$")
set_state "$S4" COMPLETED; write_log "$S4" "$SUITE_OK"; set_state "$K4" COMPLETED
tick
D4=$(newest "^hpcw_ci_deploy_${C4:0:12}$")
set_state "$D4" FAILED; write_log "$D4" "$LOG_DIFF"$'\n'"exit 1"
cp "$WATCH/bin/grid_ci.sh" "$T/bin.before"
tick
t "a version published with other files: failure, and what to do, in one sentence" eval 'st_is $C4 grid/deploy failure "^not installed: version $VER is already installed with different files; raise framework/VERSION$"'
t "a refused install leaves the watcher's scripts as they were (not commit four's)" eval 'cmp -s "$WATCH/bin/grid_ci.sh" "$T/bin.before" && [ "$(tail -1 "$WATCH/bin/grid_ci.sh")" = "# as in the test'"'"'s first commit" ] && [ -s "$R4/done" ]'

echo "== one install at a time; a queued install of a commit main has moved past"
C5=$(commit five); R5="$CI/auto-$C5"; green "$C5"; tick
S5=$(newest "^hpcw_ci_suite_${C5:0:12}$"); K5=$(newest "^hpcw_ci_check_${C5:0:12}$")
set_state "$S5" COMPLETED; write_log "$S5" "$SUITE_OK"; set_state "$K5" COMPLETED
tick
D5=$(newest "^hpcw_ci_deploy_${C5:0:12}$")
C6=$(commit six); R6="$CI/auto-$C6"; green "$C6"; tick
S6=$(newest "^hpcw_ci_suite_${C6:0:12}$"); K6=$(newest "^hpcw_ci_check_${C6:0:12}$")
set_state "$S6" COMPLETED; write_log "$S6" "$SUITE_OK"; set_state "$K6" COMPLETED
tick
t "the head waits while an older commit's install has not ended" eval '[ "$(count "^hpcw_ci_deploy_${C6:0:12}")" = 0 ] && has "another commit.s install has not ended" && [ "$(cat "$CI/main-head")" = "$C6" ]'
run_job "$D5" PATH="$ACL:$PATH"
t "the older commit's install, run after main moved on: refused in a sentence before deploy_shared" eval 'rc_is 1 && has "^grid_deploy: main has moved on to a newer commit; nothing was installed$" && lacks "^deploy_shared" && [ "$(printf "%s\n" "$OUT" | tail -1)" = "exit 1" ]'
tick
t "its verdict: error, not installed, said plainly" eval 'st_is $C5 grid/deploy error "^not installed: main has moved on to a newer commit$" && [ "$(last_st $C5 grid/deploy)" = error ] && [ -z "$(st $C5 grid/deploy success)" ] && grep -q "^error: " "$R5/done"'
t "and then the head's install goes" eval '[ "$(count "^hpcw_ci_deploy_${C6:0:12}")" = 1 ]'
D6=$(newest "^hpcw_ci_deploy_${C6:0:12}$")
set_state "$D6" COMPLETED; write_log "$D6" "$LOG_README"$'\n'"exit 0"
tick
t "a README-only difference: said so" eval 'st_is $C6 grid/deploy success "^version $VER was already installed; its README was updated in place$"'
t "the watcher's scripts now come from the head it installed (commit four's line and all)" eval '[ "$(tail -1 "$WATCH/bin/grid_ci.sh")" = "# from commit four" ]'

echo "== the scheduler refuses the next tick"
C7=$(commit seven); checks "$C7" "suite (ubuntu, current python):in_progress:"
echo "QOSMaxSubmitJobPerUserLimit" > "$T/slurm/refuse"
tick
t "the chain's end is posted on main's head, in words, and the tick fails" eval 'rc_is 1 && st_is $C7 grid/deploy error "watcher stopped .*grid_ci.sh --watch starts it again" && [ -z "$(pending_watch)" ]'
rm -f "$T/slurm/refuse"

echo "== --unwatch, STOP, --watch again"
gc --watch --every 5 --container --site testsite
WS=$(pending_watch)
t "--watch after the chain ended: a new tick queued" eval 'rc_is 0 && [ -n "$WS" ]'
nq=$(calls squeue); nc=$(calls scancel)
gc --unwatch
t "--unwatch: STOP written, the queued tick cancelled, one squeue and one scancel" eval 'rc_is 0 && [ -s "$WATCH/STOP" ] && [ "$(J $WS state)" = CANCELLED ] && [ "$(calls squeue)" = $((nq + 1)) ] && [ "$(calls scancel)" = $((nc + 1)) ] && grep -q "^scancel $WS$" "$T/slurm/calls"'
n=$(calls sbatch)
run_tick "$WS"
t "a tick that finds STOP ends the chain: no successor, nothing done" eval 'rc_is 0 && has "STOP is set" && [ "$(calls sbatch)" = $n ] && lacks "main is"'
gc --watch --every 5
t "--watch again: STOP removed, a tick queued" eval 'rc_is 0 && [ ! -e "$WATCH/STOP" ] && [ -n "$(pending_watch)" ]'
gc --unwatch >/dev/null

echo "== overrides of the queue"
for j in $(pending_watch); do set_state "$j" CANCELLED; done
rm -f "$WATCH/STOP"
HPCW_CI_PARTITION=testp HPCW_CI_QOS=testq gc --watch --every 5
WO=$(pending_watch)
t "HPCW_CI_PARTITION and HPCW_CI_QOS: the tick runs there and carries them on" eval '[ "$(J $WO partition)" = testp ] && [ "$(J $WO qos)" = testq ] && grep -qx testp "$T/slurm/jobs/$WO/args" && grep -qx testq "$T/slurm/jobs/$WO/args"'
green "$C7"; run_tick "$WO"
S7=$(newest "^hpcw_ci_suite_${C7:0:12}$")
t "and the suite is steered there too" eval '[ "$(J $S7 partition)" = testp ] && [ "$(J $S7 qos)" = testq ]'
for j in $(pending_watch); do set_state "$j" CANCELLED; done

echo "== one run by a person"
gc --deploy --ref feature
t "--deploy for another ref: refused" eval 'rc_is 1 && has "only main.s head"'
C8=$(commit eight); green "$C8"
mkdir -p "$T/slurm/finish"
printf 'COMPLETED\n%s\n' "$SUITE_OK" > "$T/slurm/finish/hpcw_ci_suite"
printf 'COMPLETED\n%s\nexit 0\n' "$LOG_SAME" > "$T/slurm/finish/hpcw_ci_deploy"
: > "$T/sleeps"
gc --deploy --site testsite
t "--deploy: the suite, GitHub's checks, then the install, exit 0" eval 'rc_is 0 && st_is $C8 grid/framework-suite-py36 success "ALL OK" && st_is $C8 grid/deploy pending "^installing on the grid$" && st_is $C8 grid/deploy success "^version $VER was already installed with these files$"'
t "--deploy: the install from the run's worktree with --site, never --replace" eval 'D8=$(newest "^hpcw_ci_deploy$"); [ "$(J $D8 dir)" = "$CI/run-$C8" ] && [ "$(J $D8 args | tr "\n" " ")" = "--site testsite " ]'
t "--deploy: the run folder kept, its worktree gone" eval '[ -d "$CI/run-$C8" ] && [ ! -e "$CI/run-$C8/src" ]'
t "a person's run asks the scheduler at most once a minute" eval '[ -s "$T/sleeps" ] && ! grep -vx 60 "$T/sleeps" >/dev/null'
printf 'FAILED\n%s\n' "$SUITE_BAD" > "$T/slurm/finish/hpcw_ci_suite"
C9=$(commit nine); green "$C9"
gc --deploy
t "--deploy after a failed suite: not installed, no install job, exit 1" eval 'rc_is 1 && st_is $C9 grid/deploy failure "^the grid suite failed; not installed$" && [ "$(count "^hpcw_ci_deploy$")" = 1 ]'
printf 'COMPLETED\n%s\n' "$SUITE_OK" > "$T/slurm/finish/hpcw_ci_suite"
gc
t "a plain run (no --deploy): the suite's verdict and nothing about an install" eval 'rc_is 0 && [ -z "$(st $C9 grid/deploy success)" ] && [ "$(st $C9 grid/framework-suite-py36 success | grep -c .)" = 1 ]'
t "a person's run on main writes main's head down too" eval '[ "$(cat "$CI/main-head")" = "$C9" ]'
C10=$(commit ten); green "$C10"
printf 'FAILED\ncontainer said no\n' > "$T/slurm/finish/hpcw9_slurmcheck"
gc --deploy --container
t "--deploy --container, the container check failed: said so, not blamed on the suite; no install" eval 'rc_is 1 && st_is $C10 grid/framework-suite-py36 success "ALL OK" && st_is $C10 grid/deploy failure "^the container check failed on the grid; not installed$" && ! st_is $C10 grid/deploy failure "grid suite" && [ "$(count "^hpcw_ci_deploy$")" = 1 ]'
rm -f "$T/slurm/finish/hpcw9_slurmcheck"
C11=$(commit eleven); green "$C11"
echo "QOSMaxSubmitJobPerUserLimit" > "$T/slurm/refuse-hpcw9_slurmcheck"
gc --deploy --container
t "--deploy --container, the container check refused: grid/deploy ends in error, never left pending; worktree gone" eval 'rc_is 1 && has "QOSMaxSubmitJobPerUserLimit" && [ "$(last_st $C11 grid/deploy)" = error ] && st_is $C11 grid/deploy error "^the scheduler refused the container check; not installed$" && [ ! -e "$CI/run-$C11/src" ]'
rm -f "$T/slurm/refuse-hpcw9_slurmcheck"
C12=$(commit twelve); green "$C12"
printf 'FAILED\nhost n042\ngrid_deploy: the lab'"'"'s shared copy is already version 99, newer than this commit'"'"'s %s; nothing was installed\nexit 1\n' "$VER" > "$T/slurm/finish/hpcw_ci_deploy"
gc --deploy
t "--deploy whose install found a newer version in place: error in its words (passed over, not failed), exit 1" eval 'rc_is 1 && [ "$(last_st $C12 grid/deploy)" = error ] && st_is $C12 grid/deploy error "^not installed: the lab.s shared copy is already version 99, newer than this commit.s $VER$"'
rm -rf "$T/slurm/finish"

echo "== tools/grid_deploy.sbatch"
# a run folder beside a clone's records (../../main-head, ../../deploy.lock), its checkout a commit, and
# a deploy_shared that writes each call to a file and, for --dry-run, the line the real one prints
DR="$T/dep/run"; mkdir -p "$DR/src/tools" "$T/minbin" "$T/lockbin"
cat > "$DR/src/tools/deploy_shared.sh" <<'EOF'
printf '%s\n' "$*" >> "$STUB_CALLS"
case " $* " in *" --dry-run "*)
  [ -z "${STUB_DRY_FAIL:-}" ] || { echo "deploy_shared: $STUB_DRY_FAIL" >&2; exit 1; }
  echo "== n042 as someone (groups: lab); hpcworker ${STUB_NEW:-18} from 1234567 -> /x/hpcworker/v${STUB_NEW:-18}"
  echo "   root: present; group: lab; v${STUB_NEW:-18}: new; current: ${STUB_CURRENT:-v17} -> v${STUB_NEW:-18}"
  echo "   dry run: nothing written (18 files would be published)"
  exit 0;;
esac
echo "deploy_shared called: $*"
echo "TMPDIR $TMPDIR $([ -d "$TMPDIR" ] && echo present)"
echo "token ${GITHUB_TOKEN:-none}"
exit "${STUB_RC:-0}"
EOF
git init -q "$DR/src" && git -C "$DR/src" add -A && git -C "$DR/src" commit -q -m stub
DHEAD=$(git -C "$DR/src" rev-parse HEAD); echo "$DHEAD" > "$T/dep/main-head"
for b in bash hostname date mkdir rm; do ln -s "$(command -v $b)" "$T/minbin/$b"; done
printf '#!/bin/sh\nexit 1\n' > "$T/lockbin/flock"; chmod 755 "$T/lockbin/flock"   # a lock still held when the wait runs out
export STUB_CALLS="$T/dep/calls"
dep() { : > "$STUB_CALLS"; OUT=$(cd "$DR" && SLURM_JOB_ID=77 "$@" 2>&1); RC=$?; }
last_is() { [ "$(printf "%s\n" "$OUT" | tail -1)" = "$1" ]; }
dep env PATH="$T/minbin" bash "$REPO/tools/grid_deploy.sbatch" --site testsite
t "no getfacl or setfacl on the node: refused in a sentence, nothing installed, the log ends exit 1" eval 'rc_is 1 && has "^grid_deploy: getfacl is not installed .*nothing was installed$" && [ ! -s "$STUB_CALLS" ] && last_is "exit 1"'
dep env PATH="$ACL:$PATH" bash "$REPO/tools/grid_deploy.sbatch" --site testsite
t "a dry run, then deploy_shared --here --site, nothing more, from the commit's checkout; the log ends exit 0" eval 'rc_is 0 && [ "$(tr "\n" "|" < "$STUB_CALLS")" = "--here --dry-run --site testsite|--here --site testsite|" ] && has "^deploy_shared called: --here --site testsite$" && has "^the lab.s shared copy names v17 now; this commit is v18$" && last_is "exit 0"'
t "its temp on the node's local disk, gone after; no token passed on" eval 'has "^TMPDIR /tmp/$USER/hpcw_deploy_77 present$" && [ ! -e "/tmp/$USER/hpcw_deploy_77" ] && has "^token none$"'
dep env PATH="$ACL:$PATH" bash "$REPO/tools/grid_deploy.sbatch" --site testsite --replace
t "--replace: refused, nothing installed" eval 'rc_is 1 && has "^grid_deploy: only --site is handed on, not --replace" && [ ! -s "$STUB_CALLS" ]'
dep env PATH="$ACL:$PATH" STUB_RC=3 bash "$REPO/tools/grid_deploy.sbatch"
t "deploy_shared's own exit is the job's, and the log's last line" eval 'rc_is 3 && last_is "exit 3" && has "^deploy_shared called: --here$"'
echo 0000000000000000000000000000000000000001 > "$T/dep/main-head"
dep env PATH="$ACL:$PATH" bash "$REPO/tools/grid_deploy.sbatch" --site testsite
t "main's head is another commit by now: refused before deploy_shared runs at all" eval 'rc_is 1 && has "^grid_deploy: main has moved on to a newer commit; nothing was installed$" && [ ! -s "$STUB_CALLS" ] && last_is "exit 1"'
rm -f "$T/dep/main-head"
dep env PATH="$ACL:$PATH" bash "$REPO/tools/grid_deploy.sbatch" --site testsite
t "no record of main's head: refused (nothing to compare with is not a yes)" eval 'rc_is 1 && has "^grid_deploy: no record of main.s head" && [ ! -s "$STUB_CALLS" ]'
echo "$DHEAD" > "$T/dep/main-head"
dep env PATH="$ACL:$PATH" STUB_CURRENT=v19 bash "$REPO/tools/grid_deploy.sbatch" --site testsite
t "the shared copy already names a newer version: refused after the dry run, current never moves back" eval 'rc_is 1 && has "^grid_deploy: the lab.s shared copy is already version 19, newer than this commit.s 18; nothing was installed$" && [ "$(grep -c . "$STUB_CALLS")" = 1 ] && lacks "deploy_shared called"'
dep env PATH="$ACL:$PATH" STUB_CURRENT=v18 bash "$REPO/tools/grid_deploy.sbatch"
t "the same version: deploy_shared decides (same files, README, or a refusal)" eval 'rc_is 0 && has "^deploy_shared called: --here$"'
dep env PATH="$ACL:$PATH" STUB_CURRENT=none bash "$REPO/tools/grid_deploy.sbatch"
t "no current yet: the first publish goes" eval 'rc_is 0 && has "^deploy_shared called: --here$"'
dep env PATH="$ACL:$PATH" STUB_CURRENT=elsewhere bash "$REPO/tools/grid_deploy.sbatch"
t "a current it cannot read as a version: refused" eval 'rc_is 1 && has "^grid_deploy: could not tell which version" && lacks "deploy_shared called"'
dep env PATH="$ACL:$PATH" STUB_DRY_FAIL="this account is not in group lab; nothing changed" bash "$REPO/tools/grid_deploy.sbatch"
t "the dry run refused: deploy_shared's own words and exit in the log, no publish" eval 'rc_is 1 && has "^deploy_shared: this account is not in group lab; nothing changed$" && last_is "exit 1" && [ "$(grep -c . "$STUB_CALLS")" = 1 ]'
dep env PATH="$T/lockbin:$ACL:$PATH" bash "$REPO/tools/grid_deploy.sbatch"
t "another install still holds the lock when the wait runs out: said in a sentence, exit 1" eval 'rc_is 1 && has "^grid_deploy: another install held the lock for ten minutes; nothing was installed$" && [ ! -s "$STUB_CALLS" ] && last_is "exit 1"'
wall=$(sed -n 's/^#SBATCH --time=\([0-9]*\):\([0-9]*\):\([0-9]*\)$/\1 \2 \3/p' "$REPO/tools/grid_deploy.sbatch")
lockw=$(sed -n 's/.*flock -w \([0-9][0-9]*\) .*/\1/p' "$REPO/tools/grid_deploy.sbatch")
OUT="wall time: $wall; lock wait: $lockw s"
t "the lock's wait ends at least five minutes before the wall time, so its refusal is ever printed" eval 'set -- $wall; [ -n "$lockw" ] && [ $(( 10#$1 * 3600 + 10#$2 * 60 + 10#$3 )) -ge $(( lockw + 300 )) ]'

echo "== no token anywhere"
t "no stand-in ever had a token in its environment" eval '[ ! -s "$T/slurm/leaks" ] && [ ! -s "$T/gh/leaks" ]'
t "no token in any argv, job script, job argument or state file" eval '! grep -rq testtoken_must_not_leak "$T/slurm" "$T/gh" "$T/ci"'
t "every job had a wall time and a folder inside the test: the stand-ins refused nothing" eval '[ ! -s "$T/slurm/refused" ] && [ "$(ls "$T/slurm/jobs" | wc -l)" -gt 20 ]'

echo "== tools/version_check.sh"
V="$T/vc"; mkdir -p "$V/tools" "$V/framework/bin" "$V/framework/lib" "$V/framework/jobs" "$V/framework/profiles" "$V/framework/tests"
cp "$REPO/tools/version_check.sh" "$REPO/tools/deploy_shared.sh" "$V/tools/"
echo 5 > "$V/framework/VERSION"; printf '#!/bin/bash\nVERSION=5\n' > "$V/framework/bin/hpcworker"
echo a > "$V/framework/lib/a.sh"; echo j > "$V/framework/jobs/j.sbatch"; echo '{}' > "$V/framework/profiles/p.json"
echo readme > "$V/framework/README.md"; echo t > "$V/framework/tests/t.py"
git init -q "$V" && git -C "$V" add -A && git -C "$V" commit -q -m base && git -C "$V" tag base
vc() { OUT=$(bash "$V/tools/version_check.sh" "$@" 2>&1); RC=$?; }
case_from_base() { git -C "$V" checkout -q -B "case$1" base; }
setver() { echo "$1" > "$V/framework/VERSION"; printf '#!/bin/bash\nVERSION=%s\n' "${2:-$1}" > "$V/framework/bin/hpcworker"; }
save() { git -C "$V" add -A && git -C "$V" commit -q -m "$1"; }
case_from_base 1; echo b >> "$V/framework/lib/a.sh"; save lib
vc base HEAD
t "a published file changed, VERSION not: refused, names the file and the next version" eval 'rc_is 1 && has "\(framework/lib/a.sh\) while framework/VERSION stayed 5; raise it and bin/hpcworker.s VERSION= line to 6 together"'
setver 6; save bump
vc base HEAD
t "with VERSION and VERSION= raised together: ok" eval 'rc_is 0 && has "5 -> 6, 2 published file"'
case_from_base 2; echo more >> "$V/framework/README.md"; echo more >> "$V/framework/tests/t.py"; save docs
vc base HEAD
t "README.md and the tests only: ok, no version needed" eval 'rc_is 0 && has "5 -> 5, 0 published file"'
case_from_base 3; setver 6 5; save half
vc base HEAD
t "VERSION raised, bin/hpcworker's VERSION= not: refused" eval 'rc_is 1 && has "VERSION is 6 but bin/hpcworker.s VERSION= line says 5; move both together"'
case_from_base 4; setver 4; save down
vc base HEAD
t "VERSION went down: refused" eval 'rc_is 1 && has "went down, from 5 to 4"'
case_from_base 5; mkdir -p "$V/framework/lib/__pycache__"; echo x > "$V/framework/lib/__pycache__/a.cpython-36.pyc"; git -C "$V" add -f -A; save cache
vc base HEAD
t "python's caches are not published, so they do not count" eval 'rc_is 0'
case_from_base 6; echo c >> "$V/framework/profiles/p.json"; save p; git -C "$V" checkout -q -B main6 base; echo d >> "$V/framework/jobs/j.sbatch"; save j
vc main6 case6
t "measured from the merge base: a change on main is not the branch's" eval 'rc_is 1 && has "\(framework/profiles/p.json\)" && lacks "j.sbatch"'
vc base nosuchref
t "an unknown commit: exit 2" eval 'rc_is 2 && has "no commit nosuchref"'
OUT=$(bash "$REPO/tools/version_check.sh" --list 2>&1); RC=$?
t "--list: deploy_shared.sh's own folders and VERSION, not README.md" eval 'rc_is 0 && [ "$(printf "%s" "$OUT" | tr "\n" " ")" = "framework/bin framework/lib framework/jobs framework/profiles framework/VERSION" ]'
sed -i 's/^files=\$(cd "\$FW" && { find /files=$(cd "$FW" \&\& { find_all /' "$V/tools/deploy_shared.sh"
vc base HEAD
t "deploy_shared.sh's list unreadable: exit 2, never a silent pass" eval 'rc_is 2 && has "cannot find the list of published files"'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
