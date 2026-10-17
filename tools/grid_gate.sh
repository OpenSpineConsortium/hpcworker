#!/bin/bash
# The ssh gate of the grid's GitHub runner: the forced command of one restricted line in the account's
# ~/.ssh/authorized_keys, which `tools/grid_runner.sh --gate-key` writes and `--gate-off` takes out.
# A workflow on GitHub's own machine holds the line's private key in an environment secret and signs
# in with it alone (a key alone signs in to the grid from outside the VPN: the owner's test of
# 2026-10-17), so a run can start the runner chain only when a job needs it, read the chain's state into
# its log, and end it, in place of a chain kept waiting in Slurm's queue. The password is nowhere.
#
#   restrict,command="<clone>/tools/grid_gate.sh --site S --runner-dir D --repo OWNER/NAME [start options]" ssh-ed25519 <key> hpcw-grid-gate:OWNER/NAME
#
# The line fixes the repository, the site, the runner's folder and the chain's size; the client says
# one word and nothing else, read from SSH_ORIGINAL_COMMAND and never handed to a shell:
#   start    grid_runner.sh --start with the line's options (a chain already queued or running is
#            no failure: the gate says "running")
#   status   grid_runner.sh --status for the line's repository
#   stop     grid_runner.sh --stop for it (a GitHub job in flight finishes first; never --now)
# Each makes on the login node the calls it makes when a person types it: file work, one gh api, one
# squeue and one sbatch to start; one squeue to read; one squeue and one scancel to stop. It refuses
# any other word, any argument or any other byte (the word must be exactly one of the three), and a
# second call within 60 seconds of the last for the same repository, whatever the word (the grid's
# etiquette: a client asks the scheduler at most once a minute). It writes one line per call to
# <runner dir>/<OWNER-NAME>/gate.log: the time, the word, the address the call came from and how it
# ended; never the key, which the gate never sees.
#
# A gate never queues a job of the workflow's own: that would run a workflow's code as the account,
# outside the runner's container, beside the account's gh sign-in and Claude login, which the runner
# was built to rule out. It starts, reads and stops a chain; every command of a workflow's still runs
# on the runner. Since whoever can change this clone, or rename a folder above it, could put other code
# where the line points and have the key run it, the gate refuses to run, and --gate-key to write the
# line, while any of the clone's tools/, framework/lib/ or framework/profiles/, or any of their files,
# belongs to someone else or may be written by group or others, or a folder from / down to the clone
# may be changed by others and is not sticky (framework/README.md, "The browser's key", the same rule).
# The runner's folder, its bin/ and image/ and the chain's folder are held to the same rule, since a
# start queues bin/'s scripts and the gate writes its files in the chain's folder. A folder above that
# belongs to another account and only it may write is accepted, as browser-key's check accepts it.
# On a login node whose umask is 002, git writes what a pull changes group-writable: after each pull,
# chmod -R go-w tools framework in the clone, or the gate refuses until it is done.
#
#   tools/grid_gate.sh --check-copy [RUNNER_DIR [OWNER-NAME]]
#                     read only: one line per such finding, then "ok" (0) or "refused" (8)
set -uo pipefail
LC_ALL=C; export LC_ALL
HERE=$(cd "$(dirname "$0")" && pwd -P) || { echo "HPCW-GRID-GATE refused copy"; exit 126; }
CLONE=$(cd "$HERE/.." && pwd -P) || { echo "HPCW-GRID-GATE refused copy"; exit 126; }
FLOOR=60          # seconds between two calls for one repository
ME=$(id -u)

