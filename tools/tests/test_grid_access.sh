#!/usr/bin/env bash
# Tests for tools/grid_access.sh. Linux only; on the maintainer's PC, in WSL:
#   wsl -e bash -lc 'bash /mnt/c/Users/<you>/OneDrive/Desktop/ashley-bridge/tools/tests/test_grid_access.sh'
# Everything happens in a temporary folder under /tmp that stands for the grid's volume: vol/ is its
# physical root and rs_grp_oschome a link to it, as on the grid. Nothing reaches the grid, the access
# service or the real vendor folder: ssh is tests/shim/ssh (it records each call and runs the grid side
# here, with the script on stdin as sshd would), and HOME and BEETHOVEN_VENDOR_DIR point into the
# temporary folder; BEETHOVEN_ROSTER_CMD is unset. The access service is a stand-in HTTPS server on
# 127.0.0.1 (python3, in its own section below), and until that section BEETHOVEN_SERVICE_URL names a
# closed loopback port, so no run ever asks the real service; where a command is the source, it is a
# stand-in shell script ($T/admin-stub) with two subcommands.
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
cleanup() { [ -z "${SVC_PID:-}" ] || kill "$SVC_PID" 2>/dev/null; chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
[ -z "${KEEP_T:-}" ] || cleanup() { [ -z "${SVC_PID:-}" ] || kill "$SVC_PID" 2>/dev/null; echo "kept $T"; }
trap cleanup EXIT

SHIM_REAL_ID=$(command -v id); SHIM_REAL_STAT=$(command -v stat); export SHIM_REAL_ID SHIM_REAL_STAT
mkdir -p "$T/bin" "$T/home" "$T/vendor"
for s in acl id ssh stat; do cp "$SHIMS/$s" "$T/bin/$s.shim" && chmod 755 "$T/bin/$s.shim"; done
ln -s acl.shim "$T/bin/setfacl"; ln -s acl.shim "$T/bin/getfacl"; ln -s id.shim "$T/bin/id"; ln -s ssh.shim "$T/bin/ssh"; ln -s stat.shim "$T/bin/stat"
export PATH="$T/bin:$PATH" SHIM_ACL_STORE="$T/acl" SHIM_LOG="$T/shim.log" SHIM_SSH_CALLS="$T/ssh.calls" SHIM_OWNERS="$T/owners"
export SHIM_USERS="hy9698 ab1234 cd5678 ef9012"
export HOME="$T/home" BEETHOVEN_VENDOR_DIR="$T/vendor"
export BEETHOVEN_SERVICE_URL=https://127.0.0.1:1   # nothing listens there: a run that asks the service cannot reach the real one
unset BEETHOVEN_ROSTER_CMD SHIM_SSH_MODE SHIM_ACL_FAIL SHIM_GROUP_OWNERS GA_READ_CAP
export BEETHOVEN_READERS_CMD=true   # no reader until the readers' section
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
# / is root's; run as root (a container), stand in a folder the stat shim says another account owns
NOTMINE=/ NOTMINE_OWNER=root
if [ "$ME" = root ]; then NOTMINE="$T/notmine" NOTMINE_OWNER=ab1234; mkdir "$NOTMINE"; owns "$NOTMINE" ab1234; fi
OUT=$(bash "$GA" --apply "$NOTMINE" hy9698 2>&1); RC=$?
t "grid side: a root this account does not own is refused" eval 'rc_is 1 && has "belongs to $NOTMINE_OWNER, not to $ME"'
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
chmod o+rx "$V/shared/access"; chmod o+rwx "$V/$ME"
ga --roster-file "$T/roster" --open-tree
t "open-tree reopens hpcworker's folder" eval 'has "^  ok      hpcworker" && [ "$(stat -c %A "$L/hpcworker/v12")" = drwxr-sr-x ]'
t "an opened shared/access, an owner folder other may write: FAILED, and open-tree leaves them alone" eval 'rc_is 2 && has "^  FAILED  shared/access is open to other" && has "^  FAILED  $ME \(the owner.s folder\) may be written by other \(drwxr-srwx\) \(fix: chmod o-w " && [ "$(stat -c %A "$V/shared/access")" = drwx--Sr-x ] && [ "$(stat -c %A "$V/$ME")" = drwxr-srwx ]'
chmod o-rx "$V/shared/access"; chmod o-w "$V/$ME"
ga --roster-file "$T/roster" --force
t "an owner folder other may read and enter, not write (the volume opened): ok" eval 'rc_is 0 && lacks FAILED && has "^  ok      $ME \(the owner.s folder\) is not writable by other \(drwxr-sr-x\)$" && has "^  ok      shared is not writable by other "'
chmod o-rx "$V/$ME"
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
t "no roster file or command: the access service is asked, and with no token here that refuses before anything is sent; no connection" eval 'rc_is 1 && has "no grid_token or admin_token in the vendor folder \($T/vendor\)" && [ "$(calls)" = $n ]'
# a command as the source: a stand-in with two subcommands, roster and readers, or a failure with its exit code
printf '%s\n' 'case "$1" in' '  roster) printf "%s\n" ${STUB_ROSTER:-hy9698 cd5678};;' '  readers) [ -z "${STUB_READERS_EXIT:-}" ] || exit "$STUB_READERS_EXIT"; printf "%s\n" "${STUB_READERS:-}";;' '  *) echo usage >&2; exit 2;;' 'esac' > "$T/admin-stub"
export BEETHOVEN_ROSTER_CMD="bash $T/admin-stub roster"
ga
t "a roster command that prints a changed list: applied" eval 'rc_is 0 && has "^  added   cd5678" && has "^  removed ef9012" && [ "$(named)" = "cd5678 hy9698" ] && [ "$(calls)" = $((n + 1)) ]'
export BEETHOVEN_ROSTER_CMD="bash $T/admin-stub nothing"
ga
t "a roster command failing: refused, no connection" eval 'rc_is 1 && has "ended with exit 2" && [ "$(calls)" = $((n + 1)) ]'
unset BEETHOVEN_ROSTER_CMD

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
t "--here with no roster file or command: the service is asked, no token here, refused" eval 'rc_is 1 && has "no grid_token or admin_token in the vendor folder"'
roster '# nobody'
ga --roster-file "$T/roster" --force
t "an empty list with --force: every named entry removed, (none)" eval 'rc_is 0 && [ -z "$(named)" ] && has "^grid access list on $ROOT: \(none\)$" && [ -z "$(state_ids)" ]'
t "at the end: owner, group, named group, mask and other entries as at the start" eval '[ "$(base)" = "$BASE0" ] && [ "$(stat -c %A "$V")" = drwxrws--T ]'

echo "== readers: the group's read on approved folders"
export SHIM_GROUP_OWNERS="$T/group_owners"; : > "$SHIM_GROUP_OWNERS"
D="$V/$ME/data"
chmod 2750 "$D"; chmod 640 "$D/results.csv"
echo secret > "$D/secret.txt"; chmod 600 "$D/secret.txt"
echo token > "$D/job.token"; chmod 600 "$D/job.token"
printf '#!/bin/sh\n' > "$D/run.sh"; chmod 750 "$D/run.sh"
echo open > "$D/notes.txt"; chmod 604 "$D/notes.txt"
echo public > "$D/public.csv"; chmod 644 "$D/public.csv"
mkdir "$D/sub"; chmod 2750 "$D/sub"; echo deep > "$D/sub/deep.csv"; chmod 640 "$D/sub/deep.csv"
echo odd > "$D/odd\\name"; chmod 640 "$D/odd\\name"
echo theirs > "$D/theirs.csv"; chmod 640 "$D/theirs.csv"; owns "$D/theirs.csv" hy9698
echo elsewhere > "$D/elsewhere.csv"; chmod 640 "$D/elsewhere.csv"; printf '%s %s\n' "$D/elsewhere.csv" othergrp >> "$SHIM_GROUP_OWNERS"
ln -s ../../shared/access/admin_token "$D/token.link"
ue() { getfacl -p --omit-header "$1" 2>/dev/null | sed -n "s/^user:$2:\([-rwx]*\).*/\1/p"; }   # PATH ID -> the named entry's perms
uem() { getfacl -p --omit-header "$1" 2>/dev/null | grep "^user:$2:" | grep '#effective' >/dev/null; }   # the mask cuts it
readers() { printf '%s\n' "$@" > "$T/readers"; }
export BEETHOVEN_READERS_CMD="cat $T/readers" BEETHOVEN_ROSTER_CMD="cat $T/roster"
roster hy9698 cd5678
readers "hy9698 $ME/data" '# approved 2026-10-07' '' $'  ab1234\tshared/access \r'
MODES0=$(find "$D" "$V/$ME" -printf '%m %p\n' | sort)
n=$(calls)
ga --dry-run
t "readers, dry run: the reader's traverse and the folder's grant, as would" eval 'has "would add ab1234 \(--x, a reader\)" && has "^  would grant hy9698 $ME/data: 5 entries set to the group.s read, 0 removed where the group may not read, 1 folders on the way made enterable"'
t "readers, dry run: nothing changed, no state" eval '[ -z "$(ue "$D" hy9698)" ] && [ -z "$(ue "$V" ab1234)" ] && ! grep -q "^# read" "$STATE" && [ "$(calls)" = $((n + 1)) ]'
ga
t "readers: ab1234 gets --x on the root, the list keeps rwx" eval 'has "^  added   ab1234 \(--x, a reader\)" && [ "$(ue "$V" ab1234)" = --x ] && [ "$(ue "$V" hy9698)" = rwx ] && [ "$(ue "$V" cd5678)" = rwx ]'
t "readers: granted, read back, exit 0" eval 'rc_is 0 && has "^  granted hy9698 $ME/data: 5 entries" && has "^  ok      reader hy9698: $ME/data reads as the group reads it \(12 entries, read back"'
t "readers: the folder and what the group reads get r-x or r--" eval '[ "$(ue "$D" hy9698)" = r-x ] && [ "$(ue "$D/results.csv" hy9698)" = r-- ] && [ "$(ue "$D/run.sh" hy9698)" = r-x ] && [ "$(ue "$D/sub" hy9698)" = r-x ] && [ "$(ue "$D/sub/deep.csv" hy9698)" = r-- ]'
t "readers: the owner's folder on the way gets --x only (enter, not list)" eval '[ "$(ue "$V/$ME" hy9698)" = --x ]'
t "readers: nothing on what the group may not read (0600 files: the secret, a job token)" eval '[ -z "$(ue "$D/secret.txt" hy9698)" ] && [ -z "$(ue "$D/job.token" hy9698)" ]'
t "readers: nothing where other reads already, where only other reads, on another's file, another group's, an escaped name" eval '[ -z "$(ue "$D/public.csv" hy9698)" ] && [ -z "$(ue "$D/notes.txt" hy9698)" ] && [ -z "$(ue "$D/theirs.csv" hy9698)" ] && [ -z "$(ue "$D/elsewhere.csv" hy9698)" ] && [ -z "$(ue "$D/odd\\name" hy9698)" ]'
t "readers: the check line counts what was left out" eval 'has "1 open to other already; 1 not $ME.s, left as they are; 1 whose names getfacl escapes"'
t "readers: no entry the mask cuts, no mode changed, no default entry, the link not followed" eval '! uem "$D/results.csv" hy9698 && ! uem "$D" hy9698 && [ "$(find "$D" "$V/$ME" -printf "%m %p\n" | sort)" = "$MODES0" ] && ! getfacl -R -p "$V/$ME" | grep "^default:" >/dev/null && [ -z "$(ue "$V/shared/access/admin_token" hy9698)" ]'
t "readers: shared/access closed to the group (2700): nothing for ab1234 there, ok" eval 'has "^  ok      reader ab1234: shared/access reads as the group reads it \(2 entries\)$" && [ -z "$(ue "$V/shared/access" ab1234)" ] && [ -z "$(ue "$V/shared/access/admin_token" ab1234)" ]'
t "readers: shared/access still closed to other, the owner's folder not writable by it" eval 'has "^  ok      shared/access is closed to other" && has "^  ok      $ME \(the owner.s folder\) is not writable by other"'
t "readers: the readers' line, then the list of rwx entries" eval 'has "^readers on $ROOT: ab1234 \(shared/access\); hy9698 \($ME/data\)$" && last_line_is_list && has "^grid access list on $ROOT: cd5678 hy9698$"'
t "readers: the state records each pair and the sweep" eval 'grep -qx "# read hy9698 $ME/data" "$STATE" && grep -qx "# read ab1234 shared/access" "$STATE" && grep -qx "# swept $TODAY" "$STATE" && [ "$(state_ids)" = "cd5678 hy9698" ]'
n=$(calls); ga
t "readers unchanged the same day: no connection, the readers named" eval 'rc_is 0 && has "not connecting" && has "^readers on $ROOT: ab1234:shared/access hy9698:$ME/data$" && [ "$(calls)" = $n ]'
ga --quiet
t "and --quiet says nothing" eval 'rc_is 0 && [ -z "$OUT" ] && [ "$(calls)" = $n ]'
echo new > "$D/new.csv"; chmod 640 "$D/new.csv"
sed -i "s/^# swept .*/# swept 2000-01-01/" "$STATE"
ga --quiet
t "on a later day the folders are swept again: a new file gets its entry; --quiet prints the grant" eval 'rc_is 0 && [ "$(calls)" = $((n + 1)) ] && has "^  granted hy9698 $ME/data: 1 entries" && has "^readers on " && [ "$(ue "$D/new.csv" hy9698)" = r-- ] && grep -qx "# swept $TODAY" "$STATE"'
chmod 600 "$D/results.csv"
ga --force
t "a file the lab lead closes to the group: its reader entry goes" eval 'rc_is 0 && has "^  granted hy9698 $ME/data: 0 entries set to the group.s read, 1 removed" && [ -z "$(ue "$D/results.csv" hy9698)" ]'
chmod 640 "$D/results.csv"; setfacl -n -m u:hy9698:rw- "$D/run.sh"
ga --force
t "a reader's entry with w is not this tool's: left as it is, and said" eval 'rc_is 0 && [ "$(ue "$D/run.sh" hy9698)" = rw- ] && [ "$(ue "$D/results.csv" hy9698)" = r-- ] && has "1 where hy9698 has w, not this tool.s, left as they are"'
GA_READ_CAP=3 ga --force
t "a folder with more entries than the cap: FAILED, not swept, exit 2" eval 'rc_is 2 && has "^  FAILED  reader hy9698: $ME/data holds 13 entries, more than 3; not swept" && lacks "granted hy9698"'
chmod 2710 "$V/shared/access"
ga --force
t "shared/access as on the grid (2710): ab1234 may enter it and read nothing in it" eval 'rc_is 0 && [ "$(ue "$V/shared/access" ab1234)" = --x ] && [ -z "$(ue "$V/shared/access/admin_token" ab1234)" ] && has "^  ok      shared/access is closed to other"'
chmod 2700 "$V/shared/access"
ga --force
t "closed to the group again: ab1234's --x goes with it" eval 'rc_is 0 && [ -z "$(ue "$V/shared/access" ab1234)" ]'

echo "== readers: folders that cannot be granted"
mkdir -m 2700 "$V/closed"; mkdir -m 2750 "$V/closed/inner"; mkdir -m 2750 "$V/$ME/theirs"; owns "$V/$ME/theirs" hy9698
readers "hy9698 $ME/data" "ab1234 shared/access" "cd5678 $ME/nope" "cd5678 shared/ashley" "cd5678 $ME/theirs" "cd5678 closed/inner"
ga
t "a missing folder, a link, another's folder, a closed way: each FAILED, exit 2" eval 'rc_is 2 && has "^  FAILED  reader cd5678: $ME/nope is not a plain folder" && has "^  FAILED  reader cd5678: shared/ashley is not a plain folder" && has "^  FAILED  reader cd5678: $ME/theirs belongs to hy9698, not to $ME" && has "^  FAILED  reader cd5678: the group may not enter closed, on the way to closed/inner"'
t "nothing given to cd5678 under them" eval '[ -z "$(ue "$V/closed" cd5678)" ] && [ -z "$(ue "$V/closed/inner" cd5678)" ] && [ -z "$(ue "$V/$ME/theirs" cd5678)" ]'
t "the state records the pairs all the same (applied, a check failed)" eval 'grep -qx "# read cd5678 closed/inner" "$STATE"'
rmdir "${V:?}/closed/inner" "${V:?}/closed" "${V:?}/${ME:?}/theirs"; : > "$SHIM_OWNERS"; owns "$D/theirs.csv" hy9698

echo "== readers: taking read back"
readers "ab1234 shared/access"
ga
t "a reader taken off: its entries under the folder go, and the --x on the way" eval 'rc_is 0 && has "^  revoked hy9698 $ME/data: " && has "^  revoked hy9698 $ME: its --x \(on the way to $ME/data\)" && [ -z "$(ue "$V/$ME" hy9698)" ] && [ -z "$(ue "$D" hy9698)" ] && [ -z "$(ue "$D/sub/deep.csv" hy9698)" ]'
t "but not its entry with w, and not its rwx on the root (the list)" eval '[ "$(ue "$D/run.sh" hy9698)" = rw- ] && [ "$(ue "$V" hy9698)" = rwx ]'
t "the state no longer records the pairs taken off" eval '! grep -q "^# read hy9698" "$STATE" && ! grep -q "^# read cd5678" "$STATE" && grep -qx "# read ab1234 shared/access" "$STATE"'
setfacl -n -x u:hy9698 "$D/run.sh"
readers '# none'
ga
t "the last reader taken off: its --x on the root goes, no readers' line" eval 'rc_is 0 && has "^  removed ab1234 \(was --x\)" && [ -z "$(ue "$V" ab1234)" ] && lacks "^readers on " && ! grep -q "^# read" "$STATE"'
n=$(calls); ga --force
t "no reader at all: --force does not sweep" eval 'rc_is 0 && lacks "readers. folders" && lacks "^  (ok|FAILED)  reader " && [ "$(calls)" = $((n + 1)) ]'
t "nothing of the readers' left under the owner's folder" eval '! getfacl -R -p "$V/$ME" | grep -E "^user:(hy9698|ab1234|cd5678):" >/dev/null'

echo "== readers: sources and refusals"
cp "$STATE" "$T/state.before"; n=$(calls); before=$(named)
for bad in "hy9698 ../etc" "hy9698 /etc" "hy9698 .hidden" "hy9698 data/-x" "hy9698" "hy9698 a b" "HY9698 data" "hy9698 data;rm"; do
  readers "ab1234 shared/access" "$bad"
  ga
  t "a bad reader line ($bad): refused, names line 2, no connection" eval 'rc_is 1 && has "line 2 of .* is not an AccessID and a folder" && unchanged $n'
done
export BEETHOVEN_READERS_CMD="exit 5"
ga
t "a failing readers command: refused, no connection" eval 'rc_is 1 && has "the readers command .* ended with exit 5" && unchanged $n'
unset BEETHOVEN_READERS_CMD
ga --here --roster-file "$T/roster"
t "--here with no readers file or command: the service is asked for them, no token here, refused" eval 'rc_is 1 && has "no grid_token or admin_token in the vendor folder" && unchanged $n'
ga --roster-file "$T/roster"
t "no readers file or command: the service is asked for them, no token here, refused, no connection" eval 'rc_is 1 && has "no grid_token or admin_token in the vendor folder" && unchanged $n'
readers "ab1234 shared/access"
OUT=$(SHIM_SSH_MODE=record bash "$GA" --site wayne --roster-file "$T/roster" --readers-file "$T/readers" 2>&1); RC=$?; runs=$((runs + 1))
t "the pairs travel to the grid side, with the sweep" eval 'tail -1 "$SHIM_SSH_CALLS" | grep -E "bash -s -- --apply --sweep-readers --read ab1234:shared/access /rs/rs_grp_oschome cd5678 hy9698 2>&1$" >/dev/null'
OUT=$(bash "$GA" --apply --read 'ab1234:../x' "$ROOT" hy9698 2>&1); RC=$?
t "grid side: a bad --read refused, nothing changed" eval 'rc_is 1 && has "is not an AccessID and a folder" && unchanged $((n + 1))'
# one stand-in command, two subcommands, as a person naming their own command for both lists would
export BEETHOVEN_ROSTER_CMD="bash $T/admin-stub roster" BEETHOVEN_READERS_CMD="bash $T/admin-stub readers"
STUB_READERS="ab1234 shared/access" ga
t "the readers command's pairs: applied" eval 'rc_is 0 && has "^  added   ab1234 \(--x, a reader\)" && grep -qx "# read ab1234 shared/access" "$STATE"'
n=$(calls); STUB_READERS_EXIT=1 ga --force
t "the readers command failing (a service without the reader list): refused, no connection" eval 'rc_is 1 && has "the readers command .* ended with exit 1" && [ "$(calls)" = $n ]'
export BEETHOVEN_READERS_CMD=true
roster hy9698 cd5678
ga
t "back to no reader: ab1234's --x goes" eval 'rc_is 0 && [ -z "$(ue "$V" ab1234)" ]'
unset SHIM_GROUP_OWNERS BEETHOVEN_ROSTER_CMD

echo "== readers: the whole volume (\".\")"
# "." is the root's entry alone, the group's read there: below the root the reader reads what every account
# on the list reads, which --open-volume makes what the group reads (greg, 2026-10-08). A fresh small volume,
# its tree under shared/beethoven opened as on the grid, shared/access at 2710 as on the grid, a 0600 file
# of the owner's, and a student's own folder (zq0002) holding a file the owner owns
mkvol; : > "$SHIM_OWNERS"
export SHIM_USERS="$SHIM_USERS zq0001 zq0002 zq0003" BEETHOVEN_ROSTER_CMD="cat $T/roster" BEETHOVEN_READERS_CMD="cat $T/readers"
roster zq0003 cd5678; readers '# none'
ga --open-tree
t "whole volume, fixture: the tree opened, every check ok" eval 'rc_is 0 && lacks FAILED && [ "$(named)" = "cd5678 zq0003" ]'
chmod 2710 "$V/shared/access"
chmod 2750 "$V/$ME/data"; chmod 640 "$V/$ME/data/results.csv"
echo secret > "$V/$ME/secret.txt"; chmod 600 "$V/$ME/secret.txt"
mkdir -m 2750 "$V/zq0002" "$V/zq0002/sub"; echo theirs > "$V/zq0002/notes.csv"; echo ours > "$V/zq0002/sub/ours.csv"
chmod 640 "$V/zq0002/notes.csv" "$V/zq0002/sub/ours.csv"
owns "$V/zq0002" zq0002; owns "$V/zq0002/notes.csv" zq0002; owns "$V/zq0002/sub" zq0002   # ours.csv stays the owner's
zq() { getfacl -R -p "$V" | awk -v u="user:$1:" '/^# file: / { f = substr($0, 9) } index($0, u) == 1 { print f, $0 }'; }   # ID -> each entry of its, with its path
MODES1=$(find "$V" -printf '%m %p\n' | sort)
readers "zq0001 ." "zq0003 ."
n=$(calls)
ga --dry-run
t "whole volume, dry run: the root's r-x, as would, and no walk" eval 'has "^  would add zq0001 \(r-x, a reader\)" && lacks "would grant" && [ -z "$(zq zq0001)" ] && [ "$(calls)" = $((n + 1)) ] && ! grep -q "^# read" "$STATE"'
: > "$SHIM_LOG"
ga
t "whole volume: zq0001 gets the group's read on the root (r-x), zq0003 on the list keeps rwx, exit 0" eval 'rc_is 0 && lacks FAILED && has "^  added   zq0001 \(r-x, a reader\)" && [ "$(ue "$V" zq0001)" = r-x ] && [ "$(ue "$V" zq0003)" = rwx ] && [ "$(ue "$V" cd5678)" = rwx ]'
t "whole volume: the root's entry and nothing below it, no walk, no mode changed" eval '! grep -E "^getfacl .*-R" "$SHIM_LOG" && [ "$(zq zq0001)" = "$V user:zq0001:r-x" ] && [ "$(zq zq0003)" = "$V user:zq0003:rwx" ] && [ "$(find "$V" -printf "%m %p\n" | sort)" = "$MODES1" ]'
t "whole volume: a note says what the reader reads" eval 'has "^  note    reader zq0001: all of $ROOT, read below the root as every account on the list reads it \(--open-volume opens it to them\)$"'
t "whole volume: the list read back expects the root's r-x, the root's entries ok" eval 'has "^  ok      the list read back from $ROOT is the list applied$" && has "^  ok      the root.s entries: each of the 3 "'
t "whole volume: the readers' line says it in words, then the list" eval 'has "^readers on $ROOT: zq0001 \(all of $ROOT\); zq0003 \(all of $ROOT\)$" && last_line_is_list && has "^grid access list on $ROOT: cd5678 zq0003$"'
t "whole volume: the state records \".\"" eval 'grep -qx "# read zq0001 ." "$STATE" && grep -qx "# read zq0003 ." "$STATE"'
ACLS1=$(getfacl -R -p "$V")
ga --force
t "whole volume, a second run: nothing changes, the root's entry stays r-x" eval 'rc_is 0 && lacks FAILED && lacks "^  (added|changed|removed|granted|revoked) " && [ "$(getfacl -R -p "$V")" = "$ACLS1" ]'
n=$(calls); ga
t "whole volume, unchanged the same day: no connection, the readers in words" eval 'rc_is 0 && [ "$(calls)" = $n ] && has "^readers on $ROOT: zq0001 \(all of $ROOT\) zq0003 \(all of $ROOT\)$"'
readers "zq0001 ." "zq0001 $ME/data" "zq0003 ."
ga
t "\".\" and a named folder: the folder is swept as any other, the root stays r-x" eval 'rc_is 0 && lacks FAILED && has "^  granted zq0001 $ME/data: " && [ "$(ue "$V/$ME/data/results.csv" zq0001)" = r-- ] && [ "$(ue "$V/$ME" zq0001)" = --x ] && [ "$(ue "$V" zq0001)" = r-x ]'
t "\".\" and a named folder: both on the readers' line" eval 'has "^readers on $ROOT: zq0001 \(all of $ROOT, $ME/data\); zq0003 \(all of $ROOT\)$"'
readers "zq0001 ." "zq0003 ."
ga
t "the named folder taken off beside \".\": taken back, the --x on the way too, the root r-x" eval 'rc_is 0 && lacks FAILED && has "^  revoked zq0001 $ME/data: " && has "^  revoked zq0001 $ME: its --x" && [ "$(zq zq0001)" = "$V user:zq0001:r-x" ]'
readers "zq0001 $ME/data"
ga
t "\".\" taken off, a named folder kept: the root's entry back to --x, the folder granted, nothing else" eval 'rc_is 0 && lacks FAILED && has "^  changed zq0001: r-x -> --x" && lacks "revoked zq0001 all of" && [ "$(ue "$V" zq0001)" = --x ] && [ "$(ue "$V/$ME/data/results.csv" zq0001)" = r-- ] && has "^  ok      the list read back from $ROOT is the list applied$"'
t "\".\" taken off zq0003, on the list: its rwx on the root stays, nothing else to take back" eval 'lacks "revoked zq0003" && [ "$(zq zq0003)" = "$V user:zq0003:rwx" ]'
readers '# none'
ga
t "every folder taken off: zq0001's entries go, the root's too" eval 'rc_is 0 && lacks FAILED && has "^  removed zq0001 \(was --x\)" && [ -z "$(zq zq0001)" ] && lacks "^readers on " && ! grep -q "^# read" "$STATE"'
# the root's entry for "." is the group's read there, not a fixed r-x: a root whose group may enter and
# not list (g::-wx, the mask still rwx) gives a reader of "." enter only
setfacl -n -m g::-wx "$V"
readers "zq0001 ."
ga
t "a root whose group entry lacks r: a reader of \".\" gets --x there, as the group has it" eval 'rc_is 0 && lacks FAILED && has "^  added   zq0001 \(--x, a reader\)" && [ "$(ue "$V" zq0001)" = --x ] && has "^  ok      the list read back from $ROOT is the list applied$"'
ga --force
t "and a second run leaves the root at --x" eval 'rc_is 0 && lacks FAILED && lacks "^  (added|changed|removed|granted|revoked) " && [ "$(ue "$V" zq0001)" = --x ]'
setfacl -n -m g::rwx "$V"
# an older state may keep "# unread <id> ." (a taking back of the old whole-volume sweep that did not
# finish): there is nothing below the root to take back, so it goes at the next sweep
readers '# none'
ga
printf '# unread zq0003 .\n' >> "$STATE"; sed -i "s/^# swept .*/# swept 2000-01-01/" "$STATE"
ga
t "an old \"# unread <id> .\": nothing taken back, no longer kept" eval 'rc_is 0 && lacks FAILED && lacks "revoked zq0003" && ! grep -q "^# unread" "$STATE"'

echo "== --open-volume: other reads what the group reads, below the gate"
# what greg asked on 2026-10-08: everything of his the group reads, his own folder included, readable by
# every account on the list, and nothing writable by them. A tree with what must stay closed beside it
mkvol; : > "$SHIM_OWNERS"; readers '# none'
ga --open-tree
chmod 2710 "$V/shared/access"
D=$V/$ME; mkdir -p "$D/runs/r1" "$D/imaging/raw" "$D/images" "$D/tmpw" "$D/sticky" "$D/half" "$L/hpcworker/.incoming-x"
echo token > "$D/runs/r1/job.token"; chmod 600 "$D/runs/r1/job.token"; chmod 2700 "$D/runs/r1"
echo conn > "$D/runs/connection.json"; chmod 640 "$D/runs/connection.json"; chmod 2750 "$D/runs"
echo scan > "$D/imaging/raw/a.dcm"; chmod 400 "$D/imaging/raw/a.dcm"; chmod 500 "$D/imaging/raw"; chmod 700 "$D/imaging"
echo sif > "$D/images/a.sif"; chmod 640 "$D/images/a.sif"; chmod 2750 "$D/images"
echo run > "$D/images/run.sh"; chmod 750 "$D/images/run.sh"
echo grp > "$D/images/g.txt"; chmod 600 "$D/images/g.txt"; setfacl -m g::r-- "$D/images/g.txt"   # the group's read through the ACL
echo named > "$D/images/n.txt"; chmod 600 "$D/images/n.txt"; setfacl -m "g:$GRP:r--" "$D/images/n.txt"   # through the group's named entry
echo w > "$D/tmpw/f"; chmod 640 "$D/tmpw/f"; chmod 2777 "$D/tmpw"
echo s > "$D/sticky/f"; chmod 640 "$D/sticky/f"; chmod 3777 "$D/sticky"
mkdir -p "$D/logs" "$D/work"; echo l > "$D/logs/x.log"; chmod 666 "$D/logs/x.log"; chmod 2750 "$D/logs"   # other may write what it cannot reach yet
echo r > "$D/work/run.sh"; chmod 750 "$D/work/run.sh"; chmod 2777 "$D/work"
mkdir "$D/half/in"; echo h > "$D/half/in/f"; chmod 640 "$D/half/in/f"; chmod 2750 "$D/half/in"
chmod 2740 "$D/half"; setfacl -n -m m::rwx "$D/half"   # the mask lets x through, the group's entry has none
echo stage > "$L/hpcworker/.incoming-x/f"; chmod 640 "$L/hpcworker/.incoming-x/f"; chmod 2750 "$L/hpcworker/.incoming-x"
ln -s ../../shared/access/admin_token "$D/token.link"
mkdir -m 2750 "$V/zq0002"; echo theirs > "$V/zq0002/notes.csv"; chmod 640 "$V/zq0002/notes.csv"; owns "$V/zq0002" zq0002; owns "$V/zq0002/notes.csv" zq0002
chmod 2750 "$D"
om() { stat -c %A "$1" | cut -c8-10; }   # PATH -> other's three places
MODES2=$(find "$V/shared/access" "$V/zq0002" "$D/runs/r1" "$D/imaging" "$L/hpcworker/.incoming-x" -printf '%m %p\n' | sort)
n=$(calls)
ga --here --open-volume
t "open-volume: refused outside a job step on a compute node, nothing changed" eval 'rc_is 1 && has "runs in a job step on a compute node" && [ "$(om "$D")" = --- ]'
OUT=$(SLURM_JOB_ID=1 bash "$GA" --site wayne --root "$ROOT" --here --open-volume 2>&1); RC=$?; runs=$((runs + 1))
t "open-volume: a job with no step on a node (salloc's own shell) is refused too" eval 'rc_is 1 && has "runs in a job step on a compute node" && [ "$(om "$D")" = --- ]'
OUT=$(bash "$GA" --site wayne --root "$ROOT" --open-volume 2>&1); RC=$?   # refused before the log is opened: no run
t "open-volume: refused without --here (it would run on the login node), no connection" eval 'rc_is 1 && has "goes with --here" && [ "$(calls)" = $n ] && [ "$(om "$D")" = --- ]'
OUT=$(SLURMD_NODENAME=node1 bash "$GA" --site wayne --root "$ROOT" --here --open-volume --dry-run 2>&1); RC=$?; runs=$((runs + 1))
t "open-volume, dry run: says what it would close to writing and open, changes nothing" eval 'has "^  would open-volume: 4 entries no longer writable by other$" && has "^  would open-volume: [0-9]+ entries opened to other" && [ "$(om "$D")" = --- ] && [ "$(om "$D/images/a.sif")" = --- ] && [ "$(om "$D/logs/x.log")" = rw- ]'
: > "$SHIM_LOG"
OUT=$(SLURMD_NODENAME=node1 bash "$GA" --site wayne --root "$ROOT" --here --open-volume 2>&1); RC=$?; runs=$((runs + 1))
t "open-volume: write taken first, then opened and read back, exit 0" eval 'rc_is 0 && lacks FAILED && has "^  open-volume: 4 entries no longer writable by other$" && has "^  open-volume: [0-9]+ entries opened to other for reading as the group reads them" && has "^  ok      the volume: other reads what the group reads below the gate, and writes nothing of $ME.s \([0-9]+ opened now, 4 closed to writing, read back\)$"'
t "open-volume: what other could write behind a closed folder is read only before the folder opens" eval '[ "$(om "$D/logs")" = r-x ] && [ "$(om "$D/logs/x.log")" = r-- ] && [ "$(om "$D/work")" = r-x ] && [ "$(om "$D/work/run.sh")" = r-x ]'
t "open-volume: the owner's folder and what the group reads in it: r-x or r--, never w" eval '[ "$(om "$D")" = r-x ] && [ "$(om "$D/runs")" = r-x ] && [ "$(om "$D/runs/connection.json")" = r-- ] && [ "$(om "$D/images/a.sif")" = r-- ] && [ "$(om "$D/images/run.sh")" = r-x ] && [ "$(om "$D/data/results.csv")" = r-- ] && ! find "$V" -mindepth 1 ! -type l -perm -0002 | grep . >/dev/null'
t "open-volume: the group's read through its ACL entry or its named entry counts" eval '[ "$(om "$D/images/g.txt")" = r-- ] && [ "$(om "$D/images/n.txt")" = r-- ]'
t "open-volume: a job token, a run folder, the locked scans, shared/access, staging, a student's folder: untouched" eval '[ "$(om "$D/runs/r1/job.token")" = --- ] && [ "$(find "$V/shared/access" "$V/zq0002" "$D/runs/r1" "$D/imaging" "$L/hpcworker/.incoming-x" -printf "%m %p\n" | sort)" = "$MODES2" ]'
t "open-volume: folders others could write, sticky or not: write taken, then opened with what is in them" eval '[ "$(om "$D/tmpw")" = r-x ] && [ "$(om "$D/tmpw/f")" = r-- ] && [ "$(om "$D/sticky")" = r-t ] && [ "$(om "$D/sticky/f")" = r-- ]'
t "open-volume: below a folder the group may not enter (its entry, the mask aside): nothing opened" eval '[ "$(om "$D/half")" = r-- ] && [ "$(om "$D/half/in")" = --- ] && [ "$(om "$D/half/in/f")" = --- ]'
t "open-volume: the root keeps other::---, no default entry, the link not followed" eval '[ "$(stat -c %A "$V")" = drwxrws--T ] && ! getfacl -R -p "$D" | grep "^default:" >/dev/null && [ "$(om "$V/shared/access/admin_token")" = --- ]'
t "open-volume: setfacl -P, never on shared/access or the student's folder" eval 'grep -q "^setfacl -P -n -m o::" "$SHIM_LOG" && ! grep -E "^setfacl .*($V/shared/access|$V/zq0002)" "$SHIM_LOG"'
t "open-volume: the folders left closed near the top, named" eval 'has "^  open-volume: folders left closed near the top .*: .*$ME/imaging" && has "$ME/runs/r1" && lacks "others may write it\)"'
t "open-volume: the owner's folder, read and not written by other, ok" eval 'has "^  ok      $ME \(the owner.s folder\) is not writable by other \(drwxr-sr-x\)$" && has "^  ok      shared/access is closed to other"'
ACLS4=$(getfacl -R -p "$V"); : > "$SHIM_LOG"
OUT=$(SLURMD_NODENAME=node1 bash "$GA" --site wayne --root "$ROOT" --here --open-volume 2>&1); RC=$?; runs=$((runs + 1))
t "open-volume again: nothing to open, nothing changed" eval 'rc_is 0 && has "^  open-volume: 0 entries opened" && lacks "no longer writable" && ! grep -q "^setfacl " "$SHIM_LOG" && [ "$(getfacl -R -p "$V")" = "$ACLS4" ]'
OUT=$(SLURMD_NODENAME=node1 bash "$GA" --site wayne --root "$ROOT" --here --open-volume --quiet 2>&1); RC=$?; runs=$((runs + 1))
t "open-volume --quiet with nothing to open: says nothing" eval 'rc_is 0 && [ -z "$OUT" ]'
echo new > "$D/images/new.csv"; chmod 640 "$D/images/new.csv"
mkdir -p "$T/real"; ln -sf "$T/bin/acl.shim" "$T/real/setfacl"; rm "$T/bin/setfacl"
printf '%s\n' '#!/usr/bin/env bash' 'a=() n=0' \
  'while [ $# -gt 0 ]; do case "$1" in -m|-x) a+=("$1" "$2"); shift 2;; -*) a+=("$1"); shift;; *) [ "$1" = "$SHIM_DROP" ] || { a+=("$1"); n=$((n + 1)); }; shift;; esac; done' \
  "[ \$n -gt 0 ] || exit 0; exec '$T/real/setfacl' \"\${a[@]}\"" > "$T/bin/setfacl"
chmod 755 "$T/bin/setfacl"
OUT=$(SHIM_DROP="$D/images/new.csv" SLURMD_NODENAME=node1 bash "$GA" --site wayne --root "$ROOT" --here --open-volume 2>&1); RC=$?; runs=$((runs + 1))
t "a setfacl that skips an entry and says nothing: the read-back finds it, FAILED, exit 2" eval 'rc_is 2 && has "^  FAILED  the volume: 1 entries still closed to other after setfacl" && [ "$(om "$D/images/new.csv")" = --- ]'
rm "$T/bin/setfacl"; ln -s acl.shim "$T/bin/setfacl"
roster zq0003 cd5678; readers "zq0001 ."
ga
t "then a reader of \".\": one entry on the root, and it reads what the list reads" eval 'rc_is 0 && lacks FAILED && [ "$(zq zq0001)" = "$V user:zq0001:r-x" ]'
cp "$STATE" "$T/state.before"; n=$(calls); before=$(named)
for bad in "zq0001 ./x" "zq0001 .." "zq0001 /" "zq0001 ./" "zq0001 x/." "zq0001 . x"; do
  readers "zq0001 ." "$bad"
  ga
  t "a bad spelling of the root ($bad): refused, names line 2, no connection" eval 'rc_is 1 && has "line 2 of .* is not an AccessID and a folder" && unchanged $n'
done
for bad in "zq0001:./x" "zq0001:.." "zq0001:/" "zq0001:" "zq0001:./"; do
  OUT=$(bash "$GA" --apply --sweep-readers --read "$bad" "$ROOT" zq0003 cd5678 2>&1); RC=$?
  t "grid side: --read $bad refused, nothing changed" eval 'rc_is 1 && has "is not an AccessID and a folder" && unchanged $n'
done
export BEETHOVEN_READERS_CMD=true; unset BEETHOVEN_ROSTER_CMD

echo "== the access service"
# The stand-in: a python3 HTTPS server on 127.0.0.1 (an ephemeral port, a certificate of its own that
# CURL_CA_BUNDLE names to curl) that compares the Authorization header byte for byte with the two tokens
# the test wrote (the admin token, and the grid token, which the service takes for these two routes too),
# writes which one it saw to a file of its own (the word admin or grid, never the token), needs no
# Origin (a program sends none), and answers the two routes with EXACTLY the bodies
# of the access service's published vectors admin-roster-txt and admin-readers-txt (in mode empty,
# admin-roster-txt-empty), copied here as data; test_access_contract.py pins the export itself once
# interface/access/ is pulled. The mode is read from a file at each request: ok, empty, 401, 403, 404 (a
# service deployed before the routes), html (a sign-in page in front). An unreachable service is a closed
# loopback port. No proxy variable may stand between curl and the loopback.
unset BEETHOVEN_ROSTER_CMD BEETHOVEN_READERS_CMD http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
cat > "$T/svc.py" <<'PY'
import http.server, os, ssl, sys
token_file, grid_file, seen_file, mode_file, port_file, cert, key = sys.argv[1:8]
ROSTER = "ab1234\nzz9999\n"                                                   # vectors/admin-roster-txt.json
READERS = "cd5678 shared/data\nrd5678 lab\nrd5678 shared/access\nzq0006 .\n"  # vectors/admin-readers-txt.json
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, status, ctype, body):
        data = body.encode("utf-8")
        self.send_response(status); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        with open(mode_file) as fh: mode = fh.read().strip()
        with open(token_file) as fh: token = fh.read().strip()
        with open(grid_file) as fh: grid = fh.read().strip()
        if mode == "404": return self.answer(404, "application/json", '{"error":"no such route"}')
        if mode == "html": return self.answer(200, "text/html; charset=utf-8", "<html><body>Sign in</body></html>")
        if mode == "403": return self.answer(403, "application/json", '{"error":"origin not allowed"}')
        if mode == "500": return self.answer(500, "text/plain; charset=utf-8", "zq0001\nzq0002\n")   # a list-shaped body that must not count
        if mode == "upper" and self.path == "/admin/roster.txt": return self.answer(200, "Text/Plain; Charset=UTF-8", ROSTER)
        sent = self.headers.get("Authorization")
        seen = "admin" if sent == "Bearer " + token else "grid" if grid and sent == "Bearer " + grid else ""
        if mode == "401" or not seen:
            return self.answer(401, "application/json", '{"error":"admin token missing or wrong"}')
        with open(seen_file, "a") as fh: fh.write(seen + "\n")
        if self.path == "/admin/roster.txt": return self.answer(200, "text/plain; charset=utf-8", "" if mode == "empty" else ROSTER)   # empty: vectors/admin-roster-txt-empty.json
        if self.path == "/admin/readers.txt": return self.answer(200, "text/plain; charset=utf-8", READERS)
        self.answer(404, "application/json", '{"error":"no such route"}')
srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(port_file + ".part", "w") as fh: fh.write(str(srv.server_address[1]))
os.rename(port_file + ".part", port_file)
srv.serve_forever()
PY
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/svc.key" -out "$T/svc.crt" -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 >/dev/null 2>&1 \
  || { fail=$((fail + 1)); echo "FAIL openssl could not make the stand-in's certificate"; }
TOKEN=standin+admin/token-4f9c2e71b0d8=   # base64's + / = as openssl rand -base64 makes the admin token
GTOKEN=standin-grid-token-7a1d93c4e5f6
printf '%s\n' "$TOKEN" > "$T/svc.token"; printf '%s\n' "$GTOKEN" > "$T/svc.gridtoken"; : > "$T/svc.seen"; echo ok > "$T/svc.mode"
python3 "$T/svc.py" "$T/svc.token" "$T/svc.gridtoken" "$T/svc.seen" "$T/svc.mode" "$T/svc.port" "$T/svc.crt" "$T/svc.key" & SVC_PID=$!
for _ in $(seq 1 100); do [ -s "$T/svc.port" ] && break; sleep 0.1; done
[ -s "$T/svc.port" ] || { fail=$((fail + 1)); echo "FAIL the stand-in service did not start"; }
PORT=$(cat "$T/svc.port"); SVC="https://127.0.0.1:$PORT"
mkdir -p "$T/tmp"
export CURL_CA_BUNDLE="$T/svc.crt" BEETHOVEN_SERVICE_URL="$SVC" TMPDIR="$T/tmp"   # TMPDIR: where the tool's run folder goes, so a leftover is seen
mode() { echo "$1" > "$T/svc.mode"; }
# curl first on PATH records its arguments, one line per request, and beside them ($SHIM_CURL_META) the
# mode of the configuration file it is handed (-K), the mode and path of $TMPDIR, and which agent markers
# and token variables reached it; then it runs the real one. curl --version (a chain's first job says
# which curl its node has) is no request and is not recorded
REAL_CURL=$(command -v curl)
printf '%s\n' '#!/usr/bin/env bash' \
  "[ \"\${1:-}\" != --version ] || exec '$REAL_CURL' --version" \
  'p=""; for a in "$@"; do [ "$p" != -K ] || printf "config-file-mode %s\n" "$(stat -c %a -- "$a")" >> "$SHIM_CURL_META"; p=$a; done' \
  '[ -z "${TMPDIR:-}" ] || printf "tmpdir %s %s\n" "$(stat -c %a -- "$TMPDIR")" "$TMPDIR" >> "$SHIM_CURL_META"' \
  'm=""; for v in CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN; do [ -z "${!v:-}" ] || m="$m $v"; done; printf "markers%s\n" "$m" >> "$SHIM_CURL_META"' \
  'printf "%q " "$@" >> "$SHIM_CURL_CALLS"; printf "\n" >> "$SHIM_CURL_CALLS"' \
  "exec '$REAL_CURL' \"\$@\"" > "$T/bin/curl"
