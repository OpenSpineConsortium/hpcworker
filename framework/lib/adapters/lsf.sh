#!/bin/bash
# hpcworker IBM Spectrum LSF adapter. WRITTEN FROM THE DOCUMENTED COMMANDS AND UNIT-TESTED
# AGAINST FIXTURE OUTPUTS ONLY: no LSF cluster was available to this build. Commands come from
# the LSF 10.1 bsub/bjobs/bkill pages: bsub reads the script on stdin so that #BSUB lines count,
# prints "Job <N> is submitted to queue <q>.", and `bjobs -o` gives delimited text (its -json
# form works only with -o and is not needed).
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

adapter_name() { echo lsf; }
adapter_job_id_var() { echo LSB_JOBID; }

lsf_parse_submit() { # stdin: bsub output -> id
  local id; id=$(grep -o 'Job <[0-9]*>' | head -1 | tr -dc '0-9')
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

lsf_parse_bjobs() { # stdin: bjobs -noheader -o 'jobid stat exec_host' output -> STATE|NODE|RAW
  local line raw node; line=$(grep -v -E '^$|not found' | head -1 | tr -d '\r')
  [ -n "$line" ] || { echo "UNKNOWN||no record"; return 1; }
  set -- $line
  raw="${2:-}"; node="${3:-}"; node="${node#*\*}"; node="${node%%:*}"; [ "$node" = "-" ] && node=""
  printf '%s|%s|%s\n' "$(hpcw_normalise_state lsf "$raw")" "$node" "$raw"
}

adapter_submit() { # SCRIPT [bsub options...] -> id
  local script="$1"; shift
  local out; out=$(bsub "$@" < "$script" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  printf '%s\n' "$out" | lsf_parse_submit || { printf '%s\n' "$out" >&2; return 1; }
}

adapter_status() { # ID -> STATE|NODE|RAW ; running jobs first, then the recent history (-a)
  local id="$1" out
  out=$(bjobs -noheader -o 'jobid stat exec_host' "$id" 2>/dev/null) && [ -n "$out" ] && ! printf '%s' "$out" | grep -q 'not found' && { printf '%s\n' "$out" | lsf_parse_bjobs; return 0; }
  out=$(bjobs -a -noheader -o 'jobid stat exec_host' "$id" 2>/dev/null) || out=""
  printf '%s\n' "$out" | lsf_parse_bjobs
}

adapter_cancel() { bkill "$1" >/dev/null 2>&1 || true; }

adapter_attach() { # LSF has no attach primitive; ssh to the node is what sites permit for your own job
  local node; node=$(adapter_status "$1" | cut -d'|' -f2)
  [ -n "$node" ] || { echo "job $1 has no node yet" >&2; return 1; }
  ssh -t "$node"
}

adapter_interactive() { # PART QOS TIME NAME MEM -- CMD... (bsub -Is: interactive with a pseudo-terminal)
  local part="$1" qos="$2" time="$3" name="$4" mem="$5"; shift 5; [ "${1:-}" = "--" ] && shift
  bsub -Is -q "$part" -J "$name" -W "$time" -n 1 -M "${mem%[GgMm]*}000" "$@"
}

adapter_run_short() { # bsub -I: interactive without a terminal
  local part="$1" qos="$2" time="$3" name="$4" mem="$5"; shift 5; [ "${1:-}" = "--" ] && shift
  bsub -I -q "$part" -J "$name" -W "$time" -n 1 -M "${mem%[GgMm]*}000" "$@"
}

adapter_partitions() { bqueues -w 2>/dev/null | awk 'NR>1 {print $1"||"($2=="Open:Active"?"up":"down")}'; }
adapter_my_qos() { :; }
