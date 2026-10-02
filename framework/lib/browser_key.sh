# shellcheck shell=bash
# ---- framework 11: the browser's key and its gate (Beethoven 12.0.0) ---------------------------------
# Sourced by bin/hpcworker after lib/adapters/common.sh. Bash 4.2 (EL7), coreutils (base64, sha256sum,
# stat, date, mktemp, mv, cat, tail, wc, tr, cut, id, env, sleep), grep, sed, awk; ssh-keygen and
# restorecon where present. Nothing on warrior's banned list, and nothing here runs python3.
#
#   hpcworker browser-key add TYPE BASE64 [COMMENT | SHA256:CHECK]
#                     one restricted authorized_keys line for the browser's key, run by Beethoven over
#                     the student's first ssh sign-in (password and code), or typed by a person. TYPE is
#                     ssh-ed25519 or ecdsa-sha2-nistp256 (read from BASE64 when left out). A CHECK is the
#                     start of the key's SHA256 fingerprint: a key that does not match it is refused.
#                     -> "HPCW-KEY added SHA256:<fingerprint>" or "HPCW-KEY refused <code> <sentence>"
#   hpcworker browser-key remove     that line out (HPCW-KEY removed | none | refused ...)
#   hpcworker browser-key check      read only: may a key's forced command run from this copy? One line
#                                    per finding, then "HPCW-KEY check ok|refused ..." (the lab lead's
#                                    check before any student enrols: every folder from / to the copy)
#   hpcworker gate    the line's forced command: SSH_ORIGINAL_COMMAND, eight fixed verbs, never a shell,
#                     never a file outside four run files, NEVER a Claude sign-in
#
# The one line it writes, exactly (one per account; a newer one replaces an older one):
#   restrict,command="<copy>/bin/hpcworker gate" <ssh-ed25519|ecdsa-sha2-nistp256> <base64> beethoven-browser <YYYY-MM-DD UTC>
# <copy> is the shared copy the site profile names (shared_install, the lab's `current` link, never the
# numbered directory behind it, so the key follows the lab's updates), and the command must run from
# that copy; at a site with no shared copy, the copy that ran (an account's own ~/.hpcworker).

BK_TAG=beethoven-browser
BK_ED_PREFIX=AAAAC3NzaC1lZDI1NTE5AAAAI                              # string "ssh-ed25519", then the length of a 32-byte key
BK_EC_PREFIX=AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBB  # "ecdsa-sha2-nistp256", "nistp256", 65 bytes, 0x04
# our line, exactly; a line of the student's own that merely mentions the tag is never taken for ours
BK_LINE_RE='^restrict,command="/[A-Za-z0-9._/-]+/bin/hpcworker gate" (ssh-ed25519|ecdsa-sha2-nistp256) [A-Za-z0-9+/]+={0,2} beethoven-browser [0-9]{4}-[0-9]{2}-[0-9]{2}$'
BK_MAX_READ=262144
# a valid key ssh-keygen must read before it is asked about the student's (see bk_keygen_ok)
BK_KNOWN_GOOD="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCj/iayuSj3Fidk+gybZFVkRGUgZuPSuVKeM+iqcGM2"   # a throwaway public key; its private half was never kept
BK_LOCK=""
GATE_MAX_NAMES=3       # worker names a key may use (a name counts for GATE_NAME_DAYS after its last use)
GATE_NAME_DAYS=7       # days a worker name keeps its place among GATE_MAX_NAMES; the student's own sign-in clears them
GATE_MAX_CONNECTS=12   # connects through the gate per rolling hour (and restricts of a name that has no run)
GATE_MAX_WATCHES=2     # watches at once
GATE_WATCH_MIN=30      # a watch through the gate ends after this many minutes
GATE_POLL_FLOOR=60     # the scheduler is asked about a queued worker at most once a minute, whoever asks

