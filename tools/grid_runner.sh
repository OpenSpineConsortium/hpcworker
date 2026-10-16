#!/bin/bash
# A GitHub Actions runner on the grid: run ON the cluster (the portal's shell), never by GitHub.
# GitHub's runners cannot reach the grid (the VPN and a one-time code stand between), and no
# token of the grid's or GitHub's ever enters a repository, a job file or an argv (CLAUDE.md), so
# the connection points the other way, as the CI lane's does: GitHub's own self-hosted runner runs
# as a Slurm job on a compute node and polls GitHub over outbound HTTPS. A workflow job that names
# the runner's labels (`runs-on: [self-hosted, grid]`) then runs on that node, and GitHub keeps
# its log and its artifacts as for any job. The runner is registered for one job at a time with a
# just-in-time credential that the account's own `gh` sign-in mints as the registration starts
# and that GitHub discards once the job has run: GitHub holds nothing of the grid's, and the grid
# holds nothing of GitHub's beyond that one-job credential, three mode-0600 files on the node's
# own disk that leave with the job.
#
#   tools/grid_runner.sh --install --site S [--version 2.338.0]
#   tools/grid_runner.sh --start --repo OWNER/NAME --site S [--labels a,b] [--hours 8] [--margin 60]
#                        [--cpus 2] [--mem 8G] [--gres gpu:1] [--partition P] [--qos Q] [--slurm]
#   tools/grid_runner.sh --stop --repo OWNER/NAME --site S [--now]
#   tools/grid_runner.sh --status --site S [--repo OWNER/NAME]
#
# --site S names the site profile, framework/profiles/S.json, read with the framework's own awk
# reader (lib/profile_sh.sh), since a login node's banner may ban python3 and nothing here starts it
# there: the runtime's path and module, the worker queue (partition_cpu_batch and qos_batch, which
# --partition and --qos override) and where the runner's folder is, beside the account's state on
# the lab volume (shared_state_dir with -runner added). --runner-dir DIR, or HPCW_RUNNER_DIR, names
# the folder instead, and a command with neither a site nor a folder is refused.
#
# --install: one job on a compute node (tools/grid_runner_install.sbatch) pulls GitHub's own runner
# image, ghcr.io/actions/actions-runner:<version> (latest unless --version says), as a SIF into
# <runner dir>/image, copies the runner's files out of it, runs the runner's --version inside the
# image with the flags every job will use (so a flag the site's Apptainer refuses is seen here and
# never in a chain) and names the version in <runner dir>/image/current. Compute nodes run the
# image because the runner, a .NET 8 application, is built for RHEL 8 and later, which an EL7 node
# is not; the container sees neither the account's home nor the lab volume nor the environment
# (--containall --cleanenv --no-mount bind-paths), only its own copy of the runner's files and a
# /tmp on the node's own disk. The install job runs on the chain's queue.
#
# --start: on the login node file work, one `gh api` (the repository must be private or internal;
# GitHub advises against self-hosted runners on a public repository, whose forks' pull requests
# could run code on the grid), one squeue (one chain per repository and account: a job of the
# chain's name already queued or running is refused) and one sbatch. The chain is
# tools/grid_runner.sbatch, --hours of wall time on the site's worker queue (the profile's
# partition_cpu_batch and qos_batch, or --partition and --qos; --cpus, --mem and --gres size it),
# requeueable, and each job first queues its one successor (--dependency=afterany:<its own id>,
# singleton), so the runner is back after a wall time or a preemption with nobody at the keyboard.
# In the job: the repository's visibility is read again; the runner's files are copied out of the
# image onto the node's disk; then, until --margin minutes before the wall time, one registration
# at a time: `gh api` mints a just-in-time runner
# (name grid-<site>-<job>-<n>; labels grid, the site's name and --labels, beside the self-hosted,
# linux and x64 GitHub adds) into a 0600 file on the node's disk, the three files it carries are
# written 0600 into the runner's folder, that file goes, and the runner listens for one job. A job
# that completes ends the runner (GitHub removes the registration itself), the work folder goes,
# and the next registration follows. A runner still idle at the margin, or once STOP is written,
# is ended and its registration deleted; one running a job finishes it first. A job the wall time
# cuts off fails on GitHub ("the runner has lost communication"), so the margin is the longest job
# the chain should take, and a workflow's timeout-minutes stays under it. The job asks nothing of
# the scheduler: it reads STOP and its own clock once a minute. With --slurm the host's Slurm
# client is bound into the container as the worker's is (lib/adapters/common.sh
# hpcw_slurm_in_container), so a step may queue a job of its own with sbatch.
#
# --stop writes <chain dir>/STOP, which every job reads before each registration, and cancels the
# queued successor (one squeue, one scancel); a job running a GitHub job finishes it first, an idle
# one ends within a minute. --now cancels the running job too, and the GitHub job on it fails.
# --status is file work (<chain dir>/status.json, which the job writes, read with awk) and one squeue.
#
# Nothing of Beethoven's runs in a workflow's job and no Claude credential is anywhere near one:
# the runner runs the repository's steps and nothing else. The credential never touches a command
# line (gh writes it to a file, the file is read into the runner's folder); the login node sees
# file work, gh, one squeue and one sbatch; nothing is deleted but the node's own temp. Every job
# is submitted with GITHUB_TOKEN and GH_TOKEN removed from the environment sbatch hands it.
set -uo pipefail
say() { printf '%s\n' "$*"; }
die() { printf 'grid_runner: %s\n' "$*" >&2; exit 1; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (--help)"; }

MODE="" REPO="" VERSION=latest SITE="" LABELS="" HOURS=8 MARGIN=60 CPUS="" MEM="" GRES="" SLURM=0 NOW=0
RUNTIME_BIN_GIVEN="" RUNTIME_MODULE_GIVEN=""
while [ $# -gt 0 ]; do case "$1" in
  --install) MODE=install; shift;; --start) MODE=start; shift;; --stop) MODE=stop; shift;; --status) MODE=status; shift;;
  --repo) need "$@"; REPO="$2"; shift 2;; --version) need "$@"; VERSION="$2"; shift 2;;
  --site) need "$@"; SITE="$2"; shift 2;; --labels) need "$@"; LABELS="$2"; shift 2;;
  --hours) need "$@"; HOURS="$2"; shift 2;; --margin) need "$@"; MARGIN="$2"; shift 2;;
  --cpus) need "$@"; CPUS="$2"; shift 2;; --mem) need "$@"; MEM="$2"; shift 2;; --gres) need "$@"; GRES="$2"; shift 2;;
  --partition) need "$@"; HPCW_RUNNER_PARTITION="$2"; shift 2;; --qos) need "$@"; HPCW_RUNNER_QOS="$2"; shift 2;;
  --slurm) SLURM=1; shift;; --now) NOW=1; shift;;
  # the jobs' own: what --install hands the install job and --start hands the first job of a chain, and each job its successor
  --pull) MODE=pull; shift;; --serve) MODE=serve; shift;; --runner-dir) need "$@"; HPCW_RUNNER_DIR="$2"; shift 2;;
  --runtime-bin) need "$@"; RUNTIME_BIN_GIVEN="$2"; shift 2;; --runtime-module) need "$@"; RUNTIME_MODULE_GIVEN="$2"; shift 2;;
  -h|--help) awk 'NR > 1 && /^set -uo pipefail/ { exit } NR > 1' "$0"; exit 0;;
  *) die "unknown option $1 (--help)";; esac; done
