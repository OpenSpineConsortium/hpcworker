#!/bin/bash
# The grid lane of CI: run ON the cluster (the portal's shell, or a worker), never by GitHub.
# GitHub's runners cannot reach the grid (the VPN and a one-time code stand between), and no
# token of the grid's or GitHub's ever enters a repository, a job file or an argv (CLAUDE.md):
# this script uses the `gh` sign-in already in the account's home, and GitHub sees only a
# commit status — pass or fail, with one sentence.
#
#   tools/grid_ci.sh [--ref main] [--repo OpenSpineConsortium/hpcworker] [--container] [--deploy [--site S]]
#   tools/grid_ci.sh --watch [--every 10] [--container] [--site S] [--repo ...]
#   tools/grid_ci.sh --unwatch
#
# One run (the first form): fetches the ref into its own clone (on the lab volume, one per
# repository), gives the run a worktree of its own named by the commit — a queued job's tree can
# then never move under it, however many runs overlap — posts "pending" on that commit, submits
# tools/grid_ci.sbatch (the suite on a compute node under /usr/bin/python3), asks the scheduler
# at most once a minute, reads the job's log, and posts success or failure as the status
# grid/framework-suite-py36. With --container it also runs
# framework/tests/grid/slurm_in_container.sbatch (the worker's container with the Slurm binds;
# its exit code is its verdict) and posts grid/slurm-in-container. With --deploy (main's head
# only) it then waits for GitHub's own checks on the commit, and when they and the grid passed and
# main has not moved on, installs the commit as the lab's shared copy with tools/grid_deploy.sbatch
# (tools/deploy_shared.sh --here in a job on a compute node, never --replace) and posts grid/deploy.
#
# The watcher (--watch): keeps main's head installed with nobody at the keyboard. A person starts it
# once; on the login node --watch is file work, one squeue (one watcher per account: a job named
# hpcw_ci_watch already queued or running is refused) and one sbatch. Each tick
# (tools/grid_ci_watch.sbatch, ten minutes of wall time at most) first queues its one successor
# (--begin=now+EVERY minutes, --dependency=singleton), then moves main's head on by at most one
# job and leaves; it never waits on a job: GitHub's checks all passed -> the grid suite (and the
# container check) -> the install -> grid/deploy. A newer head that arrives while an older commit
# is in flight gets its own run; the older one's verdicts are still posted, and it is never
# installed: not submitted once main has moved on, and an install already queued refuses when it
# runs if main's newest head either lane has fetched (<clone>/main-head) is another commit, or the
# shared copy already names a newer version, so neither lane ever moves `current` back to an older
# one (grid_deploy.sbatch). The watcher runs its own copy of these scripts, in <ci dir>/watch/bin,
# refreshed only from a commit it has just installed (one that passed GitHub's checks and the grid
# suite), so a merge cannot break the chain that would report it. --unwatch writes
# <ci dir>/watch/STOP, which every tick reads first, and cancels the queued tick (one squeue, one
# scancel). The install needs the account that runs the watcher to own the shared copy's folder:
# deploy_shared refuses others.
#
# On the login node this script is only git, gh, sbatch, squeue, sacct and scancel; everything
# heavier runs inside the jobs. Every job is submitted with GITHUB_TOKEN and GH_TOKEN removed from
# the environment sbatch hands it.
set -uo pipefail
say() { printf '%s\n' "$*"; }
die() { printf 'grid_ci: %s\n' "$*" >&2; exit 1; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (--help)"; }

REPO=OpenSpineConsortium/hpcworker REF=main CONTAINER=0 DEPLOY=0 MODE=run EVERY=10 SITE="" REF_GIVEN=0
while [ $# -gt 0 ]; do case "$1" in
  --ref) need "$@"; REF="$2"; REF_GIVEN=1; shift 2;; --repo) need "$@"; REPO="$2"; shift 2;;
  --container) CONTAINER=1; shift;; --deploy) DEPLOY=1; shift;; --site) need "$@"; SITE="$2"; shift 2;;
  --watch) MODE=watch; shift;; --unwatch) MODE=unwatch; shift;; --every) need "$@"; EVERY="$2"; shift 2;;
  # the watcher's own: what --watch hands the first tick, and each tick its successor
  --tick) MODE=tick; shift;; --ci-dir) need "$@"; HPCW_CI_DIR="$2"; shift 2;;
  --partition) need "$@"; HPCW_CI_PARTITION="$2"; shift 2;; --qos) need "$@"; HPCW_CI_QOS="$2"; shift 2;;
  -h|--help) awk 'NR > 1 && /^set -uo pipefail/ { exit } NR > 1' "$0"; exit 0;;
  *) die "unknown option $1 (--help)";; esac; done
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo is OWNER/NAME: $REPO"
[[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$REF" != -* ]] || die "bad --ref $REF"
[[ "$SITE" =~ ^[A-Za-z0-9._-]*$ ]] || die "bad --site $SITE"
[[ "${HPCW_CI_PARTITION:-}${HPCW_CI_QOS:-}" =~ ^[A-Za-z0-9._,-]*$ ]] || die "bad HPCW_CI_PARTITION or HPCW_CI_QOS"
{ [[ "$EVERY" =~ ^[0-9]+$ ]] && [ "$EVERY" -ge 5 ] && [ "$EVERY" -le 1440 ]; } || die "--every is the minutes between two looks at main, 5 to 1440: $EVERY"
case "$MODE" in watch|unwatch|tick) { [ $REF_GIVEN = 0 ] && [ $DEPLOY = 0 ]; } || die "the watcher follows main and installs it itself: no --ref, no --deploy";; esac
[ $DEPLOY = 0 ] || [ "$REF" = main ] || die "--deploy installs only main's head; leave --ref out"
USER=${USER:-$(id -un)}
HERE=$(cd "$(dirname "$0")" && pwd) || die "cannot find the folder of $0"

# the account's gh sign-in, not a GITHUB_TOKEN a ~/.bashrc may export for another account
GHBIN=$(command -v gh || true); [ -n "$GHBIN" ] || GHBIN="$HOME/.local/bin/gh"
GH() { net env -u GITHUB_TOKEN -u GH_TOKEN "$GHBIN" "$@"; }
slurm_bin() { command -v "$1" || echo "/opt/hpcw/slurm/bin/$1"; }
SBATCH=$(slurm_bin sbatch) SQUEUE=$(slurm_bin squeue) SACCT=$(slurm_bin sacct) SCANCEL=$(slurm_bin scancel)
[ -x "$SBATCH" ] || die "no sbatch here"
# sbatch hands a job the environment it was typed in (--export=ALL): never a token with it, and
# from inside a tick never this node's per-job temp either (each job makes its own). The other
# scheduler commands read neither, and are not handed them all the same
SB_ENV=(env -u GITHUB_TOKEN -u GH_TOKEN); [ "$MODE" = tick ] && SB_ENV+=(-u TMPDIR)
SB() { "${SB_ENV[@]}" "$SBATCH" "$@"; }
SQ() { "${SB_ENV[@]}" "$SQUEUE" "$@"; }
SA() { "${SB_ENV[@]}" "$SACCT" "$@"; }
SC() { "${SB_ENV[@]}" "$SCANCEL" "$@"; }
# the jobs' own headers name the site's short-test partition; when that queue starves a five-minute
# test for hours (secp, 2026-10-03: job 40555652 sat from 16:27 past 21:00 on Priority), these steer
# both jobs without editing the scripts — sbatch's flags outrank a file's #SBATCH lines
SB_ARGS=()
[ -n "${HPCW_CI_PARTITION:-}" ] && SB_ARGS+=(--partition "$HPCW_CI_PARTITION")
[ -n "${HPCW_CI_QOS:-}" ] && SB_ARGS+=(--qos "$HPCW_CI_QOS")
SITE_ARGS=(); [ -n "$SITE" ] && SITE_ARGS=(--site "$SITE")

# one clone per repository (--repo after a first run must not fetch from the wrong origin), and
# one worktree per run, named by the commit: on the lab volume, never in a person's working tree
CIROOT="${HPCW_CI_DIR:-/rs/rs_grp_oschome/$USER/hpcworker-ci}"
CI="$CIROOT/${REPO//\//-}"
WATCH="$CIROOT/watch"
# what every tick hands its successor: the watcher's whole configuration rides on the job's command line
TICK_ARGS=(--tick --repo "$REPO" --every "$EVERY" --ci-dir "$CIROOT")
[ $CONTAINER = 1 ] && TICK_ARGS+=(--container)
[ -n "$SITE" ] && TICK_ARGS+=(--site "$SITE")
[ -n "${HPCW_CI_PARTITION:-}" ] && TICK_ARGS+=(--partition "$HPCW_CI_PARTITION")
[ -n "${HPCW_CI_QOS:-}" ] && TICK_ARGS+=(--qos "$HPCW_CI_QOS")

# a network call that hangs must not hold a ten-minute tick (or a person's terminal) for ever
net() { if command -v timeout >/dev/null 2>&1; then timeout 300 "$@"; else "$@"; fi; }

# every git call speaks through the same gh sign-in: a ~/.gitconfig credential helper may hold
# ANOTHER account's sign-in (measured 2026-10-03: the clone came through gh, then the plain fetch
# went through a global `store` helper as a second account and read "Repository not found")
HELPER="!env -u GITHUB_TOKEN -u GH_TOKEN $GHBIN auth git-credential"
ci_clone() {
  if [ ! -d "$CI/src/.git" ]; then
    net git -c credential.helper= -c "credential.helper=$HELPER" clone -q "https://github.com/$REPO.git" "$CI/src" || { say "clone of $REPO failed"; return 1; }
  fi
  git -C "$CI/src" config --unset-all credential.helper 2>/dev/null
  git -C "$CI/src" config credential.helper '' && git -C "$CI/src" config --add credential.helper "$HELPER"
}
fetch_ref() { # REF -> the commit it names now (run under the lock: FETCH_HEAD is the clone's one slot)
  local sha
  net git -C "$CI/src" fetch -q origin "$1" >&2 && sha=$(git -C "$CI/src" rev-parse --verify -q 'FETCH_HEAD^{commit}') || return 1
  # main's newest head either lane has seen, for the install job to compare its own commit with when
  # it runs: a queued install of a commit main has since moved past then refuses (grid_deploy.sbatch)
  if [ "$1" = main ]; then
    printf '%s\n' "$sha" > "$CI/main-head.new" && mv -f "$CI/main-head.new" "$CI/main-head" || { say "cannot write $CI/main-head" >&2; return 1; }
  fi
  printf '%s\n' "$sha"
}
tree_add() { # RUN SHA: the run's checkout; one already there is the same immutable commit (an earlier or crashed run's)
  [ -d "$1/src" ] && return 0
  mkdir -p "$1" && git -C "$CI/src" worktree prune && git -C "$CI/src" worktree add -q --detach "$1/src" "$2"
}
tree_remove() { # RUN: the worktree goes, the run folder and its logs stay
  [ -d "$1/src" ] || return 0
  git -C "$CI/src" worktree remove --force "$1/src" 2>/dev/null || say "note: worktree $1/src left in place"
}
# a person's run and the watcher's tick share one clone: git there (the credential rewrite, a fetch
# and its FETCH_HEAD, a worktree) runs one at a time, under <clone>/.lock
locked() {
  mkdir -p "$CI" || { say "cannot create $CI"; return 1; }
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 600 9 || { say "the clone is busy: another run has held $CI/.lock for ten minutes"; exit 1; }; "$@" ) 9>>"$CI/.lock"
  else "$@"; fi
}

