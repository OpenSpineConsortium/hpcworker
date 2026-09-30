#!/bin/bash
# Runs inside the worker's container for tests/grid/slurm_in_container.sbatch: the Slurm commands a
# worker's Claude Code would run, each with its exit status. $1 this job's id, $2 partition, $3 QoS.
set -u
JOB="$1"; PART="$2"; QOS="${3:-}"
fails=0
step() { local rc=$1; echo "    (exit $rc)"; [ "$rc" = 0 ] || fails=$((fails + 1)); }
echo "== $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"), $(id -un) uid $(id -u); PATH=$PATH"
for c in sbatch squeue sacct scancel sinfo; do printf '    %-8s %s\n' "$c" "$(command -v "$c" || echo MISSING)"; done
echo "    users the config names: $(grep -E '^(slurm|munge):' /etc/passwd | cut -d: -f1,3 | tr '\n' ' ')"
echo "== squeue -u $USER"
squeue -u "$USER"; step $?
echo "== sinfo -s"
sinfo -s; step $?
echo "== sacct -j $JOB -X"
sacct -j "$JOB" -X --format=JobID,JobName%20,Partition,QOS,State,NodeList; step $?
echo "== sbatch --test-only (the controller answers; nothing is submitted)"
printf '#!/bin/bash\ntrue\n' > /tmp/hpcw_testonly.sh
if [ -n "$QOS" ]; then sbatch --test-only -p "$PART" -q "$QOS" -t 1 -c 1 --mem=100M -J hpcw_testonly /tmp/hpcw_testonly.sh; else sbatch --test-only -p "$PART" -t 1 -c 1 --mem=100M -J hpcw_testonly /tmp/hpcw_testonly.sh; fi
step $?
echo "== scancel --version"
scancel --version; step $?
echo "== the environment a job submitted from here would start from (the sbatch wrapper with env in place of sbatch)"
sed 's#^exec /opt/host/bin/sbatch .*#exec env#' "$(command -v sbatch)" > /tmp/hpcw_envprobe.sh
bash /tmp/hpcw_envprobe.sh | grep -E '^(PATH|TMPDIR|LD_LIBRARY_PATH|HOME|SLURM_[A-Z_]*|APPTAINER[A-Z_]*|SINGULARITY[A-Z_]*|XDG_RUNTIME_DIR)=' | sort | sed 's/^/    /'
echo "== the container's own view: LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-unset} TMPDIR=${TMPDIR:-unset}; SLURM_ variables here: $(compgen -e | grep -c '^SLURM_')"
echo "== $fails command(s) failed"
exit $fails
