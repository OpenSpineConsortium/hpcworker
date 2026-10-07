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
# Beside the list it keeps the readers: accounts the lab lead approved to read named folders under the
# root, as the lab's group reads them (the access service's reader list; LAB_LEAD.md, section 9). A
# reader gets user:<id>:--x on the root (or keeps rwx, if also on the list) and, under each of its
# folders, a named entry equal to the read and enter the root's group has on each entry there, never w,
# never a default entry; see "readers" below. The folder "." is the root itself, the whole volume: such a
# reader gets on the root the group's read there (r-x on drwxrws--T; rwx kept if on the list) and the
# group's read on every entry under it that the root's owner owns. Other students' own folders, and
# everything inside them, stay theirs (counted, never changed). A "." is that reader's only folder in the
# access service's list; another folder beside it is covered by it and has no sweep of its own.
#
#   tools/grid_access.sh [--site ID] [--host HOST] [--root DIR] [--service URL]
#                        [--roster-file FILE] [--readers-file FILE]
#                        [--dry-run] [--force] [--quiet] [--open-tree] [--check-tree]
#   tools/grid_access.sh --here --roster-file FILE --readers-file FILE [the same options]   on the cluster
#
# Both lists come from the access service, through its two plain-text answers and nothing else: GET
# /admin/roster.txt and GET /admin/readers.txt at --service URL (else $BEETHOVEN_SERVICE_URL, else the
# service's own name, https://beethoven-access.openspineconsortium.workers.dev; https and a host name of
# plain characters, nothing after it), with the maintainer's admin token, the one line of the vendor
# folder's admin_token. That file must be the owner's alone (mode 0600; a run that finds it readable by
# group or other refuses and says to chmod it). The token leaves it only for a header file of this run's
# own, mode 0600 in a temporary folder the run removes, which curl reads (-H @FILE): never an argument,
# never a line of the log, never a word of a message. Only an answer of 200 and text/plain is a list;
# anything else refuses with nothing changed and says what it was: the token not accepted (401, 403:
# check admin_token), the service not yet deployed with the lists (404), another answer, a page or
# another service in front (not text), or no answer at all (the message names the host). This tool runs
# no other repository's code and assumes no checkout beside it; a person's own list stands in for the
# service's: --roster-file FILE, else the command in $BEETHOVEN_ROSTER_CMD (run with bash -c, stdin
# closed), for the approved list, and --readers-file FILE, else $BEETHOVEN_READERS_CMD (`true` for no
# reader), for the readers. Each list is taken from the first of its three sources that is given.
#
# The approved AccessIDs: one AccessID per line (blank lines and lines starting with # are skipped). The
# service prints the accounts approved with the extension grant, and only those: not the store
# reviewers' mock account, and not an account approved for the lab only, which therefore never reaches
# the grid's folders. Each must look like ab1234 (^[a-z]{2}[0-9]{4}$) or the run refuses, naming the
# line, and nothing changes. An empty list is refused unless --force: it would shut every student out.
# A command that fails refuses.
#
# The readers: one "<id> <folder>" per line (blank and # lines skipped), the folder relative to the
# root, plain characters (letters, digits, . _ -) with no part starting with a dot or a dash, so no "..",
# no absolute path and nothing hidden; or exactly "." for the root itself (never "./x", "x/." or "/"). A
# bad line refuses, naming it. An empty reader list is fine (an empty answer, or a command that prints
# nothing, such as `true`, says there is no reader); a source that fails refuses (applying the list
# without the readers would take their traverse away).
#
# What it keeps, on the machine that runs it, under $BEETHOVEN_VENDOR_DIR (else $ASHLEY_VENDOR_DIR, else
# ~/.beethoven-vendor; the same folder admin_token is read from):
#   state/grid_access.<site>.ids  the list last applied and where; written only after the grid side
#                                 applied it. An approved id the grid does not know yet (no account) is
#                                 skipped there and recorded on a line "# unknown <id> <date>" instead
#                                 (UTC date of the try), not in the list. Each reader's folder on a line
#                                 "# read <id> <folder>", and "# swept <date>", the last sweep of them. A
#                                 folder taken off whose taking back did not finish (over the cap, or a
#                                 setfacl that failed) on a line "# unread <id> <folder>", until it does.
#   state/grid_access.log         one line per run
# When the target is the one last applied and the list, less the ids recorded as unknown, is the list
# last applied, it does not connect to the grid at all; an id recorded as unknown is tried again at most
# once a day (the first run on a later UTC date connects for it), or at once with --force. The readers'
# folders are swept when the reader list differs from the one last applied (a folder taken off is
# swept to take its entries back), on the first run of a UTC day while there is a reader or a folder
# not yet taken back (so that a file added since gets its entry, and a taking back that did not finish
# is tried again), and with --force or --check-tree. --force,
# --open-tree or --check-tree connects anyway. --dry-run connects when a run would, changes nothing on
# the grid and writes no state; `--dry-run --force` is the way to see the grid's entries as they are
# now. --quiet prints nothing unless the grid side changed something, skipped an id or a check failed
# (errors always go to stderr; the log has every run): for the scheduled task.
#
# The grid side (--apply [--dry-run] [--open-tree] [--check-tree] [--sweep-readers] [--read ID:FOLDER]...
# [--unread ID:FOLDER]... ROOT id...) runs over ssh (BatchMode) as `bash -s` with this script on stdin
# and the ids as arguments. It is file work only on the login node (stat, readlink, getfacl, setfacl,
# chmod, find, id, and sed, awk and xargs on their output): no scheduler call, no container, no python
# or node, no temp file (no here-documents or here-strings: bash writes those to a temp file). In order:
#   1. resolves ROOT's physical path, refuses unless this account owns it, and refuses unless it keeps
#      other::--- and the sticky bit (it prints the fix: chmod +t, chmod o-rwx). Nothing has changed yet;
#   2. adds user:<id>:rwx for each id, and user:<id>:--x for each reader not on the list (for a reader of
#      ".", the group's read on the root, within the mask and never w; skipping, with a line, an id `id`
#      does not know, and the owner), removes every named user entry that is neither,
#      and prints each addition and removal. A skipped
#      id's entry, if it has one, is left as it is. It runs setfacl with -n, so the mask is never
#      recalculated: the owner's user:: entry and the group, mask and other entries are never changed,
#      and no default entry is touched;
#   3. with --open-tree, does what was done by hand on 2026-10-02, idempotently, and only that:
#      chmod o+rx ROOT/shared; o+rX on everything under ROOT/shared/beethoven (links not followed);
#      setfacl -d -m o::r-x on each folder under ROOT/shared/beethoven. It never touches
#      ROOT/shared/access or ROOT/<owner>, nor deploy_shared's staging folders
#      (shared/beethoven/hpcworker/.incoming-*, closed while a publish runs, left behind by one that failed);
#  3b. with --sweep-readers, the readers' folders: first each --unread pair (a folder taken off) loses
#      every entry of that reader's without w under it, and then each --read pair is given the group's
#      read (getfacl -R read once, setfacl -n on what differs, each entry set read back with getfacl), and
#      the folders on the way get --x where the group may enter and other may not; last, a --x on the way
#      to a folder taken off goes unless a folder still read needs it. A folder missing, reached through a
#      link, owned by another, behind a folder the group may not enter, or holding more than $GA_READ_CAP
#      entries is a FAILED check and gets nothing; the cap decides what is done, not what is read: the
#      walk reads the whole folder to count it. A folder taken off and not taken back (over the cap, or a
#      setfacl that failed) says "<folder> not taken back:" in its FAILED line, which keeps it for the next
#      sweep. For "." the folder is the root: no folder on the way, the walk is the whole volume (one
#      getfacl -R over every entry for each reader of "." in a sweep, and one more for each "." taken off;
#      students' own folders included, which are counted and left), the same cap holds, and the root's own
#      entry is step 2's, never the sweep's (a "." taken off leaves it to step 2: --x while another folder
#      is read, gone otherwise). A folder taken off while the reader still has "." keeps its entries.
#      Without --sweep-readers, only the root's entry;
#   4. checks what a student needs and prints one line per check (ok or FAILED). Every run, cheap: the
#      gate still holds (owner, sticky, other::---) and the mask lets the entries' rwx through; the list
#      read back is the list applied (entries of skipped ids aside); the root's entries: each is named
#      for the account that owns it and is not a link (a student's own folder) or belongs to the root's
#      owner, so no one has taken the place of another student's folder before that student's first run;
#      shared and shared/beethoven open to other (read and enter); hpcworker/current/bin/hpcworker
#      readable and runnable by other, and every folder on the way enterable; the sandbox
#      (containers/claude-node22) and npm-claude-node22 likewise; shared/access and ROOT/<owner> closed
#      to other (no r, no x); each reader's folder read as the group reads it, when swept. Only with
#      --open-tree or --check-tree, the full sweep: nothing under
#      shared/beethoven closed to other (tens of thousands of entries; the staging folders left out).
#      A failed check does not undo the list.
# Its output ends with the readers, "readers on ROOT: id (folder, folder); id (all of ROOT)", when there
# are any ("." is shown as "all of ROOT"), and then the resulting list: "grid access list on ROOT: id id id".
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

