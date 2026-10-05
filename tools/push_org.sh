#!/usr/bin/env bash
# Push main to this repository, OpenSpineConsortium/hpcworker. Until the split of 2026-10-03 this pushed
# to OpenSpineConsortium/beethoven, which became the project hub on 2026-10-05; a push from here must
# never reach it, so the script refuses a checkout that is not hpcworker's. (The personal copy
# GregorySchwing/ashley-bridge is retired.) The grid token used by
# push_via_grid.sh has no rights in the organisation, so this runs where a GitHub credential with those
# rights is stored: on the maintainer's machine that is WSL (git credential.helper=store).
#   wsl -e bash -lc 'bash /mnt/c/Users/grego/OneDrive/Desktop/hpcworker/tools/push_org.sh'
# (or wherever the hpcworker checkout lives)
# or from any Linux/macOS shell whose git can push to the organisation.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -x framework/bin/hpcworker ] || { echo "not an hpcworker checkout: nothing pushed" >&2; exit 1; }
git push https://github.com/OpenSpineConsortium/hpcworker.git main:main --tags 2>&1 | tail -3
