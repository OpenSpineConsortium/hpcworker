#!/bin/bash
# hpcworker Slurm adapter. Sourced by bin/hpcworker, by the worker job and by the tests. This is
# the adapter that was run for real (Wayne State grid, Slurm, 2026-09-28/29); pbs.sh and lsf.sh are
# written from the documented commands and tested only against fixture outputs.
# Delimited text first, JSON never required: `squeue --json` exists only from 21.08 and the
# `-o`/`-P` forms exist everywhere.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

adapter_name() { echo slurm; }
adapter_job_id_var() { echo SLURM_JOB_ID; }

slurm_parse_submit() { # stdin: sbatch --parsable output ("12345" or "12345;cluster") -> id
  local line; line=$(grep -E '^[0-9]+(;|$)' | head -1)
  [ -n "$line" ] || return 1
  printf '%s\n' "${line%%;*}"
}

slurm_parse_squeue() { # stdin: squeue -h -o '%T|%N' output -> STATE|NODE|RAW ; nothing when the job is gone
  local line raw node; line=$(head -1 | tr -d '\r')
  [ -n "$line" ] || return 1
  raw=${line%%|*}; node=${line#*|}; node=${node%%|*}
  printf '%s|%s|%s\n' "$(hpcw_normalise_state slurm "$raw")" "$node" "$raw"
}

slurm_parse_squeue_many() { # stdin: squeue -h -o '%i|%T|%N' output -> ID|STATE|NODE|RAW per line (jobs squeue no longer lists are absent)
  local line id raw node
  while IFS= read -r line; do
    line=${line%$'\r'}; [ -n "$line" ] || continue
    id=${line%%|*}; line=${line#*|}; raw=${line%%|*}; node=${line#*|}; node=${node%%|*}
    printf '%s|%s|%s|%s\n' "$id" "$(hpcw_normalise_state slurm "$raw")" "$node" "$raw"
  done
}

slurm_parse_sacct() { # stdin: sacct -n -P -X --format=State,NodeList output -> STATE|NODE|RAW
  local line raw node; line=$(grep -v '^$' | tail -1 | tr -d '\r')
  [ -n "$line" ] || { echo "UNKNOWN||no record"; return 1; }
  raw=${line%%|*}; node=${line#*|}; node=${node%%|*}
  [ "$node" = "None assigned" ] && node=""
  printf '%s|%s|%s\n' "$(hpcw_normalise_state slurm "$raw")" "$node" "$raw"
}

adapter_submit() { # SCRIPT [sbatch options...] -> id ; sbatch's message on stderr when it fails
  local script="$1"; shift
  local out; out=$(sbatch --parsable "$@" "$script" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  printf '%s\n' "$out" | slurm_parse_submit || { printf '%s\n' "$out" >&2; return 1; }
}

adapter_submit_after() { # SCRIPT PARENT_ID [sbatch options...] -> id of the successor the scheduler starts when PARENT_ID has ended
  # afterany, never afterok (a parent that ends non-zero for a trivial reason would strand the chain);
  # singleton kept so two links of one name never run at once
  local script="$1" parent="$2"; shift 2
  adapter_submit "$script" --dependency="afterany:$parent,singleton" "$@"
}

adapter_status() { # ID -> STATE|NODE|RAW ; one squeue, then one sacct; never call this in a loop
  local id="$1" out
  out=$(squeue -h -j "$id" -o '%T|%N' 2>/dev/null) && [ -n "$out" ] && { printf '%s\n' "$out" | slurm_parse_squeue; return 0; }
  out=$(sacct -n -P -X -j "$id" --format=State,NodeList 2>/dev/null) || out=""
  printf '%s\n' "$out" | slurm_parse_sacct
}

adapter_status_many() { # ID[,ID...] -> ID|STATE|NODE|RAW per line, ONE squeue; ids squeue no longer knows come back as UNKNOWN (ended)
  # exit 2, and nothing printed, when squeue itself failed (a busy controller, a timeout): the caller
  # must then decide nothing, because "no job alive" read from a scheduler that did not answer would
  # submit a second worker beside one still in line. "Invalid job id" is an answer: the jobs are gone.
  local ids="$1" out rc id seen
  if command -v timeout >/dev/null 2>&1; then out=$(LC_ALL=C timeout 20 squeue -h -j "$ids" -o '%i|%T|%N' 2>&1); rc=$?; else out=$(LC_ALL=C squeue -h -j "$ids" -o '%i|%T|%N' 2>&1); rc=$?; fi
  [ $rc = 124 ] && return 2
  if [ $rc != 0 ]; then
    case "$out" in *"Invalid job id"*) out="";; *) return 2;; esac
  fi
  # squeue's own warnings start with "squeue:" or "slurm_"; only the job lines are read
  out=$(printf '%s\n' "$out" | tr -d '\r' | grep -v -E '^(squeue|slurm_[a-z_]*)[: ]')
  seen=$(printf '%s\n' "$out" | slurm_parse_squeue_many)
  [ -n "$seen" ] && printf '%s\n' "$seen"
  for id in ${ids//,/ }; do printf '%s\n' "$seen" | grep -q "^$id|" || printf '%s|UNKNOWN||ended or unknown\n' "$id"; done
}

adapter_status_one() { # ID [FORMAT] -> squeue's own line for ID in FORMAT (default %T|%N; framework 10's queue form is %T|%r|%S|%N), exit 0
  # ONE squeue. Nothing and exit 0 when Slurm no longer knows the job ("Invalid job id specified");
  # exit 2 when squeue itself failed (the controller did not answer): the caller then changes nothing,
  # so a busy controller is never read as a job that ended
  local id="$1" fmt="${2:-%T|%N}" out rc line
  # bounded: a controller that hangs must not hold `worker status` (and the panel's line) for minutes
  if command -v timeout >/dev/null 2>&1; then out=$(LC_ALL=C timeout 20 squeue -h -j "$id" -o "$fmt" 2>&1); rc=$?; else out=$(LC_ALL=C squeue -h -j "$id" -o "$fmt" 2>&1); rc=$?; fi
  [ $rc = 124 ] && return 2
  if [ $rc = 0 ]; then
    # squeue's own warnings start with "squeue:" or "slurm_"; the job's line is the first other one
    out=$(printf '%s\n' "$out" | tr -d '\r' | grep -v -E '^(squeue|slurm_[a-z_]*)[: ]' | grep -v '^[[:space:]]*$')
    # a line that starts with a state word is the job's; a notice the site prints first is passed over
    line=$(printf '%s\n' "$out" | grep -E '^[A-Z][A-Z_]*(\||$)' | head -1)
    [ -n "$line" ] || line=$(printf '%s\n' "$out" | head -1)
    [ -n "$line" ] && printf '%s\n' "$line"
    return 0
  fi
  case "$out" in *"Invalid job id"*) return 0;; esac
  return 2
}

adapter_submit_time() { # ID -> SubmitTime as ISO-8601 UTC, nothing when Slurm cannot say; ONE scontrol, run inside the job on the host side
  # (the host's scontrol, not the container's: the image cannot load it). Slurm prints local time with no zone.
  local t; t=$(timeout 20 scontrol show job "$1" -o 2>/dev/null | grep -o 'SubmitTime=[^ ]*' | head -1 | cut -d= -f2)
  hpcw_local_time_utc "$t"
  return 0
}

adapter_cancel() { [ $# -gt 0 ] && scancel "$@" 2>/dev/null; return 0; }   # one call for every id; idempotent

adapter_attach() { # ID -> a shell inside the running job (sites may forbid --overlap)
  srun --jobid="$1" --overlap -N1 -n1 --pty bash
}

adapter_interactive() { # PART QOS TIME NAME MEM -- CMD... : a short allocation with a terminal, for the student's own sign-in
  # HPCW_ALLOC_WAIT_S, when set, bounds the wait for a node (the panel's sitting must fail in words, not hang).
  # HPCW_ALLOC_PTY=0 (framework 11): no --pty, for a caller with no terminal of its own (Beethoven's plain
  # ssh exec): standard input is then a pipe all the way to the command, which reads the code from it, and
  # no remote terminal can echo it back (the sitting's own `script` gives Claude Code its terminal)
  local part="$1" qos="$2" time="$3" name="$4" mem="$5" pty=--pty; shift 5; [ "${1:-}" = "--" ] && shift
  [ "${HPCW_ALLOC_PTY:-1}" = 0 ] && pty=""
  srun -p "$part" ${qos:+-q "$qos"} -t "$time" -N1 -n1 --mem="$mem" -J "$name" ${HPCW_ALLOC_WAIT_S:+-I"$HPCW_ALLOC_WAIT_S"} $pty "$@"
}

adapter_run_short() { # PART QOS TIME NAME MEM -- CMD... : the same without a terminal (status checks)
  local part="$1" qos="$2" time="$3" name="$4" mem="$5"; shift 5; [ "${1:-}" = "--" ] && shift
  srun -p "$part" ${qos:+-q "$qos"} -t "$time" -N1 -n1 --mem="$mem" -J "$name" --quiet "$@"
}

adapter_partitions() { timeout 10 sinfo -h -o '%P|%l|%a' 2>/dev/null | sort -u; }   # NAME(*=default)|TIMELIMIT|AVAIL (9 ms of CPU on warrior)
adapter_my_qos() { command -v sacctmgr >/dev/null 2>&1 && timeout 10 sacctmgr -n -P show assoc where user="$USER" format=qos 2>/dev/null | tr ',' '\n' | sort -u | tr '\n' ' '; }