[ -n "$MODE" ] || die "one of --install, --start, --stop or --status (--help)"
[ -z "$REPO" ] || [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo is OWNER/NAME: $REPO"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad --version $VERSION"
[[ "$SITE" =~ ^[A-Za-z0-9._-]*$ ]] || die "bad --site $SITE"
[ -z "$LABELS" ] || [[ "$LABELS" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]] || die "--labels is a comma-separated list of names: $LABELS"
case ",$LABELS," in *,self-hosted,*|*,linux,*|*,x64,*|*,grid,*) die "--labels: self-hosted, linux and x64 are GitHub's own labels and grid is every chain's; name others";; esac
{ [[ "$HOURS" =~ ^[0-9]+$ ]] && [ "$HOURS" -ge 1 ] && [ "$HOURS" -le 336 ]; } || die "--hours is a job's wall time in hours, 1 to 336: $HOURS"
{ [[ "$MARGIN" =~ ^[0-9]+$ ]] && [ "$MARGIN" -ge 1 ] && [ "$MARGIN" -lt $((HOURS * 60)) ]; } || die "--margin is minutes before the wall time, 1 to under the wall time: $MARGIN"
[ -z "$CPUS" ] || [[ "$CPUS" =~ ^[0-9]+$ ]] || die "bad --cpus $CPUS"
[ -z "$MEM" ] || [[ "$MEM" =~ ^[0-9]+[KMGTkmgt]?$ ]] || die "bad --mem $MEM (as sbatch takes it: 8G)"
[ -z "$GRES" ] || [[ "$GRES" =~ ^[A-Za-z0-9:._,-]+$ ]] || die "bad --gres $GRES"
case "$MODE" in start|stop|serve) [ -n "$REPO" ] || die "--$MODE needs --repo OWNER/NAME";; esac
USER=${USER:-$(id -un)}; export USER   # the profile reader expands $USER in the lab volume's path
HERE=$(cd "$(dirname "$0")" && pwd) || die "cannot find the folder of $0"
# python3 only inside a job, on a compute node (the registration's files are decoded there); a login
# node's banner may ban it by name, so a person's command never looks for it
PY=""; case "$MODE" in pull|serve) PY=$(command -v python3 || echo /usr/bin/python3);; esac

