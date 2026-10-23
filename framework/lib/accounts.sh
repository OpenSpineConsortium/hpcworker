# shellcheck shell=bash
# ---- framework 21: several Claude accounts on the grid, one in use at a time -------------------------
# Sourced by bin/hpcworker after lib/adapters/common.sh. Bash 4.2 (EL7), coreutils, grep, sed; nothing
# here runs python3 on the login node (lib/accounts_read.py runs only inside a job, on a compute node).
#
#   hpcworker accounts list [--json]          the accounts signed in on the grid, which one is in use,
#                                             their latest usage reading, auto mode, the worker
#   hpcworker accounts use N                  account N from now on; a running worker moves to it
#                                             within seconds (Remote Control starts again on it)
#   hpcworker accounts login N                a person at a terminal: the sign-in sitting, into account N
#   hpcworker accounts login N --detach [--wait S]
#                                             the sitting as a job of its own, for the control panel:
#                                             Anthropic's link in a file `accounts link N` prints, the
#                                             code from `accounts code N CODE`
#   hpcworker accounts link N                 that link, once the job has it
#   hpcworker accounts code N CODE|- [--wait S]
#                                             the code from Anthropic's page, for the sitting of N (- reads it from stdin)
#   hpcworker accounts usage [--wait S]       one short job reads every account's use (one word on
#                                             Haiku each, which spends that word of its window)
#   hpcworker accounts auto on|off            auto mode: a worker whose account reaches 90% of a window
#                                             moves to the signed-in account with the most room;
#                                             framework 28: a workspace with the Symphony template's
#                                             tools/handoff.py is asked for its handoff first
#                                             (accounts/<N>.handoff-due, answered by <N>.handoff.json)
#                                             and the move waits for it, at most HPCW_HANDOFF_GRACE_S (900)
#   hpcworker accounts forget N               account N's folder moved aside under accounts/.forgotten;
#                                             nothing is deleted, and the account in use is refused
#   hpcworker accounts start N [NAME]         framework 22: a worker of its own on account N, kept to it
#                                             (no swap, no auto mode), named NAME or accountN; several
#                                             run at once, each its own Remote Control session on its
#                                             own account and its own workspace
#   hpcworker accounts stop NAME              that worker stopped, as worker stop does
#
# The layout, under the folder that holds the profile's claude_config_dir (at Wayne State ~/.beethoven):
#   claude                  a link, accounts/<N>, to the account in use: Claude Code's CLAUDE_CONFIG_DIR
#                           everywhere it was before, so every older piece reads the same path
#   accounts/<N>/           one Claude Code config folder per account, 0700, Claude Code's own
#   accounts/<N>.who.json   what `claude auth status` said (signed in with a subscription, e-mail, plan)
#   accounts/<N>.use.json   the last usage reading (five-hour and seven-day windows, their resets)
#   accounts/auto           "on" while auto mode is on
# N is 1 to 32, the Symphony token pool's slot numbers, so one Claude account has one number in both.
# The first verb that finds claude as a plain folder makes it account 1 (or the first free number) by a
# rename and a link: nothing is copied and nothing is deleted. The sitting's and the usage job's own
# files live in the state directory under .accounts/.
#
# What this never does: read a credential (Claude Code keeps its own; `claude auth status` and the
# probe's rate_limit_event are read, as the worker reads them), sign anyone out, or delete anything:
# forget moves a folder aside. A sign-in through a job (--detach) is the control panel's: the panel
# reaches it through the grid gate of a private repository, whose workflow lets only an admin of the
# repository ask, and hands Anthropic's link back sealed for the browser that asked (symphony-template
# grid-accounts.yml). Through Beethoven's browser key no verb here is reachable.

ACCT_SLOT_RE='^([1-9]|[12][0-9]|3[0-2])$'
ACCT_SLOTS=$(seq 1 32)
ACCT_LOGIN_MIN=25       # wall time of the sitting's job, minutes; a code later than this misses it
ACCT_USAGE_MIN=10       # the usage job's least wall time; three minutes more for each account
ACCT_STALE_S=1800       # a sitting or usage job with no end after this long counts as gone
ACCT_PROBE='Reply with the one word ok.'

