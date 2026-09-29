#!/bin/bash
# hpcworker adapter layer: the parts every scheduler shares. Sourced, never run.
# Bash 4.2 (CentOS 7) and coreutils only; nothing here runs a container on a login node.
#
# The adapter interface (eight calls, from the design report) is implemented per scheduler
# in slurm.sh, pbs.sh and lsf.sh, which source this file:
#   adapter_detect_scheduler        -> family on stdout (slurm|pbs|lsf|sge|htcondor|unknown)
#   adapter_detect_runtime [full]   -> JSON on stdout; never execs a container
#   adapter_submit SCRIPT [OPT...]  -> job id on stdout
#   adapter_status ID               -> STATE|NODE|RAW  (STATE in PENDING RUNNING DONE FAILED UNKNOWN)
#   adapter_cancel ID...            -> one scheduler call for every id given
#   adapter_attach ID               -> a shell inside the job (best effort; sites disable it)
#   adapter_node_tmp                -> the node-local directory for this job (inside the job)
#   adapter_runtime_exec IMAGE CMD..-> run CMD inside IMAGE (inside a job only)
# plus the conveniences the CLI and the worker job need:
#   adapter_interactive PART QOS TIME NAME MEM -- CMD...   a short allocation with a terminal
#   adapter_run_short   PART QOS TIME NAME MEM -- CMD...   the same without a terminal
#   adapter_status_many ID[,ID...]  -> one line per id: ID|STATE|NODE|RAW, in ONE scheduler call where the scheduler allows it
#   adapter_submit_after SCRIPT PARENT_ID [OPT...] -> id of a job the scheduler starts when PARENT_ID has ended (the always-on chain)

# every path pattern here carries $USER; a shell without it (Git Bash on a Windows checkout) gets the login name
: "${USER:=$(id -un 2>/dev/null || echo unknown)}"

hpcw_detect_scheduler() {
  # sbatch first: Slurm sites ship a qsub wrapper (Wayne State has /usr/bin/qsub), so the
  # presence of qsub proves nothing until sbatch is ruled out.
  if command -v sbatch >/dev/null 2>&1 && command -v squeue >/dev/null 2>&1; then echo slurm; return 0; fi
  if command -v bsub >/dev/null 2>&1 && command -v bjobs >/dev/null 2>&1; then echo lsf; return 0; fi
  if command -v condor_submit >/dev/null 2>&1; then echo htcondor; return 0; fi
  if command -v qsub >/dev/null 2>&1; then
    if [ -n "${SGE_ROOT:-}" ] || qsub -help 2>&1 | grep -q -- '-terse'; then echo sge; return 0; fi
    echo pbs; return 0
  fi
  echo unknown; return 1
}

hpcw_json_esc() { # VAR : escape the value of VAR in place for use inside a JSON string; no fork unless a control character needs removing
  # the local has a name no caller uses: printf -v assigns to the nearest variable of that name up the call stack
  local _hpcw_e="${!1}"
  case "$_hpcw_e" in *[[:cntrl:]]*) _hpcw_e=$(printf '%s' "$_hpcw_e" | tr -d '\000-\010\013\014\016-\037' | tr '\n' ' ');; esac
  _hpcw_e=${_hpcw_e//\\/\\\\}; _hpcw_e=${_hpcw_e//\"/\\\"}; _hpcw_e=${_hpcw_e//$'\t'/\\t}; _hpcw_e=${_hpcw_e//$'\r'/}
  printf -v "$1" '%s' "$_hpcw_e"
}
hpcw_json_str() { # escape one string for JSON and print it quoted (the in-place form above is for loops that must not fork)
  local _hpcw_s="$1"; hpcw_json_esc _hpcw_s; printf '"%s"' "$_hpcw_s"
}

