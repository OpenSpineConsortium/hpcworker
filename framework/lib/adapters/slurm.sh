#!/bin/bash
# hpcworker Slurm adapter. Sourced by bin/hpcworker and by the tests. This is the adapter that
# was run for real (Wayne State grid, Slurm, 2026-09-28); pbs.sh and lsf.sh are written from
# the documented commands and tested only against fixture outputs.
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

adapter_status() { # ID -> STATE|NODE|RAW ; one squeue, then one sacct; never call this in a loop
  local id="$1" out
  out=$(squeue -h -j "$id" -o '%T|%N' 2>/dev/null) && [ -n "$out" ] && { printf '%s\n' "$out" | slurm_parse_squeue; return 0; }
  out=$(sacct -n -P -X -j "$id" --format=State,NodeList 2>/dev/null) || out=""
  printf '%s\n' "$out" | slurm_parse_sacct
}

adapter_cancel() { scancel "$1" 2>/dev/null || true; }   # idempotent

adapter_attach() { # ID -> a shell inside the running job (sites may forbid --overlap)
  srun --jobid="$1" --overlap -N1 -n1 --pty bash
}

adapter_interactive() { # PART QOS TIME NAME MEM -- CMD... : a short allocation with a terminal, for the student's own sign-in
  local part="$1" qos="$2" time="$3" name="$4" mem="$5"; shift 5; [ "${1:-}" = "--" ] && shift
  srun -p "$part" ${qos:+-q "$qos"} -t "$time" -N1 -n1 --mem="$mem" -J "$name" --pty "$@"
}

adapter_run_short() { # PART QOS TIME NAME MEM -- CMD... : the same without a terminal (status checks)
  local part="$1" qos="$2" time="$3" name="$4" mem="$5"; shift 5; [ "${1:-}" = "--" ] && shift
  srun -p "$part" ${qos:+-q "$qos"} -t "$time" -N1 -n1 --mem="$mem" -J "$name" --quiet "$@"
}

adapter_partitions() { sinfo -h -o '%P|%l|%a' 2>/dev/null | sort -u; }   # NAME(*=default)|TIMELIMIT|AVAIL
adapter_my_qos() { command -v sacctmgr >/dev/null 2>&1 && sacctmgr -n -P show assoc where user="$USER" format=qos 2>/dev/null | tr ',' '\n' | sort -u | tr '\n' ' '; }
