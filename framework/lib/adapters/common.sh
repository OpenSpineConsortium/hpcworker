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
    case "$p" in /|"$HOME"|"$HOME"/|/tmp|/dev/shm|"${HOME}/.beethoven"*|"${HOME}/.ashley"*|*/.claude*|*/.hpcworker*) echo "REFUSING to remove $p (not a per-job directory)" >&2; continue;; esac
    case "${p%/}" in */hpcworker_[A-Za-z0-9_.-]*|*/hpcw_[A-Za-z0-9_.-]*) rm -rf -- "${p%/}";; *) echo "REFUSING to remove $p (not a per-job directory)" >&2;; esac
  done
}

# a person's terminal on stdin; a function of its own so the unit tests, which run without one, can stand in for it
hpcw_have_terminal() { [ -t 0 ]; }
# 0 when an agent's own variables are set: CLAUDECODE, the request and worker a Beethoven for VS Code
# worker sets in Claude's shell (BEETHOVEN_REQUEST_ID and kin, and the ASHLEY_ twins it still sets for
# older readers: its names before 2026-09-30)
hpcw_agent_env() {
  [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${BEETHOVEN_REQUEST_ID:-}" ] || [ -n "${BEETHOVEN_WORKER:-}" ] \
    || [ -n "${ASHLEY_REQUEST_ID:-}" ] || [ -n "${ASHLEY_WORKER:-}" ] || [ -n "${ASHLEY_JOB:-}" ] || [ -n "${HPCW_AGENT:-}" ]
}
# 0 when an agent, not a person, is at the keyboard: an agent's variables, or no terminal
hpcw_agent_marker() { hpcw_agent_env || ! hpcw_have_terminal; }
# framework 11: 0 under the browser key's forced command. `hpcworker gate` is the only way a browser key
# reaches this tool, and it hands every verb on with HPCW_GATE=1 (an environment of its own: the client
# cannot unset it); version, read and forget it answers itself. browser-key and the Remote Control record
# go by this test alone: SSH_ORIGINAL_COMMAND, which sshd sets for any forced command (a site's own
# ForceCommand too), would refuse the student's own first sign-in at such a site.
hpcw_under_gate() { [ -n "${HPCW_GATE:-}" ]; }
# 0 where no Claude sign-in may start: under the gate, and, as a second wall, under any forced command at
# all (no site this tool knows forces one for every session; one that did would have the sign-in refused)
hpcw_signin_barred() { [ -n "${HPCW_GATE:-}" ] || [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; }

# ---- framework 10: times and the run's progress log ------------------------------------------------
hpcw_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hpcw_iso_epoch() { # ISO-8601 (or anything GNU date reads) -> seconds since the epoch; nothing when unreadable
  [ -n "${1:-}" ] || return 1
  date -u -d "$1" +%s 2>/dev/null
}
hpcw_local_time_utc() { # a scheduler's own time (local, no zone: Slurm's 2026-10-01T09:12:00) -> ISO-8601 UTC; nothing for N/A, Unknown, None or an unreadable value
  local e
  case "${1:-}" in ""|None|Unknown|N/A|"(null)") return 0;; esac
  e=$(date -d "$1" +%s 2>/dev/null) || return 0
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
  return 0
}
# progress.log: "<YYYY-MM-DDTHH:MM:SSZ> <sentence>", one line per event, appended with one write
# (O_APPEND), from a fixed set of sentences (the extension's contract.ts PROGRESS). Three writers
# append to it (worker start, the job, worker status for a request the grid dropped); none reads it
# back but the person and the extension. A sentence is one line: line breaks become spaces.
hpcw_progress() { # RUN_DIR SENTENCE
  local s="${2//$'\n'/ }"; s="${s//$'\r'/}"
  printf '%s %s\n' "$(hpcw_now_iso)" "${s:0:400}" >> "$1/progress.log" 2>/dev/null
  return 0
}
hpcw_progress_trim() { # RUN_DIR: keep the last 400 lines (a temporary file, then a rename); worker start runs it before it appends
  local f="$1/progress.log" n
  [ -s "$f" ] || return 0
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' '); [ "${n:-0}" -gt 400 ] 2>/dev/null || return 0
  tail -n 399 "$f" > "$f.trim.$$" 2>/dev/null && mv -f "$f.trim.$$" "$f" || rm -f "$f.trim.$$"
  return 0
}

