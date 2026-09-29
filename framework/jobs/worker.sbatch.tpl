#!/bin/bash
# hpcworker worker "@RUN@" at site @SITE@: one student's own Claude Code, hosted as a batch job
# on a compute node and reachable from claude.ai/code and the Claude app through Claude Code's
# Remote Control. Rendered by `hpcworker worker start` from worker.sbatch.tpl; do not edit by hand.
#
# What this job does, in order: settle on node-local temp, fix XDG_RUNTIME_DIR, mint a per-job
# token, write status.json (starting), start `claude remote-control` inside the container under a
# pseudo-terminal (tmux, or `script` with a held-open pipe), answer Claude Code's one-time
# "Enable Remote Control?" question ONLY if the student recorded that answer themselves (a marker
# file), parse the session link out of rc.log into connection.json, heartbeat status.json every
# @HEARTBEAT_S@ s, and leave cleanly on SIGTERM (preempted) or a stop file (stopped).
#
# What it never does: read, copy or print the student's Claude credential (Claude Code alone
# uses CLAUDE_CONFIG_DIR; the framework only asks `claude auth status`), put a token on a command
# line, or keep anything under a swept /tmp that must survive.
@HEADER@
set -uo pipefail
HPCW_VERSION=@VERSION@
SITE='@SITE@'; RUN='@RUN@'; RUN_DIR='@RUN_DIR@'; STATE_DIR='@STATE_DIR@'; WORKSPACE='@WORKSPACE@'
HPCW_HOME='@HPCW_HOME@'
RUNTIME='@RUNTIME@'; RUNTIME_BIN='@RUNTIME_BIN@'; RUNTIME_MODULE='@RUNTIME_MODULE@'
IMAGE='@IMAGE@'; IMAGE_TYPE='@IMAGE_TYPE@'; CLAUDE_BIN='@CLAUDE_BIN@'
BINDS='@BINDS@'
CLAUDE_CONFIG_DIR_VALUE='@CLAUDE_CONFIG_DIR@'
CONSENT_MARKERS='@CONSENT_MARKERS@'
IPC_DIR='@IPC_DIR@'
HPCW_NODE_TMP_PATTERN='@NODE_TMP@'; HPCW_NODE_TMP_VAR='@NODE_TMP_VAR@'; HPCW_TMPDIR_IS_NODE_LOCAL=@TMPDIR_IS_NODE_LOCAL@
XDG_FIX=@XDG_FIX@
PERMISSION_MODE='@PERMISSION_MODE@'; CAPACITY='@CAPACITY@'
HEARTBEAT_S=@HEARTBEAT_S@; AUTH_EVERY_S=@AUTH_EVERY_S@; RESUME_WINDOW_S=@RESUME_WINDOW_S@
export RUNTIME RUNTIME_BIN RUNTIME_MODULE HPCW_NODE_TMP_PATTERN HPCW_NODE_TMP_VAR HPCW_TMPDIR_IS_NODE_LOCAL

say() { echo "$(date -u +%FT%TZ) $*"; }
# shellcheck disable=SC1090
source "$HPCW_HOME/lib/adapters/common.sh" || { echo "REFUSING: $HPCW_HOME/lib/adapters/common.sh missing (run hpcworker install)"; exit 1; }
JOB=$(hpcw_job_id)
[ -n "$JOB" ] || { echo "REFUSING: this is a batch job body and runs only inside a scheduler job, not on $(hostname -s)"; exit 1; }
NODE=$(hostname -s)
mkdir -p "$RUN_DIR" "$WORKSPACE" || { echo "REFUSING: cannot create $RUN_DIR"; exit 1; }
cd "$RUN_DIR" || exit 1
echo "$JOB" > job.id; echo "$NODE" > node; rm -f stop.done
say "hpcworker $HPCW_VERSION worker $RUN job $JOB on $NODE (site $SITE); image $IMAGE_TYPE $IMAGE"