post() { # SHA CONTEXT STATE SENTENCE (GitHub keeps 140 characters of a description)
  local d="$4"; [ ${#d} -le 140 ] || d="${d:0:137}..."
  GH api "repos/$REPO/statuses/$1" -f context="$2" -f state="$3" -f description="$d" --silent \
    || say "note: could not post $2=$3 on ${1:0:12} (the verdict is in this log either way)"
}

job_id() { # OUT: the job number in sbatch --parsable's answer ("12345" or "12345;cluster" on a line of
  # its own), as the adapter's slurm_parse_submit reads it: the answer is taken with its stderr for the
  # refusal's words, and a site's submit plugin or sbatch itself may add a warning to an accepted job
  local l; l=$(printf '%s\n' "$1" | grep -E '^[0-9]+(;|$)' | head -1)
  [ -n "$l" ] && printf '%s' "${l%%;*}"
}
sb_default() { # KEY FILE -> the value of that file's own #SBATCH --KEY= line
  sed -n "s/^#SBATCH --$1=\([A-Za-z0-9._,-]*\)\$/\1/p" "$2" 2>/dev/null | head -1
}
place() { # FILE: JOB_PLACE for a job whose script names no queue (the install, the watcher's tick):
  # HPCW_CI_PARTITION and HPCW_CI_QOS when set, else the ones grid_ci.sbatch (FILE) names for the suite
  local p q; p=${HPCW_CI_PARTITION:-$(sb_default partition "$1")}; q=${HPCW_CI_QOS:-$(sb_default qos "$1")}
  JOB_PLACE=(); [ -n "$p" ] && JOB_PLACE+=(--partition "$p"); [ -n "$q" ] && JOB_PLACE+=(--qos "$q")
  return 0
}

wait_job() { # JOB -> the job's final sacct state, asked at most once a minute
  local job="$1" st
  while :; do
    sleep 60
    st=$(SA -j "$job" -X -n -o State 2>/dev/null | head -1 | sed 's/^ *//')
    st=${st%% *}
    case "$st" in PENDING|RUNNING|REQUEUED|SUSPENDED|RESIZING|COMPLETING|CONFIGURING|'') continue;; *) break;; esac
  done
  printf '%s' "$st"
}
final() { # STATE: 0 when the scheduler is done with the job
  case "$1" in ''|PENDING|RUNNING|REQUEUED|REQUEUE_HOLD|REQUEUE_FED|SUSPENDED|RESIZING|COMPLETING|CONFIGURING|SIGNALING|STAGE_OUT|SPECIAL_EXIT) return 1;; *) return 0;; esac
}

