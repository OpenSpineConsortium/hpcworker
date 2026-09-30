#!/usr/bin/env bash
# Push main to the organisation's private repository OpenSpineConsortium/beethoven (the only remote since 2026-09-30;
# the personal copy GregorySchwing/ashley-bridge is retired). The grid token used by
# push_via_grid.sh has no rights in the organisation, so this runs where a GitHub credential with those
# rights is stored: on the maintainer's machine that is WSL (git credential.helper=store).
#   wsl -e bash -lc 'bash /mnt/c/Users/grego/OneDrive/Desktop/beethoven/tools/push_org.sh'
# (the folder is Desktop/ashley-bridge until the maintainer renames it to beethoven)
# or from any Linux/macOS shell whose git can push to the organisation.
set -euo pipefail
cd "$(dirname "$0")/.."
git push https://github.com/OpenSpineConsortium/beethoven.git main:main --tags 2>&1 | tail -3
