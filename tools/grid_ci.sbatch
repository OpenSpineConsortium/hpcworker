#!/bin/bash
# The framework suite on a compute node, under the host's own python 3.6 — the grid lane of CI
# (tools/grid_ci.sh submits this with -D <run dir>; the checkout is <run dir>/src). Short and
# requeueable; nothing here reads a secret and nothing runs on the login node.
#SBATCH --job-name=hpcw_ci_suite
#SBATCH --partition=reqp
#SBATCH --qos=requeue
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:30:00
#SBATCH --output=ci-%j.log
#SBATCH --requeue
set -uo pipefail
echo "host $(hostname -s) $(date -u +%FT%TZ) python $(/usr/bin/python3 --version 2>&1) bash ${BASH_VERSION}"
# the tests' temporary folders stay on this node's local disk, and leave with the job
export TMPDIR=/tmp/$USER/hpcw_ci_$SLURM_JOB_ID; mkdir -p "$TMPDIR"; trap 'rm -rf "$TMPDIR"' EXIT
# submitted by a person's terminal or a worker: either way the suite runs as a person's would
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT GITHUB_TOKEN GH_TOKEN
# the job starts in the folder -D named (the run folder; the log lands there too). Not
# $SLURM_SUBMIT_DIR: that is where sbatch was TYPED, and grid_ci.sh submits from wherever it
# stands (measured: job 40555495 cd'd into the caller's checkout and found no src)
cd src || exit 1
HPCW_PYTHON=/usr/bin/python3 bash framework/tests/run.sh
echo "exit $?"
