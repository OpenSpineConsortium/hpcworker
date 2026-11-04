# shellcheck shell=bash
# ---- framework 25: the one way a project's batch job reaches the scheduler (27: placement, env) ------
# Sourced by bin/hpcworker after lib/adapters/common.sh. Bash 4.2 (EL7), coreutils, grep, sed and awk;
# nothing here runs python3 or a container on the login node, and each verb is one scheduler call.
#
#   hpcworker job submit --project P --name N --class cpu|batch|gpu [--partition P[,P]...] [--time T] [--cpus C]
#                        [--mem M] [--gpus G] [--gpu-type T] [--requeue|--no-requeue] [--after ID[:ok|any]]...
#                        [--placement auto|report [--gpu-mem GB] [--gpu-arch LIST]]
#                        [--array SPEC] [--dir D] [--check] -- SCRIPT [ARG...]
#                     SCRIPT queued with the partition, QoS, account and GPU request the deployment's
#                     profile gives the class (--partition picks one or more of the class's own, the job
#                     starting on whichever of them frees first; the gpu class may instead name the batch
#                     partition alone, framework 29), its output
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
# Auto placement (30): --placement auto names what a job needs, not where it runs: its cores, memory and
# time, and for the gpu class the least memory a card must hold (--gpu-mem, in GB) and the architectures
# its code runs on (--gpu-arch, a list such as ampere,ada,hopper, or ampere+ for Ampere and newer; ampere,
# ada,hopper unless given, since the grid's JAX build fails on Volta and has not been shown to run on
# Blackwell, while its torch build carries sm_120). The candidates are the site's <site>.placement beside
# its profile: each partition with the one QoS it takes, and for the gpu class each card the partition
# holds (sinfo's GRES column) that fits the job. Every candidate is asked with sbatch --test-only, the
# job's own resources and wall time on its command line, and the job goes to the earliest start Slurm
# estimates; a start within HPCW_PLACEMENT_TIE seconds (300) of the earliest is a tie, which goes to a
# QoS that is never preempted over requeue, then to the smaller card, then to the file's order. A job
# placed on requeue is requeued when preempted and its log appended to; it resumes from its last
# checkpoint, so a preemption costs it the time since that checkpoint. A caller's --no-requeue leaves the
# preemptable candidates out. --placement report prints the race and submits nothing. The table of
# estimates and the choice open the job's log and are printed as HPCW-JOB placement lines. The wall
# time is the job's own (--time, else its script's, else four hours), so backfill can start it early.
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
# The batch partition for GPUs (29): a site's GPU partitions can be held for weeks by long jobs while
# its batch partition, where that spans every node, has cards idle and takes only its own QoS (the
# GPU QoS is an invalid QoS there); SchwingNet's films ran on such cards by plain sbatch, outside the
# ledger, on 2026-10-31. So the gpu class may name the batch partition with --partition: the job takes
# the batch QoS, is requeued when preempted as any job there is, and may ask for a card by its type
# with --gpu-type (Slurm's GRES type, as sinfo's GRES column gives it), since such a partition can
# also hold MIG slices and older cards a bare gpu:1 may land on. A site whose batch partition holds
# no GPU refuses the job in the scheduler's own words, which --check shows before anything is queued.
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
  die "usage: hpcworker job submit --project P --name N --class cpu|batch|gpu [--partition P[,P]... --time T --cpus C --mem M --gpus G --gpu-type T --requeue|--no-requeue --after ID[:ok|any] --array SPEC --dir D --check --placement auto|report --gpu-mem GB --gpu-arch LIST] -- SCRIPT [ARG...]
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

