#!/bin/bash
# Refresh interface/access/ from OpenSpineConsortium/beethoven-access, the access service's own
# repository since 2026-10-07, and write ORIGIN: the commit the copy came from, the export and its
# version, and each file's sha256 (tests/test_access_contract.py checks tools/grid_access.sh against
# the copy's lines.json and vectors, and tests/test_boundary.py the copy against ORIGIN). The copy is
# data, the contract the lab lead's tool codes to: nothing of that repository is run here, and nothing
# is read from a checkout of it (the interface standard, interface/README.md).
#
#   bash interface/access/pull.sh [--ref REF]   from GitHub through gh and its own sign-in (REF: main)
#
# REF must be a commit the repository's default branch contains (a merged change, never a pull
# request's branch), and only the files its interface/INTERFACE.json lists under the export "http-api"
# at that commit are taken, each to the same path under interface/access/ without "interface/contract/"
# (lines.json, routes.json, the schemas, vectors/). A file this copy has and the source no longer does
# is listed for a person to remove in a reviewed commit; nothing is deleted. The copy and ORIGIN are
# committed together.
set -euo pipefail
REPO=OpenSpineConsortium/beethoven-access
EXPORT=http-api WANT=1   # the export, and the version of it tools/grid_access.sh reads
PREFIX=interface/contract/   # where the export lives there; the copy drops it
REF=main
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:?--ref needs a branch, tag or commit}"; shift 2 ;;
    *) echo "usage: $0 [--ref REF]" >&2; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v gh >/dev/null || { echo "FAILED: gh is not installed" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FAILED: python3 is needed to read the export's paths" >&2; exit 1; }

sha=$(gh api "repos/$REPO/commits/$REF" --jq .sha)
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "FAILED: no commit for $REF" >&2; exit 1; }
default=$(gh api "repos/$REPO" --jq .default_branch)
case "$(gh api "repos/$REPO/compare/$default...$sha" --jq .status)" in
  identical|behind) ;;
  *) echo "FAILED: $sha is not on $REPO's $default; take only what was merged there" >&2; exit 1 ;;
esac
fetch() { gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$1?ref=$sha"; }

# the export's paths, as the provider's manifest at that commit lists them
manifest=$(fetch interface/INTERFACE.json) || { echo "FAILED: $REPO has no interface/INTERFACE.json at $sha" >&2; exit 1; }
patterns=$(printf '%s' "$manifest" | python3 -I -c '
import json, sys
m = json.load(sys.stdin)
e = [x for x in m.get("exports", []) if x.get("id") == sys.argv[1]]
if not e or e[0].get("version") != int(sys.argv[2]):
    sys.exit("export %s version %s is not offered (offered: %s)" % (sys.argv[1], sys.argv[2], ", ".join("%s %s" % (x.get("id"), x.get("version")) for x in m.get("exports", []))))
print("\n".join(e[0]["paths"]))' "$EXPORT" "$WANT") || { echo "FAILED: $REPO at $sha does not offer $EXPORT version $WANT" >&2; exit 1; }
# every path of the export sits under the one folder the copy drops; a path elsewhere has no place here
while IFS= read -r p; do
  [ -z "$p" ] || [[ "$p" == "$PREFIX"* ]] || { echo "FAILED: the export lists $p, which is not under $PREFIX; this copy takes only that folder" >&2; exit 1; }
done <<< "$patterns"
# a file the copy may hold: JSON within at most one folder, never one of the copy's own names (pull.sh,
# ORIGIN, README.md), so nothing the source holds can replace this script or the record of the copy
copyable() { [[ "${1#$PREFIX}" =~ ^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)?\.json$ ]]; }
listed() { # PATH -> 0 when one of the export's paths covers it ("dir/" a folder, "*" within one part)
  local p re
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [[ "$p" == */ ]]; then [[ "$1" == "$p"* ]] && return 0
    else re="^$(printf '%s' "$p" | sed -e 's/[.[\^$+?(){}|]/\\&/g' -e 's/\*/[^\/]*/g')\$"; [[ "$1" =~ $re ]] && return 0; fi
  done <<< "$patterns"
  return 1
}

paths=()
while IFS= read -r p; do listed "$p" || continue
  copyable "$p" || { echo "not taken: $p (the copy holds JSON files at most one folder deep)"; continue; }
  paths+=("$p"); done \
  < <(gh api "repos/$REPO/git/trees/$sha?recursive=1" --jq '.tree[] | select(.type == "blob") | .path')
[ "${#paths[@]}" -gt 0 ] || { echo "FAILED: nothing in the export at $sha" >&2; exit 1; }
origin=("repository $REPO" "commit $sha" "export $EXPORT $WANT")
for p in "${paths[@]}"; do
  rel="${p#$PREFIX}" dest="$HERE/${p#$PREFIX}"
  mkdir -p "$(dirname "$dest")"
  fetch "$p" >"$dest.part" || { rm -f "$dest.part"; echo "FAILED: could not read $p at $sha" >&2; exit 1; }
  mv -f "$dest.part" "$dest"
  origin+=("sha256 $(sha256sum "$dest" | cut -d' ' -f1) $rel")
done
printf '%s\n' "${origin[@]}" >"$HERE/ORIGIN.part"
mv -f "$HERE/ORIGIN.part" "$HERE/ORIGIN"
echo "interface/access: ${#paths[@]} file(s) from $REPO at $sha"
stale=0
taken=$(printf '%s\n' "${paths[@]}")
while IFS= read -r f; do
  rel="${f#$HERE/}"
  # a here-string, not a pipe: under pipefail a `printf | grep -q` reports a hit as a failure whenever
  # grep closes the pipe before printf is done, and a file the source still has was called stale
  grep -qxF "$PREFIX$rel" <<< "$taken" && continue
  echo "not in $REPO any more: interface/access/$rel (remove it in a reviewed commit)"
  stale=1
done < <(find "$HERE" -mindepth 1 -type f ! -name ORIGIN ! -name pull.sh ! -name README.md ! -name '*.part' | sort)
[ "$stale" = 0 ] || echo "then run the suite: HPCW_PYTHON=python3 bash framework/tests/run.sh"
