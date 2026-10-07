#!/bin/bash
# Refresh framework/sites/ from OpenSpineConsortium/beethoven-sites, where the site and lab modules
# are written and reviewed (greg, 2026-10-05: their own repository), and write ORIGIN: the commit they
# came from, the export and its version, and each file's sha256 (tests/test_sites.py and
# tests/test_boundary.py check the copy against it). The modules are data; nothing of that repository
# is run here, and nothing is read from a checkout of it (the interface standard, interface/README.md).
#
#   bash framework/sites/pull.sh [--ref REF]   from GitHub through gh and its own sign-in (REF: main)
#
# REF must be a commit the repository's default branch contains (a merged change, never a pull
# request's branch), and only the files its interface/INTERFACE.json lists under the export "modules"
# at that commit are taken, each to the same path under framework/sites/ without "sites/". A module
# this copy has and the source no longer does is listed for a person to remove in a reviewed commit;
# nothing is deleted. Then `python3 framework/lib/profile.py compose-all` writes the profiles, and the
# copy, ORIGIN and the profiles are committed together.
set -euo pipefail
REPO=OpenSpineConsortium/beethoven-sites
EXPORT=modules WANT=1   # the export, and the version of it this framework reads
REF=main
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:?--ref needs a branch, tag or commit}"; shift 2 ;;
    *) echo "usage: $0 [--ref REF]" >&2; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
module() { [[ "$1" =~ ^sites/[a-z0-9][a-z0-9-]*/(site|labs/[a-z0-9][a-z0-9-]*)\.json$ ]]; }
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
while IFS= read -r p; do module "$p" && listed "$p" && paths+=("$p"); done \
  < <(gh api "repos/$REPO/git/trees/$sha?recursive=1" --jq '.tree[] | select(.type == "blob") | .path')
[ "${#paths[@]}" -gt 0 ] || { echo "FAILED: no modules in the export at $sha" >&2; exit 1; }
origin=("repository $REPO" "commit $sha" "export $EXPORT $WANT")
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
