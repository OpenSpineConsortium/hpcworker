#!/bin/bash
# hpcworker probe: up to ten minutes on a compute node to learn what the login node cannot tell:
# node-local temp and its free space, /dev/shm, user namespaces, whether the runtime can exec the
# image (node and claude versions, the flags `claude remote-control` accepts), the egress matrix to
# Anthropic's hosts with and without inherited proxy variables, what `claude auth status` says
# (loggedIn, subscriptionType, email; never a token), the XDG_RUNTIME_DIR fix, and tmux.
# Every call inside the image has its own budget (the table at in_image below); they add up to
# five minutes, the egress checks to one more, so the job ends inside its wall time however slow
# the node is. It does not run the sign-in sitting: two probes of 2026-09-29 hit a five-minute
# wall time with the sitting's dry run on top of budgets that already summed past it, and a dry
# run in an unseeded throwaway directory measured Claude Code's first-run screens, not the
# student's sitting. probe.json records login_flow as not probed; the sitting itself is the test.
# Result: <state_dir>/probe/probe.json (mode 0600, atomic). Read it with `hpcworker probe --show`.
# Submitted by `hpcworker probe` with the profile's partition/QoS and -D <state_dir>/probe, where
# it left probe.env; the directives below are the fallback when submitted by hand.
#SBATCH --job-name=hpcw_probe
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:10:00
#SBATCH --output=probe_%j.out
set -uo pipefail
umask 077   # probe.json carries the plan and the e-mail of the sign-in: the student's eyes only
PROBE_DIR="${HPCW_PROBE_DIR:-${SLURM_SUBMIT_DIR:-$PWD}}"
cd "$PROBE_DIR" || { echo "REFUSING: cannot enter $PROBE_DIR"; exit 1; }
[ -s probe.env ] || { echo "REFUSING: no probe.env in $PROBE_DIR (submit with: hpcworker probe)"; exit 1; }
# shellcheck disable=SC1091
source ./probe.env
: "${HPCW_HOME:?probe.env must set HPCW_HOME}"
# the code's directory (a shared copy's numbered directory); a probe.env written before framework 5 has only HPCW_HOME
HPCW_CODE="${HPCW_CODE:-$HPCW_HOME}"
# shellcheck disable=SC1090
source "$HPCW_CODE/lib/adapters/common.sh"
JOB=$(hpcw_job_id)
[ -n "$JOB" ] || { echo "REFUSING: the probe runs a container and must run inside a job, not on $(hostname -s)"; exit 1; }
say() { echo "$(date -u +%FT%TZ) $*"; }
J() { hpcw_json_str "$1"; }
NODE=$(hostname -s)
say "probe job $JOB on $NODE"
export RUNTIME RUNTIME_BIN RUNTIME_MODULE HPCW_NODE_TMP_PATTERN HPCW_NODE_TMP_VAR HPCW_TMPDIR_IS_NODE_LOCAL