hpcw_strip_codes() { # stdin -> stdout: a terminal transcript without escape sequences, NULs or carriage returns
  # LC_ALL=C: under en_US.UTF-8, sed 4.2.2 (CentOS 7) matches none of the CSI sequences, because the
  # byte range in the bracket expression follows the locale's collation (measured on warrior, 2026-09-29).
  # The CSI expression uses | as its delimiter so its intermediate bytes are written [ -/] (space to slash,
  # 0x20-0x2F). Framework 13 and older wrote [ -\/] inside s/.../: in a bracket expression a backslash is a
  # literal, so GNU sed read the range as space to backslash (0x20-0x5C), and a sequence ending in a capital
  # letter (ESC[K, ESC[G, ESC[1C, ESC[1A) took the next character with it as its final byte: "or ESC[K https://"
  # lost the h, so the link was missed, and a name after ESC[2K lost its first letter (sed 4.8 and 4.9, 2026-10-03)
  tr -d '\000' | LC_ALL=C sed -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's|\x1b\[[0-9;?]*[ -/]*[@-~]||g' -e 's/\x1b[()][A-Za-z0-9]//g' -e 's/\r//g'
}

hpcw_complete_lines() { # stdin -> stdout: only the lines that end in a newline; a last line still being written (no newline yet) is left out
  # bash builtins only. A NUL would end the read early, so this runs after hpcw_strip_codes, which removes them
  local t=""
  IFS= read -r -d '' t || true
  case "$t" in
    *$'\n') printf '%s' "$t";;
    *$'\n'*) printf '%s\n' "${t%$'\n'*}";;
  esac
  return 0
}

hpcw_parse_registration() { # stdin: Claude Code's terminal text, codes stripped -> NAME|ENVIRONMENT_URL|ENVIRONMENT_ID|LINK (each empty when not printed yet)
  # `claude remote-control` (2.1.283) prints, after the QR code, for a fresh registration:
  #     ·✔︎· Connected · phone · HEAD
  #         Capacity: 1/32 · New sessions will be created in the current directory
  #         asx10-hazy-meadow
  #     Continue coding in the Claude mobile app or https://claude.ai/code?environment=env_01XzAN32jsbL8W1PAFSvitBt
  # and, framework 14, when it resumes an earlier session (--continue; go2432's job 40554211, 2026-10-03):
  #     Resuming session session_01N4R9mLRJ5wFbf1oaDe5pyj (43m ago)
  #     Single session · exits when complete
  #     Continue coding in the Claude mobile app or https://claude.ai/code/session_01N4R9mLRJ5wFbf1oaDe5pyj
  # The session name is the line after "Capacity:". A link is either form, on claude.ai or claude.com,
  # from whatever line it is on: ENVIRONMENT_URL is the last environment link, LINK the last link of either
  # form (the one Claude Code's screen offers now). The block may be redrawn, so the last occurrence wins.
  # Only complete lines are read (hpcw_complete_lines): a last line with no newline yet may be a link cut
  # mid-write, https://claude.ai/code/session_01N4 of a longer id, which the pattern would take whole.
  hpcw_complete_lines | awk '
    { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
    /Capacity:/ { want = 1; next }
    want == 1 && line == "" { next }
    want == 1 { if (line ~ /^[a-z0-9]+(-[a-z0-9]+)+$/) name = line; want = 0 }
    {
      rest = line
      while (match(rest, /https:\/\/claude\.(ai|com)\/code(\?environment=[A-Za-z0-9_-]+|\/session_[A-Za-z0-9_-]+)/)) {
        u = substr(rest, RSTART, RLENGTH); link = u
        if (u ~ /\?environment=/) env = u
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    END { id = env; sub(/.*environment=/, "", id); printf "%s|%s|%s|%s\n", name, env, id, link }'
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

hpcw_needs() { # STATE CONSENT(true|false) -> login|consent|nothing : the one thing the student must do now, for the panel's one line
  # login only once the job has said so (the first checks retry for a credential still being written);
  # consent as soon as it is missing while the job is on its way, so the panel can write the marker
  # before Claude Code asks; nothing while the job is still in line (framework 10's "queued")
  case "$1" in
    need_login) echo login;;
    need_consent) echo consent;;
    starting|running) [ "$2" = true ] && echo nothing || echo consent;;
    *) echo nothing;;
  esac
}

