#!/usr/bin/env bash
# Publish framework/ as the lab's shared copy of hpcworker on a cluster. Every account then uses that
# one copy through a small launcher (hpcworker install --shared); nothing of the code is copied into
# anyone's home, and a new version reaches every account when it is published here.
#
#   tools/deploy_shared.sh [--site wayne] [--host wsu-grid] [--root DIR] [--group NAME] [--dry-run] [--replace]
#   tools/deploy_shared.sh --here [the same options]     on the cluster itself, from a checkout there
#
# Layout on the cluster (ROOT defaults to the directory above `current` in profiles/<site>.json's
# shared_install; at Wayne State /rs/rs_grp_oschome/shared/beethoven/hpcworker, which was .../shared/ashley
# until 2026-09-30 and is still reached through the link shared/ashley -> beethoven):
#   ROOT/v<N>/      one directory per framework VERSION: bin/ lib/ jobs/ profiles/ VERSION README.md
#   ROOT/current    a relative link to v<N>, switched in one rename (ln -s, then mv -T; coreutils 8.22's
#                   `ln -sfn` unlinks first, which leaves a moment with no `current`)
#   ROOT/deploy.log one line per publish
# Older v<N> directories are never removed: a running worker's job names the numbered directory it
# started on (the launcher resolves `current` once, when the worker starts), and its chain keeps it
# until the student starts the worker again. Remove an old version by hand, and only when no worker
# can still name it.
#
# It never moves `current` from version 11 or later (the first with the gate that Beethoven's browser keys
# run) back to a version before 11, and it checks each site profile with `hpcworker profile check` (awk),
# never with python3, which warrior's login banner bans.
#
# What it does, in order: checks VERSION against bin/hpcworker's VERSION= line, LF line endings and
# `bash -n`; tars exactly the files it lists, with a SHA-256 manifest; over ssh (BatchMode) runs its
# own --publish part on the login node, which is file work only (tar, chmod, setfacl, one symlink):
# no scheduler call, no container, no temp file under /tmp (no here-documents: bash writes those to
# a temp file). A version already published with the same files is not extracted again (idempotent);
# when only README.md differs it is updated in place (a running chain never reads it); a version
# published with different code is refused unless --replace, which moves the old directory aside as
# v<N>.replaced-<time> (never deleted). Permissions: group read and traverse, no group
# write, nothing for others; the numbered directories are read-only for their owner too, so a copy
# or an upload that follows a stray link cannot change them. When the tree carries POSIX ACLs (the
# Wayne State volume does, with a group-writable default), the group and mask entries and the
# directories' default entries are set to match. It prints the tree, the link, the ACLs and what
# changed against the previous `current`.
set -uo pipefail

say() { printf '%s\n' "$*"; }
die() { printf 'deploy_shared: %s\n' "$*" >&2; exit 1; }

