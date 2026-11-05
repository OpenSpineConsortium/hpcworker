# shellcheck shell=bash
# hpcworker framework 34: a running job moved to a better card just after a checkpoint (README, "Moving a running job at a
# checkpoint (version 34)"). Sourced after lib/jobs.sh, whose placement file, ledger, placed records and candidates it uses:
#   job mark [--watch SECONDS] [-- FILE...]   inside a job: its marker <state>/jobs/<project>/checkpoints/<id> set to the
#                                            time of the oldest named checkpoint file, or to now when none is named
#   job replace (after the pending jobs)     this account's running placed GPU jobs whose marker is fresh, each moved where
#                                            a card free now runs its kind faster by the project's measured rates, and sent
#                                            back where it ran when it has not started there within HPCW_CHECKPOINT_RETURN
# The move is Slurm's own, requeuehold, update and release, so the job keeps its id and every job that waits on it, and
# starts again from the checkpoint its marker says it has just written. Nothing is moved without the kind's measured
# rate on both cards: a card's place in the placement file says little of a kind's speed (5 November: a design whose
# validation read is CPU-bound ran 1,170 steps an hour on an A30 and 1,400 on an H200).

move_marker_dir() { printf '%s/jobs/%s/checkpoints' "$STATE_DIR" "$1"; }   # PROJECT
move_record_dir() { printf '%s/jobs/.checkpoint-moves' "$STATE_DIR"; }

move_mark_once() { # MARKER [FILE...]: the marker set to the oldest file's time (now when none is named); left while one is missing
  local marker=$1 oldest="" f t
  shift
  [ $# -gt 0 ] || oldest=$(date +%s)
  for f in "$@"; do
    t=$(stat -c %Y -- "$f" 2>/dev/null) || return 0
    if [ -z "$oldest" ] || [ "$t" -lt "$oldest" ]; then oldest=$t; fi
  done
  ( umask 077; mkdir -p "${marker%/*}" && touch -d "@$oldest" -- "$marker" ) 2>/dev/null || true
}

job_mark() {
  # A job that runs several runs side by side names each run's checkpoint: the marker is only as fresh as the stalest of
  # them, so a move never costs one of them more than the time since its own last checkpoint.
  local every="" files=() id=${SLURM_JOB_ID:-}
  while [ $# -gt 0 ]; do case "$1" in
    --watch) every="${2:-}"; shift 2 || job_usage;;
    --) shift; files=("$@"); break;;
    *) job_usage;;
  esac; done
  [ -z "$every" ] || [[ "$every" =~ ^[1-9][0-9]{0,4}$ ]] || die "--watch is whole seconds, 1 to 99999"
  if [ -z "${HPCW_CHECKPOINTS:-}" ] || ! [[ "$id" =~ ^[0-9]{1,12}$ ]]; then
    echo "HPCW-JOB mark: not inside a job hpcworker submitted (no HPCW_CHECKPOINTS or SLURM_JOB_ID); nothing marked"
    return 0
  fi
  move_mark_once "$HPCW_CHECKPOINTS/$id" ${files[@]+"${files[@]}"}
  [ -n "$every" ] || return 0
  while sleep "$every"; do move_mark_once "$HPCW_CHECKPOINTS/$id" ${files[@]+"${files[@]}"}; done
}