# ---- readers: the group's read on approved folders, and nothing more ------------------------------------
# A reader (READ_RE: "<id>:<folder>", the folder relative to the root, plain characters, no part starting
# with a dot or a dash) gets traverse on the root and, on each entry under its folder that the root's owner
# owns, the read and enter the root's group has there: the owning group's entry when the entry belongs to
# that group, or a named entry for it, within the mask, never w. That is what the lab group's members may
# read, which is what such a request asks for (the group itself is C&IT's). Where other already has that
# much, no entry is needed; an entry this account does not own cannot be changed and is counted; a
# reader's entry with w is not one this tool made and is left as it is. No default entry is ever set: with
# a default ACL the creator's umask no longer applies, so a job's token written 0600 would come out
# readable; a new file gets its entry from the next sweep instead. Nothing inside a folder another account
# owns is given an entry either, even an entry this account owns: that account could put a link in its
# place between the walk and setfacl, and setfacl follows a link (counted with the others' entries).
# The folder "." (READ_RE's other branch) is the root itself: the walk is the whole volume.
READ_RE='^[a-z]{2}[0-9]{4}:(\.|[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*)$'
GA_READ_CAP=${GA_READ_CAP:-200000}    # entries under one folder (the whole volume for "."); more and the folder is not swept (FAILED)
# The awk below reads getfacl's records (-p: absolute names; a name holding a backslash or an unprintable
# character comes escaped and is left out; -R walks a folder before what it holds) and prints what the
# reader's entry should become, one line each: "set PERMS PATH", "del - PATH", "noenter - PATH", then
# "count N FOREIGN ESCAPED NOTOURS COVERED SET DEL KEPT". mode grant: the group's read; check: the same,
# counting what still differs; revoke: every entry of the reader's without w goes; anc: a folder on the
# way, made enterable where the group may enter; unanc: the --x such a folder was given goes; want: only
# "want PERMS PATH", the group's read there (step 2's, for the root). The root's own record (top) is
# counted and never acted on: its entry is step 2's. A grant leaves the reader's entry on its own status
# file of Beethoven for VS Code as it is (keep: shared/access/status/<id>.json, 0600 with u:<id>:r--,
# which those grid scripts give each applicant, again at each decision), counted as KEPT: taken as an
# entry beyond the group's read, the two tools would keep undoing each other. A revoke takes it.
GA_PLAN='
function rx(p) { return (substr(p, 1, 1) == "r" ? "r" : "-") "-" (substr(p, 3, 1) == "x" ? "x" : "-") }
function both(a, b,   i, s, c) { s = ""; for (i = 1; i <= 3; i++) { c = substr(a, i, 1); s = s ((c != "-" && c == substr(b, i, 1)) ? c : "-") }; return s }
function either(a, b,   i, s, c) { s = ""; for (i = 1; i <= 3; i++) { c = substr(a, i, 1); if (c == "-") c = substr(b, i, 1); s = s c }; return s }
function act(verb, perm) { if (n <= cap) print verb, perm, path }
function flush(   g, w, o, e, under) {
  if (path == "") return
  n++
  g = (fgroup == grp ? G : "---")
  if (NG != "") g = either(g, NG)
  w = rx(both(g, (M == "" ? "rwx" : M)))
  o = rx(O); e = E
  if (inside != "" && index(path, inside "/") != 1) inside = ""
  under = (inside != "")
  if (fowner != owner && !under) inside = path
  if (mode == "want") print "want", w, path
  else if (path == top) ;
  else if (index(path, "\\")) esc++
  else if (mode == "grant" || mode == "check") {
    if (under || fowner != owner) foreign++
    else if (substr(e, 2, 1) == "w") notours++
    else if (w == "---") { if (e != "") { if (path == keep) kept++; else { nd++; if (mode == "grant") act("del", "-") } } }
    else if (e == "" && both(w, o) == w) covered++
    else if (e != w) { ns++; if (mode == "grant") act("set", w) }
  } else if (mode == "revoke") {
    if (fowner == owner && e != "" && substr(e, 2, 1) != "w") { nd++; act("del", "-") }
  } else if (mode == "anc") {
    if (substr(e, 3, 1) == "x" || (e == "" && substr(o, 3, 1) == "x")) covered++
    else if (fowner != owner || substr(e, 2, 1) == "w" || substr(w, 3, 1) != "x") print "noenter", "-", path
    else { ns++; act("set", either((e == "" ? "---" : e), "--x")) }
  } else if (mode == "unanc") {
    if (fowner == owner && e == "--x") { nd++; act("del", "-") }
  }
  path = ""; fowner = ""; fgroup = ""; G = ""; M = ""; NG = ""; E = ""; O = ""
}
/^# file: / { flush(); path = substr($0, 9); next }
/^# owner: / { fowner = substr($0, 10); next }
/^# group: / { fgroup = substr($0, 10); next }
/^#/ || /^default:/ { next }
/^$/ { flush(); next }
{
  split($0, f, "\t"); t = f[1]; p = substr(t, length(t) - 2); t = substr(t, 1, length(t) - 4)
  if (t == "group:") G = p; else if (t == "mask:") M = p; else if (t == "other:") O = p
  else if (t == "group:" grp) NG = p; else if (t == "user:" id) E = p
}
END { flush(); print "count", n + 0, foreign + 0, esc + 0, notours + 0, covered + 0, ns + 0, nd + 0, kept + 0 }'
ga_plan() { # MODE ID: GA_PLAN over getfacl's records on stdin
  awk -v mode="$1" -v id="$2" -v owner="$GA_OWNER" -v grp="$GA_GROUP" -v cap="$GA_READ_CAP" -v top="$GA_TOP" \
    -v keep="$GA_TOP/shared/access/status/$2.json" "$GA_PLAN"
}
ga_readplan() { # MODE ID PATH [-R]
  # shellcheck disable=SC2086
  getfacl ${4:-} -P -p -- "$3" 2>/dev/null | ga_plan "$1" "$2"
}
ga_readback() { # MODE ID PLAN -> the count line for the plan's paths read again: one getfacl of what was set
  # or removed, not a second walk (on "." that would be the whole volume again)
  printf '%s\n' "$3" | sed -n 's/^set [-rwx][-rwx][-rwx] //p; s/^del - //p' | xargs -r -d '\n' getfacl -P -p -- 2>/dev/null \
    | ga_plan "$1" "$2" | sed -n 's/^count //p'
}
ga_rpath() { if [ "$2" = . ]; then printf '%s' "$1"; else printf '%s/%s' "$1" "$2"; fi; }   # PROOT REL -> the folder's path
ga_folder() { if [ "$1" = . ]; then printf 'all of %s' "$GA_NAME"; else printf '%s' "$1"; fi; }   # REL, in words
ga_readapply() { # ID PLAN: setfacl for the plan's lines, the paths grouped by what they get; fails when any setfacl did
  local perm bad=0
  for perm in r-x r-- --x; do
    printf '%s\n' "$2" | sed -n "s/^set $perm //p" | xargs -r -d '\n' setfacl -n -m "u:$1:$perm" || bad=1
  done
  printf '%s\n' "$2" | sed -n 's/^del - //p' | xargs -r -d '\n' setfacl -n -x "u:$1" || bad=1
  return $bad
}
ga_ancestors() { # REL -> each folder on the way below the root, one per line ("a" and "a/b" for "a/b/c")
  local rel=$1 acc=""
  while [ "${rel#*/}" != "$rel" ]; do acc=${acc:+$acc/}${rel%%/*}; rel=${rel#*/}; printf '%s\n' "$acc"; done
}
GA_READ_CHECKS=""
ga_counts() { n=${1:-0} foreign=${2:-0} esc=${3:-0} notours=${4:-0} covered=${5:-0} ns=${6:-0} nd=${7:-0} kept=${8:-0}; }   # a plan's count line, into the caller's locals
ga_read_check() { GA_READ_CHECKS="$GA_READ_CHECKS$1"$'\n'; }   # "ok TEXT" or "FAILED TEXT", printed with the checks
ga_readers() { # PROOT: the revocations, then the grants, then the folders on the way no grant still needs
  local proot=$1 pair id rel p f n foreign esc notours covered ns nd kept plan cnt anc a an extra total bad again
  # a pair whose taking back did not finish says "<f> not taken back:" in its FAILED line, the one form the
  # lab lead's side looks for to keep that pair and pass it again (a dropped pair would never be retried)
  again="tried again on the first run of a later day, or now with --force"
  for pair in $unreads; do
    id=${pair%%:*} rel=${pair#*:}; p=$(ga_rpath "$proot" "$rel"); f=$(ga_folder "$rel")
    if ! id -u "$id" >/dev/null 2>&1; then say "  left    $id $f: no such account now; any entry it has stays (a uid alone)"; continue; fi
    # under "." the folder's entries are the group's read already; taking them back would only cut the
    # reader off until the grant below gave them again
    if [ "$rel" != . ] && in_list "$id:." "$reads"; then say "  note    $id $f: still read with all of $GA_NAME, nothing taken back"; continue; fi
    if [ ! -d "$p" ] || [ -L "$p" ] || [ "$(readlink -f -- "$p")" != "$p" ]; then say "  note    $id $f: no such folder now, nothing to take back"; continue; fi
    plan=$(ga_readplan revoke "$id" "$p" -R); cnt=$(printf '%s\n' "$plan" | sed -n 's/^count //p')
    ga_counts $cnt
    [ "$nd" != 0 ] || continue
    if [ "$n" -gt "$GA_READ_CAP" ]; then
      ga_read_check "FAILED reader $id: $f not taken back: it holds $n entries, more than $GA_READ_CAP ($again; by hand, on the login node: find $p$([ "$rel" != . ] || printf ' -mindepth 1') -user $GA_OWNER ! -type l -exec setfacl -n -x u:$id {} +)"; continue
    fi
    if [ $dry = 1 ]; then say "  would revoke $id $f: $nd entries"; continue; fi
    if ga_readapply "$id" "$plan"; then say "  revoked $id $f: $nd entries removed"
    else ga_read_check "FAILED reader $id: $f not taken back: setfacl failed on part of it ($again)"; fi
  done
  for pair in $reads; do
    id=${pair%%:*} rel=${pair#*:}; p=$(ga_rpath "$proot" "$rel"); f=$(ga_folder "$rel")
    in_list "$id" "$skipsp" && continue
    if [ "$rel" != . ] && in_list "$id:." "$reads"; then ga_read_check "note reader $id: $rel is part of all of $GA_NAME, so it has no sweep of its own"; continue; fi
    if [ ! -d "$p" ] || [ -L "$p" ] || [ "$(readlink -f -- "$p")" != "$p" ]; then
      ga_read_check "FAILED reader $id: $rel is not a plain folder under the root (missing, or a link on the way)"; continue
    fi
    a=$(stat -c %U -- "$p" 2>/dev/null)
    if [ "$a" != "$GA_OWNER" ]; then ga_read_check "FAILED reader $id: $rel belongs to $a, not to $GA_OWNER, so only $a may let others read it"; continue; fi
    anc="" an=0
    for a in $(ga_ancestors "$rel"); do anc="$anc$(ga_readplan anc "$id" "$proot/$a")"$'\n'; done
    if printf '%s\n' "$anc" | grep '^noenter ' >/dev/null; then
      ga_read_check "FAILED reader $id: the group may not enter $(printf '%s\n' "$anc" | sed -n "s#^noenter - $proot/##p" | head -1), on the way to $rel, so neither may a reader; nothing given there"; continue
    fi
    an=$(printf '%s\n' "$anc" | grep -c '^set ')
    plan=$(ga_readplan grant "$id" "$p" -R); cnt=$(printf '%s\n' "$plan" | sed -n 's/^count //p')
    ga_counts $cnt
    if [ "$n" -gt "$GA_READ_CAP" ]; then ga_read_check "FAILED reader $id: $f holds $n entries, more than $GA_READ_CAP; not swept"; continue; fi
    extra=""
    [ "$covered" = 0 ] || extra="$extra; $covered open to other already"
    [ "$foreign" = 0 ] || extra="$extra; $foreign not $GA_OWNER's, left as they are"
    [ "$notours" = 0 ] || extra="$extra; $notours where $id has w, not this tool's, left as they are"
    [ "$esc" = 0 ] || extra="$extra; $esc whose names getfacl escapes (a backslash or an unprintable character) left out"
    [ "$kept" = 0 ] || extra="$extra; $id's own status file of Beethoven for VS Code left as it is"
    if [ $((ns + nd + an)) = 0 ]; then
      ga_read_check "ok reader $id: $f reads as the group reads it ($n entries$extra)"; continue
    fi
    if [ $dry = 1 ]; then
      say "  would grant $id $f: $ns entries set to the group's read, $nd removed where the group may not read, $an folders on the way made enterable"
      ga_read_check "ok reader $id: $f would read as the group reads it after this run ($n entries$extra)"; continue
    fi
    if ! ga_readapply "$id" "$anc$plan"; then ga_read_check "FAILED reader $id: setfacl failed on part of $f ($again)"; continue; fi
    say "  granted $id $f: $ns entries set to the group's read, $nd removed where the group may not read, $an folders on the way made enterable"
    total=$n
    cnt=$(ga_readback check "$id" "$plan"); ga_counts $cnt; bad=$((ns + nd))
    cnt=$(ga_readback anc "$id" "$anc"); ga_counts $cnt; bad=$((bad + ns))
    if [ $bad = 0 ]; then ga_read_check "ok reader $id: $f reads as the group reads it ($total entries, read back$extra)"
    else ga_read_check "FAILED reader $id: $bad entries under $f still differ from the group's read after setfacl"; fi
  done
  for pair in $unreads; do
    id=${pair%%:*} rel=${pair#*:}
    id -u "$id" >/dev/null 2>&1 || continue
    for a in $(ga_ancestors "$rel"); do
      ga_still_needed "$id" "$a" && continue
      plan=$(ga_readplan unanc "$id" "$proot/$a")
      printf '%s\n' "$plan" | grep '^del ' >/dev/null || continue
      if [ $dry = 1 ]; then say "  would revoke $id $a: its --x (on the way to $rel)"; continue; fi
      if ga_readapply "$id" "$plan"; then say "  revoked $id $a: its --x (on the way to $rel)"
      else ga_read_check "FAILED reader $id: $rel not taken back: setfacl failed taking back the --x on $a ($again)"; fi
    done
  done
}
ga_still_needed() { # ID REL: a folder the reader still reads, or one on the way to such a folder ("." covers every one)
  local pair f
  for pair in $reads; do
    [ "${pair%%:*}" = "$1" ] || continue
    f=${pair#*:}
    [ "$f" != . ] || return 0
    case "$f/" in "$2/"*) return 0;; esac
    case "$2/" in "$f/"*) return 0;; esac
  done
  return 1
}

apply() {
  local dry=0 open=0 sweep=0 sweep_r=0 reads="" unreads="" pair
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) dry=1; shift;; --open-tree) open=1; shift;; --check-tree) sweep=1; shift;; --) shift; break;;
    --sweep-readers) sweep_r=1; shift;;
    --read|--unread)
      pair=${2:-}
      { [[ "$pair" =~ $READ_RE ]] && [ ${#pair} -le 207 ]; } || die "$1 '$pair' is not an AccessID and a folder under the root (like ab1234:shared/data, or ab1234:. for the root itself); nothing changed"
      if [ "$1" = --read ]; then reads="$reads $pair"; else unreads="$unreads $pair"; fi
      shift 2;;
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
  GA_OWNER=$owner GA_GROUP=$(stat -c %G -- "$proot") GA_TOP=$proot GA_NAME=$root
  say "== $(hostname -s) as $me: grid access list on $root ($proot)$([ $dry = 1 ] && echo ', dry run')"

  # 2. the list, and the readers' way in: rwx for each id on the list, --x for a reader not on it, and for a
  # reader of "." the group's read on the root as the sweep would give it (within the mask, never w), with
  # enter always, as every reader has it. The sweep never acts on the root, so the two never undo each other
  local want wantsp cur name perm wp rids rall allp=--x result="" resperm="" skipsp=" " added=0 removed=0 changed=0 skipped=0 kept=0
  want=$(printf '%s\n' "$@" | sed '/^$/d' | sort -u)
  wantsp=" $(printf '%s' "$want" | tr '\n' ' ') "
  rids=$(for pair in $reads; do printf '%s\n' "${pair%%:*}"; done | sort -u)
  rall=" $(for pair in $reads; do [ "${pair#*:}" != . ] || printf '%s ' "${pair%%:*}"; done)"
  if [ "$rall" != " " ]; then
    case "$(ga_readplan want - "$proot" | sed -n 's/^want \([-rwx]\)[-rwx][-rwx] .*/\1/p')" in r) allp=r-x;; esac
  fi
  cur=$(ga_named "$proot")
  for id in $(printf '%s\n' $want $rids | sed '/^$/d' | sort -u); do
    wp=rwx; in_list "$id" "$wantsp" || { wp=--x; in_list "$id" "$rall" && wp=$allp; }
    if [ "$id" = "$owner" ]; then
      say "  owner   $id: owns $root; the owner's own entry covers it"
      # a named entry the owner already has is left as it is, and stays in the list read back
      perm=$(printf '%s\n' "$cur" | awk -v n="$id" '$1 == n { print $2; exit }')
      [ -z "$perm" ] || { result="$result $id"; resperm="$resperm $id:$perm"; }
      continue
    fi
    if ! id -u "$id" >/dev/null 2>&1; then
      say "  skipped $id: no such account on this system yet (id $id failed)"
      skipped=$((skipped + 1)); skipsp="$skipsp$id "; continue
    fi
    result="$result $id"; resperm="$resperm $id:$wp"
    perm=$(printf '%s\n' "$cur" | awk -v n="$id" '$1 == n { print $2; exit }')
    if [ "$perm" = "$wp" ]; then kept=$((kept + 1)); continue; fi
    if [ $dry = 1 ]; then
      if [ -n "$perm" ]; then say "  would change $id: $perm -> $wp"; else say "  would add $id$([ $wp = rwx ] || echo " ($wp, a reader)")"; fi
      continue
    fi
    setfacl -n -m "u:$id:$wp" "$proot" || die "setfacl could not give $id $wp on $proot; the list is partly applied (run again)"
    if [ -n "$perm" ]; then say "  changed $id: $perm -> $wp"; changed=$((changed + 1))
    else say "  added   $id$([ $wp = rwx ] || echo " ($wp, a reader)")"; added=$((added + 1)); fi
  done
  for name in $(printf '%s\n' "$cur" | awk 'NF { print $1 }'); do
    in_list "$name" "$wantsp" && continue
    in_list "$name" " $(printf '%s' "$rids" | tr '\n' ' ') " && continue
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

  # 3b. the readers' folders: swept when the lab lead's side asks (a changed reader list, or once a day)
  if [ -n "$reads$unreads" ]; then
    if [ $sweep_r = 1 ]; then ga_readers "$proot"
    else ga_read_check "note the readers' folders were not swept this run (a changed reader list, the first run of a day or --force sweeps them)"; fi
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
    applied_list=$(printf '%s\n' $resperm | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
    # an id the grid did not know just now keeps the entry it may have: not the list applied, not wrong
    for name in $(ga_named "$proot" | awk 'NF { print $1 ":" $2 }' | sort); do
      if in_list "${name%%:*}" "$skipsp"; then kept_skipped="$kept_skipped ${name%%:*}"; else names_cmp="$names_cmp $name"; fi
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
  local line
  while IFS= read -r line; do case "$line" in
    ok\ *) ga_ok "${line#ok }";; FAILED\ *) ga_fail "${line#FAILED }";; note\ *) say "  note    ${line#note }";;
  esac; done < <(printf '%s' "$GA_READ_CHECKS")

  # the list is the rwx entries; the readers, each with its folders, on a line of their own before it
  local rwx_names readers_line=""
  rwx_names=$(ga_named "$proot" | awk '$2 == "rwx" { print $1 }' | sort | tr '\n' ' ' | sed 's/ $//')
  for id in $rids; do
    in_list "$id" "$skipsp" && continue
    readers_line="$readers_line; $id ($(for pair in $reads; do [ "${pair%%:*}" = "$id" ] && printf '%s, ' "$(ga_folder "${pair#*:}")"; done | sed 's/, $//'))"
  done
  [ -z "$readers_line" ] || say "readers on $root: ${readers_line#; }"
  if [ $dry = 1 ]; then
    say "grid access list on $root now: ${names:-(none)}"
    say "grid access list on $root after this run would be: $(printf '%s\n' $resperm | sed -n 's/:rwx$//p' | sort | tr '\n' ' ' | sed 's/ $//')"
  else
    say "grid access list on $root: ${rwx_names:-(none)}"
  fi
  [ "$GA_FAILED" = 0 ] || return 2
  return 0
}