# ---- the cluster side: `deploy_shared.sh --publish ROOT N GROUP REPLACE DRY COMMIT MANIFEST_B64`, the tar on stdin ----
has_acl() { command -v getfacl >/dev/null 2>&1 && getfacl -p "$1" 2>/dev/null | grep -q -E '^(mask::|default:|user:[^:]|group:[^:])'; }
set_perms() { # DIR [GROUP]: group read and traverse, no group write, nothing for others, read-only for the owner
  local d="$1" group="${2:-}" acl=0
  [ -n "$group" ] && { chgrp -R "$group" "$d" || return 1; }
  has_acl "$d" && acl=1
  find "$d" -type d -exec chmod 2550 {} + || return 1
  find "$d" -type f -exec chmod 0440 {} + || return 1
  find "$d" -type f \( -path "$d/bin/*" -o -name '*.sbatch' \) -exec chmod 0550 {} + || return 1
  [ $acl = 1 ] || return 0
  # an ACL'd tree: chmod moves only the mask, so the entries are set explicitly, per kind of file.
  # Not "rX": X follows an execute bit the inherited group entry still carries, and marks every file x
  find "$d" -type d -exec setfacl -m u::r-x,g::r-x,m::r-x,o::--- {} + -exec setfacl -d -m u::r-x,g::r-x,m::r-x,o::--- {} + || return 1
  find "$d" -type f -exec setfacl -m u::r--,g::r--,m::r--,o::--- {} + || return 1
  find "$d" -type f \( -path "$d/bin/*" -o -name '*.sbatch' \) -exec setfacl -m u::r-x,g::r-x,m::r-x,o::--- {} + || return 1
}
root_perms() { # ROOT: the owner publishes into it; the group reads and traverses; others nothing (and the same as defaults)
  chmod 2750 "$1" || return 1
  has_acl "$1" || return 0
  setfacl -m u::rwx,g::r-x,m::r-x,o::--- "$1" && setfacl -d -m u::rwx,g::r-x,m::r-x,o::--- "$1"
}
compare_to_manifest() { # DIR MANIFEST -> same | readme (only README.md differs) | differs (a file added, missing or changed)
  local d="$1" man="$2" want have
  want=$(printf '%s\n' "$man" | sed -e 's/^[0-9a-f]* [ *]//' | sort)
  have=$(cd "$d" && find . -type f | sed 's#^\./##' | sort)
  [ "$want" = "$have" ] || { echo differs; return 0; }
  ( cd "$d" && printf '%s\n' "$man" | grep -v ' README\.md$' | sha256sum -c --quiet >/dev/null 2>&1 ) || { echo differs; return 0; }
  if ( cd "$d" && printf '%s\n' "$man" | grep ' README\.md$' | sha256sum -c --quiet >/dev/null 2>&1 ); then echo same; else echo readme; fi
}
publish() {
  local root="$1" n="$2" group="$3" replace="$4" dry="$5" commit="$6" man
  man=$(printf '%s' "$7" | base64 -d) || die "the file list did not arrive"
  [[ "$n" =~ ^[0-9]+$ ]] || die "version '$n' is not an integer"
  case "$root" in /*) ;; *) die "ROOT must be absolute: $root";; esac
  umask 027
  local dest="$root/v$n" now prev="" status stage parent
  now=$(date +%Y%m%d-%H%M%S)
  say "== $(hostname -s) as $(id -un) (groups: $(id -Gn)); hpcworker $n from $commit -> $dest"
  parent=$(dirname "$root"); [ -d "$parent" ] || die "$parent does not exist; nothing changed"
  [ -n "$group" ] || group=$(stat -c %G "$parent")   # the lab's group: the one that owns the directory above ROOT
  id -Gn | tr ' ' '\n' | grep -qx "$group" || die "this account is not in group $group; nothing changed"
  if [ -e "$root/current" ] && [ ! -L "$root/current" ]; then die "$root/current exists and is not a link; nothing changed"; fi
  [ -L "$root/current" ] && prev=$(readlink "$root/current")
  if [ -d "$dest" ]; then status=$(compare_to_manifest "$dest" "$man"); else status=new; fi
  # framework 11 brought the gate that every Beethoven browser key's forced command runs
  # (restrict,command=".../current/bin/hpcworker gate"); a version before it answers each key with
  # "unknown command 'gate'", so `current` never moves from 11 or later back below 11
  case "$prev" in v[0-9]*) [ "${prev#v}" -ge 11 ] 2>/dev/null && [ "$n" -lt 11 ] && die "current names $prev, whose gate the students' browser keys run; v$n has no gate, so every key would fail. Nothing changed";; esac
  say "   root: $([ -d "$root" ] && echo present || echo absent); group: $group; v$n: $status; current: ${prev:-none} -> v$n"
  if [ "$dry" = 1 ]; then say "   dry run: nothing written ($(printf '%s\n' "$man" | wc -l | tr -d ' ') files would be published)"; return 0; fi
  if [ ! -d "$root" ]; then mkdir "$root" || die "cannot create $root"; fi
  [ -n "$group" ] && { chgrp "$group" "$root" || die "chgrp $group $root failed"; }
  root_perms "$root" || die "could not set the permissions of $root"
  case "$status" in
    same) say "   v$n is already published with these files: not extracted again";;
    readme)
      # documentation only: the code a running chain reads is untouched, so the same version may carry it
      chmod u+w "$dest/README.md" && tar -x -O -f - README.md > "$dest/README.md" || die "could not update $dest/README.md"
      [ "$(compare_to_manifest "$dest" "$man")" = same ] || die "$dest/README.md does not match after the update"
      say "   v$n: README.md updated in place (only the documentation differed; the code is unchanged)";;
    differs)
      if [ "$replace" != 1 ]; then
        say "   v$n is published with different files:"
        ( cd "$dest" && printf '%s\n' "$man" | sha256sum -c 2>/dev/null | grep -v ': OK$' | sed 's/^/     /'
          find . -type f | sed 's#^\./##' | sort | while IFS= read -r f; do printf '%s\n' "$man" | grep -q "  $f\$" || echo "     $f: not in this publish"; done )
        die "publish them as the next integer version (framework/VERSION and bin/hpcworker's VERSION=), or rerun with --replace; nothing changed"
      fi
      mv -T "$dest" "$dest.replaced-$now" || die "could not move $dest aside"
      say "   the old v$n is kept as v$n.replaced-$now (a worker started on v$n now runs the new files)"
      status=replaced;;
  esac
  if [ "$status" = new ] || [ "$status" = replaced ]; then
    stage=$(mktemp -d "$root/.incoming-v$n.XXXXXX") || die "cannot make a staging directory in $root"
    tar -x -f - -C "$stage" --no-same-owner --no-same-permissions || die "tar failed; the partial copy is in $stage (remove it by hand)"
    [ "$(compare_to_manifest "$stage" "$man")" = same ] || die "the unpacked files do not match the manifest; left in $stage (remove it by hand)"
    set_perms "$stage" "$group" || die "could not set permissions on $stage"
    mv -T "$stage" "$dest" || die "could not rename $stage to $dest"
    say "   published v$n"
  fi
  set_perms "$dest" "$group" || die "could not set permissions on $dest"
  if [ "$prev" != "v$n" ]; then
    ln -s "v$n" "$root/.current-new.$$" && mv -T "$root/.current-new.$$" "$root/current" || die "could not point current at v$n (a .current-new link may be left in $root)"
    say "   current: ${prev:-none} -> v$n"
  else say "   current already names v$n"; fi
  printf '%s %s v%s %s %s current=%s\n' "$(date -u +%FT%TZ)" "$(id -un)" "$n" "$commit" "$status" "v$n" >> "$root/deploy.log"
  chmod 0640 "$root/deploy.log" 2>/dev/null
  say "== what changed"
  if [ -n "$prev" ] && [ "$prev" != "v$n" ] && [ -d "$root/$prev" ]; then
    diff -rq "$root/$prev" "$dest" | sed -e "s#$root/##g" -e 's/^/   /'
    [ "${PIPESTATUS[0]}" = 0 ] && say "   no file differs between $prev and v$n"
  elif [ "$status" = same ]; then say "   nothing: v$n was already published with these files and current already named it"
  elif [ "$status" = readme ]; then say "   README.md of v$n only"
  elif [ "$status" = replaced ]; then
    diff -rq "$dest.replaced-$now" "$dest" | sed -e "s#$root/##g" -e 's/^/   /'
  else say "   first publish under $root"; fi
  say "== the tree"
  ls -l "$root" | sed 's/^/   /'
  say "   current -> $(readlink "$root/current")"
  find "$dest" -printf '%M %u:%g %p\n' | sort -k3 | sed -e "s#$root/##" -e 's/^/   /'
  say "== ACLs"
  if command -v getfacl >/dev/null 2>&1; then getfacl -p "$root" "$dest" "$dest/bin/hpcworker" 2>&1 | grep -v '^$' | sed 's/^/   /'; else say "   (no getfacl here)"; fi
  say "   kept versions: $(cd "$root" && ls -d v[0-9]* 2>/dev/null | tr '\n' ' ')"
  say "== checks"
  say "   $(HPCW_HOME=/nonexistent/.hpcworker bash "$root/current/bin/hpcworker" version 2>&1) = hpcworker version through current"
  # each site profile, checked with framework 11's awk reader (no python3: warrior's login banner bans it)
  local f
  if [ "$n" -ge 11 ]; then
    for f in "$dest"/profiles/*.json; do say "   $(basename "$f"): $(HPCW_HOME=/nonexistent/.hpcworker bash "$dest/bin/hpcworker" profile check "$f" 2>&1 | tr '\n' ' ')"; done
  else say "   site profiles: not checked (v$n has no python-free check, and python3 is not run on the login node)"; fi
}

if [ "${1:-}" = --publish ]; then shift; publish "$@"; exit $?; fi

# ---- the maintainer's side --------------------------------------------------------------------------
HERE=$(cd "$(dirname "$0")/.." && pwd) || die "cannot find the repository"
FW="$HERE/framework"
site=wayne host=wsu-grid root="" group="" dry=0 replace=0 local_run=0
while [ $# -gt 0 ]; do case "$1" in
  --site) site="$2"; shift 2;; --host) host="$2"; shift 2;; --root) root="$2"; shift 2;;
  --group) group="$2"; shift 2;; --dry-run) dry=1; shift;; --replace) replace=1; shift;; --here) local_run=1; shift;;
  -h|--help) awk 'NR > 1 && /^set -uo pipefail/ { exit } NR > 1' "$0"; exit 0;;
  *) die "unknown option $1 (--help)";; esac; done

prof="$FW/profiles/$site.json"
[ -s "$prof" ] || die "no profile $prof"
si=$(sed -n 's/^ *"shared_install": *"\([^"]*\)".*/\1/p' "$prof" | head -1)
if [ -z "$root" ]; then
  [ -n "$si" ] || die "$prof names no shared_install; give --root DIR"
  [ "$(basename "$si")" = current ] || die "shared_install in $prof ($si) does not end in /current; give --root DIR"
  root=$(dirname "$si")
elif [ -n "$si" ] && [ "$root/current" != "$si" ]; then
  say "note: $prof names $si; accounts installed from that profile will not see $root/current"
fi
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "ROOT must be an absolute path of plain characters: $root"
# the group: given, or (empty) the group of the directory above ROOT on the cluster, oschome at Wayne State
[[ "$group" =~ ^[A-Za-z0-9._-]*$ ]] || die "bad group name $group"

n=$(tr -d '[:space:]' < "$FW/VERSION")
[[ "$n" =~ ^[0-9]+$ ]] || die "framework/VERSION is not an integer: $n"
grep -qx "VERSION=$n" "$FW/bin/hpcworker" || die "framework/VERSION is $n but bin/hpcworker says $(grep -m1 '^VERSION=' "$FW/bin/hpcworker"); move both together"

# exactly these files, nothing else from the tree (no tests, no caches)
files=$(cd "$FW" && { find bin lib jobs profiles -type f ! -path '*/__pycache__/*' ! -name '*.pyc'; printf '%s\n' VERSION README.md; } | sort)
[ -n "$files" ] || die "no files to publish"
# a CR held in a variable, and grep -U: under Git Bash a $'\r' inside $(...) matches every line, and
# grep without -U drops the CR of a CRLF line before matching
CR=$'\r'
cr=$(cd "$FW" && printf '%s\n' "$files" | while IFS= read -r f; do grep -U -l "$CR" "$f"; done)
[ -z "$cr" ] || die "CR line endings in: $(printf '%s' "$cr" | tr '\n' ' ') (bash and sbatch break on them)"
for f in bin/hpcworker lib/*.sh lib/adapters/*.sh jobs/*.sbatch; do ( cd "$FW" && bash -n $f ) || die "bash -n failed: $f"; done
manifest=$(cd "$FW" && printf '%s\n' "$files" | while IFS= read -r f; do sha256sum "$f"; done | sed 's/ \*/  /')
commit=$(cd "$HERE" && git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -n "$(cd "$HERE" && git status --porcelain -- framework 2>/dev/null)" ] && commit="$commit+uncommitted"

tmp=$(mktemp -d) || die "no local temp"
trap 'rm -rf "$tmp"' EXIT   # the laptop's own temp for the tarball
( cd "$FW" && printf '%s\n' "$files" > "$tmp/files" && tar -cf "$tmp/hpcworker-v$n.tar" -T "$tmp/files" ) || die "tar failed"
say "hpcworker $n ($commit): $(printf '%s\n' "$files" | wc -l | tr -d ' ') files, $(wc -c < "$tmp/hpcworker-v$n.tar" | tr -d ' ') bytes -> ${host}:$root/v$n (group ${group:-of the directory above it})$([ $dry = 1 ] && echo ', dry run')"

man_b64=$(printf '%s\n' "$manifest" | base64 | tr -d '\n')
args="--publish $root $n ${group:-''} $replace $dry $commit $man_b64"
if [ $local_run = 1 ]; then
  # shellcheck disable=SC2086
  bash "$0" --publish "$root" "$n" "$group" "$replace" "$dry" "$commit" "$man_b64" < "$tmp/hpcworker-v$n.tar"
  exit $?
fi
# the script travels as an argument (base64: no quoting, no temp file on the cluster); the tarball on stdin
self_b64=$(base64 < "$0" | tr -d '\n')
remote="bash -c \"\$(printf %s $self_b64 | base64 -d)\" deploy_shared.sh $args"
[ ${#remote} -lt 30000 ] || die "the command line would be ${#remote} characters; too long for a Windows ssh"
ssh -o BatchMode=yes -o ConnectTimeout=20 "$host" "$remote" < "$tmp/hpcworker-v$n.tar"
