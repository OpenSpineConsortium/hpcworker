#!/bin/bash
# hpcworker plain sign-in sitting: Claude Code's own `claude auth login`, run under a pseudo-terminal
# (`script`, the helper the worker job uses) so that a panel driving the portal's shell over a
# WebSocket gets a line contract instead of a full-screen terminal. It runs inside the allocation
# and inside the worker image, started by `hpcworker _exec login --plain`, which passes this file's
# text to bash -c (no bind mount is assumed for it):
#
#   bash -c "$(cat login_plain.sh)" _ WORKSPACE CLAUDE_BIN SITTING_DIR SEED_JS BUDGET_S [live|dry] [KEEPALIVE_S] [fresh] [DEADLINE]
#
# The last three are framework 10's, given only by `hpcworker connect` (`claude login --plain`, which
# the 10.0.0 extension types, gives none of them and behaves exactly as in framework 9):
#   KEEPALIVE_S  when > 0, "HPCW-LOGIN: still waiting" once that many seconds pass with nothing
#                printed while the sitting waits for the link and for the code (connect's relay
#                covers the wait for the computer, before this script runs)
#   fresh        `claude auth logout` first, so the sign-in is a new one ("Use another account")
#   DEADLINE     seconds since the epoch by which connect must have ended: the code budget becomes
#                min(BUDGET_S, DEADLINE - now), never under 120 s
#
# What it prints on stdout, one line each, and nothing else from Claude Code's screen:
#   HPCW-LOGIN: <progress, in plain words>
#   HPCW-LOGIN: a menu appeared; chose the first entry   when a screen before the link asked for
#                                                Enter (an assumption: see the README)
#   AUTH-URL: <Anthropic's authorize link>       the public page the student signs in on
#   HPCW-LOGIN: paste the code from that page
#   HPCW-LOGIN: code received, checking          a fixed line; never the code itself
#   HPCW-LOGIN: that code was not accepted; paste it again   once per code Claude Code rejected
#   SIGNED-IN <email> <subscriptionType>         and exit 0
#   HPCW-LOGIN-FAILED: <one plain sentence>      and exit 3 (the caller adds nothing)
#   HPCW-LOGIN: still waiting                    framework 10, under connect only (KEEPALIVE_S)
#   HPCW-LOGIN-DRY: url_seen=.. prompt_seen=..   dry mode only (the unit tests; the probe job no
#                                                longer runs it): what the flow looks like, never the link
#
# The credential boundary. The code the student pastes travels stdin -> this shell -> the pty and
# is never echoed: the terminal's echo is off for the whole sitting and Claude Code's screen is
# never copied to stdout (only the patterns below are matched against it). The pseudo-terminal
# transcript lives under SITTING_DIR (/dev/shm, mode 0600), is removed when the sitting ends, and
# is never written to shared storage. Nothing here reads a credential file, and the sitting never
# runs `claude remote-control`: the worker job answers that question from the consent marker the
# panel wrote, or from Claude Code's own record.
#
# Sourced by the tests for its functions; bash 4.2 and coreutils, plus `script` and `setsid`.