if [ "${1:-}" = --apply ]; then shift; apply "$@" < /dev/null; exit $?; fi

# ---- the lab lead's side ------------------------------------------------------------------------------
HERE=$(cd "$(dirname "$0")/.." && pwd) || die "cannot find the repository"
FW="$HERE/framework"
site=wayne host=wsu-grid root="" roster_file="" dry=0 force=0 quiet=0 open=0 check=0 local_run=0
readers_file="" service=""
while [ $# -gt 0 ]; do case "$1" in
  --site) site="${2:-}"; shift 2 || die "--site needs a value";;
  --host) host="${2:-}"; shift 2 || die "--host needs a value";;
  --root) root="${2:-}"; shift 2 || die "--root needs a value";;
  --service) service="${2:-}"; shift 2 || die "--service needs a value";;
  --roster-file) roster_file="${2:-}"; shift 2 || die "--roster-file needs a value";;
  --readers-file) readers_file="${2:-}"; shift 2 || die "--readers-file needs a value";;
  --dry-run) dry=1; shift;; --force) force=1; shift;; --quiet) quiet=1; shift;;
  --open-tree) open=1; shift;; --check-tree) check=1; shift;; --here) local_run=1; shift;;
  -h|--help) awk 'NR > 1 && /^set -uo pipefail/ { exit } NR > 1' "$0"; exit 0;;
  *) die "unknown option $1 (--help)";; esac; done