# the site profile, for a person's command on the login node, read with the framework's own awk
# reader and handed to the jobs as options (--runner-dir, --runtime-bin, --runtime-module,
# --partition, --qos), so a job needs nothing of the framework beside common.sh
FW="$HERE/../framework" STATE_DIR=""
prof_get() { # KEY: one value of the site profile, $HOME and $USER expanded
  ( LIB="$FW/lib" PROFILES="$FW/profiles"; . "$FW/lib/profile_sh.sh" && hpcw_prof_awk get "$FW/profiles/$SITE.json" "$1" )
}
site_profile() {
  local f="$FW/profiles/$SITE.json"
  [ -f "$f" ] || die "no site profile $f"
  if [ -z "$RUNTIME_BIN_GIVEN$RUNTIME_MODULE_GIVEN" ]; then
    RUNTIME_BIN_GIVEN=$(prof_get runtime_bin) && RUNTIME_MODULE_GIVEN=$(prof_get runtime_module) || die "profile $f unreadable"
  fi
  [ -n "${HPCW_RUNNER_PARTITION:-}" ] || HPCW_RUNNER_PARTITION=$(prof_get partition_cpu_batch) || die "profile $f unreadable"
  [ -n "${HPCW_RUNNER_QOS:-}" ] || HPCW_RUNNER_QOS=$(prof_get qos_batch) || die "profile $f unreadable"
  STATE_DIR=$(prof_get shared_state_dir) || die "profile $f unreadable"
}
case "$MODE" in install|start|stop|status) [ -z "$SITE" ] || site_profile;; esac
[[ "${HPCW_RUNNER_PARTITION:-}${HPCW_RUNNER_QOS:-}" =~ ^[A-Za-z0-9._,-]*$ ]] || die "bad --partition or --qos"
[[ "$RUNTIME_BIN_GIVEN$RUNTIME_MODULE_GIVEN" =~ ^[A-Za-z0-9._/-]*$ ]] || die "bad --runtime-bin or --runtime-module"
if [ -z "${HPCW_RUNNER_DIR:-}" ]; then
  [ -n "$STATE_DIR" ] || die "--site S names the site profile (framework/profiles/S.json), which says where the runner's folder is; or name the folder with --runner-dir DIR"
  case "$STATE_DIR" in /*) ;; *) die "the site profile's shared_state_dir is no absolute path: $STATE_DIR";; esac
  case "$STATE_DIR" in *'$'*) die "the site profile's shared_state_dir names a variable beside \$HOME and \$USER: $STATE_DIR";; esac
  HPCW_RUNNER_DIR="${STATE_DIR%/}-runner"
fi
case "$HPCW_RUNNER_DIR" in /*) ;; *) die "the runner's folder must be an absolute path: $HPCW_RUNNER_DIR";; esac

# the account's gh sign-in, not a GITHUB_TOKEN a ~/.bashrc may export for another account
GHBIN=$(command -v gh || true); [ -n "$GHBIN" ] || GHBIN="$HOME/.local/bin/gh"
GH() { net env -u GITHUB_TOKEN -u GH_TOKEN "$GHBIN" "$@"; }
slurm_bin() { command -v "$1" || echo "/opt/hpcw/slurm/bin/$1"; }
SBATCH=$(slurm_bin sbatch) SQUEUE=$(slurm_bin squeue) SCANCEL=$(slurm_bin scancel)
# sbatch hands a job the environment it was typed in (--export=ALL): never a token with it, and
# from inside a job never this node's per-job temp either (each job makes its own)
SB_ENV=(env -u GITHUB_TOKEN -u GH_TOKEN); case "$MODE" in serve|pull) SB_ENV+=(-u TMPDIR);; esac
SB() { "${SB_ENV[@]}" "$SBATCH" "$@"; }
SQ() { "${SB_ENV[@]}" "$SQUEUE" "$@"; }
SC() { "${SB_ENV[@]}" "$SCANCEL" "$@"; }
# a network call that hangs must not hold a job's minute (or a person's terminal) for ever
net() { if command -v timeout >/dev/null 2>&1; then timeout 300 "$@"; else "$@"; fi; }

ROOT="$HPCW_RUNNER_DIR"
IMAGES="$ROOT/image"
CHAIN="$ROOT/${REPO//\//-}"          # one folder per repository: STOP, next, status.json, the jobs' logs
JOB_NAME="hpcw_runner_${REPO//\//-}"  # unique per repository and account: --dependency=singleton keys on it
IMAGE_REF=ghcr.io/actions/actions-runner

# what the install job and every job of a chain are handed: grid_runner.sh's own options on the job's
# command line (so each job hands them to its successor) and sbatch's flags, which outrank a file's
# #SBATCH lines
JOB_ARGS=() SB_FLAGS=() SITE_ARGS=() QUEUE=()
job_args() {
  SITE_ARGS=(--runner-dir "$ROOT")
  [ -n "$SITE" ] && SITE_ARGS+=(--site "$SITE")
  [ -n "$RUNTIME_BIN_GIVEN" ] && SITE_ARGS+=(--runtime-bin "$RUNTIME_BIN_GIVEN")
  [ -n "$RUNTIME_MODULE_GIVEN" ] && SITE_ARGS+=(--runtime-module "$RUNTIME_MODULE_GIVEN")
  JOB_ARGS=(--repo "$REPO" "${SITE_ARGS[@]}" --hours "$HOURS" --margin "$MARGIN")
  [ -n "$LABELS" ] && JOB_ARGS+=(--labels "$LABELS")
  [ $SLURM = 1 ] && JOB_ARGS+=(--slurm)
  [ -n "$CPUS" ] && JOB_ARGS+=(--cpus "$CPUS")
  [ -n "$MEM" ] && JOB_ARGS+=(--mem "$MEM")
  [ -n "$GRES" ] && JOB_ARGS+=(--gres "$GRES")
  [ -n "${HPCW_RUNNER_PARTITION:-}" ] && JOB_ARGS+=(--partition "$HPCW_RUNNER_PARTITION")
  [ -n "${HPCW_RUNNER_QOS:-}" ] && JOB_ARGS+=(--qos "$HPCW_RUNNER_QOS")
  QUEUE=()
  [ -n "${HPCW_RUNNER_PARTITION:-}" ] && QUEUE+=(--partition "$HPCW_RUNNER_PARTITION")
  [ -n "${HPCW_RUNNER_QOS:-}" ] && QUEUE+=(--qos "$HPCW_RUNNER_QOS")
  SB_FLAGS=(--time "$HOURS:00:00" ${QUEUE[@]+"${QUEUE[@]}"})
  [ -n "$CPUS" ] && SB_FLAGS+=(--cpus-per-task "$CPUS")
  [ -n "$MEM" ] && SB_FLAGS+=(--mem "$MEM")
  [ -n "$GRES" ] && SB_FLAGS+=(--gres "$GRES")
  return 0
}
job_id() { # OUT: the job number in sbatch --parsable's answer, read from among a site's warnings
  local l; l=$(printf '%s\n' "$1" | grep -E '^[0-9]+(;|$)' | head -1)
  [ -n "$l" ] && printf '%s' "${l%%;*}"
}

# the chain's own copy of what it runs, in <runner dir>/bin: a checkout that changes under a queued job
# cannot break it, and a person's --start or --install refreshes it, only when every file parses
COPIED=(grid_runner.sh grid_runner.sbatch grid_runner_install.sbatch)
install_bin() { # DIR: the tools folder to copy from; common.sh comes from the framework beside it
  local f src
  for f in "${COPIED[@]}"; do bash -n "$1/$f" 2>/dev/null || { say "$1/$f is missing or does not parse"; return 1; }; done
  src="$1/../framework/lib/adapters/common.sh"
  bash -n "$src" 2>/dev/null || { say "$src is missing or does not parse"; return 1; }
  mkdir -p "$ROOT/bin" || return 1
  for f in "${COPIED[@]}"; do
    cp "$1/$f" "$ROOT/bin/.$f.new" && chmod 755 "$ROOT/bin/.$f.new" && mv -f "$ROOT/bin/.$f.new" "$ROOT/bin/$f" || { say "could not copy $f into $ROOT/bin"; return 1; }
  done
  cp "$src" "$ROOT/bin/.common.sh.new" && chmod 644 "$ROOT/bin/.common.sh.new" && mv -f "$ROOT/bin/.common.sh.new" "$ROOT/bin/common.sh" || { say "could not copy common.sh into $ROOT/bin"; return 1; }
}

visibility() { # -> private | internal | public, or 1 with gh's own words (a warning of gh's beside the answer is passed over)
  local out v
  out=$(GH api "repos/$REPO" --jq .visibility 2>&1) || { say "gh could not read $REPO ($(printf '%s\n' "$out" | tail -1)); gh auth status says which account is signed in" >&2; return 1; }
  v=$(printf '%s\n' "$out" | grep -xE 'private|internal|public' | head -1)
  [ -n "$v" ] || { say "gh answered something else than a visibility for $REPO: $(printf '%s\n' "$out" | tail -1)" >&2; return 1; }
  printf '%s' "$v"
}
refuse_public() { # 0 when the repository may have a runner
  local v; v=$(visibility) || return 1
  [ "$v" != public ] || { say "refused: $REPO is public. A self-hosted runner serves a private or internal repository only (GitHub's own advice: a public repository's forks could run their pull requests on the grid)"; return 1; }
  return 0
}
installed_version() { # -> the version <runner dir>/image/current names, with its SIF in place
  local v; v=$(cat "$IMAGES/current" 2>/dev/null | tr -d '[:space:]')
  [ -n "$v" ] && [ -s "$IMAGES/actions-runner-$v.sif" ] || return 1
  printf '%s' "$v"
}

# ---- on the login node ---------------------------------------------------------------------------
install_start() {
  local out
  mkdir -p "$IMAGES" || die "cannot create $IMAGES"
  install_bin "$HERE" || die "nothing started"
  job_args
  out=$(SB --parsable --job-name hpcw_runner_install ${QUEUE[@]+"${QUEUE[@]}"} -D "$ROOT" --output "$IMAGES/install-%j.log" "$ROOT/bin/grid_runner_install.sbatch" --pull --version "$VERSION" "${SITE_ARGS[@]}" 2>&1) \
    || die "sbatch refused the install job: $out"
  say "install is job $(job_id "$out" || printf '%s' "$out"): it pulls $IMAGE_REF:$VERSION on a compute node into $IMAGES and tries the runner there once"
  say "its log is $IMAGES/install-<job>.log; when it ends with 'installed', tools/grid_runner.sh --start --repo OWNER/NAME starts a chain"
}

chain_start() {
  local v q out
  [ -x "$GHBIN" ] || die "gh is not installed (https://cli.github.com; gh auth login once)"
  v=$(installed_version) || die "no runner image is installed under $IMAGES: tools/grid_runner.sh --install first, and wait for its job"
  refuse_public || die "nothing started"
  mkdir -p "$CHAIN" || die "cannot create $CHAIN"
  q=$(SQ -h -u "$USER" -n "$JOB_NAME" -o '%i %T' 2>&1) || die "squeue did not answer: $q"
  [ -z "$q" ] || die "a chain for $REPO is already queued or running (job $(printf '%s' "$q" | tr '\n' ' ' | sed 's/ *$//')); tools/grid_runner.sh --stop --repo $REPO ends it"
  install_bin "$HERE" || die "nothing started"
  rm -f "$CHAIN/STOP" "$CHAIN/next" "$CHAIN/next.submitting"
  job_args
  { printf 'repo=%s\nversion=%s\nlabels=%s\nsite=%s\nhours=%s\nmargin=%s\nslurm=%s\nstarted=%s\n' "$REPO" "$v" "grid${SITE:+,$SITE}${LABELS:+,$LABELS}" "$SITE" "$HOURS" "$MARGIN" "$SLURM" "$(date -u +%FT%TZ)"
    printf 'sbatch=%s\n' "${SB_FLAGS[*]}"; } > "$CHAIN/config" || die "cannot write $CHAIN/config"
  out=$(SB --parsable --job-name "$JOB_NAME" --dependency=singleton "${SB_FLAGS[@]}" -D "$ROOT" --output "$CHAIN/runner-%j.log" "$ROOT/bin/grid_runner.sbatch" --serve "${JOB_ARGS[@]}" 2>&1) \
    || die "sbatch refused the chain's first job: $out"
  say "runner chain for $REPO: job $(job_id "$out" || printf '%s' "$out"), $HOURS h of wall time a job, a successor queued by each; runner image $v"
  say "a workflow job reaches it with: runs-on: [self-hosted, grid${SITE:+, $SITE}${LABELS:+, ${LABELS//,/, }}]  (GitHub adds linux and x64); each of its jobs must end within $MARGIN minutes"
  say "logs are $CHAIN/runner-<job>.log; tools/grid_runner.sh --status --repo $REPO shows the chain; --stop --repo $REPO ends it"
}

chain_stop() {
  local q ids running
  mkdir -p "$CHAIN" && date -u +%FT%TZ > "$CHAIN/STOP" || die "cannot write $CHAIN/STOP"
  q=$(SQ -h -u "$USER" -n "$JOB_NAME" -o '%i %T' 2>&1) || die "squeue did not answer ($q); STOP is written, so each job ends before its next registration"
  [[ "$q" =~ ^[0-9A-Z_[:space:]]*$ ]] || die "squeue answered something else than jobs: $q"
  ids=$(printf '%s\n' "$q" | awk '$2 == "PENDING" { print $1 }' | tr '\n' ' ' | sed 's/ *$//')
  running=$(printf '%s\n' "$q" | awk '$2 != "PENDING" && NF { print $1 }' | tr '\n' ' ' | sed 's/ *$//')
  [ $NOW = 1 ] && ids="$ids${ids:+ }$running"
  if [ -n "${ids// /}" ]; then
    # shellcheck disable=SC2086
    SC $ids || die "scancel failed; STOP is written, so each job ends before its next registration"
    say "cancelled job ${ids// /, }"
  else say "no job of the chain was queued"; fi
  if [ -n "$running" ] && [ $NOW = 0 ]; then
    say "job $running keeps running: a GitHub job on it finishes first, an idle runner ends within a minute; --now would cancel it and fail the GitHub job"
  fi
  say "STOP written: no job of this chain registers a runner again until tools/grid_runner.sh --start --repo $REPO"
}

last_word() { # FILE: the one line status_write wrote, read with awk (no python3 on a login node)
  LC_ALL=C awk '
    function field(k,   s, i, v, c) {
      i = index($0, "\"" k "\":"); if (!i) return ""
      s = substr($0, i + length(k) + 3)
      if (substr(s, 1, 1) != "\"") { sub(/[,}].*/, "", s); return s }
      s = substr(s, 2); v = ""
      while (s != "") {
        c = substr(s, 1, 1)
        if (c == "\\") { v = v substr(s, 2, 1); s = substr(s, 3) }
        else if (c == "\"") break
        else { v = v c; s = substr(s, 2) }
      }
      return v
    }
    NR == 1 && index($0, "{\"repo\":") == 1 && field("state") != "" {
      r = field("runner"); n = field("note")
      printf "  last word: %s, job %s on %s, runner %s, %s GitHub jobs done, since %s%s\n", field("state"), field("job"), field("node"), (r == "" ? "none" : r), field("jobs_done"), field("since"), (n == "" ? "" : "; " n)
      ok = 1
    }
    END { exit ok ? 0 : 1 }' "$1" 2>/dev/null
}
chain_status() {
  local q d v
  say "runner folder: $ROOT"
  v=$(installed_version) && say "runner image: $v ($IMAGES/actions-runner-$v.sif)" || say "runner image: none installed (tools/grid_runner.sh --install)"
  q=$(SQ -h -u "$USER" -o '%i %T %j %M %N' 2>&1) || die "squeue did not answer: $q"
  for d in "$ROOT"/*/; do
    d=${d%/}; [ -f "$d/config" ] || continue
    [ -z "$REPO" ] || [ "$d" = "$CHAIN" ] || continue
    say "chain $(sed -n 's/^repo=//p' "$d/config"): labels $(sed -n 's/^labels=//p' "$d/config"), started $(sed -n 's/^started=//p' "$d/config")$([ -e "$d/STOP" ] && printf ', STOP written %s' "$(cat "$d/STOP")")"
    printf '%s\n' "$q" | awk -v n="hpcw_runner_$(basename "$d")" '$3 == n { printf "  job %s %s, %s on %s\n", $1, $2, $4, ($5 == "" ? "no node yet" : $5) }'
    if [ -f "$d/status.json" ]; then
      last_word "$d/status.json" || say "  status.json unreadable"
    else say "  no job has written status.json yet"; fi
  done
  return 0
}

# ---- inside a job ----------------------------------------------------------------------------------
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
NT="" IPC=""
node_tmp() { # the node's own disk, never the volume's $TMPDIR (CephFS at Wayne State); removed on exit whatever way the job ends
  NT="/tmp/$USER/hpcw_runner_$SLURM_JOB_ID"; IPC="/dev/shm/$USER/hpcw_runner_$SLURM_JOB_ID"
  mkdir -p "$NT/tmp" "$NT/cache" && chmod 700 "$NT" || { log "cannot create $NT"; return 1; }
  trap 'cleanup_tmp' EXIT
  export TMPDIR="$NT/tmp" APPTAINER_TMPDIR="$NT/tmp" SINGULARITY_TMPDIR="$NT/tmp" APPTAINER_CACHEDIR="$NT/cache" SINGULARITY_CACHEDIR="$NT/cache"
}
cleanup_tmp() { # only this job's own folders, by their names, as hpcw_rm_own_tmp does
  local p
  for p in "$NT" "$IPC"; do
    case "$p" in */hpcw_runner_[0-9]*) [ -d "$p" ] && rm -rf "$p";; esac
  done
}
load_runtime() { # the given path, else the module, else PATH
  RUNTIME_BIN="$RUNTIME_BIN_GIVEN"
  if [ -n "$RUNTIME_BIN" ] && [ -x "$RUNTIME_BIN" ]; then return 0; fi
  if [ -n "$RUNTIME_MODULE_GIVEN" ]; then
    [ -f /etc/profile.d/modules.sh ] && source /etc/profile.d/modules.sh 2>/dev/null
    [ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh 2>/dev/null
    if command -v module >/dev/null 2>&1; then module load "$RUNTIME_MODULE_GIVEN" >/dev/null 2>&1 || true; fi
  fi
  RUNTIME_BIN=$(command -v apptainer 2>/dev/null) || RUNTIME_BIN=""
  [ -n "$RUNTIME_BIN" ] && [ -x "$RUNTIME_BIN" ] || { log "no apptainer on $(hostname -s) (--runtime-bin ${RUNTIME_BIN_GIVEN:-none}, --runtime-module ${RUNTIME_MODULE_GIVEN:-none})"; return 1; }
}
# the container as every job runs it: no home, no lab volume, none of the environment, none of the
# site's own binds; the runner's folder on the node's disk as /home/runner and a node-local /tmp
RCMD=()
runner_cmd() { # IMAGE HOME [-B ...] -- CMD...: RCMD is the command line
  local image="$1" home="$2"; shift 2
  RCMD=("$RUNTIME_BIN" exec --containall --cleanenv --no-mount bind-paths --pwd /home/runner --home "$home:/home/runner" -B "$NT/tmp:/tmp")
  while [ $# -gt 0 ] && [ "$1" != -- ]; do RCMD+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  RCMD+=("$image" "$@")
}
runner_tree() { # IMAGE DEST: the runner's files copied out of the image onto the node's disk (the image is read-only, and the runner writes beside its own files)
  mkdir -p "$2" && chmod 700 "$2" || return 1
  "$RUNTIME_BIN" exec --containall --cleanenv --no-mount bind-paths -B "$2:/mnt/out" "$1" cp -R --preserve=mode,timestamps /home/runner/. /mnt/out/ \
    && [ -x "$2/bin/Runner.Listener" ]
}

pull() { # the install job: the image, the runner's files out of it, its --version inside, then the SIF and `current` on the volume
  local v out part
  [ -n "${SLURM_JOB_ID:-}" ] || die "--pull runs inside the install job; start it with --install"
  say() { log "$@"; }
  log "== install job $SLURM_JOB_ID on $(hostname -s), kernel $(uname -r)"
  node_tmp || exit 1
  load_runtime || exit 2
  log "runtime: $RUNTIME_BIN ($("$RUNTIME_BIN" --version 2>&1 | head -1))"
  log "pulling docker://$IMAGE_REF:$VERSION (temp and cache on $NT)"
  "$RUNTIME_BIN" pull "$NT/image.sif" "docker://$IMAGE_REF:$VERSION" > "$NT/pull.log" 2>&1 \
    || { tail -5 "$NT/pull.log"; log "STOP: the pull failed (registry egress from this node, or no such version)"; exit 3; }
  runner_tree "$NT/image.sif" "$NT/home" || { log "STOP: could not copy the runner's files out of the image"; exit 4; }
  runner_cmd "$NT/image.sif" "$NT/home" -- /home/runner/bin/Runner.Listener --version
  out=$("${RCMD[@]}" 2>&1); v=$(printf '%s\n' "$out" | tail -1 | tr -d '[:space:]')
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '%s\n' "$out" | tail -5; log "STOP: the runner did not answer its version inside the image"; exit 5; }
  log "the runner answers inside the image: version $v"
  mkdir -p "$IMAGES" || { log "STOP: cannot create $IMAGES"; exit 6; }
  part="$IMAGES/actions-runner-$v.sif.part"
  cp "$NT/image.sif" "$part" && mv -f "$part" "$IMAGES/actions-runner-$v.sif" || { rm -f "$part"; log "STOP: could not place the image under $IMAGES"; exit 6; }
  printf '%s\n' "$v" > "$IMAGES/current.new" && mv -f "$IMAGES/current.new" "$IMAGES/current" || { log "STOP: cannot write $IMAGES/current"; exit 6; }
  log "installed: runner $v at $IMAGES/actions-runner-$v.sif ($(du -sh "$IMAGES/actions-runner-$v.sif" 2>/dev/null | cut -f1)); tools/grid_runner.sh --start --repo OWNER/NAME starts a chain"
}

# the chain job's clock: the scheduler's own end time where Slurm exports it (23.02 and later), else the
# start and --hours; HPCW_RUNNER_CLOCK names a file with the time, for the tests only (their sleep returns
# at once, so a test moves the clock itself)
now() { if [ -n "${HPCW_RUNNER_CLOCK:-}" ]; then cat "$HPCW_RUNNER_CLOCK"; else date +%s; fi; }
end_time() {
  local start
  if [[ "${SLURM_JOB_END_TIME:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$SLURM_JOB_END_TIME"; return 0; fi
  start=${SLURM_JOB_START_TIME:-}; [[ "$start" =~ ^[0-9]+$ ]] || start=$(now)
  printf '%s' $((start + HOURS * 3600))
}
iso() { date -u -d "@$1" +%FT%TZ 2>/dev/null || printf '%s' "$1"; }
over() { [ "$(now)" -ge "$DEADLINE" ] || [ -e "$CHAIN/STOP" ]; }   # no new registration, and an idle runner ends

JOBS_DONE=0 RUNNER_ID="" RUNNER_NAME="" DEADLINE=0 SINCE="" IMAGE_VERSION="" LAST_STATE=""
status_write() { # STATE [NOTE]: <chain dir>/status.json, what --status and a person read; the job asks the scheduler nothing
  local note="${2:-}" f="$CHAIN/status.json"
  note=${note//\\/\\\\}; note=${note//\"/\\\"}
  printf '{"repo":"%s","job":"%s","node":"%s","state":"%s","runner":"%s","version":"%s","jobs_done":%s,"since":"%s","deadline":"%s","note":"%s"}\n' \
    "$REPO" "${SLURM_JOB_ID:-}" "$(hostname -s)" "$1" "$RUNNER_NAME" "$IMAGE_VERSION" "$JOBS_DONE" "$SINCE" "$(iso "$DEADLINE")" "$note" > "$f.new" && mv -f "$f.new" "$f"
  LAST_STATE=$1
}

successor() { # this job's one successor, queued once even when this job is run again after a requeue
  local out id
  if [ -s "$CHAIN/next" ] && [ "$(cut -d' ' -f1 "$CHAIN/next")" = "$SLURM_JOB_ID" ]; then
    log "next job: $(cut -d' ' -f2 "$CHAIN/next"), queued by an earlier run of this job"; return 0
  fi
  if [ "$(cat "$CHAIN/next.submitting" 2>/dev/null)" = "$SLURM_JOB_ID" ]; then
    # an earlier run of this same job stopped while it submitted: one squeue says whether that got through
    id=$(SQ -h -u "$USER" -n "$JOB_NAME" -t PENDING -o '%i' 2>/dev/null | grep -vx "$SLURM_JOB_ID" | head -1)
    if [ -n "$id" ]; then
      printf '%s %s\n' "$SLURM_JOB_ID" "$id" > "$CHAIN/next" && rm -f "$CHAIN/next.submitting"
      log "next job: $id, queued by an earlier run of this job"; return 0
    fi
  fi
  printf '%s\n' "$SLURM_JOB_ID" > "$CHAIN/next.submitting"
  out=$(SB --parsable --job-name "$JOB_NAME" --dependency="afterany:$SLURM_JOB_ID,singleton" "${SB_FLAGS[@]}" -D "$ROOT" --output "$CHAIN/runner-%j.log" "$ROOT/bin/grid_runner.sbatch" --serve "${JOB_ARGS[@]}" 2>&1) \
    || { rm -f "$CHAIN/next.submitting"; log "could not queue the next job: $(printf '%s' "$out" | tail -1)"; return 1; }
  id=$(job_id "$out") || { log "next job: queued, but the scheduler gave no job number ($(printf '%s' "$out" | tail -1))"; return 0; }
  printf '%s %s\n' "$SLURM_JOB_ID" "$id" > "$CHAIN/next" && rm -f "$CHAIN/next.submitting"
  log "next job: $id, after this one ends"
}

HOME_DIR="" IMAGE="" EXTRA=()   # the runner's folder on the node's disk (/home/runner inside), the SIF, the Slurm binds
mint() { # N: one just-in-time registration; its three files 0600 in the runner's folder, nothing on a command line
  local n=$1 req="$NT/jit-request.json" resp="$NT/jit-response.json" labels l
  RUNNER_NAME="grid-${SITE:-$(hostname -s)}-$SLURM_JOB_ID-$n"
  labels='"grid"'; for l in ${SITE:+"$SITE"} ${LABELS//,/ }; do labels="$labels,\"$l\""; done
  ( umask 077; printf '{"name":"%s","runner_group_id":1,"labels":[%s],"work_folder":"_work"}\n' "$RUNNER_NAME" "$labels" > "$req" ) || return 1
  rm -f "$resp"
  if ! ( umask 077; GH api -X POST "repos/$REPO/actions/runners/generate-jitconfig" --input "$req" > "$resp" 2> "$NT/gh.err" ); then
    log "GitHub did not register a runner: $(tail -1 "$NT/gh.err" 2>/dev/null)"; rm -f "$resp"; return 1
  fi
  RUNNER_ID=$("$PY" - "$resp" "$HOME_DIR" <<'PYEOF' 2> "$NT/py.err"
import base64, json, os, sys
resp, root = sys.argv[1], sys.argv[2]
with open(resp) as f:
    answer = json.load(f)
files = json.loads(base64.b64decode(answer["encoded_jit_config"]).decode("utf-8"))
known = {".runner", ".credentials", ".credentials_rsaparams"}
if set(files) - known:
    sys.exit("the registration carries other files than the runner's: " + ",".join(sorted(set(files) - known)))
if ".runner" not in files or ".credentials" not in files:
    sys.exit("the registration carries no .runner or .credentials")
for name in sorted(files):
    fd = os.open(os.path.join(root, name), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(base64.b64decode(files[name]))
print(int(answer["runner"]["id"]))
PYEOF
  ) || { log "the registration could not be read: $(tail -1 "$NT/py.err" 2>/dev/null)"; rm -f "$resp"; return 1; }
  rm -f "$resp"
  printf '%s %s\n' "$RUNNER_ID" "$RUNNER_NAME" > "$CHAIN/registered"
  log "registered runner $RUNNER_NAME (id $RUNNER_ID, labels ${labels//\"/})"
}
unregister() { # ID: a registration GitHub has not discarded itself (the runner never took a job)
  local out
  out=$(GH api -X DELETE "repos/$REPO/actions/runners/$1" --silent 2>&1) && log "runner registration $1 deleted" \
    || log "note: could not delete runner registration $1 (gone already?): $(printf '%s' "$out" | tail -1)"
  rm -f "$CHAIN/registered"
}
busy() { # a GitHub job is running: the runner's worker has written its log (an ended job ends the runner itself, so the file means a job in flight)
  local f; for f in "$HOME_DIR"/_diag/Worker_*.log; do [ -e "$f" ] && return 0; done; return 1
}
LPID="" RC=0 KILLED=0
end_listener() { # the runner is ended; a job on it would fail, so this is called only while it is idle
  kill -TERM "$LPID" 2>/dev/null
  local i; for i in 1 2 3 4 5 6; do kill -0 "$LPID" 2>/dev/null || return 0; sleep 5; done
  kill -KILL "$LPID" 2>/dev/null; return 0
}
run_listener() { # one run of the runner on the registration in place, looked at once a minute -> RC, KILLED
  runner_cmd "$IMAGE" "$HOME_DIR" ${EXTRA[@]+"${EXTRA[@]}"} -- /home/runner/bin/Runner.Listener run
  "${RCMD[@]}" & LPID=$!
  KILLED=0
  while kill -0 "$LPID" 2>/dev/null; do
    sleep 60
    kill -0 "$LPID" 2>/dev/null || break
    if busy; then
      [ "$LAST_STATE" = busy ] || status_write busy
      if over; then log "a GitHub job is running on $RUNNER_NAME; waiting for it"; fi
      continue
    fi
    if over; then
      log "ending the idle runner $RUNNER_NAME ($([ -e "$CHAIN/STOP" ] && echo "STOP is set" || echo "the margin is reached"))"
      KILLED=1; end_listener; break
    fi
  done
  wait "$LPID" 2>/dev/null; RC=$?
}
keep_diag() { # N: the runner's own logs kept beside the chain's log when a run ended badly, for a person to read
  local d="$CHAIN/diag-$SLURM_JOB_ID-$1"
  [ -d "$HOME_DIR/_diag" ] || return 0
  mkdir -p "$d" && cp "$HOME_DIR"/_diag/*.log "$d/" 2>/dev/null && log "the runner's logs are kept in $d"
  return 0
}
fresh_work() { rm -rf "$HOME_DIR/_work" "$HOME_DIR/_diag"; }

serve() {
  local n=0 fails=0 chained=1 leftover ended=0 end_state=ending end_note=""
  [ -n "${SLURM_JOB_ID:-}" ] || die "--serve runs inside a chain's job; start the chain with --start"
  say() { log "$@"; }
  [ -x "$GHBIN" ] || die "gh is not installed (https://cli.github.com; gh auth login once)"
  SINCE=$(date -u +%FT%TZ); IMAGE_VERSION=$(cat "$IMAGES/current" 2>/dev/null | tr -d '[:space:]')
  log "== runner job $SLURM_JOB_ID for $REPO on $(hostname -s), kernel $(uname -r)"
  mkdir -p "$CHAIN"
  if [ -e "$CHAIN/STOP" ]; then log "STOP is set ($CHAIN/STOP): the chain ends here; tools/grid_runner.sh --start --repo $REPO starts it again"; status_write stopped "STOP was set"; return 0; fi
  job_args
  successor || chained=0
  DEADLINE=$(( $(end_time) - MARGIN * 60 ))
  log "wall time ends $(iso "$(end_time)"); the last registration is made before $(iso "$DEADLINE") ($MARGIN minutes of margin)"
  status_write starting
  refuse_public || { date -u +%FT%TZ > "$CHAIN/STOP"; status_write refused "the repository is public; STOP written"; log "STOP written: no job of this chain registers a runner until the repository is private again and --start is run"; return 1; }
  # a registration an earlier job left behind (a preemption, a wall time with the runner idle): GitHub keeps it listed, offline
  leftover=$(cut -d' ' -f1 "$CHAIN/registered" 2>/dev/null); [[ "$leftover" =~ ^[0-9]+$ ]] && unregister "$leftover"
  node_tmp || { status_write failed "no node-local temp"; return 1; }
  load_runtime || { status_write failed "no apptainer on this node"; return 2; }
  IMAGE="$IMAGES/actions-runner-$IMAGE_VERSION.sif"
  [ -s "$IMAGE" ] || { log "no runner image at $IMAGE (tools/grid_runner.sh --install)"; status_write failed "no runner image"; return 3; }
  HOME_DIR="$NT/home"
  runner_tree "$IMAGE" "$HOME_DIR" || { log "could not copy the runner's files out of $IMAGE"; status_write failed "the image could not be read"; return 4; }
  if [ $SLURM = 1 ]; then
    # shellcheck disable=SC1090
    source "$ROOT/bin/common.sh" || { log "no $ROOT/bin/common.sh"; status_write failed "no common.sh"; return 5; }
    export RUNTIME=apptainer RUNTIME_BIN HPCW_NODE_TMP="$NT"
    mkdir -p "$IPC" && chmod 700 "$IPC"
    if HPCW_HOST_TMPDIR="${HPCW_HOST_TMPDIR:-}" hpcw_slurm_in_container "$IPC/slurm" "$IMAGE" sif; then
      log "$HPCW_SLURM_NOTE"
      # shellcheck disable=SC2206
      EXTRA=($HPCW_SLURM_BINDS); export APPTAINERENV_PREPEND_PATH="$HPCW_SLURM_INSIDE" SINGULARITYENV_PREPEND_PATH="$HPCW_SLURM_INSIDE"
    else log "the Slurm client is not bound: $HPCW_SLURM_NOTE"; fi
  fi
  log "the runner's files are on $(hostname -s):$HOME_DIR; image $IMAGE_VERSION"
  while [ $ended = 0 ]; do
    if over; then
      log "$([ -e "$CHAIN/STOP" ] && echo "STOP is set" || echo "no time for another job before the wall time ($MARGIN minutes of margin)"): this job ends"; break
    fi
    n=$((n + 1))
    if ! mint "$n"; then
      fails=$((fails + 1))
      [ $fails -le 3 ] || { log "GitHub refused three registrations in a row: this job ends"; end_state=failed end_note="GitHub refused three registrations in a row"; break; }
      status_write idle "registration refused; trying again"; sleep 60; continue
    fi
    status_write idle
    # the registration is run until it ends for good: a retryable error, or an update GitHub required, runs it again
    while :; do
      run_listener
      if [ $KILLED = 1 ]; then unregister "$RUNNER_ID"; fresh_work; ended=1; break; fi
      case "$RC" in
        0) JOBS_DONE=$((JOBS_DONE + 1)); fails=0; log "runner $RUNNER_NAME ended after its job ($JOBS_DONE done in this job)"; rm -f "$CHAIN/registered"; fresh_work; status_write idle; break;;
        2|3|4)
          fails=$((fails + 1)); keep_diag "$n"
          [ "$RC" = 2 ] && log "the runner asked to be started again (a retryable error)"
          [ "$RC" = 2 ] || log "the runner updated itself (GitHub required a newer version); tools/grid_runner.sh --install takes the new image"
          [ $fails -le 3 ] || { log "three times in a row: this job ends"; unregister "$RUNNER_ID"; fresh_work; end_state=failed end_note="the runner failed three times in a row"; ended=1; break; }
          sleep 5
          if over; then unregister "$RUNNER_ID"; fresh_work; ended=1; break; fi;;
        *)
          fails=$((fails + 1)); log "the runner ended with code $RC"; keep_diag "$n"; unregister "$RUNNER_ID"; fresh_work
          [ $fails -le 3 ] || { log "three failures in a row: this job ends"; end_state=failed end_note="the runner failed three times in a row"; ended=1; break; }
          sleep 60; break;;
      esac
    done
  done
  RUNNER_NAME=""; status_write "$end_state" "$JOBS_DONE GitHub jobs ran in this job${end_note:+; $end_note}"
  log "== job $SLURM_JOB_ID ends: $JOBS_DONE GitHub jobs ran${end_note:+; $end_note}$([ $chained = 0 ] && echo "; no successor could be queued, so the chain ends here: tools/grid_runner.sh --start --repo $REPO starts it again")"
  [ $chained = 1 ]
}

case "$MODE" in
  install) install_start;;
  start) chain_start;;
  stop) chain_stop;;
  status) chain_status;;
  pull) pull;;
  serve) serve;;
esac