# ---- node-local temp, /dev/shm, namespaces ----------------------------------------------------
HPCW_NODE_TMP=$(hpcw_node_tmp); export HPCW_NODE_TMP
mkdir -p "$HPCW_NODE_TMP/tmp" "$HPCW_NODE_TMP/cache" 2>/dev/null && NT_OK=true || NT_OK=false
# the only deletion the probe performs: its own per-job directories, through the guarded helper
trap 'hpcw_rm_own_tmp "$HPCW_NODE_TMP" "$IPC_DIR/$USER/hpcw_probe_$JOB"' EXIT
NT_FREE_GB=$(df -Pk "$HPCW_NODE_TMP" 2>/dev/null | awk 'NR==2{printf "%.1f", $4/1048576}'); NT_FREE_GB=${NT_FREE_GB:-0}
NT_FS=$(stat -f -c %T "$HPCW_NODE_TMP" 2>/dev/null || echo unknown)
NT_DEV=$(df -P "$HPCW_NODE_TMP" 2>/dev/null | awk 'NR==2{print $1}')
TMPDIR_VAL="${TMPDIR:-}"; TMPDIR_FS=""; TMPDIR_DEV=""
if [ -n "$TMPDIR_VAL" ] && [ -d "$TMPDIR_VAL" ]; then TMPDIR_FS=$(stat -f -c %T "$TMPDIR_VAL" 2>/dev/null); TMPDIR_DEV=$(df -P "$TMPDIR_VAL" 2>/dev/null | awk 'NR==2{print $1}'); fi
case "$TMPDIR_FS" in ext2|ext3|ext4|xfs|tmpfs|btrfs) TMPDIR_LOCAL=true;; "") TMPDIR_LOCAL=null;; *) TMPDIR_LOCAL=false;; esac
case "$TMPDIR_DEV" in *:*|ceph*|/rs/*) TMPDIR_LOCAL=false;; esac
SHM_KB=$(df -Pk /dev/shm 2>/dev/null | awk 'NR==2{print $2}'); SHM_KB=${SHM_KB:-0}
SHM_FREE_KB=$(df -Pk /dev/shm 2>/dev/null | awk 'NR==2{print $4}'); SHM_FREE_KB=${SHM_FREE_KB:-0}
IPC="$IPC_DIR/$USER/hpcw_probe_$JOB"; mkdir -p "$IPC" 2>/dev/null && chmod 700 "$IPC" && SHM_W=true || SHM_W=false
NS_MAX=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo -1)
if command -v unshare >/dev/null 2>&1 && unshare -U true 2>/dev/null; then NS_UNSHARE=true; else NS_UNSHARE=false; fi
RUN_USER_DIR="/run/user/$(id -u)"; [ -d "$RUN_USER_DIR" ] && RUN_USER=true || RUN_USER=false
XDG="$IPC_DIR/$USER/xdg"; mkdir -p "$XDG" 2>/dev/null && chmod 700 "$XDG" && XDG_HOST=true || XDG_HOST=false
TMUX_V=$(tmux -V 2>/dev/null || true); SCRIPT_OK=false; command -v script >/dev/null 2>&1 && SCRIPT_OK=true
GLIBC=$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
SBATCH_ON_NODE=false; command -v sbatch >/dev/null 2>&1 && SBATCH_ON_NODE=true   # the always-on chain re-submits from the compute node
say "node_tmp $HPCW_NODE_TMP ($NT_FS, ${NT_FREE_GB} GB free); TMPDIR=$TMPDIR_VAL ($TMPDIR_FS, local=$TMPDIR_LOCAL); shm ${SHM_KB}k; ns max=$NS_MAX unshare=$NS_UNSHARE; tmux='${TMUX_V}'; sbatch on node=$SBATCH_ON_NODE"

# ---- the runtime and the image ----------------------------------------------------------------
RT_OK=false; RT_VER=""; NODE_V=""; CLAUDE_V=""; RC_FLAGS=""; EXEC_S=0; HELP_HEAD=""
export HPCW_BINDS="$BINDS"
CCD=$(hpcw_expand_job_vars "$CLAUDE_CONFIG_DIR")
mkdir -p "$WORKSPACE" 2>/dev/null || true
CLEAN=(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR -u CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR
       -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -u DISABLE_GROWTHBOOK HOME="$HOME" CLAUDE_CONFIG_DIR="$CCD" DISABLE_AUTOUPDATER=1 TERM=xterm-256color BROWSER=/bin/false TMPDIR=/tmp XDG_RUNTIME_DIR="$XDG")
if hpcw_load_runtime; then
  RT_OK=true; RT_VER=$("$RUNTIME_BIN" --version 2>&1 | head -1)
  # in_image.sh: one command inside the image with Claude Code's clean environment (a file, as the
  # worker does it, so `timeout` runs it and nothing is quoted twice)
  { echo '#!/bin/bash'; echo "# written by hpcworker probe job $JOB on $NODE"
    echo "export RUNTIME=$(printf %q "$RUNTIME") RUNTIME_BIN=$(printf %q "$RUNTIME_BIN") RUNTIME_MODULE=$(printf %q "$RUNTIME_MODULE") HPCW_BINDS=$(printf %q "$BINDS") HPCW_NODE_TMP=$(printf %q "$HPCW_NODE_TMP") HPCW_JOB_ID=$(printf %q "$JOB")"
    echo "source $(printf %q "$HPCW_CODE/lib/adapters/common.sh")"
    printf 'hpcw_runtime_exec %q' "$IMAGE"; for a in "${CLEAN[@]}"; do printf ' %q' "$a"; done; echo ' "$@"'; } > in_image.sh.part
  chmod 700 in_image.sh.part && mv -f in_image.sh.part in_image.sh
  # The budgets, in seconds, and their sum: the first exec pays for the runtime's start-up, the rest
  # are one short command each. 90 + 60 + 45 + 45 + 60 = 300, five minutes of a ten-minute wall
  # time; change one and keep the sum under six minutes. Measured on probe 40501174 (asx1,
  # 2026-09-29): 29 s to the first answer where an earlier probe on the same node took 1 s, so a
  # budget under 45 s can be all start-up; the two 30 s calls of that run came back empty.
  in_image() { local t="$1"; shift; timeout "$t" "$PROBE_DIR/in_image.sh" "$@"; }
  t0=$(date +%s)
  NODE_V=$(in_image 90 node --version 2>&1 | tail -1)
  EXEC_S=$(( $(date +%s) - t0 ))
  CLAUDE_V=$(in_image 60 "$CLAUDE_BIN" --version 2>&1 | tail -1)
  HELP=$(in_image 45 "$CLAUDE_BIN" remote-control --help 2>&1 || true)
  RC_FLAGS=$(printf '%s' "$HELP" | grep -o -- '--[a-z][a-z-]*' | sort -u | tr '\n' ' ')
  # the first lines of what --help printed, so an error ("not logged in", a TTY complaint) is visible
  HELP_HEAD=$(printf '%s' "$HELP" | hpcw_strip_codes | grep -v '^[[:space:]]*$' | head -6 | cut -c1-160 | tr '\n' ' ')
  # Claude Code's own account of its stored login: three fields, never the token
  AUTH=$(in_image 45 "$CLAUDE_BIN" auth status 2>/dev/null || true)
  LOGGED_IN=$(printf '%s' "$AUTH" | grep -o '"loggedIn": *\(true\|false\)' | head -1 | grep -o 'true\|false'); LOGGED_IN=${LOGGED_IN:-false}
  AUTH_EMAIL=$(printf '%s' "$AUTH" | grep -o '"email": *"[^"]*"' | head -1 | cut -d'"' -f4)
  AUTH_SUB=$(printf '%s' "$AUTH" | grep -o '"subscriptionType": *"[^"]*"' | head -1 | cut -d'"' -f4)
  AUTH_METHOD=$(printf '%s' "$AUTH" | grep -o '"authMethod": *"[^"]*"' | head -1 | cut -d'"' -f4)
  # XDG fix as Claude Code's bash tool would see it, and curl from inside the image (its own CA
  # bundle), in one exec and one line, so the runtime starts once for both
  XC=$(in_image 60 bash -c 'x=""; test -w "$XDG_RUNTIME_DIR" && mkdir -p "$XDG_RUNTIME_DIR/probe" && x=writable; c=$(curl -s -m 10 -o /dev/null -w "%{http_code}" https://api.anthropic.com/ 2>/dev/null); echo "xdg=$x curl=${c:-000}"' 2>/dev/null | grep '^xdg=' | tail -1)
  XDG_IN=$(printf '%s' "$XC" | sed -n 's/^xdg=\([^ ]*\).*/\1/p'); CURL_IN=$(printf '%s' "$XC" | sed -n 's/.*curl=\(.*\)$/\1/p')
  say "runtime $RT_VER; node $NODE_V (${EXEC_S}s); claude $CLAUDE_V; flags: $RC_FLAGS; loggedIn=$LOGGED_IN; xdg in image: $XDG_IN; curl in image: $CURL_IN"
