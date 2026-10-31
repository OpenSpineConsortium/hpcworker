# shellcheck shell=bash
# ---- framework 25: the one way a project's batch job reaches the scheduler (27: placement, env) ------
# Sourced by bin/hpcworker after lib/adapters/common.sh. Bash 4.2 (EL7), coreutils, grep, sed and awk;
# nothing here runs python3 or a container on the login node, and each verb is one scheduler call.
#
#   hpcworker job submit --project P --name N --class cpu|batch|gpu [--partition P[,P]...] [--time T] [--cpus C]
#                        [--mem M] [--gpus G] [--requeue|--no-requeue] [--after ID[:ok|any]]... [--array SPEC]
#                        [--dir D] [--check] -- SCRIPT [ARG...]
#                     SCRIPT queued with the partition, QoS, account and GPU request the deployment's
#                     profile gives the class (--partition picks one or more of the class's own, the job
#                     starting on whichever of them frees first), its output
#                     (stdout and stderr together) under the project's log folder, and one line in the
#                     project's ledger; prints "HPCW-JOB submitted ..." or "HPCW-JOB refused ...".
#                     --time, --cpus and --mem are passed when given; left out, the script's own
#                     #SBATCH line stands, and only a script with none gets 04:00:00, 1 and 4G.
#                     --check asks the scheduler whether it would take the job (sbatch --test-only) and
#                     queues nothing. The job gets the caller's environment as the caller gave it,
#                     none of hpcworker's own names and none of the gate's; nothing of it is written
#                     to the ledger. --array queues a Slurm array, each task's log
#                     <name>_<id>_<task>.out; --after adds --kill-on-invalid-dep=yes.
#   hpcworker job status --project P [--last K] [--json]
#                     the project's last K jobs from its ledger (default 40, at most 9999) with their
#                     state, node and exit code: one squeue for those it still holds, one sacct for
#                     those it has ended, and sacct alone when squeue does not answer; an array's state
#                     is ARRAY and its tasks counted by state (ARRAY RUNNING:2,PENDING:61)
#   hpcworker job log --project P ID [--task N] [--lines N]
#                     the end of a ledger job's output, control characters taken out
#   hpcworker job cancel --project P ID...|--all
#                     the ledger's jobs cancelled in one scancel; an id the ledger does not name is named
#                     back and never cancelled, and the call then exits 1
#   hpcworker job version
#                     "HPCW-JOB version <framework> interface <n>", the copy that runs this command
#
# Placement (27): the partitions, QoS and account come from the deployment's profile as this copy
# publishes it (profiles/<site>.json), not from the account's profile.json, which install copied once
# and which a later framework never rewrites: an account installed before a site gained a GPU
# partition, or before its batch QoS was recorded, would otherwise queue on the old values without a
# word. A site this copy carries no profile for keeps the account's own values.
#
# Why: every project used to write its own #SBATCH partition and QoS lines, and one that guessed the
# GPU QoS wrong (SchwingNet's v1 on 2026-10-21, a GPU partition with no QoS) was refused, while
# Beethoven for VS Code had known the grid's GPU request since 2026-09-28 (its slurm.ts and
# DEPENDENCY_MAP grid.gpu-qos-gres). The site profile is now the one place that knows it, and a
# project's script carries no partition, QoS or output line of its own: sbatch takes its command
# line over a script's #SBATCH lines, so whatever an older script still carries, the profile wins.
#
# The ledger is <shared_state_dir>/jobs/<project>/jobs.tsv, one line per job: id, name, class,
# partition, qos, submitted (UTC), log, folder, script, array spec, the ids it waits on. Logs are <shared_state_dir>/jobs/<project>/logs/
# <name>_<id>.out. Only the account itself writes there (umask 077 folders).

HPCW_JOB_PROJECT_RE='^[a-z0-9][a-z0-9_-]{0,31}$'
HPCW_JOB_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'
HPCW_JOB_INTERFACE=2
HPCW_JOB_TIME_RE='^([0-9]{1,2}-)?[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$'
HPCW_JOB_MEM_RE='^[1-9][0-9]{0,5}[KMGT]?$'
HPCW_JOB_ARRAY_RE='^[0-9]{1,7}(-[0-9]{1,7}(:[0-9]{1,7})?)?(,[0-9]{1,7}(-[0-9]{1,7}(:[0-9]{1,7})?)?){0,31}(%[1-9][0-9]{0,4})?$'

