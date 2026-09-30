#!/bin/bash
# hpcworker worker "@RUN@" at site @SITE@: one student's own Claude Code, hosted as a batch job
# on a compute node and reachable from claude.ai/code and the Claude app through Claude Code's
# Remote Control. Rendered by `hpcworker worker start` from worker.sbatch.tpl; do not edit by hand.
#
# What this job does, in order: settle on node-local temp, fix XDG_RUNTIME_DIR, mint a per-job
# token, write status.json (starting), check the container and the sign-in (`claude auth status`,
# never the credential), queue its own successor so the worker is always on (one successor per
# link, started by the scheduler when this job ends; a stop file ends the chain), start
# `claude remote-control` inside the container under a pseudo-terminal (tmux, or `script` with a
# held-open pipe), parse the session name and the environment link out of rc.log into
# connection.json, heartbeat status.json every @HEARTBEAT_S@ s, and leave cleanly on SIGTERM
# (wall time or preemption: the successor takes over) or the stop file (stopped, chain ended; a
# TERM landing during that stop leaves the state stopped).
#
# Consent: Claude Code records the student's answer to "Enable Remote Control?" itself, as
# "remoteDialogSeen": true in <CLAUDE_CONFIG_DIR>/.claude.json. That boolean (and the workspace's
# hasTrustDialogAccepted) is all this job reads from that file; a marker file is the fallback
# (~/.hpcworker/consent, any content: the panel writes one when the student allows Remote Control
# there, `hpcworker claude consent` writes one too), and when Claude Code asks the question in the
# pty this job answers y once from either record. The file is written only to add
# hasCompletedOnboarding/theme/hasTrustDialogAccepted for the workspace, only when a session is
# about to start, never removing a key, never touching an unparseable file. status.json says in
# "needs" (login | consent | nothing) and "hint" what the student must do now, for the panel's one line.
#
# Slurm inside the worker (framework 9, when the site profile sets scheduler_in_worker): the host's
# own client, its library, the munge library and socket, /etc/slurm and a user list naming the slurm
# and munge users are bound into the container read-only, with wrappers that give a submitted job
# the host's environment, so Claude Code can submit and watch jobs; a job it submits runs on the
# host, not in the container. A piece missing on the node: the worker starts without it and says so
# (the job log, status.json "scheduler_note"). lib/adapters/common.sh hpcw_slurm_in_container.
#
# The code: lib/ comes from HPCW_CODE, the directory the command that rendered this job ran from
# (the lab's shared copy, by its numbered directory, or ~/.hpcworker); HPCW_HOME is the student's
# own folder (profile, consent marker). A chain keeps the code it started with until the next start.
#
# What it never does: read, copy or print the student's Claude credential (Claude Code alone uses
# CLAUDE_CONFIG_DIR; the framework only asks `claude auth status`), put a token on a command line,
# keep anything under a swept /tmp that must survive, or delete anything outside this run directory
# and its own per-job node-local temp.
@HEADER@
set -uo pipefail
HPCW_VERSION=@VERSION@
SITE='@SITE@'; RUN='@RUN@'; RUN_DIR='@RUN_DIR@'; STATE_DIR='@STATE_DIR@'; WORKSPACE='@WORKSPACE@'
HPCW_HOME='@HPCW_HOME@'; HPCW_CODE='@HPCW_CODE@'; SCHEDULER='@SCHEDULER@'; CHAIN=@CHAIN@
RUNTIME='@RUNTIME@'; RUNTIME_BIN='@RUNTIME_BIN@'; RUNTIME_MODULE='@RUNTIME_MODULE@'
IMAGE='@IMAGE@'; IMAGE_TYPE='@IMAGE_TYPE@'; CLAUDE_BIN='@CLAUDE_BIN@'
BINDS='@BINDS@'
CLAUDE_CONFIG_DIR_VALUE='@CLAUDE_CONFIG_DIR@'
CONSENT_MARKERS='@CONSENT_MARKERS@'
IPC_DIR='@IPC_DIR@'
HPCW_NODE_TMP_PATTERN='@NODE_TMP@'; HPCW_NODE_TMP_VAR='@NODE_TMP_VAR@'; HPCW_TMPDIR_IS_NODE_LOCAL=@TMPDIR_IS_NODE_LOCAL@
XDG_FIX=@XDG_FIX@; SCHED_IN_WORKER=@SCHED_IN_WORKER@
PERMISSION_MODE='@PERMISSION_MODE@'; CAPACITY='@CAPACITY@'
HEARTBEAT_S=@HEARTBEAT_S@; AUTH_EVERY_S=@AUTH_EVERY_S@; RESUME_WINDOW_S=@RESUME_WINDOW_S@; LOGIN_RECHECK_S=@LOGIN_RECHECK_S@
export RUNTIME RUNTIME_BIN RUNTIME_MODULE HPCW_NODE_TMP_PATTERN HPCW_NODE_TMP_VAR HPCW_TMPDIR_IS_NODE_LOCAL
ORIG_TMPDIR="${TMPDIR:-}"   # what a successor should inherit: not this node's per-job temp