[[ "$site" =~ ^[a-z0-9_-]+$ ]] || die "bad site name '$site'"
[[ "$host" =~ ^[A-Za-z0-9._@-]+$ ]] || die "bad host name '$host'"

vendor=${BEETHOVEN_VENDOR_DIR:-${ASHLEY_VENDOR_DIR:-$HOME/.beethoven-vendor}}
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

# the access service, the source of both lists unless a file or a command stands in for it (LAB_LEAD.md,
# section 9). The token stays in the vendor folder's admin_token and in a header file of this run's own
# that curl reads, so that no argument, log line or message ever carries it (a process's arguments are
# visible to every account on the machine). An answer that is not 200 plain text is never a list: a list
# taken from a 404 (the service not deployed yet), a 401 or 403 (another token) or a page in front would
# take students' entries away, so each refuses in its own words and nothing changes.
service=${service:-${BEETHOVEN_SERVICE_URL:-https://beethoven-access.openspineconsortium.workers.dev}}
[[ "$service" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]] \
  || refuse "the access service's address must be https:// and a host name of plain characters, with nothing after it: '$service'; nothing changed"
service=${service%/}
svc_name="the access service (${service#https://})"
tmpd="" svc_hdr="" svc_body=""
trap '[ -z "$tmpd" ] || rm -rf "$tmpd"' EXIT
svc_token() { # the header file, made once from admin_token's first line (CR and blanks dropped), 0600 in a folder of this run's
  [ -z "$svc_hdr" ] || return 0
  local tokf="$vendor/admin_token" mode
  [ -e "$tokf" ] || refuse "no admin_token in the vendor folder ($vendor): the access service's token is the maintainer's, one line in that file; nothing changed"
  [ -r "$tokf" ] || refuse "cannot read $tokf; nothing changed"
  mode=$(stat -c %a -- "$tokf" 2>/dev/null)
  case "$mode" in *00) ;; *) refuse "$tokf is readable by group or other (mode ${mode:-unknown}); make it yours alone first: chmod 600 $tokf; nothing changed";; esac
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/grid_access.XXXXXX") || refuse "cannot make a temporary folder under ${TMPDIR:-/tmp}; nothing changed"
  svc_hdr="$tmpd/header"
  ( umask 077; awk 'NR == 1 { sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 == "") exit 1; print "Authorization: Bearer " $0; ok = 1; exit } END { exit !ok }' "$tokf" > "$svc_hdr" ) \
    || { svc_hdr=""; refuse "$tokf is empty: the access service's token is one line in it; nothing changed"; }
}
svc_fetch() { # WHAT ROUTE: the answer's body into the file $svc_body, or a refusal; nothing but 200 plain text passes
  local what=$1 route=$2 meta n try status ctype err
  svc_token
  svc_body="$tmpd/${route##*/}"
  # curl's own --retry would try again on a 408, 429 or 5xx answer too; this loop tries again, twice at
  # most and a second apart, only when nothing answered: no such host (6), no connection (7), no answer in
  # time (28). An answer, whatever it says, is final
  for try in 1 2 3; do
    meta=$(curl -sS --max-time 60 -H "@$svc_hdr" -o "$svc_body" -w '%{http_code} %{content_type}' "$service$route" 2>"$tmpd/err"); n=$?
    case "$n" in 6|7|28) [ $try = 3 ] || { sleep 1; continue; };; esac
    break
  done
  if [ $n != 0 ]; then
    err=$(tr -d '\r' < "$tmpd/err" | grep . | tail -1)   # curl's own words: the host and the port, never the header
    refuse "$svc_name could not be reached for $what (${err:-curl ended with exit $n}); nothing changed"
  fi
  status=${meta%% *} ctype=${meta#* }
  case "$status" in
    200) case "$ctype" in text/plain*) return 0;; esac
         refuse "$svc_name answered $what as ${ctype:-no content type}, not as text: a sign-in page or another service stands in front of it; nothing changed";;
    401|403) refuse "$svc_name did not accept the token for $what (HTTP $status): check admin_token in the vendor folder ($vendor); nothing changed";;
    404) refuse "$svc_name does not give $what yet (HTTP 404): deploy the service; nothing changed";;
    *) refuse "$svc_name answered HTTP $status for $what; nothing changed";;
  esac
}

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
  src=$svc_name
  svc_fetch "the approved list" /admin/roster.txt
  raw=$(cat -- "$svc_body") || refuse "cannot read the approved list saved from $svc_name; nothing changed"
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

