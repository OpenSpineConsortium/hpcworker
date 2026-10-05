#!/bin/bash
# Refresh framework/sites/ from OpenSpineConsortium/beethoven-sites, where the site and lab modules
# are written and reviewed (greg, 2026-10-05: their own repository), and write ORIGIN: the commit they
# came from and each file's sha256 (tests/test_sites.py checks the copy against it). The modules are
# data; nothing of that repository is run here.
#
#   bash framework/sites/pull.sh --from DIR    DIR: a beethoven-sites checkout; its committed HEAD is copied
#   bash framework/sites/pull.sh [--ref REF]   from GitHub through gh and its own sign-in (REF: main)
#
# Only sites/<site>/site.json and sites/<site>/labs/<lab>.json are copied, each to the same path under
# framework/sites/. A module this copy has and the source no longer does is listed for a person to
# remove in a reviewed commit; nothing is deleted. Then `python3 framework/lib/profile.py compose-all`
# writes the profiles, and the copy, ORIGIN and the profiles are committed together.
set -euo pipefail
REPO=OpenSpineConsortium/beethoven-sites
FROM="" REF=main
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:?--from needs a directory}"; shift 2 ;;
    --ref) REF="${2:?--ref needs a branch, tag or commit}"; shift 2 ;;
    *) echo "usage: $0 --from BEETHOVEN_SITES_DIR | [--ref REF]" >&2; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
module() { [[ "$1" =~ ^sites/[a-z0-9][a-z0-9-]*/(site|labs/[a-z0-9][a-z0-9-]*)\.json$ ]]; }

if [ -n "$FROM" ]; then
  git -C "$FROM" rev-parse --verify -q HEAD >/dev/null || { echo "FAILED: $FROM is not a git checkout" >&2; exit 1; }
  [ -z "$(git -C "$FROM" status --porcelain -- sites)" ] \
    || { echo "FAILED: $FROM has uncommitted changes under sites/; commit them first, so ORIGIN names what was copied" >&2; exit 1; }
  sha=$(git -C "$FROM" rev-parse HEAD)
  list() { git -C "$FROM" ls-tree -r --name-only "$sha" -- sites; }
  fetch() { git -C "$FROM" show "$sha:$1"; }
else
  command -v gh >/dev/null || { echo "FAILED: gh is not installed; use --from with a checkout" >&2; exit 1; }
  sha=$(gh api "repos/$REPO/commits/$REF" --jq .sha)
  list() { gh api "repos/$REPO/git/trees/$sha?recursive=1" --jq '.tree[] | select(.type == "blob") | .path'; }
  fetch() { gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$1?ref=$sha"; }
fi
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "FAILED: no commit for $REF" >&2; exit 1; }

paths=()
while IFS= read -r p; do module "$p" && paths+=("$p"); done < <(list)
[ "${#paths[@]}" -gt 0 ] || { echo "FAILED: no modules under sites/ at $sha" >&2; exit 1; }
origin=("repository $REPO" "commit $sha")
for p in "${paths[@]}"; do
  rel="${p#sites/}" dest="$HERE/${p#sites/}"
  mkdir -p "$(dirname "$dest")"
  fetch "$p" >"$dest.part" || { rm -f "$dest.part"; echo "FAILED: could not read $p at $sha" >&2; exit 1; }
  mv -f "$dest.part" "$dest"
  origin+=("sha256 $(sha256sum "$dest" | cut -d' ' -f1) $rel")
done
printf '%s\n' "${origin[@]}" >"$HERE/ORIGIN.part"
mv -f "$HERE/ORIGIN.part" "$HERE/ORIGIN"
echo "framework/sites: ${#paths[@]} module(s) from $REPO at $sha"
stale=0
while IFS= read -r f; do
  rel="${f#$HERE/}"
  printf '%s\n' "${paths[@]}" | grep -qxF "sites/$rel" && continue
  echo "not in $REPO any more: framework/sites/$rel (remove it in a reviewed commit)"
  stale=1
done < <(find "$HERE" -mindepth 2 -name '*.json' -type f | sort)
[ "$stale" = 0 ] || echo "then run python3 framework/lib/profile.py compose-all"
