# shellcheck shell=bash
# hpcworker framework 33: sharing a card between runs of a kind (README, "Sharing a card, and moving a running job at a
# checkpoint"). Two verbs, sourced after lib/jobs.sh, whose ledger, placement file and refusals they use:
#   job share --project P [--last K] [--kind REGEX]   each kind's measured share of its card, and how many fit one card
#   job pack --items "A B ..." [--var NAME] [--mps auto|on|off] -- COMMAND [ARG...]
#                                                    COMMAND once an item, side by side in this job, under MPS where it can
# Nothing here asks Slurm for more than the job holds: the share is read from the site's own job accounting (gres/gpumem,
# gres/gpuutil) and the card is shared by NVIDIA's MPS control daemon inside the job, the two supported means this Slurm
# offers, since it configures no shard or mps GRES.

share_kind_of() { # NAME [REGEX] -> the kind: REGEX's first match where one is given, else the name less a trailing run index
  local name=$1 re=${2:-}
  if [ -n "$re" ]; then
    printf '%s\n' "$name" | sed -n -E "s/.*($re).*/\\1/p" | head -n 1 | grep . && return 0
  fi
  printf '%s\n' "$name" | sed -E 's/(_s|_seed|_)[0-9]+$//'
}

job_share_report() {
  # One sacct over the project's last K finished jobs: each batch step's peak card memory (TRESUsageInMax gres/gpumem)
  # and mean card use (TRESUsageInAve gres/gpuutil, else the step's peak use), gathered per kind, then the forecast of
  # how many runs of the kind fit one card of each type the placement file names: by memory, the card over 1.2 times
  # the peak; by compute, HPCW_SHARE_FLOOR (0.5) of a solo run's rate kept for each, at most 1 / (use x floor); the
  # smaller, at least 1. The lines go to share.tsv beside the ledger for a caller to read without a second sacct.
  local project="" last=200 kindre=""
  while [ $# -gt 0 ]; do case "$1" in
    --project) project="${2:-}"; shift 2 || job_usage;;
    --last) last="${2:-}"; shift 2 || job_usage;;
    --kind) kindre="${2:-}"; shift 2 || job_usage;;
    *) job_usage;;
  esac; done
  [[ "$project" =~ $HPCW_JOB_PROJECT_RE ]] || die "--project is lower-case letters, digits, _ and -, at most 32"
  [[ "$last" =~ ^[1-9][0-9]{0,3}$ ]] || die "--last is 1 to 9999"
  if [ -n "$kindre" ]; then
    local said=0; printf '' | grep -E -- "$kindre" > /dev/null 2>&1 || said=$?
    [ "$said" -le 1 ] || die "--kind is an extended regular expression"
  fi
  load_profile
  local ledger ids acct pairs id name floor=${HPCW_SHARE_FLOOR:-0.5}
  ledger=$(job_ledger "$project" "$last")
  [ -n "$ledger" ] || { echo "HPCW-JOB share: none for $project"; return 0; }
  ids=$(printf '%s\n' "$ledger" | cut -f1 | paste -sd, -)
  acct=$(LC_ALL=C timeout 60 sacct -n -P -j "$ids" --format=JobID,TRESUsageInMax,TRESUsageInAve,State 2>/dev/null | tr -d '\r') \
    || { echo "HPCW-JOB share: sacct did not answer"; return 1; }
  pairs=$(printf '%s\n' "$ledger" | while IFS=$'\t' read -r id name _; do printf '%s\t%s\n' "$id" "$(share_kind_of "$name" "$kindre")"; done)
  local cards; cards=$(awk '$1 == "card" { print $2, $3 }' "$(job_place_file)" 2>/dev/null | sort -u -k1,1)
  local out; out=$(printf '%s\n' "$pairs" | ACCT="$acct" CARDS="$cards" FLOOR="$floor" LC_ALL=C awk -F'\t' '
    function mb(v,   u) { u = v; gsub(/[0-9.]/, "", u); v += 0; if (u == "K") return v / 1024; if (u == "G") return v * 1024; if (u == "T") return v * 1048576; return v }
    function field(s, key,   i, n, kv) { n = split(s, kv, ","); for (i = 1; i <= n; i++) if (index(kv[i], key "=") == 1) return substr(kv[i], length(key) + 2); return "" }
    BEGIN { n = split(ENVIRON["ACCT"], l, "\n")
      for (i = 1; i <= n; i++) { split(l[i], f, "|"); if (f[1] !~ /\.batch$/ || f[4] !~ /COMPLETED|TIMEOUT|CANCELLED|FAILED|PREEMPTED/) continue
        base = f[1]; sub(/[._].*/, "", base); m = field(f[2], "gres/gpumem"); if (m == "") continue
        # under MPS the accounting reads the card use of a run as 0 (5 November): such a run gives its memory and no use
        u = field(f[3], "gres/gpuutil"); if (u == "" || u + 0 == 0) u = field(f[2], "gres/gpuutil")
        mem[base] = mb(m) / 1024; if (u + 0 > 0) { use[base] = u + 0; used[base] = 1 } }
      nc = split(ENVIRON["CARDS"], c, "\n"); floor = ENVIRON["FLOOR"] + 0 }
    ($1 in mem) { k = $2; if (!(k in runs)) order[++nk] = k; runs[k]++; if (mem[$1] > peak[k]) peak[k] = mem[$1]; if ($1 in used) { sum[k] += use[$1]; nu[k]++ } }
    END { for (i = 1; i <= nk; i++) { k = order[i]; u = (nu[k] > 0) ? sum[k] / nu[k] : 0; fits = ""
        for (j = 1; j <= nc; j++) { split(c[j], cm, " "); if (cm[1] == "") continue
          bym = (peak[k] > 0) ? int(cm[2] / (peak[k] * 1.2)) : 1; byc = (u > 0) ? int(100 / (u * floor)) : bym
          nfit = (bym < byc) ? bym : byc; if (nfit < 1) nfit = 1; fits = fits sprintf(" %s:%d", cm[1], nfit) }
        printf "%s\t%d\t%.1f\t%.0f\t%s\n", k, runs[k], peak[k], u, substr(fits, 2) } }')
  if [ -z "$out" ]; then echo "HPCW-JOB share: no finished run of $project gathered gres/gpumem"; return 0; fi
  local d; d=$(job_dir "$project")
  ( umask 077; mkdir -p "$d" && printf '%s\n' "$out" > "$d/share.tsv.new" && mv -f "$d/share.tsv.new" "$d/share.tsv" ) 2>/dev/null
  printf '%s\n' "$out" | while IFS=$'\t' read -r kind runs peak use fits; do
    echo "HPCW-JOB share $kind runs $runs card peak ${peak}G use ${use}% fits $fits"
  done
}

