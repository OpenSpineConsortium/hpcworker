#!/bin/bash
# One job of the chain that keeps the grid's access lists: `tools/grid_access.sh --watch` submits the
# first with -D <vendor>/access-watch, and each queues the next itself (--begin, --dependency=singleton)
# before it applies anything. It runs the chain's own copy of grid_access.sh from bin/ there, never a
# checkout's, with the root, the site, the service and the minutes on its command line, so it needs
# neither the site profile nor the framework. The token is the vendor folder's grid_token, which reads
# the access service's two lists and nothing else; it leaves that file only for a header file curl
# reads, made under the TMPDIR below and gone with it (never an argument, a line of the log or this
# job's environment). The partition and QoS arrive on sbatch's command line (grid_access.sh takes
# HPCW_ACCESS_PARTITION and HPCW_ACCESS_QOS, else the CI lane's, else grid_ci.sbatch's own), so this
# file names no site's queue. Requeueable: a requeued job finds its successor already queued. Thirty
# minutes of wall time, where a look with nothing new takes seconds: a reader of the whole volume ("."
# in the reader list) is swept inside a job, and how long that walk takes on the grid is not yet measured.
#SBATCH --job-name=hpcw_access
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:30:00
#SBATCH --output=access.log
#SBATCH --open-mode=append
#SBATCH --requeue
set -uo pipefail
# the header file and every other temporary file on this node's local disk, in a folder of this job's
# alone: the volume's $TMPDIR is not node-local, and the header must sit where no other account can look
TMPDIR=/tmp/${USER:-$(id -un)}/hpcw_access_$SLURM_JOB_ID
{ ( umask 077; mkdir -p "$TMPDIR" ) && chmod 700 "$TMPDIR" && [ -O "$TMPDIR" ]; } \
  || { echo "cannot make $TMPDIR, this job's own, on $(hostname -s); nothing applied"; exit 1; }
export TMPDIR; trap 'rm -rf "$TMPDIR"' EXIT
# started by a person's terminal or a worker: either way the job runs as a person's would, and no token
# a shell exported rides into the jobs it submits
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN
# the job starts in the folder -D named (the chain's folder; its log lands there too)
[ -f bin/grid_access.sh ] || { echo "no bin/grid_access.sh in $(pwd): the chain runs from its own folder (tools/grid_access.sh --watch)"; exit 1; }
bash bin/grid_access.sh --tick "$@"