job_usage() {
  die "usage: hpcworker job submit --project P --name N --class cpu|batch|gpu [--partition P[,P]... --time T --cpus C --mem M --gpus G --requeue|--no-requeue --after ID[:ok|any] --array SPEC --dir D --check] -- SCRIPT [ARG...]
       hpcworker job status --project P [--last K] [--json]
       hpcworker job log --project P ID [--task N] [--lines N]
       hpcworker job cancel --project P ID...|--all
       hpcworker job version"
}

job_dir() { printf '%s/jobs/%s' "$STATE_DIR" "$1"; }

job_site_placement() { # the deployment's own partitions, QoS and account over the account's copies of them
  [ -n "${P_site:-}" ] && [[ "$P_site" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || return 0
  local f="$PROFILES/$P_site.json" env line
  [ -s "$f" ] || return 0
  env=$(hpcw_prof_awk env "$f" 2>/dev/null) || return 0
  printf '%s\n' "$env" | grep -q "^P_site=['\"]\?$P_site['\"]\?\$" || return 0
  while IFS= read -r line; do
    case "$line" in
      P_partition_cpu=*|P_qos_cpu=*|P_partition_cpu_batch=*|P_qos_batch=*|P_partitions_gpu=*|P_qos_gpu=*|P_account=*) eval "$line";;
    esac
  done <<< "$env"
  return 0
}

job_class_options() { # CLASS GPUS [PARTITION] [REQUEUE yes|no|""] -> one sbatch option per line; exit 1 with why on stderr
  local class="$1" gpus="$2" want="${3:-}" requeue="${4:-}" part="" qos="" g all=""
  case "$class" in
    cpu) part="$P_partition_cpu"; qos="$P_qos_cpu";;
    batch) part="${P_partition_cpu_batch:-$P_partition_cpu}"
           if [ -n "$P_partition_cpu_batch" ]; then qos="$P_qos_batch"; else qos="$P_qos_cpu"; fi;;
    gpu) for g in $P_partitions_gpu; do part="${part:+$part,}$g"; done
         [ -n "$part" ] || { echo "this site's profile names no GPU partition (partitions_gpu)" >&2; return 1; }
         qos="${P_qos_gpu:-}";;
    *) echo "the class is cpu, batch or gpu" >&2; return 1;;
  esac
  # --partition narrows the class to one or more of its own partitions, never to another class's; given
  # several, Slurm starts the job on whichever of them frees first (29), as it does the class's whole list
  if [ -n "$want" ]; then
    for g in ${want//,/ }; do
      case ",$part," in *",$g,"*) ;; *) echo "--partition $g is not one of the $class class's ($part)" >&2; return 1;; esac
    done
    part="$want"
  fi
  printf '%s\n' "--partition=$part"
  [ -n "$qos" ] && printf '%s\n' "--qos=$qos"
  [ -n "${P_account:-}" ] && printf '%s\n' "--account=$P_account"
  [ "$class" = gpu ] && printf '%s\n' "--gres=gpu:$gpus"
  # Beethoven for VS Code's worker rule, read as the profile's job header reads it (profile.py's REQUEUE):
  # the batch QoS named requeue may stop a job and start it again, so such a job says it may be requeued
  # and its log is appended to rather than started over; every other job says it may not be
  # --requeue or --no-requeue says so for this job alone, whatever the class's QoS
  if [ "$requeue" = yes ] || { [ -z "$requeue" ] && [ "$class" = batch ] && [ -n "$qos" ] && [ "$qos" = "$P_qos_batch" ] && [ "$P_qos_batch" = requeue ]; }; then
    printf '%s\n' "--requeue" "--open-mode=append"
  else
    printf '%s\n' "--no-requeue"
  fi
  return 0
}

