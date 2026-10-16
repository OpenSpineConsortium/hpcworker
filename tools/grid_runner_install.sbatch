#!/bin/bash
# The runner image's install, one job on a compute node: `tools/grid_runner.sh --install` submits
# it with -D <runner dir>. It pulls GitHub's own runner image (ghcr.io/actions/actions-runner, the
# version --install names) as a SIF, with the pull's temp and cache on this node's own disk, copies
# the runner's files out of it and runs the runner's --version inside the image with the flags
# every chain job uses, so a flag the site's Apptainer refuses, or a runner the node's kernel cannot
# run, is seen here and never in a chain; then it places the SIF under <runner dir>/image and
# names the version in image/current (grid_runner.sh --pull). Short and requeueable: a requeued
# install pulls again. Nothing here reads a secret, and no token a shell exported rides along.
# The partition and the QoS arrive on sbatch's command line (the site profile's worker queue, as
# the chain's, or --partition and --qos), so this file names no site's queue.
#SBATCH --job-name=hpcw_runner_install
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:40:00
#SBATCH --output=install-%j.log
#SBATCH --requeue
set -uo pipefail
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN
# the job starts in the folder -D named (the runner folder)
[ -f bin/grid_runner.sh ] || { echo "no bin/grid_runner.sh in $(pwd): the install runs from the runner folder (tools/grid_runner.sh --install)"; exit 1; }
bash bin/grid_runner.sh --pull "$@"
