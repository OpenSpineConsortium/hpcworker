#!/bin/bash
# One tick of the grid's watcher: `tools/grid_ci.sh --watch` submits the first with -D <ci dir>/watch,
# and each tick queues the next itself (--begin, --dependency=singleton) before it does anything else.
# It runs the watcher's own copy of grid_ci.sh from bin/ there, never a checkout's, so a merge cannot
# break the chain that would report it (grid_ci.sh refreshes that copy only from a commit it has just
# installed). Short and light: a tick moves main's head on by at most one job and never waits on one.
# The partition and QoS arrive on sbatch's command line (grid_ci.sh takes grid_ci.sbatch's own, or
# HPCW_CI_PARTITION and HPCW_CI_QOS), so this file names no site's queue. Requeueable: a requeued tick
# finds its successor already queued and every submission it made written down. Nothing here reads a
# secret; gh and git use the account's own sign-in.
#SBATCH --job-name=hpcw_ci_watch
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:10:00
#SBATCH --output=watch.log
#SBATCH --open-mode=append
#SBATCH --requeue
set -uo pipefail
# git's and gh's temporary files on this node's local disk: the volume's $TMPDIR is not node-local
export TMPDIR=/tmp/$USER/hpcw_ci_watch_$SLURM_JOB_ID; mkdir -p "$TMPDIR"; trap 'rm -rf "$TMPDIR"' EXIT
# started by a person's terminal or a worker: either way the tick runs as a person's would, and no
# token a shell exported rides into gh, git or the jobs the tick submits
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN
# the job starts in the folder -D named (the watcher's folder; its log lands there too)
[ -f bin/grid_ci.sh ] || { echo "no bin/grid_ci.sh in $(pwd): the watcher runs from its own folder (tools/grid_ci.sh --watch)"; exit 1; }
bash bin/grid_ci.sh --tick "$@"