bk_stop() { bk_unlock; echo "$2"; exit "$1"; }   # EXIT LINE
bk_refuse() { bk_stop "$1" "HPCW-KEY refused $2 $3"; }   # EXIT CODE SENTENCE
bk_root_run() { abs_dir "$(dirname "$SELF")/.."; }  # the copy that runs, as it was named: a shared copy's `current`, not the directory it names
bk_uid() { id -u 2>/dev/null; }
bk_msys() { case "${OSTYPE:-}" in msys*|cygwin*) return 0;; esac; return 1; }   # a Windows checkout's Git Bash (the tests): no POSIX modes
bk_abs() { case "$1" in /*) return 0;; [A-Za-z]:/*) bk_msys;; *) return 1;; esac; }
bk_mode_ok() { # PATH -> 0 when it belongs to this account (or root) and neither group nor others may write to it
  local m o u; m=$(stat -c %a "$1" 2>/dev/null) && o=$(stat -c %u "$1" 2>/dev/null) || return 1
  u=$(bk_uid); { [ "$o" = "$u" ] || [ "$o" = 0 ]; } && [ $(( 8#$m & 8#022 )) = 0 ]
}
bk_prof_str() { # FILE KEY -> a plain top-level string of a profile, $HOME/$USER expanded; awk only, never python
  local out; [ -s "$1" ] || return 1
  out=$(HPCW_J_MODE=get HPCW_J_FILE="$1" HPCW_J_KEY="$2" LC_ALL=C awk "$HPCW_JSON_AWK" < /dev/null 2>/dev/null) || return 1
  case "$out" in S?*) hpcw_expand_login "${out#S}";; *) return 1;; esac
}
# a person at a terminal, or Beethoven's own ssh session (no terminal, but an ssh connection: the
# student's first sign-in, with the password and the code); never Claude Code or another agent, never a
# batch job, never through the gate (the gate hands every verb on with HPCW_GATE set, and browser-key is
# not one of its verbs; a site's own ForceCommand, which also sets SSH_ORIGINAL_COMMAND, is not the gate)
bk_person_or_session() {
  hpcw_agent_env && return 1
  [ -n "${SLURM_JOB_ID:-${PBS_JOBID:-${LSB_JOBID:-}}}" ] && return 1
  hpcw_under_gate && return 1
  hpcw_have_terminal && return 0
  [ -n "${SSH_CONNECTION:-}" ]
}

# ---- the key as Beethoven sent it -----------------------------------------------------------------
bk_fp() { # BASE64 -> SHA256:<43>, as ssh-keygen -l prints it (coreutils only: sha256sum is not on the banned list; md5sum is)
  local hex esc
  hex=$(printf '%s' "$1" | base64 -d 2>/dev/null | sha256sum 2>/dev/null) || return 1
  hex=${hex%% *}
  [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || return 1
  esc=$(printf '%s' "$hex" | sed 's/../\\x&/g')
  # shellcheck disable=SC2059
  printf 'SHA256:%s\n' "$(printf "$esc" | base64 | tr -d '\n=')"
}
bk_parse_key() { # ARGS -> BK_TYPE BK_B64 BK_CHECK; 1 when the words are not one of our two key types, whole
  BK_TYPE=""; BK_B64=""; BK_CHECK=""
  case "${1:-}" in
    ssh-ed25519|ecdsa-sha2-nistp256) [ $# -ge 2 ] || return 1; BK_TYPE="$1"; BK_B64="$2"; shift 2;;
    AAAA*) BK_B64="$1"; shift;;
    *) return 1;;
  esac
  # at most one more word: SHA256:<six or more characters of the fingerprint> (the check), or a comment
  # as a public-key file carries one (ignored: the line carries our own)
  [ $# -le 1 ] || return 1
  if [ $# = 1 ]; then
    if [[ "$1" =~ ^SHA256:[A-Za-z0-9+/]{6,43}$ ]]; then BK_CHECK="${1#SHA256:}"
    elif ! [[ "$1" =~ ^[A-Za-z0-9._@][A-Za-z0-9._@-]{0,63}$ ]]; then return 1; fi
  fi
  [[ "$BK_B64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  case "$BK_B64" in
    "$BK_ED_PREFIX"*) BK_TYPE="${BK_TYPE:-ssh-ed25519}"; [ "$BK_TYPE" = ssh-ed25519 ] && [ ${#BK_B64} = 68 ] || return 1;;
    "$BK_EC_PREFIX"*) BK_TYPE="${BK_TYPE:-ecdsa-sha2-nistp256}"; [ "$BK_TYPE" = ecdsa-sha2-nistp256 ] && [ ${#BK_B64} = 140 ] || return 1;;
    *) return 1;;
  esac
  local n; n=$(printf '%s' "$BK_B64" | base64 -d 2>/dev/null | wc -c) || return 1
  n=${n//[[:space:]]/}
  if [ "$BK_TYPE" = ssh-ed25519 ]; then [ "$n" = 51 ]; else [ "$n" = 104 ]; fi
}
bk_keygen_fp() { # "TYPE BASE64" -> the fingerprint ssh-keygen prints for it, read from a pipe
  printf '%s\n' "$1" | ssh-keygen -l -E sha256 -f /dev/stdin 2>/dev/null | awk 'NR == 1 { print $2 }'
}
bk_keygen_ok() { # TYPE BASE64 FP -> 0 when ssh-keygen reads it as a public key with that fingerprint (an EC point
  # off the curve fails here). Where ssh-keygen is absent, or cannot read a key from a pipe at all (it is
  # asked about a known-good key first: OpenSSH 7.4's -f /dev/stdin is not measured), the shell's own
  # checks above are what there is, and the key is not refused for that
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  [ -n "$(bk_keygen_fp "$BK_KNOWN_GOOD")" ] || return 0
  [ "$(bk_keygen_fp "$1 $2")" = "$3" ]
}

# ---- the copy a forced command runs from --------------------------------------------------------------
# Every key line names a command in the lab's shared copy, so whoever can change that copy can run
# anything in every enrolled account, the moment its key is used. browser-key add therefore refuses
# unless the copy's own folders and files can be changed by their owner alone: the folder that holds
# the `current` link (re-pointing it re-points every key), the numbered directory, bin/, lib/,
# lib/adapters/, jobs/ and profiles/ (a profile names the image and the claude a worker runs), and each
# file in them; each owned by the copy's owner or root, none a link (but `current` itself). Every folder
# from / down to the copy is judged as well, and one that others may change is refused too: whoever can
# rename a folder above the copy can put another `current/bin/hpcworker` in its place, and a key's forced
# command would run it in every enrolled account at the next poll, from anywhere (README.md, "The
# browser's key"). A sticky folder (chmod +t), or one only its owner may write, is fine.
bk_dir_ok() { # DIR -> 0 when only its owner may add, rename or remove entries in it (or it is sticky)
  local m; m=$(stat -c %a "$1" 2>/dev/null) || return 1
  [ $(( 8#$m & 8#1000 )) != 0 ] && return 0
  [ $(( 8#$m & 8#022 )) = 0 ]
}
BK_WHY=""; BK_REAL=""
bk_walk() { # PATH: the directories a lookup of PATH reads, from /, links followed (40 at most); BK_WHY the
  # first one others may change ("" when none), BK_REAL the physical path; 1 when PATH cannot be walked
  local rest="$1" cur=/ c t hops=0 p
  BK_WHY=""; BK_REAL=""
  case "$rest" in /*) ;; *) return 1;; esac
  while :; do
    while [ "${rest#/}" != "$rest" ]; do rest="${rest#/}"; done
    [ -n "$rest" ] || break
    c="${rest%%/*}"; if [ "${rest#*/}" != "$rest" ]; then rest="${rest#*/}"; else rest=""; fi
    case "$c" in .) continue;; ..) [ "$cur" = / ] || { cur="${cur%/*}"; [ -n "$cur" ] || cur=/; }; continue;; esac
    [ -n "$BK_WHY" ] || bk_dir_ok "$cur" || BK_WHY="$cur"
    if [ "$cur" = / ]; then p="/$c"; else p="$cur/$c"; fi
    if [ -L "$p" ]; then
      hops=$((hops + 1)); [ $hops -le 40 ] || return 1
      t=$(readlink "$p") || return 1
      case "$t" in /*) cur=/; rest="$t${rest:+/$rest}";; *) rest="$t${rest:+/$rest}";; esac
      continue
    fi
    [ -e "$p" ] || return 1
    cur="$p"
  done
  BK_REAL="$cur"
  return 0
}
bk_copy_problems() { # ROOT -> one line per thing others than the copy's owner may change: "copy <path>" or
  # "above <path>" (both refused); nothing when there is none. 1 when the copy cannot be read at all
  local root="${1%/}" real owner holder hr d f m o n=0
  local -a list=()
  bk_msys && return 0   # a Windows checkout has no POSIX modes to judge
  bk_walk "$root" || return 1
  real="$BK_REAL"; [ -d "$real" ] || return 1
  owner=$(stat -c %u "$real" 2>/dev/null) || return 1
  [ -n "$BK_WHY" ] && printf 'above %s\n' "$BK_WHY"
  # the folder the copy is named in: with a `current` link, the one that holds it
  holder=$(dirname "$root"); hr=$(cd "$holder" 2>/dev/null && pwd -P) || return 1
  for d in "$hr" "$real" "$real/bin" "$real/lib" "$real/lib/adapters" "$real/jobs" "$real/profiles"; do
    if [ ! -d "$d" ] || [ -L "$d" ]; then printf 'copy %s\n' "$d"; else list+=("$d"); fi
  done
  for f in "$real/VERSION" "$real"/bin/* "$real"/lib/* "$real"/lib/adapters/* "$real"/jobs/* "$real"/profiles/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    case "$f" in "$real/lib/adapters") continue;; esac
    if [ -L "$f" ]; then printf 'copy %s\n' "$f"; else list+=("$f"); fi
  done
  # one stat for all of them (the names are the copy's own: no space, no line break)
  while read -r m o f; do
    n=$((n + 1))
    { [[ "$m" =~ ^[0-7]+$ ]] && [ $(( 8#$m & 8#022 )) = 0 ] && { [ "$o" = "$owner" ] || [ "$o" = 0 ]; }; } || printf 'copy %s\n' "$f"
  done < <(stat -c '%a %u %n' -- "${list[@]}" 2>/dev/null)
  [ "$n" = "${#list[@]}" ] || printf 'copy %s\n' "$real"   # something could not be read: refused rather than guessed
  return 0
}
bk_line_root() { # -> the copy the line names: the shared copy the site profile names, which must be the one
  # that runs; else (no shared copy at this site) the copy that runs. Exit 1, printing the copy the site
  # profile names, when another copy runs (a command substitution: no variable of it survives)
  local run want site
  run=$(bk_root_run) || return 1
  site=""; [ -s "$PROFILE" ] && site=$(bk_prof_str "$PROFILE" site 2>/dev/null)
  # an account not set up yet: the one site profile of this copy that names this copy as its shared copy
  [ -n "$site" ] || site=$(site_of_this_copy)
  want=$(shared_default "$site"); want="${want%/}"
  if [ -n "$want" ]; then
    same_dir "$want" "$run" || { printf '%s' "$want"; return 1; }
    printf '%s' "$want"
  else
    printf '%s' "${run%/}"
  fi
}

# ---- the account's side: home, ~/.ssh, authorized_keys --------------------------------------------
bk_home_check() { # refuses with a sentence when sshd would ignore every key here, or when this is not a person's own account
  [ "$(bk_uid)" != 0 ] || bk_refuse 2 root "this runs as your own account, never as root. Nothing was changed."
  local h="${HOME%/}"
  [ -n "$h" ] && [ -d "$h" ] || bk_refuse 3 home "your home folder could not be found. Ask your lab lead. Nothing was changed."
  [ -L "$h" ] && bk_refuse 3 home "your home folder is a link to another folder, so Beethoven will not change how your account signs in. Ask your lab lead. Nothing was changed."
  bk_mode_ok "$h" || bk_msys || bk_refuse 3 home "other people can change your home folder, so the grid would ignore Beethoven's key. Ask your lab lead. Nothing was changed."
}
bk_ssh_dir() { # ~/.ssh: made at 700 when missing; refused when it is a link, someone else's, or writable by group or others
  local sd="$HOME/.ssh"
  [ -L "$sd" ] && bk_refuse 4 ssh-dir "your ~/.ssh folder is a link to another folder, so Beethoven will not change it. Ask your lab lead. Nothing was changed."
  if [ ! -e "$sd" ]; then (umask 077; mkdir "$sd") 2>/dev/null || bk_refuse 4 ssh-dir "your ~/.ssh folder could not be made. Ask your lab lead. Nothing was changed."; chmod 700 "$sd" 2>/dev/null; fi
  { [ -d "$sd" ] && { bk_mode_ok "$sd" || bk_msys; }; } || bk_refuse 4 ssh-dir "other people can change your ~/.ssh folder, or it is not yours, so the grid would ignore Beethoven's key. Ask your lab lead. Nothing was changed."
}
bk_ak_ok() { # authorized_keys: absent, or a plain file of this account's that only it may change, with no NUL byte; ~/.ssh not a link
  local sd="$HOME/.ssh" ak="$HOME/.ssh/authorized_keys"
  [ -L "$sd" ] && return 1
  [ -L "$ak" ] && return 1
  [ -e "$ak" ] || return 0
  [ -f "$ak" ] && { bk_mode_ok "$ak" || bk_msys; } || return 1
  [ "$(tr -d '\000' < "$ak" | wc -c)" = "$(wc -c < "$ak")" ]
}
bk_lock() { # one writer at a time (an add racing the gate's own removal); a lock older than two minutes is a leftover
  local l="$HOME/.ssh/.beethoven-browser.lock" i t
  for i in 1 2 3 4 5 6; do
    if mkdir "$l" 2>/dev/null; then BK_LOCK="$l"; return 0; fi
    t=$(stat -c %Y "$l" 2>/dev/null) && [ $(( $(date +%s) - t )) -gt 120 ] && { rmdir "$l" 2>/dev/null; continue; }
    sleep 1
  done
  return 1
}
bk_unlock() { [ -n "${BK_LOCK:-}" ] && rmdir "$BK_LOCK" 2>/dev/null; BK_LOCK=""; return 0; }
bk_write() { # MODE [LINE] -> 0 written, 10 nothing to change, 1 could not (nothing changed)
  # add LINE: every line of ours out, LINE in at the end; drop-all: every line of ours out; drop-line
  # LINE: that exact line out. Every other line is kept as it was, in its place. A temporary file at
  # 600 in ~/.ssh, the old file kept as authorized_keys.beethoven-prev, then one rename. The kept copy
  # holds every line of the student's own and none of Beethoven's: putting it back can never bring a
  # forgotten or replaced browser key back.
  local mode="$1" line="${2:-}" sd="$HOME/.ssh" ak="$HOME/.ssh/authorized_keys" tmp prev rc
  bk_ak_ok || return 1
  case "$mode" in
    add) if [ -f "$ak" ] && [ "$(grep -a -c -E -- "$BK_LINE_RE" "$ak")" = 1 ] && grep -a -q -x -F -- "$line" "$ak"; then return 10; fi;;
    drop-all) { [ -f "$ak" ] && grep -a -q -E -- "$BK_LINE_RE" "$ak"; } || return 10;;
    drop-line) { [ -f "$ak" ] && grep -a -q -x -F -- "$line" "$ak"; } || return 10;;
    *) return 1;;
  esac
  bk_lock || return 1
  bk_ak_ok || { bk_unlock; return 1; }   # again, now that this process holds the lock
  tmp=$(mktemp "$sd/.authorized_keys.beethoven.XXXXXX" 2>/dev/null) || { bk_unlock; return 1; }
  if [ -e "$ak" ]; then
    if [ "$mode" = drop-line ]; then grep -a -v -x -F -- "$line" "$ak" > "$tmp"; else grep -a -v -E -- "$BK_LINE_RE" "$ak" > "$tmp"; fi
    rc=$?; [ $rc -le 1 ] || { rm -f "$tmp"; bk_unlock; return 1; }   # 1: no line was left, every one was ours
    # a last line without its newline stays a line of its own
    [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ] && echo >> "$tmp"
  fi
  if [ "$mode" = add ]; then printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; bk_unlock; return 1; }; fi
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; bk_unlock; return 1; }
  if [ -e "$ak" ]; then
    prev=$(mktemp "$sd/.authorized_keys.prev.XXXXXX" 2>/dev/null) \
      && { if grep -a -q -E -- "$BK_LINE_RE" "$ak"; then grep -a -v -E -- "$BK_LINE_RE" "$ak" > "$prev"; [ $? -le 1 ]; else cat "$ak" > "$prev"; fi; } \
      && chmod 600 "$prev" && mv -f "$prev" "$ak.beethoven-prev" \
      || { rm -f "$tmp" "${prev:-}"; bk_unlock; return 1; }
  fi
  mv -f "$tmp" "$ak" || { rm -f "$tmp"; bk_unlock; return 1; }
  # where SELinux labels home folders, a file a program made needs sshd's label to be read
  command -v restorecon >/dev/null 2>&1 && restorecon "$sd" "$ak" "$ak.beethoven-prev" >/dev/null 2>&1
  bk_unlock
  return 0
}

# ---- hpcworker browser-key ------------------------------------------------------------------------
cmd_browser_key() {
  LC_ALL=C; export LC_ALL
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)
      bk_person_or_session || bk_refuse 2 agent "this changes how your account signs in, so it runs only for you: in your own sign-in from Beethoven, or typed in a terminal, never under Claude Code, another program or a batch job. Nothing was changed."
      bk_parse_key "$@" || bk_refuse 2 key "the key Beethoven sent did not come through whole. Nothing was changed."
      local fp; fp=$(bk_fp "$BK_B64") || bk_refuse 2 key "the key Beethoven sent did not come through whole. Nothing was changed."
      if [ -n "$BK_CHECK" ] && [[ "${fp#SHA256:}" != "$BK_CHECK"* ]]; then
        bk_refuse 2 key "the key does not match the fingerprint it came with. Nothing was changed."
      fi
      bk_keygen_ok "$BK_TYPE" "$BK_B64" "$fp" || bk_refuse 2 key "the key Beethoven sent did not come through whole. Nothing was changed."
      local root
      root=$(bk_line_root) || bk_refuse 8 copy "this must run from the lab's copy of the grid tool at ${root:-the folder the site profile names}. Nothing was changed."
      { [[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [ -r "$root/bin/hpcworker" ]; } \
        || bk_refuse 8 copy "the lab's copy of the grid tool is in a folder Beethoven cannot name safely. Ask your lab lead. Nothing was changed."
      local probs bad
      probs=$(bk_copy_problems "$root") || bk_refuse 8 copy "the lab's copy of the grid tool at $root could not be checked. Ask your lab lead. Nothing was changed."
      bad=$(printf '%s\n' "$probs" | sed -n 's/^copy //p' | head -1)
      [ -z "$bad" ] || bk_refuse 8 copy "other people can change $bad in the lab's copy of the grid tool, which your key would run. Ask your lab lead. Nothing was changed."
      bad=$(printf '%s\n' "$probs" | sed -n 's/^above //p' | head -1)
      [ -z "$bad" ] || bk_refuse 8 copy "other people can rename things in $bad, which holds the lab's copy of the grid tool your key would run. Ask your lab lead (hpcworker browser-key check says what to change). Nothing was changed."
      bk_home_check
      bk_ssh_dir
      local line
      line="restrict,command=\"$root/bin/hpcworker gate\" $BK_TYPE $BK_B64 $BK_TAG $(date -u +%Y-%m-%d)"
      [[ "$line" =~ $BK_LINE_RE ]] || bk_refuse 7 authorized-keys "Beethoven could not write its line safely. Ask your lab lead. Nothing was changed."
      bk_write add "$line"
      case $? in
        0|10) gate_names_clear; bk_stop 0 "HPCW-KEY added $fp";;
        *) bk_refuse 7 authorized-keys "your ~/.ssh/authorized_keys file could not be changed safely. Ask your lab lead. Nothing was changed.";;
      esac;;
    remove)
      [ $# = 0 ] || bk_refuse 2 usage "browser-key remove takes nothing more. Nothing was changed."
      bk_person_or_session || bk_refuse 2 agent "this changes how your account signs in, so it runs only for you, never under Claude Code, another program or a batch job. Nothing was changed."
      bk_write drop-all
      case $? in
        0) bk_stop 0 "HPCW-KEY removed";;
        10) bk_stop 0 "HPCW-KEY none";;
        *) bk_refuse 7 authorized-keys "your ~/.ssh/authorized_keys file could not be changed safely. Ask your lab lead. Nothing was changed.";;
      esac;;
    check)
      # read only, for the lab lead (and diag): the copy a key line would name, and what others may change
      [ $# = 0 ] || { echo "hpcworker: browser-key check takes nothing more" >&2; exit 2; }
      local root probs l refused=0
      if ! root=$(bk_line_root); then echo "HPCW-KEY check refused this is not the lab's copy (the site profile names ${root:-another})"; exit 8; fi
      if ! probs=$(bk_copy_problems "$root"); then echo "HPCW-KEY check refused $root could not be read"; exit 8; fi
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        case "$l" in
          copy\ *) echo "copy: others than its owner may change ${l#copy }"; refused=1;;
          above\ *) echo "above the copy: others than its owner may rename things in ${l#above } (chmod +t or chmod go-w on it, by its owner)"; refused=1;;
        esac
      done <<< "$probs"
      if [ $refused = 1 ]; then echo "HPCW-KEY check refused $root"; exit 8; fi
      echo "HPCW-KEY check ok $root"; exit 0;;
    *) echo "hpcworker: browser-key add TYPE KEY [COMMENT|SHA256:CHECK] | browser-key remove | browser-key check" >&2; exit 2;;
  esac
}

# ---- hpcworker gate: the forced command -------------------------------------------------------------
# What a copied key can do is exactly this table, and nothing else:
#   version                                   HPCW-GATE ok <framework> <due|never|-> <account> claude=<yes|no|unknown>
#   status NAME                               worker status --name NAME --json --poll-floor 60
#   watch NAME                                worker watch --name NAME --json --minutes 30 --poll-floor 60 (two at once)
#   connect NAME SITE INSTALLID|- MODE chain|no-chain
#                                             connect --name NAME --profile SITE --permission-mode MODE [--consent ID] [--no-chain] --login never
#   stop NAME                                 worker stop --name NAME
#   restrict NAME                             worker restrict --name NAME
#   read NAME FILE                            FILE one of status.json connection.json progress.log node: its bytes
#                                             (progress.log's last 256 KB); exit 1 none, 3 not a plain file or too big
#   forget                                    this account's Beethoven line out: HPCW-KEY forgotten | none | stuck
# Anything else, an empty or over-long command, a character outside [A-Za-z0-9._-] and single spaces, a
# word that starts with "-" (but the lone "-" for no install id), or a word to `gate` itself: "HPCW-GATE
# refused", exit 126. Past the due date (browser_key_days in the site profile; none means no expiry): the
# line is removed, "HPCW-KEY expired", exit 125. The caps (at most 3 worker names, 12 connects in any
# hour, 2 watches at once): "HPCW-GATE limit names|hourly|watch", exit 123, nothing run. A name counts
# for GATE_NAME_DAYS after its last use, and the student's own sign-in (browser-key add) clears them all.
# connect is ALWAYS --login never, written last so no earlier word can outrank it, and connect itself
# pins it under the gate: a key that could run the Claude sign-in sitting could sign the student's
# worker in to someone else's Claude account, a shell in the account by a longer road.
gate_refuse() { echo "HPCW-GATE refused"; exit 126; }
gate_limit() { echo "HPCW-GATE limit $1"; exit 123; }
gate_name_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; }   # WORKER_NAME_RE, never with a leading "-"
gate_exec() { # ARGS: hpcworker's own verb, in a fresh bash with none of the variables that make bash read or trace something first
  exec env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH -u GLOBIGNORE -u PROMPT_COMMAND HPCW_GATE=1 "${BASH:-/bin/bash}" "$SELF" "$@"
}
bk_days() { # the site's browser_key_days (its site profile first, then the account's): whole days, or nothing for no expiry
  local f v site=""
  [ -s "$PROFILE" ] && site=$(bk_prof_str "$PROFILE" site 2>/dev/null)
  for f in ${site:+"$PROFILES/$site.json"} "$PROFILE"; do
    [ -s "$f" ] || continue
    v=$(read_field "$f" browser_key_days 2>/dev/null) || continue
    v=${v//[[:space:]]/}
    if [[ "$v" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$v))" -gt 0 ]; then printf '%s' "$((10#$v))"; return 0; fi
  done
  return 0
}
bk_due() { # DATE DAYS -> the due date, or nothing for a date that is not a real one
  local d="$1" n
  n=$(date -u -d "$d" +%Y-%m-%d 2>/dev/null) && [ "$n" = "$d" ] || return 1
  date -u -d "$d + $2 days" +%Y-%m-%d 2>/dev/null
}
gate_expiry() { # a line of ours past its due date is removed, and the gate stops: HPCW-KEY expired, 125
  local days; days=$(bk_days); [ -n "$days" ] || return 0
  local ak="$HOME/.ssh/authorized_keys" today line due any=0
  [ -f "$ak" ] && [ ! -L "$ak" ] || return 0
  today=$(date -u +%Y-%m-%d)
  while IFS= read -r line; do
    due=$(bk_due "${line##* }" "$days")
    if [ -z "$due" ] || [[ "$today" > "$due" ]]; then bk_write drop-line "$line"; any=1; fi
  done < <(grep -a -E -- "$BK_LINE_RE" "$ak" 2>/dev/null)
  [ $any = 0 ] || { echo "HPCW-KEY expired"; exit 125; }
}
gate_state_dir() { # [SITE] -> the account's state directory: profile.json's shared_state_dir, else SITE's site profile's; awk only
  local sd=""
  [ -s "$PROFILE" ] && sd=$(bk_prof_str "$PROFILE" shared_state_dir 2>/dev/null)
  if [ -z "$sd" ] && [ -n "${1:-}" ]; then sd=$(bk_prof_str "$PROFILES/$1.json" shared_state_dir 2>/dev/null); fi
  [ -n "$sd" ] && bk_abs "$sd" || return 1
  printf '%s' "${sd%/}"
}
gate_claude_state() { # yes | no | unknown: the newest Claude Code answer any run of this account recorded (files only)
  local STATE_DIR last; STATE_DIR=$(gate_state_dir) || { echo unknown; return 0; }
  last=$(connect_last_login 2>/dev/null)
  case "${last%%|*}" in true) echo yes;; false) echo no;; *) echo unknown;; esac
}
gate_version() {
  local fw days due=never dd line ak="$HOME/.ssh/authorized_keys" who
  fw=$(read_version "$SRC_ROOT/VERSION") || fw="$VERSION"
  days=$(bk_days)
  if [ -n "$days" ]; then
    due=-
    while IFS= read -r line; do
      dd=$(bk_due "${line##* }" "$days") || continue
      { [ "$due" = - ] || [[ "$dd" < "$due" ]]; } && due="$dd"
    done < <(grep -a -E -- "$BK_LINE_RE" "$ak" 2>/dev/null)
  fi
  who=$(id -un 2>/dev/null)
  echo "HPCW-GATE ok ${fw:-?} $due ${who:--} claude=$(gate_claude_state)"
}
gate_read() { # NAME FILE
  case "$2" in status.json|connection.json|progress.log|node) ;; *) gate_refuse;; esac
  local sd f sz
  sd=$(gate_state_dir) || { echo "HPCW-GATE missing" >&2; return 1; }
  f="$sd/$1/$2"
  [ -L "$sd/$1" ] && { echo "HPCW-GATE not-plain" >&2; return 3; }
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then echo "HPCW-GATE missing" >&2; return 1; fi
  # a run file is written by the job as a plain file: a link or anything else is not followed
  { [ -f "$f" ] && [ ! -L "$f" ]; } || { echo "HPCW-GATE not-plain" >&2; return 3; }
  case "$2" in
    progress.log) tail -c "$BK_MAX_READ" -- "$f";;
    *) sz=$(stat -c %s -- "$f" 2>/dev/null) && [ "$sz" -le "$BK_MAX_READ" ] || { echo "HPCW-GATE too-large" >&2; return 3; }
       cat -- "$f";;
  esac
}
# ---- the caps: one small file per account, <state_dir>/.gate/caps, under a lock -----------------------
#   name <worker name> <epoch>   a name a key has used, and when it last did (at most GATE_MAX_NAMES used in
#                                the last GATE_NAME_DAYS days; browser-key add, the student's own sign-in, clears them)
#   connect <epoch>        a connect through the gate, or a restrict of a name with no run (those of the last hour are kept)
# Watches hold one of GATE_MAX_WATCHES slot folders, <state_dir>/.gate/watch.<n>, for as long as they
# run (a watch ends after GATE_WATCH_MIN minutes, so a slot older than that and five minutes is a leftover).
GATE_LOCK=""
gate_lock() { # DIR -> 0 when this process holds DIR/lock; a lock older than two minutes is a leftover
  local l="$1/lock" i t
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if mkdir "$l" 2>/dev/null; then GATE_LOCK="$l"; return 0; fi
    t=$(stat -c %Y "$l" 2>/dev/null) && [ $(( $(date +%s) - t )) -gt 120 ] && { rmdir "$l" 2>/dev/null; continue; }
    sleep 1
  done
  return 1
}
gate_unlock() { [ -n "$GATE_LOCK" ] && rmdir "$GATE_LOCK" 2>/dev/null; GATE_LOCK=""; return 0; }
gate_dir() { # STATE_DIR -> its .gate folder, made private; 1 when it cannot be (or is a link)
  local d="$1/.gate"
  mkdir -p "$1" 2>/dev/null
  [ -d "$d" ] || { (umask 077; mkdir "$d") 2>/dev/null; }
  { [ -d "$d" ] && [ ! -L "$d" ]; } || return 1
  chmod 700 "$d" 2>/dev/null
  printf '%s' "$d"
}
gate_caps() { # STATE_DIR KIND NAME -> 0 allowed and recorded; 1 the names cap; 2 the hourly cap; 3 could not record
  # KIND connect (a name, and one of the hour's actions) or restrict (of a run that exists: nothing is
  # counted; of a name with no run: one of the hour's actions, and no name)
  local d f kind="$2" name="$3" now cut ncut w v t have=0 i run=0 tmp
  local -a names=() times=() recent=()
  d=$(gate_dir "$1") || return 3
  f="$d/caps"
  gate_lock "$d" || return 3
  [ -L "$f" ] && { gate_unlock; return 3; }
  now=$(date +%s); cut=$((now - 3600)); ncut=$((now - GATE_NAME_DAYS * 86400))
  if [ -f "$f" ]; then
    while read -r w v t; do
      case "$w" in
        # a line from before names carried a time counts as used now (it can only make the cap stricter)
        name) gate_name_ok "$v" || continue; [[ "${t:-}" =~ ^[0-9]{1,12}$ ]] || t=$now
              [ "$t" -gt "$ncut" ] || continue
              if [ "$v" = "$name" ]; then have=1; fi
              names+=("$v"); times+=("$t");;
        connect) [[ "$v" =~ ^[0-9]{1,12}$ ]] && [ "$v" -gt "$cut" ] && [ "$v" -le "$now" ] && recent+=("$v");;
      esac
    done < "$f"
  fi
  [ -d "$1/$name" ] && [ ! -L "$1/$name" ] && run=1
  if [ "$kind" = restrict ] && [ $run = 1 ]; then gate_unlock; return 0; fi
  if [ "$kind" = connect ]; then
    if [ $have = 0 ]; then
      [ ${#names[@]} -lt "$GATE_MAX_NAMES" ] || { gate_unlock; return 1; }
      names+=("$name"); times+=("$now")
    else
      for ((i = 0; i < ${#names[@]}; i++)); do [ "${names[i]}" = "$name" ] && times[i]=$now; done
    fi
  fi
  [ ${#recent[@]} -lt "$GATE_MAX_CONNECTS" ] || { gate_unlock; return 2; }
  recent+=("$now")
  tmp="$f.$$"
  { for ((i = 0; i < ${#names[@]}; i++)); do printf 'name %s %s\n' "${names[i]}" "${times[i]}"; done
    for v in ${recent[@]+"${recent[@]}"}; do printf 'connect %s\n' "$v"; done; } > "$tmp" 2>/dev/null \
    && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || { rm -f "$tmp"; gate_unlock; return 3; }
  gate_unlock
  return 0
}
gate_names_clear() { # the worker names the gate counted are forgotten: run by browser-key add, which only the
  # student's own sign-in (password and code) reaches. The hour's actions stay. Quiet: nothing to clear is fine
  local sd d f tmp
  sd=$(gate_state_dir 2>/dev/null) || return 0
  d="$sd/.gate"; f="$d/caps"
  { [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$f" ] && [ ! -L "$f" ]; } || return 0
  gate_lock "$d" || return 0
  tmp="$f.$$"
  { grep -v '^name ' "$f" > "$tmp"; [ $? -le 1 ]; } && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$f" || rm -f "$tmp"
  gate_unlock
  return 0
}
gate_watch_slot() { # STATE_DIR -> the slot folder taken; 1 when every slot is in use, 3 when none could be made
  local d i s t now
  d=$(gate_dir "$1") || return 3
  now=$(date +%s)
  for ((i = 1; i <= GATE_MAX_WATCHES; i++)); do
    s="$d/watch.$i"
    if mkdir "$s" 2>/dev/null; then printf '%s' "$s"; return 0; fi
    t=$(stat -c %Y "$s" 2>/dev/null) && [ $(( now - t )) -gt $(( (GATE_WATCH_MIN + 5) * 60 )) ] \
      && rmdir "$s" 2>/dev/null && mkdir "$s" 2>/dev/null && { printf '%s' "$s"; return 0; }
  done
  return 1
}
cmd_gate() {
  LC_ALL=C; export LC_ALL   # ranges and lengths in bytes, whatever LANG or LC_* the client sent
  [ $# = 0 ] || gate_refuse
  local c="${SSH_ORIGINAL_COMMAND-}"
  { [ -n "$c" ] && [ ${#c} -le 200 ]; } || gate_refuse
  case "$c" in *[!A-Za-z0-9._\ -]*|' '*|*' '|*'  '*) gate_refuse;; esac
  # split on the single spaces the check above leaves; no glob character can be left either, and
  # globbing is off anyway (no here-string: bash 4.2 writes one to a file under TMPDIR)
  local -a t; local w
  # shellcheck disable=SC2206
  set -f; t=( $c ); set +f
  [ ${#t[@]} -ge 1 ] || gate_refuse
  for w in "${t[@]}"; do
    [[ "$w" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || gate_refuse
    # never an option: a word that starts with "-" is refused, but the lone "-" that stands for "no install id"
    case "$w" in -) ;; -*) gate_refuse;; esac
  done
  local n=${#t[@]} sd r
  gate_expiry
  case "${t[0]}" in
    version) [ "$n" = 1 ] || gate_refuse; gate_version; exit 0;;
    status) [ "$n" = 2 ] && gate_name_ok "${t[1]}" || gate_refuse
      gate_exec worker status --name "${t[1]}" --json --poll-floor "$GATE_POLL_FLOOR";;
    # watch, restrict and connect keep their state under the account's state directory. With no profile at
    # all (an account never set up; connect names its site, whose profile says where) there is nothing to
    # watch or restrict, and the verb itself says so; a profile whose state directory cannot be read is
    # never a way round a cap: "limit busy"
    watch) [ "$n" = 2 ] && gate_name_ok "${t[1]}" || gate_refuse
      if sd=$(gate_state_dir); then
        if [ -d "$sd/${t[1]}" ] && [ ! -L "$sd/${t[1]}" ]; then
          r=$(gate_watch_slot "$sd"); case $? in 0) ;; 1) gate_limit watch;; *) gate_limit busy;; esac
          export HPCW_GATE_SLOT="$r"
        fi
      elif [ -s "$PROFILE" ]; then gate_limit busy; fi
      gate_exec worker watch --name "${t[1]}" --json --minutes "$GATE_WATCH_MIN" --poll-floor "$GATE_POLL_FLOOR";;
    stop) [ "$n" = 2 ] && gate_name_ok "${t[1]}" || gate_refuse
      gate_exec worker stop --name "${t[1]}";;
    restrict) [ "$n" = 2 ] && gate_name_ok "${t[1]}" || gate_refuse
      if sd=$(gate_state_dir); then
        gate_caps "$sd" restrict "${t[1]}"; case $? in 0) ;; 1) gate_limit names;; 2) gate_limit hourly;; *) gate_limit busy;; esac
      elif [ -s "$PROFILE" ]; then gate_limit busy; fi
      gate_exec worker restrict --name "${t[1]}";;
    connect)
      [ "$n" = 6 ] && gate_name_ok "${t[1]}" && [[ "${t[2]}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && [[ "${t[3]}" =~ ^([0-9a-f]{32}|-)$ ]] || gate_refuse
      case "${t[4]}" in default|acceptEdits|plan) ;; *) gate_refuse;; esac
      case "${t[5]}" in chain|no-chain) ;; *) gate_refuse;; esac
      if sd=$(gate_state_dir "${t[2]}"); then
        gate_caps "$sd" connect "${t[1]}"; case $? in 0) ;; 1) gate_limit names;; 2) gate_limit hourly;; *) gate_limit busy;; esac
      elif [ -s "$PROFILE" ] || [ -s "$PROFILES/${t[2]}.json" ]; then gate_limit busy; fi
      local -a a=(connect --name "${t[1]}" --profile "${t[2]}" --permission-mode "${t[4]}")
      [ "${t[3]}" = - ] || a+=(--consent "${t[3]}")
      [ "${t[5]}" = no-chain ] && a+=(--no-chain)
      a+=(--login never)
      gate_exec "${a[@]}";;
    read) [ "$n" = 3 ] && gate_name_ok "${t[1]}" || gate_refuse; gate_read "${t[1]}" "${t[2]}"; exit $?;;
    forget)
      [ "$n" = 1 ] || gate_refuse
      bk_write drop-all
      case $? in 0) echo "HPCW-KEY forgotten"; exit 0;; 10) echo "HPCW-KEY none"; exit 0;; *) echo "HPCW-KEY stuck"; exit 7;; esac;;
    *) gate_refuse;;
  esac
  gate_refuse
}