chmod 755 "$T/bin/curl"; export SHIM_CURL_CALLS="$T/curl.calls" SHIM_CURL_META="$T/curl.meta"; : > "$SHIM_CURL_CALLS"; : > "$SHIM_CURL_META"
SVC_OUT="$T/svc.out"; : > "$SVC_OUT"
gs() { ga "$@"; printf '%s\n' "$OUT" >> "$SVC_OUT"; }   # every run's output (stdout and stderr) kept for the token check
curls() { grep -c . "$SHIM_CURL_CALLS"; }   # the requests made: one argv line each
mkvol; : > "$SHIM_OWNERS"
mkdir -m 2750 "$V/shared/data" "$V/lab"   # the folders the readers vector names
roster zq0003
ga --roster-file "$T/roster" --readers-file /dev/null --open-tree
t "service, fixture: the tree opened with a file as the source, every check ok" eval 'rc_is 0 && lacks FAILED && [ "$(named)" = zq0003 ]'
OUT=$(bash "$GA" --help 2>&1); RC=$?
t "--help names the service and its address as the source, and no tool of another repository" eval 'rc_is 0 && has "https://beethoven-access.openspineconsortium.workers.dev" && has "admin_token" && lacks "admin.mjs"'
cp "$STATE" "$T/state.before"; n=$(calls); before=$(named)
gs --dry-run --force
t "service: no grid_token or admin_token in the vendor folder: refused in words naming both, nothing sent, nothing changed" eval 'rc_is 1 && has "^grid_access: no grid_token or admin_token in the vendor folder \($T/vendor\): the access service.s token is one line in either \(grid_token, made on the admin page, reads only the two lists; admin_token is the maintainer.s\); nothing changed$" && [ "$(curls)" = 0 ] && unchanged $n'
printf '%s\r\n' "$TOKEN" > "$T/vendor/admin_token"; chmod 644 "$T/vendor/admin_token"
gs --dry-run --force
t "service: admin_token readable by others (0644): refused naming the fix, nothing sent" eval 'rc_is 1 && has "^grid_access: $T/vendor/admin_token is readable by group or other \(mode 644\); make it yours alone first: chmod 600 $T/vendor/admin_token; nothing changed$" && [ "$(curls)" = 0 ] && unchanged $n'
chmod 600 "$T/vendor/admin_token"; printf '  \r\n' > "$T/vendor/admin_token"
gs --dry-run --force
t "service: an empty admin_token: refused, nothing sent" eval 'rc_is 1 && has "admin_token is empty: the access service.s token is one line in it; nothing changed" && [ "$(curls)" = 0 ] && unchanged $n'
printf '%s\r\n' "$TOKEN" > "$T/vendor/admin_token"   # with a CR, which must not reach the header
gs --dry-run --force
t "service, dry run: both lists from the stand-in (the token's CR dropped), the vectors' ids and pairs parsed, the grid side asked" eval 'has "^grid access: 2 ids from the access service \(127.0.0.1:$PORT\) and 3 readers from the access service \(127.0.0.1:$PORT\) -> wsu-grid:$ROOT, dry run$" && has "would add ab1234$" && has "^  skipped zz9999" && has "would add cd5678 \(--x, a reader\)" && has "^  skipped rd5678" && has "^  skipped zq0006" && has "^  would grant cd5678 shared/data" && [ "$(calls)" = $((n + 1)) ]'
t "service, dry run: two requests, nothing changed, no state" eval '[ "$(curls)" = 2 ] && grep -q -- "$SVC/admin/roster.txt " "$SHIM_CURL_CALLS" && grep -q -- "$SVC/admin/readers.txt " "$SHIM_CURL_CALLS" && [ "$(named)" = "$before" ] && cmp -s "$STATE" "$T/state.before"'
# the token's mode where WSL shows a Windows drive without file modes (every file 0777 there, chmod ignored):
# the scheduled task's vendor folder is on C:. GA_PROC stands in for /proc
chmod 644 "$T/vendor/admin_token"; mkdir -p "$T/proc"; VREAL=$(readlink -f "$T/vendor")
echo "Linux version 5.15.153.1-microsoft-standard-WSL2 (root@buildhost) (gcc)" > "$T/proc/version"
wslmounts() { printf '%s\n' "rootfs / ext4 rw 0 0" "C:\\134 $VREAL 9p rw,noatime,dirsync,aname=drvfs;path=C:\\;uid=1000;gid=1000;${1}symlinkroot=/mnt/,mmap,access=client,trans=fd 0 0" > "$T/proc/mounts"; }
wslmounts ""; c=$(curls); GA_PROC="$T/proc" gs --dry-run --force
t "service: admin_token 0644 on a WSL Windows drive without file modes: its mode not checked, said so, both lists fetched" eval 'lacks "readable by group or other" && has "^note: $T/vendor/admin_token is on a Windows drive WSL shows without file modes, so its mode is not checked" && has "^grid access: 2 ids from the access service" && [ "$(curls)" = $((c + 2)) ]'
wslmounts "metadata;"; c=$(curls); GA_PROC="$T/proc" gs --dry-run --force
t "service: the same drive mounted with metadata (real modes): 0644 refused, nothing sent" eval 'rc_is 1 && has "admin_token is readable by group or other \(mode 644\)" && lacks "^note: .*Windows drive" && [ "$(curls)" = $c ]'
wslmounts ""; echo "Linux version 6.8.0-1021-generic (buildd@host) (gcc)" > "$T/proc/version"; c=$(curls); GA_PROC="$T/proc" gs --dry-run --force
t "service: not WSL, whatever the mounts say: 0644 refused, nothing sent" eval 'rc_is 1 && has "admin_token is readable by group or other \(mode 644\)" && [ "$(curls)" = $c ]'
# a linked admin_token is judged by the file it names, which is what the refusal's chmod changes
mv "$T/vendor/admin_token" "$T/token.real"; ln -s "$T/token.real" "$T/vendor/admin_token"; c=$(curls); gs --dry-run --force
t "service: admin_token a link to a 0644 file: refused with the file's mode" eval 'rc_is 1 && has "admin_token is readable by group or other \(mode 644\)" && [ "$(curls)" = $c ]'
chmod 600 "$T/token.real"; c=$(curls); gs --dry-run --force
t "service: admin_token a link to a 0600 file: accepted, both lists fetched" eval 'lacks "readable by group or other" && has "^grid access: 2 ids from the access service" && [ "$(curls)" = $((c + 2)) ]'
rm -f "$T/vendor/admin_token"; mv "$T/token.real" "$T/vendor/admin_token"; chmod 600 "$T/vendor/admin_token"
gs
t "service: applied as from any source; the unknown ids recorded, the pair of the known reader only" eval 'rc_is 0 && lacks FAILED && has "^  added   ab1234$" && has "^  removed zq0003 " && has "^  added   cd5678 \(--x, a reader\)" && [ "$(named)" = "ab1234 cd5678" ] && [ "$(state_ids)" = ab1234 ] && grep -qx "# unknown zz9999 $TODAY" "$STATE" && grep -qx "# read cd5678 shared/data" "$STATE" && ! grep -q "^# read \(rd5678\|zq0006\)" "$STATE"'
t "service: the readers' line and the list, as from any source" eval 'has "^readers on $ROOT: cd5678 \(shared/data\)$" && last_line_is_list && has "^grid access list on $ROOT: ab1234$"'
n=$(calls); gs
t "service: unchanged since: fetched again, not connected" eval 'rc_is 0 && has "not connecting" && [ "$(calls)" = $n ]'
gs --quiet
t "service: --quiet says nothing when unchanged" eval 'rc_is 0 && [ -z "$OUT" ] && [ "$(calls)" = $n ]'
BEETHOVEN_SERVICE_URL=https://127.0.0.1:1 gs --service "$SVC/" --dry-run --force
t "service: --service (a trailing slash allowed) comes before \$BEETHOVEN_SERVICE_URL" eval 'rc_is 0 && has "from the access service \(127.0.0.1:$PORT\)" && [ "$(calls)" = $((n + 1)) ]'
gs --roster-file "$T/roster" --dry-run --force
t "service: a file for one list, the service for the other" eval 'has "^grid access: 1 ids from the file $T/roster and 3 readers from the access service \(127.0.0.1:$PORT\) ->"'
echo "-- the service's refusals: nothing changes"
cp "$STATE" "$T/state.before"; n=$(calls); before=$(named)
printf '%s\n' not-the-token > "$T/vendor/admin_token"
c=$(curls); gs --force
t "service: a token the service does not know (401): refused naming the fix, one request, no connection, nothing changed" eval 'rc_is 1 && has "^grid_access: the access service \(127.0.0.1:$PORT\) did not accept the token for the approved list \(HTTP 401\): check admin_token in the vendor folder \($T/vendor\); nothing changed$" && [ "$(curls)" = $((c + 1)) ] && unchanged $n'
printf '%s\r\n' "$TOKEN" > "$T/vendor/admin_token"
mode 403; gs --force
t "service: 403: refused as the token not accepted" eval 'rc_is 1 && has "did not accept the token for the approved list \(HTTP 403\)" && unchanged $n'
mode 404; c=$(curls); gs --force
t "service: a service deployed before the routes (404): refused, says to deploy, no second try" eval 'rc_is 1 && has "^grid_access: the access service \(127.0.0.1:$PORT\) does not give the approved list yet \(HTTP 404\): deploy the service; nothing changed$" && [ "$(curls)" = $((c + 1)) ] && unchanged $n'
mode html; gs --force
t "service: a page in front (200 text/html): refused as not text" eval 'rc_is 1 && has "^grid_access: the access service \(127.0.0.1:$PORT\) answered the approved list as text/html; charset=utf-8, not as text: a sign-in page or another service stands in front of it; nothing changed$" && unchanged $n'
mode 500; c=$(curls); gs --force
t "service: an error (HTTP 500) with a list-shaped body: refused, the body not taken, no second try" eval 'rc_is 1 && has "^grid_access: the access service \(127.0.0.1:$PORT\) answered HTTP 500 for the approved list; nothing changed$" && [ "$(curls)" = $((c + 1)) ] && unchanged $n'
mode upper; gs --dry-run --force
t "service: 200 Text/Plain in capitals is plain text (a media type has no case)" eval 'lacks "not as text" && has "^grid access: 2 ids from the access service"'
n=$(calls)   # that dry run asked the grid side
mode ok
c=$(curls); gs --force --service https://127.0.0.1:1
t "service: a closed port: refused naming the host, after two more tries" eval 'rc_is 1 && has "^grid_access: the access service \(127.0.0.1:1\) could not be reached for the approved list \(curl: \(7\) .*127.0.0.1.*\); nothing changed$" && [ "$(curls)" = $((c + 3)) ] && unchanged $n'
mode empty; gs
t "service: an empty approved list (the empty-roster vector): refused without --force, naming the source" eval 'rc_is 1 && has "^grid_access: the access service \(127.0.0.1:$PORT\) gave no AccessID; applying that would shut every student out of $ROOT" && unchanged $n'
gs --force
t "service: an empty approved list with --force: applied, (none); the reader stays" eval 'rc_is 0 && [ "$(named)" = cd5678 ] && has "^grid access list on $ROOT: \(none\)$" && [ -z "$(state_ids)" ]'
mode ok; gs
t "service: back to the vector's list" eval 'rc_is 0 && has "^  added   ab1234$" && [ "$(state_ids)" = ab1234 ]'
n=$(calls); c=$(curls)
for bad in "http://127.0.0.1:$PORT" "$SVC/admin" "$SVC/admin/roster.txt" "https://127.0.0.1:$PORT?x" "https://a b" "beethoven-access.openspineconsortium.workers.dev"; do
  gs --service "$bad" --force
  t "service: a bad address ($bad): refused, nothing sent" eval 'rc_is 1 && has "must be https:// and a host name of plain characters, with nothing after it" && [ "$(curls)" = $c ] && [ "$(calls)" = $n ]'