json_str() { hpcw_json_str "$1"; }
now_s() { date +%s; }
STARTED_AT=$(date -u +%FT%TZ)
STATE=starting; MESSAGE=""; SESSION_NAME="$SITE-$JOB"; SESSION_URL=""; AUTH_JSON=null; RESTARTS=0; RESUMED=false; RC_ALIVE=false; USING_TMUX=false; RC_PID=0
consent_given() { # the student answered "Enable Remote Control?" themselves and recorded it (any marker)
  local m; local IFS=':'; for m in $CONSENT_MARKERS; do [ -n "$m" ] && [ -e "$m" ] && return 0; done; return 1
}
write_status() { # STATE MESSAGE : atomic status.json, the one file clients read (never the scheduler)
  STATE="$1"; MESSAGE="$2"
  local consent=false; consent_given && consent=true
  printf '{"version":%s,"site":%s,"run":%s,"job":%s,"node":%s,"pid":%s,"state":%s,"message":%s,"started_at":%s,"updated_at":%s,"session_name":%s,"session_url":%s,"claude_login":%s,"consent":%s,"rc_alive":%s,"resumed":%s,"tmux":%s,"restarts":%s,"workspace":%s,"rc_log":%s,"token_path":%s}\n' \
    "$HPCW_VERSION" "$(json_str "$SITE")" "$(json_str "$RUN")" "$(json_str "$JOB")" "$(json_str "$NODE")" "$$" "$(json_str "$STATE")" "$(json_str "$MESSAGE")" \
    "$(json_str "$STARTED_AT")" "$(json_str "$(date -u +%FT%TZ)")" "$(json_str "$SESSION_NAME")" "$(json_str "$SESSION_URL")" "$AUTH_JSON" "$consent" "$RC_ALIVE" "$RESUMED" "$USING_TMUX" "$RESTARTS" \
    "$(json_str "$WORKSPACE")" "$(json_str "$RUN_DIR/rc.log")" "$(json_str "$RUN_DIR/job.token")" > status.json.part && mv -f status.json.part status.json
}
write_connection() {
  printf '{"session_name":%s,"session_url":%s,"node":%s,"job":%s,"pid":%s,"started_at":%s,"token_path":%s,"workspace":%s,"rc_log":%s,"permission_mode":%s,"capacity":%s,"resumed":%s}\n' \
    "$(json_str "$SESSION_NAME")" "$(json_str "$SESSION_URL")" "$(json_str "$NODE")" "$(json_str "$JOB")" "${RC_PID:-0}" "$(json_str "$STARTED_AT")" "$(json_str "$RUN_DIR/job.token")" \
    "$(json_str "$WORKSPACE")" "$(json_str "$RUN_DIR/rc.log")" "$(json_str "$PERMISSION_MODE")" "$(json_str "$CAPACITY")" "$RESUMED" > connection.json.part && mv -f connection.json.part connection.json
}

# ---- 1. node-local temp, IPC under /dev/shm, XDG fix ------------------------------------------
HPCW_NODE_TMP=$(hpcw_node_tmp); export HPCW_NODE_TMP
mkdir -p "$HPCW_NODE_TMP/tmp" "$HPCW_NODE_TMP/cache" || { write_status error "cannot create node-local temp $HPCW_NODE_TMP on $NODE"; exit 1; }
IPC="$IPC_DIR/$USER/hpcw_$JOB"; mkdir -p "$IPC" && chmod 700 "$IPC" || { write_status error "cannot create $IPC"; exit 1; }
cleanup() { type rc_stop >/dev/null 2>&1 && rc_stop; rm -rf "$HPCW_NODE_TMP" "$IPC"; }
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
CCD=$(hpcw_expand_job_vars "$CLAUDE_CONFIG_DIR_VALUE")
export HPCW_BINDS="$BINDS"
if [ "$IMAGE_TYPE" = sandbox ]; then [ -x "$IMAGE/usr/local/bin/node" ] || { write_status error "image $IMAGE is not a readable sandbox with node"; exit 1; }
else [ -r "$IMAGE" ] || { write_status error "image $IMAGE is not readable"; exit 1; }; fi
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
  echo "source $(printf %q "$HPCW_HOME/lib/adapters/common.sh")"
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
say "claude auth status: loggedIn=$LOGGED_IN"
HELP=$(in_image 90 "$CLAUDE_BIN" remote-control --help 2>&1 || true)
# when --help did not answer at all, assume the documented flags rather than starting bare
if ! printf '%s' "$HELP" | grep -q -i -E 'usage|remote-control|options'; then HELP='--name --capacity --continue --permission-mode'; say "remote-control --help gave no usable text; assuming the documented flags"; fi
accepts() { printf '%s' "$HELP" | grep -q -- "$1"; }
say "remote-control flags accepted: $(printf '%s' "$HELP" | grep -o -- '--[a-z-]*' | sort -u | tr '\n' ' ')"