job_class_options() { # CLASS GPUS [PARTITION] [REQUEUE yes|no|""] [GPU_TYPE] -> one sbatch option per line; exit 1 with why on stderr
  local class="$1" gpus="$2" want="${3:-}" requeue="${4:-}" type="${5:-}" part="" qos="" g on_batch=0
  case "$class" in
    cpu) part="$P_partition_cpu"; qos="$P_qos_cpu";;
    batch) part="${P_partition_cpu_batch:-$P_partition_cpu}"; on_batch=1
           if [ -n "$P_partition_cpu_batch" ]; then qos="$P_qos_batch"; else qos="$P_qos_cpu"; fi;;
    gpu) for g in $P_partitions_gpu; do part="${part:+$part,}$g"; done
         [ -n "$part" ] || { echo "this site's profile names no GPU partition (partitions_gpu)" >&2; return 1; }
         qos="${P_qos_gpu:-}";;
    *) echo "the class is cpu, batch or gpu" >&2; return 1;;
  esac
  [ -z "$type" ] || [ "$class" = gpu ] || { echo "--gpu-type is for the gpu class" >&2; return 1; }
  # --partition narrows the class to one or more of its own partitions, never to another class's; given
  # several, Slurm starts the job on whichever of them frees first (29), as it does the class's whole list.
  # The gpu class has one way out: the batch partition, named alone, with the batch QoS (the header says
  # why); alone, since one job carries one QoS and the batch partition takes no other.
  if [ -n "$want" ]; then
    if [ "$class" = gpu ] && [ -n "${P_partition_cpu_batch:-}" ] && [ "$want" = "$P_partition_cpu_batch" ]; then
      part="$want"; qos="$P_qos_batch"; on_batch=1
    else
      local also=""; [ "$class" = gpu ] && [ -n "${P_partition_cpu_batch:-}" ] && also=", or the batch partition $P_partition_cpu_batch alone"
      for g in ${want//,/ }; do
        case ",$part," in *",$g,"*) ;; *) echo "--partition $g is not one of the $class class's ($part)$also" >&2; return 1;; esac
      done
      part="$want"
    fi
  fi
  printf '%s\n' "--partition=$part"
  [ -n "$qos" ] && printf '%s\n' "--qos=$qos"
  [ -n "${P_account:-}" ] && printf '%s\n' "--account=$P_account"
  [ "$class" = gpu ] && printf '%s\n' "--gres=gpu:${type:+$type:}$gpus"
  # Beethoven for VS Code's worker rule, read as the profile's job header reads it (profile.py's REQUEUE):
  # the batch QoS named requeue may stop a job and start it again, so such a job says it may be requeued
  # and its log is appended to rather than started over; every other job says it may not be
  # --requeue or --no-requeue says so for this job alone, whatever the class's QoS
  if [ "$requeue" = yes ] || { [ -z "$requeue" ] && [ $on_batch = 1 ] && [ -n "$qos" ] && [ "$qos" = "$P_qos_batch" ] && [ "$P_qos_batch" = requeue ]; }; then
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