# the readers: "<id> <folder>" lines, the folder relative to the root. An empty list is fine (no reader);
# a source that fails refuses, since applying the list without the readers would take their traverse away
if [ -n "$readers_file" ]; then
  rsrc="the file $readers_file"
  [ -r "$readers_file" ] || refuse "cannot read $readers_file; nothing changed"
  rraw=$(cat -- "$readers_file") || refuse "cannot read $readers_file; nothing changed"
elif [ -n "${BEETHOVEN_READERS_CMD:-}" ]; then
  rsrc="\$BEETHOVEN_READERS_CMD"
  rraw=$(bash -c "$BEETHOVEN_READERS_CMD" < /dev/null); rc=$?
  [ $rc = 0 ] || refuse "the readers command (\$BEETHOVEN_READERS_CMD) ended with exit $rc; nothing changed"
else
  rsrc=$svc_name
  svc_fetch "the reader list" /admin/readers.txt
  rraw=$(cat -- "$svc_body") || refuse "cannot read the reader list saved from $svc_name; nothing changed"
fi
numbered=$(printf '%s\n' "$rraw" | awk '{ sub(/\r$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); gsub(/[ \t]+/, " "); if ($0 == "" || substr($0, 1, 1) == "#") next; print NR ":" $0 }')
pairs=""
oldifs=$IFS; IFS=$'\n'
for entry in $numbered; do
  val=${entry#*:}
  case "$val" in *" "*" "*|*:*) val="bad";; *" "*) val="${val%% *}:${val#* }";; *) val="bad";; esac
  { [[ "$val" =~ $READ_RE ]] && [ ${#val} -le 207 ]; } || { IFS=$oldifs; refuse "line ${entry%%:*} of $rsrc is not an AccessID and a folder under the root (like ab1234 shared/data, or ab1234 . for the root itself): '${entry#*:}'; nothing changed"; }
  pairs="$pairs$val"$'\n'
done
IFS=$oldifs
pairs=$(printf '%s' "$pairs" | sed '/^$/d' | sort -u)
rids=$(printf '%s\n' $pairs | sed 's/:.*//' | sed '/^$/d' | sort -u)
nreaders=$(printf '%s' "$rids" | grep -c .)

# unchanged since the last apply: no connection at all. An id the grid did not know at the last apply
# ("# unknown <id> <date>") does not make the list differ; it is due for another try on a later UTC date.
# The readers' folders are swept (each entry under them read and, where needed, set) when the reader list
# differs from the one last applied, on the first run of a UTC day while there is a reader (so that what
# was added to a folder since is given the group's read too), and with --force or --check-tree. A folder
# taken off whose taking back did not finish ("# unread <id> <folder>") is passed again at each of those
# sweeps until it does, and is itself a reason for the day's sweep.
today=$(date -u +%F)
prev_target="" prev_ids="" prev_when="" prev_unknown="" prev_pairs="" prev_unread="" prev_swept=""
if [ -s "$statef" ]; then
  prev_target=$(sed -n 's/^# target //p' "$statef" | head -1)
  prev_when=$(sed -n 's/^# applied //p' "$statef" | head -1)
  prev_ids=$(grep -v '^#' "$statef" | sed '/^$/d' | sort -u)
  prev_unknown=$(sed -n 's/^# unknown \([a-z][a-z][0-9][0-9][0-9][0-9]\) \([0-9-]*\)$/\1 \2/p' "$statef" | sort -u)
  prev_pairs=$(sed -n 's/^# read \([a-z][a-z][0-9][0-9][0-9][0-9]\) \([^ ][^ ]*\)$/\1:\2/p' "$statef" | sort -u)
  prev_unread=$(sed -n 's/^# unread \([a-z][a-z][0-9][0-9][0-9][0-9]\) \([^ ][^ ]*\)$/\1:\2/p' "$statef" | sort -u)
  prev_swept=$(sed -n 's/^# swept //p' "$statef" | head -1)
fi
known="" due="" waiting=""
for id in $(printf '%s\n' $ids $rids | sed '/^$/d' | sort -u); do
  d=$(printf '%s\n' "$prev_unknown" | awk -v n="$id" '$1 == n { print $2; exit }')
  if [ -z "$d" ]; then in_list "$id" " $(printf '%s' "$ids" | tr '\n' ' ') " && known="$known$id"$'\n'; continue; fi
  waiting="$waiting $id"
  [[ "$d" < "$today" ]] && due="$due $id"
done
known=$(printf '%s' "$known" | sed '/^$/d' | sort -u)
known_inline=$(printf '%s' "$known" | tr '\n' ' ' | sed 's/ $//')
nwait=$(printf '%s\n' $waiting | grep -c .)
known_pairs=$(for pair in $pairs; do in_list "${pair%%:*}" "$waiting" || printf '%s\n' "$pair"; done)
pairs_sp=" $(printf '%s' "$pairs" | tr '\n' ' ') "
unreads=$(for pair in $prev_pairs $prev_unread; do in_list "$pair" "$pairs_sp" || printf '%s\n' "$pair"; done | sort -u)
pending=$(for pair in $prev_unread; do in_list "$pair" "$pairs_sp" || printf '%s\n' "$pair"; done)
sweep_r=0
if [ -n "$pairs$prev_pairs$pending" ] && { [ "$prev_pairs" != "$known_pairs" ] || [ $force = 1 ] || [ $check = 1 ] \
   || { [ -n "$known_pairs$pending" ] && [[ "$prev_swept" < "$today" ]]; }; }; then sweep_r=1; fi
in_words() { printf '%s\n' "$@" | sed "s#^\([a-z0-9]*\):\.\$#\1 (all of $root)#" | tr '\n' ' ' | sed 's/ $//'; }   # PAIR... -> "id (all of ROOT) id:folder"
if [ $force = 0 ] && [ $open = 0 ] && [ $check = 0 ] && [ -s "$statef" ] && [ "$prev_target" = "$target" ] \
   && [ "$prev_ids" = "$known" ] && [ -z "$due" ] && [ $sweep_r = 0 ]; then
  log "unchanged ($count ids, $nreaders readers, $nwait unknown to the grid$([ -z "$pending" ] || printf '; %s folders not taken back yet' "$(printf '%s\n' $pending | grep -c .)")); not connected"
  if [ $quiet = 0 ]; then
    say "unchanged since ${prev_when:-the last apply}: $count ids and $nreaders readers for $target, the readers' folders swept $prev_swept; not connecting (--force to apply anyway)"
    [ -z "$waiting" ] || say "not on the grid yet, no account there when last tried today (tried again tomorrow, or now with --force):$waiting"
    [ -z "$pending" ] || say "not taken back yet, tried again on the first run of a later day (or now with --force): $(in_words $pending)"
    [ -z "$known_pairs" ] || say "readers on $root: $(in_words $known_pairs)"
    say "grid access list on $root: ${known_inline:-(none)}"
  fi
  exit 0
fi

# the grid side
args="--apply"
[ $dry = 1 ] && args="$args --dry-run"
[ $open = 1 ] && args="$args --open-tree"
[ $check = 1 ] && args="$args --check-tree"
[ $sweep_r = 1 ] && args="$args --sweep-readers"
for pair in $pairs; do args="$args --read $pair"; done
[ $sweep_r = 0 ] || for pair in $unreads; do args="$args --unread $pair"; done
args="$args $root $inline"
[ $quiet = 1 ] || say "grid access: $count ids from $src and $nreaders readers from $rsrc -> $target$([ $dry = 1 ] && echo ', dry run')${due:+ (trying again:$due)}"
if [ $local_run = 1 ]; then
  # shellcheck disable=SC2086
  out=$(bash "$0" $args 2>&1); rc=$?
else
  # the script on stdin, the ids as arguments; the grid side's errors come back on stdout with its lines
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=20 "$host" "bash -s -- $args 2>&1" < "$0"); rc=$?
fi
# (grep without -q after these pipes: under pipefail, grep -q leaving early fails the printf with SIGPIPE)
CHANGE_RE='^  (added|changed|removed|skipped|would|open-tree|granted|revoked)|^  FAILED'
if [ $quiet = 0 ]; then
  [ -z "$out" ] || printf '%s\n' "$out"
elif [ $rc != 0 ] && [ $rc != 2 ]; then
  [ -z "$out" ] || printf '%s\n' "$out" >&2
elif printf '%s\n' "$out" | grep -E "$CHANGE_RE" >/dev/null; then
  printf '%s\n' "$out" | grep -E "$CHANGE_RE|^readers on |^grid access list on "
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
ngrant=$(printf '%s\n' "$out" | grep -c -E '^  (granted|would grant) ')
nrevoke=$(printf '%s\n' "$out" | grep -c -E '^  (revoked|would revoke) ')
if [ $dry = 1 ]; then
  log "dry run ($count ids, $nreaders readers): would add $nadd, remove $nrem, grant $ngrant, revoke $nrevoke; $nskip unknown; $nfail checks failed"
  exit $rc
fi
# the state: the list as applied; each id the grid did not know on a dated line of its own instead; each
# folder taken off whose taking back did not finish, or was not tried this run, on a line of its own
skipsp=" $(printf '%s' "$skipped" | tr '\n' ' ') "
left=""
for pair in $unreads; do
  words=${pair#*:}; [ "$words" != . ] || words="all of $root"
  if [ $sweep_r = 0 ] || printf '%s\n' "$out" | grep -F -- "  FAILED  reader ${pair%%:*}: $words not taken back:" >/dev/null; then
    left="$left$pair"$'\n'
  fi
done
nleft=$(printf '%s' "$left" | grep -c .)
applied=""
for id in $ids; do in_list "$id" "$skipsp" || applied="$applied$id"$'\n'; done
tmpf="$statef.new.$$"
{ say "# grid_access.sh: the list last applied. An approved id the grid did not know is on a line \"# unknown <id> <date>\" instead, tried again once a day (or with --force); a reader's folder not yet taken back, on a line \"# unread <id> <folder>\", likewise"
  say "# target $target"
  say "# applied $(date -u +%FT%TZ)"
  for id in $skipped; do say "# unknown $id $today"; done
  for pair in $pairs; do in_list "${pair%%:*}" "$skipsp" || say "# read ${pair%%:*} ${pair#*:}"; done
  for pair in $left; do say "# unread ${pair%%:*} ${pair#*:}"; done
  if [ $sweep_r = 1 ]; then say "# swept $today"; elif [ -n "$prev_swept" ]; then say "# swept $prev_swept"; fi
  printf '%s' "$applied"
} > "$tmpf" && mv -f "$tmpf" "$statef" || { rm -f "$tmpf"; log "applied, but the state file could not be written"; die "could not write $statef (the grid side did apply the list)"; }
log "applied $count ids and $nreaders readers (+$nadd -$nrem, readers' folders$([ $sweep_r = 1 ] || echo ' not') swept: $ngrant granted, $nrevoke revoked; $nskip unknown to the grid$([ "$nskip" != 0 ] && printf ': %s' "$(printf '%s' "$skipped" | tr '\n' ' ' | sed 's/ $//')")$([ "$nleft" = 0 ] || echo "; $nleft folders not taken back yet"))$([ "$nfail" != 0 ] && echo "; $nfail checks FAILED")"
exit $rc