acct_init() { # after load_profile: where the accounts are
  ACCT_LINK="$CCD_LINK"
  ACCT_DIR="$(dirname "$ACCT_LINK")/accounts"
  ACCT_WORK="$STATE_DIR/.accounts"
}
acct_slot_ok() { [[ "${1:-}" =~ $ACCT_SLOT_RE ]]; }
acct_need_slot() { acct_slot_ok "${1:-}" || die "accounts: the account is a number from 1 to 32, not '${1:-}'"; }
acct_target() { # the folder claude names now: itself when it is no link, else the link's target one level, logically
  local t; [ -L "$ACCT_LINK" ] || { printf '%s' "$ACCT_LINK"; return 0; }
  t=$(readlink "$ACCT_LINK") || { printf '%s' "$ACCT_LINK"; return 0; }
  case "$t" in /*) printf '%s' "$t";; *) printf '%s/%s' "$(dirname "$ACCT_LINK")" "$t";; esac
}
acct_current() { # the number of the account in use, nothing when claude is not a link to one
  local t; t=$(acct_target)
  case "$t" in "$ACCT_DIR"/*) t=${t#"$ACCT_DIR"/}; acct_slot_ok "$t" && printf '%s' "$t";; esac
  return 0
}
acct_slots() { local n; for n in $ACCT_SLOTS; do [ -d "$ACCT_DIR/$n" ] && [ ! -L "$ACCT_DIR/$n" ] && echo "$n"; done; return 0; }
acct_free_slot() { local n; for n in $ACCT_SLOTS; do [ -e "$ACCT_DIR/$n" ] || [ -L "$ACCT_DIR/$n" ] || { echo "$n"; return 0; }; done; return 1; }
acct_write() { # FILE TEXT: written whole through a temporary name, 0600
  local part="$1.part$$"
  ( umask 077; printf '%s\n' "$2" > "$part" ) 2>/dev/null && mv -f "$part" "$1" 2>/dev/null || { rm -f "$part"; return 1; }
}
acct_mkdir() { ( umask 077; mkdir -p "$1" ) 2>/dev/null && [ -d "$1" ] && [ ! -L "$1" ] && chmod 700 "$1" 2>/dev/null; }
acct_link() { # N: claude -> accounts/N, replaced in one rename so no reader ever finds it missing
  local tmp="$ACCT_LINK.hpcw$$"
  rm -f "$tmp" 2>/dev/null
  ln -s "accounts/$1" "$tmp" 2>/dev/null && mv -Tf "$tmp" "$ACCT_LINK" 2>/dev/null || { rm -f "$tmp"; return 1; }
}
# The newest worker heartbeat carries Claude Code's own answer about the sign-in it ran on: an account
# made from the plain folder starts with what it said, so the panel can name it before any usage job
acct_seed_who() { # N
  local best="" bt=0 d m t li em pl
  for d in "$STATE_DIR"/*/; do [ -s "$d/status.json" ] || continue; m=$(stat -c %Y "$d/status.json"); [ "$m" -gt "$bt" ] && { bt=$m; best="$d/status.json"; }; done
  [ -n "$best" ] || return 0
  t=$(tr -d '\n' < "$best" | grep -o '"claude_login": *{[^}]*}') || return 0
  li=$(printf '%s' "$t" | grep -o '"loggedIn": *\(true\|false\)' | grep -o 'true\|false')
  em=$(printf '%s' "$t" | grep -o '"email": *"[^"]*"' | cut -d'"' -f4)
  pl=$(printf '%s' "$t" | grep -o '"subscriptionType": *"[^"]*"' | cut -d'"' -f4)
  [ "$li" = true ] || return 0
  acct_write "$ACCT_DIR/$1.who.json" "$(printf '{"checked_at":%s,"email":%s,"plan":%s,"sign_in":"subscription","signed_in":true,"slot":"%s","v":1}' \
    "$(json_str "$(date -u -d "@$bt" +%FT%TZ)")" "$(json_str "$em")" "$(json_str "$pl")" "$1")"
}
acct_adopt() { # claude as a plain folder becomes an account; nothing when it is a link already
  [ -L "$ACCT_LINK" ] && return 0
  acct_mkdir "$ACCT_DIR" || die "accounts: cannot make $ACCT_DIR"
  [ -e "$ACCT_LINK" ] || return 0
  [ -d "$ACCT_LINK" ] || die "accounts: $ACCT_LINK is neither a folder nor a link; nothing was changed"
  # two verbs at once (a terminal and the panel) must not both move it: one lock, and the test again under it
  local lock; lock="$(dirname "$ACCT_LINK")/.accounts.lock"
  mkdir "$lock" 2>/dev/null || { sleep 2; [ -L "$ACCT_LINK" ] && return 0; die "accounts: another accounts command is making the first account; try again"; }
  if [ -L "$ACCT_LINK" ]; then rmdir "$lock"; return 0; fi
  local n; n=$(acct_free_slot) || { rmdir "$lock"; die "accounts: all 32 numbers are taken; nothing was changed"; }
  mv "$ACCT_LINK" "$ACCT_DIR/$n" 2>/dev/null || { rmdir "$lock"; die "accounts: could not move $ACCT_LINK to $ACCT_DIR/$n; nothing was changed"; }
  if ! ln -s "accounts/$n" "$ACCT_LINK" 2>/dev/null; then
    mv "$ACCT_DIR/$n" "$ACCT_LINK" 2>/dev/null; rmdir "$lock"
    die "accounts: could not link $ACCT_LINK to $ACCT_DIR/$n; it was put back"
  fi
  rmdir "$lock"
  acct_seed_who "$n"
  ACCT_ADOPTED="$n"
}
acct_one_line() { # FILE -> its JSON object when it is one we wrote (one line, an object, small); else null
  local t
  if [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %s "$1" 2>/dev/null || echo 99999)" -lt 8192 ]; then
    t=$(head -n 1 "$1"); case "$t" in "{"*"}") printf '%s' "$t"; return 0;; esac
  fi
  printf 'null'
}
acct_field() { # JSON KEY -> a top-level plain string or true/false (the files are ours: one line, no nesting before it)
  printf '%s' "$1" | grep -o "\"$2\": *\(\"[^\"]*\"\|true\|false\)" | head -1 | sed -e "s/^\"$2\": *//" -e 's/^"//' -e 's/"$//'
}