# ---- auto placement (30) ----------------------------------------------------------------------------
HPCW_ARCHS="kepler maxwell pascal volta turing ampere ada hopper blackwell"
job_arch_set() { # LIST -> the architectures it names (X+ is X and every newer one), spaced; exit 1 on an unknown one
  local w a on out=""
  for w in ${1//,/ }; do
    case "$w" in
      *+) on=0; for a in $HPCW_ARCHS; do [ "$a" = "${w%+}" ] && on=1; [ $on = 1 ] && out="$out $a"; done; [ $on = 1 ] || return 1;;
      *) case " $HPCW_ARCHS " in *" $w "*) out="$out $w";; *) return 1;; esac;;
    esac
  done
  [ -n "$out" ] || return 1
  printf '%s' "${out# }"
}
job_place_file() { printf '%s/%s.placement' "$PROFILES" "${P_site:-}"; }
job_card() { # TYPE PARTITION -> "MEMORY_GB ARCH" from the placement file, the partition's own line first; 1 when unknown
  local f; f=$(job_place_file)
  awk -v t="$1" -v p="$2" '$1 == "card" && $2 == t && $5 == p { print $3, $4; found = 1; exit }
    $1 == "card" && $2 == t && $5 == "" && !any { any = $3 " " $4 }
    END { if (!found && any != "") print any; exit (found || any != "") ? 0 : 1 }' "$f"
}
job_partition_types() { # PARTITION -> each GPU type its nodes hold, one a line (sinfo's partition and GRES columns)
  sinfo -h -o '%P|%G' 2>/dev/null | awk -F'|' -v p="$1" '{ q = $1; sub(/[*]$/, "", q); if (q == p) print $2 }' \
    | tr ',' '\n' | sed -n 's/^gpu:\([A-Za-z0-9_.-]*\):[0-9].*/\1/p' | sort -u
}
job_candidates() { # CLASS GPU_MEM ARCHS NO_PREEMPT -> "PARTITION QOS PREEMPTABLE TYPE MEMORY ARCH" lines, TYPE - for a CPU job
  local class="$1" need="$2" archs="$3" nopre="$4" f kind part qos pre t card mem arch
  f=$(job_place_file)
  [ -r "$f" ] || return 1
  [ "$class" = gpu ] && kind=gpu || kind=cpu
  while read -r tag k part qos pre; do
    [ "$tag" = candidate ] && [ "$k" = "$kind" ] || continue
    [ "$nopre" = 1 ] && [ "$pre" = yes ] && continue
    if [ "$kind" = cpu ]; then printf '%s %s %s - - -\n' "$part" "$qos" "$pre"; continue; fi
    for t in $(job_partition_types "$part"); do
      card=$(job_card "$t" "$part") || continue
      mem=${card% *} arch=${card#* }
      [ "$mem" -ge "$need" ] || continue
      case " $archs " in *" $arch "*) ;; *) continue;; esac
      printf '%s %s %s %s %s %s\n' "$part" "$qos" "$pre" "$t" "$mem" "$arch"
    done
  done < <(grep -E '^candidate ' "$f")
}
job_estimate() { # START_TEXT -> epoch seconds of "to start at YYYY-MM-DDTHH:MM:SS", or nothing
  local at; at=$(printf '%s\n' "$1" | sed -n 's/.*to start at \([0-9T:-]*\).*/\1/p' | head -1)
  [ -n "$at" ] && date -d "${at/T/ }" +%s 2>/dev/null
}
PLACE_TABLE="" PLACE_CHOICE=""
job_race() { # GPUS REQUEUE SCRIPT ARGS... -> PLACE_CHOICE "PARTITION QOS PREEMPTABLE TYPE" and PLACE_TABLE, or 1 when no candidate answered
  local gpus="$1" requeue="$2" script="$3"; shift 3
  local line part qos pre t mem arch opts out at best="" best_at="" best_pre="" best_mem="" tie=${HPCW_PLACEMENT_TIE:-300} now
  now=$(date +%s); PLACE_TABLE=""
  while read -r part qos pre t mem arch; do
    [ -n "$part" ] || continue
    opts=(--partition="$part" --qos="$qos")
    [ -n "${P_account:-}" ] && opts+=(--account="$P_account")
    [ "$t" != - ] && opts+=(--gres="gpu:$t:$gpus")
    out=$(job_caller_env; sbatch --test-only "${opts[@]}" "$@" "$script" 2>&1 | job_clean | tr '\n' ' ')
    at=$(job_estimate "$out")
    if [ -z "$at" ]; then
      PLACE_TABLE="$PLACE_TABLE$part/$qos ${t/#-/cpu} refused: $(printf '%s' "$out" | sed 's/^sbatch: error: //' | cut -c1-120)"$'\n'; continue
    fi
    [ "$at" -lt "$now" ] && at=$now
    PLACE_TABLE="$PLACE_TABLE$part/$qos ${t/#-/cpu}$([ "$t" != - ] && echo " ${mem}GB $arch") start $(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ) in $(( (at - now) / 60 )) min$([ "$pre" = yes ] && echo ", preemptable")"$'\n'
    if [ -z "$best" ]; then best="$part $qos $pre $t" best_at=$at best_pre=$pre best_mem=$mem; continue; fi
    # earlier by more than the tie wins; within the tie, never preempted wins, then the smaller card
    if [ "$at" -lt $((best_at - tie)) ] \
      || { [ "$at" -le $((best_at + tie)) ] && [ "$best_pre" = yes ] && [ "$pre" = no ]; } \
      || { [ "$at" -le $((best_at + tie)) ] && [ "$best_pre" = "$pre" ] && [ "$mem" != - ] && [ "$best_mem" != - ] && [ "$mem" -lt "$best_mem" ] && [ "$at" -le $((best_at + tie)) ]; }; then
      best="$part $qos $pre $t" best_at=$at best_pre=$pre best_mem=$mem
    fi
  done
  [ -n "$best" ] || return 1
  PLACE_CHOICE="$best"
}