# ---- 4. the launcher: claude remote-control under a pseudo-terminal, transcript in rc.log -------
# shellcheck disable=SC2016
SEED='const fs=require("fs"),p=process.env.CLAUDE_CONFIG_DIR+"/.claude.json";let j={};try{j=JSON.parse(fs.readFileSync(p,"utf8"))}catch{};j.hasCompletedOnboarding=true;j.theme=j.theme||"dark";j.projects=j.projects||{};j.projects[process.cwd()]=Object.assign({},j.projects[process.cwd()]||{},{hasTrustDialogAccepted:true});fs.writeFileSync(p+".part",JSON.stringify(j,null,1),{mode:0o600});fs.renameSync(p+".part",p);'
pretrust() { # mark the workspace trusted in this login's settings file (settings, not credentials): the
  # consent marker records that the student agreed to Remote Control in the framework's own workspace
  in_image 60 bash -c 'cd "$1" && node -e "$2"' _ "$WORKSPACE" "$SEED" >/dev/null 2>&1 || say "note: could not pre-trust $WORKSPACE (the trust question is answered from the marker instead)"
}
RC_ARGS=()
accepts '--name' && RC_ARGS+=(--name "$SESSION_NAME")
accepts '--capacity' && [ -n "$CAPACITY" ] && RC_ARGS+=(--capacity "$CAPACITY")
accepts '--permission-mode' && [ -n "$PERMISSION_MODE" ] && RC_ARGS+=(--permission-mode "$PERMISSION_MODE")
resume_wanted() { # a previous session younger than the resume window: bring it back instead of a new one
  [ -s connection.json ] || return 1
  local age=$(( $(now_s) - $(stat -c %Y connection.json 2>/dev/null || echo 0) ))
  [ "$age" -lt "$RESUME_WINDOW_S" ] && accepts '--continue'
}
TMUX_SOCK="$IPC/tmux"; FIFO="$IPC/stdin"
command -v tmux >/dev/null 2>&1 && USING_TMUX=true
RC_OFF=0; LAST_ANSWER=0; RC_STARTED=0
write_launcher() { # [extra args]: the command line claude gets, as a file
  local a; { echo '#!/bin/bash'; echo "# written by hpcworker job $JOB on $NODE; runs under a pseudo-terminal (tmux or script)"
    printf 'exec %q bash -c %q _ %q %q' "$RUN_DIR/in_image.sh" 'cd "$1" && exec "$2" remote-control "${@:3}"' "$WORKSPACE" "$CLAUDE_BIN"
    for a in ${RC_ARGS[@]+"${RC_ARGS[@]}"} "$@"; do printf ' %q' "$a"; done; echo; } > launch.sh.part
  chmod 700 launch.sh.part && mv -f launch.sh.part launch.sh
}
start_rc() { # [extra args]
  pretrust
  write_launcher "$@"
  RC_OFF=$(stat -c %s rc.log 2>/dev/null || echo 0)
  { echo; echo "===== $(date -u +%FT%TZ) job $JOB on $NODE: starting claude remote-control ${RC_ARGS[*]} $* ====="; } >> rc.log
  if [ "$USING_TMUX" = true ]; then
    tmux -S "$TMUX_SOCK" new-session -d -s rc -x 200 -y 50 "script -qfc '$RUN_DIR/launch.sh' '$RUN_DIR/rc.log'; sleep 2"
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
  say "remote-control started (pid $RC_PID, tmux=$USING_TMUX${RESUMED:+, resumed=$RESUMED})"
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
  tail -c +"$((from + 1))" rc.log 2>/dev/null | tr -d '\000' | sed -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' -e 's/\x1b[()][A-Za-z0-9]//g' -e 's/\r//g'
}
last_line() { printf '%s' "$1" | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200; }
PROMPT_RE='\(y/n\)|\[y/n\]|\[Y/n\]|\[y/N\]|yes/no'
URL_RE='https://claude\.(com|ai)/[^[:space:]"'"'"'<>]*'

# ---- 5. signals and the stop file --------------------------------------------------------------
on_term() { # --signal=B:TERM@120: the wall time or a preemption is 120 s away; scancel after a stop request also lands here
  trap - TERM INT
  rc_stop
  if [ -e stop ]; then rm -f stop; touch stop.done; write_status stopped "stopped by request"; say "stopped (signal after stop request)"
  else write_status preempted "job $JOB ending (wall time or preemption); start the worker again within 4 h to resume: hpcworker worker start --name $RUN"; say "preempted: left cleanly"; fi
  exit 0
}
trap on_term TERM INT