hpcw_detect_runtime() { # [full]
  # Phase-1 discovery on the login node: which runtimes exist, by name and by module, whether
  # Pyxis is compiled into srun, and whether user namespaces are allowed. No container exec.
  # The module list comes from the modulefile directories on $MODULEPATH (a glob, 4 ms measured
  # on warrior); `module -t avail`, which costs 0.76 s of CPU there, runs only with "full".
  local full="${1:-}" first=1 c p
  printf '{"candidates":['
  local ul
  while IFS= read -r p; do
    [ -n "$p" ] || continue; c=${p##*/}
    [ $first = 1 ] || printf ','; first=0
    ul=false; [ "${p#"$HOME"/.local/}" != "$p" ] && ul=true
    hpcw_json_esc p; printf '{"name":"%s","path":"%s","user_local":%s}' "$c" "$p" "$ul"
  done < <(command -v apptainer singularity podman enroot 2>/dev/null)
  printf '],"modules":['
  first=1
  local mods=""
  if [ "$full" = full ]; then
    # `module` is a shell function from /etc/profile.d; source just that file rather than a whole login shell
    mods=$(timeout 8 bash -c 'for f in /etc/profile.d/modules.sh /etc/profile.d/lmod.sh /usr/share/Modules/init/bash; do [ -r "$f" ] && { source "$f"; break; }; done 2>/dev/null; command -v module >/dev/null 2>&1 || exit 0; module -t avail 2>&1' 2>/dev/null | grep -i -E '^(apptainer|singularity|podman|enroot|pyxis)' | grep -v '/$' | sed 's/(default)//' | sort -u)
  else
    local d f name mp="${MODULEPATH:-}"; for d in ${mp//:/ }; do for f in "$d"/apptainer/* "$d"/singularity/* "$d"/podman/* "$d"/enroot/* "$d"/pyxis/*; do
      [ -e "$f" ] || continue; name="${f#"$d"/}"; case "$name" in *~|.*|*/.*) continue;; esac; mods="$mods${mods:+$'\n'}$name"; done; done
    [ -n "$mods" ] && mods=$(printf '%s\n' "$mods" | sort -u)
  fi
  for c in $mods; do [ $first = 1 ] || printf ','; first=0; hpcw_json_esc c; printf '"%s"' "$c"; done
  local pyx=false; [ "$full" = full ] && command -v srun >/dev/null 2>&1 && srun --help 2>/dev/null | grep -q 'container-image' && pyx=true
  local ns; ns=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo -1)
  printf '],"pyxis":%s,"user_namespaces":%s,"subuid":%s,"modules_from":"%s"}' "$pyx" "$ns" "$( [ -r /etc/subuid ] && grep -q "^$USER:" /etc/subuid 2>/dev/null && echo true || echo false)" "$([ "$full" = full ] && echo module-avail || echo modulepath)"
}

hpcw_job_id() { echo "${SLURM_JOB_ID:-${PBS_JOBID:-${LSB_JOBID:-${JOB_ID:-${HPCW_JOB_ID:-}}}}}"; }