suite_verdict() { # SHA RUN JOB STATE: posts grid/framework-suite-py36; 0 when the suite passed
  local log="$2/ci-$3.log" n node
  # the suite's own word, not only the scheduler's: the log ends "exit 0" and says ALL OK
  if [ "$4" = COMPLETED ] && grep -q '^exit 0$' "$log" 2>/dev/null && grep -q '^ALL OK$' "$log" 2>/dev/null; then
    n=$(grep -m1 -oE '^Ran [0-9]+' "$log" | grep -oE '[0-9]+' || echo '?')
    node=$(sed -n 's/^host \([A-Za-z0-9-]*\).*/\1/p' "$log" | head -1)
    post "$1" grid/framework-suite-py36 success "$n tests, ALL OK on $node under python 3.6"
    say "suite: ALL OK"; return 0
  fi
  post "$1" grid/framework-suite-py36 failure "the suite failed on the grid ($4); log kept on the cluster"
  say "suite: FAILED (see $log)"; return 1
}
container_verdict() { # SHA RUN JOB STATE: posts grid/slurm-in-container; its exit code is its verdict
  if [ "$4" = COMPLETED ]; then
    post "$1" grid/slurm-in-container success "the worker's container answered every scheduler call"
    say "container check: ok"; return 0
  fi
  post "$1" grid/slurm-in-container failure "the container check failed ($4); log kept on the cluster"
  say "container check: FAILED (see $2/slurm_check_$3.out)"; return 1
}
deploy_verdict() { # SHA RUN JOB STATE: posts grid/deploy in deploy_shared's own words; 0 when installed
  local log="$2/deploy-$3.log" n why
  n=$(sed -n 's/^== .*; hpcworker \([0-9][0-9]*\) from .*/\1/p' "$log" 2>/dev/null | head -1)
  [ -n "$n" ] || n=$(sed -n 's/^hpcworker \([0-9][0-9]*\) (.*/\1/p' "$log" 2>/dev/null | head -1)
  if [ "$4" = COMPLETED ] && grep -q '^exit 0$' "$log" 2>/dev/null; then
    if grep -q '^   published v' "$log"; then why="installed as the lab's shared copy, version $n"
    elif grep -q 'README.md updated in place' "$log"; then why="version $n was already installed; its README was updated in place"
    elif grep -q '^   current already names v' "$log"; then why="version $n was already installed with these files"
    else why="the lab's shared copy is version $n again (it was already published with these files)"; fi
    DV=$why DS=success; post "$1" grid/deploy success "$why"; say "install: $why"; return 0
  fi
  # deploy_shared's own refusal, in its words; the one a merge meets most is a version it already
  # published with other files, whose fix is the next integer version (CI never replaces one)
  local state=failure
  if grep -q ' is published with different files:$' "$log" 2>/dev/null; then
    why="not installed: version $n is already installed with different files; raise framework/VERSION"
  else
    why=$(sed -n 's/^\(deploy_shared\|grid_deploy\): //p' "$log" 2>/dev/null | tail -1)
    why=${why%; nothing was installed}
    # passed over for a newer commit, not failed: the same word as a commit the watcher never sent
    case "$why" in "main has moved on"*|"the lab's shared copy is already version"*) state=error;; esac
    why="not installed: ${why:-the install job ended $4; its log is kept on the cluster}"
  fi
  DV=$why DS=$state; post "$1" grid/deploy "$state" "$why"; say "install: $why (see $log)"; return 1
}

