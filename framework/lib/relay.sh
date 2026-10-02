#!/bin/bash
# hpcworker connect's relay: the one writer to the terminal while the Claude sign-in sitting runs.
#
#   bash relay.sh KEEPALIVE_S SUMMARY_FILE     the relay
#   bash relay.sh --ticks                      its clock: a tick line a second, into the relay's pipe
#
# `hpcworker connect` sends the sitting's allocation (srun, its own messages included) into a pipe, and
# the relay copies it to the terminal one whole line at a time, so every line the extension parses
# arrives whole and at the start of a line (docs/V11_CONTRACT.md, "The keepalive and the one-writer
# rule"). When KEEPALIVE_S seconds pass with nothing written and no part of a line waiting, it writes
# the keepalive line, "HPCW-LOGIN: still waiting": the portal's shell closes a connection that shows no
# activity (Open OnDemand's default is 300 s), and the wait for the sign-in computer alone can be ten
# minutes. A part of a line that waits five seconds with nothing after it is written as a line of its
# own, at the fifth tick after the one that brought its last byte (5 to 6 s after that byte; the
# sitting prints whole lines, and srun may split one only for a moment). Carriage returns go.
#
# At the end SUMMARY_FILE (mode 0600) gets two lines: the last "SIGNED-IN ..." line seen (or an empty
# line) and the last "HPCW-LOGIN-FAILED: ..." line seen (or an empty line), the outcome connect turns
# into its HPCW-STEP line. Nothing else is kept. The relay's exit status is 0; connect takes srun's own
# from PIPESTATUS. The code the student pastes never passes through here: it goes from the terminal to
# srun's standard input, and the sitting never echoes it.
#
# The login node's rules: warrior's banner bans python3 (which relayed the sitting in the first
# framework 10 build), node, make, rsync and others, and heavy work there is not allowed. The relay runs
# for the whole sitting, up to fourteen minutes, so it is bash and nothing else: bash 4.2 builtins
# (EL7), the clock read from /proc/uptime by a redirection. It starts no program, ever (the tests run it
# with an empty PATH), and writes no file but SUMMARY_FILE, once, at the end.
#
# Why a tick and not `read -t`: the relay never reads with a timer, because bash 4.2's `read -t` can
# lose what it had read of a line when the timer fires (a SIGALRM and a longjmp past a local that is
# not volatile: bash 4.2.46 built from source dropped the "SIGNED" of a split "SIGNED-IN" line). It
# blocks in a plain `read` instead, and connect starts `relay.sh --ticks` beside srun, writing into the
# same pipe: once a second the line "<0x01>tick", one 6-byte write, which a pipe never splits or mixes
# into another write. A line that ends in it is a tick, and what came before it is a part of a line
# still waiting. The ticker is the only one that starts a program: coreutils `sleep 1`, once a second.
#
# CPU while it waits: the relay sleeps in the kernel's read until a byte or a tick arrives; the ticker
# waits for one `sleep 1` a second. Nothing spins.
#
# How it ends when the portal's shell is cut: connect is typed with `exec`, so the hpcworker process is
# the terminal's session leader, and without job control srun, the ticker (and its sleep) and the relay
# all run in its process group, the terminal's foreground group. A hang-up sends SIGHUP to the session
# leader; as it exits the kernel sends SIGHUP to that group, every one of them included. Neither half
# traps SIGHUP, so each ends. The relay ignores SIGPIPE alone, so a terminal that went away makes its
# writes fail rather than end it while srun may still write: it then reads on, writing nothing, until
# the pipe closes, so srun never blocks on a full pipe. The ticker ends when connect stops it after srun
# (TERM, its sleep stopped with it), within a second of connect's side of the pipe ending any other way
# (it looks at that pid each tick: bash 4.2.46 runs no EXIT trap in a pipeline's subshell), when the
# relay is gone (its next tick finds no reader), or with the group. Nothing is left behind, and srun's
# allocation ends with srun (and with its 20-minute limit).
LC_ALL=C          # bytes, not characters: a line is whatever ends in a newline byte
TICK=$'\001tick'

if [ "${1:-}" = --ticks ]; then
  # the ticker: until it is stopped (TERM), the relay is gone (a tick finds no reader), or the process
  # it ticks for (PID, else its parent: connect's side of the pipe, which runs srun) has ended
  watch="${2:-$PPID}"
  case "$watch" in ""|*[!0-9]*) watch=$PPID;; esac
  sp=""
  trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM INT
  while :; do
    sleep 1 < /dev/null > /dev/null 2>&1 &
    sp=$!
    wait "$sp" || exit 0          # no sleep here, or it was stopped: no ticks, rather than a spin
    sp=""
    kill -0 "$watch" 2>/dev/null || exit 0
    printf '%s\n' "$TICK" || exit 0
  done
