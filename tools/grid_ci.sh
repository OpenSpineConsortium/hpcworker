#!/bin/bash
# The grid lane of CI: run ON the cluster (the portal's shell, or a worker), never by GitHub.
# GitHub's runners cannot reach the grid (the VPN and a one-time code stand between), and no
# token of the grid's or GitHub's ever enters a repository, a job file or an argv (CLAUDE.md):
# this script uses the `gh` sign-in already in the account's home, and GitHub sees only a
# commit status — pass or fail, with one sentence.
#
#   tools/grid_ci.sh [--ref main] [--repo OpenSpineConsortium/hpcworker] [--container]
#
# What it does: fetches the ref into its own clone (on the lab volume, one per repository),
# gives the run a worktree of its own named by the commit — a queued job's tree can then never
# move under it, however many runs overlap — posts "pending" on that commit, submits
# tools/grid_ci.sbatch (the suite on a compute node under /usr/bin/python3), asks the scheduler
# at most once a minute, reads the job's log, and posts success or failure as the status
# grid/framework-suite-py36. With --container it also runs
# framework/tests/grid/slurm_in_container.sbatch (the worker's container with the Slurm binds;
# its exit code is its verdict) and posts grid/slurm-in-container. On the login node this
# script itself is only git, gh, sbatch and sacct; everything heavier runs inside the jobs.
set -uo pipefail
say() { printf '%s\n' "$*"; }
die() { printf 'grid_ci: %s\n' "$*" >&2; exit 1; }

REPO=OpenSpineConsortium/hpcworker REF=main CONTAINER=0
while [ $# -gt 0 ]; do case "$1" in
  --ref) REF="$2"; shift 2;; --repo) REPO="$2"; shift 2;; --container) CONTAINER=1; shift;;
  -h|--help) sed -n '2,18p' "$0"; exit 0;;
  *) die "unknown option $1 (--help)";; esac; done

# the account's gh sign-in, not a GITHUB_TOKEN a ~/.bashrc may export for another account
GHBIN=$(command -v gh || true); [ -n "$GHBIN" ] || GHBIN="$HOME/.local/bin/gh"
[ -x "$GHBIN" ] || die "gh is not installed (https://cli.github.com; gh auth login once)"
GH() { env -u GITHUB_TOKEN -u GH_TOKEN "$GHBIN" "$@"; }
SBATCH=$(command -v sbatch || echo /opt/hpcw/slurm/bin/sbatch); [ -x "$SBATCH" ] || die "no sbatch here"
SACCT=$(command -v sacct || echo /opt/hpcw/slurm/bin/sacct)

# one clone per repository (--repo after a first run must not fetch from the wrong origin), and
# one worktree per run, named by the commit: on the lab volume, never in a person's working tree
CIROOT="${HPCW_CI_DIR:-/rs/rs_grp_oschome/$USER/hpcworker-ci}"
CI="$CIROOT/${REPO//\//-}"
mkdir -p "$CI" || die "cannot create $CI"
# every git call speaks through the same gh sign-in: a ~/.gitconfig credential helper may hold
# ANOTHER account's sign-in (measured 2026-10-03: the clone came through gh, then the plain fetch
# went through a global `store` helper as a second account and read "Repository not found")
HELPER="!env -u GITHUB_TOKEN -u GH_TOKEN $GHBIN auth git-credential"
if [ ! -d "$CI/src/.git" ]; then
  git -c credential.helper= -c "credential.helper=$HELPER" clone -q "https://github.com/$REPO.git" "$CI/src" || die "clone of $REPO failed"
fi
git -C "$CI/src" config --unset-all credential.helper 2>/dev/null
git -C "$CI/src" config credential.helper '' && git -C "$CI/src" config --add credential.helper "$HELPER"
git -C "$CI/src" fetch -q origin "$REF" || die "fetch of $REF failed"
SHA=$(git -C "$CI/src" rev-parse FETCH_HEAD) || die "no commit for $REF"
RUN="$CI/run-$SHA"
# a worktree already there is this same immutable commit (an earlier or crashed run's); reuse it
[ -d "$RUN/src" ] || git -C "$CI/src" worktree add -q --detach "$RUN/src" "$SHA" || die "worktree for $SHA failed"
say "grid CI for $REPO@$REF ($SHA) in $RUN"

post() { # CONTEXT STATE SENTENCE
  GH api "repos/$REPO/statuses/$SHA" -f context="$1" -f state="$2" -f description="$3" --silent \
    || say "note: could not post $1=$2 (the run's verdict is above either way)"
}

wait_job() { # JOB -> the job's final sacct state, asked at most once a minute
  local job="$1" st
  while :; do
    sleep 60
    st=$("$SACCT" -j "$job" -X -n -o State 2>/dev/null | head -1 | tr -d ' ')
    case "$st" in PENDING|RUNNING|REQUEUED|SUSPENDED|RESIZING|'') continue;; *) break;; esac
  done
  printf '%s' "$st"
}

FAILED=0
post grid/framework-suite-py36 pending "suite queued on the grid"
OUT=$("$SBATCH" --parsable -D "$RUN" "$RUN/src/tools/grid_ci.sbatch") || { post grid/framework-suite-py36 error "the scheduler refused the job"; die "sbatch refused: $OUT"; }
JOB=${OUT%%;*}; LOG="$RUN/ci-$JOB.log"
say "suite is job $JOB (log $LOG)"
ST=$(wait_job "$JOB"); say "job $JOB: $ST"; [ -f "$LOG" ] && tail -3 "$LOG"
# the suite's own word, not only the scheduler's: the log ends "exit 0" and says ALL OK
if [ "$ST" = COMPLETED ] && grep -q '^exit 0$' "$LOG" 2>/dev/null && grep -q '^ALL OK$' "$LOG" 2>/dev/null; then
  N=$(grep -m1 -oE '^Ran [0-9]+' "$LOG" | grep -oE '[0-9]+' || echo '?')
  NODE=$(sed -n 's/^host \([A-Za-z0-9-]*\).*/\1/p' "$LOG" | head -1)
  post grid/framework-suite-py36 success "$N tests, ALL OK on $NODE under python 3.6"
  say "suite: ALL OK"
else
  post grid/framework-suite-py36 failure "the suite failed on the grid ($ST); log kept on the cluster"
  say "suite: FAILED (see $LOG)"; FAILED=1
fi

if [ "$CONTAINER" = 1 ]; then
  post grid/slurm-in-container pending "container check queued on the grid"
  OUT=$("$SBATCH" --parsable -D "$RUN" "$RUN/src/framework/tests/grid/slurm_in_container.sbatch" "$RUN/src/framework") \
    || { post grid/slurm-in-container error "the scheduler refused the job"; die "sbatch refused: $OUT"; }
  JOB2=${OUT%%;*}
  say "container check is job $JOB2 (log $RUN/slurm_check_$JOB2.out)"
  ST2=$(wait_job "$JOB2"); say "job $JOB2: $ST2"
  if [ "$ST2" = COMPLETED ]; then
    post grid/slurm-in-container success "the worker's container answered every scheduler call"
    say "container check: ok"
  else
    post grid/slurm-in-container failure "the container check failed ($ST2); log kept on the cluster"
    say "container check: FAILED (see $RUN/slurm_check_$JOB2.out)"; FAILED=1
  fi
fi
# the worktree goes, the run folder and its logs stay
git -C "$CI/src" worktree remove --force "$RUN/src" 2>/dev/null || say "note: worktree $RUN/src left in place"
exit "$FAILED"