say() { echo "$(date -u +%FT%TZ) $*"; }
# shellcheck disable=SC1090
source "$HPCW_CODE/lib/adapters/common.sh" || { echo "REFUSING: $HPCW_CODE/lib/adapters/common.sh missing (run hpcworker install, then start the worker again)"; exit 1; }
HAVE_ADAPTER=0
# shellcheck disable=SC1090
if [ -s "$HPCW_CODE/lib/adapters/$SCHEDULER.sh" ] && source "$HPCW_CODE/lib/adapters/$SCHEDULER.sh"; then HAVE_ADAPTER=1; fi
JOB=$(hpcw_job_id)
[ -n "$JOB" ] || { echo "REFUSING: this is a batch job body and runs only inside a scheduler job, not on $(hostname -s)"; exit 1; }
NODE=$(hostname -s)
mkdir -p "$RUN_DIR" "$WORKSPACE" || { echo "REFUSING: cannot create $RUN_DIR"; exit 1; }
cd "$RUN_DIR" || exit 1
echo "$JOB" > job.id; echo "$NODE" > node; rm -f stop.done
say "hpcworker $HPCW_VERSION worker $RUN job $JOB on $NODE (site $SITE); image $IMAGE_TYPE $IMAGE; chain=$CHAIN"

json_str() { hpcw_json_str "$1"; }
now_s() { date +%s; }
STARTED_AT=$(date -u +%FT%TZ)
CCD=$(hpcw_expand_job_vars "$CLAUDE_CONFIG_DIR_VALUE")
STATE=starting; MESSAGE=""; REQUESTED_NAME="$SITE-$RUN"; SESSION_NAME="$REQUESTED_NAME"; SESSION_URL=""; ENV_URL=""; ENV_ID=""
AUTH_JSON=null; RESTARTS=0; RESUMED=false; RESUME_TRIED=0; RC_ALIVE=false; USING_TMUX=false; RC_PID=0
NEXT_JOB=""; CHAIN_NOTE=""; WS_TRUSTED=false; SCHED_INSIDE=false; SCHED_NOTE="off in the site profile"
# trust for the workspace as Claude Code has it on record (the second of the two booleans read); the seed below may add it later
hpcw_workspace_trusted "$CCD" "$WORKSPACE" && WS_TRUSTED=true
consent_source() { # claude_config | marker | none : where the student's recorded answer was found
  if hpcw_consent_seen "$CCD"; then echo claude_config; return 0; fi
  local m; local IFS=':'; for m in $CONSENT_MARKERS; do [ -n "$m" ] && [ -e "$m" ] && { echo marker; return 0; }; done
  echo none
}
consent_given() { [ "$(consent_source)" != none ]; }
write_status() { # STATE MESSAGE : atomic status.json, the one file clients read (never the scheduler)
  STATE="$1"; MESSAGE="$2"
  local src; src=$(consent_source); local consent=false; [ "$src" != none ] && consent=true
  # the one thing the student must do now, and a sentence for it: what the panel shows on its one line
  local needs hint; needs=$(hpcw_needs "$STATE" "$consent"); hint=$(hpcw_hint "$STATE" "$needs" "$NEXT_JOB")
  printf '{"version":%s,"site":%s,"run":%s,"job":%s,"node":%s,"pid":%s,"state":%s,"message":%s,"needs":%s,"hint":%s,"started_at":%s,"updated_at":%s,"session_name":%s,"requested_name":%s,"session_url":%s,"environment_url":%s,"environment_id":%s,"claude_login":%s,"consent":%s,"consent_source":%s,"workspace_trusted":%s,"rc_alive":%s,"resumed":%s,"tmux":%s,"restarts":%s,"chain":%s,"next_job":%s,"chain_note":%s,"scheduler_in_worker":%s,"scheduler_note":%s,"workspace":%s,"rc_log":%s,"token_path":%s}\n' \
    "$HPCW_VERSION" "$(json_str "$SITE")" "$(json_str "$RUN")" "$(json_str "$JOB")" "$(json_str "$NODE")" "$$" "$(json_str "$STATE")" "$(json_str "$MESSAGE")" "$(json_str "$needs")" "$(json_str "$hint")" \
    "$(json_str "$STARTED_AT")" "$(json_str "$(date -u +%FT%TZ)")" "$(json_str "$SESSION_NAME")" "$(json_str "$REQUESTED_NAME")" "$(json_str "$SESSION_URL")" "$(json_str "$ENV_URL")" "$(json_str "$ENV_ID")" \
    "$AUTH_JSON" "$consent" "$(json_str "$src")" "$WS_TRUSTED" "$RC_ALIVE" "$RESUMED" "$USING_TMUX" "$RESTARTS" "$([ "$CHAIN" = 1 ] && echo true || echo false)" "$(json_str "$NEXT_JOB")" "$(json_str "$CHAIN_NOTE")" \
    "$SCHED_INSIDE" "$(json_str "$SCHED_NOTE")" "$(json_str "$WORKSPACE")" "$(json_str "$RUN_DIR/rc.log")" "$(json_str "$RUN_DIR/job.token")" > status.json.part && mv -f status.json.part status.json
}
write_connection() {
  printf '{"session_name":%s,"requested_name":%s,"session_url":%s,"environment_url":%s,"environment_id":%s,"node":%s,"job":%s,"pid":%s,"started_at":%s,"token_path":%s,"workspace":%s,"rc_log":%s,"permission_mode":%s,"capacity":%s,"resumed":%s,"next_job":%s}\n' \
    "$(json_str "$SESSION_NAME")" "$(json_str "$REQUESTED_NAME")" "$(json_str "$SESSION_URL")" "$(json_str "$ENV_URL")" "$(json_str "$ENV_ID")" "$(json_str "$NODE")" "$(json_str "$JOB")" "${RC_PID:-0}" "$(json_str "$STARTED_AT")" "$(json_str "$RUN_DIR/job.token")" \
    "$(json_str "$WORKSPACE")" "$(json_str "$RUN_DIR/rc.log")" "$(json_str "$PERMISSION_MODE")" "$(json_str "$CAPACITY")" "$RESUMED" "$(json_str "$NEXT_JOB")" > connection.json.part && mv -f connection.json.part connection.json
}
# a stop asked for while the previous link was ending: this link ends the chain and leaves at once
if [ -e stop ]; then rm -f stop; write_status stopped "stopped by request; the chain ended"; say "stop file present at start: chain ended"; touch stop.done; exit 0; fi