done
echo "-- the grid token: read before admin_token when it is there"
OUT=$(bash "$GA" --help 2>&1); RC=$?
t "--help names grid_token before admin_token, and the chain's two commands" eval 'rc_is 0 && has "grid_token when that file is there, else admin_token" && has "tools/grid_access.sh --watch \[--every 15\]" && has "tools/grid_access.sh --unwatch"'
cp "$STATE" "$T/state.before"; n=$(calls); before=$(named)
printf '%s\n' "$GTOKEN" > "$T/vendor/grid_token"; chmod 600 "$T/vendor/grid_token"
c=$(curls); : > "$T/svc.seen"; gs --dry-run --force
t "grid token: preferred over admin_token, both lists asked with it (the stand-in saw it twice)" eval 'has "^grid access: 2 ids from the access service \(127.0.0.1:$PORT\)" && [ "$(curls)" = $((c + 2)) ] && [ "$(tr "\n" " " < "$T/svc.seen")" = "grid grid " ]'
cp "$STATE" "$T/state.before"; n=$(calls)
printf '%s\n' not-the-grid-token > "$T/vendor/grid_token"
c=$(curls); gs --force
t "grid token: one the service does not know (401): refused naming grid_token, admin_token not tried" eval 'rc_is 1 && has "^grid_access: the access service \(127.0.0.1:$PORT\) did not accept the token for the approved list \(HTTP 401\): check grid_token in the vendor folder \($T/vendor\); nothing changed$" && [ "$(curls)" = $((c + 1)) ] && unchanged $n'
printf '%s\n' "$GTOKEN" > "$T/vendor/grid_token"; chmod 644 "$T/vendor/grid_token"
c=$(curls); gs --force
t "grid token: readable by others (0644): refused naming grid_token and the fix, nothing sent" eval 'rc_is 1 && has "^grid_access: $T/vendor/grid_token is readable by group or other \(mode 644\); make it yours alone first: chmod 600 $T/vendor/grid_token; nothing changed$" && [ "$(curls)" = $c ] && unchanged $n'
chmod 600 "$T/vendor/grid_token"; printf ' \r\n' > "$T/vendor/grid_token"
gs --force
t "grid token: an empty grid_token: refused naming it, nothing sent, admin_token not used instead" eval 'rc_is 1 && has "^grid_access: $T/vendor/grid_token is empty: the access service.s token is one line in it; nothing changed$" && [ "$(curls)" = $c ] && unchanged $n'
for bad in 'quo"te' 'back\slash' 'two words' 'semi;colon'; do
  printf '%s\n' "$bad" > "$T/vendor/grid_token"
  gs --force
  t "grid token: a first line no bearer token has ($bad): refused naming the characters, nothing sent" eval 'rc_is 1 && has "^grid_access: $T/vendor/grid_token does not hold a token: its first line must be the token alone, letters, digits and - . _ ~ \+ / \(and = at its end\), as the admin page and the service make it; nothing changed$" && [ "$(curls)" = $c ] && unchanged $n'