hpcw_login_strip() { # stdin -> stdout: the transcript without escape sequences, NULs, carriage returns or any non-ASCII byte
  # LC_ALL=C: under a UTF-8 locale sed 4.2.2 matches none of the byte ranges; the tr drops the box
  # drawing and tick marks the screen uses, so a link inside a box is a bare token afterwards. The CSI
  # expression's intermediate bytes are [ -/] under a | delimiter: the [ -\/] of framework 13 and older was
  # space to backslash in GNU sed, and ESC[K before a link took the link's h (hpcw_strip_codes, common.sh)
  tr -d '\000' | LC_ALL=C sed -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' -e 's|\x1b\[[0-9;?]*[ -/]*[@-~]||g' -e 's/\x1b[()][A-Za-z0-9]//g' -e 's/\r//g' | LC_ALL=C tr -d '\200-\377'
}

hpcw_login_url() { # stdin: stripped text -> the first authorize link (an Anthropic domain, "oauth" and "authorize" in it), wrapped lines joined; nothing when absent
  LC_ALL=C awk '
    { l = $0; gsub(/^[ \t|]+|[ \t|]+$/, "", l) }
    have == 1 {
      # a link that ran to the end of its line may continue on the next: the terminal wrapped it
      if (l != "" && l !~ /^https?:/ && l ~ /^[A-Za-z0-9%&=?._~:\/+#-]+$/) { url = url l; next }
      have = 2
    }
    have == 0 && match(l, /https:\/\/[A-Za-z0-9.-]*(claude\.(ai|com)|anthropic\.com)\/[^ \t]*/) {
      url = substr(l, RSTART, RLENGTH); sub(/[|).,"]+$/, "", url)
      if (RSTART + RLENGTH - 1 >= length(l)) have = 1; else have = 2
    }
    have == 2 { if (url ~ /oauth/ && url ~ /authorize/) { print url; exit } have = 0; url = "" }
    END { if (have == 1 && url ~ /oauth/ && url ~ /authorize/) print url }'
}

hpcw_login_flags() { # stdin: stripped text (the recent tail) -> words: select prompt invalid success
  local t f=""; t=$(cat)
  printf '%s' "$t" | grep -q -i -E 'Select login method|Enter to (confirm|select|continue)|Press Enter' && f="$f select"
  printf '%s' "$t" | grep -q -i 'Paste code here' && f="$f prompt"
  printf '%s' "$t" | grep -q -i -E 'Invalid code|code (is |was )?(invalid|not valid)|OAuth error|Failed to (log ?in|authenticate|exchange)|authorization (code )?expired' && f="$f invalid"
  printf '%s' "$t" | grep -q -i -E 'Login successful|Logged in as|Successfully logged in|logged in successfully|Sign-?in successful' && f="$f success"
  printf '%s' "${f# }"
}

hpcw_login_rejected() { # stdin: stripped text -> 0 when it shows a rejected code (however many frames repeat it)
  grep -q -i -E 'Invalid code|code (is |was )?(invalid|not valid)'
}

hpcw_login_main() {
  local ws="$1" claude="$2" dir="$3" seed="${4:-}" budget="${5:-600}" mode="${6:-live}" keepalive="${7:-0}" fresh="${8:-}" deadline="${9:-0}"
  local fifo="$dir/stdin" log="$dir/login.log" launch="$dir/launch.sh"
  local spid=0 tty_saved="" url="" url_seen=0 url_at=0 prompt_seen=0 prompt_at=0 sent=0 sent_at=0 judged=0 invalid_n=0 enters=0 last_enter=0 stdin_eof=0 saw_select=0 tail_txt flags line out_json li em st i
  local last_out=0 now_s left
  local -a sent_off=()   # per code sent: the transcript's size just before its Enter; the verdict on it is drawn after that point
  [[ "$keepalive" =~ ^[0-9]+$ ]] || keepalive=0
  [[ "$deadline" =~ ^[0-9]+$ ]] || deadline=0
  out() { printf '%s\n' "$*"; last_out=$SECONDS; }
  # framework 10 (connect only): a line at least every KEEPALIVE_S seconds while the sitting waits
  still_waiting() { [ "$keepalive" -gt 0 ] && [ $(( SECONDS - last_out )) -ge "$keepalive" ] && out "HPCW-LOGIN: still waiting"; return 0; }
  cleanup() {
    # the sitting's own process group (script and Claude Code under it), then its own three files;
    # the directory itself goes with the allocation's guarded cleanup on the host side
    if [ "$spid" -gt 0 ] && kill -0 "$spid" 2>/dev/null; then kill -TERM -- "-$spid" 2>/dev/null; sleep 1; kill -KILL -- "-$spid" 2>/dev/null; fi
    exec 7>&- 2>/dev/null
    rm -f "$fifo" "$log" "$launch" "$dir/pid"
    [ -n "$tty_saved" ] && stty "$tty_saved" 2>/dev/null
    return 0
  }
  fail() { out "HPCW-LOGIN-FAILED: $1"; cleanup; exit 3; }
  auth_status() { # loggedIn|email|subscriptionType, from Claude Code's own answer; nothing else is read
    local o; o=$(timeout 60 "$claude" auth status 2>/dev/null) || o=""
    li=$(printf '%s' "$o" | grep -o '"loggedIn": *\(true\|false\)' | head -1 | grep -o 'true\|false'); li=${li:-false}
    em=$(printf '%s' "$o" | grep -o '"email": *"[^"]*"' | head -1 | cut -d'"' -f4)
    st=$(printf '%s' "$o" | grep -o '"subscriptionType": *"[^"]*"' | head -1 | cut -d'"' -f4)
  }
  send() { printf '%s' "$1" >&7; }
  has() { case " $flags " in *" $1 "*) return 0;; esac; return 1; }
  dur() { if [ "$1" -ge 120 ]; then echo "$(( $1 / 60 )) minutes"; else echo "$1 seconds"; fi; }
  trap 'fail "the sign-in was interrupted; start it again"' INT TERM HUP

  cd "$ws" 2>/dev/null || fail "the worker folder $ws is not reachable from the compute node"
  command -v script >/dev/null 2>&1 || fail "this image has no terminal helper (script); ask your lead to rebuild it"
  command -v setsid >/dev/null 2>&1 || fail "this image has no setsid; ask your lead to rebuild it"
  [ -x "$claude" ] || command -v "$claude" >/dev/null 2>&1 || fail "Claude Code is not at $claude in this image"
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || fail "cannot create the sitting's directory under $dir"

  if [ "$mode" != dry ]; then
    out "HPCW-LOGIN: on $(hostname -s 2>/dev/null || echo the compute node); checking whether you are signed in already"
    # framework 10, "Use another account": Claude Code's own sign-out first; nothing of it is read
    [ "$fresh" = fresh ] && timeout 60 "$claude" auth logout >/dev/null 2>&1
    auth_status
    if [ "$li" = true ]; then out "SIGNED-IN ${em:--} ${st:--}"; cleanup; return 0; fi
    # the three settings Claude Code's screens ask about (onboarding done, a theme, trust for this
    # folder), added before the sign-in so no other screen sits in front of the link; never a credential
    [ -n "$seed" ] && node -e "$seed" >/dev/null 2>&1
    if [ -t 0 ]; then tty_saved=$(stty -g 2>/dev/null); stty -echo 2>/dev/null; fi
  fi

  rm -f "$fifo"; mkfifo -m 600 "$fifo" 2>/dev/null || fail "cannot create the sitting's pipe under $dir"
  exec 7<>"$fifo"
  : > "$log" && chmod 600 "$log" || fail "cannot write the sitting's transcript under $dir"
  # `stty sane` first: an older script (util-linux 2.23, CentOS 7) given a pipe on stdin hands the
  # child a zeroed terminal (speed 0, no control characters, no canonical mode, VMIN 0), on which
  # every plain read returns nothing at once; measured on warrior 2026-09-29. Then a wide terminal
  # so the link is one line, then Claude Code, which sets raw mode itself when it reads.
  { echo '#!/bin/bash'; echo '# written by the hpcworker sign-in sitting: a sane, wide terminal, then Claude Code'
    printf 'stty sane cols 400 rows 50 2>/dev/null; exec %q auth login\n' "$claude"; } > "$launch" && chmod 700 "$launch"
  # script gives Claude Code a real terminal whose input is our pipe (held open on fd 7 so it never
  # sees end-of-file) and whose screen goes to the transcript only; setsid makes the pair one process
  # group. The leader writes its own pid: util-linux 2.23's setsid (CentOS 7) forks when its caller
  # leads a group, so $! would name a parent that has already left
  rm -f "$dir/pid"
  setsid bash -c 'echo "$$" > "$1"; exec script -qfc "$2" "$3"' _ "$dir/pid" "$launch" "$log" <&7 >/dev/null 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$dir/pid" ] && break; sleep 0.25; done
  spid=$(cat "$dir/pid" 2>/dev/null); spid=${spid:-0}
  [ "$spid" -gt 0 ] 2>/dev/null || fail "the terminal helper (script) did not start on this node"
  out "HPCW-LOGIN: starting Claude Code's sign-in; waiting for the sign-in link"
  # framework 10: connect ends within its own budget (14 minutes); the code budget is what is left, at least two minutes
  if [ "$deadline" -gt 0 ]; then
    now_s=$(date +%s); left=$(( deadline - now_s )); [ "$left" -lt 120 ] && left=120
    [ "$left" -lt "$budget" ] && budget=$left
  fi
  SECONDS=0; last_out=0
  while :; do
    still_waiting
    tail_txt=$(tail -c 12000 "$log" 2>/dev/null | hpcw_login_strip)
    if [ $url_seen = 0 ]; then
      url=$(printf '%s\n' "$tail_txt" | hpcw_login_url)
      if [ -n "$url" ]; then
        url_seen=1; url_at=$SECONDS
        if [ "$mode" != dry ]; then out "AUTH-URL: $url"; out "HPCW-LOGIN: paste the code from that page"; fi
      fi
    fi
    flags=$(printf '%s' "$tail_txt" | tail -c 3000 | hpcw_login_flags)
    if has prompt && [ $prompt_seen = 0 ]; then prompt_seen=1; prompt_at=$SECONDS; fi
    has select && saw_select=1
    # a menu before the link (a login method, a first-run screen), or a "press Enter" after the
    # sign-in: Enter takes the first, highlighted entry, at most once every 3 s and six times in
    # all; never while the link is up and the code is what Claude Code waits for. That the first
    # entry is the right one is an assumption (the README says so); the line below shows the panel
    # that it happened, so a wrong guess is visible rather than silent
    if has select && { [ $url_seen = 0 ] || has success; } && [ $enters -lt 6 ] && [ $(( SECONDS - last_enter )) -ge 3 ]; then
      send $'\r'; enters=$((enters + 1)); last_enter=$SECONDS
      if [ "$mode" != dry ] && [ $url_seen = 0 ]; then
        if [ $enters = 1 ]; then out "HPCW-LOGIN: a menu appeared; chose the first entry"; else out "HPCW-LOGIN: the menu is still up; pressed Enter again"; fi
      fi
    fi
    # a rejection counts once per code sent, codes in order, each judged from what Claude Code drew
    # after that code went in: the screen is redrawn whole on every change, so counting the words
    # on screen would count frames, not rejections. Whether Claude Code keeps the previous
    # rejection on screen while the next code is typed is not measured; if it does, that stale
    # line can count for the new code once, early, and never more than once per code
    while [ "$judged" -lt "$sent" ] && tail -c +"$((${sent_off[$judged]} + 1))" "$log" 2>/dev/null | hpcw_login_strip | hpcw_login_rejected; do
      judged=$((judged + 1)); invalid_n=$((invalid_n + 1)); [ "$mode" = dry ] || out "HPCW-LOGIN: that code was not accepted; paste it again"
    done
    if [ "$mode" = dry ]; then
      if { [ $url_seen = 1 ] && [ $prompt_seen = 1 ]; } || [ $SECONDS -ge "$budget" ] || ! kill -0 "$spid" 2>/dev/null; then
        out "HPCW-LOGIN-DRY: url_seen=$url_seen prompt_seen=$prompt_seen select_seen=$saw_select enters=$enters seconds=$SECONDS script=1"
        cleanup; return 0
      fi
      sleep 1; continue
    fi
    has success && break
    kill -0 "$spid" 2>/dev/null || break
    if [ $SECONDS -ge "$budget" ]; then
      [ $sent = 0 ] && fail "no code arrived within $(dur "$budget"); start the sign-in again"
      fail "the sign-in did not finish within $(dur "$budget"); start it again"
    fi
    [ $url_seen = 0 ] && [ $SECONDS -ge 120 ] && fail "Claude Code did not show a sign-in link within two minutes; try again, and if it repeats ask your lead"
    # the code: one line from the student (through the shell), taken once the paste prompt is up,
    # or five seconds after the link when this Claude Code words its prompt differently
    if [ $stdin_eof = 0 ] && { [ $prompt_seen = 1 ] || { [ $url_seen = 1 ] && [ $(( SECONDS - url_at )) -ge 5 ]; }; }; then
      if IFS= read -r -t 1 line; then
        line=$(printf '%s' "$line" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -n "$line" ]; then
          send "$line"; sleep 1
          # the transcript's size once the code is typed (its typing redraws landed during that
          # second) and before Enter: what is drawn after this point is the verdict on this code
          sent_off[$sent]=$(stat -c %s "$log" 2>/dev/null || echo 0); sent=$((sent + 1)); sent_at=$SECONDS
          send $'\r'; line=""
          out "HPCW-LOGIN: code received, checking"
        fi
      else
        case $? in 1) stdin_eof=1; [ $sent = 0 ] && fail "the shell closed before a code arrived; start the sign-in again";; esac
      fi
    else
      sleep 1
    fi
  done
  # Claude Code saves its credential and leaves; give it a moment, then ask it (never the file)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do kill -0 "$spid" 2>/dev/null || break; still_waiting; sleep 1; done
  for i in 1 2 3; do auth_status; [ "$li" = true ] && break; still_waiting; sleep 3; done
  if [ "$li" = true ]; then
    out "SIGNED-IN ${em:--} ${st:--}"; cleanup; return 0
  fi
  if [ "$invalid_n" -gt 0 ]; then fail "Claude Code did not accept the code; start the sign-in again and paste the whole code"; fi
  [ $sent = 0 ] && fail "Claude Code's sign-in ended before a code was pasted; start it again"
  fail "the sign-in did not complete; start it again"
}

# run when executed or handed to bash -c; only define the functions when sourced (the tests)
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then hpcw_login_main "$@"; fi
