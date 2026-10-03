#!/usr/bin/env bash
# Tests for tools/grid_access.sh. Linux only; on the maintainer's PC, in WSL:
#   wsl -e bash -lc 'bash /mnt/c/Users/<you>/OneDrive/Desktop/ashley-bridge/tools/tests/test_grid_access.sh'
# Everything happens in a temporary folder under /tmp that stands for the grid's volume: vol/ is its
# physical root and rs_grp_oschome a link to it, as on the grid. Nothing reaches the grid, the access
# service or the real vendor folder: ssh is tests/shim/ssh (it records each call and runs the grid side
# here, with the script on stdin as sshd would), and HOME, BEETHOVEN_VENDOR_DIR and BEETHOVEN_SERVICE_DIR
# point into the temporary folder; BEETHOVEN_ROSTER_CMD is unset.
# setfacl and getfacl are always tests/shim/acl, an emulation of the POSIX ACL behaviour the tool relies
# on (WSL has no acl package, and the grid's AccessIDs exist on no test machine, so even a real setfacl
# could not name them); `id` answers for the test's accounts (tests/shim/id); `stat` answers another
# owner for the paths the test lists in $SHIM_OWNERS (tests/shim/stat), since only root could chown to
# accounts that do not exist. tools/deploy_shared.sh's cluster side (--publish) runs here too, into the
# test's tree. What a real ACL implementation would do differently is not tested here.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
GA="$REPO/tools/grid_access.sh"
DS="$REPO/tools/deploy_shared.sh"
SHIMS="$REPO/tools/tests/shim"
T=$(mktemp -d /tmp/grid_access_test.XXXXXX) || exit 1
T=$(cd "$T" && pwd -P)
cleanup() { chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

SHIM_REAL_ID=$(command -v id); SHIM_REAL_STAT=$(command -v stat); export SHIM_REAL_ID SHIM_REAL_STAT
mkdir -p "$T/bin" "$T/home" "$T/vendor"
for s in acl id ssh stat; do cp "$SHIMS/$s" "$T/bin/$s.shim" && chmod 755 "$T/bin/$s.shim"; done
ln -s acl.shim "$T/bin/setfacl"; ln -s acl.shim "$T/bin/getfacl"; ln -s id.shim "$T/bin/id"; ln -s ssh.shim "$T/bin/ssh"; ln -s stat.shim "$T/bin/stat"
export PATH="$T/bin:$PATH" SHIM_ACL_STORE="$T/acl" SHIM_LOG="$T/shim.log" SHIM_SSH_CALLS="$T/ssh.calls" SHIM_OWNERS="$T/owners"
export SHIM_USERS="hy9698 ab1234 cd5678 ef9012"
export HOME="$T/home" BEETHOVEN_VENDOR_DIR="$T/vendor" BEETHOVEN_SERVICE_DIR="$T/no-service"
unset BEETHOVEN_ROSTER_CMD SHIM_SSH_MODE SHIM_ACL_FAIL
ME=$(id -un); GRP=$(id -gn)
STATE="$T/vendor/state/grid_access.wayne.ids"; LOG="$T/vendor/state/grid_access.log"
: > "$SHIM_SSH_CALLS"; : > "$SHIM_LOG"; : > "$SHIM_OWNERS"
TODAY=$(date -u +%F)
echo "setfacl/getfacl: the emulation in tools/tests/shim/acl$(command -v -p setfacl >/dev/null 2>&1 && echo ' (a real setfacl exists here but cannot name the test accounts)' || echo ' (no setfacl on this machine)')"

pass=0 fail=0 runs=0 OUT="" RC=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }
t() { local d=$1; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
# grep without -q after a pipe: under pipefail, grep -q leaving early fails the writer with SIGPIPE
has() { printf '%s\n' "$OUT" | grep -E -- "$1" >/dev/null; }
lacks() { ! has "$1"; }
rc_is() { [ "$RC" = "$1" ]; }
calls() { wc -l < "$SHIM_SSH_CALLS" | tr -d ' '; }
ga() { OUT=$(bash "$GA" --site wayne --root "$ROOT" "$@" 2>&1); RC=$?; runs=$((runs + 1)); }
named() { getfacl -p --omit-header "$V" | sed -n 's/^user:\([^:][^:]*\):.*/\1/p' | sort | tr '\n' ' ' | sed 's/ $//'; }
base() { getfacl -p --omit-header "$V" | grep -E '^(user::|group:|mask::|other::|default:)'; }
state_ids() { grep -v '^#' "$STATE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
roster() { printf '%s\n' "$@" > "$T/roster"; }
owns() { printf '%s %s\n' "$1" "$2" >> "$SHIM_OWNERS"; }   # PATH OWNER, for the stat shim
snap() { # the two folders that must stay closed: every mode and owner in them, and their ACLs
  find "$V/shared/access" "$V/$ME" -printf '%m %u %p\n' | sort
  getfacl -p "$V/shared/access" "$V/$ME"
}
last_line_is_list() { printf '%s\n' "$OUT" | tail -1 | grep '^grid access list on ' >/dev/null; }

mkvol() { # a fresh volume, closed below the gate as it was before 2026-10-02
  chmod -R u+rwx "$T/vol" 2>/dev/null; rm -rf "$T/vol" "$T/acl" "$T/rs_grp_oschome"
  V="$T/vol"; L="$V/shared/beethoven"; ROOT="$T/rs_grp_oschome"
  mkdir -p "$V/$ME/data" "$V/shared/access" "$L/hpcworker/v12/bin" "$L/containers/claude-node22/etc" "$L/npm-claude-node22/bin"
  echo data > "$V/$ME/data/results.csv"
  echo token > "$V/shared/access/admin_token"; chmod 600 "$V/shared/access/admin_token"
  printf '#!/bin/sh\necho 12\n' > "$L/hpcworker/v12/bin/hpcworker"
  ln -s v12 "$L/hpcworker/current"
  echo NAME=test > "$L/containers/claude-node22/etc/os-release"
  echo '#!/bin/sh' > "$L/npm-claude-node22/bin/claude"
  ln -s beethoven "$V/shared/ashley"
  find "$L" -type d -exec chmod 2750 {} +
  find "$L" -type f -exec chmod 640 {} +
  chmod 750 "$L/hpcworker/v12/bin/hpcworker" "$L/npm-claude-node22/bin/claude"
  chmod 2750 "$V/$ME"; chmod 2700 "$V/shared/access"; chmod 2770 "$V/shared"
  chmod 2770 "$V"; chmod +t "$V"
  ln -s vol "$ROOT"
}

mkvol
setfacl -m "u:ab1234:rwx,g:$GRP:r-x" "$V"   # a hand entry not on the list, and a named group entry
BASE0=$(base)
t "fixture: the root is drwxrws--T with ab1234 and group $GRP named" eval '[ "$(stat -c %A "$V")" = drwxrws--T ] && [ "$(named)" = ab1234 ] && printf "%s\n" "$BASE0" | grep "^group:$GRP:r-x" >/dev/null'

echo "== dry run"
roster hy9698 '# approved 2026-10-02' '' $'  cd5678\r'
ga --roster-file "$T/roster" --dry-run --open-tree
t "dry run: says what it would add and remove" eval 'has "would add cd5678" && has "would add hy9698" && has "would remove ab1234"'
t "dry run: says what --open-tree would do" eval 'has "would chmod o\+rx" && has "would chmod o\+rX everything under"'
t "dry run: shows the entries as they are now, and as they would be" eval 'has "^grid access list on $ROOT now: ab1234$" && has "^grid access list on $ROOT after this run would be: cd5678 hy9698$"'
t "dry run: nothing changed (named, shared's mode, no state)" eval '[ "$(named)" = ab1234 ] && [ "$(stat -c %a "$V/shared")" = 2770 ] && [ ! -e "$STATE" ]'
t "dry run: one connection, exit 2 for the closed tree" eval '[ "$(calls)" = 1 ] && rc_is 2'

echo "== first apply (the tree still closed)"
ga --roster-file "$T/roster"
t "apply: adds the two ids and removes the hand entry" eval 'has "^  added   cd5678" && has "^  added   hy9698" && has "^  removed ab1234 \(was rwx\)"'
t "apply: the named entries are the list" eval '[ "$(named)" = "cd5678 hy9698" ]'
t "apply: owner, group, named group, mask and other entries untouched" eval '[ "$(base)" = "$BASE0" ]'
t "apply: the root keeps drwxrws--T" eval '[ "$(stat -c %A "$V")" = drwxrws--T ]'
t "apply: closed tree reported by the cheap checks, exit 2, list kept" eval 'rc_is 2 && has "^  FAILED  shared: closed to other" && has "^  FAILED  hpcworker" && [ "$(named)" = "cd5678 hy9698" ]'
t "apply: an ordinary apply does not sweep the whole tree" eval 'has "^  note    everything under shared/beethoven was not swept this run" && lacks "entries under shared/beethoven are closed" && lacks "everything under shared/beethoven is readable"'
t "apply: the output ends with the list" eval 'last_line_is_list && has "^grid access list on $ROOT: cd5678 hy9698$"'
t "apply: state written with the list and the target" eval '[ "$(state_ids)" = "cd5678 hy9698" ] && grep -q "^# target wsu-grid:$ROOT$" "$STATE"'
t "apply: two connections so far" eval '[ "$(calls)" = 2 ]'

echo "== unchanged list"
ga --roster-file "$T/roster"
t "unchanged: no connection, exit 0" eval '[ "$(calls)" = 2 ] && rc_is 0 && has "not connecting"'
ga --roster-file "$T/roster" --quiet
t "unchanged --quiet: no output, no connection" eval '[ -z "$OUT" ] && rc_is 0 && [ "$(calls)" = 2 ]'
ga --roster-file "$T/roster" --force
t "--force connects although unchanged, changes nothing" eval '[ "$(calls)" = 3 ] && lacks "^  (added|removed|changed) " && [ "$(named)" = "cd5678 hy9698" ]'

echo "== --open-tree"
SNAP0=$(snap)
: > "$SHIM_LOG"
ga --roster-file "$T/roster" --open-tree
t "open-tree: connects although the list is unchanged" eval '[ "$(calls)" = 4 ]'
t "open-tree: every check ok, the sweep included, exit 0" eval 'rc_is 0 && lacks FAILED && has "^  ok      everything under shared/beethoven is readable by other"'
t "open-tree: the gate's line names its owner" eval 'has "^  ok      the gate: $ROOT belongs to $ME, is sticky and closed to other \(drwxrws--T\)"'
t "open-tree: shared is drwxrwsr-x, hpcworker -rwxr-xr-x, a data file -rw-r--r--" eval '[ "$(stat -c %A "$V/shared")" = drwxrwsr-x ] && [ "$(stat -c %A "$L/hpcworker/v12/bin/hpcworker")" = -rwxr-xr-x ] && [ "$(stat -c %A "$L/containers/claude-node22/etc/os-release")" = -rw-r--r-- ]'
t "open-tree: folders under shared/beethoven get default other::r-x" eval 'getfacl -p "$L/containers/claude-node22" | grep "^default:other::r-x" >/dev/null && getfacl -p "$L" | grep "^default:other::r-x" >/dev/null'
t "open-tree: shared/access and the owner folder untouched (modes, owners, ACLs)" eval '[ "$(snap)" = "$SNAP0" ]'
t "open-tree: setfacl ran under shared/beethoven, never on shared/access or the owner folder" eval 'grep -q "^setfacl -d -m o::r-x $L" "$SHIM_LOG" && ! grep -E "^setfacl .*($V/shared/access|$V/$ME( |/|$))" "$SHIM_LOG"'
t "open-tree: the root still drwxrws--T, the shared/ashley link still a link" eval '[ "$(stat -c %A "$V")" = drwxrws--T ] && [ -L "$V/shared/ashley" ]'
t "open-tree: the root's entries untouched" eval '[ "$(base)" = "$BASE0" ]'

echo "== a changed list, with an id the grid does not know"
roster hy9698 ef9012 zz0000
ga --roster-file "$T/roster"
t "change: adds ef9012, removes cd5678, skips zz0000" eval 'has "^  added   ef9012" && has "^  removed cd5678" && has "^  skipped zz0000: no such account"'
t "change: the named entries are the list, exit 0" eval '[ "$(named)" = "ef9012 hy9698" ] && rc_is 0'
t "change: the state lists the two and records zz0000 as unknown today" eval '[ "$(state_ids)" = "ef9012 hy9698" ] && grep -qx "# unknown zz0000 $TODAY" "$STATE"'
t "change: entries untouched" eval '[ "$(base)" = "$BASE0" ]'
n=$(calls)
ga --roster-file "$T/roster" --quiet
t "an unknown id alone is no change: the same day no connection, and --quiet says nothing" eval '[ "$(calls)" = $n ] && rc_is 0 && [ -z "$OUT" ]'
ga --roster-file "$T/roster"
t "unchanged: names the id still waiting for a grid account, then the list" eval 'rc_is 0 && has "not on the grid yet.*: zz0000$" && last_line_is_list && has "^grid access list on $ROOT: ef9012 hy9698$" && [ "$(calls)" = $n ]'
roster hy9698 ef9012
ga --roster-file "$T/roster"
t "the unknown id taken off the roster: still unchanged, no connection" eval 'rc_is 0 && has "not connecting" && [ "$(calls)" = $n ]'
roster hy9698 ef9012 zz0000
sed -i "s/^# unknown zz0000 .*/# unknown zz0000 2000-01-01/" "$STATE"
ga --roster-file "$T/roster" --quiet
t "on a later day it is tried again: one connection; --quiet prints only the skip and the list" eval '[ "$(calls)" = $((n + 1)) ] && has "^  skipped zz0000" && has "^grid access list on " && lacks "^==" && lacks "^  ok " && lacks "^  note "'
t "the retry dates the record today, the list unchanged" eval 'grep -qx "# unknown zz0000 $TODAY" "$STATE" && [ "$(state_ids)" = "ef9012 hy9698" ]'
ga --roster-file "$T/roster" --quiet
t "and not again the same day" eval '[ "$(calls)" = $((n + 1)) ] && [ -z "$OUT" ] && rc_is 0'
ga --roster-file "$T/roster" --force
t "--force tries it at once" eval '[ "$(calls)" = $((n + 2)) ] && has "^  skipped zz0000" && rc_is 0'
sed -i "s/^# unknown zz0000 .*/# unknown zz0000 2000-01-01/" "$STATE"
SHIM_USERS="$SHIM_USERS zz0000" ga --roster-file "$T/roster"
t "once the grid knows it, the day's retry adds it and its record goes" eval 'rc_is 0 && has "^  added   zz0000" && [ "$(named)" = "ef9012 hy9698 zz0000" ] && [ "$(state_ids)" = "ef9012 hy9698 zz0000" ] && ! grep -q "^# unknown" "$STATE"'
roster hy9698 ef9012
SHIM_USERS="$SHIM_USERS zz0000" ga --roster-file "$T/roster"
t "taken off the roster again: removed" eval 'rc_is 0 && has "^  removed zz0000" && [ "$(named)" = "ef9012 hy9698" ] && [ "$(state_ids)" = "ef9012 hy9698" ]'

echo "== an approved id the grid stops knowing for a moment"
SHIM_USERS="hy9698 ab1234 cd5678" ga --roster-file "$T/roster" --force
t "its entry is kept, the read-back tolerates it, exit 0" eval 'rc_is 0 && has "^  skipped ef9012" && lacks FAILED && has "^  ok      the list read back from $ROOT is the list applied \(with the entry kept for ef9012" && [ "$(named)" = "ef9012 hy9698" ]'
t "the state records it as unknown, the list holds the rest" eval 'grep -qx "# unknown ef9012 $TODAY" "$STATE" && [ "$(state_ids)" = hy9698 ]'
ga --roster-file "$T/roster" --force
t "known again: back in the state's list" eval 'rc_is 0 && [ "$(state_ids)" = "ef9012 hy9698" ] && ! grep -q "^# unknown" "$STATE"'

echo "== refusals: nothing changes"
cp "$STATE" "$T/state.before"; n=$(calls); before=$(named)
unchanged() { [ "$(calls)" = "$1" ] && [ "$(named)" = "$before" ] && cmp -s "$STATE" "$T/state.before"; }
roster hy9698 HY1234
ga --roster-file "$T/roster"
t "bad id: refused, names line 2, no connection, nothing changed" eval 'rc_is 1 && has "line 2 of the file .* is not an AccessID .*HY1234" && unchanged $n'
roster hy9698 'cd5678; rm -rf ~' ef9012
ga --roster-file "$T/roster" --force
t "an id with shell words: refused, no connection" eval 'rc_is 1 && has "line 2 of" && unchanged $n'
roster '# nobody yet' ''
ga --roster-file "$T/roster"
t "empty list: refused without --force, no connection" eval 'rc_is 1 && has "gave no AccessID" && unchanged $n'
roster hy9698 ef9012 cd5678
chmod o+rx "$V"
ga --roster-file "$T/roster"
t "other-readable root: refused with the fix, nothing changed" eval 'rc_is 1 && has "chmod o-rwx $V" && unchanged $((n + 1))'
chmod o-rx "$V"; chmod -t "$V"
ga --roster-file "$T/roster"
t "root not sticky: refused with the fix, nothing changed" eval 'rc_is 1 && has "chmod \+t $V" && unchanged $((n + 2))'
chmod +t "$V"
mv "$L" "$V/shared/beethoven.real"; ln -s beethoven.real "$L"
ga --roster-file "$T/roster" --open-tree
t "open-tree on a linked shared/beethoven: refused, nothing changed" eval 'rc_is 1 && has "is not a plain folder" && unchanged $((n + 3))'
rm "$L"; mv "$V/shared/beethoven.real" "$L"
OUT=$(bash "$GA" --apply "$ROOT" hy9698 'x;y' 2>&1); RC=$?
t "grid side: a bad id refused, nothing changed" eval 'rc_is 1 && has "not an AccessID" && unchanged $((n + 3))'
OUT=$(bash "$GA" --apply / hy9698 2>&1); RC=$?
t "grid side: a root this account does not own is refused" eval 'rc_is 1 && has "belongs to root, not to $ME"'
OUT=$(bash "$GA" --apply relative/root hy9698 2>&1); RC=$?
t "grid side: a relative root is refused" eval 'rc_is 1 && has "must be absolute"'
roster hy9698 cd5678
SHIM_ACL_FAIL=x ga --roster-file "$T/roster"
t "setfacl failing half-way (the removal): exit 1, state not written" eval 'rc_is 1 && has "^  added   cd5678" && has "partly applied" && cmp -s "$STATE" "$T/state.before"'
ga --roster-file "$T/roster"
t "the next run finishes it" eval 'rc_is 0 && has "^  removed ef9012" && [ "$(named)" = "cd5678 hy9698" ] && [ "$(state_ids)" = "cd5678 hy9698" ]'

echo "== checks"
setfacl -m m::r-x "$V"
roster hy9698 ef9012
ga --roster-file "$T/roster"
t "a narrowed mask: FAILED, exit 2, the mask left as it is" eval 'rc_is 2 && has "^  FAILED  the mask: mask::r-x" && getfacl -p "$V" | grep "^mask::r-x" >/dev/null'
setfacl -m m::rwx "$V"
chmod o-rx "$L/hpcworker/v12"
rm -f "$STATE"
ga --roster-file "$T/roster" --force
t "a closed folder on the way to hpcworker: FAILED naming it, exit 2, no sweep" eval 'rc_is 2 && has "^  FAILED  hpcworker: closed to other at shared/beethoven/hpcworker/v12" && lacks "entries under shared/beethoven are closed"'
t "exit 2 still writes the state (the list was applied)" eval '[ "$(state_ids)" = "ef9012 hy9698" ]'
ga --roster-file "$T/roster" --check-tree
t "--check-tree connects although unchanged and sweeps: 1 entry closed" eval 'rc_is 2 && has "^  FAILED  1 entries under shared/beethoven are closed to other, like shared/beethoven/hpcworker/v12 "'
chmod o+rx "$V/shared/access" "$V/$ME"
ga --roster-file "$T/roster" --open-tree
t "open-tree reopens hpcworker's folder" eval 'has "^  ok      hpcworker" && [ "$(stat -c %A "$L/hpcworker/v12")" = drwxr-sr-x ]'
t "an opened shared/access and owner folder: FAILED, and open-tree leaves them alone" eval 'rc_is 2 && has "^  FAILED  shared/access is open to other" && has "^  FAILED  $ME \(the owner.s folder\) is open to other" && [ "$(stat -c %A "$V/shared/access")" = drwx--Sr-x ]'
chmod o-rx "$V/shared/access" "$V/$ME"
ga --roster-file "$T/roster" --force
t "closed again: every check ok" eval 'rc_is 0 && lacks FAILED'

echo "== a publish by tools/deploy_shared.sh, and the sweep"
P="$T/pub"; mkdir -p "$P/bin"
printf '#!/bin/sh\necho 13\n' > "$P/bin/hpcworker"; echo 13 > "$P/VERSION"; echo 'the test copy' > "$P/README.md"
MAN_B64=$(cd "$P" && sha256sum bin/hpcworker VERSION README.md | base64 | tr -d '\n')
( cd "$P" && tar -cf "$T/pub.tar" bin/hpcworker VERSION README.md )
publish() { OUT=$(bash "$DS" --publish "$L/hpcworker" 13 "$GRP" 0 0 test0000 "$MAN_B64" < "$T/pub.tar" 2>&1); RC=$?; }
publish
t "deploy_shared publishes v13 into the test tree" eval 'rc_is 0 && has "published v13" && [ "$(readlink "$L/hpcworker/current")" = v13 ]'
t "deploy_shared leaves deploy.log readable by other (0644)" eval '[ "$(stat -c %a "$L/hpcworker/deploy.log")" = 644 ]'
ga --roster-file "$T/roster" --check-tree
t "after the publish the sweep finds nothing closed, exit 0" eval 'rc_is 0 && lacks FAILED && has "^  ok      everything under shared/beethoven is readable by other" && has "^  ok      hpcworker: other may read and enter it \(-r-xr-xr-x\)"'
chmod 0640 "$L/hpcworker/deploy.log"
ga --roster-file "$T/roster" --check-tree
t "a deploy.log at 0640 (as deploy_shared wrote it before): the sweep names it" eval 'rc_is 2 && has "^  FAILED  1 entries under shared/beethoven are closed to other, like shared/beethoven/hpcworker/deploy.log "'
ga --roster-file "$T/roster" --force
t "an ordinary apply does not sweep: exit 0 with the note" eval 'rc_is 0 && lacks FAILED && has "^  note    everything under shared/beethoven was not swept this run \(--check-tree sweeps it\)"'
ga --roster-file "$T/roster" --open-tree
t "--open-tree gives deploy.log the mode deploy_shared now writes" eval 'rc_is 0 && [ "$(stat -c %a "$L/hpcworker/deploy.log")" = 644 ]'
publish
ga --roster-file "$T/roster" --check-tree
t "a second publish (the same files) and the sweep agree: deploy.log 0644, exit 0" eval 'rc_is 0 && [ "$(stat -c %a "$L/hpcworker/deploy.log")" = 644 ] && [ "$(wc -l < "$L/hpcworker/deploy.log" | tr -d " ")" = 2 ]'
STG="$L/hpcworker/.incoming-v14.Ab12Cd"
mkdir -m 700 "$STG"; echo 14 > "$STG/VERSION"; chmod 600 "$STG/VERSION"
ga --roster-file "$T/roster" --check-tree
t "a staging folder left by a failed publish (0700) is not swept: exit 0" eval 'rc_is 0 && lacks FAILED && has "^  ok      everything under shared/beethoven is readable by other"'
: > "$SHIM_LOG"; STG0=$(find "$STG" -printf '%M %p\n')
ga --roster-file "$T/roster" --open-tree
t "--open-tree leaves the staging folder as it is (drwx--S---, its file -rw-------)" eval 'rc_is 0 && [ "$(find "$STG" -printf "%M %p\n")" = "$STG0" ] && [ "$(stat -c %A "$STG")" = drwx--S--- ] && [ "$(stat -c %A "$STG/VERSION")" = -rw------- ] && ! grep -q incoming "$SHIM_LOG"'
chmod -R u+rwx "$STG"; rm -rf "$STG"

echo "== the root's entries: a folder in another student's place"
mkdir "$V/hy9698"; owns "$V/hy9698" hy9698
ga --roster-file "$T/roster" --force
t "a student's own folder, named for its owner: ok" eval 'rc_is 0 && has "^  ok      the root.s entries: each of the 3 is a student.s own folder, named for its owner, or belongs to $ME$"'
mkdir "$V/cd5678"; owns "$V/cd5678" hy9698
ga --roster-file "$T/roster" --force
t "a folder named for cd5678 that hy9698 owns: FAILED naming both, exit 2" eval 'rc_is 2 && has "^  FAILED  the root.s entries: cd5678 \(directory\) belongs to hy9698, not to cd5678"'
t "the squat does not stop the list (applied, state written)" eval '[ "$(named)" = "ef9012 hy9698" ] && [ "$(state_ids)" = "ef9012 hy9698" ]'
ln -s "$V/shared" "$V/ef9012"; owns "$V/ef9012" ef9012
mkdir "$V/scratch"; owns "$V/scratch" hy9698
mkdir "$V/notes"
ga --roster-file "$T/roster" --force
t "a link in a student's place, even one that student owns: FAILED" eval 'has "^  FAILED  the root.s entries: ef9012 is a link \(to $V/shared\) owned by ef9012"'
t "another name a student owns: FAILED; one the root's owner owns: fine" eval 'has "^  FAILED  the root.s entries: scratch \(directory\) belongs to hy9698, not to $ME" && lacks "notes"'
t "each offending entry on a line of its own: three, exit 2" eval 'rc_is 2 && [ "$(printf "%s\n" "$OUT" | grep -c "^  FAILED  the root.s entries: ")" = 3 ]'
ga --roster-file "$T/roster" --force --quiet
t "--quiet still prints the offending entries" eval 'rc_is 2 && has "^  FAILED  the root.s entries: cd5678" && has "^grid access list on "'
ga --roster-file "$T/roster" --dry-run --force
t "a dry run checks the entries too, and shows the list as it is" eval 'rc_is 2 && has "^  FAILED  the root.s entries: cd5678" && has "^grid access list on $ROOT now: ef9012 hy9698$"'
rm -r "$V/cd5678" "$V/scratch" "$V/notes" "$V/hy9698"; rm "$V/ef9012"; : > "$SHIM_OWNERS"
ga --roster-file "$T/roster" --force
t "the squatters gone: every check ok" eval 'rc_is 0 && lacks FAILED && has "^  ok      the root.s entries: each of the 2 "'

echo "== roster sources"
export BEETHOVEN_ROSTER_CMD="printf 'ef9012\nhy9698\n'"
ga
t "\$BEETHOVEN_ROSTER_CMD: the same list as applied, no connection" eval 'rc_is 0 && has "not connecting" && has "BEETHOVEN_ROSTER_CMD|unchanged"'
export BEETHOVEN_ROSTER_CMD="exit 3"
n=$(calls); ga
t "a failing roster command: refused, no connection" eval 'rc_is 1 && has "ended with exit 3" && [ "$(calls)" = $n ]'
unset BEETHOVEN_ROSTER_CMD
ga
t "no service checkout: refused, no connection" eval 'rc_is 1 && has "no $T/no-service/tools/intake/admin.mjs" && [ "$(calls)" = $n ]'
if command -v node >/dev/null 2>&1; then
  mkdir -p "$T/svc/tools/intake"
  printf '%s\n' "if (process.argv[2] !== 'roster') { console.error('usage'); process.exit(2); }" "console.log('hy9698'); console.log('cd5678');" > "$T/svc/tools/intake/admin.mjs"
  BEETHOVEN_SERVICE_DIR="$T/svc" ga
  t "admin.mjs roster from \$BEETHOVEN_SERVICE_DIR: applied" eval 'rc_is 0 && has "^  added   cd5678" && has "^  removed ef9012" && [ "$(named)" = "cd5678 hy9698" ] && [ "$(calls)" = $((n + 1)) ]'
  printf '%s\n' "process.exit(4);" > "$T/svc/tools/intake/admin.mjs"
  BEETHOVEN_SERVICE_DIR="$T/svc" ga
  t "admin.mjs failing: refused, no connection" eval 'rc_is 1 && has "ended with exit 4" && [ "$(calls)" = $((n + 1)) ]'
else
  echo "skip the admin.mjs tests: no node on PATH"
fi

echo "== the root from the site profile, and --here"
roster hy9698 cd5678
cp "$STATE" "$T/state.before"; n=$(calls)
OUT=$(SHIM_SSH_MODE=record bash "$GA" --site wayne --roster-file "$T/roster" 2>&1); RC=$?; runs=$((runs + 1))
t "profile: the grid side is asked for /rs/rs_grp_oschome over wsu-grid, as bash -s" eval 'tail -1 "$SHIM_SSH_CALLS" | grep -E "wsu-grid bash -s -- --apply /rs/rs_grp_oschome cd5678 hy9698 2>&1$" >/dev/null'
t "profile: ssh failing is exit 1, the state unchanged" eval 'rc_is 1 && has "ssh to wsu-grid failed" && cmp -s "$STATE" "$T/state.before" && [ "$(calls)" = $((n + 1)) ]'
OUT=$(SHIM_SSH_MODE=record bash "$GA" --site wayne --roster-file "$T/roster" --check-tree --force 2>&1); RC=$?; runs=$((runs + 1))
t "--check-tree travels to the grid side" eval 'tail -1 "$SHIM_SSH_CALLS" | grep -E "bash -s -- --apply --check-tree /rs/rs_grp_oschome cd5678 hy9698 2>&1$" >/dev/null'
roster hy9698
n=$(calls)
ga --here --roster-file "$T/roster"
t "--here: applied without ssh" eval 'rc_is 0 && has "^  removed (cd5678|ef9012)" && [ "$(named)" = hy9698 ] && [ "$(calls)" = $n ] && grep -q "^# target here:$ROOT$" "$STATE"'
ga --here
t "--here with no roster file or command: refused" eval 'rc_is 1 && has "with --here give --roster-file"'
roster '# nobody'
ga --roster-file "$T/roster" --force
t "an empty list with --force: every named entry removed, (none)" eval 'rc_is 0 && [ -z "$(named)" ] && has "^grid access list on $ROOT: \(none\)$" && [ -z "$(state_ids)" ]'
t "at the end: owner, group, named group, mask and other entries as at the start" eval '[ "$(base)" = "$BASE0" ] && [ "$(stat -c %A "$V")" = drwxrws--T ]'

echo "== the log"
t "one log line per run ($runs runs)" eval '[ "$(wc -l < "$LOG" | tr -d " ")" = "$runs" ]'
t "the log names an unknown id once it is skipped" eval 'grep -q "1 unknown to the grid: zz0000" "$LOG"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