job_after_option() { # ID[:ok|any]... -> --dependency=afterany:1,afterok:2 ; exit 1 on a bad one
  local dep="" a id kind
  for a in "$@"; do
    id="${a%%:*}"; kind=any; [ "$id" != "$a" ] && kind="${a#*:}"
    [[ "$id" =~ ^[0-9]{1,12}$ ]] || return 1
    case "$kind" in ok|any) ;; *) return 1;; esac
    dep="${dep:+$dep,}after$kind:$id"
  done
  [ -n "$dep" ] && printf -- '--dependency=%s\n' "$dep"
  return 0
}

job_after_ids() { # ID[:ok|any]... -> the ids alone, comma-joined, for the ledger
  local a out=""; for a in "$@"; do out="${out:+$out,}${a%%:*}"; done; printf '%s' "$out"
}
job_script_sets() { # SCRIPT 'OPT|OPT' -> 0 when the script's #SBATCH header names one of them
  awk -v opts="$2" '
    BEGIN { n = split(opts, o, "|") }
    /^#SBATCH[ \t]/ { for (i = 1; i <= n; i++) { w = o[i]; if (index($2, w "=") == 1 || $2 == w) { found = 1; exit } } next }
    /^#!/ || /^[ \t]*$/ || /^#/ { next }
    { exit }
    END { exit found ? 0 : 1 }' "$1"
}

job_caller_env() { # in the subshell that runs sbatch: every exported name off, then the caller's own back
  local v exports
  # Rewritten before the unset, which takes PATH and so sed with it.
  exports=$(printf '%s\n' "$HPCW_CALLER_EXPORTS" | sed 's/^declare -[a-zA-Z]*x[a-zA-Z]* /export /')
  for v in $(compgen -e); do unset "$v" 2>/dev/null; done
  eval "$exports" 2>/dev/null
  unset HPCW_GATE HPCW_GATE_SLOT SSH_ORIGINAL_COMMAND 2>/dev/null
  return 0
}

job_clean() { tr -d '\000-\010\013\014\016-\037\177' | tr '\t' ' '; }