# ---- 6. main loop: start, watch, answer from the marker, record, heartbeat -------------------------
[ -s rc.log ] && mv -f rc.log rc.prev.log
: > rc.log
BACKOFF=10; NEXT_START=0; LAST_BEAT=0; ONLINE_NOTED=0
if [ "$LOGGED_IN" != true ]; then write_status need_login "Claude Code on the grid is not signed in; run: hpcworker claude login"; fi
while :; do
  if [ -e stop ]; then rc_stop; write_status stopped "stopped by request"; rm -f stop; touch stop.done; say "stopped"; exit 0; fi
  if rc_alive; then
    RC_ALIVE=true
    tail_txt=$(clean_tail "$RC_OFF")
    # the one-time consent question (and the per-directory trust question): answered only from the
    # student's own recorded answer, once per prompt; otherwise wait, alive, for hpcworker claude consent
    if printf '%s' "$tail_txt" | grep -q -E "$PROMPT_RE" && [ $(( $(now_s) - LAST_ANSWER )) -gt 5 ]; then
      if consent_given; then
        rc_send y; LAST_ANSWER=$(now_s); RC_OFF=$(stat -c %s rc.log 2>/dev/null || echo 0)
        say "answered Claude Code's question from the student's recorded consent"
        write_status starting "answered the one-time question from your recorded consent; waiting for the session"
      else
        [ "$STATE" = need_consent ] || { write_status need_consent "Claude Code asks once whether to enable Remote Control; answer it yourself with: hpcworker claude consent (this job waits)"; say "waiting for consent"; }
      fi
    else
      url=$(printf '%s' "$tail_txt" | grep -o -E "$URL_RE" | grep '/code' | tail -1 || true)
      [ -n "$url" ] && SESSION_URL="$url"
      if printf '%s' "$tail_txt" | grep -q -i -E 'full-scope|must be logged in|not logged in|log in again|Please run /login|Invalid API key'; then
        [ "$STATE" = need_login ] || { write_status need_login "Claude Code says the sign-in on the grid is missing or expired; run: hpcworker claude login"; say "need_login"; }
      elif printf '%s' "$tail_txt" | grep -q -i "Couldn't verify Remote Control eligibility"; then
        [ "$STATE" = error ] || write_status error "Claude Code could not reach its feature-flag service from $NODE (Remote Control needs it); ask your center about outbound HTTPS from compute nodes"
      elif printf '%s' "$tail_txt" | grep -q -i 'Workspace not trusted'; then
        [ "$STATE" = error ] || write_status error "Claude Code refused the workspace as untrusted: run hpcworker claude consent once (it records your answers)"
      elif [ -n "$SESSION_URL" ] || printf '%s' "$tail_txt" | grep -q -i -E 'remote control.*(ready|listening|waiting|connected|running|online|started)|session (name|id)|open claude\.ai|claude\.ai/code'; then
        if [ $ONLINE_NOTED = 0 ]; then ONLINE_NOTED=1; BACKOFF=10; write_connection; say "online: session $SESSION_NAME ${SESSION_URL:+$SESSION_URL}"; fi
        [ "$STATE" = online ] || write_status online "Open claude.ai/code, or tap Code in the Claude app, and find $SESSION_NAME. $(last_line "$tail_txt")"
      elif [ $(( $(now_s) - RC_STARTED )) -gt 60 ] && [ "$STATE" = starting ]; then
        write_status running "claude remote-control is running; no registration line recognised yet. Last output: $(last_line "$tail_txt")"
      fi
    fi
  else
    RC_ALIVE=false
    if [ "$RC_PID" != 0 ]; then
      # it exited: back off and start again (a new start later resumes with --continue while it can)
      RC_PID=0; RESTARTS=$((RESTARTS + 1)); NEXT_START=$(( $(now_s) + BACKOFF )); BACKOFF=$(( BACKOFF * 2 > 300 ? 300 : BACKOFF * 2 ))
      [ "$STATE" = need_login ] || write_status starting "Remote Control stopped; starting again in $(( NEXT_START - $(now_s) )) s. Last output: $(last_line "$(clean_tail "$RC_OFF")")"
      say "remote-control exited; restart #$RESTARTS in ${BACKOFF}s"
    fi
    if [ "$STATE" = need_login ] && [ $(( $(now_s) - LAST_AUTH )) -ge "$AUTH_EVERY_S" ]; then check_auth; [ "$LOGGED_IN" = true ] && write_status starting "signed in; starting Remote Control"; fi
    if [ "$STATE" != need_login ] && [ "$LOGGED_IN" = true ] && [ "$(now_s)" -ge "$NEXT_START" ]; then
      RESUMED=false; ONLINE_NOTED=0; SESSION_URL=""
      if resume_wanted; then RESUMED=true; start_rc --continue; write_status starting "starting Remote Control (resuming the previous session)"; else start_rc; write_status starting "starting Remote Control"; fi
    fi
  fi
  if [ $(( $(now_s) - LAST_AUTH )) -ge "$AUTH_EVERY_S" ] && [ "$STATE" != need_login ]; then check_auth; fi
  if [ $(( $(now_s) - LAST_BEAT )) -ge "$HEARTBEAT_S" ]; then write_status "$STATE" "$MESSAGE"; LAST_BEAT=$(now_s); fi
  sleep 5
done