# ---- 1. node-local temp, IPC under /dev/shm, XDG fix ------------------------------------------
HPCW_NODE_TMP=$(hpcw_node_tmp); export HPCW_NODE_TMP
mkdir -p "$HPCW_NODE_TMP/tmp" "$HPCW_NODE_TMP/cache" || { write_status error "cannot create node-local temp $HPCW_NODE_TMP on $NODE"; exit 1; }
IPC="$IPC_DIR/$USER/hpcw_$JOB"; mkdir -p "$IPC" && chmod 700 "$IPC" || { write_status error "cannot create $IPC"; exit 1; }
# the only deletion this job performs: its own per-job directories, through the guarded helper
cleanup() { type rc_stop >/dev/null 2>&1 && rc_stop; hpcw_rm_own_tmp "$HPCW_NODE_TMP" "$IPC"; say "cleanup: removed $HPCW_NODE_TMP and $IPC on $NODE"; }
trap cleanup EXIT
export TMPDIR="$HPCW_NODE_TMP/tmp"
XDG=""
if [ "$XDG_FIX" = 1 ]; then
  # Claude Code's bash tool wants /run/user/<uid>, which compute nodes without systemd user
  # sessions do not have; point XDG_RUNTIME_DIR at /dev/shm (an upstream "not planned" defect)
  XDG="$IPC_DIR/$USER/xdg"; mkdir -p "$XDG" && chmod 700 "$XDG" && export XDG_RUNTIME_DIR="$XDG"
fi
say "node temp $HPCW_NODE_TMP ($(df -Pk "$HPCW_NODE_TMP" 2>/dev/null | awk 'NR==2{printf "%.1f GB free", $4/1048576}')); ipc $IPC; xdg ${XDG:-unchanged}"
@EGRESS_EXPORTS@