job_submit() {
  local project="" name="" class="" time="" cpus="" mem="" gpus=1 dir="$PWD" check=0 afters=() array="" want="" requeue=""
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --name) name="${2:-}"; shift 2 || job_usage;;
    --class) class="${2:-}"; shift 2 || job_usage;;
    --time) time="${2:-}"; shift 2 || job_usage;;
    --cpus) cpus="${2:-}"; shift 2 || job_usage;;
    --mem) mem="${2:-}"; shift 2 || job_usage;;
    --gpus) gpus="${2:-}"; shift 2 || job_usage;;
    --partition) want="${2:-}"; shift 2 || job_usage;;
    --requeue) requeue=yes; shift;;
    --no-requeue) requeue=no; shift;;
    --after) afters+=("${2:-}"); shift 2 || job_usage;;
    --array) array="${2:-}"; shift 2 || job_usage;;
    --dir) dir="${2:-}"; shift 2 || job_usage;;
    --check) check=1; shift;;
    --) shift; break;;
    *) job_usage;;
  esac; done
  local script="${1:-}"; [ $# -gt 0 ] && shift
  [[ "$project" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"
  [[ "$name" =~ $HPCW_JOB_NAME_RE ]] || die "--name is letters, digits, _, . and -, at most 64, starting with a letter or digit"
  [ -z "$time" ] || [[ "$time" =~ $HPCW_JOB_TIME_RE ]] || die "--time is H:MM:SS or D-H:MM:SS"
  [ -z "$cpus" ] || [[ "$cpus" =~ ^[1-9][0-9]{0,2}$ ]] || die "--cpus is a whole number from 1 to 999"
  [ -z "$mem" ] || [[ "$mem" =~ $HPCW_JOB_MEM_RE ]] || die "--mem is a number with K, M, G or T after it"
  [ -z "$want" ] || [[ "$want" =~ ^[A-Za-z0-9_.-]{1,64}(,[A-Za-z0-9_.-]{1,64}){0,7}$ ]] || die "--partition is a partition's name, or up to eight joined by commas"
  [[ "$gpus" =~ ^[1-8]$ ]] || die "--gpus is 1 to 8"
  [ -z "$array" ] || [[ "$array" =~ $HPCW_JOB_ARRAY_RE ]] || die "--array is task numbers and ranges (0-63, 1,3,5-9, 0-99:2) with an optional %N limit"
  case "$dir" in /*) [ -d "$dir" ] || die "--dir $dir is not a folder";; *) die "--dir must be an absolute path";; esac
  [ -n "$script" ] || job_usage
  case "$script" in /*) ;; *) script="$dir/$script";; esac
  [ -f "$script" ] && [ -r "$script" ] || die "no script at $script"
  load_profile
  [ "$P_scheduler" = slurm ] || die "hpcworker job speaks Slurm only for now; this site's scheduler is $P_scheduler"
  job_site_placement
  # a resource the caller left out stays as the script's own #SBATCH line says; a script with none gets the default
  [ -n "$time" ] || job_script_sets "$script" '--time|-t' || time="04:00:00"
  [ -n "$cpus" ] || job_script_sets "$script" '--cpus-per-task|-c' || cpus=1
  [ -n "$mem" ] || job_script_sets "$script" '--mem|--mem-per-cpu|--mem-per-gpu' || mem=4G
  local opts dep
  opts=$(job_class_options "$class" "$gpus" "$want" "$requeue" 2>&1) || die "$opts"
  dep=$(job_after_option ${afters[@]+"${afters[@]}"}) || die "--after is a job id, then :ok or :any (any when left out)"
  local jd; jd=$(job_dir "$project")
  ( umask 077; mkdir -p "$jd/logs" ) || die "could not make $jd/logs"
  local args=() o
  while IFS= read -r o; do [ -n "$o" ] && args+=("$o"); done <<< "$opts"
  # a dependency that can never be met (its job failed under afterok, or is gone) ends this job at
  # once instead of leaving it pending for ever behind a half-built chain
  [ -n "$dep" ] && args+=("$dep" "--kill-on-invalid-dep=yes")
  # TERM two minutes before the wall time, to the batch shell, so a script's trap can save its place
  # (the same signal Beethoven for VS Code's workers take)
  args+=("--signal=B:TERM@120")
  # an array's tasks each write their own log: %A the array's id, %a the task's number
  local pat="${name}_%j.out"; [ -n "$array" ] && { args+=("--array=$array"); pat="${name}_%A_%a.out"; }
  args+=("--job-name=$project-$name" -D "$dir" "--output=$jd/logs/$pat" "--error=$jd/logs/$pat")
  [ -n "$time" ] && args+=("--time=$time")
  [ -n "$cpus" ] && args+=("--cpus-per-task=$cpus")
  [ -n "$mem" ] && args+=("--mem=$mem")
  local part qos; part=$(printf '%s\n' "$opts" | sed -n 's/^--partition=//p'); qos=$(printf '%s\n' "$opts" | sed -n 's/^--qos=//p')
  if [ $check = 1 ]; then
    local t rc=0; t=$(job_caller_env; sbatch --test-only "${args[@]}" "$script" "$@" 2>&1) || rc=$?
    t=$(printf '%s' "$t" | job_clean | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ $rc = 0 ]; then echo "HPCW-JOB would-run $name $part/${qos:-none}: $t"; return 0; fi
    echo "HPCW-JOB refused $name $part/${qos:-none}: $t"; return 1
  fi
  local id out rc=0
  # sbatch itself rather than adapter_submit, which puts the script last and so takes no arguments for it
  # the job gets the caller's environment, not hpcworker's (sbatch exports the whole environment)
  out=$(job_caller_env; sbatch --parsable "${args[@]}" "$script" "$@" 2>&1) || rc=$?
  id=$(printf '%s\n' "$out" | slurm_parse_submit 2>/dev/null) || id=""
  if [ $rc != 0 ] || [ -z "$id" ]; then
    out=$(printf '%s' "$out" | job_clean | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    echo "HPCW-JOB refused $name $part/${qos:-none}: ${out:-the scheduler gave no reason}"; return 1
  fi
  local log="$jd/logs/${name}_$id.out"; [ -n "$array" ] && log="$jd/logs/${name}_${id}_%a.out"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$class" "$part" "${qos:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$log" "$dir" "$script" "$array" "$(job_after_ids ${afters[@]+"${afters[@]}"})" >> "$jd/jobs.tsv"
  echo "HPCW-JOB submitted $id $name $part/${qos:-none} log $log"
}

job_ledger() { # PROJECT LAST -> the last LAST ledger lines, newest last
  local f; f="$(job_dir "$1")/jobs.tsv"
  [ -s "$f" ] || return 0
  tail -n "$2" "$f"
}

job_status() {
  local project="" last=40 json=0
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --last) last="${2:-}"; shift 2 || job_usage;;
    --json) json=1; shift;;
    *) job_usage;;
  esac; done
  [[ "$project" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"
  [[ "$last" =~ ^[1-9][0-9]{0,3}$ ]] || die "--last is 1 to 9999"
  load_profile
  local ledger ids live ended="" ended_ids="" rc=0
  ledger=$(job_ledger "$project" "$last")
  if [ -z "$ledger" ]; then
    if [ $json = 1 ]; then printf '{"project":%s,"jobs":[]}\n' "$(json_str "$project")"; else echo "HPCW-JOB none for $project"; fi
    return 0
  fi
  ids=$(printf '%s\n' "$ledger" | cut -f1 | paste -sd, -)
  live=$(adapter_status_many "$ids") || rc=$?
  # squeue silent: sacct alone still knows each job's last state, so ask it about all of them
  if [ $rc = 2 ]; then live=""; ended_ids="$ids"
  else ended_ids=$(printf '%s\n' "$live" | awk -F'|' '$2 == "UNKNOWN" { print $1 }' | paste -sd, -); fi
  if [ -n "$ended_ids" ] && [ "${P_scheduler:-}" = slurm ]; then
    ended=$(LC_ALL=C timeout 20 sacct -n -P -X -j "$ended_ids" --format=JobID,State,ExitCode,NodeList 2>/dev/null | tr -d '\r') || ended=""
  fi
  printf '%s\n' "$ledger" | LIVE="$live" ENDED="$ended" JSON=$json PROJECT="$project" LC_ALL=C awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return "\"" s "\"" }
    BEGIN {
      n = split(ENVIRON["LIVE"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], f, "|"); if (f[2] != "" && f[2] != "UNKNOWN") { st[f[1]] = f[2]; nd[f[1]] = f[3] } }
      n = split(ENVIRON["ENDED"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], f, "|"); if (f[1] == "") continue; s = f[2]; sub(/ .*/, "", s)
        # an array task (123_4, or 123_[5-63%32] while it waits): counted under the array, by state
        if (f[1] ~ /^[0-9]+_/) { b = f[1]; sub(/_.*/, "", b); t = f[1]; sub(/^[0-9]+_/, "", t); w = 1
          if (t ~ /^\[/) { w = 0; gsub(/[\[\]]|%.*/, "", t); m = split(t, rr, ","); for (j = 1; j <= m; j++) { if (split(rr[j], ab, "-") == 2) w += ab[2] - ab[1] + 1; else w++ } }
          if (!((b, s) in cnt)) order[b] = order[b] " " s; cnt[b, s] += w; continue }
        if (!(f[1] in st)) { st[f[1]] = s; ex[f[1]] = f[3]; nd[f[1]] = f[4] } }
      if (ENVIRON["JSON"] == "1") printf "{\"project\":%s,\"jobs\":[", esc(ENVIRON["PROJECT"])
    }
    function tasks(b,   o, k, i, out, ws) { o = order[b]; k = split(o, ws, " "); out = ""; for (i = 1; i <= k; i++) if (ws[i] != "") out = out (out == "" ? "" : ",") ws[i] ":" cnt[b, ws[i]]; return out }
    NF >= 7 {
      id = $1; s = (id in st) ? st[id] : "ENDED"
      if ($10 != "") s = (id in order) ? "ARRAY " tasks(id) : (id in st ? st[id] : "ARRAY ENDED")
      if (ENVIRON["JSON"] == "1") {
        printf "%s{\"id\":%s,\"name\":%s,\"class\":%s,\"partition\":%s,\"qos\":%s,\"submitted\":%s,\"state\":%s,\"node\":%s,\"exit\":%s,\"log\":%s,\"array\":%s,\"after\":%s}",
          (k++ ? "," : ""), esc(id), esc($2), esc($3), esc($4), esc($5), esc($6), esc(s), esc(nd[id]), esc(ex[id]), esc($7), esc($10), esc($11)
      } else printf "HPCW-JOB %s %s %s%s%s log %s\n", id, $2, s, (nd[id] != "" && nd[id] != "None assigned" ? " on " nd[id] : ""), (ex[id] != "" ? " exit " ex[id] : ""), $7
    }
    END { if (ENVIRON["JSON"] == "1") print "]}" }'
}

