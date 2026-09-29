#!/bin/bash
# hpcworker PBS Pro / OpenPBS adapter. WRITTEN FROM THE DOCUMENTED COMMANDS AND UNIT-TESTED
# AGAINST FIXTURE OUTPUTS ONLY: no PBS cluster was available to this build. Commands come from
# the OpenPBS qsub(1B) and qstat man pages (qsub prints the bare job id; `qstat -f -F json`
# returns a Jobs object; `-x` includes finished jobs; `-W depend=afterany:<id>` is the chain).
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

adapter_name() { echo pbs; }
adapter_job_id_var() { echo PBS_JOBID; }

pbs_parse_submit() { # stdin: qsub output ("12345.pbsserver") -> id
  local line; line=$(grep -E '^[0-9]+(\.|\[|$)' | head -1 | tr -d '\r')
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

pbs_parse_qstat_json() { # stdin: qstat -f -F json output -> STATE|NODE|RAW  (python3 parses the JSON)
  "${HPCW_PYTHON:-python3}" -c "$(cat <<'PYEOF'
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("UNKNOWN||unparseable qstat output"); sys.exit(1)
jobs = d.get("Jobs") or {}
if not jobs:
    print("UNKNOWN||no record"); sys.exit(1)
j = list(jobs.values())[0]
st = j.get("job_state", "")
eh = j.get("exec_host") or ""
node = eh.split("+")[0].split("/")[0] if eh else ""
ex = j.get("Exit_status")
pend = {"Q", "H", "W", "T", "S", "M"}
run = {"R", "E", "B", "X"}
if st == "F":
    norm = "DONE" if str(ex) == "0" else "FAILED"
elif st in pend:
    norm = "PENDING"
elif st in run:
    norm = "RUNNING"
else:
    norm = "UNKNOWN"
print("%s|%s|%s" % (norm, node, st))
PYEOF
)"
}

adapter_submit() { # SCRIPT [qsub options...] -> id
  local script="$1"; shift
  local out; out=$(qsub "$@" "$script" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  printf '%s\n' "$out" | pbs_parse_submit || { printf '%s\n' "$out" >&2; return 1; }
}

adapter_submit_after() { # SCRIPT PARENT_ID [qsub options...] -> id of the successor (documented form, not run on a real PBS site)
  local script="$1" parent="$2"; shift 2
  adapter_submit "$script" -W "depend=afterany:$parent" "$@"
}

adapter_status() { # ID -> STATE|NODE|RAW ; active jobs first, then the finished-job history (-x)
  local id="$1" out
  out=$(qstat -f -F json "$id" 2>/dev/null) && printf '%s\n' "$out" | pbs_parse_qstat_json 2>/dev/null && return 0
  out=$(qstat -x -f -F json "$id" 2>/dev/null) || out="{}"
  printf '%s\n' "$out" | pbs_parse_qstat_json
}

adapter_cancel() { [ $# -gt 0 ] && qdel "$@" 2>/dev/null; return 0; }

adapter_attach() { # PBS has no attach primitive; ssh to the node is what sites permit for your own job
  local node; node=$(adapter_status "$1" | cut -d'|' -f2)
  [ -n "$node" ] || { echo "job $1 has no node yet" >&2; return 1; }
  ssh -t "$node"
}

adapter_interactive() { # PART QOS TIME NAME MEM -- CMD... (qsub -I -- <command>: PBS Pro form)
  local part="$1" qos="$2" time="$3" name="$4" mem="$5"; shift 5; [ "${1:-}" = "--" ] && shift
  qsub -I -q "$part" -N "$name" -l "walltime=$time" -l "select=1:ncpus=1:mem=${mem,,}" -- "$@"
}

adapter_run_short() { # no non-interactive "run and wait" exists in PBS; use the interactive form
  adapter_interactive "$@"
}

adapter_partitions() { qstat -Q 2>/dev/null | awk 'NR>2 && $1!="" {print $1"||up"}'; }
adapter_my_qos() { :; }