# ---- 2. per-job token (0600, in the run directory; never printed) ------------------------------
( umask 077; head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_' > job.token.part && mv -f job.token.part job.token ) || { write_status error "cannot write job.token"; exit 1; }
write_status starting "checking the container and the sign-in"

# ---- 3. the container, the sign-in status (never the credential), the accepted flags ------------
export HPCW_BINDS="$BINDS"
if [ "$IMAGE_TYPE" = sandbox ]; then [ -x "$IMAGE/usr/local/bin/node" ] || { write_status error "image $IMAGE is not a readable sandbox with node"; exit 1; }
else [ -r "$IMAGE" ] || { write_status error "image $IMAGE is not readable"; exit 1; }; fi
# Slurm inside the container, when the profile asks for it: the binds and wrappers are made on this
# node for this job, under its /dev/shm directory (not /tmp, which a cleaner sweeps while jobs run),
# and added to every container start below; a job submitted from inside gets the host's PATH and
# LD_LIBRARY_PATH and the TMPDIR this job was given, not the container's
SCHED_PATH=""
if [ "$SCHED_IN_WORKER" = 1 ]; then
  if [ "$SCHEDULER" = slurm ] && HPCW_HOST_TMPDIR="$ORIG_TMPDIR" hpcw_slurm_in_container "$IPC/slurm" "$IMAGE" "$IMAGE_TYPE"; then
    BINDS="$BINDS $HPCW_SLURM_BINDS"; export HPCW_BINDS="$BINDS"; SCHED_INSIDE=true; SCHED_PATH="$HPCW_SLURM_INSIDE"
  fi
  SCHED_NOTE="${HPCW_SLURM_NOTE:-not available: only the Slurm client can be bound into the container}"
  say "scheduler inside the container: $SCHED_NOTE"
fi
# The environment Claude Code gets: its own config dir, no other credential or endpoint (a token
# in the environment would outrank the sign-in and switch Remote Control off), feature flags left
# on (Remote Control needs them), no self-update under a running worker.
CLEAN_ENV=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR -u CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR
           -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -u DISABLE_GROWTHBOOK
           HOME="$HOME" CLAUDE_CONFIG_DIR="$CCD" DISABLE_AUTOUPDATER=1 TERM=xterm-256color BROWSER=/bin/false TMPDIR=/tmp ${XDG:+XDG_RUNTIME_DIR="$XDG"} HPCW_JOB="$JOB" HPCW_SITE="$SITE")
# in_image.sh runs one command inside the image with that environment; a file, so `timeout`,
# `script` and tmux can all run it without quoting travelling through them
{ echo '#!/bin/bash'; echo "# written by hpcworker job $JOB on $NODE: one command inside the worker image, with Claude Code's clean environment"
  echo "export RUNTIME=$(printf %q "$RUNTIME") RUNTIME_BIN=$(printf %q "$RUNTIME_BIN") RUNTIME_MODULE=$(printf %q "$RUNTIME_MODULE") HPCW_BINDS=$(printf %q "$BINDS") HPCW_NODE_TMP=$(printf %q "$HPCW_NODE_TMP") HPCW_JOB_ID=$(printf %q "$JOB")"
  # the Slurm wrappers first on the container's PATH (the runtime prepends it to the image's own)
  [ -n "$SCHED_PATH" ] && echo "export APPTAINERENV_PREPEND_PATH=$(printf %q "$SCHED_PATH") SINGULARITYENV_PREPEND_PATH=$(printf %q "$SCHED_PATH")"
  echo "source $(printf %q "$HPCW_CODE/lib/adapters/common.sh")"
  printf 'hpcw_runtime_exec %q' "$IMAGE"; for a in "${CLEAN_ENV[@]}"; do printf ' %q' "$a"; done; echo ' "$@"'; } > in_image.sh.part
chmod 700 in_image.sh.part && mv -f in_image.sh.part in_image.sh
in_image() { local t="$1"; shift; timeout "$t" "$RUN_DIR/in_image.sh" "$@"; }
v=$(in_image 120 "$CLAUDE_BIN" --version 2>&1 | tail -1) || v="(no answer: $v)"
case "$v" in *REFUSING*|*"no answer"*|"") write_status error "the container cannot run claude on $NODE: $v"; exit 1;; esac
say "claude in the container: $v"
LAST_AUTH=0; LOGGED_IN=false
check_auth() { # Claude Code's own answer about its stored login; loggedIn/email/subscriptionType only, never tokens
  local out li em st; out=$(in_image 90 "$CLAUDE_BIN" auth status 2>/dev/null) || out=""
  li=$(printf '%s' "$out" | grep -o '"loggedIn": *\(true\|false\)' | head -1 | grep -o 'true\|false'); li=${li:-false}
  em=$(printf '%s' "$out" | grep -o '"email": *"[^"]*"' | head -1 | cut -d'"' -f4)
  st=$(printf '%s' "$out" | grep -o '"subscriptionType": *"[^"]*"' | head -1 | cut -d'"' -f4)
  AUTH_JSON=$(printf '{"loggedIn":%s,"email":%s,"subscriptionType":%s,"checked_at":%s}' "$li" "$(json_str "$em")" "$(json_str "$st")" "$(json_str "$(date -u +%FT%TZ)")")
  LAST_AUTH=$(now_s); LOGGED_IN="$li"
}
check_auth
# started seconds after a sign-in finished (the panel does that): Claude Code may still be writing
# its credential, so ask three more times, 10 s apart, before saying need_login
for _try in 1 2 3; do [ "$LOGGED_IN" = true ] && break; say "not signed in yet (try $_try of 3); asking again in 10 s"; sleep 10; check_auth; done
say "claude auth status: loggedIn=$LOGGED_IN; consent: $(consent_source)"
HELP=$(in_image 90 "$CLAUDE_BIN" remote-control --help 2>&1 || true)
# when --help did not answer at all, assume the documented flags rather than starting bare
if ! printf '%s' "$HELP" | grep -q -i -E 'usage|remote-control|options'; then HELP='--name --capacity --continue --permission-mode'; say "remote-control --help gave no usable text; assuming the documented flags"; fi
accepts() { printf '%s' "$HELP" | grep -q -- "$1"; }
say "remote-control flags accepted: $(printf '%s' "$HELP" | grep -o -- '--[a-z-]*' | sort -u | tr '\n' ' ')"

