# shellcheck shell=bash
# ---- framework 24: the one way a project's batch job reaches the scheduler ---------------------------
# Sourced by bin/hpcworker after lib/adapters/common.sh. Bash 4.2 (EL7), coreutils, grep, sed and awk;
# nothing here runs python3 or a container on the login node, and each verb is one scheduler call.
#
#   hpcworker job submit --project P --name N --class cpu|batch|gpu [--time T] [--cpus C] [--mem M]
#                        [--gpus G] [--after ID[:ok|any]]... [--dir D] [--check] -- SCRIPT [ARG...]
#                     SCRIPT queued with the partition, QoS, account and GPU request the site profile
#                     gives the class, its output (stdout and stderr together) under the project's log
#                     folder, and one line in the project's ledger; prints "HPCW-JOB submitted ..."
#                     or "HPCW-JOB refused ...". --check asks the scheduler whether it would take the
#                     job (sbatch --test-only) and queues nothing.
#   hpcworker job status --project P [--last K] [--json]
#                     the project's last K jobs from its ledger (default 40) with their state, node and
#                     exit code: one squeue for those it still holds, one sacct for those it has ended
#   hpcworker job log --project P ID [--lines N]
#                     the end of a ledger job's output, control characters taken out
#   hpcworker job cancel --project P ID...|--all
#                     the ledger's jobs cancelled in one scancel; a job the ledger does not name never is
#
# Why: every project used to write its own #SBATCH partition and QoS lines, and one that guessed the
# GPU QoS wrong (SchwingNet's v1 on 2026-10-21, a GPU partition with no QoS) was refused, while
# Beethoven for VS Code had known the grid's GPU request since 2026-09-28 (its slurm.ts and
# DEPENDENCY_MAP grid.gpu-qos-gres). The site profile is now the one place that knows it, and a
# project's script carries no partition, QoS or output line of its own: sbatch takes its command
# line over a script's #SBATCH lines, so whatever an older script still carries, the profile wins.
#
# The ledger is <shared_state_dir>/jobs/<project>/jobs.tsv, one line per job: id, name, class,
# partition, qos, submitted (UTC), log, folder, script. Logs are <shared_state_dir>/jobs/<project>/logs/
# <name>_<id>.out. Only the account itself writes there (umask 077 folders).

HPCW_JOB_PROJECT_RE='^[a-z0-9][a-z0-9_-]{0,31}$'
HPCW_JOB_NAME_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,39}$'
HPCW_JOB_TIME_RE='^([0-9]{1,2}-)?[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$'
HPCW_JOB_MEM_RE='^[1-9][0-9]{0,5}[KMGT]?$'

job_usage() {
  die "usage: hpcworker job submit --project P --name N --class cpu|batch|gpu [--time T --cpus C --mem M --gpus G --after ID[:ok|any] --dir D --check] -- SCRIPT [ARG...]
       hpcworker job status --project P [--last K] [--json]
       hpcworker job log --project P ID [--lines N]
       hpcworker job cancel --project P ID...|--all"
}

job_dir() { printf '%s/jobs/%s' "$STATE_DIR" "$1"; }

job_class_options() { # CLASS GPUS -> one sbatch option per line, from the site profile; exit 1 with why on stderr
  local class="$1" gpus="$2" part="" qos="" g
  case "$class" in
    cpu) part="$P_partition_cpu"; qos="$P_qos_cpu";;
    batch) part="${P_partition_cpu_batch:-$P_partition_cpu}"
           if [ -n "$P_partition_cpu_batch" ]; then qos="$P_qos_batch"; else qos="$P_qos_cpu"; fi;;
    gpu) for g in $P_partitions_gpu; do part="${part:+$part,}$g"; done
         [ -n "$part" ] || { echo "this site's profile names no GPU partition (partitions_gpu)" >&2; return 1; }
         qos="${P_qos_gpu:-}";;
    *) echo "the class is cpu, batch or gpu" >&2; return 1;;
  esac
  printf '%s\n' "--partition=$part"
  [ -n "$qos" ] && printf '%s\n' "--qos=$qos"
  [ -n "${P_account:-}" ] && printf '%s\n' "--account=$P_account"
  [ "$class" = gpu ] && printf '%s\n' "--gres=gpu:$gpus"
  # Beethoven for VS Code's worker rule: a QoS named requeue may stop a job and start it again, so the
  # job says it may be requeued and its log is appended to rather than started over
  [ "$qos" = requeue ] && printf '%s\n' "--requeue" "--open-mode=append"
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