else
  LOGGED_IN=false; AUTH_EMAIL=""; AUTH_SUB=""; AUTH_METHOD=""; XDG_IN=""; CURL_IN=""
  say "no container runtime could be loaded on $NODE (RUNTIME=$RUNTIME RUNTIME_BIN=$RUNTIME_BIN RUNTIME_MODULE=$RUNTIME_MODULE)"
fi
# the sign-in flow is not measured here (see the header); the panel's sitting reports its own lines
LOGIN_FLOW='{"tried":false,"note":"not probed; the sign-in sitting itself is the test"}'

# ---- egress: the three hosts, with the inherited proxy variables and without ---------------------
# six curls of at most 10 s each: one more minute at the worst
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$1/" 2>/dev/null || echo 000; }
strip_userinfo() { printf '%s' "$1" | sed 's#//[^/@]*@#//#'; }   # a proxy URL may carry a password: never record it
PROXY_JSON=$(printf '{"https_proxy":%s,"http_proxy":%s,"no_proxy":%s}' "$(J "$(strip_userinfo "${https_proxy:-${HTTPS_PROXY:-}}")")" "$(J "$(strip_userinfo "${http_proxy:-${HTTP_PROXY:-}}")")" "$(J "${no_proxy:-${NO_PROXY:-}}")")
E_API=$(code api.anthropic.com); E_PLAT=$(code platform.claude.com); E_CLAUDE=$(code claude.ai)
N_API=$(env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY -u no_proxy -u NO_PROXY bash -c "$(declare -f code); code api.anthropic.com")
N_PLAT=$(env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY -u no_proxy -u NO_PROXY bash -c "$(declare -f code); code platform.claude.com")
N_CLAUDE=$(env -u https_proxy -u HTTPS_PROXY -u http_proxy -u HTTP_PROXY -u no_proxy -u NO_PROXY bash -c "$(declare -f code); code claude.ai")
STATSIG=$(getent hosts statsig.anthropic.com 2>/dev/null | awk '{print $1}' | head -1); [ -n "$STATSIG" ] || STATSIG="no DNS record"
reach() { case "$1" in 000) echo false;; *) echo true;; esac; }
if [ "$(reach "$N_API")" = true ] && [ "$(reach "$N_PLAT")" = true ]; then EGRESS=direct
elif [ "$(reach "$E_API")" = true ] && [ "$(reach "$E_PLAT")" = true ]; then EGRESS=http-proxy-auto
else EGRESS=none; fi
say "egress: inherited api=$E_API platform=$E_PLAT claude.ai=$E_CLAUDE; bare api=$N_API platform=$N_PLAT claude.ai=$N_CLAUDE; statsig: $STATSIG; class $EGRESS"