job_submit() {
  local project="" name="" class="" time="" cpus="" mem="" gpus=1 dir="$PWD" check=0 afters=() array="" want="" requeue="" type=""
  local placement="" gpumem=0 gpuarch=""
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --name) name="${2:-}"; shift 2 || job_usage;;
    --class) class="${2:-}"; shift 2 || job_usage;;
    --time) time="${2:-}"; shift 2 || job_usage;;
    --cpus) cpus="${2:-}"; shift 2 || job_usage;;
    --mem) mem="${2:-}"; shift 2 || job_usage;;
    --gpus) gpus="${2:-}"; shift 2 || job_usage;;
    --gpu-type) type="${2:-}"; shift 2 || job_usage;;
    --partition) want="${2:-}"; shift 2 || job_usage;;
    --requeue) requeue=yes; shift;;
    --no-requeue) requeue=no; shift;;
    --after) afters+=("${2:-}"); shift 2 || job_usage;;
    --array) array="${2:-}"; shift 2 || job_usage;;
    --dir) dir="${2:-}"; shift 2 || job_usage;;
    --check) check=1; shift;;
    --placement) placement="${2:-}"; shift 2 || job_usage;;
    --gpu-mem) gpumem="${2:-}"; shift 2 || job_usage;;
    --gpu-arch) gpuarch="${2:-}"; shift 2 || job_usage;;
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
  [ -z "$type" ] || [[ "$type" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "--gpu-type is one GPU type's name, as sinfo's GRES column gives it"
  [ -z "$array" ] || [[ "$array" =~ $HPCW_JOB_ARRAY_RE ]] || die "--array is task numbers and ranges (0-63, 1,3,5-9, 0-99:2) with an optional %N limit"
  case "$dir" in /*) [ -d "$dir" ] || die "--dir $dir is not a folder";; *) die "--dir must be an absolute path";; esac
  case "$placement" in ""|auto|report) ;; *) die "--placement is auto or report";; esac
  [[ "$gpumem" =~ ^[0-9]{1,4}$ ]] || die "--gpu-mem is the least memory a card must hold, in whole GB"
  if [ -n "$placement" ]; then
    [ -z "$want" ] && [ -z "$type" ] || die "--placement chooses the partition and the card; leave out --partition and --gpu-type, and name the need with --gpu-mem and --gpu-arch"
    [ -z "$array" ] || die "--placement places one job; an array keeps its --partition"
    gpuarch=$(job_arch_set "${gpuarch:-ampere,ada,hopper}") || die "--gpu-arch is a list of $HPCW_ARCHS, or one of them with + for it and every newer one"
  else
    [ "$gpumem" = 0 ] && [ -z "$gpuarch" ] || die "--gpu-mem and --gpu-arch are --placement's"
  fi
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
  if [ -n "$placement" ]; then
    case "$class" in cpu|batch|gpu) ;; *) die "the class is cpu, batch or gpu";; esac
    [ -r "$(job_place_file)" ] || die "this site has no placement file ($(job_place_file)); name the partition instead"
    local cands race_args=() nopre=0
    [ "$requeue" = no ] && nopre=1
    cands=$(job_candidates "$class" "$gpumem" "$gpuarch" "$nopre")
    [ -n "$cands" ] || die "no partition of this site holds a card of ${gpumem} GB or more of ${gpuarch// /, }$([ $nopre = 1 ] && echo " that is never preempted (--no-requeue)")"
    # the job's own resources and wall time, as each candidate is asked with them
    race_args=("--job-name=$project-$name" -D "$dir")
    [ -n "$time" ] && race_args+=("--time=$time")
    [ -n "$cpus" ] && race_args+=("--cpus-per-task=$cpus")
    [ -n "$mem" ] && race_args+=("--mem=$mem")
    job_race "$gpus" "$requeue" "$script" "${race_args[@]}" <<< "$cands" \
      || die "no candidate placement answered sbatch --test-only: $(printf '%s' "$PLACE_TABLE" | tail -n 3 | tr '\n' ' ')"
    local cp cq cpre ct how; read -r cp cq cpre ct <<< "$PLACE_CHOICE"
    how="never preempted"; [ "$cpre" = yes ] && how="preemptable, requeued"
    while IFS= read -r o; do [ -n "$o" ] && echo "HPCW-JOB placement $name $o"; done <<< "$PLACE_TABLE"
    echo "HPCW-JOB placement $name chose $cp/$cq$([ "$ct" != - ] && echo " $ct") ($how)"
    [ "$placement" = report ] && return 0
    opts="--partition=$cp"$'\n'"--qos=$cq"
    [ -n "${P_account:-}" ] && opts="$opts"$'\n'"--account=$P_account"
    [ "$ct" != - ] && opts="$opts"$'\n'"--gres=gpu:$ct:$gpus"
    # a job placed where it may be preempted is requeued and resumes; every placed job's log is appended to,
    # so the table above, written first, stays at its head
    if [ "$cpre" = yes ] && [ "$requeue" != no ]; then opts="$opts"$'\n'"--requeue"; else opts="$opts"$'\n'"--no-requeue"; fi
    opts="$opts"$'\n'"--open-mode=append"
  else
  opts=$(job_class_options "$class" "$gpus" "$want" "$requeue" "$type" 2>&1) || die "$opts"
  fi
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
  if [ -n "$placement" ]; then
    { printf '== hpcworker placement for %s, %s UTC: the estimates sbatch --test-only gave, then the choice\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%S)"
      printf '%s' "$PLACE_TABLE" | sed 's/^/   /'
      printf '   chose %s\n' "$PLACE_CHOICE"; } >> "$log" 2>/dev/null
  fi
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