# ---- what a job printed, for the control panel's Console (framework 23) ---------------------------------
# A job's log reaches the panel through the gate and the branch grid, so it is cleaned first: no terminal
# codes, no byte outside printable ASCII, no line over 300 characters, and any run of 32 or more letters
# and digits hidden, which is the shape of every token, key and code Claude Code or Anthropic's page prints
acct_clean() { # stdin -> stdout
  hpcw_strip_codes | LC_ALL=C tr -cd '\11\12\40-\176' | cut -c1-300 \
    | sed -E -e 's/[A-Za-z0-9_+=-]{32,}/[hidden]/g' -e 's/(sk-ant|oauth|token|secret|password)[^ ]*[:=][^ ]*/\1 [hidden]/Ig'
}
acct_last_said() { # FILE -> its last line that says something, cleaned, at most 200 characters
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  tail -c 8000 "$1" 2>/dev/null | acct_clean | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-200
}
acct_show() { # TITLE FILE LINES
  [ -s "$2" ] && [ ! -L "$2" ] || { echo "--- $1: nothing yet"; return 0; }
  echo "--- $1 (last $3 lines)"
  tail -c 40000 "$2" 2>/dev/null | acct_clean | grep -v '^[[:space:]]*$' | tail -n "$3"
}
acct_log() { # login N | usage | worker NAME: what that job printed, between two marker lines
  local what="${1:-}" w
  case "$what" in
    login) acct_need_slot "${2:-}"; w=$(acct_login_dir "$2")
      echo "HPCW-ACCOUNTS-LOG-BEGIN login $2"
      acct_show "the sign-in's own lines" "$w/out" 80
      acct_show "the job's output (stdout and stderr)" "$w/job.log" 120;;
    usage) w="$ACCT_WORK/usage"
      echo "HPCW-ACCOUNTS-LOG-BEGIN usage"
      acct_show "the job's output (stdout and stderr)" "$w/job.log" 120;;
    worker) [[ "${2:-}" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "accounts: log worker needs a worker's name"
      w="$STATE_DIR/$2"; [ -d "$w" ] && [ ! -L "$w" ] || die "accounts: there is no worker named $2"
      echo "HPCW-ACCOUNTS-LOG-BEGIN worker $2"
      acct_show "Claude Code's terminal" "$w/rc.log" 120
      acct_show "the job's output (stdout and stderr)" "$(ls -t "$w"/slurm_*.out "$w"/pbs.out "$w"/lsf_*.out 2>/dev/null | head -1)" 80;;
    *) die "accounts: log login N, log usage or log worker NAME";;
  esac
  echo "HPCW-ACCOUNTS-LOG-END"
}