done
ln -s "$T/no-such-token" "$T/vendor/grid_token.link"; rm "$T/vendor/grid_token"; mv "$T/vendor/grid_token.link" "$T/vendor/grid_token"
gs --force
t "grid token: a link to nothing is still grid_token: cannot read it, admin_token not used instead" eval 'rc_is 1 && has "^grid_access: cannot read $T/vendor/grid_token; nothing changed$" && [ "$(curls)" = $c ] && unchanged $n'
rm "$T/vendor/grid_token"; : > "$T/svc.seen"
gs --dry-run --force
t "without grid_token, admin_token as before" eval 'has "^grid access: 2 ids from the access service" && [ "$(tr "\n" " " < "$T/svc.seen")" = "admin admin " ]'
echo "-- the token leaves its file only for curl's configuration file"
# -K FILE, which every curl reads (CentOS 7's 7.29 sends nothing for -H @FILE), after -q, so no ~/.curlrc adds to it
t "service: every request is curl -q -sS --max-time 60 -K <the run's own configuration file>, never a token" eval '! grep -v -- "^-q -sS --max-time 60 -K $T/tmp/grid_access\.[A-Za-z0-9]*/curl\.config -o " "$SHIM_CURL_CALLS" >/dev/null && ! grep -F -e "$TOKEN" -e not-the-token -e "$GTOKEN" -e not-the-grid-token "$SHIM_CURL_CALLS" >/dev/null'
t "service: the configuration file was 0600 at every request" eval '[ "$(grep -c "^config-file-mode " "$SHIM_CURL_META")" = "$(curls)" ] && ! grep "^config-file-mode " "$SHIM_CURL_META" | grep -v "^config-file-mode 600$" >/dev/null'
t "service: the run's folder is gone after every run" eval '[ -z "$(ls -A "$T/tmp")" ]'
t "service: neither token is in any output, nor in the log or the state" eval '! grep -F -e "$TOKEN" -e not-the-token -e "$GTOKEN" -e not-the-grid-token "$SVC_OUT" "$LOG" "$STATE" >/dev/null'
t "service: the log names the source and the refusals, in words" eval 'grep -q "refused: the access service (127.0.0.1:$PORT) did not accept the token" "$LOG" && grep -q "refused: the access service (127.0.0.1:1) could not be reached" "$LOG"'
export BEETHOVEN_SERVICE_URL=https://127.0.0.1:1 BEETHOVEN_READERS_CMD=true; unset CURL_CA_BUNDLE TMPDIR

