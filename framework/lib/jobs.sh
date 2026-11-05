# shellcheck shell=bash
# ---- framework 25: the one way a project's batch job reaches the scheduler (27: placement, env) ------
# Sourced by bin/hpcworker after lib/adapters/common.sh. Bash 4.2 (EL7), coreutils, grep, sed and awk;
# nothing here runs python3 or a container on the login node, and each verb is one scheduler call.
#
#   hpcworker job submit --project P --name N --class cpu|batch|gpu [--partition P[,P]...] [--time T] [--cpus C]
#                        [--mem M] [--gpus G] [--gpu-type T] [--requeue|--no-requeue] [--after ID[:ok|any]]...
#                        [--placement auto|report [--gpu-mem GB] [--gpu-arch LIST] [--prefer P[,P]...]]
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
#   hpcworker job place --class cpu|batch|gpu|runner [--name N] [--time T] [--cpus C] [--mem M] [--gpus G]
#                        [--gpu-mem GB] [--gpu-arch LIST] [--prefer P[,P]...] [--requeue|--no-requeue]
#                     the placement --placement auto would make, submitted nowhere: the race's
#                     "HPCW-JOB placement" lines, then "HPCW-JOB options <sbatch options>" (31)
#   hpcworker job replace [--project P]... [--runners] [--dry-run] [--job ID]... [--gain S] [--age S]
#                     this account's pending jobs that hpcworker placed (every project's ledger unless
#                     --project names some; with --runners the autoscaler's runner jobs too) raced
#                     again, an array's waiting tasks as one (32), each moved with scontrol update when another
#                     placement starts it sooner by more than --gain seconds (300); "HPCW-JOB moved|would-move|kept|cancelled"
#                     lines, then "HPCW-JOB replace looked at N pending job(s), moved M" (31)
#   hpcworker job usage --project P [--last K]
#                     per job name of the ledger's last K ended jobs: memory and cores asked against
#                     the measured peak memory and mean cores used, and a fit of 1.5 times the peak (31)
#   hpcworker job probe [--nodes LIST] [--max N]
#                     from inside a Slurm job: a one-core, one-minute job on each GPU node of the site's gpu
#                     candidates (or those LIST names) that reads this account's home and state folder; a
#                     node that cannot is kept out of every placement for an hour (31)
#   hpcworker job version
#                     "HPCW-JOB version <framework> interface <n>", the copy that runs this command
#
# Placement over every fitting partition at once (31): framework 30 sent a job to the one partition and
# card type the race said would start it soonest, and the job then waited there however the grid changed.
# sbatch --test-only is a will-run test over the running jobs alone, each ending at its time limit: it
# ignores every pending job and every job that ends early, so with a low fairshare its estimates were
# hours off either way (2026-11-04: two GPU jobs waited seven hours on the H200 cards of the preemptable
# partition, estimated for 6 November, while A30 cards stood free). So a placement is now one QoS: every
# candidate partition of that QoS, asked alone (given several, --test-only answers for the first, not the
# earliest), and the job submitted to all of them at once with a generic gpu:N and --exclude of every GPU
# node there whose cards do not all fit, so Slurm starts it wherever a fitting card frees first. A caller's --requeue says the job resumes
# from its last checkpoint, and a tie then goes to the preemptable QoS, which reaches the most cards. A
# candidate line's sixth field caps how many of this account's jobs a QoS holds at once (the debug QoS,
# whose limits allow one 4-core job a user). Each placed job's need is kept beside the ledger
# (<project>/placed/<id>), and job replace races it again while it waits: a user may change a pending
# job's partitions, QoS, gres, excluded nodes and requeue flag with scontrol update, which keeps its id
# and every job waiting on it. A move is logged in the job's log and in <state>/jobs/replace.log.
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
  die "usage: hpcworker job submit --project P --name N --class cpu|batch|gpu [--partition P[,P]... --time T --cpus C --mem M --gpus G --gpu-type T --requeue|--no-requeue --after ID[:ok|any] --array SPEC --dir D --check --placement auto|report --gpu-mem GB --gpu-arch LIST --prefer P[,P]] -- SCRIPT [ARG...]
       hpcworker job status --project P [--last K] [--json]
       hpcworker job log --project P ID [--task N] [--lines N]
       hpcworker job cancel --project P ID...|--all
       hpcworker job place --class cpu|batch|gpu|runner [--name N --time T --cpus C --mem M --gpus G --gpu-mem GB --gpu-arch LIST --prefer P[,P] --requeue|--no-requeue]
       hpcworker job replace [--project P]... [--runners] [--dry-run] [--job ID]... [--gain SECONDS] [--age SECONDS]
       hpcworker job usage --project P [--last K]
       hpcworker job share --project P [--last K] [--kind REGEX]
       hpcworker job pack --items \"A B ...\" [--var NAME] [--mps auto|on|off] -- COMMAND [ARG...]
       hpcworker job probe [--nodes LIST] [--max N]
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
job_candidates() { # CLASS GPU_MEM ARCHS NO_PREEMPT -> "PARTITION QOS PREEMPTABLE TYPE MEMORY ARCH MAX" lines, TYPE - for a CPU job
  # MAX is the most of this account's jobs the QoS may hold at once (the file's sixth field), - for no such bound
  local class="$1" need="$2" archs="$3" nopre="$4" f kind part qos pre max t card mem arch
  f=$(job_place_file)
  [ -r "$f" ] || return 1
  case "$class" in gpu) kind=gpu;; runner) kind=runner;; *) kind=cpu;; esac
  while read -r tag k part qos pre max; do
    [ "$tag" = candidate ] && [ "$k" = "$kind" ] || continue
    [ "$nopre" = 1 ] && [ "$pre" = yes ] && continue
    [[ "${max:=-}" =~ ^([1-9][0-9]{0,3}|-)$ ]] || max=-
    if [ "$kind" != gpu ]; then printf '%s %s %s - - - %s\n' "$part" "$qos" "$pre" "$max"; continue; fi
    for t in $(job_partition_types "$part"); do
      card=$(job_card "$t" "$part") || continue
      mem=${card% *} arch=${card#* }
      [ "$mem" -ge "$need" ] || continue
      case " $archs " in *" $arch "*) ;; *) continue;; esac
      printf '%s %s %s %s %s %s %s\n' "$part" "$qos" "$pre" "$t" "$mem" "$arch" "$max"
    done
  done < <(grep -E '^candidate ' "$f")
}
job_gpu_nodes() { # PARTITION... -> "NODE PARTITION TYPE" a line for each GPU type a node of those partitions holds (? for an untyped card)
  sinfo -h -N -o '%N|%P|%G' 2>/dev/null | awk -F'|' -v ps=" $* " '
    { q = $2; sub(/[*]$/, "", q); if (index(ps, " " q " ") == 0) next
      # GRES pieces split on commas: gpu:TYPE:N(S:0,3) leaves a "3)" behind, which names nothing
      n = split($3, g, ",")
      for (i = 1; i <= n; i++) {
        if (g[i] ~ /^gpu:[A-Za-z0-9_.-]+:[0-9]/) { split(g[i], f, ":"); print $1, q, f[2] }
        else if (g[i] ~ /^gpu:[0-9]/) print $1, q, "?"
      } }' | sort -u
}
job_hostlist() { # NODE... -> one Slurm host list, compressed where scontrol can say it (arw[1-3],tta1)
  local plain short; plain=$(printf '%s,' "$@"); plain=${plain%,}
  [ -n "$plain" ] || return 0
  short=$(scontrol show hostlist "$plain" 2>/dev/null | head -1)
  if [[ "$short" =~ ^[A-Za-z0-9_.,\[\]-]+$ ]]; then printf '%s\n' "$short"; else printf '%s\n' "$plain"; fi
}
BAD_NODES="" BAD_NODES_READ=0
job_bad_nodes() { # the nodes that end jobs at once: one sacct a process, the nodes spaced
  # A node that takes jobs and fails each within a minute is a black hole for a placement that goes wherever
  # a card is free first (2026-11-04: an H200 node back from draining without the home file system failed
  # every job of three users in its first second, two of ours among them). A node where, in the last
  # HPCW_BAD_NODE_HOURS (3), at least 3 jobs of at least 2 users ended FAILED or NODE_FAIL within 60 seconds of
  # starting is left out of every placement; one user's own broken script, failing on every node it meets, marks
  # none. Where sacct gives no answer nothing is left out.
  if [ $BAD_NODES_READ = 0 ]; then
    BAD_NODES_READ=1
    local since; since=$(date -d "-${HPCW_BAD_NODE_HOURS:-3} hours" +%Y-%m-%dT%H:%M:%S 2>/dev/null) || return 0
    BAD_NODES=$(LC_ALL=C timeout 30 sacct -a -X -n -P -S "$since" -E now -s FAILED,NODE_FAIL -o NodeList,User,ElapsedRaw 2>/dev/null \
      | awk -F'|' '$1 ~ /^[A-Za-z0-9_.-]+$/ && $3 ~ /^[0-9]+$/ && $3 <= 60 { n[$1]++; if (!((($1) SUBSEP ($2)) in seen)) { seen[$1, $2] = 1; u[$1]++ } }
        END { for (k in n) if (n[k] >= 3 && u[k] >= 2) print k }' | sort | tr '\n' ' ')
  fi
  printf '%s' "$BAD_NODES"
}
# a Slurm host list as one word; ] comes first in the bracket since a backslash is no escape inside one, and an escaped ]
# there would close it and refuse every plain node name
HPCW_JOB_HOSTLIST_RE='^[][A-Za-z0-9_.,-]+$'
job_exclude_file() { printf '%s/placement.exclude' "$STATE_DIR"; }
job_listed_nodes() { # the nodes a person has listed to keep every job off, spaced: <state>/placement.exclude and HPCW_PLACEMENT_EXCLUDE
  # One node or Slurm host list a line (msa[2-3]), # starting a comment, or a comma list in the variable: a node
  # the site keeps in service that cannot run our jobs (2026-11-04: an H200 node, some hours without the home file system).
  local f w out=""; f=$(job_exclude_file)
  for w in $( { [ -r "$f" ] && sed 's/#.*//' "$f"; printf '%s\n' "${HPCW_PLACEMENT_EXCLUDE:-}" | tr ',' '\n'; } | tr -s ' \t' '\n' ); do
    [[ "$w" =~ $HPCW_JOB_HOSTLIST_RE ]] || continue
    case "$w" in *\[*) out="$out $(scontrol show hostnames "$w" 2>/dev/null | tr '\n' ' ')";; *) out="$out $w";; esac
  done
  printf '%s' "${out# }"
}
AVOID_NODES="" AVOID_READ=0
job_avoid_nodes() { # every node a job of ours is kept off: listed, ending jobs at once, or failing its probe, spaced, one read a process
  if [ $AVOID_READ = 0 ]; then
    AVOID_READ=1
    AVOID_NODES=$(printf '%s\n' $(job_listed_nodes) $(job_bad_nodes) $(job_probed_bad) | grep . | sort -u | tr '\n' ' ')
  fi
  printf '%s' "$AVOID_NODES"
}
job_probe_file() { printf '%s/placement.probe' "$STATE_DIR"; }
job_probed_bad() { # the nodes whose latest probe within HPCW_PROBE_FRESH seconds (3600) failed, spaced
  local f; f=$(job_probe_file)
  [ -r "$f" ] || return 0
  awk -v t="$(( $(date +%s) - ${HPCW_PROBE_FRESH:-3600} ))" '$2 ~ /^[0-9]+$/ && $3 != "unknown" { last[$1] = $2; said[$1] = $3 }
    END { for (n in last) if (last[n] >= t && said[n] == "fail") printf "%s ", n }' "$f"
}
job_groups() { # GPUS: job_candidates' lines on stdin -> "QOS PREEMPTABLE MAX PARTITIONS GRES EXCLUDE CARDS" a line, in the file's order
  # Framework 31: one QoS is one placement. Slurm gives a job one QoS, and a job naming several partitions
  # starts on whichever of them can run it first, so the candidates of each QoS become one submission over
  # every partition they fit on, with a generic gpu:N and every GPU node of those partitions excluded that
  # holds a card the job cannot use (a MIG slice, a card too small, an architecture its code does not run
  # on), since a generic request could otherwise land on one. A node with a fitting card beside an unfitting
  # one is left out for the same reason.
  local gpus="$1" part qos pre t mem arch max q order="" node np nt cards p excl
  declare -A parts pres maxes fits
  while read -r part qos pre t mem arch max; do
    [ -n "$part" ] || continue
    case " $order " in *" $qos "*) ;; *) order="$order $qos"; pres[$qos]=$pre; maxes[$qos]=$max;; esac
    case ",${parts[$qos]:-}," in *",$part,"*) ;; *) parts[$qos]="${parts[$qos]:+${parts[$qos]},}$part";; esac
    [ "$t" = - ] || fits[$qos/$part]="${fits[$qos/$part]:-} $t "
  done
  local bad; bad=" $(job_avoid_nodes) "
  for q in $order; do
    if [ -z "${fits[$q/${parts[$q]%%,*}]:-}" ]; then
      excl=""
      [ "$bad" = "  " ] || excl=$(sinfo -h -N -p "${parts[$q]}" -o '%N' 2>/dev/null | sort -u | while read -r node; do case "$bad" in *" $node "*) printf '%s ' "$node";; esac; done)
      p=""; [ -n "$excl" ] && p=$(job_hostlist $excl)
      printf '%s %s %s %s - %s -\n' "$q" "${pres[$q]}" "${maxes[$q]}" "${parts[$q]}" "${p:--}"; continue
    fi
    excl=" " cards=""
    while read -r node np nt; do
      [ -n "$node" ] || continue
      # a node listed to avoid, or one that ends every job at once, is left out whatever its cards (job_avoid_nodes)
      case "$bad" in *" $node "*) case "$excl" in *" $node "*) ;; *) excl="$excl$node ";; esac; continue;; esac
      case "${fits[$q/$np]:-}" in
        *" $nt "*) case ",$cards," in *",$nt,"*) ;; *) cards="${cards:+$cards,}$nt";; esac;;
        *) case "$excl" in *" $node "*) ;; *) excl="$excl$node ";; esac;;
      esac
    done < <(job_gpu_nodes ${parts[$q]//,/ })
    p=""; [ "$excl" != " " ] && p=$(job_hostlist $excl)
    cards=$(printf '%s\n' ${cards//,/ } | sort | paste -sd, -)
    printf '%s %s %s %s gpu:%s %s %s\n' "$q" "${pres[$q]}" "${maxes[$q]}" "${parts[$q]}" "$gpus" "${p:--}" "${cards:--}"
  done
}
job_estimate() { # START_TEXT -> epoch seconds of "to start at YYYY-MM-DDTHH:MM:SS", or nothing
  local at; at=$(printf '%s\n' "$1" | sed -n 's/.*to start at \([0-9T:-]*\).*/\1/p' | head -1)
  [ -n "$at" ] && date -d "${at/T/ }" +%s 2>/dev/null
}
OWN_JOBS="" OWN_JOBS_READ=0
job_own_jobs() { # this account's jobs, one squeue a process: ID|NAME|STATE|PARTITIONS|QOS|REASON|CPUS|MEM|TIME|TRES|EXCLUDED|SUBMITTED|DEPENDENCY
  if [ $OWN_JOBS_READ = 0 ]; then
    OWN_JOBS=$(squeue -h -u "${USER:-$(id -un)}" -o '%i|%j|%T|%P|%q|%r|%C|%m|%l|%b|%x|%V|%E' 2>/dev/null) || return 1
    OWN_JOBS_READ=1
  fi
  [ -n "$OWN_JOBS" ] && printf '%s\n' "$OWN_JOBS"
  return 0
}
# ---- the wait behind priority (32) ------------------------------------------------------------------
# sbatch --test-only answers over running jobs alone, so where pending jobs of others outrank ours it says a card frees
# soon while our jobs wait there for hours with the reason Priority. A site that gives this account the lowest fairshare
# shows it on every busy partition: on 5 November job replace moved a wave of an account's GPU jobs from cards that freed
# within the hour into the requeue QoS, where test-only said "now" and the jobs sat behind priority all morning. A job of
# ours no larger than the one being placed (its cores, memory and cards) and pending there for Priority longer than
# HPCW_WAIT_MIN seconds (900) is the evidence: no placement there is believed to start the job sooner than now plus the
# longest such wait, counted from the job's submission or its last move and held to HPCW_WAIT_CAP (86400). Each wait seen
# is written to <state>/placement.waits, so the evidence outlives the jobs that gave it, which may themselves be moved
# out, for HPCW_WAIT_FRESH seconds (3600), and a job is not moved back into the queue it was just moved out of.
WAIT_ROWS="" WAIT_READ=0
job_waits_file() { printf '%s/placement.waits' "$STATE_DIR"; }
job_mem_mb() { # 32G, 62.50G, 16000M, 4T or a bare count of MB -> whole MB, 0 when unreadable
  printf '%s\n' "$1" | awk '{ v = $0 + 0; u = toupper(substr($0, length($0), 1))
    if (u == "K") v /= 1024; else if (u == "G") v *= 1024; else if (u == "T") v *= 1048576; else if (u != "M" && $0 !~ /^[0-9.]+$/) v = 0
    printf "%d\n", v }'
}
job_waits() { # "EPOCH PARTITION QOS CPUS MEM_MB GPUS WAIT" lines: this account's jobs waiting for priority now, and the fresh ones recorded
  if [ $WAIT_READ = 0 ]; then
    WAIT_READ=1
    local now id st parts qos reason cpus mem tres sub base at last wait gpus p min=${HPCW_WAIT_MIN:-900} f live=""
    now=$(date +%s)
    while IFS='|' read -r id _ st parts qos reason cpus mem _ tres _ sub _; do
      [ "$st" = PENDING ] && [ "$reason" = Priority ] || continue
      at=$(date -d "${sub/T/ }" +%s 2>/dev/null) || continue
      base=${id%%_*}; last=$(tail -n 1 "$STATE_DIR/jobs/.moves/$base" 2>/dev/null)
      [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -gt "$at" ] && at=$last
      wait=$((now - at)); [ "$wait" -ge "$min" ] || continue
      [ "$wait" -le "${HPCW_WAIT_CAP:-86400}" ] || wait=${HPCW_WAIT_CAP:-86400}
      gpus=0; case "$tres" in *gpu:*) gpus=${tres##*:}; [[ "$gpus" =~ ^[0-9]+$ ]] || gpus=1;; esac
      for p in ${parts//,/ }; do live="$live$now $p $qos ${cpus:-1} $(job_mem_mb "$mem") $gpus $wait"$'\n'; done
    done < <(job_own_jobs)
    f=$(job_waits_file)
    if [ -n "$live" ]; then
      ( umask 077; mkdir -p "$(dirname "$f")" && printf '%s' "$live" >> "$f"
        if [ "$(wc -l < "$f")" -gt 4000 ]; then tail -n 2000 "$f" > "$f.new" && mv -f "$f.new" "$f"; fi ) 2>/dev/null
    fi
    WAIT_ROWS=$( { printf '%s' "$live"; awk -v t="$((now - ${HPCW_WAIT_FRESH:-3600}))" 'NF == 7 && $1 ~ /^[0-9]+$/ && $1 >= t' "$f" 2>/dev/null; } )
  fi
  [ -n "$WAIT_ROWS" ] && printf '%s\n' "$WAIT_ROWS"
  return 0
}
job_wait_floor() { # PARTITION QOS CPUS MEM GPUS -> seconds a job of that shape is believed to wait there at least, 0 for none
  local cpus=${3:-1} mem gpus=${5:-0}; mem=$(job_mem_mb "${4:-0}")
  [[ "$cpus" =~ ^[0-9]+$ ]] || cpus=1
  job_waits | awk -v p="$1" -v q="$2" -v c="$cpus" -v m="$mem" -v g="$gpus" '
    $2 == p && $3 == q && $4 + 0 <= c + 0 && $5 + 0 <= m + 0 && $6 + 0 <= g + 0 && $7 + 0 > w { w = $7 + 0 }
    END { print w + 0 }'
}
job_race_shape() { # sbatch options... -> "CPUS MEM" the race asks with (1 and 0 where not given)
  local a cpus=1 mem=0
  for a in "$@"; do case "$a" in --cpus-per-task=*) cpus=${a#*=};; --mem=*) mem=${a#*=};; esac; done
  printf '%s %s' "$cpus" "$mem"
}

ASK_SAID=""
job_ask() { # PARTITION QOS GRES EXCLUDE SCRIPT ARGS... -> epoch seconds of the start sbatch --test-only gives, else 1 with its words in ASK_SAID
  local part="$1" qos="$2" gres="$3" excl="$4" script="$5" opts out at; shift 5
  opts=(--partition="$part" --qos="$qos")
  [ -n "${P_account:-}" ] && opts+=(--account="$P_account")
  [ "$gres" != - ] && opts+=(--gres="$gres")
  [ "$excl" != - ] && opts+=(--exclude="$excl")
  # a caller that submits itself has no script to ask with: a one-word job asks for the same resources
  if [ -n "$script" ]; then out=$(job_caller_env; sbatch --test-only "${opts[@]}" "$@" "$script" 2>&1 | job_clean | tr '\n' ' ')
  else out=$(job_caller_env; sbatch --test-only "${opts[@]}" "$@" --wrap=true 2>&1 | job_clean | tr '\n' ' '); fi
  at=$(job_estimate "$out")
  if [ -n "$at" ]; then printf '%s' "$at"; return 0; fi
  ASK_SAID=$(printf '%s' "$out" | sed 's/^sbatch: error: //' | cut -c1-120); return 1
}
PLACE_TABLE="" PLACE_CHOICE="" PLACE_AT="" PLACE_WHY="" PLACE_PREFER=""
job_race() { # GPUS RESUMES SCRIPT ARGS...: the groups on stdin -> PLACE_CHOICE "PARTITIONS QOS PREEMPTABLE GRES EXCLUDE", PLACE_AT and PLACE_TABLE; 1 when none answered
  # Each partition is asked alone, since given several, sbatch --test-only answers for the first of them and
  # not the earliest (Slurm 23.02 at Wayne State, 2026-11-04). A group's estimate is its earliest partition's,
  # and its partitions are submitted earliest first, refused ones left out. The earliest group wins; one
  # within HPCW_PLACEMENT_TIE seconds of it is a tie, which goes, when RESUMES is yes (the caller's
  # --requeue: the job resumes from its last checkpoint, so a preemption costs it little), to the preemptable
  # QoS, which reaches more cards, and otherwise to the QoS never preempted; then to the file's order.
  # PLACE_PREFER names partitions the caller asked for (--prefer, a gate word's own --partition): the earliest
  # of them, alone, is taken unless another placement starts the job more than HPCW_PLACEMENT_PREFER seconds
  # (600) sooner, so a preference is honoured while it costs the job little, and never holds it long from a free card.
  local gpus="$1" resumes="$2" script="$3"; shift 3
  local q pre max parts gres excl cards part at tie=${HPCW_PLACEMENT_TIE:-300} now held got ok best="" best_at="" best_pre="" won
  local pgot pok pat pbest="" pbest_at="" window=${HPCW_PLACEMENT_PREFER:-600} shape floor said
  now=$(date +%s); PLACE_TABLE="" PLACE_AT=""
  shape=$(job_race_shape "$@")
  while read -r q pre max parts gres excl cards; do
    [ -n "$q" ] || continue
    if [ "$max" != - ]; then
      held=$(job_own_jobs | awk -F'|' -v q="$q" '$5 == q { n++ } END { print n + 0 }')
      if [ "$held" -ge "$max" ]; then PLACE_TABLE="$PLACE_TABLE$parts/$q held: $held of this account's jobs hold it, its most at once $max"$'\n'; continue; fi
    fi
    got=""
    for part in ${parts//,/ }; do
      if at=$(job_ask "$part" "$q" "$gres" "$excl" "$script" "$@"); then
        [ "$at" -lt "$now" ] && at=$now
        # (32) where a job of ours no larger has waited behind priority, test-only's answer is no sooner than that wait
        said=""; floor=$(job_wait_floor "$part" "$q" "${shape%% *}" "${shape#* }" "$([ "$gres" = - ] && echo 0 || echo "$gpus")")
        if [ "$floor" -gt 0 ] && [ "$at" -lt $((now + floor)) ]; then at=$((now + floor)); said=", behind priority: a job of this account's no larger has waited $((floor / 60)) min there"; fi
        got="$got$at $part"$'\n'
        PLACE_TABLE="$PLACE_TABLE$part/$q $([ "$gres" = - ] && echo cpu || echo "$gres of ${cards//,/ }") start $(date -u -d "@$at" +%Y-%m-%dT%H:%M:%SZ) in $(( (at - now) / 60 )) min$([ "$pre" = yes ] && echo ", preemptable")$said"$'\n'
      else
        PLACE_TABLE="$PLACE_TABLE$part/$q $([ "$gres" = - ] && echo cpu || echo "$gres") refused: $ASK_SAID"$'\n'
      fi
    done
    [ -n "$got" ] || continue
    ok=$(printf '%s' "$got" | sort -s -n -k1,1 | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $2 }')
    at=$(printf '%s' "$got" | sort -n | head -1 | cut -d' ' -f1)
    won=0
    if [ -z "$best" ] || [ "$at" -lt $((best_at - tie)) ]; then won=1
    elif [ "$at" -le $((best_at + tie)) ] && [ "$best_pre" != "$pre" ]; then
      if [ "$resumes" = yes ]; then [ "$pre" = yes ] && won=1; else [ "$pre" = no ] && won=1; fi
    fi
    [ $won = 1 ] && best="$ok $q $pre $gres $excl" best_at=$at best_pre=$pre
    if [ -n "${PLACE_PREFER:-}" ]; then
      pgot=$(printf '%s' "$got" | awk -v want=",$PLACE_PREFER," 'index(want, "," $2 ",") > 0')
      if [ -n "$pgot" ]; then
        pok=$(printf '%s\n' "$pgot" | sort -s -n -k1,1 | awk '{ printf "%s%s", (NR > 1 ? "," : ""), $2 }')
        pat=$(printf '%s\n' "$pgot" | sort -n | head -1 | cut -d' ' -f1)
        if [ -z "$pbest" ] || [ "$pat" -lt "$pbest_at" ]; then pbest="$pok $q $pre $gres $excl" pbest_at=$pat; fi
      fi
    fi
  done
  [ -n "$best" ] || return 1
  PLACE_CHOICE="$best" PLACE_AT="$best_at"
  if [ -n "$pbest" ] && [ "$pbest_at" -le $((best_at + window)) ]; then PLACE_CHOICE="$pbest" PLACE_AT="$pbest_at"; fi
  return 0
}
job_choice_text() { # -> "PARTITIONS/QOS [GRES] (how)" of PLACE_CHOICE, as the choice line says it
  local cp cq cpre cg cx; read -r cp cq cpre cg cx <<< "$PLACE_CHOICE"
  printf '%s/%s%s (%s)' "$cp" "$cq" "$([ "$cg" != - ] && echo " $cg")" "$([ "$cpre" = yes ] && echo "preemptable, requeued" || echo "never preempted")"
}
job_choice_options() { # REQUEUE(yes|no|"") -> PLACE_CHOICE as sbatch options, one a line
  local cp cq cpre cg cx; read -r cp cq cpre cg cx <<< "$PLACE_CHOICE"
  printf '%s\n' "--partition=$cp" "--qos=$cq"
  [ -n "${P_account:-}" ] && printf '%s\n' "--account=$P_account"
  [ "$cg" != - ] && printf '%s\n' "--gres=$cg"
  [ "$cx" != - ] && printf '%s\n' "--exclude=$cx"
  # a job placed where it may be preempted is requeued and resumes; every placed job's log is appended to,
  # so the table written first stays at its head
  if [ "$cpre" = yes ] && [ "$1" != no ]; then printf '%s\n' --requeue; else printf '%s\n' --no-requeue; fi
  printf '%s\n' --open-mode=append
}
job_need_place() { # CLASS GPUS GPU_MEM ARCHS REQUEUE SCRIPT ARGS...: the whole race for one need -> PLACE_*, or 1 with why in PLACE_WHY
  local class="$1" gpus="$2" need="$3" archs="$4" requeue="$5" script="$6" cands nopre=0; shift 6
  [ "$requeue" = no ] && nopre=1
  PLACE_WHY="" PLACE_TABLE="" PLACE_CHOICE=""
  job_avoid_nodes > /dev/null   # read once in this shell, so every race of one job replace shares one sacct
  cands=$(job_candidates "$class" "$need" "$archs" "$nopre")
  if [ -z "$cands" ]; then
    if [ "$class" = gpu ]; then PLACE_WHY="no partition of this site holds a card of ${need} GB or more of ${archs// /, }$([ $nopre = 1 ] && echo " that is never preempted (--no-requeue)")"
    else PLACE_WHY="this site's placement file names no $class candidate$([ $nopre = 1 ] && echo " that is never preempted (--no-requeue)")"; fi
    return 1
  fi
  job_race "$gpus" "$requeue" "$script" "$@" < <(printf '%s\n' "$cands" | job_groups "$gpus") && return 0
  PLACE_WHY="no candidate placement answered sbatch --test-only: $(printf '%s' "$PLACE_TABLE" | tail -n 3 | tr '\n' ' ')"
  return 1
}
job_need_write() { # PROJECT ID CLASS GPUS GPU_MEM ARCHS REQUEUE [PREFER]: what the job was placed for, for job replace
  local d; d="$(job_dir "$1")/placed"
  ( umask 077; mkdir -p "$d" && printf 'class=%s gpus=%s gpu_mem=%s gpu_arch=%s requeue=%s%s\n' "$3" "$4" "$5" "${6// /,}" "${7:--}" "${8:+ prefer=$8}" > "$d/$2" ) 2>/dev/null
  return 0
}

job_submit() {
  local project="" name="" class="" time="" cpus="" mem="" gpus=1 dir="$PWD" check=0 afters=() array="" want="" requeue="" type=""
  local placement="" gpumem=0 gpuarch="" prefer="" gpus_named=0
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --prefer) prefer="${2:-}"; shift 2 || job_usage;;
    --name) name="${2:-}"; shift 2 || job_usage;;
    --class) class="${2:-}"; shift 2 || job_usage;;
    --time) time="${2:-}"; shift 2 || job_usage;;
    --cpus) cpus="${2:-}"; shift 2 || job_usage;;
    --mem) mem="${2:-}"; shift 2 || job_usage;;
    --gpus) gpus="${2:-}"; gpus_named=1; shift 2 || job_usage;;
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
  # (32) only the gpu class asks for a card: a batch or cpu job named with --gpus once started on a node with no card and
  # nothing said why, so the request is refused aloud, and a GPU job on the batch partition is --class gpu --partition <it>
  [ "${gpus_named:-0}" = 0 ] || [ "$class" = gpu ] || die "--gpus is for the gpu class; a $class job gets no card (a GPU job on the batch partition is --class gpu --partition ${P_partition_cpu_batch:-<the batch partition>})"
  [ -z "$type" ] || [[ "$type" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "--gpu-type is one GPU type's name, as sinfo's GRES column gives it"
  [ -z "$array" ] || [[ "$array" =~ $HPCW_JOB_ARRAY_RE ]] || die "--array is task numbers and ranges (0-63, 1,3,5-9, 0-99:2) with an optional %N limit"
  case "$dir" in /*) [ -d "$dir" ] || die "--dir $dir is not a folder";; *) die "--dir must be an absolute path";; esac
  case "$placement" in ""|auto|report) ;; *) die "--placement is auto or report";; esac
  [[ "$gpumem" =~ ^[0-9]{1,4}$ ]] || die "--gpu-mem is the least memory a card must hold, in whole GB"
  [ -z "$prefer" ] || [[ "$prefer" =~ ^[A-Za-z0-9_.-]{1,64}(,[A-Za-z0-9_.-]{1,64}){0,7}$ ]] || die "--prefer is a partition's name, or up to eight joined by commas"
  [ -z "$prefer" ] || [ -n "$placement" ] || die "--prefer is --placement's"
  if [ -n "$placement" ]; then
    [ -z "$want" ] && [ -z "$type" ] || die "--placement chooses the partition and the card; leave out --partition and --gpu-type, and name the need with --gpu-mem and --gpu-arch"
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
    local race_args=()
    # the job's own resources and wall time, as each candidate is asked with them
    race_args=("--job-name=$project-$name" -D "$dir")
    [ -n "$time" ] && race_args+=("--time=$time")
    [ -n "$cpus" ] && race_args+=("--cpus-per-task=$cpus")
    [ -n "$mem" ] && race_args+=("--mem=$mem")
    PLACE_PREFER=$prefer
    job_need_place "$class" "$gpus" "$gpumem" "$gpuarch" "$requeue" "$script" "${race_args[@]}" || die "$PLACE_WHY"
    while IFS= read -r o; do [ -n "$o" ] && echo "HPCW-JOB placement $name $o"; done <<< "$PLACE_TABLE"
    echo "HPCW-JOB placement $name chose $(job_choice_text)"
    [ "$placement" = report ] && return 0
    opts=$(job_choice_options "$requeue")
  else
  opts=$(job_class_options "$class" "$gpus" "$want" "$requeue" "$type" 2>&1) || die "$opts"
  # a job placed by hand is kept off the nodes placement avoids too (job_avoid_nodes): a node listed in
  # placement.exclude, one ending every job at once, or one failing its probe
  local avoid; avoid=$(job_avoid_nodes)
  [ -z "$avoid" ] || opts="$opts"$'\n'"--exclude=$(job_hostlist $avoid)"
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
  # (32) the project's own admission: an executable <state>/jobs/<project>/admit, handed the class, the script and the
  # sbatch options, may refuse a job before anything is asked or queued (a project's rule of which jobs it runs at all,
  # such as every GPU job on a launched pipeline); its words are the refusal's, and --check meets it as a submission does
  local admit="$jd/admit" said
  if [ -x "$admit" ]; then
    said=$("$admit" "$class" "$script" "${args[@]}" 2>&1) \
      || { echo "HPCW-JOB refused $name: the project's admission: $(printf '%s' "$said" | job_clean | tr '\n' ' ' | sed 's/[[:space:]]*$//' | cut -c1-400)"; return 1; }
  fi
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
    # an array's tasks each write a log of their own, so only a single job's log opens with the table
    [ -n "$array" ] || { printf '== hpcworker placement for %s, %s UTC: the estimates sbatch --test-only gave, then the choice\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%S)"
      printf '%s' "$PLACE_TABLE" | sed 's/^/   /'
      printf '   chose %s\n' "$PLACE_CHOICE"; } >> "$log" 2>/dev/null
    job_need_write "$project" "$id" "$class" "$gpus" "$gpumem" "$gpuarch" "$requeue" "$prefer"
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

# ---- job place, job replace and job usage (31) ------------------------------------------------------------
job_need_args() { # the resource options place and replace share, validated -> 0, or die
  [ -z "$N_time" ] || [[ "$N_time" =~ $HPCW_JOB_TIME_RE ]] || die "--time is H:MM:SS or D-H:MM:SS"
  [ -z "$N_cpus" ] || [[ "$N_cpus" =~ ^[1-9][0-9]{0,2}$ ]] || die "--cpus is a whole number from 1 to 999"
  [ -z "$N_mem" ] || [[ "$N_mem" =~ $HPCW_JOB_MEM_RE ]] || die "--mem is a number with K, M, G or T after it"
  [[ "$N_gpus" =~ ^[1-8]$ ]] || die "--gpus is 1 to 8"
  [[ "$N_gpumem" =~ ^[0-9]{1,4}$ ]] || die "--gpu-mem is the least memory a card must hold, in whole GB"
  return 0
}

job_place() {
  # The placement job submit --placement auto makes, printed as sbatch options and submitted nowhere, for a
  # caller that submits its own jobs (tools/grid_runner.sh's autoscaler): the race's lines, the choice, and
  # one line "HPCW-JOB options --partition=... --qos=..." to put on its sbatch line.
  local class="" name=place requeue="" gpuarch="" o
  N_time="" N_cpus="" N_mem="" N_gpus=1 N_gpumem=0
  while [ $# -gt 0 ]; do case "$1" in
    --class) class="${2:-}"; shift 2 || job_usage;;
    --name) name="${2:-}"; shift 2 || job_usage;;
    --time) N_time="${2:-}"; shift 2 || job_usage;;
    --cpus) N_cpus="${2:-}"; shift 2 || job_usage;;
    --mem) N_mem="${2:-}"; shift 2 || job_usage;;
    --gpus) N_gpus="${2:-}"; shift 2 || job_usage;;
    --gpu-mem) N_gpumem="${2:-}"; shift 2 || job_usage;;
    --gpu-arch) gpuarch="${2:-}"; shift 2 || job_usage;;
    --prefer) PLACE_PREFER="${2:-}"; shift 2 || job_usage;;
    --requeue) requeue=yes; shift;;
    --no-requeue) requeue=no; shift;;
    *) job_usage;;
  esac; done
  case "$class" in cpu|batch|gpu|runner) ;; *) die "--class is cpu, batch, gpu or runner";; esac
  [ -z "${PLACE_PREFER:-}" ] || [[ "$PLACE_PREFER" =~ ^[A-Za-z0-9_.-]{1,64}(,[A-Za-z0-9_.-]{1,64}){0,7}$ ]] || die "--prefer is a partition's name, or up to eight joined by commas"
  [[ "$name" =~ $HPCW_JOB_NAME_RE ]] || die "--name is letters, digits, _, . and -, at most 64, starting with a letter or digit"
  job_need_args
  gpuarch=$(job_arch_set "${gpuarch:-ampere,ada,hopper}") || die "--gpu-arch is a list of $HPCW_ARCHS, or one of them with + for it and every newer one"
  load_profile
  [ "$P_scheduler" = slurm ] || die "hpcworker job speaks Slurm only for now; this site's scheduler is $P_scheduler"
  job_site_placement
  [ -r "$(job_place_file)" ] || die "this site has no placement file ($(job_place_file))"
  local race_args=("--job-name=$name")
  [ -n "$N_time" ] && race_args+=("--time=$N_time")
  [ -n "$N_cpus" ] && race_args+=("--cpus-per-task=$N_cpus")
  [ -n "$N_mem" ] && race_args+=("--mem=$N_mem")
  if ! job_need_place "$class" "$N_gpus" "$N_gpumem" "$gpuarch" "$requeue" "" "${race_args[@]}"; then
    while IFS= read -r o; do [ -n "$o" ] && echo "HPCW-JOB placement $name $o"; done <<< "$PLACE_TABLE"
    echo "HPCW-JOB refused $name: $PLACE_WHY"; return 1
  fi
  while IFS= read -r o; do [ -n "$o" ] && echo "HPCW-JOB placement $name $o"; done <<< "$PLACE_TABLE"
  echo "HPCW-JOB placement $name chose $(job_choice_text)"
  echo "HPCW-JOB options $(job_choice_options "$requeue" | tr '\n' ' ' | sed 's/ *$//')"
}

job_need_read() { # PROJECT ID LEDGER_LINE -> "class=C gpus=G gpu_mem=M gpu_arch=A requeue=R" of a job hpcworker placed; 1 for any other
  local f; f="$(job_dir "$1")/placed/$2"
  if [ -s "$f" ]; then head -n 1 "$f"; return 0; fi
  # A job framework 30 placed has no record, but its log opens with the race it ran: the cards it was asked
  # with (each fits it, so the smallest is no more than it needs) and whether a preemptable partition was one.
  local class log; class=$(printf '%s\n' "$3" | cut -f3); log=$(printf '%s\n' "$3" | cut -f7)
  [ -f "$log" ] || return 1
  awk -v class="$class" -v pf="$(job_place_file)" '
    BEGIN { while ((getline l < pf) > 0) { n = split(l, w, " "); if (w[1] == "candidate") pre[w[3] "/" w[4]] = w[5] } }
    NR == 1 && !/^== hpcworker placement for / { exit 1 }
    NR == 1 { next }
    /^   chose / { done = 1; exit }
    /^   / { if (pre[$1] == "yes") anypre = 1
            if ($3 ~ /^[0-9]+GB$/) { m = $3 + 0; if (min == "" || m < min) min = m; a[$4] = 1 }
            next }
    { exit 1 }
    END { if (!done) exit 1
          archs = ""; for (k in a) archs = archs (archs == "" ? "" : ",") k
          if (class == "gpu" && min == "") exit 1
          printf "class=%s gpus=1 gpu_mem=%s gpu_arch=%s requeue=%s\n", class, (min == "" ? 0 : min), (archs == "" ? "-" : archs), (anypre ? "-" : "no") }' "$log"
}

job_same_set() { # LIST LIST -> 0 when the two comma lists name the same members
  [ "$(printf '%s\n' ${1//,/ } | sort -u | paste -sd, -)" = "$(printf '%s\n' ${2//,/ } | sort -u | paste -sd, -)" ]
}
job_iso() { if [ -n "${1:-}" ]; then date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; else printf 'none'; fi; }

REPLACE_MOVED=0
job_replace_one() { # ID NAME PARTITIONS QOS CPUS MEM TIME TRES EXCLUDED NEED PROJECT LOG DRY GAIN: race one pending job again, and move it when that pays
  local id=$1 jname=$2 parts=$3 qos=$4 cpus=$5 jmem=$6 tl=$7 tres=$8 excl=${9:--} need=${10} project=${11} log=${12} dry=${13} gain=${14}
  local class="" gpus=1 gpumem=0 archs="" rq="" kv gres=- n prefer=""
  for kv in $need; do case "$kv" in
    class=*) class=${kv#*=};; gpus=*) gpus=${kv#*=};; gpu_mem=*) gpumem=${kv#*=};; gpu_arch=*) archs=${kv#*=};; requeue=*) rq=${kv#*=};;
    prefer=*) prefer=${kv#*=};;
  esac; done
  [[ "$prefer" =~ ^[A-Za-z0-9_.,-]*$ ]] || prefer=""
  PLACE_PREFER=$prefer
  [ "$rq" = - ] && rq=""
  { [ -z "$archs" ] || [ "$archs" = - ]; } && archs="ampere,ada,hopper"
  archs=$(job_arch_set "$archs") || return 0
  # the gres the job holds now, and its count of cards
  case "$tres" in *gres:gpu:*) gres=${tres#*gres:}; gres=${gres%%,*}; n=${gres##*:}; [[ "$n" =~ ^[1-8]$ ]] && gpus=$n;; esac
  [ -n "$excl" ] || excl=-
  local race_args=("--job-name=$jname" "--cpus-per-task=$cpus" "--mem=$jmem")
  [[ "$tl" =~ ^[0-9:-]+$ ]] && race_args+=("--time=$tl")
  # where it stands now, each of its partitions asked alone, as the race asks the others
  local cur="" at p now floor
  now=$(date +%s)
  for p in ${parts//,/ }; do
    at=$(job_ask "$p" "$qos" "$gres" "$excl" "" "${race_args[@]}") || continue
    # (32) a job waiting for priority where it is waits at least as long again as it has: its own wait is the evidence
    floor=$(job_wait_floor "$p" "$qos" "$cpus" "$jmem" "$([ "$gres" = - ] && echo 0 || echo "$gpus")")
    [ "$floor" -gt 0 ] && [ "$at" -lt $((now + floor)) ] && at=$((now + floor))
    if [ -z "$cur" ] || [ "$at" -lt "$cur" ]; then cur=$at; fi
  done
  job_need_place "$class" "$gpus" "$gpumem" "$archs" "$rq" "" "${race_args[@]}" || { echo "HPCW-JOB kept $id $jname: $PLACE_WHY"; return 0; }
  local bp bq bpre bg bx; read -r bp bq bpre bg bx <<< "$PLACE_CHOICE"
  local from="$parts/$qos$([ "$gres" != - ] && echo " $gres")" to
  to="$(job_choice_text)"
  local what="estimate $(job_iso "$cur") -> $(job_iso "$PLACE_AT")"
  # a dry run says why each job stays, so a person can read the race the way the move would have
  stays() { [ "$dry" = 1 ] && echo "HPCW-JOB stays $id $jname $from: $1, $what"; return 0; }
  if job_same_set "$bp" "$parts" && [ "$bq" = "$qos" ] && [ "$bg" = "$gres" ] && [ "$bx" = "$excl" ]; then stays "already where the race puts it"; return 0; fi
  now=$(date +%s)
  # about to start where it is, or no sooner by the margin elsewhere: left where it is
  if [ -n "$cur" ]; then
    [ "$cur" -le $((now + 120)) ] && { stays "about to start there"; return 0; }
    [ "$PLACE_AT" -lt $((cur - gain)) ] || { stays "$to starts it no sooner by ${gain} s"; return 0; }
  fi
  if [ "$dry" = 1 ]; then echo "HPCW-JOB would-move $id $jname $from -> $to, $what"; return 0; fi
  local upd=("jobid=$id" "partition=$bp" "qos=$bq") out rc=0
  if [ "$bg" != - ]; then
    upd+=("gres=$bg")
    if [ "$bx" != - ]; then upd+=("excnodelist=$bx"); elif [ "$excl" != - ]; then upd+=("excnodelist="); fi
  fi
  # a job sent where it may be preempted must be requeued then, not ended (PreemptMode=REQUEUE ends a job
  # that may not requeue); only a job that never said --no-requeue is ever sent there
  [ "$bpre" = yes ] && upd+=("requeue=1")
  out=$(scontrol update "${upd[@]}" 2>&1) || rc=$?
  local stamp jd; stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ); jd="$STATE_DIR/jobs"
  if [ $rc = 0 ]; then
    REPLACE_MOVED=$((REPLACE_MOVED + 1))
    echo "HPCW-JOB moved $id $jname $from -> $to, $what"
    ( umask 077; mkdir -p "$jd/.moves" && echo "$now" >> "$jd/.moves/${id%%_*}"
      echo "$stamp moved $id $jname $from -> $to, $what" >> "$jd/replace.log" ) 2>/dev/null
    [ -n "$log" ] && [ -f "$log" ] && echo "== hpcworker $stamp: moved while pending from $from to $to, $what" >> "$log" 2>/dev/null
    return 0
  fi
  out=$(printf '%s' "$out" | job_clean | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  # A runner job holds nothing yet while it waits, and the autoscaler queues one again, placed afresh, for a
  # GitHub job still waiting; any other job is left where it is, since its environment, which a cancel
  # would lose, is never kept (it may hold a credential).
  if [ "$class" = runner ] && scancel "$id" 2>/dev/null; then
    echo "HPCW-JOB cancelled $id $jname: Slurm refused the move to $to ($out); the autoscaler queues it again"
    ( umask 077; echo "$stamp cancelled $id $jname: the move to $to refused ($out)" >> "$jd/replace.log" ) 2>/dev/null
  else
    echo "HPCW-JOB kept $id $jname: Slurm refused the move to $to: $out"
  fi
  return 0
}

job_array_tasks() { # BASE SPEC -> BASE_i,BASE_j,... for what squeue names 123_[5-7,9%4] or 123_5; 1 for anything else
  local base=$1 spec=${2#\[} part a b step i out=""
  spec=${spec%\]}; spec=${spec%%\%*}
  [[ "$spec" =~ ^[0-9][0-9,:-]*$ ]] || return 1
  for part in ${spec//,/ }; do
    step=1
    case "$part" in *:*) step=${part#*:}; part=${part%:*};; esac
    a=${part%-*}; b=${part#*-}
    [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] && [[ "$step" =~ ^[1-9][0-9]*$ ]] || return 1
    for ((i = a; i <= b; i += step)); do out="$out,${base}_$i"; done
  done
  printf '%s' "${out#,}"
}

job_replace() {
  # Framework 31: a placement is a guess made once, from estimates that ignore every pending job and every
  # job that ends before its time limit, so the guess goes stale while a job waits. job replace races this
  # account's own pending jobs again (those hpcworker placed, and with --runners the autoscaler's runner
  # jobs) and moves one, in place with scontrol update, which keeps its id and whatever waits on it, when
  # another placement would start it sooner by more than --gain seconds.
  local projects=() only=" " runners=0 dry=0 gain=${HPCW_REPLACE_GAIN:-300} age=${HPCW_REPLACE_AGE:-120} hold=${HPCW_REPLACE_HOLD:-600} most=${HPCW_REPLACE_MAX:-20}
  while [ $# -gt 0 ]; do case "$1" in
    --project) projects+=("${2:-}"); shift 2 || job_usage;;
    --runners) runners=1; shift;;
    --dry-run) dry=1; shift;;
    --job) [[ "${2:-}" =~ ^[0-9]{1,12}$ ]] || die "--job is one job id"; only="$only$2 "; shift 2;;
    --gain) gain="${2:-}"; shift 2 || job_usage;;
    --age) age="${2:-}"; shift 2 || job_usage;;
    *) job_usage;;
  esac; done
  local p; for p in ${projects[@]+"${projects[@]}"}; do [[ "$p" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"; done
  [[ "$gain" =~ ^[0-9]{1,6}$ ]] && [[ "$age" =~ ^[0-9]{1,6}$ ]] && [[ "$hold" =~ ^[0-9]{1,6}$ ]] && [[ "$most" =~ ^[0-9]{1,4}$ ]] \
    || die "--gain, --age, HPCW_REPLACE_HOLD and HPCW_REPLACE_MAX are whole seconds (a count for the last)"
  load_profile
  [ "$P_scheduler" = slurm ] || die "hpcworker job speaks Slurm only for now; this site's scheduler is $P_scheduler"
  job_site_placement
  [ -r "$(job_place_file)" ] || die "this site has no placement file ($(job_place_file))"
  if [ ${#projects[@]} = 0 ]; then
    local f; for f in "$STATE_DIR"/jobs/*/jobs.tsv; do [ -s "$f" ] && projects+=("$(basename "$(dirname "$f")")"); done
  fi
  local own; own=$(job_own_jobs) || { echo "HPCW-JOB replace: squeue did not answer; nothing was moved"; return 1; }
  local now id jname st parts qos reason cpus jmem tl tres excl sub dep line need project log at last looked=0 base target
  now=$(date +%s)
  while IFS='|' read -r id jname st parts qos reason cpus jmem tl tres excl sub dep; do
    [ "$st" = PENDING ] || continue
    # an array's waiting tasks, as squeue lists them (123_[5-7%4], or 123_5 once one has been moved), are raced
    # as one under the array's record; each is a worker that may start on any card that fits
    base=${id%%_*} target=$id
    [[ "$base" =~ ^[0-9]{1,12}$ ]] || continue
    if [ "$id" != "$base" ]; then target=$(job_array_tasks "$base" "${id#*_}") || continue; fi
    [ "$only" = " " ] || case "$only" in *" $base "*) ;; *) continue;; esac   # --job: these alone
    case "$reason" in Priority|Resources|ReqNodeNotAvail*|QOS*) ;; *) continue;; esac
    case "$dep" in ""|"(null)") ;; *) continue;; esac  # one that waits on another job is not waiting for a card
    need="" project="" line="" log=""
    for p in ${projects[@]+"${projects[@]}"}; do line=$(job_known "$p" "$base"); [ -n "$line" ] && { project=$p; break; }; done
    if [ -n "$line" ]; then
      need=$(job_need_read "$project" "$base" "$line") || continue
      log=$(printf '%s\n' "$line" | cut -f7)
    elif [ $runners = 1 ] && [[ "$jname" == hpcw_auto_* ]] && [[ "$tres" != *gpu* ]]; then
      need="class=runner gpus=1 gpu_mem=0 gpu_arch=- requeue=-"
    else continue; fi
    at=$(date -d "${sub/T/ }" +%s 2>/dev/null) || continue
    [ $((now - at)) -ge "$age" ] || continue
    last=$(tail -n 1 "$STATE_DIR/jobs/.moves/$base" 2>/dev/null)
    [[ "$last" =~ ^[0-9]+$ ]] && [ $((now - last)) -lt "$hold" ] && continue
    looked=$((looked + 1)); [ "$looked" -le "$most" ] || break
    job_replace_one "$target" "$jname" "$parts" "$qos" "$cpus" "$jmem" "$tl" "$tres" "$excl" "$need" "$project" "$log" "$dry" "$gain" < /dev/null
  done <<< "$own"
  echo "HPCW-JOB replace looked at $((looked > most ? most : looked)) pending job(s), moved $REPLACE_MOVED"
}

