# shellcheck shell=bash
# ---- framework 11: the site profile on the login node without python3 -----------------------------------
# Sourced by bin/hpcworker. warrior's banner bans python3 by name, and Beethoven 12.0.0 reaches the login
# node over ssh by itself (the browser key's gate, the student's own first sign-in), so nothing on that
# path may start it. lib/profile.awk reads the profile; these functions fill the job file and the
# workspace guide from what it gave, exactly as `profile.py render` and `profile.py guide` did
# (tests/test_profile_awk.py compares them byte for byte). Bash 4.2, coreutils (env, tail), awk.
#
#   hpcw_prof_awk MODE FILE [KEY]   lib/profile.awk (env | check | get) on FILE; 3 when FILE is not JSON
#   hpcw_render TEMPLATE KEY=VALUE...   the job file on stdout, for the profile load_profile read
#   hpcw_guide TEMPLATE RUN=NAME        the workspace guide (CLAUDE.md) on stdout, likewise
# Both refuse, with profile.py's words on stderr and exit 1, a profile `profile.py validate` would refuse.

hpcw_prof_awk() { # MODE FILE [KEY]
  HPCW_P_MODE="$1" HPCW_P_FILE="$2" HPCW_P_KEY="${3:-}" HPCW_P_SITEDIR="$PROFILES" LC_ALL=C awk -f "$LIB/profile.awk" < /dev/null
}
hpcw_prof_refuse() { # the profile's problems, as profile.py render and guide print them
  [ -n "${HPCW_PV_errors:-}" ] || return 1
  { printf 'profile invalid:\n'; printf '%s\n' "$HPCW_PV_errors" | sed 's/^/  /'; } >&2
  return 0
}
hpcw_pjoin() { # A B -> posixpath.join(A, B)
  case "$2" in /*) printf '%s' "$2";; *) case "$1" in ""|*/) printf '%s%s' "$1" "$2";; *) printf '%s/%s' "$1" "$2";; esac;; esac
}
hpcw_pyrepr() { printf "'%s'" "$1"; }   # a value quoted in a message (profile.py prints its repr; the words are for a person)
# KEY VALUE pairs for the substitution, in the array HPCW_SUBST, then the template with each @KEY@
# replaced once, left to right, as profile.py render() does: a placeholder with no value, or one left in
# the result, is refused. The values reach awk in an environment of their own (env -i): nothing the
# caller's environment holds can fill a placeholder.
hpcw_subst() { # TEMPLATE
  local tpl="$1" nonl=0 a
  [ -r "$tpl" ] || { echo "hpcworker: no template at $tpl" >&2; return 1; }
  [ -s "$tpl" ] && [ -n "$(tail -c1 "$tpl")" ] && nonl=1
  local -a env_args=(PATH="$PATH" LC_ALL=C HPCW_R_TPL="$tpl" HPCW_R_NONL="$nonl")
  for a in "${HPCW_SUBST[@]}"; do env_args+=("HPCW_R_$a"); done
  env -i "${env_args[@]}" awk '
    BEGIN {
      f = ENVIRON["HPCW_R_TPL"]; t = ""
      while ((r = (getline line < f)) > 0) t = t line "\n"
      if (r < 0) { print "hpcworker: cannot read " f > "/dev/stderr"; exit 1 }
      if (ENVIRON["HPCW_R_NONL"] == "1") t = substr(t, 1, length(t) - 1)
      o = ""
      while (match(t, /@[A-Z][A-Z0-9_]*@/)) {
        k = substr(t, RSTART + 1, RLENGTH - 2)
        if (!(("HPCW_R_" k) in ENVIRON) || k == "TPL" || k == "NONL") { print "unresolved placeholder @" k "@" > "/dev/stderr"; exit 1 }
        o = o substr(t, 1, RSTART - 1) ENVIRON["HPCW_R_" k]; t = substr(t, RSTART + RLENGTH)
      }
      o = o t
      if (match(o, /@[A-Z][A-Z0-9_]*@/)) { print "placeholders left after rendering: " substr(o, RSTART + 1, RLENGTH - 2) > "/dev/stderr"; exit 1 }
      printf "%s", o
    }' < /dev/null
}
hpcw_kv_parse() { # KEY=VALUE... -> HPCW_KV (an associative array the caller declared); 1 on a word with no "="
  local a
  for a in "$@"; do
    case "$a" in [!=]*=*) HPCW_KV["${a%%=*}"]="${a#*=}";; *) echo "expected KEY=VALUE, got $(hpcw_pyrepr "$a")" >&2; return 1;; esac
  done
}
hpcw_fw_version() { local v; v=$(read_version "$LIB/../VERSION") || v=1; printf '%s' "${v:-1}"; }   # profile.py framework_version()