# ---- 4. the always-on chain: one successor per link, queued now, started when this job ends ----
arm_chain() {
  [ "$CHAIN" = 1 ] || { CHAIN_NOTE="chain off for this worker"; return 0; }
  [ $HAVE_ADAPTER = 1 ] || { CHAIN_NOTE="no $SCHEDULER adapter in $HPCW_CODE/lib/adapters; this job runs alone"; say "chain: $CHAIN_NOTE"; return 0; }
  [ -e stop ] && return 0
  [ -s job.sbatch ] || { CHAIN_NOTE="no job.sbatch in $RUN_DIR to re-submit; this job runs alone"; say "chain: $CHAIN_NOTE"; return 0; }
  local nid np
  if [ -s next.id ]; then read -r nid np < next.id; if [ "$np" = "$JOB" ]; then NEXT_JOB="$nid"; CHAIN_NOTE="successor $nid was queued by this job before a restart"; say "chain: $CHAIN_NOTE"; return 0; fi; fi
  # the successor inherits this shell's environment minus this node's per-job temp and sockets
  local out; out=$( ( if [ -n "$ORIG_TMPDIR" ]; then export TMPDIR="$ORIG_TMPDIR"; else unset TMPDIR; fi; unset XDG_RUNTIME_DIR HPCW_NODE_TMP HPCW_BINDS APPTAINER_TMPDIR APPTAINER_CACHEDIR SINGULARITY_TMPDIR SINGULARITY_CACHEDIR
                        adapter_submit_after "$RUN_DIR/job.sbatch" "$JOB" -D "$RUN_DIR" ) 2>&1 ) || { CHAIN_NOTE="the scheduler refused the successor: $(printf '%s' "$out" | tail -1 | cut -c1-160); this job runs alone"; say "chain: $CHAIN_NOTE"; return 0; }
  NEXT_JOB="$out"; printf '%s %s\n' "$NEXT_JOB" "$JOB" > next.id.part && mv -f next.id.part next.id
  echo "$(date -u +%FT%TZ) $JOB on $NODE -> $NEXT_JOB" >> chain.log
  CHAIN_NOTE="successor $NEXT_JOB queued (afterany:$JOB)"; say "chain: $CHAIN_NOTE; it takes over when this job ends"
}
end_chain() { # a stop was asked for: the queued successor must not start
  local nid np; [ -s next.id ] || return 0
  read -r nid np < next.id
  if [ -n "$nid" ] && [ $HAVE_ADAPTER = 1 ]; then adapter_cancel "$nid"; say "chain: successor $nid cancelled"; fi
  rm -f next.id; NEXT_JOB=""; CHAIN_NOTE="chain ended by request"
}
arm_chain