echo "== the log"
t "one log line per run ($runs runs)" eval '[ "$(wc -l < "$LOG" | tr -d " ")" = "$runs" ]'
t "the log names an unknown id once it is skipped" eval 'grep -q "1 unknown to the grid: zz0000" "$LOG"'

echo "== the chain on the cluster: --watch, --unwatch and each job (--tick)"
# sbatch, squeue, sacct and scancel are tests/shim/slurm, the scheduler test_grid_ci.sh uses: it runs
# nothing, records each call, refuses a script or a -D outside $T, and its sbatch writes a warning to
# stderr beside every job it takes. A job "runs" when the test runs its copied script the way Slurm
# would: in its -D folder, with its arguments and SLURM_JOB_ID, its output appended to its log. The
# stand-in service still answers; GITHUB_TOKEN and GH_TOKEN are markers no scheduler call may see, and
# BEETHOVEN_READERS_CMD (true) and BEETHOVEN_SERVICE_URL (a closed port) are still set from above, as a
# shell's own settings a job inherits and must not follow.
cp "$REPO/tools/tests/shim/slurm" "$T/bin/slurm.shim" && chmod 755 "$T/bin/slurm.shim"
for s in sbatch squeue sacct scancel; do ln -s slurm.shim "$T/bin/$s"; done
export SHIM_SLURM="$T/slurm" SHIM_SLURM_ROOT="$T" CURL_CA_BUNDLE="$T/svc.crt"
export GITHUB_TOKEN=ghp_testtoken_must_not_leak GH_TOKEN=gho_testtoken_must_not_leak
unset HPCW_ACCESS_PARTITION HPCW_ACCESS_QOS HPCW_CI_PARTITION HPCW_CI_QOS SLURM_JOB_ID
mkdir -p "$T/slurm"; : > "$T/slurm/calls"
echo "sbatch: Warning: this job may be preempted and requeued" > "$T/slurm/warn"
WD="$T/vendor/access-watch"
DEF_PART=$(sed -n 's/^#SBATCH --partition=//p' "$REPO/tools/grid_ci.sbatch"); DEF_QOS=$(sed -n 's/^#SBATCH --qos=//p' "$REPO/tools/grid_ci.sbatch")
J() { cat "$T/slurm/jobs/$1/$2" 2>/dev/null; }
scalls() { grep -c "^$1 " "$T/slurm/calls"; }
set_state() { echo "$2" > "$T/slurm/jobs/$1/state"; }
chain_jobs() { local j; for j in $(ls "$T/slurm/jobs" 2>/dev/null | sort -n); do [ "$(J "$j" name)" = hpcw_access ] && echo "$j"; done; return 0; }
pending() { local j; for j in $(chain_jobs); do [ "$(J "$j" state)" = PENDING ] && echo "$j"; done; return 0; }
newest() { chain_jobs | tail -1; }
run_tick() { # ID [VAR=VALUE...]: the job as Slurm runs it, its output appended to its log (--open-mode=append),
  # which is opened before the job starts, as Slurm opens it: a job that renames its log keeps writing there
  local id=$1 args=(); shift
  mapfile -t args < "$T/slurm/jobs/$id/args"
  set_state "$id" RUNNING
  OUT=$({ cd "$(J "$id" dir)" && env "$@" SLURM_JOB_ID="$id" bash "$T/slurm/jobs/$id/script" "${args[@]}" 2>&1 | tee -a /dev/fd/3; } 3>>"$(J "$id" out)"); RC=$?
  if [ "$RC" = 0 ]; then set_state "$id" COMPLETED; else set_state "$id" FAILED; fi
}
same_bin() { local f; for f in grid_access.sh grid_access_watch.sbatch grid_ci.sbatch; do cmp -s "$WD/bin/$f" "$1/$f" || return 1; done; }
unowns() { local tmp="$SHIM_OWNERS.new"; awk -v p="$1" '$1 != p' "$SHIM_OWNERS" > "$tmp" && mv -f "$tmp" "$SHIM_OWNERS"; }   # PATH: the stat shim's answer for it taken back
nodetmp() { printf '/tmp/%s/hpcw_access_%s' "$(id -un)" "$1"; }
for f in tools/grid_access.sh tools/grid_access_watch.sbatch; do OUT=$(bash -n "$REPO/$f" 2>&1); t "bash -n $f" [ -z "$OUT" ]; done
JF="$REPO/tools/grid_access_watch.sbatch"
t "the chain's job file names no queue, has a wall time of thirty minutes and the chain's name" eval '! grep -E "^#SBATCH --(partition|qos)" "$JF" && grep -qx "#SBATCH --time=00:30:00" "$JF" && grep -qx "#SBATCH --job-name=hpcw_access" "$JF"'
t "the chain's job file: one node, one task, one core, 1 GB, its log appended to (one log for every job) and requeueable" eval '( for l in --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=1G --output=access.log --open-mode=append --requeue; do grep -qx -- "#SBATCH $l" "$JF" || exit 1; done )'
t "the chain's job file unsets every agent marker and both token variables, and the node's verdict a shell may have set" eval '( u=$(grep "^unset CLAUDECODE " "$JF"); for v in CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN; do case " $u " in *" $v "*) ;; *) exit 1;; esac; done; grep -qx "unset HPCW_ACCESS_NO_TMP" "$JF" )'

echo "-- --watch refuses, and asks the scheduler nothing"
mv "$T/vendor/admin_token" "$T/admin_token.kept"
if ! ( PATH=/usr/bin:/bin; command -v sbatch ) >/dev/null 2>&1; then
  OUT=$(PATH=/usr/bin:/bin bash "$GA" --site wayne --root "$ROOT" --watch 2>&1); RC=$?
  t "--watch where there is no sbatch: refused, it runs on the cluster" eval 'rc_is 1 && has "^grid_access: --watch runs on the cluster, in a shell on its login node: sbatch and squeue are not here; nothing started$"'
fi
ga --watch
t "--watch without grid_token: refused, says where it comes from" eval 'rc_is 1 && has "^grid_access: no grid_token in the vendor folder \($T/vendor\): make the grid token on the admin page" && [ ! -s "$T/slurm/calls" ]'
printf '%s\n' "$GTOKEN" > "$T/vendor/grid_token"; chmod 644 "$T/vendor/grid_token"
ga --watch
t "--watch with grid_token readable by others (0644): refused with the fix" eval 'rc_is 1 && has "grid_token is readable by group or other \(mode 644\); make it yours alone first: chmod 600 $T/vendor/grid_token; nothing started$" && [ ! -s "$T/slurm/calls" ]'
chmod 600 "$T/vendor/grid_token"; : > "$T/vendor/grid_token"
ga --watch
t "--watch with an empty grid_token: refused" eval 'rc_is 1 && has "grid_token is empty: the grid token is one line in it; nothing started$" && [ ! -s "$T/slurm/calls" ]'
printf '%s\r\n' "$GTOKEN" > "$T/vendor/grid_token"
cp "$T/admin_token.kept" "$T/vendor/admin_token"
ga --watch
t "--watch with admin_token beside grid_token: refused, gives the exact rm" eval 'rc_is 1 && has "^grid_access: $T/vendor/admin_token is here too: the admin token can approve accounts and must not sit on a shared machine, and the chain needs only grid_token. Remove it first: rm $T/vendor/admin_token; nothing started$" && [ ! -s "$T/slurm/calls" ]'
rm "$T/vendor/admin_token"; ln -s "$T/admin_token.kept" "$T/vendor/admin_token"
ga --watch
t "--watch with admin_token a link: the rm names the file and the link" eval 'rc_is 1 && has "Remove it first: rm $T/admin_token.kept $T/vendor/admin_token; nothing started$" && [ ! -s "$T/slurm/calls" ]'
rm "$T/vendor/admin_token"; ln -s "$T/no-such-admin-token" "$T/vendor/admin_token"
ga --watch
t "--watch with admin_token a link to nothing: still refused, the rm names the link" eval 'rc_is 1 && has "Remove it first: rm $T/vendor/admin_token; nothing started$" && [ ! -s "$T/slurm/calls" ]'
rm "$T/vendor/admin_token"
printf '%s\n' 'quo"te' > "$T/vendor/grid_token"
ga --watch
t "--watch with a grid_token that holds no bearer token: refused naming the characters" eval 'rc_is 1 && has "grid_token does not hold a token: its first line must be the grid token alone, letters, digits and - . _ ~ \+ / \(and = at its end\)" && [ ! -s "$T/slurm/calls" ]'
printf '%s\r\n' "$GTOKEN" > "$T/vendor/grid_token"
for e in 4 1441 x; do
  ga --watch --every "$e"
  t "--watch --every $e: refused (5 to 1440), the scheduler not asked" eval 'rc_is 1 && has "5 to 1440: $e$" && [ ! -s "$T/slurm/calls" ]'
done
# 5 and 1440 pass: each run below is refused for its folder instead, which is checked after the minutes
chmod 777 "$T/vendor"
ga --watch --every 5
t "--watch --every 5 with a vendor folder others may write (0777): refused with the chmod, nothing asked" eval 'rc_is 1 && has "^grid_access: group or other may write in $T/vendor \(mode 777; fix: chmod go-w $T/vendor\): another account could put its own script where the chain.s jobs run it, beside the token; nothing started$" && [ ! -s "$T/slurm/calls" ]'
chmod 755 "$T/vendor"; chmod 775 "$WD"
ga --watch --every 1440
t "--watch --every 1440 with access-watch others may write (0775): refused with the chmod" eval 'rc_is 1 && has "group or other may write in $WD \(mode 775; fix: chmod go-w $WD\)" && [ ! -s "$T/slurm/calls" ]'
chmod 700 "$WD"; mv "$WD" "$T/aw.real"; ln -s "$T/aw.real" "$WD"
ga --watch
t "--watch with access-watch a link: refused" eval 'rc_is 1 && has "^grid_access: $WD is a link, where the chain keeps a folder of its own" && [ ! -s "$T/slurm/calls" ]'
rm "${WD:?}"; mv "$T/aw.real" "$WD"; mkdir -m 700 "$WD/bin"; owns "$WD/bin" ab1234
ga --watch
t "--watch with access-watch/bin another account's: refused" eval 'rc_is 1 && has "^grid_access: $WD/bin belongs to ab1234, not to $(id -un): another account could" && [ ! -s "$T/slurm/calls" ]'
unowns "$WD/bin"; rmdir "${WD:?}/bin"
OUT=$( ( umask 002; BEETHOVEN_VENDOR_DIR="$T/vendor2" bash "$GA" --site wayne --root "$ROOT" --watch ) 2>&1)
t "a vendor folder the tool makes is its owner's alone, whatever the umask (0002 here)" eval 'has "no grid_token in the vendor folder" && [ "$(stat -c %a "$T/vendor2")" = 700 ] && [ "$(stat -c %a "$T/vendor2/state")" = 700 ]'
rm -r "${T:?}/vendor2"
ga --watch --dry-run
t "--watch with an option of a run's own (--dry-run): refused" eval 'rc_is 1 && has "^grid_access: --watch takes no --dry-run: " && [ ! -s "$T/slurm/calls" ]'
ga --watch --partition p1
t "--partition outside a job of the chain: refused, names the variable to set" eval 'rc_is 1 && has "HPCW_ACCESS_PARTITION" && [ ! -s "$T/slurm/calls" ]'
ga --every 15
t "--every without --watch: refused" eval 'rc_is 1 && has "--every goes with --watch"'
t "nothing of the chain made by a refusal" eval '[ ! -e "$WD/bin" ]'