# ---- the copy the line points at -------------------------------------------------------------------
dir_ok() { # DIR -> 0 when only its owner may add, rename or remove entries in it, or it is sticky (a folder above
  # the clone may be the site's or root's: its mode is what decides, as browser-key's check judges it)
  local m; m=$(stat -L -c %a "$1" 2>/dev/null) || return 1   # a link is judged by the folder it names
  [ $(( 8#$m & 8#1000 )) != 0 ] || [ $(( 8#$m & 8#022 )) = 0 ]
}
# A folder above that someone else owns is "beyond": a note, never a refusal, as browser-key's check
# judges it (framework/lib/browser_key.sh, 2026-10-02). At Wayne State the lab's volume sits under CephFS
# scaffold folders, root's or another lab's and writable by everyone, that only the university can change;
# the lab's shared code and this runner's chain run from under them with or without the gate, so refusing
# the gate over them would protect nothing. A folder of this account's own that others may change is refused.
above_one() { # DIR
  local o
  dir_ok "$1" && return 0
  o=$(stat -L -c %u "$1" 2>/dev/null) || o="?"
  if [ "$o" = "$ME" ]; then echo "above $1"; else echo "beyond $1 (owner uid $o)"; fi
}
above_problems() { # PATH: a line for each existing folder from / down to PATH, PATH left out, that others may change
  local p="" c rest="${1#/}"
  above_one /
  while [ -n "$rest" ]; do
    c="${rest%%/*}"; if [ "${rest#*/}" != "$rest" ]; then rest="${rest#*/}"; else rest=""; fi
    p="$p/$c"
    [ "$p" = "$1" ] && break
    [ -e "$p" ] || break
    above_one "$p"
  done
}
refusals() { grep -v '^beyond ' || true; }   # the findings that refuse: all but the notes
own_problems() { # PATH...: "runner <path>" for each that exists and is a link, someone else's, or writable by group or others
  local f
  for f in "$@"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -L "$f" ]; then echo "runner $f (a link)"; continue; fi
    find "$f" -maxdepth 0 \( ! -user "$ME" -o -perm -g+w -o -perm -o+w \) -print 2>/dev/null | sed 's/^/runner /'
  done
}
# The runner's folder is judged as the clone is: its bin/ holds the scripts --start copies there and
# queues, and the chain's folder holds the gate's own files, so whoever could change either could have
# a start queue their code as the account, or have the gate write through a link they planted.
runner_problems() { # RUNNER_DIR [CHAIN_NAME]
  local r="$1" f
  above_problems "$r"
  # the folders a link along the way leads through are judged too, from the physical path
  [ -d "$r" ] && f=$(cd "$r" 2>/dev/null && pwd -P) && [ "$f" != "$r" ] && above_problems "$f"
  own_problems "$r" "$r/bin" "$r/image"
  [ -d "$r/bin" ] && [ ! -L "$r/bin" ] && for f in "$r"/bin/*; do own_problems "$f"; done
  [ -z "${2:-}" ] || own_problems "$r/$2" "$r/$2/gate.log" "$r/$2/gate.log.1" "$r/$2/gate.last" "$r/$2/STOP"
  return 0
}
copy_problems() { # one line per thing others than this account may change; nothing when there is none
  local f
  above_problems "$CLONE"
  # inside the clone nothing is sticky-excused: every folder and file here is this account's own, written by it alone
  local d
  for d in "$CLONE" "$CLONE/tools" "$CLONE/framework" "$CLONE/framework/lib" "$CLONE/framework/profiles"; do
    [ -d "$d" ] && [ ! -L "$d" ] || { echo "copy $d (missing or a link)"; continue; }
  done
  find "$CLONE" -maxdepth 0 \( ! -user "$ME" -o -perm -g+w -o -perm -o+w \) -print 2>/dev/null | sed 's/^/copy /'
  for d in tools framework framework/lib framework/profiles; do
    [ -d "$CLONE/$d" ] || continue
    f=$(find "$CLONE/$d" -maxdepth 1 \( ! -user "$ME" -o \( ! -type l \( -perm -g+w -o -perm -o+w \) \) \) -print 2>/dev/null)
    [ -z "$f" ] || printf '%s\n' "$f" | sed 's/^/copy /'
  done
  find "$CLONE/tools" "$CLONE/framework/lib" "$CLONE/framework/profiles" -mindepth 1 -type l -print 2>/dev/null | sed 's/^/copy (a link) /'
  return 0
}
if [ "${1:-}" = --check-copy ]; then   # --check-copy [RUNNER_DIR [CHAIN_NAME]]
  out=$(copy_problems; [ -z "${2:-}" ] || runner_problems "$2" "${3:-}")
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^beyond \(.*\)$/note for the university: \1 is writable by others and not sticky; it is not yours, so it refuses nothing (ask for chmod +t)/'
  if [ -n "$(printf '%s\n' "$out" | refusals)" ]; then echo "refused: chmod go-w on each, by its owner (a folder above the clone may be sticky instead, chmod +t)"; exit 8; fi
  echo "ok $CLONE"; exit 0
fi

# ---- the line's own options ----------------------------------------------------------------------------
SITE="" RUNNER_DIR="" REPO="" START=()
bad_line() { echo "HPCW-GRID-GATE refused line: the key's line is not one --gate-key writes; write it again with tools/grid_runner.sh --gate-key"; exit 126; }
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || bad_line
  case "$1" in
    --site) [[ "$2" =~ ^[A-Za-z0-9._-]+$ ]] || bad_line; SITE="$2";;
    --runner-dir) [[ "$2" =~ ^/[A-Za-z0-9._/-]+$ ]] || bad_line; RUNNER_DIR="$2";;
    --repo) [[ "$2" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || bad_line; REPO="$2";;
    --labels|--hours|--margin|--cpus|--mem|--gres|--partition|--qos) [[ "$2" =~ ^[A-Za-z0-9._,:-]+$ ]] || bad_line; START+=("$1" "$2");;
    *) bad_line;;
  esac
  shift 2
done
[ -n "$REPO" ] && [ -n "$RUNNER_DIR" ] || bad_line

# ---- the client's word ------------------------------------------------------------------------------
CHAIN="$RUNNER_DIR/${REPO//\//-}"
FROM=${SSH_CONNECTION:-}; FROM=${FROM%% *}; [[ "$FROM" =~ ^[0-9A-Fa-f.:]{1,45}$ ]] || FROM=unknown
LOG_MAX=1048576   # bytes of gate.log before it is turned over to gate.log.1, so a key used in a loop cannot fill the volume
note() { # WORD HOW: the call's one line in gate.log, where the chain's folder is there and the log is no link
  local l="$CHAIN/gate.log" n
  [ -d "$CHAIN" ] && [ ! -L "$CHAIN" ] && [ ! -L "$l" ] || return 0
  n=$(stat -c %s "$l" 2>/dev/null) && [ "$n" -gt $LOG_MAX ] && [ ! -L "$l.1" ] && mv -f "$l" "$l.1" 2>/dev/null
  printf '%s %s from %s: %s\n' "$(date -u +%FT%TZ)" "$1" "$FROM" "$2" >> "$l" 2>/dev/null
  return 0
}
refuse() { # CODE SENTENCE
  note refused "$1"; echo "HPCW-GRID-GATE refused $1: $2"; exit 126
}
if [ -z "${SSH_ORIGINAL_COMMAND+set}" ]; then
  echo "HPCW-GRID-GATE refused word: name one of start, status or stop after the host (ssh ... <user>@<host> status)"; exit 126
fi
WORD=$SSH_ORIGINAL_COMMAND
case "$WORD" in start|status|stop) ;; *) refuse word "one of start, status or stop, and nothing else";; esac
problems=$( { copy_problems; runner_problems "$RUNNER_DIR" "${REPO//\//-}"; } | refusals)
[ -z "$problems" ] || refuse copy "others may change the clone or the runner's folder the key runs from ($(printf '%s' "$problems" | head -1)); tools/grid_gate.sh --check-copy $RUNNER_DIR ${REPO//\//-} lists all"
( umask 077; mkdir -p "$CHAIN" ) 2>/dev/null && [ -d "$CHAIN" ] && [ ! -L "$CHAIN" ] || refuse folder "the chain's folder $CHAIN cannot be made"

# ---- one call a minute ------------------------------------------------------------------------------
LOCK="$CHAIN/gate.lock"
take_lock() { # a lock older than two minutes is a leftover
  local t
  mkdir "$LOCK" 2>/dev/null && return 0
  t=$(stat -c %Y "$LOCK" 2>/dev/null) && [ $(( $(date +%s) - t )) -gt 120 ] && rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null
}
take_lock || { note "$WORD" "limit (another call holds the gate)"; echo "HPCW-GRID-GATE limit: another call is being taken; try again in a minute"; exit 123; }
now=$(date +%s); last=$(cat "$CHAIN/gate.last" 2>/dev/null); [[ "$last" =~ ^[0-9]{1,12}$ ]] || last=0
if [ $(( now - last )) -lt $FLOOR ] && [ $(( now - last )) -ge 0 ]; then
  rmdir "$LOCK" 2>/dev/null
  note "$WORD" "limit"; echo "HPCW-GRID-GATE limit: one call a minute; try again in $(( FLOOR - (now - last) )) seconds"; exit 123
fi
tmp=$(mktemp "$CHAIN/.gate.last.XXXXXX" 2>/dev/null) && printf '%s\n' "$now" > "$tmp" && mv -f "$tmp" "$CHAIN/gate.last" \
  || { rm -f "${tmp:-}"; rmdir "$LOCK" 2>/dev/null; refuse folder "cannot write $CHAIN/gate.last"; }
rmdir "$LOCK" 2>/dev/null

# ---- the one command ----------------------------------------------------------------------------------
# a forced command's shell is not a login shell, so the scheduler's commands may not be on its PATH
# yet; the PATH a login shell gets is taken from a subshell that reads /etc/profile, and nothing else of it
if ! command -v sbatch >/dev/null 2>&1 && [ -r /etc/profile ]; then
  p=$(set +u; . /etc/profile >/dev/null 2>&1 < /dev/null; printf '%s' "$PATH")
  [ -n "$p" ] && PATH="$p"
fi
ARGS=(--repo "$REPO" --runner-dir "$RUNNER_DIR"); [ -n "$SITE" ] && ARGS+=(--site "$SITE")
case "$WORD" in
  start) ARGS=(--start "${ARGS[@]}" ${START[@]+"${START[@]}"});;
  status) ARGS=(--status "${ARGS[@]}");;
  stop) ARGS=(--stop "${ARGS[@]}");;
esac
# grid_runner.sh starts with an environment of the gate's choosing: none of the client's (LANG and LC_*
# that sshd accepts, SSH_*), nothing a token or a shell start-up file could ride in on, and nothing that
# sbatch --export=ALL would carry into the chain's jobs beside what a person's command has
KEEP=(HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" PATH="$PATH" LC_ALL=C HPCW_GATE=1)
for v in SLURM_CONF GH_CONFIG_DIR XDG_CONFIG_HOME; do [ -n "${!v:-}" ] && KEEP+=("$v=${!v}"); done
out=$(env -i "${KEEP[@]}" /bin/bash "$HERE/grid_runner.sh" "${ARGS[@]}" < /dev/null 2>&1); rc=$?
printf '%s\n' "$out"
if [ "$WORD" = start ] && [ $rc != 0 ] && printf '%s\n' "$out" | grep -q 'is already queued or running (job'; then
  # a chain told to stop keeps its running job until the GitHub job on it ends, and registers nothing
  # more: that is no started chain, and a workflow waiting on it would wait a day
  if [ -e "$CHAIN/STOP" ]; then
    note start "stopping"; echo "HPCW-GRID-GATE start failed: the chain is stopping (STOP is set) and its last job still runs; start it again once that job has ended"; exit 75
  fi
  note start "running already"; echo "HPCW-GRID-GATE running"; exit 0
fi
if [ $rc = 0 ]; then note "$WORD" "ok"; echo "HPCW-GRID-GATE $WORD ok"
else note "$WORD" "failed $rc"; echo "HPCW-GRID-GATE $WORD failed $rc"; fi
exit $rc
