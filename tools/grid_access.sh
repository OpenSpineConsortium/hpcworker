#!/usr/bin/env bash
# Keep the grid's approved list: which accounts, besides the lab's own, may enter the lab's volume.
# The list IS the set of named-user ACL entries `user:<id>:rwx` on the volume root (/rs/rs_grp_oschome
# at Wayne State: the parent of the site profile's shared_state_dir). rwx, because each student makes
# their own folder there; the root's sticky bit stops anyone renaming or removing another's entries;
# its other::--- keeps every account not on the list out. Those two facts are the gate, and this tool
# refuses to touch a root that lacks either. Below the gate, everything students use (shared/,
# shared/beethoven and all under it) is readable by other; shared/access and the owner's own folder
# stay closed by their own modes. The Unix group (oschome) is C&IT's to change and is not the list.
#
#   tools/grid_access.sh [--site wayne] [--host wsu-grid] [--root DIR] [--roster-file FILE]
#                        [--dry-run] [--force] [--quiet] [--open-tree] [--check-tree]
#   tools/grid_access.sh --here --roster-file FILE [the same options]   on the cluster, from a checkout
#
# The approved AccessIDs come from, in order: --roster-file FILE (one per line; blank lines and lines
# starting with # are skipped), the command in $BEETHOVEN_ROSTER_CMD, else `node
# <service>/tools/intake/admin.mjs roster`, where <service> is $BEETHOVEN_SERVICE_DIR or the checkout
# `ashley` beside this one (admin.mjs finds the admin token itself). `roster` prints the accounts
# approved with the extension grant, and only those: not the store reviewers' mock account, and not an
# account approved for the lab only (approve-lab, grant lab), which therefore never reaches the grid's
# folders. Each must look like ab1234 (^[a-z]{2}[0-9]{4}$) or the run refuses, naming the line, and
# nothing changes. An empty list is refused unless --force: it would shut every student out. With
# --here (on the cluster, where the login node bans node) give --roster-file or $BEETHOVEN_ROSTER_CMD.
#
# What it keeps, on the machine that runs it, under $BEETHOVEN_VENDOR_DIR (default ~/.beethoven-vendor):
#   state/grid_access.<site>.ids  the list last applied and where; written only after the grid side
#                                 applied it. An approved id the grid does not know yet (no account) is
#                                 skipped there and recorded on a line "# unknown <id> <date>" instead
#                                 (UTC date of the try), not in the list.
#   state/grid_access.log         one line per run
# When the target is the one last applied and the list, less the ids recorded as unknown, is the list
# last applied, it does not connect to the grid at all; an id recorded as unknown is tried again at most
# once a day (the first run on a later UTC date connects for it), or at once with --force. --force,
# --open-tree or --check-tree connects anyway. --dry-run connects when a run would, changes nothing on
# the grid and writes no state; `--dry-run --force` is the way to see the grid's entries as they are
# now. --quiet prints nothing unless the grid side changed something, skipped an id or a check failed
# (errors always go to stderr; the log has every run): for the scheduled task.
#
# The grid side (--apply [--dry-run] [--open-tree] [--check-tree] ROOT id...) runs over ssh (BatchMode)
# as `bash -s` with this script on stdin and the ids as arguments. It is file work only on the login
# node (stat, readlink, getfacl, setfacl, chmod, find, id): no scheduler call, no container, no python
# or node, no temp file (no here-documents or here-strings: bash writes those to a temp file). In order:
#   1. resolves ROOT's physical path, refuses unless this account owns it, and refuses unless it keeps
#      other::--- and the sticky bit (it prints the fix: chmod +t, chmod o-rwx). Nothing has changed yet;
#   2. adds user:<id>:rwx for each id (skipping, with a line, an id `id` does not know, and the owner),
#      removes every named user entry not on the list, and prints each addition and removal. A skipped
#      id's entry, if it has one, is left as it is. It runs setfacl with -n, so the mask is never
#      recalculated: the owner's user:: entry and the group, mask and other entries are never changed,
#      and no default entry is touched;
#   3. with --open-tree, does what was done by hand on 2026-10-02, idempotently, and only that:
#      chmod o+rx ROOT/shared; o+rX on everything under ROOT/shared/beethoven (links not followed);
#      setfacl -d -m o::r-x on each folder under ROOT/shared/beethoven. It never touches
#      ROOT/shared/access or ROOT/<owner>, nor deploy_shared's staging folders
#      (shared/beethoven/hpcworker/.incoming-*, closed while a publish runs, left behind by one that failed);
#   4. checks what a student needs and prints one line per check (ok or FAILED). Every run, cheap: the
#      gate still holds (owner, sticky, other::---) and the mask lets the entries' rwx through; the list
#      read back is the list applied (entries of skipped ids aside); the root's entries: each is named
#      for the account that owns it and is not a link (a student's own folder) or belongs to the root's
#      owner, so no one has taken the place of another student's folder before that student's first run;
#      shared and shared/beethoven open to other (read and enter); hpcworker/current/bin/hpcworker
#      readable and runnable by other, and every folder on the way enterable; the sandbox
#      (containers/claude-node22) and npm-claude-node22 likewise; shared/access and ROOT/<owner> closed
#      to other (no r, no x). Only with --open-tree or --check-tree, the full sweep: nothing under
#      shared/beethoven closed to other (tens of thousands of entries; the staging folders left out).
#      A failed check does not undo the list.
# Its output ends with the resulting list: "grid access list on ROOT: id id id".
#
# Exit 0: done (or unchanged, not connected); 1: refused or failed (a refusal changes nothing; the state
# file is not written); 2: the list was applied but a check failed (the state file is written; the
# check's line says what to fix).
set -uo pipefail
set -f
export LC_ALL=C