job_known() { # PROJECT ID -> the ledger line of ID, nothing when the ledger does not name it
  local f; f="$(job_dir "$1")/jobs.tsv"
  [ -s "$f" ] && awk -F'\t' -v id="$2" '$1 == id { line = $0 } END { if (line != "") print line }' "$f"
}

job_log() {
  local project="" id="" lines=80 task=""
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --lines) lines="${2:-}"; shift 2 || job_usage;;
    --task) task="${2:-}"; shift 2 || job_usage;;
    -*) job_usage;;
    *) [ -z "$id" ] || job_usage; id="$1"; shift;;
  esac; done
  [[ "$project" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"
  [[ "$id" =~ ^[0-9]{1,12}$ ]] || die "the job id is a number"
  [[ "$lines" =~ ^[1-9][0-9]{0,3}$ ]] || die "--lines is 1 to 9999"
  load_profile
  local line log; line=$(job_known "$project" "$id")
  [ -n "$line" ] || die "job $id is not in $project's ledger"
  log=$(printf '%s\n' "$line" | cut -f7)
  case "$log" in *%a.out)
    [[ "$task" =~ ^[0-9]{1,7}$ ]] || die "job $id is an array: name its task with --task N"
    log="${log%\%a.out}$task.out";; esac
  [ -f "$log" ] || { echo "HPCW-JOB no output yet for $id ($log)"; return 0; }
  tail -n "$lines" "$log" | tr -d '\r' | tr -d '\000-\010\013\014\016-\037\177'
}