# ---- consent and config-dir presence ----------------------------------------------------------------
# Claude Code's own record first (remoteDialogSeen, one boolean in .claude.json), the marker files second
CONSENT=false; CONSENT_SOURCE=none
if hpcw_consent_seen "$CCD"; then CONSENT=true; CONSENT_SOURCE=claude_config
else IFS=':' read -r -a MARKERS <<< "${CONSENT_MARKERS:-}"; for m in "${MARKERS[@]}"; do [ -n "$m" ] && [ -e "$m" ] && { CONSENT=true; CONSENT_SOURCE=marker; }; done; fi
CCD_PRESENT=false; [ -d "$CCD" ] && CCD_PRESENT=true
WS_TRUSTED=false; hpcw_workspace_trusted "$CCD" "$WORKSPACE" && WS_TRUSTED=true

# ---- probe.json ------------------------------------------------------------------------------
cat > probe.json.part <<EOF
{"version":2,"when":$(J "$(date -u +%FT%TZ)"),"job":$(J "$JOB"),"hostname":$(J "$NODE"),"os":$(J "$OS"),"glibc":$(J "$GLIBC"),
 "node_tmp":{"path":$(J "$HPCW_NODE_TMP"),"ok":$NT_OK,"free_gb":${NT_FREE_GB},"fs":$(J "$NT_FS"),"device":$(J "$NT_DEV")},
 "tmpdir":{"value":$(J "$TMPDIR_VAL"),"fs":$(J "$TMPDIR_FS"),"device":$(J "$TMPDIR_DEV"),"node_local":$TMPDIR_LOCAL},
 "dev_shm":{"size_kb":${SHM_KB},"free_kb":${SHM_FREE_KB},"writable":$SHM_W},
 "user_namespaces":{"max":${NS_MAX},"unshare_works":$NS_UNSHARE},
 "run_user_dir":{"path":$(J "$RUN_USER_DIR"),"present":$RUN_USER},
 "xdg_fix":{"dir":$(J "$XDG"),"host_writable":$XDG_HOST,"in_image":$(J "$XDG_IN")},
 "tmux":{"present":$([ -n "$TMUX_V" ] && echo true || echo false),"version":$(J "$TMUX_V")},"script_present":$SCRIPT_OK,"sbatch_on_node":$SBATCH_ON_NODE,
 "runtime":{"ok":$RT_OK,"name":$(J "$RUNTIME"),"bin":$(J "${RUNTIME_BIN:-}"),"module":$(J "${RUNTIME_MODULE:-}"),"version":$(J "$RT_VER")},
 "image":{"type":$(J "$IMAGE_TYPE"),"path":$(J "$IMAGE"),"node_version":$(J "$NODE_V"),"claude_version":$(J "$CLAUDE_V"),"first_exec_seconds":${EXEC_S},"curl_api_from_image":$(J "$CURL_IN")},
 "remote_control_flags":$(J "$RC_FLAGS"),"remote_control_help_head":$(J "$HELP_HEAD"),
 "claude_auth":{"loggedIn":$LOGGED_IN,"subscriptionType":$(J "$AUTH_SUB"),"email":$(J "$AUTH_EMAIL"),"authMethod":$(J "$AUTH_METHOD"),"config_dir_present":$CCD_PRESENT},
 "consent_recorded":$CONSENT,"consent_source":$(J "$CONSENT_SOURCE"),"workspace_trusted":$WS_TRUSTED,
 "login_flow":$LOGIN_FLOW,
 "egress":{"class":$(J "$EGRESS"),"inherited_proxy":$PROXY_JSON,
  "with_inherited_env":{"api.anthropic.com":$(J "$E_API"),"platform.claude.com":$(J "$E_PLAT"),"claude.ai":$(J "$E_CLAUDE")},
  "without_proxy_vars":{"api.anthropic.com":$(J "$N_API"),"platform.claude.com":$(J "$N_PLAT"),"claude.ai":$(J "$N_CLAUDE")},
  "statsig.anthropic.com":$(J "$STATSIG")}}
EOF
mv -f probe.json.part probe.json
say "probe.json written: $PROBE_DIR/probe.json"
