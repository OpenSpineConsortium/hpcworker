#!/bin/bash
# hpcworker build_image: make the worker image for a site that has none. NOT RUN ON WAYNE STATE
# (an image exists there: the shared sandbox of Beethoven for VS Code named in profiles/wayne.json); written from
# bootstrap.sbatch's guards and the Apptainer documentation, untested on a real cluster.
#
# Product: an Apptainer SIF from docker://node:22-bookworm with Claude Code pinned to
# CLAUDE_CODE_VERSION. Two routes, tried in order:
#   1. a definition file whose %post runs Claude Code's native installer (needs --fakeroot, which
#      depends on the site's user-namespace and /etc/subuid setup);
#   2. without fakeroot: the plain base image as a SIF, and Claude Code installed with npm into a
#      prefix next to the image (the layout Wayne State uses). The job prints the claude_bin to
#      put in the profile in either case.
# Runs only inside a job (container commands never run on a login node); temp and cache on the
# compute node's local disk, removed on exit whatever way the job ends. SIF over sandbox on
# purpose: Lustre, GPFS and PanFS homes lack overlay support (Apptainer admin guide).
#   sbatch -D <image dir> --export=ALL,HPCW_HOME=$HOME/.hpcworker,IMAGE_OUT=<dir>/claude-node22.sif,CLAUDE_CODE_VERSION=2.1.283 build_image.sbatch
#SBATCH --job-name=hpcw_build_image
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=02:00:00
#SBATCH --output=build_image_%j.out
set -uo pipefail
HPCW_HOME="${HPCW_HOME:-$HOME/.hpcworker}"
# the code: HPCW_CODE when given, else the lab's shared copy this account uses (~/.hpcworker/shared names it), else ~/.hpcworker
if [ -z "${HPCW_CODE:-}" ] && [ -s "$HPCW_HOME/shared" ]; then IFS= read -r HPCW_CODE < "$HPCW_HOME/shared"; fi
HPCW_CODE="${HPCW_CODE:-$HPCW_HOME}"
# shellcheck disable=SC1090
source "$HPCW_CODE/lib/adapters/common.sh" || { echo "REFUSING: $HPCW_CODE/lib/adapters/common.sh missing (run hpcworker install)"; exit 1; }
JOB=$(hpcw_job_id)
if [ -z "$JOB" ]; then echo "REFUSING: this builds a container and must run as a scheduler job (sbatch), not on $(hostname -s)"; exit 1; fi
IMAGE_OUT="${IMAGE_OUT:?set IMAGE_OUT=<dir>/claude-node22.sif}"
BASE="${BASE:-docker://node:22-bookworm}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:?set CLAUDE_CODE_VERSION=<version> (an exact version; the image is pinned)}"
export RUNTIME="${RUNTIME:-apptainer}" RUNTIME_BIN="${RUNTIME_BIN:-}" RUNTIME_MODULE="${RUNTIME_MODULE:-}"
say() { echo "$(date -u +%FT%TZ) $*"; }
say "build_image job $JOB on $(hostname -s): $BASE + Claude Code $CLAUDE_CODE_VERSION -> $IMAGE_OUT"
hpcw_load_runtime || { echo "STOP: no $RUNTIME runtime on $(hostname -s) (RUNTIME_BIN=$RUNTIME_BIN RUNTIME_MODULE=$RUNTIME_MODULE)"; exit 2; }
case "$RUNTIME" in apptainer|singularity) ;; *) echo "STOP: build_image knows apptainer/singularity only"; exit 2;; esac
OUT_DIR=$(dirname "$IMAGE_OUT"); mkdir -p "$OUT_DIR" || { echo "STOP: cannot create $OUT_DIR"; exit 2; }
# node-local temp with a cleanup trap: the pull, the layers and the build scratch never touch shared storage
HPCW_NODE_TMP=$(hpcw_node_tmp); export HPCW_NODE_TMP
mkdir -p "$HPCW_NODE_TMP/tmp" "$HPCW_NODE_TMP/cache" || { echo "STOP: no node-local temp at $HPCW_NODE_TMP"; exit 2; }
trap 'hpcw_rm_own_tmp "$HPCW_NODE_TMP"' EXIT   # the guarded helper: only a per-job directory is ever removed
export TMPDIR="$HPCW_NODE_TMP/tmp" APPTAINER_TMPDIR="$HPCW_NODE_TMP/tmp" SINGULARITY_TMPDIR="$HPCW_NODE_TMP/tmp" APPTAINER_CACHEDIR="$HPCW_NODE_TMP/cache" SINGULARITY_CACHEDIR="$HPCW_NODE_TMP/cache"
say "temp and cache on $(hostname -s):$HPCW_NODE_TMP ($(df -Pk "$HPCW_NODE_TMP" | awk 'NR==2{printf "%.1f GB free", $4/1048576}'))"
if [ -s "$IMAGE_OUT" ]; then say "image exists: $IMAGE_OUT (remove it to rebuild)"; exit 0; fi