github_checks() { # SHA -> green | pending | failed | unknown: GitHub's own check runs on the commit
  local out
  out=$(GH api "repos/$REPO/commits/$1/check-runs?per_page=100" --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv' 2>/dev/null) \
    || { echo unknown; return 0; }
  # none yet: the push's workflow has not started
  [ -n "$out" ] || { echo pending; return 0; }
  printf '%s\n' "$out" | awk -F'\t' '$2 != "completed" { open = 1; next } $3 !~ /^(success|neutral|skipped)$/ { bad = 1 }
    END { print (bad ? "failed" : (open ? "pending" : "green")) }'
}

# ---- one run, a person at the keyboard ------------------------------------------------------------
deploy_now() { # after the suite: GitHub's checks, main's head, then the install job, waited on once a minute
  local tries=0 c head out job st
  [ "$SUITE_FAILED" = 0 ] || { post "$SHA" grid/deploy failure "the grid suite failed; not installed"; return 1; }
  [ "$CHECK_FAILED" = 0 ] || { post "$SHA" grid/deploy failure "the container check failed on the grid; not installed"; return 1; }
  while :; do
    c=$(github_checks "$SHA")
    case "$c" in
      green) break;;
      failed) post "$SHA" grid/deploy failure "GitHub's checks failed; not installed"; say "GitHub's checks failed: not installed"; return 1;;
    esac
    tries=$((tries + 1))
    [ $tries -le 60 ] || { post "$SHA" grid/deploy error "GitHub's checks did not finish within an hour; not installed"; say "GitHub's checks did not finish: not installed"; return 1; }
    say "GitHub's checks: $c; asking again in a minute"; sleep 60
  done
  head=$(locked fetch_ref main) || { post "$SHA" grid/deploy error "could not read main's head; not installed"; return 1; }
  [ "$head" = "$SHA" ] || { post "$SHA" grid/deploy error "not installed: main has moved on to a newer commit"; say "main is now $head: not installed"; return 1; }
  place "$RUN/src/tools/grid_ci.sbatch"
  out=$(SB --parsable ${JOB_PLACE[@]+"${JOB_PLACE[@]}"} -D "$RUN" "$RUN/src/tools/grid_deploy.sbatch" ${SITE_ARGS[@]+"${SITE_ARGS[@]}"} 2>&1) \
    || { post "$SHA" grid/deploy error "the scheduler refused the install job"; say "sbatch refused: $out"; return 1; }
  job=$(job_id "$out") || { post "$SHA" grid/deploy error "the scheduler gave no job number for the install"; say "sbatch gave no job number: $out"; return 1; }
  post "$SHA" grid/deploy pending "installing on the grid"
  say "install is job $job (log $RUN/deploy-$job.log)"
  st=$(wait_job "$job"); say "job $job: $st"; [ -f "$RUN/deploy-$job.log" ] && tail -3 "$RUN/deploy-$job.log"
  deploy_verdict "$SHA" "$RUN" "$job" "$st"
}