# ---- the sitting as a job (the control panel's sign-in) --------------------------------------------
acct_login_dir() { echo "$ACCT_WORK/login-$1"; }
acct_job_live() { # DIR: a job was started there, has not said it ended, and is younger than the stale bound
  [ -s "$1/job.id" ] && [ ! -e "$1/done" ] && [ $(( $(date +%s) - $(stat -c %Y "$1/job.id" 2>/dev/null || echo 0) )) -lt "$ACCT_STALE_S" ]
}
acct_login_state() { # N -> "STATE|SENTENCE": none | waiting | link | code | signed-in | failed
  local w; w=$(acct_login_dir "$1")
  [ -s "$w/job.id" ] || { echo "none|"; return 0; }
  local out="$w/out" l
  if [ -s "$out" ]; then
    l=$(grep -E ' (SIGNED-IN|HPCW-LOGIN-FAILED:)' "$out" | tail -1)
    case "$l" in
      *" SIGNED-IN "*) echo "signed-in|Signed in as ${l##* SIGNED-IN }"; return 0;;
      *HPCW-LOGIN-FAILED:*) echo "failed|${l#*HPCW-LOGIN-FAILED: }"; return 0;;
    esac
  fi
  if [ -e "$w/done" ]; then
    l=$(acct_last_said "$w/job.log")
    echo "failed|The sign-in ended without a word from Claude Code${l:+; the last line it printed: $l} (its log is $w/job.log; Console shows it whole)"; return 0
  fi
  acct_job_live "$w" || { echo "failed|The sign-in's job is gone (wall time, or the grid ended it); start it again"; return 0; }
  if [ -s "$out" ] && grep -q ' code received, checking' "$out" && ! grep -q 'that code was not accepted' <(sed -n '/code received, checking/,$p' "$out" | tail -n +2); then echo "code|Checking the code"; return 0; fi
  if [ -s "$out" ] && grep -q ' AUTH-URL: ' "$out"; then
    if grep -q 'that code was not accepted' "$out"; then echo "link|That code was not accepted; paste it again"; else echo "link|Open the link, sign in, and paste the code if the page shows one"; fi
    return 0
  fi
  echo "waiting|Waiting for a computer and for Claude Code's link"
}
acct_link_url() { # N -> the link the sitting printed, nothing when none; only Anthropic's own hosts
  local w l; w=$(acct_login_dir "$1")
  [ -s "$w/out" ] || return 0
  l=$(grep ' AUTH-URL: ' "$w/out" | tail -1); l=${l##* AUTH-URL: }
  [[ "$l" =~ ^https://(claude\.ai|claude\.com)/[A-Za-z0-9._~:/?#@!\$\&\'\(\)*+,\;=%-]{1,2000}$ ]] && printf '%s' "$l"
  return 0
}
acct_wait_login() { # N SECONDS UNTIL_STATES: wait, reading files every 2 s, for one of the states (a|b|c)
  local i=0 s
  while :; do
    s=$(acct_login_state "$1"); s=${s%%|*}
    [[ "$s" =~ ^($3)$ ]] && return 0
    [ $i -ge "$2" ] && return 0
    sleep 2; i=$((i + 2))
  done
}
acct_submit() { # DIR NAME MINUTES VERB...: one job that runs this command's VERB; its id in DIR/job.id
  local w="$1" name="$2" min="$3"; shift 3
  local self="$SELF" q
  { echo '#!/bin/bash'; echo "# written by hpcworker accounts: one short job"
    printf 'exec /bin/bash %q accounts' "$self"; for q in "$@"; do printf ' %q' "$q"; done; echo; } > "$w/job.sh.part" \
    && chmod 700 "$w/job.sh.part" && mv -f "$w/job.sh.part" "$w/job.sh" || die "accounts: cannot write $w/job.sh"
  local id
  # nothing of a gate or an ssh command rides into the job, where it would bar the sitting (sbatch exports all)
  id=$(unset HPCW_GATE HPCW_GATE_SLOT SSH_ORIGINAL_COMMAND; adapter_submit "$w/job.sh" -p "$P_partition_cpu" ${P_qos_cpu:+--qos="$P_qos_cpu"} -t "00:$(printf '%02d' "$min"):00" -N 1 -n 1 --mem=2G \
       -J "$name" -D "$w" --output "$w/job.log") || die "accounts: the scheduler refused the job"
  acct_write "$w/job.id" "$id" || die "accounts: cannot write $w/job.id"
  echo "$id"
}

cmd_accounts() {
  # Beethoven's browser key never reaches these verbs (its gate takes eight others); this is the backstop
  hpcw_under_gate && die "accounts: not through Beethoven's browser key"
  load_profile
  acct_init
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list) acct_list "$@";;
    use) acct_use "$@";;
    login) acct_login "$@";;
    link) acct_need_slot "${1:-}"; local u; u=$(acct_link_url "$1"); [ -n "$u" ] || { echo "HPCW-ACCOUNTS no link for account $1 yet"; return 3; }; echo "AUTH-URL: $u";;
    code) acct_code "$@";;
    usage) acct_usage "$@";;
    auto) acct_auto "$@";;
    forget) acct_forget "$@";;
    start) acct_start "$@";;
    stop) acct_stop "$@";;
    log) acct_log "$@";;
    _login-job) acct_login_job "$@";;
    _usage-job) acct_usage_job "$@";;
    *) die "accounts: list | use N | login N [--detach] | link N | code N CODE | usage | auto on|off | forget N | start N [NAME] | stop NAME";;
  esac
}