# ---- 5. the launcher: claude remote-control under a pseudo-terminal, transcript in rc.log -------
# The seed adds three settings to this login's .claude.json (never a credential): onboarding done,
# a theme, and trust for this workspace, which Remote Control requires. It only ADDS keys, writes
# nothing when they are already there, and refuses to touch a file it cannot parse. It runs only
# from start_rc, i.e. only when a session is about to start for a signed-in student.
# shellcheck disable=SC2016
SEED='const fs=require("fs"),p=process.env.CLAUDE_CONFIG_DIR+"/.claude.json";let j={},had=false;try{const t=fs.readFileSync(p,"utf8");had=true;j=JSON.parse(t)}catch(e){if(had){console.log("unreadable");process.exit(0)}}if(!j||typeof j!=="object")j={};let ch=false;if(j.hasCompletedOnboarding!==true){j.hasCompletedOnboarding=true;ch=true}if(!j.theme){j.theme="dark";ch=true}j.projects=j.projects||{};const d=process.cwd();const pr=j.projects[d]||{};if(pr.hasTrustDialogAccepted!==true){pr.hasTrustDialogAccepted=true;j.projects[d]=pr;ch=true}if(ch){fs.writeFileSync(p+".part",JSON.stringify(j,null,1),{mode:0o600});fs.renameSync(p+".part",p)}console.log(ch?"seeded":"already");'
pretrust() {
  local r; r=$(in_image 60 bash -c 'cd "$1" && node -e "$2"' _ "$WORKSPACE" "$SEED" 2>/dev/null | tail -1)
  case "$r" in seeded|already) WS_TRUSTED=true; say "workspace trust for $WORKSPACE: $r";; *) WS_TRUSTED=false; say "note: could not record trust for $WORKSPACE (${r:-no answer}); Claude Code will ask, and the answer comes from your recorded consent";; esac
}
RC_ARGS=()
accepts '--name' && RC_ARGS+=(--name "$REQUESTED_NAME")
accepts '--capacity' && [ -n "$CAPACITY" ] && RC_ARGS+=(--capacity "$CAPACITY")
accepts '--permission-mode' && [ -n "$PERMISSION_MODE" ] && RC_ARGS+=(--permission-mode "$PERMISSION_MODE")
resume_wanted() { # a previous session younger than the resume window: bring it back with --continue, tried once per job
  [ "$RESUME_TRIED" = 0 ] || return 1
  [ -s connection.json ] || return 1
  local age=$(( $(now_s) - $(stat -c %Y connection.json 2>/dev/null || echo 0) ))
  [ "$age" -lt "$RESUME_WINDOW_S" ] && accepts '--continue'
}
TMUX_SOCK="$IPC/tmux"; FIFO="$IPC/stdin"
command -v tmux >/dev/null 2>&1 && USING_TMUX=true
RC_OFF=0; LAST_ANSWER=0; RC_STARTED=0
write_launcher() { # [extra args]: the command line claude gets, as a file; a wide terminal so the link is never wrapped
  # A resume (--continue) refuses --capacity in Claude Code 2.1.283: "--session-id and --continue
  # cannot be used with --spawn, --capacity, or --create-session-in-dir" (job 40501175, 2026-09-29),
  # so the flag is left out then; what capacity a resumed session runs with is not measured
  local a resume=0 skip=0; for a in "$@"; do [ "$a" = --continue ] && resume=1; done
  { echo '#!/bin/bash'; echo "# written by hpcworker job $JOB on $NODE; runs under a pseudo-terminal (tmux or script)"
    printf 'exec %q bash -c %q _ %q %q' "$RUN_DIR/in_image.sh" 'stty cols 220 rows 50 2>/dev/null; cd "$1" && exec "$2" remote-control "${@:3}"' "$WORKSPACE" "$CLAUDE_BIN"
    for a in ${RC_ARGS[@]+"${RC_ARGS[@]}"} "$@"; do
      if [ $skip = 1 ]; then skip=0; continue; fi
      if [ $resume = 1 ] && [ "$a" = --capacity ]; then skip=1; continue; fi
      printf ' %q' "$a"
    done; echo; } > launch.sh.part
  chmod 700 launch.sh.part && mv -f launch.sh.part launch.sh
}
start_rc() { # [extra args]
  pretrust
  write_launcher "$@"
  RC_OFF=$(stat -c %s rc.log 2>/dev/null || echo 0)
  { echo; echo "===== $(date -u +%FT%TZ) job $JOB on $NODE: starting claude remote-control ${RC_ARGS[*]} $* ====="; } >> rc.log
  if [ "$USING_TMUX" = true ]; then
    tmux -S "$TMUX_SOCK" new-session -d -s rc -x 220 -y 50 "script -qfc '$RUN_DIR/launch.sh' '$RUN_DIR/rc.log'; sleep 2"
    sleep 1; RC_PID=$(tmux -S "$TMUX_SOCK" list-panes -t rc -F '#{pane_pid}' 2>/dev/null | head -1); RC_PID=${RC_PID:-0}
  else
    # no tmux on this node: `script` still gives claude a real terminal; its stdin is a pipe we hold
    # open on fd 7 so the session does not end at EOF, and consent answers go through the same pipe
    [ -p "$FIFO" ] || mkfifo -m 600 "$FIFO"
    exec 7<>"$FIFO"
    script -qfc "$RUN_DIR/launch.sh" "$RUN_DIR/rc.log" <&7 >/dev/null 2>&1 &
    RC_PID=$!
  fi
  RC_ALIVE=true; RC_STARTED=$(now_s)
  say "remote-control started (pid $RC_PID, tmux=$USING_TMUX, resumed=$RESUMED)"
}
rc_alive() {
  if [ "$USING_TMUX" = true ]; then tmux -S "$TMUX_SOCK" has-session -t rc 2>/dev/null; else [ "$RC_PID" -gt 0 ] && kill -0 "$RC_PID" 2>/dev/null; fi
}
rc_send() { # type an answer into claude's terminal
  if [ "$USING_TMUX" = true ]; then tmux -S "$TMUX_SOCK" send-keys -t rc "$1" Enter; else printf '%s\r' "$1" >&7; fi
}
rc_stop() { # Ctrl-C first, so Remote Control deregisters; then end the session
  rc_alive || return 0
  if [ "$USING_TMUX" = true ]; then tmux -S "$TMUX_SOCK" send-keys -t rc C-c; else printf '\003' >&7; fi
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do rc_alive || break; sleep 1; done
  if [ "$USING_TMUX" = true ]; then tmux -S "$TMUX_SOCK" kill-server 2>/dev/null; else kill "$RC_PID" 2>/dev/null; fi
  RC_ALIVE=false
}
clean_tail() { # what claude printed since offset $1 (last 6000 bytes at most), without terminal codes
  local size from=$1; size=$(stat -c %s rc.log 2>/dev/null || echo 0)
  [ $((size - from)) -gt 6000 ] && from=$((size - 6000))
  tail -c +"$((from + 1))" rc.log 2>/dev/null | hpcw_strip_codes
}
last_line() { printf '%s' "$1" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200; }
note_registration() { # $1: cleaned tail -> SESSION_NAME / ENV_URL / ENV_ID from the "Connected" block; 0 when a link is known
  local reg name url id; reg=$(printf '%s\n' "$1" | hpcw_parse_registration)
  name=${reg%%|*}; url=${reg#*|}; url=${url%%|*}; id=${reg##*|}
  [ -n "$name" ] && SESSION_NAME="$name"
  [ -n "$url" ] && { ENV_URL="$url"; ENV_ID="$id"; SESSION_URL="$url"; }
  [ -n "$ENV_URL" ]
}
PROMPT_RE='\(y/n\)|\[y/n\]|\[Y/n\]|\[y/N\]|yes/no|Enable Remote Control'

# ---- 6. signals and the stop file --------------------------------------------------------------
# A student's stop (the stop file, from `hpcworker worker stop` or the panel) and a TERM (the wall
# time or a preemption through --signal=B:TERM@120, or the CLI's one scancel when this job did not
# leave by itself) can land together. The rule: a stop that has begun finishes, its last status
# write is "stopped", and the trap stays armed the whole way; a TERM that fires inside the stop
# path hands back to it instead of writing a state of its own. Measured the other way round on job
# 40501099 (2026-09-29): the trap wrote "preempted" over a stop that had gone through.
STOPPING=0
stop_and_leave() { # REASON: end the session, cancel the successor, write stopped, mark stop.done, leave
  [ "$STOPPING" = 1 ] && return 0   # already on this path (a signal landed inside it): the path resumes and finishes
  STOPPING=1
  rc_stop
  end_chain
  write_status stopped "stopped by request; the chain ended"
  # stop.done after the status, so whoever sees it may trust status.json; the stop file goes with it
  rm -f stop; touch stop.done
  say "stopped ($1)"
  exit 0
}
on_term() {
  # a stop file, stop.done or a stop under way: a student's stop, whatever the signal's reason
  if [ -e stop ] || [ -e stop.done ] || [ "$STOPPING" = 1 ]; then stop_and_leave "signal after a stop request"; return 0; fi
  trap - TERM INT
  rc_stop
  if [ -n "$NEXT_JOB" ]; then write_status preempted "job $JOB ending (wall time or preemption); the next job in the chain, $NEXT_JOB, takes over and resumes the session"; say "ending: successor $NEXT_JOB takes over"
  else write_status preempted "job $JOB ending (wall time or preemption) with no successor queued; start the worker again within seven days to resume the same session: hpcworker worker start --name $RUN"; say "preempted: left cleanly"; fi
  exit 0
}
trap on_term TERM INT

# ---- 7. main loop: start, watch, answer from the recorded consent, record, heartbeat ---------------
[ -s rc.log ] && mv -f rc.log rc.prev.log
: > rc.log
BACKOFF=10; NEXT_START=0; LAST_BEAT=0; ONLINE_NOTED=0
if [ "$LOGGED_IN" != true ]; then write_status need_login "Claude Code on the cluster is not signed in; sign in from the panel (or run: hpcworker claude login). This job waits and asks again every minute."; fi
while :; do
  if [ -e stop ]; then stop_and_leave "stop file"; fi
  if rc_alive; then
    RC_ALIVE=true
    tail_txt=$(clean_tail "$RC_OFF")
    # the one-time consent question (and the per-directory trust question): answered only from the
    # student's own recorded answer, once per prompt; otherwise wait, alive, for hpcworker claude login
    if printf '%s' "$tail_txt" | grep -q -E "$PROMPT_RE" && [ $(( $(now_s) - LAST_ANSWER )) -gt 5 ]; then
      if consent_given; then
        rc_send y; LAST_ANSWER=$(now_s); RC_OFF=$(stat -c %s rc.log 2>/dev/null || echo 0)
        say "answered Claude Code's question from the student's recorded consent ($(consent_source))"
        write_status starting "answered the one-time question from your recorded consent; waiting for the session"
      else
        [ "$STATE" = need_consent ] || { write_status need_consent "Claude Code asks once whether to enable Remote Control; answer it yourself with: hpcworker claude login (this job waits)"; say "waiting for consent"; }
      fi
    else
      note_registration "$tail_txt" || true
      if printf '%s' "$tail_txt" | grep -q -i -E 'full-scope|must be logged in|not logged in|log in again|Please run /login|Invalid API key'; then
        [ "$STATE" = need_login ] || { write_status need_login "Claude Code says the sign-in on the grid is missing or expired; run: hpcworker claude login"; say "need_login"; }
      elif printf '%s' "$tail_txt" | grep -q -i "Couldn't verify Remote Control eligibility"; then
        [ "$STATE" = error ] || write_status error "Claude Code could not reach its feature-flag service from $NODE (Remote Control needs it); ask your center about outbound HTTPS from compute nodes"
      elif printf '%s' "$tail_txt" | grep -q -i 'Workspace not trusted'; then
        [ "$STATE" = error ] || write_status error "Claude Code refused the workspace as untrusted: run hpcworker claude login once more (it records the trust answer)"
      elif [ -n "$ENV_URL" ] || printf '%s' "$tail_txt" | grep -q -E 'Connected ·|Capacity: [0-9]+/[0-9]+|claude\.ai/code'; then
        if [ $ONLINE_NOTED = 0 ]; then ONLINE_NOTED=1; BACKOFF=10; write_connection; say "online: session $SESSION_NAME ${ENV_URL:+$ENV_URL}"; fi
        [ "$STATE" = online ] && [ -n "$ENV_URL" ] || { write_status online "Open in Claude: ${ENV_URL:-claude.ai/code} and find $SESSION_NAME (or tap Code in the Claude app). $(last_line "$tail_txt")"; [ -n "$ENV_URL" ] && write_connection; }
      elif [ $(( $(now_s) - RC_STARTED )) -gt 60 ] && [ "$STATE" = starting ]; then
        write_status running "claude remote-control is running; no registration line recognised yet. Last output: $(last_line "$tail_txt")"
      fi
    fi
  else
    RC_ALIVE=false
    if [ "$RC_PID" != 0 ]; then
      # it exited: back off and start again (a fresh registration joins the same environment; --continue was tried once)
      RC_PID=0; RESTARTS=$((RESTARTS + 1)); NEXT_START=$(( $(now_s) + BACKOFF )); BACKOFF=$(( BACKOFF * 2 > 300 ? 300 : BACKOFF * 2 ))
      [ "$STATE" = need_login ] || write_status starting "Remote Control stopped; starting again in $(( NEXT_START - $(now_s) )) s. Last output: $(last_line "$(clean_tail "$RC_OFF")")"
      say "remote-control exited; restart #$RESTARTS in ${BACKOFF}s"
    fi
    # while waiting for the sign-in, ask every minute (the panel's sign-in ends with a worker start or a wait for this)
    if [ "$STATE" = need_login ] && [ $(( $(now_s) - LAST_AUTH )) -ge "$LOGIN_RECHECK_S" ]; then check_auth; [ "$LOGGED_IN" = true ] && write_status starting "signed in; starting Remote Control"; fi
    if [ "$STATE" != need_login ] && [ "$LOGGED_IN" = true ] && [ "$(now_s)" -ge "$NEXT_START" ]; then
      RESUMED=false; ONLINE_NOTED=0; ENV_URL=""; ENV_ID=""; SESSION_URL=""
      if resume_wanted; then RESUMED=true; RESUME_TRIED=1; start_rc --continue; write_status starting "starting Remote Control (resuming the previous session)"; else start_rc; write_status starting "starting Remote Control"; fi
    fi
  fi
  if [ $(( $(now_s) - LAST_AUTH )) -ge "$AUTH_EVERY_S" ] && [ "$STATE" != need_login ]; then check_auth; fi
  if [ $(( $(now_s) - LAST_BEAT )) -ge "$HEARTBEAT_S" ]; then write_status "$STATE" "$MESSAGE"; LAST_BEAT=$(now_s); fi
  sleep 5
done