fi

umask 077         # SUMMARY_FILE is this account's alone
trap '' PIPE

KEEPALIVE="HPCW-LOGIN: still waiting"
PARTIAL_TICKS=5   # a part of a line waits five ticks (seconds) after the one that brought its last byte
LATE_CS=50        # ticks come a second apart: a keepalive due within half a second of a tick is written at it

# KEEPALIVE_S as centiseconds (whole seconds or a decimal; 0 = no keepalive; anything else = 20 s)
KA=2000
case "${1:-}" in
  "") ;;
  *[!0-9.]*|*.*.*|.) ;;
  *.*) _i=${1%%.*}; _f="${1#*.}00"; KA=$(( 10#${_i:-0} * 100 + 10#${_f:0:2} ));;
  *) KA=$(( 10#$1 * 100 ));;
esac
SUM="${2:-}"

# the clock, in centiseconds: /proc/uptime (monotonic, read by a redirection, no program started); the
# shell's own SECONDS where that file cannot be read, continued from the last reading
NOW=0
CLOCK_OFF=0
USE_UPTIME=0
[ -r /proc/uptime ] && USE_UPTIME=1
tick() {
  local u f
  if [ $USE_UPTIME = 1 ] && { read -r u f < /proc/uptime; } 2>/dev/null; then
    case "$u" in
      *.*) f="${u#*.}00"; f=${f:0:2}; u=${u%%.*};;
      *) f=00;;
    esac
    case "$u$f" in
      ""|*[!0-9]*) ;;
      *) NOW=$(( 10#$u * 100 + 10#$f )); return 0;;
    esac
  fi
  if [ $USE_UPTIME = 1 ]; then USE_UPTIME=0; CLOCK_OFF=$(( NOW - SECONDS * 100 )); fi
  NOW=$(( SECONDS * 100 + CLOCK_OFF ))
}

SIGNED=""
FAILED=""
BROKEN=0
tick
LAST_OUT=$NOW
WAITED=0

emit() { # LINE: written as one line (one write), carriage returns removed; the outcome lines remembered
  local text="${1//$'\r'/}" bare
  bare="${text#"${text%%[![:space:]]*}"}"
  bare="${bare%"${bare##*[![:space:]]}"}"
  case "$bare" in
    SIGNED-IN*) SIGNED="$bare";;
    HPCW-LOGIN-FAILED*) FAILED="$bare";;
  esac
  if [ $BROKEN = 0 ]; then
    # the terminal went away: keep reading (srun must never block on a full pipe), stop writing
    { printf '%s\n' "$text"; } 2>/dev/null || BROKEN=1
  fi
  tick
  LAST_OUT=$NOW
}

BUF=""
line=""
# a plain read, no timer: whatever it has read of a line stays read (see "Why a tick")
while IFS= read -r line; do
  tick
  case "$line" in
    *"$TICK")
      # a tick: a part of a line that came before it waits in BUF. Its wait is counted in ticks, not
      # read from the clock: the ticker wrote them a second apart, so five ticks after the one that
      # brought the last byte are five seconds of the sitting's own time, even if this script itself
      # was kept waiting by a busy node and reads them all at once
      line="${line%"$TICK"}"
      if [ -n "$line" ]; then BUF="$BUF$line"; WAITED=0
      elif [ -n "$BUF" ]; then WAITED=$(( WAITED + 1 )); fi
      if [ -n "$BUF" ] && [ $WAITED -ge $PARTIAL_TICKS ]; then emit "$BUF"; BUF=""; fi
      if [ -z "$BUF" ] && [ $KA -gt 0 ] && [ $(( NOW - LAST_OUT + LATE_CS )) -ge $KA ]; then emit "$KEEPALIVE"; fi
      ;;
    *)
      # a whole line (a part of it read before a tick, if any, is its start)
      BUF="$BUF$line"
      emit "$BUF"
      BUF=""
      ;;
  esac
  line=""
done
# the end of the input (srun and the ticker are gone): a last part of a line, if any, is the last line
BUF="$BUF${line%"$TICK"}"
[ -n "$BUF" ] && emit "$BUF"

if [ -n "$SUM" ]; then
  { printf '%s\n%s\n' "$SIGNED" "$FAILED" > "$SUM"; } 2>/dev/null
fi
exit 0
