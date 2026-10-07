#!/usr/bin/env bash
# A change to what tools/deploy_shared.sh publishes as the lab's shared copy moves framework/VERSION
# with it. The shared copy keeps one folder per version and refuses a version already published with
# other files, so a commit that changed those files under the same version would be refused by the
# grid's install (tools/grid_ci.sh --watch) after it merged; this says so before, on the pull request.
#
#   tools/version_check.sh BASE HEAD    HEAD against its merge base with BASE (commits or refs)
#   tools/version_check.sh --list       the paths that count
#
# The paths are deploy_shared.sh's own list, read from that script so the two cannot drift: the
# folders its `find` names and the single files beside them, under framework/. README.md is left out:
# a publish updates it in place under the same version. It also fails when VERSION and bin/hpcworker's
# VERSION= line disagree at HEAD, and when VERSION went down. Exit 0 ok, 1 refused, 2 could not tell.
set -uo pipefail
die() { printf 'version_check: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'version_check: %s\n' "$*" >&2; exit 1; }
REPO=$(cd "$(dirname "$0")/.." && pwd) || die "cannot find the repository"
DS="$REPO/tools/deploy_shared.sh"

# deploy_shared's line: files=$(cd "$FW" && { find bin lib jobs profiles -type f ...; printf '%s\n' VERSION README.md; } | sort)
line=$(grep -m1 '^files=$(cd "$FW" && { find ' "$DS" 2>/dev/null) || die "cannot find the list of published files in $DS"
re_dirs='[{] find ([A-Za-z0-9_./ -]+) -type f'
re_files='printf .%s\\n. ([A-Za-z0-9_. -]+);'
[[ $line =~ $re_dirs ]] || die "cannot read the folders deploy_shared.sh publishes from: $line"
dirs=${BASH_REMATCH[1]}
[[ $line =~ $re_files ]] || die "cannot read the single files deploy_shared.sh publishes from: $line"
singles=${BASH_REMATCH[1]}
paths=()
for p in $dirs $singles; do
  [[ "$p" =~ ^[A-Za-z0-9_.-]+$ ]] || die "an odd name in deploy_shared.sh's list: $p"
  [ "$p" = README.md ] || paths+=("framework/$p")
done
[ ${#paths[@]} -ge 2 ] || die "deploy_shared.sh's list looks empty: ${paths[*]:-nothing}"
if [ "${1:-}" = --list ]; then printf '%s\n' "${paths[@]}"; exit 0; fi
[ $# = 2 ] || die "usage: tools/version_check.sh BASE HEAD"

G() { git -C "$REPO" "$@"; }
base=$(G rev-parse --verify -q "$1^{commit}") || die "no commit $1 here (a shallow checkout? fetch with depth 0)"
head=$(G rev-parse --verify -q "$2^{commit}") || die "no commit $2 here"
mb=$(G merge-base "$base" "$head") || die "$1 and $2 share no history"
ver() { G show "$1:framework/VERSION" 2>/dev/null | tr -d '[:space:]'; }
was=$(ver "$mb"); now=$(ver "$head")
[[ "$now" =~ ^[0-9]+$ ]] || refuse "framework/VERSION at $2 is not a whole number: '$now'"
said=$(G show "$head:framework/bin/hpcworker" 2>/dev/null | sed -n 's/^VERSION=\([^[:space:]]*\).*/\1/p' | head -1)
[ "$said" = "$now" ] || refuse "framework/VERSION is $now but bin/hpcworker's VERSION= line says ${said:-nothing}; move both together"
[[ "$was" =~ ^[0-9]+$ ]] || was=""   # no readable version before: nothing to compare with
if [ -n "$was" ] && [ "$now" -lt "$was" ]; then refuse "framework/VERSION went down, from $was to $now; versions only go up"; fi

# what deploy_shared would publish differently (it leaves out python's caches, so these do too)
changed=$(G diff --name-only "$mb" "$head" -- "${paths[@]}" | grep -v -e '/__pycache__/' -e '\.pyc$' -e '^framework/VERSION$')
count=$(printf '%s' "$changed" | grep -c . || true)
if [ "$count" -gt 0 ] && [ "$now" = "$was" ]; then
  shown=$(printf '%s\n' "$changed" | head -5 | tr '\n' ' ' | sed 's/ $//'); [ "$count" -gt 5 ] && shown="$shown and $((count - 5)) more"
  refuse "$count file(s) the lab's shared copy publishes changed ($shown) while framework/VERSION stayed $now; raise it and bin/hpcworker's VERSION= line to $((now + 1)) together: the shared copy never takes other files under a version it has published, so the grid's install would refuse this commit"
fi
printf 'version_check: framework/VERSION %s -> %s, %s published file(s) changed: ok\n' "${was:-none}" "$now" "$count"