hpcw_expand_job_vars() { # controlled expansion of the few variables a profile path may use (no eval)
  local s="$1" jid; jid=$(hpcw_job_id)
  s=${s//\$\{USER\}/$USER}; s=${s//\$USER/$USER}
  s=${s//\$\{HOME\}/$HOME}; s=${s//\$HOME/$HOME}
  local v; for v in SLURM_JOB_ID PBS_JOBID LSB_JOBID HPCW_JOB_ID; do s=${s//\$\{$v\}/$jid}; s=${s//\$$v/$jid}; done
  if [ -n "${SLURM_TMPDIR:-}" ]; then s=${s//\$\{SLURM_TMPDIR\}/$SLURM_TMPDIR}; s=${s//\$SLURM_TMPDIR/$SLURM_TMPDIR}; fi
  if [ -n "${L_SCRATCH:-}" ]; then s=${s//\$\{L_SCRATCH\}/$L_SCRATCH}; s=${s//\$L_SCRATCH/$L_SCRATCH}; fi
  if [ -n "${TMPDIR:-}" ]; then s=${s//\$\{TMPDIR\}/$TMPDIR}; s=${s//\$TMPDIR/$TMPDIR}; fi
  printf '%s' "$s"
}

hpcw_node_tmp() {
  # Node-local temp, resolved inside the job. Order: the profile's pattern (HPCW_NODE_TMP_PATTERN),
  # the site's variable (HPCW_NODE_TMP_VAR, e.g. SLURM_TMPDIR), $TMPDIR only when the profile says it
  # is node-local (Wayne State's is CephFS), an Expanse-style /scratch/$USER/job_<id>, then /tmp.
  local jid; jid=$(hpcw_job_id); jid=${jid:-local}
  local pat="${HPCW_NODE_TMP_PATTERN:-}" var="${HPCW_NODE_TMP_VAR:-}"
  if [ -n "$pat" ]; then hpcw_expand_job_vars "$pat"; echo; return 0; fi
  if [ -n "$var" ] && [ -n "${!var:-}" ]; then echo "${!var}/${USER}/hpcworker_$jid"; return 0; fi
  if [ "${HPCW_TMPDIR_IS_NODE_LOCAL:-0}" = 1 ] && [ -n "${TMPDIR:-}" ]; then echo "$TMPDIR/hpcworker_$jid"; return 0; fi
  if [ -d "/scratch/$USER" ] && [ -w "/scratch/$USER" ]; then echo "/scratch/$USER/hpcworker_$jid"; return 0; fi
  echo "/tmp/$USER/hpcworker_$jid"
}

hpcw_rm_own_tmp() { # PATH... : remove ONLY directories the framework made for one job (node-local temp, /dev/shm IPC).
  # The one place the framework deletes anything. A path is removed only when its last component is
  # hpcworker_<id>, hpcw_<id> or hpcw_probe_<id>, so a mis-rendered pattern can never point this at a
  # home directory, a config directory, a state directory or the root.
  local p; for p in "$@"; do
    [ -n "$p" ] || continue
    case "$p" in /|"$HOME"|"$HOME"/|/tmp|/dev/shm|"${HOME}/.ashley"*|*/.claude*|*/.hpcworker*) echo "REFUSING to remove $p (not a per-job directory)" >&2; continue;; esac
    case "${p%/}" in */hpcworker_[A-Za-z0-9_.-]*|*/hpcw_[A-Za-z0-9_.-]*) rm -rf -- "${p%/}";; *) echo "REFUSING to remove $p (not a per-job directory)" >&2;; esac
  done
}

hpcw_agent_marker() { # 0 when an agent, not a person, is at the keyboard: CLAUDECODE, ASHLEY_REQUEST_ID and kin, or no terminal
  [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${ASHLEY_REQUEST_ID:-}" ] || [ -n "${ASHLEY_JOB:-}" ] || [ -n "${HPCW_AGENT:-}" ] || [ ! -t 0 ]
}

hpcw_strip_codes() { # stdin -> stdout: a terminal transcript without escape sequences, NULs or carriage returns
  # LC_ALL=C: under en_US.UTF-8, sed 4.2.2 (CentOS 7) matches none of the CSI sequences, because the
  # byte range in the bracket expression follows the locale's collation (measured on warrior, 2026-09-29)
  tr -d '\000' | LC_ALL=C sed -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' -e 's/\x1b[()][A-Za-z0-9]//g' -e 's/\r//g'
}

hpcw_parse_registration() { # stdin: Claude Code's terminal text, codes stripped -> NAME|URL|ENVIRONMENT_ID (empty when not printed yet)
  # `claude remote-control` (2.1.283) prints, after the QR code:
  #     ·✔︎· Connected · phone · HEAD
  #         Capacity: 1/32 · New sessions will be created in the current directory
  #         asx10-hazy-meadow
  #     Continue coding in the Claude mobile app or https://claude.ai/code?environment=env_01XzAN32jsbL8W1PAFSvitBt
  # The session name is the line after "Capacity:"; the link is the environment URL. The block may be
  # redrawn, so the last occurrence of each wins.
  awk '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    /Capacity:/ { want = 1; next }
    want == 1 && line == "" { next }
    want == 1 { if (line ~ /^[a-z0-9]+(-[a-z0-9]+)+$/) name = line; want = 0 }
    { if (match(line, /https:\/\/claude\.ai\/code\?environment=[A-Za-z0-9_-]+/)) url = substr(line, RSTART, RLENGTH) }
    END { id = url; sub(/.*environment=/, "", id); printf "%s|%s|%s\n", name, url, id }'
}

hpcw_consent_seen() { # CLAUDE_CONFIG_DIR -> 0 when Claude Code itself recorded the student's answer to "Enable Remote Control?"
  # Claude Code writes "remoteDialogSeen": true into <config dir>/.claude.json when the student answers.
  # That one boolean is the consent signal; nothing else in that file is read (grep -q prints nothing).
  [ -n "${1:-}" ] && grep -q -E '"remoteDialogSeen": *true' "$1/.claude.json" 2>/dev/null
}

hpcw_workspace_trusted() { # CLAUDE_CONFIG_DIR WORKSPACE -> 0 when projects[WORKSPACE].hasTrustDialogAccepted is true (python3 reads the two keys)
  local py; for py in "${HPCW_PYTHON:-}" python3 /usr/bin/python3 /usr/libexec/platform-python; do [ -n "$py" ] && command -v "$py" >/dev/null 2>&1 && break; py=""; done
  [ -n "$py" ] || return 1
  "$py" - "$1/.claude.json" "$2" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        j = json.load(fh)
    ok = ((j.get("projects") or {}).get(sys.argv[2]) or {}).get("hasTrustDialogAccepted") is True
except (OSError, ValueError, AttributeError):
    ok = False
sys.exit(0 if ok else 1)
PYEOF
}

hpcw_load_runtime() {
  # Make $RUNTIME_BIN executable: the configured path, else the module, else PATH. Login nodes
  # may hide the module (TACC); that is why the probe job, not discovery, is the arbiter.
  if [ -n "${RUNTIME_BIN:-}" ] && [ -x "$RUNTIME_BIN" ]; then return 0; fi
  if [ -n "${RUNTIME_MODULE:-}" ]; then
    [ -f /etc/profile.d/modules.sh ] && source /etc/profile.d/modules.sh 2>/dev/null
    [ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh 2>/dev/null
    if command -v module >/dev/null 2>&1; then module load "$RUNTIME_MODULE" >/dev/null 2>&1 || true; fi
  fi
  local b; b=$(command -v "${RUNTIME:-apptainer}" 2>/dev/null) || b=""
  [ -n "$b" ] && RUNTIME_BIN="$b"
  [ -n "${RUNTIME_BIN:-}" ] && [ -x "$RUNTIME_BIN" ]
}

hpcw_runtime_exec() {
  # Run a command inside the image, inside a job. Reads: RUNTIME, RUNTIME_BIN, HPCW_BINDS (a
  # string of "-B a -B b"), HPCW_NODE_TMP (its tmp/ becomes the container's /tmp and holds the
  # runtime's own temp and cache), HPCW_NV (--nv or empty). Refuses outside a job.
  local image="$1"; shift
  [ -n "$(hpcw_job_id)" ] || { echo "REFUSING: container commands run only inside a job, not on $(hostname -s)" >&2; return 97; }
  local nt="${HPCW_NODE_TMP:-}"; [ -n "$nt" ] || nt=$(hpcw_node_tmp)
  mkdir -p "$nt/tmp" "$nt/cache" 2>/dev/null || { echo "REFUSING: cannot create node-local temp $nt" >&2; return 98; }
  # shellcheck disable=SC2206
  local binds=(${HPCW_BINDS:-})
  case "${RUNTIME:-apptainer}" in
    apptainer|singularity)
      hpcw_load_runtime || { echo "REFUSING: no ${RUNTIME:-apptainer} runtime on $(hostname -s)" >&2; return 99; }
      APPTAINER_TMPDIR="$nt/tmp" SINGULARITY_TMPDIR="$nt/tmp" APPTAINER_CACHEDIR="$nt/cache" SINGULARITY_CACHEDIR="$nt/cache" \
        "$RUNTIME_BIN" exec ${HPCW_NV:-} ${binds[@]+"${binds[@]}"} -B "$nt/tmp:/tmp" "$image" "$@";;
    podman)
      # rootless Podman (FASRC, OSC): documented form, not run on a real site by this build
      local vols=() b; for b in ${binds[@]+"${binds[@]}"}; do [ "$b" = -B ] && continue; vols+=(-v "${b%%:*}:${b#*:}"); done
      podman run --rm --userns=keep-id ${vols[@]+"${vols[@]}"} -v "$nt/tmp:/tmp" "$image" "$@";;
    pyxis)
      # Enroot/Pyxis via srun (Sherlock, Penn): documented form, not run on a real site by this build
      local m="" b; for b in ${binds[@]+"${binds[@]}"}; do [ "$b" = -B ] && continue; m="${m:+$m,}$b"; done
      srun --overlap -N1 -n1 --container-image="$image" ${m:+--container-mounts="$m,$nt/tmp:/tmp"} "$@";;
    *) echo "REFUSING: unknown runtime ${RUNTIME:-}" >&2; return 99;;
  esac
}

hpcw_normalise_state() { # FAMILY RAWSTATE [EXIT] -> PENDING|RUNNING|DONE|FAILED|UNKNOWN
  local fam="$1" raw="$2" ex="${3:-}"
  case "$fam" in
    slurm) case "${raw%%+*}" in
      PENDING|PD|CONFIGURING|CF|REQUEUED|RQ|REQUEUE_HOLD|RH|REQUEUE_FED|RF|SUSPENDED|S|RESIZING|RS|RESV_DEL_HOLD|RD|SIGNALING|SI|STAGE_OUT|SO|STOPPED|ST) echo PENDING;;
      RUNNING|R|COMPLETING|CG) echo RUNNING;;
      COMPLETED|CD) echo DONE;;
      CANCELLED*|CA|FAILED|F|TIMEOUT|TO|NODE_FAIL|NF|PREEMPTED|PR|OUT_OF_MEMORY|OOM|BOOT_FAIL|BF|DEADLINE|DL|REVOKED|RV|SPECIAL_EXIT|SE) echo FAILED;;
      "") echo UNKNOWN;;
      *) echo UNKNOWN;;
    esac;;
    pbs) case "$raw" in
      Q|H|W|T|S|M) echo PENDING;;
      R|E|B|X) echo RUNNING;;
      F) if [ "${ex:-1}" = 0 ]; then echo DONE; else echo FAILED; fi;;
      *) echo UNKNOWN;;
    esac;;
    lsf) case "$raw" in
      PEND|PSUSP|WAIT|PROV) echo PENDING;;
      RUN|USUSP|SSUSP) echo RUNNING;;
      DONE) echo DONE;;
      EXIT|ZOMBI) echo FAILED;;
      *) echo UNKNOWN;;
    esac;;
    *) echo UNKNOWN;;
  esac
}

# the names the CLI calls, shared by every adapter
adapter_detect_scheduler() { hpcw_detect_scheduler; }
adapter_detect_runtime() { hpcw_detect_runtime "$@"; }
adapter_node_tmp() { hpcw_node_tmp; }
adapter_runtime_exec() { hpcw_runtime_exec "$@"; }
# a scheduler without a one-call form answers several ids one by one (PBS, LSF); Slurm overrides this
adapter_status_many() { local id; for id in ${1//,/ }; do printf '%s|%s\n' "$id" "$(adapter_status "$id" 2>/dev/null || echo 'UNKNOWN||')"; done; }