PACK_PIDS=()
pack_mps_start() { # SCRATCH -> 0 when an MPS daemon now serves this job's card, its folders under SCRATCH
  [ -n "${CUDA_VISIBLE_DEVICES:-}" ] && command -v nvidia-cuda-mps-control > /dev/null 2>&1 || return 1
  mkdir -p "$1/pipe" "$1/log" || return 1
  export CUDA_MPS_PIPE_DIRECTORY=$1/pipe CUDA_MPS_LOG_DIRECTORY=$1/log
  nvidia-cuda-mps-control -d > /dev/null 2>&1
}
pack_mps_stop() { echo quit | nvidia-cuda-mps-control > /dev/null 2>&1; }
pack_wait_all() { # -> the worst exit of PACK_PIDS, each waited on until it has ended, TERM or not
  local pid r rc=0
  for pid in "${PACK_PIDS[@]}"; do
    r=0; wait "$pid" || r=$?
    while kill -0 "$pid" 2>/dev/null; do r=0; wait "$pid" || r=$?; done
    [ "$r" -le "$rc" ] || rc=$r
  done
  return "$rc"
}

job_pack() {
  # COMMAND once an item, side by side, inside the job this runs in: each child with --var's name (HPCW_PACK_ITEM) set to
  # its item and HPCW_PACK=1, its lines in the job's log with the item before them; under one MPS daemon for the job's card
  # when --mps is auto (the default) and the job holds a card and the daemon is installed, or on (refused without one);
  # Slurm's TERM passed to every child; the job's exit the worst child's.
  local items="" var=HPCW_PACK_ITEM mps=auto
  while [ $# -gt 0 ]; do case "$1" in
    --items) items="${2:-}"; shift 2 || job_usage;;
    --var) var="${2:-}"; shift 2 || job_usage;;
    --mps) mps="${2:-}"; shift 2 || job_usage;;
    --) shift; break;;
    *) job_usage;;
  esac; done
  [ $# -gt 0 ] || die "job pack runs a command: -- COMMAND [ARG...]"
  [[ "$var" =~ ^[A-Z_][A-Z0-9_]{0,63}$ ]] || die "--var is an environment variable's name, upper case"
  case "$mps" in auto|on|off) ;; *) die "--mps is auto, on or off";; esac
  local list=() it
  for it in $items; do [[ "$it" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || die "an item is letters, digits, _, . and -, at most 128: $it"; list+=("$it"); done
  [ ${#list[@]} -ge 1 ] || die "--items names at least one item"
  local scratch="${TMPDIR:-/tmp}/hpcw_pack.${SLURM_JOB_ID:-$$}" daemon=0
  if [ "$mps" != off ]; then
    if pack_mps_start "$scratch"; then daemon=1; echo "HPCW-JOB pack ${#list[@]} side by side under MPS on card ${CUDA_VISIBLE_DEVICES}"
    elif [ "$mps" = on ]; then die "--mps on: no card in this job or no nvidia-cuda-mps-control here"
    else echo "HPCW-JOB pack ${#list[@]} side by side, taking turns on the card (no MPS here)"; fi
  fi
  PACK_PIDS=()
  trap '[ ${#PACK_PIDS[@]} = 0 ] || kill -TERM "${PACK_PIDS[@]}" 2>/dev/null' TERM
  for it in "${list[@]}"; do
    env HPCW_PACK=1 "$var=$it" "$@" > >(sed -u "s/^/[$it] /") 2>&1 &
    PACK_PIDS+=("$!")
  done
  local rc=0; pack_wait_all || rc=$?
  trap - TERM
  [ $daemon = 0 ] || pack_mps_stop
  rm -rf "$scratch" 2>/dev/null
  echo "HPCW-JOB pack ended, worst exit $rc"
  return "$rc"
}