echo "-- --watch starts the chain"
# left by an earlier chain, naming the job the scheduler gives next: --watch clears both, or that job would
# take its successor for queued already
echo "$(( $(cat "$T/slurm/counter" 2>/dev/null || echo 1000) + 1 )) 999999" > "$WD/next"; cp "$WD/next" "$WD/next.submitting"
ga --watch --every 7 --service "$SVC"
W1=$(newest)
t "--watch: one squeue and one sbatch, nothing else" eval 'rc_is 0 && [ "$(grep -c . "$T/slurm/calls")" = 2 ] && [ "$(scalls squeue)" = 1 ] && [ "$(scalls sbatch)" = 1 ] && grep -q "^squeue -h -u $(id -un) -n hpcw_access " "$T/slurm/calls"'
t "--watch: says what it started, in two lines" eval '[ "$(printf "%s\n" "$OUT" | wc -l)" = 2 ] && has "^copying the access lists to $ROOT every 7 minutes: job $W1 looks now$" && has "^its log is $WD/access.log; tools/grid_access.sh --unwatch stops it$"'
t "--watch: the chain's own copy of its scripts in access-watch/bin (grid_ci.sbatch for its queue), the folders the owner's alone" eval 'same_bin "$REPO/tools" && [ "$(stat -c %a "$WD")" = 700 ] && [ "$(stat -c %a "$WD/bin")" = 700 ] && [ ! -e "$WD/next" ] && [ ! -e "$WD/next.submitting" ]'
t "--watch: the job runs that copy, in the chain's folder, singleton, at once" eval '[ "$(J $W1 dir)" = "$WD" ] && cmp -s "$T/slurm/jobs/$W1/script" "$REPO/tools/grid_access_watch.sbatch" && [ "$(J $W1 dependency)" = singleton ] && [ -z "$(J $W1 begin)" ]'
t "--watch: on grid_ci.sbatch's own partition and QoS, carried in the job's arguments" eval '[ -n "$DEF_PART" ] && [ "$(J $W1 partition)" = "$DEF_PART" ] && [ "$(J $W1 qos)" = "$DEF_QOS" ]'
t "--watch: the root, the site, the service and the minutes fixed in the job's arguments" eval '[ "$(J $W1 args | tr "\n" " ")" = "--tick --every 7 --site wayne --root $ROOT --service $SVC --partition $DEF_PART --qos $DEF_QOS " ]'
echo "# changed by hand" >> "$WD/bin/grid_access.sh"
ga --watch --every 9
t "--watch again while a job is queued: submits nothing, refreshes the chain's copy, says so" eval 'rc_is 0 && has "^already watching \(job $W1\); its scripts now come from this copy$" && [ "$(scalls sbatch)" = 1 ] && [ "$(scalls squeue)" = 2 ] && same_bin "$REPO/tools"'
echo "squeue: warning: a notice of the site's" > "$T/slurm/sqwarn"
ga --watch
t "--watch while a job is queued and squeue warns on stderr: the job is found, the warning shown, not taken for a job" eval 'rc_is 0 && has "^already watching \(job $W1\); " && has "^squeue: warning: a notice of the site.s$" && [ "$(scalls sbatch)" = 1 ]'
rm -f "$T/slurm/sqwarn"; echo "squeue: error: Invalid user" > "$T/slurm/sqout"
ga --watch
t "--watch when squeue answers something else than its job list: refused, nothing submitted" eval 'rc_is 1 && has "^grid_access: squeue answered something else than the chain.s jobs: squeue: error: Invalid user" && [ "$(scalls sbatch)" = 1 ]'
rm -f "$T/slurm/sqout"
mkdir -p "$T/tools2"; cp "$REPO/tools/grid_access.sh" "$REPO/tools/grid_access_watch.sbatch" "$REPO/tools/grid_ci.sbatch" "$T/tools2/"; echo 'if' >> "$T/tools2/grid_access_watch.sbatch"
OUT=$(bash "$T/tools2/grid_access.sh" --site wayne --root "$ROOT" --watch 2>&1); RC=$?
t "a copy whose job file does not parse: refused, the chain keeps its scripts" eval 'rc_is 1 && has "grid_access_watch.sbatch is missing or does not parse" && has "keeps the scripts it had" && same_bin "$REPO/tools" && [ "$(scalls sbatch)" = 1 ]'

echo "-- a job of the chain"
OUT=$(cd "$WD" && env -u SLURM_JOB_ID bash bin/grid_access.sh --tick --every 7 --site wayne --root "$ROOT" 2>&1); RC=$?
t "--tick outside a job: refused" eval 'rc_is 1 && has "^grid_access: --tick runs inside the chain.s own job; start the chain with tools/grid_access.sh --watch$"'
OUT=$(SLURM_JOB_ID=77 bash "$GA" --tick --every 7 --site wayne --root "$ROOT" 2>&1); RC=$?
t "--tick from a checkout: refused, it runs the chain's own copy" eval 'rc_is 1 && has "runs the chain.s own copy, <vendor>/access-watch/bin/grid_access.sh"'
: > "$T/svc.seen"; c=$(curls); n=$(calls)
run_tick "$W1"
W2=$(newest)
t "a job: its line, then exactly one successor, in 7 minutes, singleton, the same arguments and queue" eval 'rc_is 0 && has "^== tick $W1 on [A-Za-z0-9.-]+ at [0-9T:-]+Z$" && [ "$(pending)" = "$W2" ] && [ "$(J $W2 begin)" = now+7minutes ] && [ "$(J $W2 dependency)" = singleton ] && [ "$(J $W2 args)" = "$(J $W1 args)" ] && [ "$(J $W2 partition)" = "$DEF_PART" ] && [ "$(J $W2 qos)" = "$DEF_QOS" ] && [ "$(J $W2 dir)" = "$WD" ]'
t "the chain's first job says which curl its node has" eval 'has "^curl on [A-Za-z0-9.-]+: curl [0-9]"'
t "a job: its successor queued before the lists are asked for" eval 'printf "%s\n" "$OUT" | awk "/^next tick: job / && !n { n = NR } /^tick done: / && !m { m = NR } END { exit !(n && m && n < m) }"'
t "a job: the lists applied here, with the grid token, from the service (not the shell's readers command)" eval 'has "^tick done: exit 0 in [0-9]+s$" && [ "$(tr "\n" " " < "$T/svc.seen")" = "grid grid " ] && [ "$(curls)" = $((c + 2)) ] && [ "$(calls)" = $n ] && grep -qx "# target here:$ROOT" "$STATE" && grep -qx "# read cd5678 shared/data" "$STATE" && [ "$(named)" = "ab1234 cd5678" ]'
t "a job: its log, last-tick, and the token's folder on the node gone" eval 'grep -q "^== tick $W1 on " "$WD/access.log" && grep -Eq "^[0-9T:-]+Z job $W1 on [A-Za-z0-9.-]+: exit 0 in [0-9]+s$" "$WD/last-tick" && [ ! -e "$(nodetmp $W1)" ]'
t "a job: curl's configuration file made in the job's own folder on the node's disk, 0700, the file 0600" eval 'grep -q -- "^-q -sS --max-time 60 -K $(nodetmp $W1)/grid_access\.[A-Za-z0-9]*/curl\.config " "$SHIM_CURL_CALLS" && [ "$(grep -c "^tmpdir 700 $(nodetmp $W1)$" "$SHIM_CURL_META")" = 2 ] && ! grep "^config-file-mode " "$SHIM_CURL_META" | grep -v "^config-file-mode 600$" >/dev/null'
n=$(scalls sbatch)
run_tick "$W1"
t "the same job run again (a requeue): no second successor" eval 'rc_is 0 && has "^next tick: job $W2, queued by an earlier run of this job$" && [ "$(scalls sbatch)" = $n ] && [ "$(pending)" = "$W2" ]'
t "a job with nothing new: the child (--quiet) says nothing, and no curl line but the chain's first job's" eval '[ "$(printf "%s\n" "$OUT" | grep -c .)" = 3 ] && lacks "^unchanged since" && lacks "^curl on "'
echo "$W1" > "$WD/next.submitting"; rm -f "$WD/next"; nq=$(scalls squeue)
echo "squeue: error: a line that is no job number" > "$T/slurm/sqout"   # never taken for the successor's number
: > "$T/svc.seen"; m0=$(grep -c '^markers' "$SHIM_CURL_META")
run_tick "$W1" BEETHOVEN_ROSTER_CMD="printf 'zz1111\\n'" CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=cli AI_AGENT=x BEETHOVEN_REQUEST_ID=r1 BEETHOVEN_WORKER=1 ASHLEY_REQUEST_ID=r1 ASHLEY_WORKER=1 ASHLEY_JOB=1 HPCW_AGENT=1
t "a job started from a shell with a roster command and an agent's markers: both lists from the service, no marker reaches curl" eval '[ "$(tr "\n" " " < "$T/svc.seen")" = "grid grid " ] && [ "$(grep "^markers" "$SHIM_CURL_META" | sed -n "$((m0 + 1)),\$p" | sort -u)" = markers ]'
rm -f "$T/slurm/sqout"
t "stopped between its successor's sbatch and writing it down: one squeue finds it, no second" eval 'rc_is 0 && [ "$(scalls sbatch)" = $n ] && [ "$(scalls squeue)" = $((nq + 1)) ] && [ "$(pending)" = "$W2" ] && [ ! -e "$WD/next.submitting" ] && [ "$(cat "$WD/next")" = "$W1 $W2" ]'
t "no file of the chain's folder or the vendor folder's state holds the token; no job's arguments either" eval '! grep -rF -e "$GTOKEN" -e "$TOKEN" "$WD" "$T/vendor/state" "$T/slurm" >/dev/null'
t "no scheduler call saw GITHUB_TOKEN or GH_TOKEN" eval '[ ! -s "$T/slurm/leaks" ]'