acct_list() {
  local json=0; [ "${1:-}" = --json ] && json=1
  acct_adopt
  local cur auto=false n first=1 who use st
  cur=$(acct_current)
  [ "$(head -c 2 "$ACCT_DIR/auto" 2>/dev/null)" = on ] && auto=true
  if [ $json = 0 ]; then
    [ -n "${ACCT_ADOPTED:-}" ] && say "Your sign-in folder is now account $ACCT_ADOPTED ($ACCT_DIR/$ACCT_ADOPTED); $ACCT_LINK points at it."
    say "Auto mode: $([ $auto = true ] && echo on || echo off)"
    for n in $(acct_slots); do
      who=$(acct_one_line "$ACCT_DIR/$n.who.json")
      st=$(acct_login_state "$n")
      printf '%s account %s: %s%s\n' "$([ "$n" = "$cur" ] && echo '*' || echo ' ')" "$n" \
        "$(if [ "$(acct_field "$who" signed_in)" = true ]; then echo "$(acct_field "$who" email) ($(acct_field "$who" plan))"; elif [ "$who" = null ]; then echo "not read yet"; elif [ "$(acct_field "$who" sign_in)" = unread ]; then echo "not checked (the last check got no answer)"; else echo "not signed in"; fi)" \
        "$([ "${st%%|*}" != none ] && echo "; sign-in: ${st#*|}")"
    done
    [ -n "$(acct_slots)" ] || say "No account yet: hpcworker accounts login 1"
    return 0
  fi
  printf '{"v":1,"framework":%s,"current":%s,"auto":%s,"accounts":[' "$VERSION" "$([ -n "$cur" ] && json_str "$cur" || echo null)" "$auto"
  for n in $(acct_slots); do
    who=$(acct_one_line "$ACCT_DIR/$n.who.json"); use=$(acct_one_line "$ACCT_DIR/$n.use.json"); st=$(acct_login_state "$n")
    [ $first = 1 ] || printf ','; first=0
    printf '{"slot":"%s","current":%s,"who":%s,"use":%s,"login":{"state":%s,"line":%s}}' "$n" "$([ "$n" = "$cur" ] && echo true || echo false)" \
      "$who" "$use" "$(json_str "${st%%|*}")" "$(json_str "${st#*|}")"
  done
  local uw; uw="$ACCT_WORK/usage"
  printf '],"usage_job":%s,"worker":%s,"workers":%s}\n' "$(if acct_job_live "$uw"; then echo '"running"'; else echo null; fi)" "$(acct_worker_json)" "$(acct_workers_json)"
}
acct_worker_json() { # the newest worker heartbeat, the few fields the panel shows; null when there is none
  local best="" bt=0 d m
  for d in "$STATE_DIR"/*/; do [ "$(basename "$d")" = probe ] && continue; [ -s "$d/status.json" ] || continue; m=$(stat -c %Y "$d/status.json"); [ "$m" -gt "$bt" ] && { bt=$m; best="$d"; }; done
  [ -n "$best" ] || { printf 'null'; return 0; }
  local f="$best/status.json" a=""
  [ -s "$best/account" ] && a=$(head -c 3 "$best/account" | tr -dc '0-9')
  printf '{"name":%s,"state":%s,"message":%s,"job":%s,"node":%s,"link":%s,"updated_at":%s,"age_s":%s,"account":%s}' \
    "$(json_str "$(basename "$best")")" "$(json_str "$(read_field "$f" state)")" "$(json_str "$(read_field "$f" message | cut -c1-300)")" \
    "$(json_str "$(read_field "$f" job)")" "$(json_str "$(read_field "$f" node)")" "$(json_str "$(run_link "$f")")" \
    "$(json_str "$(read_field "$f" updated_at)")" "$(( $(date +%s) - bt ))" "$([ -n "$a" ] && json_str "$a" || echo null)"
}

acct_workers_json() { # framework 22: every worker with a heartbeat in the last day, newest first, as the panel lists them
  local d f m now first=1 a pin
  now=$(date +%s)
  printf '['
  for d in $(ls -1dt "$STATE_DIR"/*/ 2>/dev/null); do
    [ "$(basename "$d")" = probe ] && continue
    f="$d/status.json"; [ -s "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || echo 0); [ $(( now - m )) -lt 86400 ] || continue
    a=""; [ -s "$d/account" ] && a=$(head -c 3 "$d/account" | tr -dc '0-9')
    pin=$(acct_pin_of "$d")
    [ $first = 1 ] || printf ','; first=0
    printf '{"name":%s,"state":%s,"node":%s,"link":%s,"age_s":%s,"account":%s,"pinned":%s}' \
      "$(json_str "$(basename "$d")")" "$(json_str "$(read_field "$f" state)")" "$(json_str "$(read_field "$f" node)")" \
      "$(json_str "$(run_link "$f")")" "$(( now - m ))" "$([ -n "$a" ] && json_str "$a" || echo null)" "$([ -n "$pin" ] && json_str "$pin" || echo null)"
  done
  printf ']'
}
acct_pin_of() { local p; p=$(head -c 3 "$1/account.pin" 2>/dev/null | tr -dc '0-9'); [[ "$p" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] && printf '%s' "$p"; return 0; }
acct_pinned_live() { # N: the name of a live worker kept to account N, nothing when there is none
  local d st m
  for d in "$STATE_DIR"/*/; do
    [ "$(acct_pin_of "$d")" = "$1" ] || continue
    [ -s "$d/status.json" ] || continue
    st=$(read_field "$d/status.json" state); case "$st" in stopped|error) continue;; esac
    m=$(stat -c %Y "$d/status.json" 2>/dev/null || echo 0); [ $(( $(date +%s) - m )) -lt 86400 ] || continue
    basename "$d"; return 0
  done
  return 0
}
acct_start() { # N [NAME]: a worker of its own on account N (worker start --account N)
  acct_need_slot "${1:-}"
  local n="$1" name="${2:-account$1}"
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,24}$ ]] || die "accounts: a worker name is letters, digits, _ or -, at most 24"
  acct_adopt
  [ -d "$ACCT_DIR/$n" ] || die "accounts: there is no account $n yet (hpcworker accounts login $n signs one in)"
  [ "$(acct_field "$(acct_one_line "$ACCT_DIR/$n.who.json")" signed_in)" = false ] && die "accounts: account $n is not signed in with a Claude subscription (the last check said so); sign it in again first"
  cmd_worker start --name "$name" --account "$n" || return $?
  say "HPCW-ACCOUNTS start $n: worker $name asked for a computer on account $n"
}
acct_stop() { # NAME
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "accounts: stop needs a worker's name"
  [ -d "$STATE_DIR/$name" ] || die "accounts: there is no worker named $name"
  cmd_worker stop --name "$name" || return $?
  say "HPCW-ACCOUNTS stop $name: stopped"
}

acct_use() {
  acct_need_slot "${1:-}"
  local n="$1" who
  acct_adopt
  [ -d "$ACCT_DIR/$n" ] || die "accounts: there is no account $n yet (hpcworker accounts login $n signs one in)"
  who=$(acct_one_line "$ACCT_DIR/$n.who.json")
  [ "$(acct_field "$who" signed_in)" = false ] && die "accounts: account $n is not signed in with a Claude subscription (the last check said so); sign it in again first"
  [ "$(acct_current)" = "$n" ] && { say "HPCW-ACCOUNTS use $n: already in use"; return 0; }
  # a worker of framework 20 or older runs Claude Code through the link itself, so moving the link would
  # change its account mid-run: it is stopped and started again first (it then follows every move)
  local old; old=$(acct_old_worker)
  [ -z "$old" ] || die "accounts: your worker runs framework $old, which cannot move between accounts; stop it and start it again (it then runs framework $VERSION), then use $n. Nothing was changed."
  acct_link "$n" || die "accounts: could not point $ACCT_LINK at account $n; nothing was changed"
  say "HPCW-ACCOUNTS use $n: in use now; a running worker moves to it within seconds"
}

acct_old_worker() { # the framework of a live worker older than 21, nothing when there is none
  local d v st m
  for d in "$STATE_DIR"/*/; do
    [ -s "$d/status.json" ] || continue
    m=$(stat -c %Y "$d/status.json" 2>/dev/null || echo 0); [ $(( $(date +%s) - m )) -lt 300 ] || continue
    st=$(read_field "$d/status.json" state); case "$st" in online|starting|running|need_consent) ;; *) continue;; esac
    v=$(read_field "$d/status.json" version); [[ "$v" =~ ^[0-9]{1,4}$ ]] && [ "$v" -lt 21 ] && { echo "$v"; return 0; }
  done
  return 0
}
acct_auto() {
  case "${1:-}" in
    on|off) acct_mkdir "$ACCT_DIR" || die "accounts: cannot make $ACCT_DIR"
      acct_write "$ACCT_DIR/auto" "$1" || die "accounts: cannot write $ACCT_DIR/auto"
      say "HPCW-ACCOUNTS auto $1";;
    *) die "accounts: auto on | auto off";;
  esac
}