move_secs() { # SLURM_TIME (D-HH:MM:SS, HH:MM:SS or MM:SS) -> whole seconds; 1 for UNLIMITED or anything unreadable
  [[ "$1" =~ ^(([0-9]+)-)?(([0-9]+):)?([0-9]+):([0-9]+)$ ]] || return 1
  echo $(( 10#${BASH_REMATCH[2]:-0} * 86400 + 10#${BASH_REMATCH[4]:-0} * 3600 + 10#${BASH_REMATCH[5]} * 60 + 10#${BASH_REMATCH[6]} ))
}

move_age() { # FILE -> seconds since it was last changed; 1 when there is none
  local t; t=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  echo $(( $(date +%s) - t ))
}

move_nodes() { # every usable GPU node: "NODE PARTITIONS IDLE_CORES ALLOCATABLE_MB TYPE:FREE[,TYPE:FREE]..." a line, one scontrol
  # The memory is what Slurm can still allocate, RealMemory less AllocMem, never what the node's system has free: on
  # 5 November a reading of sinfo's FreeMem called five Blackwell cards free for 48 GB jobs on a node whose allocations
  # left 15 GB, and a node's cores and memory bind a move as its cards do, since a job's cores cannot change.
  scontrol -o show node 2>/dev/null | awk '
    function val(k,   i) { for (i = 1; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
    function cards(s, out,   n, i, kv, t) {
      n = split(s, kv, ",")
      for (i = 1; i <= n; i++) if (index(kv[i], "gres/gpu:") == 1) { t = substr(kv[i], 10); out[substr(t, 1, index(t, "=") - 1)] = substr(t, index(t, "=") + 1) + 0 } }
    { if (val("State") ~ /DRAIN|DOWN|MAINT|RESERVED|FAIL|NOT_RESPONDING|POWER|REBOOT|FUTURE/) next
      split("", cfg); split("", used); cards(val("CfgTRES"), cfg); cards(val("AllocTRES"), used)
      cores = val("CPUEfctv"); if (cores == "") cores = val("CPUTot")
      free = ""; for (t in cfg) free = free (free == "" ? "" : ",") t ":" (cfg[t] - used[t])
      if (free != "") print val("NodeName"), val("Partitions"), cores - val("CPUAlloc"), val("RealMemory") - val("AllocMem"), free }'
}

move_rate() { # PROJECT NAME TYPE -> the kind's measured rate on that card type, from the project's speeds file; 1 when none
  # <state>/jobs/<project>/speeds: "NAME_REGEX CARD_TYPE RATE" a line, # a comment; the first line whose regular
  # expression matches the job's name and whose card is TYPE gives the rate, in any unit the project keeps alike.
  local f; f="$(job_dir "$1")/speeds"
  [ -r "$f" ] || return 1
  awk -v name="$2" -v type="$3" '!/^[ \t]*#/ && NF >= 3 && $2 == type && $3 ~ /^[0-9]+([.][0-9]+)?$/ && name ~ $1 { print $3; found = 1; exit }
    END { exit found ? 0 : 1 }' "$f" 2>/dev/null
}

move_card_of() { # TRES NODE -> the type of card the running job holds: its gres's own type, else its node's one type
  local t
  case "$1" in *gres:gpu:*:*) t=${1#*gres:gpu:}; printf '%s\n' "${t%%:*}"; return 0;; esac
  printf '%s\n' "$MOVE_NODES" | awk -v n="$2" '$1 == n { k = split($5, c, ","); if (k == 1) { split(c[1], p, ":"); print p[1]; found = 1 } }
    END { exit found ? 0 : 1 }'
}

move_waiting() { # PARTITION CORES MEM_MB SELF -> 0 when a pending GPU job of anyone's there fits such a node and so comes first
  # A free card a waiting job fits goes to that job at Slurm's next pass, whatever this account does: a running job sent
  # to it would give up its own card and then wait.
  squeue -h -t PENDING -p "$1" -o '%i|%C|%m|%b|%r' 2>/dev/null | awk -F'|' -v cores="$2" -v mem="$3" -v self="$4" '
    function mb(v,   u) { u = substr(v, length(v)); v += 0; if (u == "K") return v / 1024; if (u == "G") return v * 1024; if (u == "T") return v * 1048576; return v }
    $1 != self && $4 ~ /gpu/ && $5 ~ /^(Priority|Resources)$/ && $2 + 0 <= cores + 0 && mb($3) <= mem + 0 { found = 1; exit }
    END { exit found ? 0 : 1 }'
}

move_free_cards() { # NEED CPUS MEM_MB GPUS -> "PARTITION QOS PREEMPTABLE TYPE NODE CORES MEM_MB" for each card free now that fits the job
  local class="" gpumem=0 archs="" rq="" kv nopre=0 part qos pre t mem arch max
  for kv in $1; do case "$kv" in
    class=*) class=${kv#*=};; gpu_mem=*) gpumem=${kv#*=};; gpu_arch=*) archs=${kv#*=};; requeue=*) rq=${kv#*=};;
  esac; done
  [ "$class" = gpu ] || return 0
  { [ -z "$archs" ] || [ "$archs" = - ]; } && archs="ampere,ada,hopper"
  archs=$(job_arch_set "$archs") || return 0
  [ "$rq" = no ] && nopre=1
  while read -r part qos pre t mem arch max; do
    [ -n "$part" ] && [ "${max:--}" = - ] || continue
    printf '%s\n' "$MOVE_NODES" | awk -v p="$part" -v t="$t" -v c="$2" -v m="$3" -v g="$4" -v avoid=" $MOVE_AVOID " \
      -v q="$qos" -v pre="$pre" 'index(avoid, " " $1 " ") == 0 && index("," $2 ",", "," p ",") > 0 && $3 + 0 >= c + 0 && $4 + 0 >= m + 0 {
        k = split($5, f, ","); for (i = 1; i <= k; i++) { split(f[i], x, ":"); if (x[1] == t && x[2] + 0 >= g + 0) print p, q, pre, t, $1, $3, $4 } }'
  done < <(job_candidates gpu "$gpumem" "$archs" "$nopre")
}

move_gain() { # RATE_NOW RATE_THERE HORIZON LOST -> whole seconds the move is expected to save, below 0 when it costs
  awk -v a="$1" -v b="$2" -v h="$3" -v lost="$4" 'BEGIN { if (b <= 0) { print -1; exit } printf "%d\n", h * (1 - a / b) - lost }'
}

move_best() { # ID NAME NEED CPUS MEM_MB GPUS TYPE_NOW HORIZON LOST -> MOVE_TO "PART QOS PRE TYPE NODE", MOVE_SAVES; 1 with MOVE_WHY
  local id=$1 jname=$2 need=$3 cpus=$4 mb=$5 gpus=$6 now_type=$7 horizon=$8 lost=$9 rate_now rate p q pre t node cores mem saves
  MOVE_TO="" MOVE_SAVES=0 MOVE_WHY="no other card it fits is free now"
  rate_now=$(move_rate "$MOVE_PROJECT" "$jname" "$now_type") || { MOVE_WHY="no measured rate for it on $now_type"; return 1; }
  while read -r p q pre t node cores mem; do
    [ -n "$p" ] && [ "$t" != "$now_type" ] || continue
    rate=$(move_rate "$MOVE_PROJECT" "$jname" "$t") || { MOVE_WHY="no measured rate for it on the free $t card"; continue; }
    saves=$(move_gain "$rate_now" "$rate" "$horizon" "$lost")
    [ "$saves" -gt 0 ] || MOVE_WHY="the free $t card would not run it faster by the time it has left"
    [ "$saves" -gt "$MOVE_SAVES" ] || continue
    if move_waiting "$p" "$cores" "$mem" "$id"; then MOVE_WHY="a waiting job fits the free $t card on $node first"; continue; fi
    MOVE_TO="$p $q $pre $t $node" MOVE_SAVES=$saves
  done < <(move_free_cards "$need" "$cpus" "$mb" "$gpus")
  [ -n "$MOVE_TO" ] || return 1
  [ "$MOVE_SAVES" -gt "$MOVE_GAIN" ] || { MOVE_WHY="it would save ${MOVE_SAVES} s, not more than ${MOVE_GAIN} s"; return 1; }
}

move_said() { # LOG LINE: one line of the output, of <state>/jobs/replace.log and of the job's own log
  local stamp; stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "HPCW-JOB $2"
  ( umask 077; echo "$stamp $2" >> "$STATE_DIR/jobs/replace.log" ) 2>/dev/null
  [ -n "$1" ] && [ -f "$1" ] && echo "== hpcworker $stamp: $2" >> "$1" 2>/dev/null
  return 0
}

move_tries() { # COMMAND...: run until it answers 0, while Slurm still finishes the requeue (HPCW_CHECKPOINT_TRIES, 6, 10 s apart)
  local n=0 out
  until out=$("$@" 2>&1); do
    n=$((n + 1)); [ "$n" -lt "${HPCW_CHECKPOINT_TRIES:-6}" ] || { MOVE_SAID=$(printf '%s' "$out" | job_clean | tr '\n' ' '); return 1; }
    sleep "${HPCW_CHECKPOINT_WAIT:-10}"
  done
}
move_update() { move_tries scontrol update "$@"; }   # ARGS...: one scontrol update, tried again as move_tries says
move_release() { move_tries scontrol release "$1"; } # ID: the hold a move put on it taken off, tried again as move_tries says

move_go() { # ID NAME LOG GPUS FROM_PARTITION FROM_QOS FROM_GRES FROM_EXCLUDED: MOVE_TO done, recorded for the return; 0 when moved
  local id=$1 jname=$2 log=$3 gpus=$4 tp tq tpre tt tn rq out excl=""
  read -r tp tq tpre tt tn <<< "$MOVE_TO"
  [ -n "$MOVE_AVOID" ] && excl=$(job_hostlist $MOVE_AVOID)
  rq=$(scontrol show job "$id" 2>/dev/null | sed -n 's/.*Requeue=\([01]\).*/\1/p' | head -n 1)
  # Slurm requeues only a job that may be requeued; one sent with --no-requeue is made so for the move alone
  [ "$rq" = 1 ] || move_update jobid="$id" requeue=1 || { move_said "$log" "kept $id $jname: Slurm refused requeue=1: $MOVE_SAID"; return 1; }
  if ! out=$(scontrol requeuehold "$id" 2>&1); then
    [ "$rq" = 1 ] || scontrol update jobid="$id" requeue=0 > /dev/null 2>&1
    move_said "$log" "kept $id $jname: Slurm refused the requeue: $(printf '%s' "$out" | job_clean | tr '\n' ' ')"; return 1
  fi
  ( umask 077; mkdir -p "$(move_record_dir)" && printf '%s %s %s %s %s %s %s\n' "$(date +%s)" "$MOVE_PROJECT" "$5" "$6" "$7" "${8:--}" "${rq:-0}" \
      > "$(move_record_dir)/$id" ) 2>/dev/null
  if ! move_update jobid="$id" partition="$tp" qos="$tq" gres="gpu:$tt:$gpus" excnodelist="$excl"; then
    scontrol release "$id" > /dev/null 2>&1; rm -f "$(move_record_dir)/$id"
    move_said "$log" "kept $id $jname: requeued where it ran, Slurm refused the move to $tp/$tq gpu:$tt:$gpus: $MOVE_SAID"; return 1
  fi
  move_release "$id" || move_said "$log" "HELD $id $jname: moved to $tp/$tq gpu:$tt:$gpus but Slurm refused to release it: $MOVE_SAID; scontrol release $id"
  # back to the requeue flag it was sent with, where the card it goes to is never preempted
  [ "$rq" = 1 ] || [ "$tpre" = yes ] || scontrol update jobid="$id" requeue=0 > /dev/null 2>&1
  return 0
}

move_look() { # ID NAME PARTITION QOS CPUS MEM TRES NODE LEFT EXCLUDED: one running job; 0 when its marker was fresh enough to look
  local id=$1 jname=$2 part=$3 qos=$4 cpus=$5 jmem=$6 tres=$7 node=$8 left=$9 excl=${10} line="" p need age now_type secs horizon gpus=1 log what
  for p in ${MOVE_PROJECTS[@]+"${MOVE_PROJECTS[@]}"}; do line=$(job_known "$p" "$id"); [ -n "$line" ] && { MOVE_PROJECT=$p; break; }; done
  [ -n "$line" ] || return 1
  need=$(job_need_read "$MOVE_PROJECT" "$id" "$line") || return 1
  age=$(move_age "$(move_marker_dir "$MOVE_PROJECT")/$id") || return 1
  [ "$age" -le "${HPCW_CHECKPOINT_FRESH:-600}" ] || return 1
  log=$(printf '%s\n' "$line" | cut -f7)
  case "$tres" in *gres:gpu:*) gpus=${tres##*:}; [[ "$gpus" =~ ^[1-8]$ ]] || gpus=1;; esac
  now_type=$(move_card_of "$tres" "$node") || { [ "$MOVE_DRY" = 1 ] && echo "HPCW-JOB stays $id $jname: its card's type on $node is not known"; return 0; }
  secs=$(move_secs "$left") || secs=${HPCW_CHECKPOINT_HORIZON:-14400}
  horizon=$(( secs < ${HPCW_CHECKPOINT_HORIZON:-14400} ? secs : ${HPCW_CHECKPOINT_HORIZON:-14400} ))
  if ! move_best "$id" "$jname" "$need" "$cpus" "$(job_mem_mb "$jmem")" "$gpus" "$now_type" "$horizon" "$((age + ${HPCW_CHECKPOINT_RESTART:-600}))"; then
    [ "$MOVE_DRY" = 1 ] && echo "HPCW-JOB stays $id $jname on $node $now_type: $MOVE_WHY"; return 0
  fi
  what="$part/$qos $now_type on $node -> $(echo "$MOVE_TO" | awk '{ print $1 "/" $2 " " $4 " on " $5 }'), checkpoint ${age} s old, saves about ${MOVE_SAVES} s"
  if [ "$MOVE_DRY" = 1 ]; then echo "HPCW-JOB would-move-running $id $jname $what"; return 0; fi
  case "$excl" in ""|"(null)") excl=-;; esac
  move_go "$id" "$jname" "$log" "$gpus" "$part" "$qos" "$(printf '%s\n' "$tres" | sed 's/^gres[:/]//')" "$excl" || return 0
  MOVE_MOVED=$((MOVE_MOVED + 1))
  ( umask 077; mkdir -p "$STATE_DIR/jobs/.moves" && date +%s >> "$STATE_DIR/jobs/.moves/$id" ) 2>/dev/null
  move_said "$log" "moved-running $id $jname $what"
}

move_held() { # ID -> 0 when it was moved within HPCW_CHECKPOINT_HOLD seconds (3600), or waits to start where it was sent
  local last; last=$(tail -n 1 "$STATE_DIR/jobs/.moves/$1" 2>/dev/null)
  [ -f "$(move_record_dir)/$1" ] && return 0
  [[ "$last" =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - last )) -lt "${HPCW_CHECKPOINT_HOLD:-3600}" ]
}

move_returns() { # each job moved at a checkpoint: let be once it has started, sent back where it ran when it has not within the time
  local d f id at project fp fq fg fx rq st line log
  d=$(move_record_dir); [ -d "$d" ] || return 0
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    id=${f##*/}; read -r at project fp fq fg fx rq < "$f" || { rm -f "$f"; continue; }
    st=$(squeue -h -j "$id" -o %T 2>/dev/null | head -n 1)
    line=$(job_known "$project" "$id"); log=$(printf '%s\n' "$line" | cut -f7)
    case "$st" in
      PENDING) ;;
      "") rm -f "$f"; continue;;
      *) rm -f "$f"; move_said "$log" "started $id after its move at a checkpoint ($st)"; continue;;
    esac
    [ $(( $(date +%s) - at )) -ge "${HPCW_CHECKPOINT_RETURN:-900}" ] || continue
    [ "$MOVE_DRY" = 1 ] && { echo "HPCW-JOB would-return $id to $fp/$fq $fg"; continue; }
    [ "$fx" = - ] && fx=""
    if move_update jobid="$id" partition="$fp" qos="$fq" gres="$fg" excnodelist="$fx"; then
      rm -f "$f"; move_said "$log" "returned $id to $fp/$fq $fg: not started within ${HPCW_CHECKPOINT_RETURN:-900} s of its move"
    else
      move_said "$log" "kept $id where it was sent: Slurm refused its return to $fp/$fq: $MOVE_SAID"
    fi
  done
}