job_cancel() {
  local project="" all=0 ids=() id
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --all) all=1; shift;;
    -*) job_usage;;
    *) ids+=("$1"); shift;;
  esac; done
  [[ "$project" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"
  [ $all = 1 ] || [ ${#ids[@]} -gt 0 ] || job_usage
  load_profile
  local f; f="$(job_dir "$project")/jobs.tsv"
  if [ $all = 1 ]; then
    [ -s "$f" ] || { echo "HPCW-JOB none for $project"; return 0; }
    ids=($(cut -f1 "$f" | sort -u))
  else
    local known=() unknown=()
    for id in "${ids[@]}"; do
      [[ "$id" =~ ^[0-9]{1,12}$ ]] || die "a job id is a number"
      if [ -n "$(job_known "$project" "$id")" ]; then known+=("$id"); else unknown+=("$id"); fi
    done
    [ ${#unknown[@]} = 0 ] || echo "HPCW-JOB not-in-ledger ${unknown[*]}"
    [ ${#known[@]} -gt 0 ] || return 1
    adapter_cancel "${known[@]}"
    echo "HPCW-JOB cancelled ${known[*]}"
    [ ${#unknown[@]} = 0 ]; return
  fi
  adapter_cancel "${ids[@]}"
  echo "HPCW-JOB cancelled ${ids[*]}"
}

cmd_job() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    submit) job_submit "$@";;
    status) job_status "$@";;
    log) job_log "$@";;
    cancel) job_cancel "$@";;
    version) echo "HPCW-JOB version $VERSION interface $HPCW_JOB_INTERFACE";;
    *) job_usage;;
  esac
}