echo "-- --unwatch, STOP, --watch again"
nq=$(scalls squeue); nc=$(scalls scancel); set_state "$W1" RUNNING
echo "squeue: warning: a notice of the site's" > "$T/slurm/sqwarn"
ga --unwatch
rm -f "$T/slurm/sqwarn"
t "--unwatch: a job running then is left to end (STOP ends the chain there), the warning not taken for a job" eval '[ "$(J $W1 state)" = RUNNING ] && ! grep -q "^scancel .*$W1" "$T/slurm/calls" && has "^squeue: warning: "'
set_state "$W1" COMPLETED
t "--unwatch: STOP written, the queued job cancelled, one squeue and one scancel" eval 'rc_is 0 && [ -s "$WD/STOP" ] && [ "$(J $W2 state)" = CANCELLED ] && [ "$(scalls squeue)" = $((nq + 1)) ] && [ "$(scalls scancel)" = $((nc + 1)) ] && grep -q "^scancel $W2$" "$T/slurm/calls" && has "^cancelled the queued job \(job $W2\)$" && has "^STOP written: a job running now queues at most one more, which ends on STOP when it runs \(--unwatch again cancels it at once\)"'
echo "squeue: error: Invalid user" > "$T/slurm/sqout"; nc=$(scalls scancel)
ga --unwatch
t "--unwatch when squeue answers something else than job numbers: refused, nothing cancelled, STOP kept" eval 'rc_is 1 && has "squeue answered something else than job numbers: squeue: error: Invalid user; STOP is written" && [ "$(scalls scancel)" = $nc ] && [ -e "$WD/STOP" ]'
rm -f "$T/slurm/sqout"
set_state "$W2" PENDING; n=$(scalls sbatch); echo "# changed by hand" >> "$WD/bin/grid_access.sh"
ga --watch --service "$SVC"
t "--watch while STOP is set and a job is only queued: refused, names --unwatch to cancel it now; the copy refreshed all the same" eval 'rc_is 1 && has "job $W2 of the chain is queued, but STOP is set, so it only ends the chain when it runs \(its scripts now come from this copy\); tools/grid_access.sh --unwatch cancels it now, then --watch starts the chain again" && [ "$(scalls sbatch)" = $n ] && same_bin "$REPO/tools"'
set_state "$W2" RUNNING; n=$(scalls sbatch)
ga --watch --service "$SVC"
t "--watch while a job still runs and STOP is set: refused, says the chain ends with it" eval 'rc_is 1 && has "job $W2 of the chain is running, but STOP is set, so the chain ends with it" && [ "$(scalls sbatch)" = $n ] && [ -e "$WD/STOP" ]'
: > "$T/svc.seen"
run_tick "$W2"
t "a job that finds STOP: the chain ends, no successor, nothing applied" eval 'rc_is 0 && has "^STOP is set \($WD/STOP\): the chain ends here" && [ "$(scalls sbatch)" = $n ] && lacks "^tick done" && [ ! -s "$T/svc.seen" ] && [ -z "$(pending)" ]'
HPCW_ACCESS_PARTITION=accp HPCW_ACCESS_QOS=accq HPCW_CI_PARTITION=cip HPCW_CI_QOS=ciq ga --watch --every 6 --service "$SVC"
W3=$(newest)
t "--watch after the chain ended: STOP gone, a job queued, on HPCW_ACCESS_PARTITION and HPCW_ACCESS_QOS, carried on" eval 'rc_is 0 && [ ! -e "$WD/STOP" ] && [ "$(pending)" = "$W3" ] && [ "$(J $W3 partition)" = accp ] && [ "$(J $W3 qos)" = accq ] && [ "$(J $W3 args | tr "\n" " ")" = "--tick --every 6 --site wayne --root $ROOT --service $SVC --partition accp --qos accq " ]'
mode 401
run_tick "$W3"
W4=$(newest)
t "a job whose child fails: its exit, the chain goes on, on the same queue" eval 'rc_is 1 && has "check grid_token in the vendor folder" && has "^tick done: exit 1 in " && [ "$(pending)" = "$W4" ] && [ "$(J $W4 partition)" = accp ] && [ "$(J $W4 begin)" = now+6minutes ] && grep -q ": exit 1 in " "$WD/last-tick"'
mode ok
{ head -c 1100000 /dev/zero | tr '\0' x; echo; } > "$WD/access.log"
echo "QOSMaxSubmitJobPerUserLimit" > "$T/slurm/refuse"
run_tick "$W4"
t "the scheduler refuses the successor: the lists still applied, the chain ends there in words, exit 1" eval 'rc_is 1 && has "^could not queue the next tick: sbatch: error: QOSMaxSubmitJobPerUserLimit$" && has "^tick done: exit 0 in " && has "^the chain ends here: its next job could not be queued" && [ -z "$(pending)" ] && [ ! -e "$WD/next.submitting" ]'
t "a log over 1 MB: kept as access.log.1, the next job starts a new one" eval '[ "$(wc -c < "$WD/access.log.1")" -gt 1048576 ] && [ ! -e "$WD/access.log" ] && grep -q "^== tick $W4 on " "$WD/access.log.1"'
rm -f "$T/slurm/refuse"
HPCW_CI_PARTITION=cip HPCW_CI_QOS=ciq ga --watch --service "$SVC"
W5=$(newest)
t "HPCW_CI_PARTITION and HPCW_CI_QOS when the chain's own are not set" eval 'rc_is 0 && [ "$(J $W5 partition)" = cip ] && [ "$(J $W5 qos)" = ciq ] && grep -qx cip "$T/slurm/jobs/$W5/args"'
mv "$T/vendor/grid_token" "$T/grid_token.kept"; cp "$T/admin_token.kept" "$T/vendor/admin_token"; : > "$T/svc.seen"
run_tick "$W5"
t "a job with no grid_token: applies nothing, never falls back to admin_token, and says it is there" eval 'rc_is 1 && has "^no grid_token in the vendor folder \($T/vendor\): the chain reads the lists with the grid token alone" && has "^note: $T/vendor/admin_token is here too; .*: rm $T/vendor/admin_token$" && [ ! -s "$T/svc.seen" ] && [ -n "$(pending)" ]'
rm "$T/vendor/admin_token"; mv "$T/grid_token.kept" "$T/vendor/grid_token"
for j in $(pending); do set_state "$j" CANCELLED; done

echo "-- the job's own folder on the node's disk"
# The job file makes /tmp/<account>/hpcw_access_<job> on the real /tmp of this machine, as on a compute node.
# A node where that fails still lets the job queue its successor; what another account put there is never
# followed, changed or removed
TU=$(dirname "$(nodetmp 1)"); TU_MODE=$(stat -c %a "$TU" 2>/dev/null)
noapply() { [ ! -s "$T/svc.seen" ] && has "; this job applies nothing, and the next one tries again$" && grep -q ": exit 1 in " "$WD/last-tick"; }
ga --watch --service "$SVC"; K=$(newest)
mkdir -p "$TU"; : > "$(nodetmp "$K")"; : > "$T/svc.seen"
run_tick "$K"
t "a node where the job's folder cannot be made (a file there): its successor still queued, nothing applied, the reason said" eval 'rc_is 1 && [ -n "$(pending)" ] && [ "$(pending)" != "$K" ] && has "could not give this job a folder of its own on its disk for the token.s configuration file: $(nodetmp $K) cannot be made a folder" && noapply && [ -f "$(nodetmp $K)" ] && lacks "^the chain ends here"'
rm -f "$(nodetmp "$K")"; K=$(pending)
mkdir -p "$T/notmine-root"; chmod 3770 "$T/notmine-root"; ln -s "$T/notmine-root" "$(nodetmp "$K")"; : > "$T/svc.seen"
run_tick "$K"
t "a link another account put in place of the job's folder: never followed (its target's mode unchanged), left as it is, the successor queued" eval 'rc_is 1 && has "$(nodetmp $K) is there already, as a link" && [ "$(stat -c %a "$T/notmine-root")" = 3770 ] && [ -L "$(nodetmp $K)" ] && [ -z "$(ls -A "$T/notmine-root")" ] && noapply && [ -n "$(pending)" ]'
rm -f "$(nodetmp "$K")"; K=$(pending)
owns "$TU" ab1234; : > "$T/svc.seen"
run_tick "$K"
unowns "$TU"
t "/tmp/<account> another account's: nothing made in it, the successor queued" eval 'rc_is 1 && has "$TU belongs to ab1234, not to $(id -un)" && [ ! -e "$(nodetmp $K)" ] && noapply && [ -n "$(pending)" ]'
K=$(pending); mkdir -m 755 "$(nodetmp "$K")"; chmod 777 "$TU"; : > "$T/svc.seen"; m0=$(grep -c '^tmpdir ' "$SHIM_CURL_META")
run_tick "$K"
t "the job's folder left by an earlier run of the same job (a requeue): taken, made 0700, /tmp/<account> closed to writing by others, gone after" eval 'rc_is 0 && [ "$(tr "\n" " " < "$T/svc.seen")" = "grid grid " ] && [ "$(grep "^tmpdir " "$SHIM_CURL_META" | sed -n "$((m0 + 1)),\$p" | sort -u)" = "tmpdir 700 $(nodetmp $K)" ] && [ ! -e "$(nodetmp $K)" ] && case "$(stat -c %a "$TU")" in *[2367]?|*[2367]) false;; esac'
[ -z "$TU_MODE" ] || chmod "$TU_MODE" "$TU"

echo "-- the folders the job runs from"
K=$(pending); n=$(scalls sbatch); chmod 777 "$T/vendor"; : > "$T/svc.seen"
run_tick "$K"
chmod 755 "$T/vendor"
t "a vendor folder others may write: the job runs nothing of bin/, queues no successor, and says the chain ends" eval 'rc_is 1 && has "^group or other may write in $T/vendor \(mode 777; fix: chmod go-w $T/vendor\): another account could change what this job runs. Nothing applied, and the chain ends here" && [ "$(scalls sbatch)" = $n ] && [ -z "$(pending)" ] && [ ! -s "$T/svc.seen" ] && lacks "^== tick"'
ga --watch --service "$SVC"; K=$(newest); n=$(scalls sbatch); owns "$WD" ab1234
run_tick "$K"
unowns "$WD"
t "the chain's folder another account's: the same" eval 'rc_is 1 && has "^$WD belongs to ab1234, not to $(id -un): another account could change what this job runs" && [ "$(scalls sbatch)" = $n ] && [ -z "$(pending)" ]'
ga --watch --service "$SVC"; K=$(newest); n=$(scalls sbatch); chmod 775 "$WD/bin/grid_access.sh"
run_tick "$K"
t "bin/grid_access.sh others may write: the same" eval 'rc_is 1 && has "^group or other may write in $WD/bin/grid_access.sh \(mode 775; fix: chmod go-w $WD/bin/grid_access.sh\)" && [ "$(scalls sbatch)" = $n ] && [ -z "$(pending)" ]'
chmod 755 "$WD/bin/grid_access.sh"
OUT=$(cd "$WD" && env -u SLURM_JOB_ID bash bin/grid_access_watch.sbatch --tick 2>&1); RC=$?
t "the job file outside a job: refused before anything" eval 'rc_is 1 && has "this file is a job of the chain; tools/grid_access.sh --watch submits it"'

echo "-- --watch from the chain's own copy, and --unwatch while a job queues its next"
OUT=$(bash "$WD/bin/grid_access.sh" --site wayne --root "$ROOT" --watch --every 7 --service "$SVC" 2>&1); RC=$?; K=$(newest)
t "--watch typed from the chain's own copy (the clone gone): the same queue, from the copy's grid_ci.sbatch" eval 'rc_is 0 && has "job $K looks now" && [ "$(J $K partition)" = "$DEF_PART" ] && [ "$(J $K qos)" = "$DEF_QOS" ]'
# sbatch first on the job's PATH runs --unwatch once, just before the job's successor is submitted: past
# the job's own look at STOP
mkdir -p "$T/hk/real"; ln -sf "$T/bin/slurm.shim" "$T/hk/real/sbatch"
printf '%s\n' '#!/usr/bin/env bash' \
  "if [ -e '$T/hk/once' ]; then rm -f '$T/hk/once'; env -u SLURM_JOB_ID bash '$GA' --site wayne --root '$ROOT' --unwatch > '$T/hk/unwatch.out' 2>&1; fi" \
  "exec '$T/hk/real/sbatch' \"\$@\"" > "$T/hk/sbatch"
chmod 755 "$T/hk/sbatch"; touch "$T/hk/once"
run_tick "$K" PATH="$T/hk:$PATH"
K2=$(pending)
t "--unwatch typed while a job queues its next: one more job queued, as --unwatch said it may be" eval 'grep -q "^no job of the chain was queued$" "$T/hk/unwatch.out" && grep -q "^STOP written: a job running now queues at most one more" "$T/hk/unwatch.out" && [ -n "$K2" ] && [ -e "$WD/STOP" ]'
ga --watch --service "$SVC"
t "--watch then: refused, names --unwatch to cancel that one now" eval 'rc_is 1 && has "job $K2 of the chain is queued, but STOP is set, so it only ends the chain when it runs .*tools/grid_access.sh --unwatch cancels it now"'
ga --unwatch
t "--unwatch again: that job cancelled" eval 'rc_is 0 && [ "$(J $K2 state)" = CANCELLED ] && [ -z "$(pending)" ]'
echo "squeue: warning: a notice of the site's" > "$T/slurm/sqwarn"
ga --watch
W6=$(newest)
rm -f "$T/slurm/sqwarn"
t "--watch with nothing queued while squeue warns on stderr: the chain starts, the warning shown" eval 'rc_is 0 && has "^squeue: warning: " && has "^copying the access lists to $ROOT every 15 minutes: job $W6 looks now$"'
t "--watch with no --service but \$BEETHOVEN_SERVICE_URL set: that address goes with every job" eval 'rc_is 0 && grep -qx -- "--service" "$T/slurm/jobs/$W6/args" && grep -qx "https://127.0.0.1:1" "$T/slurm/jobs/$W6/args"'
set_state "$W6" CANCELLED
env -u BEETHOVEN_SERVICE_URL bash "$GA" --site wayne --root "$ROOT" --watch >/dev/null 2>&1
W7=$(newest)
t "--watch with no service named: none in the job's arguments (each job's child takes the tool's own)" eval '[ "$W7" != "$W6" ] && ! grep -qx -- "--service" "$T/slurm/jobs/$W7/args"'
set_state "$W7" CANCELLED
t "after all of it: no token in the chain's folder, the state or the scheduler's records; no token variable reached it" eval '! grep -rF -e "$GTOKEN" -e "$TOKEN" "$WD" "$T/vendor/state" "$T/slurm" >/dev/null && [ ! -s "$T/slurm/leaks" ] && [ ! -s "$T/slurm/refused" ]'
unset GITHUB_TOKEN GH_TOKEN CURL_CA_BUNDLE

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