MOVE_NODES="" MOVE_AVOID="" MOVE_PROJECT="" MOVE_PROJECTS=() MOVE_DRY=0 MOVE_GAIN=300 MOVE_MOVED=0 MOVE_SAID="" MOVE_TO="" MOVE_SAVES=0 MOVE_WHY=""
job_move_running() { # DRY GAIN ONLY PROJECT...: the jobs moved at a checkpoint looked at, then this account's running placed GPU jobs
  MOVE_DRY=$1 MOVE_GAIN=$2; local only=$3; shift 3; MOVE_PROJECTS=("$@")
  [ "${HPCW_CHECKPOINT_MOVES:-on}" = off ] && return 0
  move_returns
  local rows id jname part qos cpus jmem tres node left excl looked=0
  rows=$(squeue -h -u "${USER:-$(id -un)}" -t RUNNING -o '%i|%j|%P|%q|%C|%m|%b|%N|%L|%x' 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  MOVE_NODES=$(move_nodes) MOVE_AVOID=$(job_avoid_nodes)
  while IFS='|' read -r id jname part qos cpus jmem tres node left excl; do
    # an array's task is a worker of its array's own queue, never moved; a job that holds no card has none to change
    [[ "$id" =~ ^[0-9]{1,12}$ ]] && [[ "$tres" == *gpu* ]] || continue
    [ "$only" = " " ] || case "$only" in *" $id "*) ;; *) continue;; esac
    move_held "$id" && continue
    move_look "$id" "$jname" "$part" "$qos" "$cpus" "$jmem" "$tres" "$node" "$left" "$excl" < /dev/null && looked=$((looked + 1))
  done <<< "$rows"
  echo "HPCW-JOB replace looked at $looked running job(s) just after a checkpoint, moved $MOVE_MOVED"
}
