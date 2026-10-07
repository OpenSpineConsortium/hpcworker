#!/bin/bash
# The install step of the grid's CI: tools/deploy_shared.sh --here, in a job on a compute node, from
# the commit's own checkout (tools/grid_ci.sh submits this with -D <run dir>; the checkout is
# <run dir>/src), and only for main's head after GitHub's checks and the grid suite passed. Never
# --replace: a version already published with other files is refused by deploy_shared, and the fix
# is the next integer version. The account must own the shared copy's folder, as for any publish.
# It runs only while its commit is still main's head and never moves the shared copy back to an
# older version: an install waits in the queue, and an older commit's can start after a newer one's.
# The partition and QoS arrive on sbatch's command line, so this file names no site's queue. The log
# ends "exit N", which grid_ci.sh reads beside the scheduler's state.
#SBATCH --job-name=hpcw_ci_deploy
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:20:00
#SBATCH --output=deploy-%j.log
#SBATCH --requeue
set -uo pipefail
end() { echo "exit $1"; exit "$1"; }
refuse() { echo "grid_deploy: $*"; end 1; }
echo "host $(hostname -s) $(date -u +%FT%TZ) bash ${BASH_VERSION}"
site=()
while [ $# -gt 0 ]; do case "$1" in
  --site) [[ "${2:-}" =~ ^[A-Za-z0-9._-]+$ ]] || refuse "--site needs a site name; nothing was installed"; site=(--site "$2"); shift 2;;
  *) refuse "only --site is handed on, not $1 (an install from CI never replaces a published version); nothing was installed";;
esac; done
# deploy_shared's own temporary folder (mktemp -d, the tarball) on this node's local disk: never the
# volume's $TMPDIR, which is not node-local, and never a login node's /tmp
export TMPDIR=/tmp/$USER/hpcw_deploy_$SLURM_JOB_ID
mkdir -p "$TMPDIR" || refuse "cannot make $TMPDIR on this node; nothing was installed"
trap 'rm -rf "$TMPDIR"' EXIT
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT AI_AGENT BEETHOVEN_REQUEST_ID BEETHOVEN_WORKER ASHLEY_REQUEST_ID ASHLEY_WORKER ASHLEY_JOB HPCW_AGENT GITHUB_TOKEN GH_TOKEN
# without them deploy_shared publishes and leaves the ACL entries as the volume's defaults made them
# (a publish without setfacl once left v15's default:user:: at rwx); from CI that is a refusal, not a skip
for t in getfacl setfacl; do
  command -v "$t" >/dev/null 2>&1 || refuse "$t is not installed on $(hostname -s), so the permissions could not be set; nothing was installed"
done
{ cd src 2>/dev/null && [ -f tools/deploy_shared.sh ]; } || refuse "no checkout with tools/deploy_shared.sh in $(pwd)/src; nothing was installed"
# one install at a time per clone: a person's --deploy and the watcher's share the shared copy
if command -v flock >/dev/null 2>&1; then
  exec 9>>../../deploy.lock || refuse "cannot open the install lock; nothing was installed"
  # well inside the wall time, so a wait that runs out is said in words, not cut off by the scheduler
  flock -w 600 9 || refuse "another install held the lock for ten minutes; nothing was installed"
fi
# main's newest head as either lane last fetched it (grid_ci.sh writes <clone>/main-head under the
# clone's lock): an install queued for a commit main has since moved past does not run
here=$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)
[ -n "$here" ] || refuse "cannot tell which commit the checkout holds; nothing was installed"
head=$(cat ../../main-head 2>/dev/null)
[ -n "$head" ] || refuse "no record of main's head beside the clone (grid_ci.sh writes one at every fetch of main); nothing was installed"
[ "$head" = "$here" ] || refuse "main has moved on to a newer commit; nothing was installed"
# never back to an older version (deploy_shared itself moves current anywhere from version 11 up):
# its own dry run, the same publish with nothing written, names the version current points at now
dry=$(bash tools/deploy_shared.sh --here --dry-run ${site[@]+"${site[@]}"} 2>&1); rc=$?
[ $rc = 0 ] || { printf '%s\n' "$dry"; end "$rc"; }
cur=$(printf '%s\n' "$dry" | sed -n 's/^   root: .*; current: \(none\|v[0-9][0-9]*\) -> v\([0-9][0-9]*\)$/\1 \2/p' | head -1)
[ -n "$cur" ] || refuse "could not tell which version the lab's shared copy names now; nothing was installed"
now=${cur% *} new=${cur#* }
echo "the lab's shared copy names ${now} now; this commit is v$new"
if [ "$now" != none ] && [ "${now#v}" -gt "$new" ]; then
  refuse "the lab's shared copy is already version ${now#v}, newer than this commit's $new; nothing was installed"
fi
bash tools/deploy_shared.sh --here ${site[@]+"${site[@]}"}
end $?