# ---- route 1: %post with the native installer (fakeroot) -------------------------------------
DEF="$HPCW_NODE_TMP/claude.def"
cat > "$DEF" <<'DEFEOF'
Bootstrap: docker
From: __BASE__

%post
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends git curl ca-certificates procps tmux util-linux python3 less
    rm -rf /var/lib/apt/lists/*
    # Claude Code's native installer, pinned; the binary is copied to /usr/local/bin so every user
    # runs the same one and no user-writable install path exists inside the image
    export HOME=/root DISABLE_AUTOUPDATER=1
    if curl -fsSL https://claude.ai/install.sh | bash -s -- __VERSION__ && [ -e /root/.local/bin/claude ]; then
        cp -L /root/.local/bin/claude /usr/local/bin/claude && chmod 755 /usr/local/bin/claude
        rm -rf /root/.local/share/claude /root/.local/bin/claude
    else
        npm install -g "@anthropic-ai/claude-code@__VERSION__"
    fi
    /usr/local/bin/claude --version

%environment
    export DISABLE_AUTOUPDATER=1
    export LC_ALL=C.UTF-8

%labels
    org.hpcworker.claude_code_version __VERSION__
    org.hpcworker.base __BASE__
DEFEOF
sed -i -e "s#__BASE__#$BASE#g" -e "s#__VERSION__#$CLAUDE_CODE_VERSION#g" "$DEF"
say "route 1: $RUNTIME_BIN build --fakeroot (user namespaces: $(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo unknown))"
if "$RUNTIME_BIN" build --fakeroot "$IMAGE_OUT.part" "$DEF" > "$HPCW_NODE_TMP/build1.log" 2>&1 && "$RUNTIME_BIN" exec "$IMAGE_OUT.part" claude --version > "$HPCW_NODE_TMP/v.txt" 2>&1; then
  mv -f "$IMAGE_OUT.part" "$IMAGE_OUT"
  say "built $IMAGE_OUT ($(du -sh "$IMAGE_OUT" | cut -f1)); claude $(tail -1 "$HPCW_NODE_TMP/v.txt")"
  echo "PROFILE: image_store {\"type\":\"sif\",\"path\":\"$IMAGE_OUT\"}; claude_bin /usr/local/bin/claude"
  exit 0
fi
say "route 1 failed (fakeroot unavailable or the installer refused); last lines:"; tail -5 "$HPCW_NODE_TMP/build1.log"; rm -f "$IMAGE_OUT.part"

# ---- route 2: plain base as SIF + npm prefix beside it (no root of any kind) -------------------
say "route 2: $RUNTIME_BIN build $IMAGE_OUT.part $BASE"
"$RUNTIME_BIN" build "$IMAGE_OUT.part" "$BASE" > "$HPCW_NODE_TMP/build2.log" 2>&1 || { tail -5 "$HPCW_NODE_TMP/build2.log"; echo "STOP: cannot build the base image (registry egress from this node?)"; exit 3; }
mv -f "$IMAGE_OUT.part" "$IMAGE_OUT"
NPM_PREFIX="$OUT_DIR/npm-claude-$CLAUDE_CODE_VERSION"; mkdir -p "$NPM_PREFIX" "$OUT_DIR/npm-cache"
"$RUNTIME_BIN" exec -B "$OUT_DIR" -B "$HPCW_NODE_TMP/tmp:/tmp" "$IMAGE_OUT" env npm_config_cache="$OUT_DIR/npm-cache" npm install -g --prefix "$NPM_PREFIX" "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" > "$HPCW_NODE_TMP/npm.log" 2>&1 || { tail -20 "$HPCW_NODE_TMP/npm.log"; echo "STOP: npm install failed"; exit 4; }
V=$("$RUNTIME_BIN" exec -B "$OUT_DIR" -B "$HPCW_NODE_TMP/tmp:/tmp" "$IMAGE_OUT" "$NPM_PREFIX/bin/claude" --version 2>&1 | tail -1)
say "built $IMAGE_OUT ($(du -sh "$IMAGE_OUT" | cut -f1)) with Claude Code beside it: $V"
echo "PROFILE: image_store {\"type\":\"sif\",\"path\":\"$IMAGE_OUT\"}; claude_bin $NPM_PREFIX/bin/claude; add $OUT_DIR to binds"
