#!/bin/bash
# One job of a runner chain: `tools/grid_runner.sh --start --repo OWNER/NAME` submits the first with
# -D <runner dir>, and each job queues the next itself (--dependency=afterany:<its id>,singleton)
# before it does anything else, so the chain outlives a wall time or a preemption. It runs the
# chain's own copy of grid_runner.sh from bin/ there, never a checkout's, so a checkout that moves
# under a queued job cannot break it. The job serves GitHub's self-hosted runner inside the runner
# image on this node, one just-in-time registration at a time, until a margin before its wall time
# (grid_runner.sh --serve). The wall time, the partition and the QoS (the site profile's worker
# queue, or --partition and --qos), the cpus, the memory and any GPU arrive on sbatch's command line
# from --start's options, which outrank the lines below, so this file names no site's queue and the
# chain's size is the person's choice. Requeueable: a requeued job finds its successor already
# queued, deletes the registration the earlier run left and registers afresh. Nothing here reads a
# secret; gh uses the account's own sign-in, and no token a shell exported rides into gh, the
# container or the next job.
#SBATCH --job-name=hpcw_runner
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=08:00:00
#SBATCH --output=runner-%j.log
#SBATCH --requeue
set -uo pipefail
# started by a person's terminal or a worker: either way the job runs as a person's would, and no
# agent marker or token reaches the runner's container (which sees no environment anyway) or the jobs
# this one submits
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN
# the job starts in the folder -D named (the runner folder; the chain's log lands where --output says)
[ -f bin/grid_runner.sh ] || { echo "no bin/grid_runner.sh in $(pwd): a chain runs from the runner folder (tools/grid_runner.sh --start)"; exit 1; }
bash bin/grid_runner.sh --serve "$@"