run_once() {
  [ -x "$GHBIN" ] || die "gh is not installed (https://cli.github.com; gh auth login once)"
  locked ci_clone || die "clone of $REPO failed"
  SHA=$(locked fetch_ref "$REF") || die "fetch of $REF failed"
  RUN="$CI/run-$SHA"
  locked tree_add "$RUN" "$SHA" || die "worktree for $SHA failed"
  say "grid CI for $REPO@$REF ($SHA) in $RUN"
  SUITE_FAILED=0 CHECK_FAILED=0
  post "$SHA" grid/framework-suite-py36 pending "suite queued on the grid"
  [ $DEPLOY = 1 ] && post "$SHA" grid/deploy pending "waiting for the grid suite"
  OUT=$(SB --parsable ${SB_ARGS[@]+"${SB_ARGS[@]}"} -D "$RUN" "$RUN/src/tools/grid_ci.sbatch" 2>&1) && JOB=$(job_id "$OUT") || {
    post "$SHA" grid/framework-suite-py36 error "the scheduler refused the job"
    [ $DEPLOY = 1 ] && post "$SHA" grid/deploy error "the scheduler refused the suite; not installed"
    locked tree_remove "$RUN"; die "sbatch refused the suite (or gave no job number): $OUT"; }
  LOG="$RUN/ci-$JOB.log"
  say "suite is job $JOB (log $LOG)"
  ST=$(wait_job "$JOB"); say "job $JOB: $ST"; [ -f "$LOG" ] && tail -3 "$LOG"
  suite_verdict "$SHA" "$RUN" "$JOB" "$ST" || SUITE_FAILED=1
  if [ "$CONTAINER" = 1 ]; then
    post "$SHA" grid/slurm-in-container pending "container check queued on the grid"
    OUT=$(SB --parsable ${SB_ARGS[@]+"${SB_ARGS[@]}"} -D "$RUN" "$RUN/src/framework/tests/grid/slurm_in_container.sbatch" "$RUN/src/framework" 2>&1) && JOB2=$(job_id "$OUT") || {
      post "$SHA" grid/slurm-in-container error "the scheduler refused the job"
      [ $DEPLOY = 1 ] && post "$SHA" grid/deploy error "the scheduler refused the container check; not installed"
      locked tree_remove "$RUN"; die "sbatch refused the container check (or gave no job number): $OUT"; }
    say "container check is job $JOB2 (log $RUN/slurm_check_$JOB2.out)"
    ST2=$(wait_job "$JOB2"); say "job $JOB2: $ST2"
    container_verdict "$SHA" "$RUN" "$JOB2" "$ST2" || CHECK_FAILED=1
  fi
  FAILED=$(( SUITE_FAILED | CHECK_FAILED ))
  if [ $DEPLOY = 1 ]; then deploy_now || FAILED=1; fi
  locked tree_remove "$RUN"
  exit "$FAILED"
}

# ---- the watcher ------------------------------------------------------------------------------------
WATCHED=(grid_ci.sh grid_ci_watch.sbatch grid_ci.sbatch)
install_bin() { # DIR: the watcher's own copy of its scripts from DIR, each replaced by a rename (a tick
  # reading the old file keeps reading it), and only when every one of them parses
  local f
  for f in "${WATCHED[@]}"; do bash -n "$1/$f" 2>/dev/null || { say "$1/$f is missing or does not parse"; return 1; }; done
  mkdir -p "$WATCH/bin" || return 1
  for f in "${WATCHED[@]}"; do
    cp "$1/$f" "$WATCH/bin/.$f.new" && chmod 755 "$WATCH/bin/.$f.new" && mv -f "$WATCH/bin/.$f.new" "$WATCH/bin/$f" || { say "could not copy $f into $WATCH/bin"; return 1; }
  done
}

watch_start() {
  local q out
  [ -x "$GHBIN" ] || die "gh is not installed (https://cli.github.com; gh auth login once)"
  mkdir -p "$WATCH" || die "cannot create $WATCH"
  q=$(SQ -h -u "$USER" -n hpcw_ci_watch -o '%i %T' 2>&1) || die "squeue did not answer: $q"
  [ -z "$q" ] || die "a watcher is already queued or running (job $(printf '%s' "$q" | tr '\n' ' ' | sed 's/ *$//'); last tick: $(cat "$WATCH/last-tick" 2>/dev/null || echo none)); tools/grid_ci.sh --unwatch stops it"
  install_bin "$HERE" || die "nothing started"
  rm -f "$WATCH/STOP" "$WATCH/next" "$WATCH/next.submitting"
  place "$WATCH/bin/grid_ci.sbatch"
  out=$(SB --parsable --dependency=singleton ${JOB_PLACE[@]+"${JOB_PLACE[@]}"} -D "$WATCH" "$WATCH/bin/grid_ci_watch.sbatch" "${TICK_ARGS[@]}" 2>&1) \
    || die "sbatch refused the watcher: $out"
  say "watching $REPO's main: job $(job_id "$out" || printf '%s' "$out") looks now, then every $EVERY minutes$([ $CONTAINER = 1 ] && echo ', with the container check')"
  say "it installs main's head once GitHub's checks and the grid suite pass; its log is $WATCH/watch.log; tools/grid_ci.sh --unwatch stops it"
}