job_usage_report() {
  # What each job name of the project's last K ended jobs asked for beside what it used, from one sacct: the
  # memory asked and the batch step's peak resident memory, the cores asked and the cores used on average
  # (TotalCPU over Elapsed), and a fit of 1.5 times the peak (at least 2 GB). Asking far more than a job uses
  # keeps it off nodes whose cards are free but whose cores or memory are mostly taken. The peak on the card is the
  # batch step's gres/gpumem where the site gathers it; a framework that preallocates (JAX) reads its share of whatever
  # card it held, so that number says what a torch job needs and says nothing of a JAX job's.
  local project="" last=200
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --last) last="${2:-}"; shift 2 || job_usage;;
    *) job_usage;;
  esac; done
  [[ "$project" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"
  [[ "$last" =~ ^[1-9][0-9]{0,3}$ ]] || die "--last is 1 to 9999"
  load_profile
  local ledger ids acct
  ledger=$(job_ledger "$project" "$last")
  [ -n "$ledger" ] || { echo "HPCW-JOB none for $project"; return 0; }
  ids=$(printf '%s\n' "$ledger" | cut -f1 | paste -sd, -)
  acct=$(LC_ALL=C timeout 60 sacct -n -P -j "$ids" --format=JobID,ReqMem,MaxRSS,AllocCPUS,TotalCPU,Elapsed,State,TRESUsageInMax 2>/dev/null | tr -d '\r') \
    || { echo "HPCW-JOB usage: sacct did not answer"; return 1; }
  printf '%s\n' "$ledger" | ACCT="$acct" LC_ALL=C awk -F'\t' '
    function secs(t,   d, n, p, s, i) { d = 0; if (t ~ /-/) { d = substr(t, 1, index(t, "-") - 1); t = substr(t, index(t, "-") + 1) }
      sub(/\..*/, "", t); n = split(t, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]; return d * 86400 + s }
    function gb(m,   v, u) { if (m == "" || m == "0") return 0; v = m + 0; u = m; gsub(/[0-9.]/, "", u); u = substr(u, 1, 1)
      if (u == "K") return v / 1048576; if (u == "M") return v / 1024; if (u == "G") return v; if (u == "T") return v * 1024; return v / 1073741824 }
    BEGIN { n = split(ENVIRON["ACCT"], l, "\n")
      for (i = 1; i <= n; i++) { split(l[i], f, "|"); id = f[1]; base = id; sub(/[._].*/, "", base)
        if (id ~ /\.batch$/) { r = gb(f[3]); if (r > rss[base]) rss[base] = r
          if (match(f[8], /gres\/gpumem=[0-9.]+[KMGT]?/)) { c = gb(substr(f[8], RSTART + 12, RLENGTH - 12)); if (c > card[base]) card[base] = c }
          continue }
        if (id ~ /\./) continue
        a = gb(f[2]); if (a > ask[base]) ask[base] = a; if (f[4] + 0 > cores[base]) cores[base] = f[4] + 0
        e = secs(f[6]); if (e > 0) { u = secs(f[5]) / e; if (u > used[base]) used[base] = u }
        st[base] = st[base] " " f[7]; seen[base] = 1 } }
    { id = $1; nm = $2; if (!(id in seen)) next
      if (st[id] ~ /PENDING|RUNNING/ && st[id] !~ /COMPLETED|FAILED|TIMEOUT|OUT_OF/) next
      if (!(nm in runs)) order[++k] = nm
      runs[nm]++; if (ask[id] > mask[nm]) mask[nm] = ask[id]; if (rss[id] > mrss[nm]) mrss[nm] = rss[id]
      if (cores[id] > mcores[nm]) mcores[nm] = cores[id]; if (used[id] > mused[nm]) mused[nm] = used[id]
      if (card[id] > mcard[nm]) mcard[nm] = card[id]
      if (st[id] ~ /OUT_OF_ME/) oom[nm] = 1 }
    END { for (i = 1; i <= k; i++) { nm = order[i]; fit = mrss[nm] * 1.5; if (fit < 2) fit = 2; fit = int(fit + 0.999)
        printf "HPCW-JOB usage %s runs %d mem asked %.0fG peak %.1fG fit %dG cores asked %d used %.1f card peak %.1fG%s\n", nm, runs[nm], mask[nm], mrss[nm], fit, mcores[nm], mused[nm], mcard[nm], (oom[nm] ? " out-of-memory" : "") } }'
}

job_probe() {
  # A node that takes jobs but cannot run ours (2026-11-04: an H200 node, back in service without the home file system,
  # ended every job in its first second) is found before a job lands there: a one-minute job of one core on the
  # node itself, which reads this account's home and state folder and nothing else. --immediate gives it 10
  # seconds to start, so a busy node is no failure: it reads "unknown" and is asked again at the next probe. A
  # node whose probe ran and could not read them reads "fail", and placement keeps every job off it for
  # HPCW_PROBE_FRESH seconds (3600). Each node is asked at most once in that time, the ones asked longest ago
  # first, at most --max (6) a call. It runs only from a Slurm job (the autoscaler's controller), whose own
  # allocation the probe must not use, so it starts a job of its own; never on a login node.
  local nodes="" most=6 f now n part qos node out rc said asked=0
  while [ $# -gt 0 ]; do case "$1" in
    --nodes) nodes="${2:-}"; shift 2 || job_usage;;
    --max) most="${2:-}"; shift 2 || job_usage;;
    *) job_usage;;
  esac; done
  [[ "$most" =~ ^[1-9][0-9]{0,2}$ ]] || die "--max is 1 to 999"
  [ -z "$nodes" ] || [[ "$nodes" =~ $HPCW_JOB_HOSTLIST_RE ]] || die "--nodes is a Slurm host list"
  [ -n "${SLURM_JOB_ID:-}" ] || die "job probe starts jobs of its own on the nodes it asks; run it inside a Slurm job (the autoscaler's controller), never on a login node"
  load_profile
  [ "$P_scheduler" = slurm ] || die "hpcworker job speaks Slurm only for now; this site's scheduler is $P_scheduler"
  job_site_placement
  [ -r "$(job_place_file)" ] || die "this site has no placement file ($(job_place_file))"
  f=$(job_probe_file); now=$(date +%s)
  # the GPU nodes of the site's gpu candidates, each with the first candidate partition and QoS that holds it
  local cand; cand=$(awk '$1 == "candidate" && $2 == "gpu" { print $3, $4 }' "$(job_place_file)")
  local pairs="" p q
  while read -r p q; do
    [ -n "$p" ] || continue
    while read -r node np nt; do
      [ -n "$node" ] || continue
      case "$pairs" in *" $node "*) ;; *) pairs="$pairs $node $p $q ";; esac
    done < <(job_gpu_nodes "$p")
  done <<< "$cand"
  local want=" "
  if [ -n "$nodes" ]; then want=" $(scontrol show hostnames "$nodes" 2>/dev/null | tr '\n' ' ') "; fi
  # oldest probe first, a node never asked before all of them
  local order
  order=$(set -- $pairs; while [ $# -ge 3 ]; do
      [ "$want" = " " ] || case "$want" in *" $1 "*) ;; *) shift 3; continue;; esac
      printf '%s %s %s %s\n' "$(awk -v n="$1" '$1 == n { t = $2 } END { print t + 0 }' "$f" 2>/dev/null || echo 0)" "$1" "$2" "$3"; shift 3
    done | sort -n -s -k1,1)
  local sargs=() v
  # a new allocation, not a step of the calling job's: every SLURM_ name of this job is taken away
  for v in $(compgen -e | grep '^SLURM_'); do sargs+=(-u "$v"); done
  while read -r n node part qos; do
    [ -n "$node" ] || continue
    [ $((now - n)) -ge "${HPCW_PROBE_FRESH:-3600}" ] || continue
    [ "$asked" -lt "$most" ] || break
    asked=$((asked + 1))
    rc=0
    out=$(env ${sargs[@]+"${sargs[@]}"} timeout 60 srun --immediate=10 --quiet -w "$node" -N 1 -n 1 -c 1 --mem=256M -t 1 \
      -p "$part" -q "$qos" ${P_account:+-A "$P_account"} -J hpcw_probe stat -c %n "$HOME" "$STATE_DIR" 2>&1) || rc=$?
    if [ $rc = 0 ] && printf '%s\n' "$out" | grep -qxF "$HOME"; then said=ok
    elif printf '%s' "$out" | grep -qiE 'immediate|unable to allocate|not available|resources|priority|reservation|timed out|socket|invalid'; then said=unknown
    elif [ $rc = 124 ]; then said=unknown
    else said=fail; fi
    ( umask 077; mkdir -p "$(dirname "$f")" && echo "$node $(date +%s) $said" >> "$f" ) 2>/dev/null
    echo "HPCW-JOB probe $node $said$([ "$said" = fail ] && echo ": $(printf '%s' "$out" | job_clean | tr '\n' ' ' | cut -c1-160)")"
  done <<< "$order"
  # the record keeps its last thousand lines
  if [ -f "$f" ] && [ "$(wc -l < "$f")" -gt 2000 ]; then tail -n 1000 "$f" > "$f.new" && mv -f "$f.new" "$f"; fi
  echo "HPCW-JOB probe asked $asked node(s)"
}

cmd_job() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    submit) job_submit "$@";;
    status) job_status "$@";;
    log) job_log "$@";;
    cancel) job_cancel "$@";;
    place) job_place "$@";;
    replace) job_replace "$@";;
    usage) job_usage_report "$@";;
    probe) job_probe "$@";;
    share) job_share_report "$@";;
    pack) job_pack "$@";;
    version) echo "HPCW-JOB version $VERSION interface $HPCW_JOB_INTERFACE";;
    *) job_usage;;
  esac
}