acct_forget() {
  acct_need_slot "${1:-}"
  local n="$1" to
  acct_adopt
  [ -d "$ACCT_DIR/$n" ] || die "accounts: there is no account $n"
  [ "$(acct_current)" = "$n" ] && die "accounts: account $n is in use; use another first. Nothing was changed."
  acct_job_live "$(acct_login_dir "$n")" && die "accounts: a sign-in for account $n is under way. Nothing was changed."
  local held; held=$(acct_pinned_live "$n")
  [ -z "$held" ] || die "accounts: worker $held runs on account $n; stop it first. Nothing was changed."
  to="$ACCT_DIR/.forgotten/$(date -u +%Y%m%dT%H%M%SZ)-$n"
  acct_mkdir "$to" || die "accounts: cannot make $to"
  mv "$ACCT_DIR/$n" "$to/claude" || die "accounts: could not move account $n aside"
  local f; for f in who use; do [ -e "$ACCT_DIR/$n.$f.json" ] && mv -f "$ACCT_DIR/$n.$f.json" "$to/$f.json"; done
  say "HPCW-ACCOUNTS forget $n: moved aside to $to (nothing was deleted)"
}

acct_login() {
  acct_need_slot "${1:-}"
  local n="$1" detach=0 wait_s=0; shift
  while [ $# -gt 0 ]; do case "$1" in
    --detach) detach=1; shift;;
    --wait) [[ "${2:-}" =~ ^[0-9]{1,3}$ ]] || die "accounts: --wait takes seconds"; wait_s="$2"; shift 2;;
    *) die "accounts login: unknown option $1";; esac; done
  acct_adopt
  acct_mkdir "$ACCT_DIR/$n" || die "accounts: cannot make $ACCT_DIR/$n"
  if [ $detach = 0 ]; then
    # a person at a terminal: today's sitting, into this account's folder
    hpcw_agent_marker && die "accounts login without --detach is for a person at a terminal"
    HPCW_ACCOUNT_SLOT="$n" PROFILE_LOADED="" cmd_claude login || return 1
    [ -n "$(acct_current)" ] || acct_link "$n"
    say "Account $n is signed in. hpcworker accounts use $n makes it the one in use."
    return 0
  fi
  local w; w=$(acct_login_dir "$n")
  acct_mkdir "$ACCT_WORK" && acct_mkdir "$w" || die "accounts: cannot make $w"
  if acct_job_live "$w"; then say "HPCW-ACCOUNTS login $n: already under way"
  else
    # a fresh sitting: the last one's files are this tool's own, emptied, never another's
    : > "$w/out"; : > "$w/code"; rm -f "$w/done"
    local id; id=$(acct_submit "$w" hpcw_acct_login "$ACCT_LOGIN_MIN" _login-job "$n") || return 1
    say "HPCW-ACCOUNTS login $n: job $id"
  fi
  [ "$wait_s" -gt 0 ] && acct_wait_login "$n" "$wait_s" 'link|signed-in|failed'
  local s; s=$(acct_login_state "$n"); say "HPCW-ACCOUNTS login $n ${s%%|*}: ${s#*|}"
}