# profile.py render(template, mapping(prof, overrides)), for the profile load_profile read
hpcw_render() { # TEMPLATE KEY=VALUE...
  local tpl="$1"; shift
  hpcw_prof_refuse && return 1
  [ -n "${HPCW_PV_note:-}" ] && printf 'profile: %s\n' "$HPCW_PV_note" >&2
  [ -z "${HPCW_M_BAD:-}" ] || { echo "hpcworker: the profile cannot fill a job file: $HPCW_M_BAD" >&2; return 1; }
  local -A HPCW_KV=()
  hpcw_kv_parse "$@" || return 1
  local run="worker"; [ -n "${HPCW_KV[RUN]+x}" ] && run="${HPCW_KV[RUN]}"
  [[ "$run" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo "run name must be letters, digits, _ or - (got $(hpcw_pyrepr "$run"))" >&2; return 1; }
  local hours="$HPCW_M_WD_HOURS" h
  if [ -n "${HPCW_KV[HOURS]+x}" ]; then
    h="${HPCW_KV[HOURS]}"; h="${h#"${h%%[![:space:]]*}"}"; h="${h%"${h##*[![:space:]]}"}"
    [[ "$h" =~ ^[-+]?[0-9]+$ ]] || { echo "HOURS must be a whole number (got $(hpcw_pyrepr "${HPCW_KV[HOURS]}"))" >&2; return 1; }
    case "$h" in -*) hours=$(( -10#${h#-} ));; *) hours=$(( 10#${h#+} ));; esac
  fi
  local sd="$HPCW_M_STATE_DIR" rundir ws
  rundir=$(hpcw_pjoin "$sd" "$run"); ws=$(hpcw_pjoin "$(hpcw_pjoin "$sd" workspaces)" "$run")
  local part="${HPCW_KV[PARTITION]:-}"; [ -n "$part" ] || part="$HPCW_M_PART_BATCH"; [ -n "$part" ] || part="$HPCW_M_PART_CPU"
  local qos
  if [ -n "${HPCW_KV[QOS]+x}" ]; then qos="${HPCW_KV[QOS]}"
  elif [ "$part" = "$HPCW_M_PART_BATCH_RAW" ]; then qos="$HPCW_M_QOS_BATCH"
  else qos="$HPCW_M_QOS_CPU"; fi
  local requeue=0
  if [ -n "${HPCW_KV[REQUEUE]+x}" ]; then requeue="${HPCW_KV[REQUEUE]}"
  elif [ -n "$qos" ] && [ "$qos" = "$HPCW_M_QOS_BATCH" ] && [ "$HPCW_M_QOS_BATCH" = requeue ]; then requeue=1; fi
  local hh="${HPCW_KV[HPCW_HOME]:-}"; [ -n "$hh" ] || hh='$HOME/.hpcworker'
  hh=$(hpcw_expand_login "$hh")
  local code="${HPCW_KV[HPCW_CODE]:-}"; [ -n "$code" ] || code=$(abs_dir "$LIB/..")
  code=$(hpcw_expand_login "$code")
  local markers; markers=$(hpcw_pjoin "$hh" consent); [ "${HPCW_M_CM_N:-0}" -gt 0 ] && markers="$HPCW_M_CM:$markers"
  local chain="1"; [ -n "${HPCW_KV[CHAIN]+x}" ] && chain="${HPCW_KV[CHAIN]}"
  case "$chain" in 0|1) ;; *) echo "CHAIN must be 0 or 1 (got $(hpcw_pyrepr "$chain"))" >&2; return 1;; esac
  local sch="$HPCW_M_SCHEDULER" time="${HPCW_KV[TIME]:-}"
  if [ -z "$time" ]; then
    local q=$(( hours / 24 )) r=$(( hours % 24 ))
    [ "$r" -lt 0 ] && { r=$(( r + 24 )); q=$(( q - 1 )); }   # python's // and %, for a negative count
    case "$sch" in slurm) time=$(printf '%d-%02d:00:00' "$q" "$r");; lsf) time="$hours:00";; *) time=$(printf '%02d:00:00' "$hours");; esac
  fi
  local cpus="$HPCW_M_WD_CPUS" mem="$HPCW_M_WD_MEM" pm="$HPCW_M_WD_PM" cap="$HPCW_M_WD_CAP"
  [ -n "${HPCW_KV[CPUS]+x}" ] && cpus="${HPCW_KV[CPUS]}"
  [ -n "${HPCW_KV[MEM]+x}" ] && mem="${HPCW_KV[MEM]}"
  [ -n "${HPCW_KV[PERMISSION_MODE]+x}" ] && pm="${HPCW_KV[PERMISSION_MODE]}"
  [ -n "${HPCW_KV[CAPACITY]+x}" ] && cap="${HPCW_KV[CAPACITY]}"
  local title="$HPCW_M_TITLE_BASE"; [ "$run" = worker ] || title="$title "$'\302\267'" $run"
  local -a m=(
    VERSION "$(hpcw_fw_version)" SITE "$HPCW_M_SITE" SCHEDULER "$sch" CHAIN "$chain" RUN "$run" JOB_NAME "hpcw_$run"
    RUN_DIR "$rundir" STATE_DIR "$sd" WORKSPACE "$ws" PARTITION "$part" QOS "$qos" CPUS "$cpus" MEM "$mem"
    HOURS "$hours" TIME "$time" REQUEUE "$requeue" NODE_TMP "$HPCW_M_NODE_TMP" NODE_TMP_VAR "$HPCW_M_NODE_TMP_VAR"
    TMPDIR_IS_NODE_LOCAL "$HPCW_M_TMPDIR_LOCAL" IPC_DIR "$HPCW_M_IPC_DIR" RUNTIME "$HPCW_M_RUNTIME"
    RUNTIME_BIN "$HPCW_M_RUNTIME_BIN" RUNTIME_MODULE "$HPCW_M_RUNTIME_MODULE" IMAGE "$HPCW_M_IMAGE"
    IMAGE_TYPE "$HPCW_M_IMAGE_TYPE" CLAUDE_BIN "$HPCW_M_CLAUDE_BIN" BINDS "$HPCW_M_BINDS"
    CLAUDE_CONFIG_DIR "$HPCW_M_CCD" CONSENT_MARKERS "$markers" EGRESS_CLASS "$HPCW_M_EGRESS_CLASS"
    EGRESS_EXPORTS "$HPCW_M_EGRESS_EXPORTS" XDG_FIX "$HPCW_M_XDG" SCHED_IN_WORKER "$HPCW_M_SIW"
    PERMISSION_MODE "$pm" CAPACITY "$cap" HEARTBEAT_S "${HPCW_KV[HEARTBEAT_S]-30}" AUTH_EVERY_S "${HPCW_KV[AUTH_EVERY_S]-300}"
    LOGIN_RECHECK_S "${HPCW_KV[LOGIN_RECHECK_S]-60}" AUTH_RETRY_S "${HPCW_KV[AUTH_RETRY_S]-10}"
    RESUME_WINDOW_S "${HPCW_KV[RESUME_WINDOW_S]-14400}" LOGIN_ABANDON_S "${HPCW_KV[LOGIN_ABANDON_S]-$HPCW_M_LAS}"
    TITLE "$title" HPCW_HOME "$hh" HPCW_CODE "$code"
  )
  # profile.py header_lines(): the scheduler's directives (Slurm is the tested path; PBS and LSF are written from their documentation)
  local acct="$HPCW_M_ACCOUNT" header nl=$'\n'
  case "$sch" in
    slurm)
      header="#SBATCH --job-name=hpcw_$run$nl#SBATCH --partition=$part"
      [ -n "$qos" ] && header="$header$nl#SBATCH --qos=$qos"
      [ -n "$acct" ] && header="$header$nl#SBATCH --account=$acct"
      header="$header$nl#SBATCH --nodes=1$nl#SBATCH --ntasks=1$nl#SBATCH --cpus-per-task=$cpus$nl#SBATCH --mem=$mem$nl#SBATCH --time=$time"
      header="$header$nl#SBATCH --output=slurm_%j.out$nl#SBATCH --open-mode=append$nl#SBATCH --signal=B:TERM@120"
      if [ "$requeue" = 1 ]; then header="$header$nl#SBATCH --requeue"; else header="$header$nl#SBATCH --no-requeue"; fi
      header="$header$nl#SBATCH --dependency=singleton";;
    pbs)
      local pmem="${mem,,}"; pmem="${pmem//g/gb}"
      header="#PBS -N hpcw_$run$nl#PBS -q $part"
      [ -n "$acct" ] && header="$header$nl#PBS -A $acct"
      header="$header$nl#PBS -l select=1:ncpus=$cpus:mem=$pmem$nl#PBS -l walltime=$time$nl#PBS -j oe$nl#PBS -o pbs.out"
      if [ "$requeue" = 1 ]; then header="$header$nl#PBS -r y"; else header="$header$nl#PBS -r n"; fi;;
    lsf)
      local lmem="${mem^^}"; lmem="${lmem//G/000}"
      header="#BSUB -J hpcw_$run$nl#BSUB -q $part"
      [ -n "$acct" ] && header="$header$nl#BSUB -P $acct"
      header="$header$nl#BSUB -n $cpus$nl#BSUB -R span[hosts=1]$nl#BSUB -M $lmem$nl#BSUB -W $time$nl#BSUB -o lsf_%J.out"
      [ "$requeue" = 1 ] && header="$header$nl#BSUB -r";;
    *) echo "no header template for scheduler $sch" >&2; return 1;;
  esac
  # a value goes into the job file inside single quotes, so none may carry a quote or a line break
  # (HEADER and EGRESS_EXPORTS are lines of their own, made here and in profile.awk from checked parts)
  local i k v
  for ((i = 0; i < ${#m[@]}; i += 2)); do
    k="${m[i]}"; v="${m[i+1]}"
    [ "$k" = EGRESS_EXPORTS ] && continue
    case "$v" in *"'"*|*$'\n'*) echo "value for $k may not contain a quote or newline: $(hpcw_pyrepr "$v")" >&2; return 1;; esac
  done
  # the account goes into the header as a line of its own: a line break in it would add a line to the job
  case "$acct" in *$'\n'*) echo "value for account may not contain a newline" >&2; return 1;; esac
  HPCW_SUBST=()
  for ((i = 0; i < ${#m[@]}; i += 2)); do HPCW_SUBST+=("${m[i]}=${m[i+1]}"); done
  HPCW_SUBST+=("HEADER=$header")
  hpcw_subst "$tpl"
}

# profile.py render(template, guide_mapping(prof, overrides)): the workspace guide, for the profile load_profile read
hpcw_guide() { # TEMPLATE RUN=NAME
  local tpl="$1"; shift
  hpcw_prof_refuse && return 1
  local -A HPCW_KV=()
  hpcw_kv_parse "$@" || return 1
  local run="worker"; [ -n "${HPCW_KV[RUN]+x}" ] && run="${HPCW_KV[RUN]}"
  [[ "$run" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || { echo "run name must be letters, digits, _ or - (got $(hpcw_pyrepr "$run"))" >&2; return 1; }
  local ws; ws=$(hpcw_pjoin "$(hpcw_pjoin "$HPCW_M_STATE_DIR" workspaces)" "$run")
  HPCW_SUBST=(
    "VERSION=$(hpcw_fw_version)" "SITE=$HPCW_M_SITE" "RUN=$run" "CLUSTER=$HPCW_G_CLUSTER" "SCHEDULER_NAME=$HPCW_G_SCHEDULER_NAME"
    "WORKSPACE=$ws" "SUBMIT=$HPCW_G_SUBMIT" "SUBMIT_EXAMPLE=$HPCW_G_SUBMIT_PRE$ws$HPCW_G_SUBMIT_POST" "SUBMITTING=$HPCW_G_SUBMITTING"
    "JOB_RESULTS=$HPCW_G_JOB_RESULTS" "LOGIN_NODE=$HPCW_G_LOGIN_NODE" "POLL_S=$HPCW_G_POLL_S" "SCHEDULING=$HPCW_G_SCHEDULING"
    "IPC=$HPCW_G_IPC" "DATA=$HPCW_G_DATA" "CLAUDE_CONFIG_DIR=$HPCW_M_CCD"
  )
  hpcw_subst "$tpl"
}