say() { printf '%s\n' "$*"; }
die() { printf 'grid_access: %s\n' "$*" >&2; exit 1; }
ID_RE='^[a-z]{2}[0-9]{4}$'

# ---- the grid side: grid_access.sh --apply [--dry-run] [--open-tree] [--check-tree] ROOT id... ----------
ga_mode() { stat -c %A -- "$1" 2>/dev/null; }
ga_other() { local m; m=$(ga_mode "$1") || return 1; printf '%s' "${m:7:3}"; }   # other's three places: r w x|t|T|-
ga_o_enter() { case "${1:2:1}" in x|t) return 0;; esac; return 1; }
ga_named() { # PATH -> "name perms" for each named user entry of the access ACL (never default:, never user::)
  getfacl -p --omit-header "$1" 2>/dev/null | sed -n 's/^user:\([^:][^:]*\):\([-rwx][-rwx][-rwx]\).*/\1 \2/p'
}
ga_entry() { # PATH TAG -> the perms of a base entry (user, group, mask, other), empty when there is none
  getfacl -p --omit-header "$1" 2>/dev/null | sed -n "s/^$2::\([-rwx][-rwx][-rwx]\).*/\1/p" | head -1
}
ga_gate() { # PROOT [OWNER] -> what is wrong with the gate, one line each with its fix; nothing when it holds
  local o a u
  o=$(ga_other "$1") || { say "it cannot be read with stat"; return 0; }
  if [ -n "${2:-}" ]; then
    u=$(stat -c %U -- "$1" 2>/dev/null)
    [ "$u" = "$2" ] || say "it belongs to ${u:-an account stat cannot name}, not to $2, who keeps the list"
  fi
  case "${o:2:1}" in t|T) ;; *) say "it is not sticky, so anyone who may write in it could rename another's folder (fix: chmod +t $1)";; esac
  case "$o" in ---|--T) ;; *) say "other accounts may use it (other: $o), so the list is not what keeps them out (fix: chmod o-rwx $1)";; esac
  a=$(ga_entry "$1" other)
  case "$a" in ""|---) ;; *) say "its ACL gives other $a (fix: chmod o-rwx $1)";; esac
}
GA_FAILED=0
ga_ok() { say "  ok      $*"; }
ga_fail() { say "  FAILED  $*"; GA_FAILED=$((GA_FAILED + 1)); }
ga_reach() { # LABEL PATH PROOT: other may read PATH and enter (or run) it, and enter every folder from PROOT down to it
  local label="$1" p="$2" proot="$3" phys rel rest part cur o bad=""
  phys=$(readlink -f -- "$p" 2>/dev/null)
  if [ -z "$phys" ] || [ ! -e "$phys" ]; then ga_fail "$label: ${p#"$proot"/} is missing"; return 0; fi
  case "$phys" in "$proot"/*) rel=${phys#"$proot"/};; *) rel="";; esac
  cur=$proot rest=$rel
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    if [ "$part" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    cur="$cur/$part"
    [ -n "$rest" ] || break                       # the last part is PATH itself, judged below
    o=$(ga_other "$cur"); ga_o_enter "$o" || bad="$bad ${cur#"$proot"/} ($o)"
  done
  o=$(ga_other "$phys")
  { [ "${o:0:1}" = r ] && ga_o_enter "$o"; } || bad="$bad ${phys#"$proot"/} ($o)"
  if [ -z "$bad" ]; then ga_ok "$label: other may read and enter it ($(ga_mode "$phys"))"
  else ga_fail "$label: closed to other at$bad (fix: tools/grid_access.sh --open-tree)"; fi
}
ga_closed() { # LABEL PATH: other may neither read nor enter PATH (absent is fine)
  local phys o
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then ga_ok "$1 is absent"; return 0; fi
  phys=$(readlink -f -- "$2" 2>/dev/null); o=$(ga_other "${phys:-$2}")
  if [ -z "$o" ]; then ga_fail "$1: its mode cannot be read"
  elif [ "${o:0:1}" != r ] && ! ga_o_enter "$o"; then ga_ok "$1 is closed to other ($(ga_mode "${phys:-$2}"))"
  else ga_fail "$1 is open to other ($(ga_mode "${phys:-$2}")) (fix: chmod o-rwx ${phys:-$2})"; fi
}
ga_entries() { # PROOT OWNER: each entry of the root is a student's own (named for the account that owns it, not a link) or the owner's
  local proot="$1" owner="$2" name info u ty shown n=0 bad=0
  while IFS= read -r -d '' name; do
    n=$((n + 1))
    shown=$(printf '%q' "$name")
    if ! info=$(stat -c '%U:%F' -- "$proot/$name" 2>/dev/null); then
      ga_fail "the root's entries: $shown cannot be read with stat"; bad=1; continue
    fi
    u=${info%%:*} ty=${info#*:}
    if [[ "$name" =~ $ID_RE ]]; then
      if [ "$ty" = "symbolic link" ]; then
        ga_fail "the root's entries: $shown is a link (to $(printf '%q' "$(readlink -- "$proot/$name" 2>/dev/null)")) owned by $u, where $name's own folder belongs (LAB_LEAD.md, section 9)"; bad=1
      elif [ "$u" != "$name" ]; then
        ga_fail "the root's entries: $shown ($ty) belongs to $u, not to $name, so it has taken the place of $name's own folder (LAB_LEAD.md, section 9)"; bad=1
      fi
    elif [ "$u" != "$owner" ]; then
      ga_fail "the root's entries: $shown ($ty) belongs to $u, not to $owner; only $owner's entries and students' own folders, each named for its owner, belong here (LAB_LEAD.md, section 9)"; bad=1
    fi
  done < <(find "$proot" -mindepth 1 -maxdepth 1 -printf '%f\0' 2>/dev/null)
  [ $bad = 1 ] || ga_ok "the root's entries: each of the $n is a student's own folder, named for its owner, or belongs to $owner"
}
ga_closed_under() { # LAB -> the entries under LAB other may not read (files) or enter (folders); deploy_shared's staging folders left out
  find "$1" -path "$1/hpcworker/.incoming-*" -prune -o \( -type d ! -perm -005 -print \) -o \( -type f ! -perm -004 -print \) 2>/dev/null
}
in_list() { case " $2 " in *" $1 "*) return 0;; esac; return 1; }   # ID " a b c "

apply() {
  local dry=0 open=0 sweep=0
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) dry=1; shift;; --open-tree) open=1; shift;; --check-tree) sweep=1; shift;; --) shift; break;;
    -*) die "unknown grid-side option $1; nothing changed";; *) break;; esac; done
  [ $open = 1 ] && sweep=1
  [ $# -ge 1 ] || die "no ROOT given; nothing changed"
  local root="$1"; shift
  case "$root" in /*) ;; *) die "ROOT must be absolute: $root; nothing changed";; esac
  local id
  for id in "$@"; do [[ "$id" =~ $ID_RE ]] || die "'$id' is not an AccessID (like ab1234); nothing changed"; done
  { command -v getfacl && command -v setfacl; } >/dev/null 2>&1 || die "no getfacl or setfacl on $(hostname -s); nothing changed"
  local proot me owner problems
  proot=$(readlink -f -- "$root" 2>/dev/null)
  [ -n "$proot" ] && [ -d "$proot" ] || die "$root is not a folder here; nothing changed"
  case "$proot" in *[][*?\\]*) die "$root resolves to $proot, whose name holds a pattern character (* ? [ ] \\); nothing changed";; esac
  me=$(id -un); owner=$(stat -c %U -- "$proot")
  [ "$owner" = "$me" ] || die "$root ($proot) belongs to $owner, not to $me: only its owner keeps the list. Nothing changed"
  problems=$(ga_gate "$proot")
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed "s#^#grid_access: $root: #" >&2
    die "the gate on $root does not hold, so no list on it would mean anything. Nothing changed"
  fi
  local sh="$proot/shared" lab="$proot/shared/beethoven" p
  if [ $open = 1 ]; then
    for p in "$sh" "$lab"; do
      { [ -d "$p" ] && [ ! -L "$p" ]; } || die "--open-tree: $p is not a plain folder (a link, or missing); nothing changed"
    done
  fi
  say "== $(hostname -s) as $me: grid access list on $root ($proot)$([ $dry = 1 ] && echo ', dry run')"

  # 2. the list
  local want wantsp cur name perm result="" skipsp=" " added=0 removed=0 changed=0 skipped=0 kept=0
  want=$(printf '%s\n' "$@" | sed '/^$/d' | sort -u)
  wantsp=" $(printf '%s' "$want" | tr '\n' ' ') "
  cur=$(ga_named "$proot")
  for id in $want; do
    if [ "$id" = "$owner" ]; then
      say "  owner   $id: owns $root; the owner's own entry covers it"
      # a named entry the owner already has is left as it is, and stays in the list read back
      printf '%s\n' "$cur" | awk -v n="$id" '$1 == n { f = 1 } END { exit !f }' && result="$result $id"
      continue
    fi
    if ! id -u "$id" >/dev/null 2>&1; then
      say "  skipped $id: no such account on this system yet (id $id failed)"
      skipped=$((skipped + 1)); skipsp="$skipsp$id "; continue
    fi
    result="$result $id"
    perm=$(printf '%s\n' "$cur" | awk -v n="$id" '$1 == n { print $2; exit }')
    if [ "$perm" = rwx ]; then kept=$((kept + 1)); continue; fi
    if [ $dry = 1 ]; then
      if [ -n "$perm" ]; then say "  would change $id: $perm -> rwx"; else say "  would add $id"; fi
      continue
    fi
    setfacl -n -m "u:$id:rwx" "$proot" || die "setfacl could not give $id rwx on $proot; the list is partly applied (run again)"
    if [ -n "$perm" ]; then say "  changed $id: $perm -> rwx"; changed=$((changed + 1)); else say "  added   $id"; added=$((added + 1)); fi
  done
  for name in $(printf '%s\n' "$cur" | awk 'NF { print $1 }'); do
    in_list "$name" "$wantsp" && continue
    perm=$(printf '%s\n' "$cur" | awk -v n="$name" '$1 == n { print $2; exit }')
    # getfacl prints a bare uid for an account the system cannot resolve just now (the same moment `id`
    # fails): that entry is a student's whose name is missing for a while, not one to remove. It is left
    # as it is and named, so that the lab lead removes it by hand if the account is really gone (LAB_LEAD.md 9)
    case "$name" in *[!0-9]*) ;; *) say "  left    $name: an entry whose account does not resolve now (a uid alone); remove it by hand if the account is really gone"; continue;; esac
    if [ $dry = 1 ]; then say "  would remove $name (now $perm)"; continue; fi
    setfacl -n -x "u:$name" "$proot" || die "setfacl could not remove $name from $proot; the list is partly applied (run again)"
    say "  removed $name (was $perm)"; removed=$((removed + 1))
  done
  if [ $dry = 1 ]; then say "  (dry run: nothing changed on $root)"
  else say "  $added added, $changed changed, $removed removed, $kept already there, $skipped skipped"; fi

  # 3. the tree below the gate (deploy_shared's staging folders, hpcworker/.incoming-*, left alone)
  local stage_re="$lab/hpcworker/.incoming-*"
  if [ $open = 1 ]; then
    local before n nd
    if [ $dry = 1 ]; then
      say "  would chmod o+rx $sh (now $(ga_mode "$sh"))"
      n=$(ga_closed_under "$lab" | wc -l | tr -d ' ')
      say "  would chmod o+rX everything under $lab ($n entries closed to other now)"
      nd=$(find "$lab" -path "$stage_re" -prune -o -type d -print 2>/dev/null | wc -l | tr -d ' ')
      say "  would setfacl -d -m o::r-x on the $nd folders under $lab"
    else
      before=$(ga_mode "$sh")
      chmod o+rx "$sh" || die "--open-tree: chmod o+rx $sh failed (the list is applied)"
      say "  open-tree: chmod o+rx $sh ($before -> $(ga_mode "$sh"))"
      # each entry named once, links left out (chmod would follow a link named to it), as chmod -R does
      n=$(find "$lab" -path "$stage_re" -prune -o ! -type l -exec chmod -c o+rX {} + | wc -l | tr -d ' ') \
        || die "--open-tree: chmod o+rX under $lab failed (the list is applied)"
      say "  open-tree: chmod o+rX under $lab ($n entries changed)"
      find "$lab" -path "$stage_re" -prune -o -type d -exec setfacl -d -m o::r-x {} + \
        || die "--open-tree: setfacl -d -m o::r-x under $lab failed (the list is applied)"
      nd=$(find "$lab" -path "$stage_re" -prune -o -type d -print | wc -l | tr -d ' ')
      say "  open-tree: default o::r-x on the $nd folders under $lab"
    fi
  fi

  # 4. what a student needs
  say "== checks"
  problems=$(ga_gate "$proot" "$owner")
  if [ -z "$problems" ]; then ga_ok "the gate: $root belongs to $owner, is sticky and closed to other ($(ga_mode "$proot"))"
  else ga_fail "the gate: $(printf '%s' "$problems" | tr '\n' ';')"; fi
  local mask names
  names=$(ga_named "$proot" | awk 'NF { print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')
  mask=$(ga_entry "$proot" mask)
  if [ -z "$names" ]; then ga_ok "the mask: no named entries on $root"
  elif [ "$mask" = rwx ]; then ga_ok "the mask: mask::rwx, so the list's entries take effect as rwx"
  else ga_fail "the mask: mask::${mask:-none} cuts the list's rwx, so students cannot make their own folder (fix: setfacl -m m::rwx $proot)"; fi
  if [ $dry = 0 ]; then
    local applied_list names_cmp="" kept_skipped=""
    applied_list=$(printf '%s\n' $result | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    # an id the grid did not know just now keeps the entry it may have: not the list applied, not wrong
    for name in $names; do
      if in_list "$name" "$skipsp"; then kept_skipped="$kept_skipped $name"; else names_cmp="$names_cmp $name"; fi
    done
    names_cmp=${names_cmp# }
    if [ "$names_cmp" = "$applied_list" ]; then
      ga_ok "the list read back from $root is the list applied${kept_skipped:+ (with the entry kept for$kept_skipped, unknown to the grid just now)}"
    else ga_fail "the list read back from $root ($names_cmp) is not the list applied ($applied_list)"; fi
  fi
  ga_entries "$proot" "$owner"
  ga_reach "shared" "$sh" "$proot"
  ga_reach "shared/beethoven" "$lab" "$proot"
  ga_reach "hpcworker" "$lab/hpcworker/current/bin/hpcworker" "$proot"
  ga_reach "the sandbox" "$lab/containers/claude-node22" "$proot"
  ga_reach "npm-claude-node22" "$lab/npm-claude-node22" "$proot"
  if [ $sweep = 0 ]; then
    say "  note    everything under shared/beethoven was not swept this run (--check-tree sweeps it)"
  elif [ -d "$lab" ]; then
    local closed nclosed
    closed=$(ga_closed_under "$lab")
    nclosed=$(printf '%s' "$closed" | grep -c .)
    if [ "$nclosed" = 0 ]; then ga_ok "everything under shared/beethoven is readable by other"
    else ga_fail "$nclosed entries under shared/beethoven are closed to other, like $(printf '%s\n' "$closed" | head -3 | sed "s#^$proot/##" | tr '\n' ' ')(fix: tools/grid_access.sh --open-tree)"; fi
  fi
  ga_closed "shared/access" "$sh/access"
  ga_closed "$owner (the owner's folder)" "$proot/$owner"

  if [ $dry = 1 ]; then
    say "grid access list on $root now: ${names:-(none)}"
    say "grid access list on $root after this run would be: $(printf '%s\n' $result | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
  else
    say "grid access list on $root: ${names:-(none)}"
  fi
  [ "$GA_FAILED" = 0 ] || return 2
  return 0
}

if [ "${1:-}" = --apply ]; then shift; apply "$@" < /dev/null; exit $?; fi

# ---- the lab lead's side ------------------------------------------------------------------------------
HERE=$(cd "$(dirname "$0")/.." && pwd) || die "cannot find the repository"
FW="$HERE/framework"
site=wayne host=wsu-grid root="" roster_file="" dry=0 force=0 quiet=0 open=0 check=0 local_run=0
while [ $# -gt 0 ]; do case "$1" in
  --site) site="${2:-}"; shift 2 || die "--site needs a value";;
  --host) host="${2:-}"; shift 2 || die "--host needs a value";;
  --root) root="${2:-}"; shift 2 || die "--root needs a value";;
  --roster-file) roster_file="${2:-}"; shift 2 || die "--roster-file needs a value";;
  --dry-run) dry=1; shift;; --force) force=1; shift;; --quiet) quiet=1; shift;;
  --open-tree) open=1; shift;; --check-tree) check=1; shift;; --here) local_run=1; shift;;
  -h|--help) awk 'NR > 1 && /^set -uo pipefail/ { exit } NR > 1' "$0"; exit 0;;
  *) die "unknown option $1 (--help)";; esac; done
[[ "$site" =~ ^[a-z0-9_-]+$ ]] || die "bad site name '$site'"
[[ "$host" =~ ^[A-Za-z0-9._@-]+$ ]] || die "bad host name '$host'"

vendor=${BEETHOVEN_VENDOR_DIR:-$HOME/.beethoven-vendor}
statedir="$vendor/state"
mkdir -p "$statedir" || die "cannot make $statedir"
statef="$statedir/grid_access.$site.ids"
logf="$statedir/grid_access.log"
target="-"
log() { printf '%s %s %s %s\n' "$(date -u +%FT%TZ)" "$site" "$target" "$*" >> "$logf" 2>/dev/null; }
refuse() { log "refused: $*"; die "$*"; }
note() { [ $quiet = 1 ] || say "note: $*"; }

# the root: given, or the parent of the account folder in the site profile's shared_state_dir, read
# with the framework's own awk reader ($USER and $HOME left unexpanded; never python)
prof="$FW/profiles/$site.json"
prof_get() { ( LIB="$FW/lib" PROFILES="$FW/profiles"; unset USER HOME; . "$FW/lib/profile_sh.sh" && hpcw_prof_awk get "$prof" "$1" ); }
from_profile=0
if [ -z "$root" ]; then
  [ -s "$prof" ] || refuse "no profile $prof; give --root DIR"
  ssd=$(prof_get shared_state_dir) || refuse "could not read shared_state_dir from $prof"
  case "$ssd" in
    */'$USER'|*/'$USER'/*) root=${ssd%%/\$USER*};;
    */'${USER}'|*/'${USER}'/*) root=${ssd%%/\$\{USER\}*};;
    *) refuse "shared_state_dir in $prof ($ssd) has no \$USER folder, so it names no root; give --root DIR";;
  esac
  from_profile=1
fi
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] || refuse "ROOT must be an absolute path of plain characters: $root"
root=${root%/}
if [ $local_run = 1 ]; then target="here:$root"; else target="$host:$root"; fi
if [ $from_profile = 1 ]; then
  # the grid side checks a fixed layout under the root; say so when the profile names another
  for pair in "shared_install=$root/shared/beethoven/hpcworker/current" "image_store.path=$root/shared/beethoven/containers/claude-node22" "claude_bin=$root/shared/beethoven/npm-claude-node22/bin/claude"; do
    k=${pair%%=*} v=${pair#*=}
    got=$(prof_get "$k")
    [ "$got" = "$v" ] || note "$prof names $k $got; the grid side checks $v"
  done
fi

# the approved list
if [ -n "$roster_file" ]; then
  src="the file $roster_file"
  [ -r "$roster_file" ] || refuse "cannot read $roster_file; nothing changed"
  raw=$(cat -- "$roster_file") || refuse "cannot read $roster_file; nothing changed"
elif [ -n "${BEETHOVEN_ROSTER_CMD:-}" ]; then
  src="\$BEETHOVEN_ROSTER_CMD"
  raw=$(bash -c "$BEETHOVEN_ROSTER_CMD" < /dev/null); rc=$?
  [ $rc = 0 ] || refuse "the roster command (\$BEETHOVEN_ROSTER_CMD) ended with exit $rc; nothing changed"
else
  [ $local_run = 0 ] || refuse "with --here give --roster-file FILE or \$BEETHOVEN_ROSTER_CMD (the grid's login node bans node); nothing changed"
  svc=${BEETHOVEN_SERVICE_DIR:-$(dirname "$HERE")/ashley}
  adm="$svc/tools/intake/admin.mjs"
  src="node $adm roster"
  [ -f "$adm" ] || refuse "no $adm (set BEETHOVEN_SERVICE_DIR, BEETHOVEN_ROSTER_CMD or --roster-file); nothing changed"
  command -v node >/dev/null 2>&1 || refuse "node is not on PATH, so $adm cannot run; nothing changed"
  raw=$(node "$adm" roster < /dev/null); rc=$?
  [ $rc = 0 ] || refuse "$src ended with exit $rc; nothing changed"
fi
# one id per line; CR, surrounding blanks, blank lines and # lines dropped; the first bad line refuses
numbered=$(printf '%s\n' "$raw" | awk '{ sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 == "" || substr($0, 1, 1) == "#") next; print NR ":" $0 }')
ids=""
oldifs=$IFS; IFS=$'\n'
for entry in $numbered; do
  val=${entry#*:}
  [[ "$val" =~ $ID_RE ]] || { IFS=$oldifs; refuse "line ${entry%%:*} of $src is not an AccessID (like ab1234): '$val'; nothing changed"; }
  ids="$ids$val"$'\n'
done
IFS=$oldifs
ids=$(printf '%s' "$ids" | sed '/^$/d' | sort -u)
count=$(printf '%s' "$ids" | grep -c .)
inline=$(printf '%s' "$ids" | tr '\n' ' ' | sed 's/ $//')
if [ "$count" = 0 ] && [ $force = 0 ]; then
  refuse "$src gave no AccessID; applying that would shut every student out of $root. Rerun with --force if that is meant; nothing changed"
fi

# unchanged since the last apply: no connection at all. An id the grid did not know at the last apply
# ("# unknown <id> <date>") does not make the list differ; it is due for another try on a later UTC date.
today=$(date -u +%F)
prev_target="" prev_ids="" prev_when="" prev_unknown=""
if [ -s "$statef" ]; then
  prev_target=$(sed -n 's/^# target //p' "$statef" | head -1)
  prev_when=$(sed -n 's/^# applied //p' "$statef" | head -1)
  prev_ids=$(grep -v '^#' "$statef" | sed '/^$/d' | sort -u)
  prev_unknown=$(sed -n 's/^# unknown \([a-z][a-z][0-9][0-9][0-9][0-9]\) \([0-9-]*\)$/\1 \2/p' "$statef" | sort -u)
fi
known="" due="" waiting=""
for id in $ids; do
  d=$(printf '%s\n' "$prev_unknown" | awk -v n="$id" '$1 == n { print $2; exit }')
  if [ -z "$d" ]; then known="$known$id"$'\n'; continue; fi
  waiting="$waiting $id"
  [[ "$d" < "$today" ]] && due="$due $id"
done
known=$(printf '%s' "$known" | sed '/^$/d' | sort -u)
known_inline=$(printf '%s' "$known" | tr '\n' ' ' | sed 's/ $//')
nwait=$(printf '%s\n' $waiting | grep -c .)
if [ $force = 0 ] && [ $open = 0 ] && [ $check = 0 ] && [ -s "$statef" ] && [ "$prev_target" = "$target" ] \
   && [ "$prev_ids" = "$known" ] && [ -z "$due" ]; then
  log "unchanged ($count ids, $nwait unknown to the grid); not connected"
  if [ $quiet = 0 ]; then
    say "unchanged since ${prev_when:-the last apply}: $count ids for $target; not connecting (--force to apply anyway)"
    [ -z "$waiting" ] || say "not on the grid yet, no account there when last tried today (tried again tomorrow, or now with --force):$waiting"
    say "grid access list on $root: ${known_inline:-(none)}"
  fi
  exit 0
fi

# the grid side
args="--apply"
[ $dry = 1 ] && args="$args --dry-run"
[ $open = 1 ] && args="$args --open-tree"
[ $check = 1 ] && args="$args --check-tree"
args="$args $root $inline"
[ $quiet = 1 ] || say "grid access: $count ids from $src -> $target$([ $dry = 1 ] && echo ', dry run')${due:+ (trying again:$due)}"
if [ $local_run = 1 ]; then
  # shellcheck disable=SC2086
  out=$(bash "$0" $args 2>&1); rc=$?
else
  # the script on stdin, the ids as arguments; the grid side's errors come back on stdout with its lines
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$host" "bash -s -- $args 2>&1" < "$0"); rc=$?
fi
# (grep without -q after these pipes: under pipefail, grep -q leaving early fails the printf with SIGPIPE)
CHANGE_RE='^  (added|changed|removed|skipped|would|open-tree)|^  FAILED'
if [ $quiet = 0 ]; then
  [ -z "$out" ] || printf '%s\n' "$out"
elif [ $rc != 0 ] && [ $rc != 2 ]; then
  [ -z "$out" ] || printf '%s\n' "$out" >&2
elif printf '%s\n' "$out" | grep -E "$CHANGE_RE" >/dev/null; then
  printf '%s\n' "$out" | grep -E "$CHANGE_RE|^grid access list on "
fi

if [ $rc != 0 ] && [ $rc != 2 ]; then
  why=$(printf '%s\n' "$out" | grep '^grid_access: ' | tail -1 | sed 's/^grid_access: //')
  [ $local_run = 0 ] && [ $rc = 255 ] && [ -z "$why" ] && why="ssh to $host failed"
  log "failed (exit $rc): ${why:-see the output}"
  die "the grid side ended with exit $rc${why:+: $why}; the state file is unchanged"
fi
if ! printf '%s\n' "$out" | grep '^grid access list on ' >/dev/null; then
  log "failed: the grid side ended without its list"
  die "the grid side ended without printing its list; the state file is unchanged"
fi
nadd=$(printf '%s\n' "$out" | grep -c -E '^  (added|would add) ')
nrem=$(printf '%s\n' "$out" | grep -c -E '^  (removed|would remove) ')
skipped=$(printf '%s\n' "$out" | sed -n 's/^  skipped \([a-z][a-z][0-9][0-9][0-9][0-9]\):.*/\1/p' | sort -u)
nskip=$(printf '%s' "$skipped" | grep -c .)
nfail=$(printf '%s\n' "$out" | grep -c '^  FAILED')
if [ $dry = 1 ]; then
  log "dry run ($count ids): would add $nadd, remove $nrem; $nskip unknown; $nfail checks failed"
  exit $rc
fi
# the state: the list as applied; each id the grid did not know on a dated line of its own instead
skipsp=" $(printf '%s' "$skipped" | tr '\n' ' ') "
applied=""
for id in $ids; do in_list "$id" "$skipsp" || applied="$applied$id"$'\n'; done
tmpf="$statef.new.$$"
{ say "# grid_access.sh: the list last applied. An approved id the grid did not know is on a line \"# unknown <id> <date>\" instead, tried again once a day (or with --force)"
  say "# target $target"
  say "# applied $(date -u +%FT%TZ)"
  for id in $skipped; do say "# unknown $id $today"; done
  printf '%s' "$applied"
} > "$tmpf" && mv -f "$tmpf" "$statef" || { rm -f "$tmpf"; log "applied, but the state file could not be written"; die "could not write $statef (the grid side did apply the list)"; }
log "applied $count ids (+$nadd -$nrem, $nskip unknown to the grid$([ "$nskip" != 0 ] && printf ': %s' "$(printf '%s' "$skipped" | tr '\n' ' ' | sed 's/ $//')"))$([ "$nfail" != 0 ] && echo "; $nfail checks FAILED")"
exit $rc
