#!/bin/bash
# One job of the chain that keeps the grid's access lists: `tools/grid_access.sh --watch` submits the
# first with -D <vendor>/access-watch, and each queues the next itself (--begin, --dependency=singleton)
# before it applies anything. It runs the chain's own copy of grid_access.sh from bin/ there, never a
# checkout's, with the root, the site, the service and the minutes on its command line, so it needs
# neither the site profile nor the framework. The token is the vendor folder's grid_token, which reads
# the access service's two lists and nothing else; it leaves that file only for a configuration file curl
# reads, made under the TMPDIR below and gone with it (never an argument, a line of the log or this
# job's environment). The partition and QoS arrive on sbatch's command line (grid_access.sh takes
# HPCW_ACCESS_PARTITION and HPCW_ACCESS_QOS, else the CI lane's, else grid_ci.sbatch's own), so this
# file names no site's queue. Requeueable: a requeued job finds its successor already queued. Thirty
# minutes of wall time, where a look with nothing new takes seconds: a reader of the whole volume ("."
# in the reader list) is swept inside a job, and how long that walk takes on the grid is not yet measured.
#SBATCH --job-name=hpcw_access
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:30:00
#SBATCH --output=access.log
#SBATCH --open-mode=append
#SBATCH --requeue
set -uo pipefail
# started by a person's terminal or a worker: either way the job runs as a person's would, and no token
# a shell exported rides into the jobs it submits; the node's verdict below is this job's own to give
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN
unset HPCW_ACCESS_NO_TMP
: "${SLURM_JOB_ID:?this file is a job of the chain; tools/grid_access.sh --watch submits it}"
me=$(id -un) node=$(hostname -s 2>/dev/null || hostname)
# the job starts in the folder -D named (the chain's folder; its log lands there too)
[ -f bin/grid_access.sh ] || { echo "no bin/grid_access.sh in $(pwd): the chain runs from its own folder (tools/grid_access.sh --watch)"; exit 1; }
# Slurm runs its own copy of this file, taken when the job was queued, so these checks hold even when
# bin/ has changed since: the vendor folder, the chain's folder, bin/ and the script must be this
# account's own, and no other account may write them, or that account could have put its own script
# there, to run as this one beside the token (an ACL entry that lets another write raises the mask, which
# stat shows in the group's place). A failure ends the chain, since its next job would run the same script
mine() { # PATH: what is wrong with it, or nothing
  local u m
  if [ -L "$1" ]; then echo "$1 is a link"; return 0; fi
  u=$(stat -c %U -- "$1" 2>/dev/null) m=$(stat -c %a -- "$1" 2>/dev/null)
  if [ "$u" != "$me" ]; then echo "$1 belongs to ${u:-an account stat cannot name}, not to $me"; return 0; fi
  case "${m: -2}" in *[2367]*) echo "group or other may write in $1 (mode $m; fix: chmod go-w $1)";; esac
}
here=$(pwd -P)
for p in "${here%/*}" "$here" "$here/bin" "$here/bin/grid_access.sh"; do
  why=$(mine "$p")
  [ -z "$why" ] || { echo "$why: another account could change what this job runs. Nothing applied, and the chain ends here; tools/grid_access.sh --watch starts it again once that is fixed"; exit 1; }
done
# The token's configuration file and every other temporary file on this node's own disk, in a folder of
# this job's alone: the volume's $TMPDIR is not node-local. /tmp/<account> must be this account's own
# real folder, closed to writing by others (another account may have made it, or put a link there,
# before this job ran, and chmod would follow a link), before this job's folder is made in it; that one
# is new, or this job's own from an earlier run (a requeue onto the same node whose cleanup never ran).
# A node where that fails still lets the tick queue its successor, which may land elsewhere: the tick
# reads the reason from $HPCW_ACCESS_NO_TMP and applies nothing
node_tmp() { # -> 0 with TMPDIR this job's own folder; else 1 with $why
  local base=/tmp/$me
  local u
  ( umask 077; mkdir -p "$base" ) 2>/dev/null
  if [ -L "$base" ]; then why="$base is a link"; return 1; fi
  if [ ! -d "$base" ]; then why="$base cannot be made a folder (a file is there, or /tmp is full or read-only)"; return 1; fi
  u=$(stat -c %U -- "$base" 2>/dev/null)
  if [ "$u" != "$me" ]; then why="$base belongs to ${u:-an account stat cannot name}, not to $me"; return 1; fi
  chmod go-w "$base" || { why="$base cannot be closed to writing by others"; return 1; }
  TMPDIR=$base/hpcw_access_$SLURM_JOB_ID
  if ! ( umask 077; mkdir "$TMPDIR" ) 2>/dev/null; then
    if [ -L "$TMPDIR" ]; then why="$TMPDIR is there already, as a link"; return 1; fi
    if [ ! -d "$TMPDIR" ]; then why="$TMPDIR cannot be made a folder (a file is there, or /tmp is full or read-only)"; return 1; fi
    u=$(stat -c %U -- "$TMPDIR" 2>/dev/null)
    if [ "$u" != "$me" ]; then why="$TMPDIR is there already and belongs to ${u:-an account stat cannot name}"; return 1; fi
  fi
  chmod 700 "$TMPDIR" || { why="$TMPDIR cannot be made this account's alone"; return 1; }
}
why=""
if node_tmp; then
  export TMPDIR; trap 'rm -rf "$TMPDIR"' EXIT
else
  unset TMPDIR
  export HPCW_ACCESS_NO_TMP="$node could not give this job a folder of its own on its disk for the token's configuration file: $why"
fi
bash bin/grid_access.sh --tick "$@"