watch_stop() {
  local ids
  mkdir -p "$WATCH" && date -u +%FT%TZ > "$WATCH/STOP" || die "cannot write $WATCH/STOP"
  ids=$(SQ -h -u "$USER" -n hpcw_ci_watch -t PENDING -o '%i' 2>&1) || die "squeue did not answer ($ids); STOP is written, so the next tick ends the watcher"
  [[ "$ids" =~ ^[0-9[:space:]]*$ ]] || die "squeue answered something else than job ids: $ids"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    SC $ids || die "scancel failed; STOP is written, so the next tick ends the watcher"
    say "cancelled the queued tick (job $(printf '%s' "$ids" | tr '\n' ' ' | sed 's/ *$//'))"
  else say "no tick was queued"; fi
  say "STOP written: a tick running now ends without a successor. A job it already submitted runs to its end, and its verdict is posted when a watcher runs again"
}

# one tick: its successor first, then main's head (and any older commit still in flight) moved on
# by at most one job. State per commit lives in <clone>/auto-<sha>/ (the watcher's runs, apart from
# a person's run-<sha>/, so neither removes the other's worktree): <kind>.submitting is written
# before a sbatch and <kind>.job after it, so a tick stopped in between and run again asks the
# scheduler's accounting (one sacct, by the job's name, unique per commit) instead of submitting twice
declare -A JST=() JNO=()
NOW=$(date +%s)
SACCT_OK=0
jobname() { printf 'hpcw_ci_%s_%s' "$1" "$(basename "$2" | sed 's/^auto-//' | cut -c1-12)"; }
in_flight() { local d; for d in "$CI"/auto-*; do [ -d "$d" ] && [ ! -e "$d/done" ] && printf '%s\n' "$d"; done; return 0; }

ask_sacct() { # one sacct for every job the watcher has in flight: JST[name]=state, JNO[name]=id
  local d k ids="" names="" since="$NOW" t out id name st
  while IFS= read -r d; do
    for k in suite check deploy; do
      if [ -s "$d/$k.job" ]; then
        ids="$ids,$(cat "$d/$k.job")"; names="$names,$(jobname "$k" "$d")"
        t=$(stat -c %Y "$d/$k.job" 2>/dev/null || echo "$NOW"); [ "$t" -lt "$since" ] && since=$t
      elif [ -s "$d/$k.submitting" ]; then
        names="$names,$(jobname "$k" "$d")"; UNRESOLVED=1
        t=$(cat "$d/$k.submitting"); [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -lt "$since" ] && since=$t
      fi
    done
  done < <(in_flight)
  [ -n "$names" ] || { SACCT_OK=1; return 0; }
  if [ "${UNRESOLVED:-0}" = 1 ]; then
    # a submission no tick wrote down: only its name can find it, so ask by name since the oldest one
    out=$(SA -X -n -P -u "$USER" -S "$(date -d "@$((since - 120))" +%Y-%m-%dT%H:%M:%S)" --name "${names#,}" -o JobID,JobName,State 2>&1)
  else
    out=$(SA -X -n -P -j "${ids#,}" -o JobID,JobName,State 2>&1)
  fi || { say "sacct did not answer ($(printf '%s' "$out" | tail -1)); jobs in flight wait for the next tick"; return 1; }
  while IFS='|' read -r id name st; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if [ -z "${JNO[$name]:-}" ] || [ "$id" -gt "${JNO[$name]}" ]; then JNO[$name]=$id; JST[$name]=${st%% *}; fi
  done <<< "$out"
  SACCT_OK=1
}

resolve() { # RUN KIND -> 0 go on, 1 wait: a .submitting marker becomes the job's record, or goes
  local d=$1 k=$2 name t
  [ -s "$d/$k.submitting" ] && [ ! -s "$d/$k.job" ] || return 0
  name=$(jobname "$k" "$d")
  if [ -n "${JNO[$name]:-}" ]; then
    printf '%s\n' "${JNO[$name]}" > "$d/$k.job" && rm -f "$d/$k.submitting"
    say "  $k: job ${JNO[$name]}, found by its name (a tick stopped before it wrote the number down)"; return 0
  fi
  [ "$SACCT_OK" = 1 ] || return 1
  t=$(cat "$d/$k.submitting"); [[ "$t" =~ ^[0-9]+$ ]] || t=0
  # the accounting can lag a submission by a little; a quarter of an hour without a trace means none was made
  if [ $((NOW - t)) -lt 900 ]; then say "  $k: submitted $(( (NOW - t) / 60 )) min ago and not yet in the scheduler's accounting; waiting"; return 1; fi
  rm -f "$d/$k.submitting"; say "  $k: the scheduler never saw that submission; it may be made again"; return 0
}

submit() { # RUN KIND SCRIPT [ARGS...]: one job, written down before and after sbatch
  local d=$1 k=$2 script=$3 out id; shift 3
  local where=(${SB_ARGS[@]+"${SB_ARGS[@]}"})
  # the suite and the container check keep the queues their own headers name; the install names none
  if [ "$k" = deploy ]; then place "$d/src/tools/grid_ci.sbatch"; where=(${JOB_PLACE[@]+"${JOB_PLACE[@]}"}); fi
  printf '%s\n' "$NOW" > "$d/$k.submitting" || return 1
  out=$(SB --parsable --job-name "$(jobname "$k" "$d")" ${where[@]+"${where[@]}"} -D "$d" "$script" "$@" 2>&1) \
    || { rm -f "$d/$k.submitting"; say "  $k: the scheduler refused the job: $(printf '%s' "$out" | tail -1)"; return 1; }
  # taken but no number in the answer: the marker stays, and the next tick finds the job by its name
  id=$(job_id "$out") || { say "  $k: the scheduler gave no job number ($(printf '%s' "$out" | tail -1)); the next tick finds it by its name"; return 0; }
  printf '%s\n' "$id" > "$d/$k.job" && rm -f "$d/$k.submitting"
  say "  $k: job $id"
}