acct_code() {
  acct_need_slot "${1:-}"
  local n="$1" code="${2:-}" wait_s=0 w; shift 2 2>/dev/null || shift $#
  while [ $# -gt 0 ]; do case "$1" in
    --wait) [[ "${2:-}" =~ ^[0-9]{1,3}$ ]] || die "accounts: --wait takes seconds"; wait_s="$2"; shift 2;;
    *) die "accounts code: unknown option $1";; esac; done
  # "-": the code on standard input, as the grid gate hands it on, so it is never in a process's arguments
  if [ "$code" = - ]; then IFS= read -r -t 10 code || true; fi
  # Anthropic's page shows the code as letters, digits, - and _, a # and the state after it
  [[ "$code" =~ ^[A-Za-z0-9_#.~-]{8,512}$ ]] || die "accounts: that is not a code Anthropic's page shows"
  w=$(acct_login_dir "$n")
  acct_job_live "$w" || die "accounts: no sign-in for account $n is waiting for a code; start one first"
  ( umask 077; printf '%s\n' "$code" > "$w/code.part" ) && mv -f "$w/code.part" "$w/code" || die "accounts: cannot hand the code on"
  # a fixed line: never the code itself
  say "HPCW-ACCOUNTS code $n: handed to the sitting"
  [ "$wait_s" -gt 0 ] && { sleep 3; acct_wait_login "$n" "$wait_s" 'signed-in|failed|link'; }
  local s; s=$(acct_login_state "$n"); say "HPCW-ACCOUNTS login $n ${s%%|*}: ${s#*|}"
}

# Inside the sitting's job: Claude Code's sitting reads the code from standard input, which is a pipe
# this job holds open; the code arrives as a file `accounts code` writes in the job's folder (a pipe
# cannot reach from the login node to this node), is handed on and emptied at once
acct_login_job() {
  acct_need_slot "${1:-}"
  in_job || die "accounts: _login-job runs inside its job"
  local n="$1" w nt pipe feeder rc l em pl
  w=$(acct_login_dir "$n")
  export HPCW_ACCOUNT_SLOT="$n"
  nt="$P_ipc_dir/$USER/hpcw_acct_$(hpcw_job_id)"
  acct_mkdir "$nt" || { echo "$(hpcw_now_iso) HPCW-LOGIN-FAILED: this compute node has no writable $P_ipc_dir" >> "$w/out"; touch "$w/done"; return 1; }
  pipe="$nt/code"; mkfifo -m 600 "$pipe" || { touch "$w/done"; return 1; }
  exec 8<>"$pipe"
  ( i=0; while [ $i -lt $(( ACCT_LOGIN_MIN * 60 )) ]; do
      if [ -s "$w/code" ]; then c=$(head -c 600 "$w/code"); : > "$w/code"; printf '%s\n' "$c" >&8; fi
      sleep 1; i=$((i + 1)); done ) &
  feeder=$!
  # through bash, never by the file's mode: a clone of the repository carries bin/hpcworker as 0644, and
  # run directly it was refused (Permission denied), which the panel read as a sign-in with no word
  "${BASH:-/bin/bash}" "$SELF" _exec login --plain --deadline $(( $(date +%s) + ACCT_LOGIN_MIN * 60 - 60 )) <&8 2>&1 \
    | while IFS= read -r l; do printf '%s %s\n' "$(hpcw_now_iso)" "$l" >> "$w/out"; done
  rc=${PIPESTATUS[0]}
  kill "$feeder" 2>/dev/null; exec 8>&-; rm -f "$pipe"; rmdir "$nt" 2>/dev/null
  : > "$w/code"
  l=$(grep ' SIGNED-IN ' "$w/out" | tail -1)
  if [ -n "$l" ]; then
    l=${l##* SIGNED-IN }; em=${l%% *}; pl=${l#* }; [ "$pl" = "$l" ] && pl=""
    acct_write "$ACCT_DIR/$n.who.json" "$(printf '{"checked_at":%s,"email":%s,"plan":%s,"sign_in":"subscription","signed_in":true,"slot":"%s","v":1}' \
      "$(json_str "$(hpcw_now_iso)")" "$(json_str "$em")" "$(json_str "$pl")" "$n")"
    # the first account signed in is the one in use; another waits for `use` or auto mode
    [ -n "$(acct_current)" ] || acct_link "$n"
    acct_consent_carry "$n"
  fi
  touch "$w/done"
  return "$rc"
}
# The person answered "Enable Remote Control?" in another of their own accounts: that answer is theirs,
# so it is carried to the fallback marker the worker reads, as `claude consent` records it. Nothing is
# written when no account of theirs holds Claude Code's own record, or a marker is there already
acct_consent_carry() { # N
  local f="$HPCW_HOME/consent" m any=""
  [ -e "$f" ] && return 0
  for m in $(acct_slots); do hpcw_consent_seen "$ACCT_DIR/$m" && { any="$m"; break; }; done
  [ -n "$any" ] || return 0
  acct_write "$f" "yes $(hpcw_now_iso) carried-from-account-$any-to-$1" || true
}

acct_usage() {
  local wait_s=0
  while [ $# -gt 0 ]; do case "$1" in
    --wait) [[ "${2:-}" =~ ^[0-9]{1,3}$ ]] || die "accounts: --wait takes seconds"; wait_s="$2"; shift 2;;
    *) die "accounts usage: unknown option $1";; esac; done
  acct_adopt
  [ -n "$(acct_slots)" ] || die "accounts: no account yet"
  local w="$ACCT_WORK/usage"
  acct_mkdir "$ACCT_WORK" && acct_mkdir "$w" || die "accounts: cannot make $w"
  if acct_job_live "$w"; then say "HPCW-ACCOUNTS usage: already being read"
  else
    # three minutes an account at most (a container start for its sign-in, a probe of 150 s), and a few more
    local min; min=$(( 3 + 3 * $(acct_slots | wc -l) )); [ "$min" -gt 59 ] && min=59; [ "$min" -lt "$ACCT_USAGE_MIN" ] && min=$ACCT_USAGE_MIN
    rm -f "$w/done"; local id; id=$(acct_submit "$w" hpcw_acct_usage "$min" _usage-job) || return 1; say "HPCW-ACCOUNTS usage: job $id"
  fi
  local i=0
  while [ $i -lt "$wait_s" ] && acct_job_live "$w"; do sleep 3; i=$((i + 3)); done
  if [ -e "$w/done" ]; then say "HPCW-ACCOUNTS usage: read"; else say "HPCW-ACCOUNTS usage: still reading"; fi
}
acct_usage_job() {
  in_job || die "accounts: _usage-job runs inside its job"
  local w="$ACCT_WORK/usage" n
  # done whatever ends the job (the wall time sends TERM first), so the panel never waits on a job that is gone
  trap 'touch "$w/done"' EXIT
  trap 'exit 143' TERM
  [ -n "$PY" ] || die "accounts: python3 is needed on the compute node"
  for n in $(acct_slots); do
    HPCW_ACCOUNT_SLOT="$n" HPCW_WS=.accounts-probe timeout 120 "${BASH:-/bin/bash}" "$SELF" _exec run auth status > "$w/auth-$n" 2>/dev/null
    "$PY" "$LIB/accounts_read.py" who "$n" "$w/auth-$n" "$ACCT_DIR/$n.who.json"
    : > "$w/auth-$n"
    if [ "$(acct_field "$(acct_one_line "$ACCT_DIR/$n.who.json")" signed_in)" = true ]; then
      HPCW_ACCOUNT_SLOT="$n" HPCW_WS=.accounts-probe timeout 150 "${BASH:-/bin/bash}" "$SELF" _exec run -p "$ACCT_PROBE" --model haiku --max-turns 1 --output-format stream-json --verbose > "$w/probe-$n" 2>&1
      "$PY" "$LIB/accounts_read.py" use "$n" "$w/probe-$n" "$ACCT_DIR/$n.use.json"
    fi
  done
  touch "$w/done"
}