job_clean() { tr -d '\000-\010\013\014\016-\037\177' | tr '\t' ' '; }

job_submit() {
  local project="" name="" class="" time="04:00:00" cpus=1 mem=4G gpus=1 dir="$PWD" check=0 afters=()
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --name) name="${2:-}"; shift 2 || job_usage;;
    --class) class="${2:-}"; shift 2 || job_usage;;
    --time) time="${2:-}"; shift 2 || job_usage;;
    --cpus) cpus="${2:-}"; shift 2 || job_usage;;
    --mem) mem="${2:-}"; shift 2 || job_usage;;
    --gpus) gpus="${2:-}"; shift 2 || job_usage;;
    --after) afters+=("${2:-}"); shift 2 || job_usage;;
    --dir) dir="${2:-}"; shift 2 || job_usage;;
    --check) check=1; shift;;
    --) shift; break;;
    *) job_usage;;
  esac; done
  local script="${1:-}"; [ $# -gt 0 ] && shift
  [[ "$project" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"
  [[ "$name" =~ $HPCW_JOB_NAME_RE ]] || die "--name is letters, digits, _, . and -, at most 40, starting with a letter or digit"
  [[ "$time" =~ $HPCW_JOB_TIME_RE ]] || die "--time is H:MM:SS or D-H:MM:SS"
  [[ "$cpus" =~ ^[1-9][0-9]{0,2}$ ]] || die "--cpus is a whole number from 1 to 999"
  [[ "$mem" =~ $HPCW_JOB_MEM_RE ]] || die "--mem is a number with K, M, G or T after it"
  [[ "$gpus" =~ ^[1-8]$ ]] || die "--gpus is 1 to 8"
  case "$dir" in /*) [ -d "$dir" ] || die "--dir $dir is not a folder";; *) die "--dir must be an absolute path";; esac
  [ -n "$script" ] || job_usage
  case "$script" in /*) ;; *) script="$dir/$script";; esac
  [ -f "$script" ] && [ -r "$script" ] || die "no script at $script"
  load_profile
  [ "$P_scheduler" = slurm ] || die "hpcworker job speaks Slurm only for now; this site's scheduler is $P_scheduler"
  local opts dep
  opts=$(job_class_options "$class" "$gpus" 2>&1) || die "$opts"
  dep=$(job_after_option "${afters[@]}") || die "--after is a job id, then :ok or :any (any when left out)"
  local jd; jd=$(job_dir "$project")
  ( umask 077; mkdir -p "$jd/logs" ) || die "could not make $jd/logs"
  local args=() o
  while IFS= read -r o; do [ -n "$o" ] && args+=("$o"); done <<< "$opts"
  [ -n "$dep" ] && args+=("$dep")
  # TERM two minutes before the wall time, to the batch shell, so a script's trap can save its place
  # (the same signal Beethoven for VS Code's workers take)
  args+=("--signal=B:TERM@120")
  args+=("--job-name=$project-$name" "--time=$time" "--cpus-per-task=$cpus" "--mem=$mem" -D "$dir"
         "--output=$jd/logs/${name}_%j.out" "--error=$jd/logs/${name}_%j.out")
  local part qos; part=$(printf '%s\n' "$opts" | sed -n 's/^--partition=//p'); qos=$(printf '%s\n' "$opts" | sed -n 's/^--qos=//p')
  if [ $check = 1 ]; then
    local t rc=0; t=$(sbatch --test-only "${args[@]}" "$script" "$@" 2>&1) || rc=$?
    t=$(printf '%s' "$t" | job_clean | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ $rc = 0 ]; then echo "HPCW-JOB would-run $name $part/${qos:-none}: $t"; return 0; fi
    echo "HPCW-JOB refused $name $part/${qos:-none}: $t"; return 1
  fi
  local id out rc=0
  # sbatch itself rather than adapter_submit, which puts the script last and so takes no arguments for it
  out=$(sbatch --parsable "${args[@]}" "$script" "$@" 2>&1) || rc=$?
  id=$(printf '%s\n' "$out" | slurm_parse_submit 2>/dev/null) || id=""
  if [ $rc != 0 ] || [ -z "$id" ]; then
    out=$(printf '%s' "$out" | job_clean | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    echo "HPCW-JOB refused $name $part/${qos:-none}: ${out:-the scheduler gave no reason}"; return 1
  fi
  local log="$jd/logs/${name}_$id.out"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$class" "$part" "${qos:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$log" "$dir" "$script" >> "$jd/jobs.tsv"
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
  [[ "$last" =~ ^[1-9][0-9]{0,2}$ ]] || die "--last is 1 to 999"
  load_profile
  local ledger ids live ended="" ended_ids="" rc=0
  ledger=$(job_ledger "$project" "$last")
  if [ -z "$ledger" ]; then
    if [ $json = 1 ]; then printf '{"project":%s,"jobs":[]}\n' "$(json_str "$project")"; else echo "HPCW-JOB none for $project"; fi
    return 0
  fi
  ids=$(printf '%s\n' "$ledger" | cut -f1 | paste -sd, -)
  live=$(adapter_status_many "$ids") || rc=$?
  [ $rc = 2 ] && die "the scheduler did not answer (squeue); nothing is known about these jobs now, ask again"
  ended_ids=$(printf '%s\n' "$live" | awk -F'|' '$2 == "UNKNOWN" { print $1 }' | paste -sd, -)
  if [ -n "$ended_ids" ] && [ "${P_scheduler:-}" = slurm ]; then
    ended=$(LC_ALL=C timeout 20 sacct -n -P -X -j "$ended_ids" --format=JobID,State,ExitCode,NodeList 2>/dev/null | tr -d '\r') || ended=""
  fi
  printf '%s\n' "$ledger" | LIVE="$live" ENDED="$ended" JSON=$json PROJECT="$project" LC_ALL=C awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return "\"" s "\"" }
    BEGIN {
      n = split(ENVIRON["LIVE"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], f, "|"); if (f[2] != "" && f[2] != "UNKNOWN") { st[f[1]] = f[2]; nd[f[1]] = f[3] } }
      n = split(ENVIRON["ENDED"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], f, "|"); if (f[1] != "" && !(f[1] in st)) { s = f[2]; sub(/ .*/, "", s); st[f[1]] = s; ex[f[1]] = f[3]; nd[f[1]] = f[4] } }
      if (ENVIRON["JSON"] == "1") printf "{\"project\":%s,\"jobs\":[", esc(ENVIRON["PROJECT"])
    }
    NF >= 7 {
      id = $1; s = (id in st) ? st[id] : "ENDED"
      if (ENVIRON["JSON"] == "1") {
        printf "%s{\"id\":%s,\"name\":%s,\"class\":%s,\"partition\":%s,\"qos\":%s,\"submitted\":%s,\"state\":%s,\"node\":%s,\"exit\":%s,\"log\":%s}",
          (k++ ? "," : ""), esc(id), esc($2), esc($3), esc($4), esc($5), esc($6), esc(s), esc(nd[id]), esc(ex[id]), esc($7)
      } else printf "HPCW-JOB %s %s %s%s%s log %s\n", id, $2, s, (nd[id] != "" && nd[id] != "None assigned" ? " on " nd[id] : ""), (ex[id] != "" ? " exit " ex[id] : ""), $7
    }
    END { if (ENVIRON["JSON"] == "1") print "]}" }'
}

job_known() { # PROJECT ID -> the ledger line of ID, nothing when the ledger does not name it
  local f; f="$(job_dir "$1")/jobs.tsv"
  [ -s "$f" ] && awk -F'\t' -v id="$2" '$1 == id { line = $0 } END { if (line != "") print line }' "$f"
}

job_log() {
  local project="" id="" lines=80
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --lines) lines="${2:-}"; shift 2 || job_usage;;
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
    for id in "${ids[@]}"; do
      [[ "$id" =~ ^[0-9]{1,12}$ ]] || die "a job id is a number"
      [ -n "$(job_known "$project" "$id")" ] || die "job $id is not in $project's ledger; nothing was cancelled"
    done
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
    *) job_usage;;
  esac
}