finish() { # RUN STATE SENTENCE: the commit's last word, posted as grid/deploy; the worktree goes
  post "${1##*/auto-}" grid/deploy "$2" "$3"
  done_mark "$1" "$2: $3"
}
done_mark() { # RUN TEXT
  printf '%s\n' "$2" > "$1/done"
  locked tree_remove "$1"
  say "  done: $2"
}
deploy_busy() { # RUN: another commit's install not yet ended (one install at a time, oldest first)
  local d
  while IFS= read -r d; do
    [ "$d" = "$1" ] && continue
    { [ -s "$d/deploy.job" ] && ! final "${JST[$(jobname deploy "$d")]:-}"; } && return 0
    [ -s "$d/deploy.submitting" ] && return 0
  done < <(in_flight)
  return 1
}

state_of() { # RUN KIND -> the job's final state; 1 (with a line saying why) while it is not final
  local st; st=${JST[$(jobname "$2" "$1")]:-}
  final "$st" && { printf '%s' "$st"; return 0; }
  # a job the accounting has no row for three days after it was written down will not get one
  if [ -z "$st" ] && [ -n "$(find "$1/$2.job" -mmin +4320 2>/dev/null)" ]; then printf '%s' LOST; return 0; fi
  say "  $2: job $(cat "$1/$2.job") ${st:-not yet in the accounting}" >&2; return 1
}

advance() { # RUN IS_HEAD: one commit moved on by at most one job
  local d=$1 head=$2 sha k st c v
  sha=${d##*/auto-}
  say "${sha:0:12}$([ "$head" = 1 ] && echo ' (main)'):"
  for k in suite check deploy; do resolve "$d" "$k" || return 0; done
  if [ ! -s "$d/suite.job" ]; then
    [ "$head" = 1 ] || { done_mark "$d" "superseded: main moved on before the grid ran it"; return 0; }
    c=$(github_checks "$sha")
    case "$c" in
      pending) say "  GitHub's checks are not finished; the next tick looks again"; return 0;;
      unknown) say "  GitHub did not answer; the next tick asks again"; return 0;;
      failed)
        mkdir -p "$d"
        # posted once; checks run again on GitHub that pass are picked up by a later tick
        [ -e "$d/github.failed" ] || { post "$sha" grid/deploy failure "GitHub's checks failed; not installed"; : > "$d/github.failed"; }
        say "  GitHub's checks failed: nothing runs on the grid unless they are run again and pass"; return 0;;
    esac
    rm -f "$d/github.failed"
    locked tree_add "$d" "$sha" || { say "  could not make the worktree; the next tick tries again"; return 0; }
    if submit "$d" suite "$d/src/tools/grid_ci.sbatch"; then post "$sha" grid/framework-suite-py36 pending "suite queued on the grid"
    else post "$sha" grid/framework-suite-py36 error "the scheduler refused the job; the next tick tries again"; return 0; fi
    if [ "$CONTAINER" = 1 ]; then
      if submit "$d" check "$d/src/framework/tests/grid/slurm_in_container.sbatch" "$d/src/framework"; then post "$sha" grid/slurm-in-container pending "container check queued on the grid"
      else post "$sha" grid/slurm-in-container error "the scheduler refused the job; the next tick tries again"; fi
    fi
    post "$sha" grid/deploy pending "GitHub's checks passed; waiting for the grid suite"
    return 0
  fi
  [ "$SACCT_OK" = 1 ] || return 0
  # the container check, asked for while this commit was in flight and not yet submitted
  if [ "$CONTAINER" = 1 ] && [ ! -s "$d/check.job" ] && [ ! -s "$d/check.verdict" ]; then
    submit "$d" check "$d/src/framework/tests/grid/slurm_in_container.sbatch" "$d/src/framework" \
      && post "$sha" grid/slurm-in-container pending "container check queued on the grid"
    return 0
  fi
  st=$(state_of "$d" suite) || return 0
  if [ ! -s "$d/suite.verdict" ]; then
    v=fail; suite_verdict "$sha" "$d" "$(cat "$d/suite.job")" "$st" && v=pass; echo "$v" > "$d/suite.verdict"
  fi
  if [ -s "$d/check.job" ]; then
    st=$(state_of "$d" check) || return 0
    if [ ! -s "$d/check.verdict" ]; then
      v=fail; container_verdict "$sha" "$d" "$(cat "$d/check.job")" "$st" && v=pass; echo "$v" > "$d/check.verdict"
    fi
  fi
  [ "$(cat "$d/suite.verdict")" = pass ] || { finish "$d" failure "the grid suite failed; not installed"; return 0; }
  [ ! -s "$d/check.verdict" ] || [ "$(cat "$d/check.verdict")" = pass ] || { finish "$d" failure "the container check failed on the grid; not installed"; return 0; }
  if [ ! -s "$d/deploy.job" ]; then
    [ "$head" = 1 ] || { finish "$d" error "not installed: main has moved on to a newer commit"; return 0; }
    if deploy_busy "$d"; then say "  another commit's install has not ended; this one waits"; return 0; fi
    if submit "$d" deploy "$d/src/tools/grid_deploy.sbatch" ${SITE_ARGS[@]+"${SITE_ARGS[@]}"}; then post "$sha" grid/deploy pending "installing on the grid"
    else post "$sha" grid/deploy error "the scheduler refused the install job; the next tick tries again"; fi
    return 0
  fi
  st=$(state_of "$d" deploy) || return 0
  if deploy_verdict "$sha" "$d" "$(cat "$d/deploy.job")" "$st"; then
    # the watcher's own scripts follow the commit it has just installed
    if install_bin "$d/src/tools"; then say "  the watcher's scripts now come from ${sha:0:12}"
    else say "  the watcher keeps its scripts as they were"; fi
    done_mark "$d" "success: $DV"
  else done_mark "$d" "$DS: $DV"; fi
}

