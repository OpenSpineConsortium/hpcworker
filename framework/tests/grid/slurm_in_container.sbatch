#!/bin/bash
# The grid check for framework 9's scheduler_in_worker: one short job that starts the worker's
# container with the Slurm binds made exactly as the worker job makes them (lib/adapters/common.sh
# hpcw_slurm_in_container; the site profile's image, runtime and binds) and runs, from inside, what
# a worker's Claude Code would: squeue -u, sinfo -s, sacct on this job, sbatch --test-only (the
# controller answers; nothing is submitted), scancel --version, and the environment a job submitted
# from inside would start from. It starts no worker and no second job. The maintainer's check, not
# published with the shared copy (tools/deploy_shared.sh ships bin/ lib/ jobs/ profiles/ only).
#
# Run once, as job 40518457 on asx1 (2026-09-30), with the wrappers as they were then: everything
# above answered; `scontrol show job` did not (the host's scontrol needs libreadline.so.6, which the
# bookworm image lacks), so scontrol gets no wrapper; and the environment check showed a submitted job
# would start with the container's LD_LIBRARY_PATH, so the wrappers now carry the host's. Those two
# changes came after that run and have not been run on the grid.
#
#   sbatch -D <an output folder> tests/grid/slurm_in_container.sbatch <framework folder> [profile]
#
# Container temp and cache are node-local (hpcw_runtime_exec puts them under the job's node temp),
# the wrappers and user lists go under /dev/shm/$USER/hpcw_<job>, and the EXIT trap removes both.
#SBATCH --job-name=hpcw9_slurmcheck
#SBATCH --partition=secp
#SBATCH --qos=secondary
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:05:00
#SBATCH --output=slurm_check_%j.out
#SBATCH --no-requeue
set -uo pipefail
CODE="${1:?give the framework folder}"; PROFILE="${2:-$CODE/profiles/wayne.json}"
say() { echo "$(date -u +%FT%TZ) $*"; }
# shellcheck disable=SC1090
source "$CODE/lib/adapters/common.sh" || { echo "no $CODE/lib/adapters/common.sh"; exit 1; }
PY=$(command -v python3 || echo /usr/bin/python3)
ENV_LINES=$("$PY" "$CODE/lib/profile.py" shellenv "$PROFILE") || { echo "profile $PROFILE unreadable"; exit 1; }
eval "$ENV_LINES"
export RUNTIME="$P_runtime" RUNTIME_BIN="$P_runtime_bin" RUNTIME_MODULE="$P_runtime_module"
JOB=$(hpcw_job_id); [ -n "$JOB" ] || { echo "REFUSING: a batch job body; submit it with sbatch"; exit 1; }
HOST_TMPDIR="${TMPDIR:-}"
HPCW_NODE_TMP=$(HPCW_NODE_TMP_PATTERN="$P_node_tmp" hpcw_node_tmp); export HPCW_NODE_TMP
IPC="$P_ipc_dir/$USER/hpcw_$JOB"
mkdir -p "$HPCW_NODE_TMP/tmp" "$HPCW_NODE_TMP/cache" "$IPC" && chmod 700 "$IPC" || { echo "cannot create $HPCW_NODE_TMP or $IPC"; exit 1; }
trap 'hpcw_rm_own_tmp "$HPCW_NODE_TMP" "$IPC"; say "cleanup: removed $HPCW_NODE_TMP and $IPC"' EXIT
say "hpcworker $(cat "$CODE/VERSION") Slurm-in-container check, job $JOB on $(hostname -s); profile $PROFILE (scheduler_in_worker=$P_scheduler_in_worker)"
say "host pieces:"
ls -ld /usr/bin/sbatch /usr/lib64/slurm /etc/slurm /var/run/munge /var/run/munge/munge.socket.2 /usr/lib64/libmunge.so.2 2>&1 | sed 's/^/    /'
echo "    libmunge.so.2 -> $(readlink -f /usr/lib64/libmunge.so.2)"
echo "    SlurmUser in slurm.conf: $(sed -n 's/^[[:space:]]*SlurmUser[[:space:]]*=[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p' /etc/slurm/slurm.conf 2>/dev/null | head -1)"
echo "    host TMPDIR=${HOST_TMPDIR:-unset} LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-unset}"
BINDS=""; for b in $P_binds; do BINDS="$BINDS${BINDS:+ }-B $b"; done
if HPCW_HOST_TMPDIR="$HOST_TMPDIR" hpcw_slurm_in_container "$IPC/slurm" "$P_image_store_path" "$P_image_store_type"; then
  say "$HPCW_SLURM_NOTE"
  say "binds: $BINDS $HPCW_SLURM_BINDS"
else
  say "NOT BOUND: $HPCW_SLURM_NOTE"; exit 2
fi
export HPCW_BINDS="$BINDS $HPCW_SLURM_BINDS" APPTAINERENV_PREPEND_PATH="$HPCW_SLURM_INSIDE" SINGULARITYENV_PREPEND_PATH="$HPCW_SLURM_INSIDE"
say "the container, from inside:"
hpcw_runtime_exec "$P_image_store_path" env TMPDIR=/tmp HPCW_JOB="$JOB" bash "$CODE/tests/grid/slurm_in_container_inside.sh" "$JOB" "$P_partition_cpu" "$P_qos_cpu"
rc=$?
say "inside exited $rc"
exit $rc