hpcw_hint() { # STATE NEEDS [NEXT_JOB] -> one sentence in plain words
  case "$2" in
    login) echo "Sign in to Claude on the cluster; your worker is waiting for it.";;
    consent) echo "Allow Remote Control once; your worker is waiting for that answer.";;
    *) case "$1" in
      online) echo "Your worker is online: open it in Claude.";;
      queued) echo "Your worker is in line for a computer.";;
      # framework 10: no promise of "about a minute"; the extension tells the wait from status.json
      starting) echo "Your worker has a computer and is connecting to Claude.";;
      running) echo "Claude Code is running; waiting for its session link.";;
      stopped) echo "Your worker is stopped; start it again when you need it.";;
      preempted) if [ -n "${3:-}" ]; then echo "This job ended; the next one takes over shortly."; else echo "This job ended; start the worker again to continue."; fi;;
      error) echo "Something went wrong; the message says what.";;
      *) echo "Waiting for the worker.";;
    esac;;
  esac
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

# ---- framework 10: the one-time grid key out of Claude Code's reach --------------------------------------
# `hpcworker login-setup` (AM2) leaves ~/.ssh/beethoven_ed25519 in the student's home: a key with no
# passphrase that the portal's own server may use. Claude Code in the worker runs in a container that
# sees the home, so a prompt that tricked it into printing ~/.ssh would put that key in a chat. An empty
# file of this job's own is bound over it inside the container (a file over a file, as the Slurm binds
# below do with /etc/passwd); the key itself is untouched on the host and still serves the portal's
# terminal. Only when the key exists and a bind of the home (or a folder above it) makes it visible.
#   hpcw_hide_login_key "BINDS" NODE_TMP -> the extra "-B empty:key:ro" to append, or nothing
hpcw_hide_login_key() {
  local binds="$1" nt="$2" key="${HOME:-}/.ssh/beethoven_ed25519" b dst seen=0 covered=0
  [ -n "${HOME:-}" ] && [ -f "$key" ] && [ -n "$nt" ] || return 0
  for b in $binds; do
    if [ "$b" = -B ] || [ "$b" = --bind ]; then seen=1; continue; fi
    [ $seen = 1 ] || continue
    # shlex quoting from the render ('…') comes off; a bind is SRC or SRC:DST or SRC:DST:OPTS
    seen=0; b=${b//\'/}; dst="${b#*:}"; [ "$dst" = "$b" ] && dst="$b"; dst="${dst%%:*}"; dst="${dst%/}"
    case "$key" in "$dst"/*) covered=1;; esac
  done
  [ $covered = 1 ] || return 0
  if [ ! -e "$nt/no-login-key" ]; then ( umask 077; : > "$nt/no-login-key" ) 2>/dev/null && chmod 400 "$nt/no-login-key" 2>/dev/null || return 0; fi
  [ -f "$nt/no-login-key" ] && [ ! -s "$nt/no-login-key" ] || return 0
  printf -- '-B %s:%s:ro' "$nt/no-login-key" "$key"
}

# ---- the host's Slurm client inside the worker's container (profile: scheduler_in_worker) ----------
# The container has no scheduler of its own. The host's client works inside it with these binds,
# measured at Wayne State on asx1 (2026-09-28, Apptainer 1.2.2, the Debian bookworm sandbox the
# workers use; the lab's VS Code tool has bound them since): /usr/bin under /opt/host/bin (never all
# of it on PATH), /usr/lib64/slurm (libslurmfull and the plugins), the munge library into /usr/lib (a
# default search folder, so no LD_LIBRARY_PATH is needed), /etc/slurm, the munge socket's folder, and
# an /etc/passwd and /etc/group that add the users slurm.conf names (without the slurm user: "Invalid
# user for SlurmUser slurm", then "Unable to process configuration file"). Small wrappers run each
# client with the host's PATH, LD_LIBRARY_PATH and TMPDIR and without the container's variables or
# the worker job's own SLURM_ ones, so a job submitted from inside runs on the host as if submitted
# from a terminal (it would otherwise start with the container's LD_LIBRARY_PATH, /.singularity.d/libs,
# and without the person's module libraries: seen in check job 40518457; and a worker's
# SLURM_CPUS_PER_TASK or SLURM_MEM_PER_NODE left in a new job would steer its srun). A library path
# the host sees but the container does not is simply absent inside, so the client loads what the
# host's own copy loads, or the container's newer system library. Everything is read-only except the
# socket, and written under DIR (the job's /dev/shm directory: node-local, never swept, removed with
# the job). scontrol is left out: the host's needs libreadline.so.6, which the bookworm image does not
# have ("error while loading shared libraries", check job 40518457 on asx1, 2026-09-30); squeue and
# sacct answer what a worker needs to know about a job.
HPCW_SLURM_CMDS="sbatch squeue scancel sacct sinfo"
HPCW_SLURM_INSIDE=/opt/hpcw/slurm/bin   # the wrappers, as the container sees them
hpcw_getent() { getent "$@"; }          # a function, so the tests can stand in for the host's user list
hpcw_slurm_in_container() { # DIR IMAGE IMAGE_TYPE -> 0 with HPCW_SLURM_BINDS set, or 1; HPCW_SLURM_NOTE says which in one sentence
  # HPCW_HOST_ROOT (empty on a cluster) prefixes every host path, for the tests only
  local dir="${1%/}" image="$2" itype="${3:-sandbox}" r="${HPCW_HOST_ROOT:-}" node miss="" c lib sock conf su users own
  HPCW_SLURM_BINDS=""; HPCW_SLURM_NOTE=""
  node=$(hostname -s 2>/dev/null || echo "this node")
  case "$dir$r" in *[[:space:]]*) HPCW_SLURM_NOTE="not bound: the folder $dir has a space in its name, which a bind list cannot carry"; return 1;; esac
  [ -x "$r/usr/bin/sbatch" ] && [ -x "$r/usr/bin/squeue" ] || miss="$miss /usr/bin/sbatch"
  [ -d "$r/usr/lib64/slurm" ] || miss="$miss /usr/lib64/slurm"
  [ -d "$r/etc/slurm" ] || miss="$miss /etc/slurm"
  lib=$(readlink -f "$r/usr/lib64/libmunge.so.2" 2>/dev/null) || lib=""
  [ -n "$lib" ] && [ -f "$lib" ] || { lib=""; miss="$miss /usr/lib64/libmunge.so.2"; }
  sock=""; for c in "$r/var/run/munge" "$r/run/munge"; do [ -d "$c" ] && { sock="$c"; break; }; done
  [ -n "$sock" ] || miss="$miss /var/run/munge"
  # the account slurm.conf runs the daemons as (SlurmUser; Slurm's own default is root), plus munge and this user
  conf="$r/etc/slurm/slurm.conf"; su=""
  [ -r "$conf" ] && su=$(sed -n 's/^[[:space:]]*[Ss][Ll][Uu][Rr][Mm][Uu][Ss][Ee][Rr][[:space:]]*=[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p' "$conf" | head -1)
  users="${su:-slurm} munge $USER"
  [ "${su:-slurm}" = root ] || hpcw_getent passwd "${su:-slurm}" >/dev/null 2>&1 || miss="$miss the ${su:-slurm} user"
  if [ -n "$miss" ]; then HPCW_SLURM_NOTE="not available: missing on $node:$miss"; return 1; fi
  # the container's own user list first (a name it has keeps its entry), then the host's for the rest
  if [ "$itype" = sandbox ]; then own=$(cat "$image/etc/passwd" 2>/dev/null) || own=""
  else own=$(hpcw_runtime_exec "$image" cat /etc/passwd 2>/dev/null) || own=""; fi
  [ -n "$own" ] || { HPCW_SLURM_NOTE="not available: the container's /etc/passwd could not be read ($image)"; return 1; }
  mkdir -p "$dir/bin" "$dir/etc" && chmod 700 "$dir" || { HPCW_SLURM_NOTE="not available: cannot create $dir on $node"; return 1; }
  # shellcheck disable=SC2086
  { printf '%s\n' "$own"; hpcw_getent passwd $users; } | awk -F: 'NF && !seen[$1]++' > "$dir/etc/passwd.part" || return 1
  if [ "$itype" = sandbox ]; then own=$(cat "$image/etc/group" 2>/dev/null) || own=""
  else own=$(hpcw_runtime_exec "$image" cat /etc/group 2>/dev/null) || own=""; fi
  # shellcheck disable=SC2086
  { printf '%s\n' "$own"; hpcw_getent group ${su:-slurm} munge "$(id -gn 2>/dev/null)"; } | awk -F: 'NF && !seen[$1]++' > "$dir/etc/group.part" || return 1
  chmod 644 "$dir/etc/passwd.part" "$dir/etc/group.part" && mv -f "$dir/etc/passwd.part" "$dir/etc/passwd" && mv -f "$dir/etc/group.part" "$dir/etc/group" || return 1
  # the wrappers: the environment a submitted job starts from is the host's, as this job had it
  local path_q tmp_q ld_q have=""
  path_q=$(printf %q "$PATH"); tmp_q=$(printf %q "${HPCW_HOST_TMPDIR:-}"); ld_q=$(printf %q "${LD_LIBRARY_PATH:-}")
  for c in $HPCW_SLURM_CMDS; do
    [ -x "$r/usr/bin/$c" ] || continue
    { printf '%s\n' '#!/bin/bash' \
        "# hpcworker: the host's $c for Claude Code inside the worker's container (written by job $(hpcw_job_id) on $node)." \
        "# A job submitted from here runs on the host: the host's PATH, LD_LIBRARY_PATH and TMPDIR, none of the" \
        "# container's variables, none of the worker job's own SLURM_ ones (SLURM_CONF is kept)." \
        'for v in $(compgen -e); do case "$v" in APPTAINER_*|SINGULARITY_*|APPTAINERENV_*|SINGULARITYENV_*|XDG_RUNTIME_DIR) unset "$v";; SLURM_CONF) ;; SLURM_*) unset "$v";; esac; done'
      printf 'export PATH=%s\n' "$path_q"
      if [ -n "${LD_LIBRARY_PATH:-}" ]; then printf 'export LD_LIBRARY_PATH=%s\n' "$ld_q"; else printf 'unset LD_LIBRARY_PATH\n'; fi
      if [ -n "${HPCW_HOST_TMPDIR:-}" ]; then printf 'export TMPDIR=%s\n' "$tmp_q"; else printf 'unset TMPDIR\n'; fi
      printf 'exec /opt/host/bin/%s "$@"\n' "$c"; } > "$dir/bin/$c.part" && chmod 755 "$dir/bin/$c.part" && mv -f "$dir/bin/$c.part" "$dir/bin/$c" || return 1
    have="$have${have:+ }$c"
  done
  HPCW_SLURM_BINDS="-B $r/usr/bin:/opt/host/bin:ro -B $r/usr/lib64/slurm:/usr/lib64/slurm:ro -B $lib:/usr/lib/libmunge.so.2:ro -B $r/etc/slurm:/etc/slurm:ro -B $sock:/var/run/munge -B $dir/etc/passwd:/etc/passwd:ro -B $dir/etc/group:/etc/group:ro -B $dir/bin:$HPCW_SLURM_INSIDE:ro"
  HPCW_SLURM_NOTE="the host's Slurm client is in the container ($have, in $HPCW_SLURM_INSIDE)"
  return 0
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
# framework 10: one job in line, for `worker status` while status.json says "queued".
#   adapter_status_one ID [FORMAT] -> STATE|REASON|START|NODE (Slurm: squeue's own %T|%r|%S|%N), exit 0;
#   nothing and exit 0 when the scheduler no longer lists the job; exit 2 when the scheduler could not
#   be asked (the caller then changes nothing). A scheduler without squeue's fields (PBS, LSF) answers
#   its normalised state and node with no reason and no estimate, from its one status call.
adapter_status_one() {
  local s rest; s=$(adapter_status "$1" 2>/dev/null) || return 2
  rest=${s#*|}
  case "${s%%|*}" in PENDING|RUNNING) printf '%s|||%s\n' "${s%%|*}" "${rest%%|*}";; UNKNOWN) return 2;; esac
  return 0
}
# framework 10: when the scheduler accepted a job, as ISO-8601 UTC (the job asks, inside itself, when
# no queued status.json names it: a chain successor); nothing where the scheduler cannot say
adapter_submit_time() { return 0; }