successor() { # this tick's one successor, queued once even when this job is run again after a requeue
  local out id
  if [ -s "$WATCH/next" ] && [ "$(cut -d' ' -f1 "$WATCH/next")" = "$SLURM_JOB_ID" ]; then
    say "next tick: job $(cut -d' ' -f2 "$WATCH/next"), queued by an earlier run of this job"; return 0
  fi
  if [ "$(cat "$WATCH/next.submitting" 2>/dev/null)" = "$SLURM_JOB_ID" ]; then
    # an earlier run of this same job stopped while it submitted: one squeue says whether that got through
    id=$(SQ -h -u "$USER" -n hpcw_ci_watch -t PENDING -o '%i' 2>/dev/null | grep -vx "$SLURM_JOB_ID" | head -1)
    if [ -n "$id" ]; then
      printf '%s %s\n' "$SLURM_JOB_ID" "$id" > "$WATCH/next" && rm -f "$WATCH/next.submitting"
      say "next tick: job $id, queued by an earlier run of this job"; return 0
    fi
  fi
  printf '%s\n' "$SLURM_JOB_ID" > "$WATCH/next.submitting"
  place "$WATCH/bin/grid_ci.sbatch"
  out=$(SB --parsable --begin="now+${EVERY}minutes" --dependency=singleton ${JOB_PLACE[@]+"${JOB_PLACE[@]}"} -D "$WATCH" "$WATCH/bin/grid_ci_watch.sbatch" "${TICK_ARGS[@]}" 2>&1) \
    || { rm -f "$WATCH/next.submitting"; say "could not queue the next tick: $(printf '%s' "$out" | tail -1)"; return 1; }
  # taken but no number in the answer: next.submitting stays, and a run of this same job again asks squeue
  id=$(job_id "$out") || { say "next tick: queued, but the scheduler gave no job number ($(printf '%s' "$out" | tail -1))"; return 0; }
  printf '%s %s\n' "$SLURM_JOB_ID" "$id" > "$WATCH/next" && rm -f "$WATCH/next.submitting"
  say "next tick: job $id, in $EVERY minutes"
}

tick() {
  local head d chained=1
  [ -n "${SLURM_JOB_ID:-}" ] || die "--tick runs inside the watcher's job; start the watcher with --watch"
  [ -x "$GHBIN" ] || die "gh is not installed (https://cli.github.com; gh auth login once)"
  say "== tick $SLURM_JOB_ID on $(hostname -s) at $(date -u +%FT%TZ)"
  if [ -e "$WATCH/STOP" ]; then say "STOP is set ($WATCH/STOP): the watcher ends here; tools/grid_ci.sh --watch starts it again"; return 0; fi
  # one log for every tick (--open-mode=append), one older one kept
  if [ -f "$WATCH/watch.log" ] && [ "$(wc -c < "$WATCH/watch.log")" -gt 1048576 ]; then mv -f "$WATCH/watch.log" "$WATCH/watch.log.1"; fi
  successor || chained=0
  printf '%s job %s on %s\n' "$(date -u +%FT%TZ)" "$SLURM_JOB_ID" "$(hostname -s)" > "$WATCH/last-tick"
  locked ci_clone || { say "no clone of $REPO; the next tick tries again"; return 0; }
  head=$(locked fetch_ref main) || { say "could not fetch main; the next tick tries again"; return 0; }
  say "main is $head"
  ask_sacct
  while IFS= read -r d; do [ "$d" = "$CI/auto-$head" ] || advance "$d" 0; done < <(in_flight)
  if [ -e "$CI/auto-$head/done" ]; then say "${head:0:12} (main): $(cat "$CI/auto-$head/done")"
  else advance "$CI/auto-$head" 1; fi
  if [ $chained = 0 ]; then
    # the chain ends with this tick: say so where it is seen, on the commit that will not be installed
    [ -e "$CI/auto-$head/done" ] || post "$head" grid/deploy error "the grid's watcher stopped (it could not queue its next look); tools/grid_ci.sh --watch starts it again"
    say "the watcher ends here: no successor could be queued"
    return 1
  fi
}

case "$MODE" in
  run) run_once;;
  watch) watch_start;;
  unwatch) watch_stop;;
  tick) tick;;
esac
