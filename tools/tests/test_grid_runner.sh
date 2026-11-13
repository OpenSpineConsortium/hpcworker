#!/usr/bin/env bash
# Tests for the grid's GitHub runner: tools/grid_runner.sh (--install, --start, --stop, --status,
# the install job and a chain's jobs), tools/grid_runner.sbatch and tools/grid_runner_install.sbatch,
# and, at its end, tools/tests/test_grid_gate.sh for the ssh gate, so CI's one step runs both.
# Linux only; nothing reaches GitHub, a registry, a scheduler or the grid. Everything happens in a
# temporary folder under /tmp (the runner folder is HPCW_RUNNER_DIR there, never the lab volume):
# gh is tests/shim/gh (the repository's visibility, the just-in-time registrations and their
# deletion, as files), sbatch, squeue and scancel are tests/shim/slurm (a scheduler that runs
# nothing and refuses a path outside the test's folder or a job with no wall time), apptainer is
# tests/shim/apptainer (a runtime that pulls a stand-in image and runs the runner's stand-in,
# tests/shim/runner-listener, in the folder the job bound as /home/runner, with the environment the
# image and --env give a container), sleep is tests/shim/nosleep (it records the wait and returns) and a job's clock is a
# file, which the runner stand-in moves as its plan says. A job "runs" when the test runs its copied
# script the way Slurm would (its -D folder, its arguments, SLURM_JOB_ID and the start time); its
# node-local temp is the real /tmp/$USER/hpcw_runner_<id>, gone when the job ends. GITHUB_TOKEN and
# GH_TOKEN are set to marker values the whole time, and no stand-in may ever see them; a
# registration carries a marker of its own, which must never reach the runner folder, a log or a
# job record. KEEP_T=1 keeps the temporary folder.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
GR="$REPO/tools/grid_runner.sh"
SHIMS="$REPO/tools/tests/shim"
command -v jq >/dev/null 2>&1 || { echo "jq is needed: the gh stand-in runs grid_runner.sh's --jq expression through it"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed: the gh stand-in builds a registration with it"; exit 1; }
T=$(mktemp -d /tmp/grid_runner_test.XXXXXX) || exit 1
T=$(cd "$T" && pwd -P)
cleanup() { chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
if [ -n "${KEEP_T:-}" ]; then echo "keeping $T"; else trap cleanup EXIT; fi

export HOME="$T/home" USER=${USER:-$(id -un)}
mkdir -p "$HOME" "$T/bin"
for s in slurm gh nosleep apptainer; do cp "$SHIMS/$s" "$T/bin/$s.shim" && chmod 755 "$T/bin/$s.shim"; done
for s in sbatch squeue scancel; do ln -s slurm.shim "$T/bin/$s"; done
ln -s gh.shim "$T/bin/gh"; ln -s nosleep.shim "$T/bin/sleep"; ln -s apptainer.shim "$T/bin/apptainer"
# a login node's banner may ban programs by name (framework/README.md, "The login node"): every
# person's command here runs with a stand-in for each of them first on PATH, which writes down any
# start; a job, on a compute node, may run python3 and runs with the real one
mkdir -p "$T/banned"
for b in python python2 python3 pip node make md5sum rsync conda gcc R; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/banned.calls"\nexit 97\n' "$b" "$T" > "$T/banned/$b"; chmod 755 "$T/banned/$b"
done
export PATH="$T/bin:$PATH" SHIM_SLURM="$T/slurm" SHIM_SLURM_ROOT="$T" SHIM_GH="$T/gh" SHIM_SLEEPS="$T/sleeps" SHIM_APPTAINER="$T/apptainer"
export HPCW_RUNNER_DIR="$T/runner"   # never the lab volume's default
export HPCW_RUNNER_CLOCK="$T/clock"
export HPCW_RUNNER_HPCWORKER=none   # the fixed batch queue unless a test names an hpcworker, so the checkout's own never races here
unset HPCW_RUNNER_PARTITION HPCW_RUNNER_QOS SLURM_JOB_ID SLURM_JOB_START_TIME SLURM_JOB_END_TIME TMPDIR
export GITHUB_TOKEN=ghp_testtoken_must_not_leak GH_TOKEN=gho_testtoken_must_not_leak
mkdir -p "$T/slurm" "$T/gh" "$T/apptainer/tree/home/runner/bin"
: > "$T/slurm/calls"; : > "$T/gh/calls"; : > "$T/sleeps"; : > "$T/apptainer/calls"
echo "sbatch: Warning: this job may be preempted and requeued" > "$T/slurm/warn"
cp "$SHIMS/runner-listener" "$T/apptainer/tree/home/runner/bin/Runner.Listener" && chmod 755 "$T/apptainer/tree/home/runner/bin/Runner.Listener"
echo 1000000 > "$T/clock"

R="$T/runner"; IMG="$R/image"
GH_REPO=OpenSpineConsortium/symphony-template
CH="$R/OpenSpineConsortium-symphony-template"; NAME=hpcw_runner_OpenSpineConsortium-symphony-template
WAYNE_BIN=$(python3 "$REPO/framework/lib/profile.py" shellenv "$REPO/framework/profiles/wayne.json" | sed -n 's/^P_runtime_bin=//p')
WAYNE_MOD=$(python3 "$REPO/framework/lib/profile.py" shellenv "$REPO/framework/profiles/wayne.json" | sed -n 's/^P_runtime_module=//p')
# the site's worker queue and the account's state folder, as the reference reader gives them
WAYNE_ENV=$(python3 "$REPO/framework/lib/profile.py" shellenv "$REPO/framework/profiles/wayne.json")
DEF_PART=$(printf '%s\n' "$WAYNE_ENV" | sed -n 's/^P_partition_cpu_batch=//p'); DEF_QOS=$(printf '%s\n' "$WAYNE_ENV" | sed -n 's/^P_qos_batch=//p')
WAYNE_ROOT="$(printf '%s\n' "$WAYNE_ENV" | sed -n 's/^P_shared_state_dir=//p')-runner"

pass=0 fail=0 OUT="" RC=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }
t() { local d=$1; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
# grep without -q after a pipe: under pipefail, grep -q leaving early fails the writer with SIGPIPE
has() { printf '%s\n' "$OUT" | grep -E -- "$1" >/dev/null; }
all() { local p; for p in "$@"; do has "$p" || return 1; done; }
lacks() { ! has "$1"; }
rc_is() { [ "$RC" = "$1" ]; }
TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout 120)
gr() { OUT=$(PATH="$T/banned:$PATH" ${TO[@]+"${TO[@]}"} bash "$GR" "$@" 2>&1); RC=$?; }
J() { cat "$T/slurm/jobs/$1/$2" 2>/dev/null; }
ids() { local j; for j in $(ls "$T/slurm/jobs" 2>/dev/null | sort -n); do [[ "$(J "$j" name)" =~ $1 ]] && echo "$j"; done; return 0; }
count() { ids "$1" | grep -c . ; }
newest() { ids "$1" | tail -1; }
set_state() { echo "$2" > "$T/slurm/jobs/$1/state"; }
run_job() { # ID [VAR=VALUE...]: a submitted job's copied script as Slurm runs it, its output in its log, the clock's start time unless given
  local id=$1 args=(); shift
  mapfile -t args < "$T/slurm/jobs/$id/args"
  set_state "$id" RUNNING
  ( cd "$(J "$id" dir)" && env SLURM_JOB_START_TIME=1000000 "$@" SLURM_JOB_ID="$id" ${TO[@]+"${TO[@]}"} bash "$T/slurm/jobs/$id/script" ${args[@]+"${args[@]}"} ) > "$(J "$id" out)" 2>&1; RC=$?
  OUT=$(cat "$(J "$id" out)")
  if [ "$RC" = 0 ]; then set_state "$id" COMPLETED; else set_state "$id" FAILED; fi
}
plan() { printf '%s\n' "$@" > "$T/apptainer/plan"; }
runs() { cat "$T/apptainer/runs" 2>/dev/null; }
jit_requests() { cat "$T/gh/jit/requests" 2>/dev/null; }
n_jit() { grep -c 'generate-jitconfig' "$T/gh/calls"; }
deleted() { cat "$T/gh/deleted" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
status_field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$CH/status.json" "$1" 2>/dev/null; }
clear_runs() { rm -f "$T/apptainer/runs" "$T/apptainer/binds" "$T/gh/deleted"; : > "$T/sleeps"; }
fresh() { rm -f "$CH/STOP" "$CH/failures"; clear_runs; }   # a chain a person started again, as far as a job can tell
note_starts() { case "$(status_field note)" in "$1"*) return 0;; esac; return 1; }
minted() { printf '%s\n' "$OUT" | sed -n "s/.*registered runner $1 (id \([0-9]*\),.*/\1/p" | head -1; }
no_leak() { # nothing of either marker anywhere a person or a later job could read it
  [ ! -e "$T/gh/leaks" ] && [ ! -e "$T/slurm/leaks" ] && [ ! -e "$T/apptainer/leaks" ] \
    && ! grep -rIl 'testtoken_must_not_leak\|jitsecret_must_not_leak' "$R" "$T/slurm/jobs" "$T/apptainer/calls" "$T/slurm/calls" "$T/gh/calls" >/dev/null 2>&1
}
node_tmp_gone() { [ ! -e "/tmp/$USER/hpcw_runner_$1" ] && [ ! -e "/dev/shm/$USER/hpcw_runner_$1" ]; }

echo "== the files parse"
for f in tools/grid_runner.sh tools/grid_runner.sbatch tools/grid_runner_install.sbatch tools/tests/shim/apptainer tools/tests/shim/runner-listener; do
  OUT=$(bash -n "$REPO/$f" 2>&1); RC=$?; t "$f parses" rc_is 0
done
t "both job files have a wall time" grep -q '^#SBATCH --time=' "$REPO/tools/grid_runner.sbatch" "$REPO/tools/grid_runner_install.sbatch"
t "both job files unset the tokens and the agent markers before anything runs" bash -c "grep -q '^unset .*GITHUB_TOKEN GH_TOKEN' '$REPO/tools/grid_runner.sbatch' && grep -q '^unset .*CLAUDECODE' '$REPO/tools/grid_runner_install.sbatch'"

echo "== options"
gr; t "no mode is refused" rc_is 1; t "  and the modes are named" has 'one of --install, --start'
gr --start; t "--start needs --repo" has 'needs --repo'
gr --start --repo bad; t "--repo is OWNER/NAME" has 'OWNER/NAME'
gr --start --repo "$GH_REPO" --labels grid; t "grid is every chain's label" has "GitHub's own labels"
gr --start --repo "$GH_REPO" --labels 'a b'; t "labels are names" has 'comma-separated'
gr --start --repo "$GH_REPO" --hours 0; t "--hours is 1 to 336" has -- '--hours is'
gr --start --repo "$GH_REPO" --hours 2 --margin 120; t "--margin is under the wall time" has -- '--margin is'
# --ro-bind: an absolute folder that is here, bound read-only, never the home, inside it or holding it
mkdir -p "$T/envs/pixi"
gr --start --repo "$GH_REPO" --ro-bind relative/envs; t "--ro-bind is an absolute folder" all 'ro-bind takes an absolute folder' 'relative/envs'
gr --start --repo "$GH_REPO" --ro-bind "$T/envs:/x"; t "  whose name holds no colon, which a bind would split on" has 'ro-bind takes an absolute folder'
gr --start --repo "$GH_REPO" --ro-bind "$T/envs/../home"; t "  with no .. in its path" has 'no \. or \.\. in its path'
gr --start --repo "$GH_REPO" --ro-bind "$HOME/.config"; t "  never inside the account's home" has "is in the account's home"
gr --start --repo "$GH_REPO" --ro-bind "$T"; t "  never a folder that holds it" has "holds the account's home"
gr --start --repo "$GH_REPO" --ro-bind "$T/envs/none"; t "  and one that is here" has 'envs/none is no folder here'
gr --start --repo "$GH_REPO" --mem 8GB; t "--mem is as sbatch takes it" has 'bad --mem'
gr --start --repo "$GH_REPO" --gres 'gpu;1'; t "--gres is checked" has 'bad --gres'
gr --bogus; t "an unknown option is refused" has 'unknown option --bogus'
gr --start --repo "$GH_REPO" --slurm; t "no option hands a step the scheduler" has 'unknown option --slurm'
gr --start --repo "$GH_REPO" --site; t "an option without its value is refused" has 'needs a value'
gr --help; t "--help prints the header" rc_is 0; t "  with the four modes" has -- '--install.*--start.*--stop.*--status'; t "  and none of the code" lacks 'set -uo pipefail'
gr --pull; t "--pull runs only inside the install job" has 'inside the install job'
gr --serve --repo "$GH_REPO"; t "--serve runs only inside a chain's job" has "inside a chain's job"
t "none of that reached the scheduler or GitHub" bash -c "[ ! -s '$T/slurm/calls' ] && [ ! -s '$T/gh/calls' ]"
HPCW_RUNNER_DIR= gr --status; t "a command naming neither a site nor a folder is refused" rc_is 1
t "  saying where the folder comes from" has "names the site profile"
HPCW_RUNNER_DIR= gr --status --site wayne; t "--site puts the runner folder beside the account's state" rc_is 0
t "  as the site profile names it" has "^runner folder: $WAYNE_ROOT\$"
t "  and --status made nothing there" [ ! -e "$WAYNE_ROOT" ]
HPCW_RUNNER_DIR=runner gr --status; t "a relative runner folder is refused" has 'must be an absolute path'
OUT=$(cd "$T" && bash "$REPO/tools/grid_runner.sbatch" --serve --repo "$GH_REPO" 2>&1); RC=$?
t "the chain's job file refuses to run outside a runner folder" rc_is 1; t "  and says so" has 'no bin/grid_runner.sh'

echo "== --install"
gr --start --repo "$GH_REPO"; t "--start before any install is refused" has 'no runner image is installed'
gr --install --version 2.330.0 --partition secp --qos secondary
t "--install submits the install job" rc_is 0; t "  and names it" has 'install is job 1001'
I1=$(newest '^hpcw_runner_install$')
t "  on the partition and qos given" bash -c "[ '$(J "$I1" partition)' = secp ] && [ '$(J "$I1" qos)' = secondary ]"
t "  from the runner folder" [ "$(J "$I1" dir)" = "$R" ]
t "  with its log under image/" [ "$(J "$I1" out)" = "$IMG/install-$I1.log" ]
t "  with the version and the runner folder as its arguments" [ "$(J "$I1" args | tr '\n' ' ')" = "--pull --version 2.330.0 --runner-dir $R " ]
t "  the runner folder holds the chain's own copies, and nothing of the framework" bash -c "[ -x '$R/bin/grid_runner.sh' ] && [ -x '$R/bin/grid_runner.sbatch' ] && [ -x '$R/bin/grid_runner_install.sbatch' ] && [ ! -e '$R/bin/common.sh' ]"
t "  the job is the copied file" [ "$(J "$I1" script | head -1)" = "$(head -1 "$R/bin/grid_runner_install.sbatch")" ]
touch "$T/apptainer/offline"
run_job "$I1"
t "an install without registry egress fails" rc_is 3; t "  and says STOP" has 'STOP: the pull failed'
t "  and installs nothing" [ ! -e "$IMG/current" ]
t "  and its node-local temp is gone" node_tmp_gone "$I1"
rm -f "$T/apptainer/offline"
set_state "$I1" PENDING; run_job "$I1"
t "a requeued install pulls again" rc_is 0; t "  and installs the version named" has 'installed: runner 2.330.0'
t "  the image is placed and current names it" bash -c "[ -s '$IMG/actions-runner-2.330.0.sif' ] && [ \"\$(cat '$IMG/current')\" = 2.330.0 ]"
t "  the pull ran on the node's own disk" grep -q "^apptainer pull /tmp/$USER/hpcw_runner_$I1/image.sif docker://ghcr.io/actions/actions-runner:2.330.0$" "$T/apptainer/calls"
t "  the runner's version was asked inside the image with the chain's flags, its trace on stdout off" grep -q "^apptainer exec --containall --cleanenv --no-mount bind-paths --env ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=false --pwd /home/runner --home /tmp/$USER/hpcw_runner_$I1/home:/home/runner -B /tmp/$USER/hpcw_runner_$I1/tmp:/tmp /tmp/$USER/hpcw_runner_$I1/image.sif /home/runner/bin/Runner.Listener --version$" "$T/apptainer/calls"
t "  and the job says so, though Apptainer's own lines come after the version" has 'the runner answers inside the image: version 2.330.0'
gr --install --site wayne
t "--install with a site takes the runtime from its profile" rc_is 0
I2=$(newest '^hpcw_runner_install$')
t "  and hands it to the job" [ "$(J "$I2" args | tr '\n' ' ')" = "--pull --version latest --runner-dir $R --site wayne --runtime-bin $WAYNE_BIN --runtime-module $WAYNE_MOD " ]
t "  on the site's worker queue when none is given" bash -c "[ -n '$DEF_PART' ] && [ '$(J "$I2" partition)' = '$DEF_PART' ] && [ '$(J "$I2" qos)' = '$DEF_QOS' ]"
run_job "$I2"
t "the latest image installs" rc_is 0; t "  as 2.338.0" has 'installed: runner 2.338.0'
t "  and current moves to it" [ "$(cat "$IMG/current")" = 2.338.0 ]
gr --install --site nowhere; t "--install with an unknown site is refused" has 'no site profile'
t "no token reached a stand-in" no_leak

echo "== --start"
echo public > "$T/gh/visibility"
gr --start --repo "$GH_REPO"; t "a public repository is refused" rc_is 1; t "  with GitHub's reason" has 'refused: OpenSpineConsortium/symphony-template is public'
t "  and nothing was submitted" [ "$(count "^$NAME$")" = 0 ]
rm -f "$T/gh/visibility"; touch "$T/gh/offline"
gr --start --repo "$GH_REPO"; t "gh without a network refuses the start" has 'gh could not read'
rm -f "$T/gh/offline"
gr --start --repo "$GH_REPO" --site wayne --hours 2 --margin 30 --cpus 4 --mem 16G --gres gpu:1 --labels gpu
t "--start submits the chain's first job" rc_is 0; t "  and names it" has 'runner chain for OpenSpineConsortium/symphony-template: job 1003'
t "  and says the labels a workflow names" has 'runs-on: \[self-hosted, grid, wayne, gpu\]'
t "  and the margin a job must end within" has 'end within 30 minutes'
C1=$(newest "^$NAME$")
t "  the job is a singleton of the chain's name" [ "$(J "$C1" dependency)" = singleton ]
t "  with the wall time, the size and the GPU asked" bash -c "[ '$(J "$C1" time)' = 2:00:00 ] && [ '$(J "$C1" cpus)' = 4 ] && [ '$(J "$C1" mem)' = 16G ] && [ '$(J "$C1" gres)' = gpu:1 ]"
t "  on the site's worker queue, which the job file never names" bash -c "[ '$(J "$C1" partition)' = '$DEF_PART' ] && [ '$(J "$C1" qos)' = '$DEF_QOS' ] && ! grep -q '^#SBATCH --\(partition\|qos\)' '$T/slurm/jobs/$C1/script'"
t "  from the runner folder, logging under the chain's folder" bash -c "[ '$(J "$C1" dir)' = '$R' ] && [ '$(J "$C1" out)' = '$CH/runner-$C1.log' ]"
t "  with everything a job needs on its command line" [ "$(J "$C1" args | tr '\n' ' ')" = "--serve --repo $GH_REPO --runner-dir $R --site wayne --runtime-bin $WAYNE_BIN --runtime-module $WAYNE_MOD --hours 2 --margin 30 --labels gpu --cpus 4 --mem 16G --gres gpu:1 --constraint avx2 --partition $DEF_PART --qos $DEF_QOS " ]
t "  on nodes with the site placement file's runner feature, which nothing named" [ "$(J "$C1" constraint)" = avx2 ]
t "  the chain's config says what was asked" bash -c "grep -qx 'labels=grid,wayne,gpu' '$CH/config' && grep -qx 'hours=2' '$CH/config' && grep -qx 'margin=30' '$CH/config' && grep -qx 'version=2.338.0' '$CH/config'"
gr --start --repo "$GH_REPO"; t "a second chain for the repository is refused while one is queued" has "already queued or running \(job $C1 PENDING\)"
t "  and nothing was submitted" [ "$(count "^$NAME$")" = 1 ]

echo "== a chain's job: two GitHub jobs, then STOP"
echo "$CH" > "$T/apptainer/chain"
plan done done stop
# a person's shell or the site's module may set Apptainer's own binds and variables for the container;
# the job hands none of them on (the stand-in refuses an exec that would bind them)
run_job "$C1" APPTAINER_BIND="$HOME:/mnt/home" SINGULARITY_BINDPATH="$HOME" APPTAINERENV_FROM_THE_SHELL=1
t "the job ends well" rc_is 0; t "  and says whose it is" has "== runner job $C1 for $GH_REPO"
C2=$(newest "^$NAME$")
t "it queued its successor first" bash -c "[ '$C2' != '$C1' ] && [ '$(J "$C2" dependency)' = 'afterany:$C1,singleton' ]"
t "  with the same arguments, size and wall time" bash -c "[ \"\$(cat '$T/slurm/jobs/$C2/args')\" = \"\$(cat '$T/slurm/jobs/$C1/args')\" ] && [ '$(J "$C2" time)' = 2:00:00 ] && [ '$(J "$C2" gres)' = gpu:1 ] && [ '$(J "$C2" partition)' = '$DEF_PART' ] && [ '$(J "$C2" qos)' = '$DEF_QOS' ] && [ '$(J "$C2" constraint)' = avx2 ]"
t "  and wrote it down" [ "$(cat "$CH/next")" = "$C1 $C2" ]
t "the wall time and the margin are read from the start time and --hours" has 'wall time ends 1970-01-12T15:46:40Z; the last registration is made before 1970-01-12T15:16:40Z \(30 minutes of margin\)'
t "the container was given the node's GPU, which --gres asked for" has "image 2.338.0, with the node's GPU"
t "three registrations were minted, one at a time" [ "$(n_jit)" = 3 ]
t "  named after the site, the job and their turn" [ "$(jit_requests | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | tr '\n' ' ')" = "grid-wayne-$C1-1 grid-wayne-$C1-2 grid-wayne-$C1-3 " ]
t "  with GitHub's own three labels, which a just-in-time registration is not given, then the chain's" [ "$(jit_requests | grep -c '"labels":\["self-hosted","linux","x64","grid","wayne","gpu"\]')" = 3 ]
t "  and the work folder" [ "$(jit_requests | grep -c '"work_folder":"_work"')" = 3 ]
t "the runner ran three times on files of mode 0600" [ "$(runs | grep -c "^run grid-wayne-$C1-[123] files ok ")" = 3 ]
t "  seeing nothing of the job's or the shell's environment, its trace on stdout off" [ "$(runs | grep -c ' env=ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=false$')" = 3 ]
t "  in a container with the chain's flags, the GPU and the node's own temp, and no other bind" grep -q "^apptainer exec --containall --cleanenv --no-mount bind-paths --nv --env ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=false --pwd /home/runner --home /tmp/$USER/hpcw_runner_$C1/home:/home/runner -B /tmp/$USER/hpcw_runner_$C1/tmp:/tmp $IMG/actions-runner-2.338.0.sif /home/runner/bin/Runner.Listener run$" "$T/apptainer/calls"
t "  so the runner's trace stays out of the chain's log" lacks 'INFO Runner\]'
t "two GitHub jobs ran" all "runner grid-wayne-$C1-1 ended after its job \(1 done in this job\)" "runner grid-wayne-$C1-2 ended after its job \(2 done in this job\)"
t "the third runner, idle when STOP was written, was ended" has "ending the idle runner grid-wayne-$C1-3 \(STOP is set\)"
t "  and its registration deleted, the others GitHub discarded itself" [ "$(deleted)" = 102 ]
t "  so no registration is left on record" [ ! -e "$CH/registered" ]
t "the job's last word is the count" bash -c "[ '$(status_field state)' = ending ] && [ '$(status_field jobs_done)' = 2 ] && [ '$(status_field job)' = '$C1' ] && [ '$(status_field runner)' = '' ]"
t "  and its log says so" has "== job $C1 ends: 2 GitHub jobs ran"
t "the job looked at the runner once a minute and at an ending one every five seconds, never faster" bash -c "[ -s '$T/sleeps' ] && ! grep -vxE '60|5' '$T/sleeps' >/dev/null"
t "the node-local temp is gone with the job" node_tmp_gone "$C1"
t "no token and no registration left the job" no_leak
clear_runs
run_job "$C2"
t "the successor reads STOP and ends" rc_is 0; t "  saying so" has 'STOP is set'
t "  queuing nothing" [ "$(count "^$NAME$")" = 2 ]
t "  registering nothing" [ "$(n_jit)" = 3 ]
t "  and says stopped" [ "$(status_field state)" = stopped ]

echo "== --stop and --status"
gr --stop --repo "$GH_REPO"; t "--stop with nothing queued says so" has 'no job of the chain was queued'
gr --start --repo "$GH_REPO" --site wayne; t "--start after a stop starts again" rc_is 0
t "  and takes STOP away" [ ! -e "$CH/STOP" ]
C3=$(newest "^$NAME$")
gr --stop --repo "$GH_REPO"; t "--stop cancels the queued job" has "cancelled job $C3"
t "  which is cancelled" [ "$(J "$C3" state)" = CANCELLED ]; t "  and STOP is written" [ -f "$CH/STOP" ]
gr --start --repo "$GH_REPO" --site wayne; C4=$(newest "^$NAME$"); set_state "$C4" RUNNING
gr --stop --repo "$GH_REPO"; t "--stop leaves a running job to finish its GitHub job" has "job $C4 keeps running"
t "  so it still runs" [ "$(J "$C4" state)" = RUNNING ]
gr --stop --repo "$GH_REPO" --now; t "--stop --now cancels the running job too" has "cancelled job $C4"
t "  which is cancelled" [ "$(J "$C4" state)" = CANCELLED ]
gr --start --repo OpenSpineConsortium/other --labels a,b --site wayne --partition secp --qos secondary --constraint "a&b"
t "a --constraint that is no plain feature name is refused" has "--constraint is one node feature.s name"
t "  and nothing was submitted" [ "$(count '^hpcw_runner_OpenSpineConsortium-other$')" = 0 ]
gr --start --repo OpenSpineConsortium/other --labels a,b --site wayne --partition secp --qos secondary --constraint avx512
t "a chain for another repository starts beside the first" rc_is 0; t "  with its own labels" has 'runs-on: \[self-hosted, grid, wayne, a, b\]'
O1=$(newest '^hpcw_runner_OpenSpineConsortium-other$'); echo n042 > "$T/slurm/jobs/$O1/node"; set_state "$O1" RUNNING
t "  on the queue --partition and --qos give over the site's" bash -c "[ '$(J "$O1" partition)' = secp ] && [ '$(J "$O1" qos)' = secondary ]"
t "  and on the feature --constraint gives over the site's" [ "$(J "$O1" constraint)" = avx512 ]
gr --status
t "--status names the runner folder" has "^runner folder: $R\$"
t "  and the image" has 'runner image: 2.338.0'
t "  and each chain with its labels, as the last --start gave them" all 'chain OpenSpineConsortium/symphony-template: labels grid,wayne, started' 'chain OpenSpineConsortium/other: labels grid,wayne,a,b, started'
t "  whether STOP is written" has 'STOP written'
t "  the chain's jobs in the queue" has "job $O1 RUNNING, 0:01 on n042"
t "  and the last word of the chain's last job" has 'last word: stopped, job'
gr --status --repo OpenSpineConsortium/other; t "--status --repo shows that chain alone" lacks 'symphony-template'
gr --stop --repo OpenSpineConsortium/other --now

echo "== the margin, a busy runner, a retry, an update, failures"
gr --start --repo "$GH_REPO" --site wayne; C5=$(newest "^$NAME$")
run_job "$C5" SLURM_JOB_END_TIME=$((1000000 + 3600 - 1))
t "a job whose scheduler end time leaves no margin ends well" rc_is 0; t "  registering nothing" [ "$(n_jit)" = 3 ]
t "  reading the scheduler's own end time" has 'wall time ends 1970-01-12T14:46:39Z'
t "  and saying why it ends" has 'no time for another job before the wall time \(60 minutes of margin\)'
C6=$(newest "^$NAME$"); t "  after queuing its successor" [ "$C6" != "$C5" ]
clear_runs; plan "clock=$((1000000 + 8 * 3600 - 3600))"
run_job "$C6"
t "an idle runner is ended at the margin" has "ending the idle runner grid-wayne-$C6-1 \(the margin is reached\)"
t "  and its registration deleted" bash -c "[ -n '$(minted "grid-wayne-$C6-1")' ] && [ '$(deleted)' = '$(minted "grid-wayne-$C6-1")' ]"
t "  with no GitHub job counted" [ "$(status_field jobs_done)" = 0 ]
t "  without the GPU, which no --gres asked for" grep -q "^apptainer exec --containall --cleanenv --no-mount bind-paths --env ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=false --pwd /home/runner --home /tmp/$USER/hpcw_runner_$C6/home:/home/runner .*/home/runner/bin/Runner.Listener run$" "$T/apptainer/calls"
echo 1000000 > "$T/clock"; clear_runs
C7=$(newest "^$NAME$"); plan "busy-clock=$((1000000 + 8 * 3600 - 3600))"
run_job "$C7"
t "a runner busy at the margin finishes its GitHub job" has "a GitHub job is running on grid-wayne-$C7-1; waiting for it"
t "  which counts" has "runner grid-wayne-$C7-1 ended after its job \(1 done in this job\)"; t "  in the last word too" [ "$(status_field jobs_done)" = 1 ]
t "  and no registration was deleted" [ -z "$(deleted)" ]
echo 1000000 > "$T/clock"; clear_runs
C8=$(newest "^$NAME$"); plan retry done stop
run_job "$C8"
t "a runner that asks to be started again is" has 'the runner asked to be started again'
t "  on the same registration" [ "$(runs | grep -c "^run grid-wayne-$C8-1 files ok")" = 2 ]
t "  keeping its logs for a person" bash -c "ls '$CH/diag-$C8-1/'Runner_*.log >/dev/null 2>&1"
t "  and the GitHub job then ran" [ "$(status_field jobs_done)" = 1 ]
fresh; C9=$(newest "^$NAME$"); plan update
run_job "$C9"
t "a runner that asks for a newer version stops the chain" has 'STOP written: the runner asks for a newer version than the image.s 2.338.0'
t "  saying what a person does" bash -c "grep -q 'grid_runner.sh --install, then --start' '$CH/STOP' && [ '$(status_field state)' = stopped ]"
t "  its registration deleted and no GitHub job counted" bash -c "[ '$(deleted | wc -w)' = 1 ] && [ '$(status_field jobs_done)' = 0 ]"
t "  and its logs kept for a person" bash -c "ls '$CH/diag-$C9-1/'Runner_*.log >/dev/null 2>&1"
fresh; C10=$(newest "^$NAME$"); plan gone stop
run_job "$C10"
t "a runner that ends with no job run is not counted" has "runner grid-wayne-$C10-1 ended with no job run"
t "  its registration deleted, a minute before the next" bash -c "[ '$(deleted | wc -w)' = 2 ] && grep -qx 60 '$T/sleeps'"
t "  and the next registration serves" bash -c "[ '$(status_field jobs_done)' = 0 ] && [ '$(status_field state)' = ending ]"
t "  finding none of the first one's files" [ ! -s "$T/gh/jit/over" ]
fresh; C10=$(newest "^$NAME$"); plan term term term term
run_job "$C10"
t "four failures in a row end the job" has 'four failures in a row: this job ends'
t "  each registration deleted" [ "$(deleted | wc -w)" = 4 ]
t "  and the last word says failed, and why" bash -c "[ '$(status_field state)' = failed ] && [ '$(status_field note)' = 'the runner failed four times in a row (1 of 3 jobs in a row that could not serve; the third writes STOP)' ]"
clear_runs; C11=$(newest "^$NAME$"); touch "$T/gh/refuse-jit"
run_job "$C11"
t "GitHub refusing every registration ends the job" has 'GitHub refused four registrations in a row'
t "  and the last word says so" bash -c "[ '$(status_field state)' = failed ] && [ '$(status_field note)' = 'GitHub refused four registrations in a row (2 of 3 jobs in a row that could not serve; the third writes STOP)' ]"
t "  after a minute between tries" [ "$(grep -cx 60 "$T/sleeps")" -ge 3 ]
t "  with no runner run" [ -z "$(runs)" ]
clear_runs; C11=$(newest "^$NAME$")
run_job "$C11"
t "the third job in a row that cannot serve writes STOP, with why" bash -c "grep -q '3 jobs in a row could not serve, the last: GitHub refused four registrations in a row' '$CH/STOP' && [ '$(status_field state)' = stopped ]"
rm -f "$T/gh/refuse-jit"; clear_runs; C11=$(newest "^$NAME$"); n=$(count "^$NAME$"); j=$(n_jit)
run_job "$C11"
t "  so the chain's queued successor ends on it" bash -c "[ '$RC' = 0 ] && [ '$(count "^$NAME$")' = '$n' ] && [ '$(n_jit)' = '$j' ]"

echo "== what a job finds when it starts"
fresh; echo 2 > "$CH/failures"; C12=$(newest "^$NAME$"); echo "77 grid-wayne-0-1" > "$CH/registered"; plan stop; : > "$T/gh/calls"
run_job "$C12"
t "a job that serves clears the count of jobs that could not" [ ! -e "$CH/failures" ]
t "a registration an earlier job left behind is deleted" [ "$(head -1 "$T/gh/deleted" 2>/dev/null)" = 77 ]
t "  before any registration is made" [ "$(grep -n 'runners/77\|generate-jitconfig' "$T/gh/calls" | head -1 | grep -c 'runners/77')" = 1 ]
t "  and the job goes on to register" has "registered runner grid-wayne-$C12-1"
fresh; C13=$(newest "^$NAME$"); echo "78 grid-wayne-0-1" > "$CH/registered"; touch "$T/gh/delete-404"; plan stop
run_job "$C13"
t "a leftover GitHub no longer lists is noted and passed over" has 'note: could not delete runner registration 78'
rm -f "$T/gh/delete-404"
echo public > "$T/gh/visibility"; fresh; C14=$(newest "^$NAME$"); plan stop
run_job "$C14"
t "a repository gone public stops the chain in the job" rc_is 1; t "  saying why" has 'refused: OpenSpineConsortium/symphony-template is public'
t "  STOP written with why, and the last word stopped" bash -c "grep -q 'the repository is public' '$CH/STOP' && [ '$(status_field state)' = stopped ]"
t "  with nothing registered" [ -z "$(runs)" ]
rm -f "$T/gh/visibility"; touch "$T/gh/offline"; fresh; C14=$(newest "^$NAME$"); plan stop
run_job "$C14"
t "gh that cannot answer in a job is a job that could not serve" bash -c "[ '$RC' = 1 ] && [ '$(cat "$CH/failures")' = 1 ]"
t "  never taken for a public repository" bash -c "[ ! -e '$CH/STOP' ] && [ '$(status_field state)' = failed ]"
t "  saying why" note_starts "gh could not read the repository's visibility (1 of 3 jobs in a row"
rm -f "$T/gh/offline"
gr --start --repo "$GH_REPO" --site wayne; t "the chain's queued successor keeps --start refused until it is stopped" has 'already queued or running'
gr --stop --repo "$GH_REPO" --now; gr --start --repo "$GH_REPO" --site wayne; t "stopped, the chain starts again" rc_is 0
C15=$(newest "^$NAME$")
mv "$IMG/current" "$IMG/current.away"; plan stop
run_job "$C15"
t "a job without the image fails" rc_is 3; t "  saying so" has 'no runner image at'
mv "$IMG/current.away" "$IMG/current"

echo "== a job run again, and a chain that cannot go on"
clear_runs; C16=$(newest "^$NAME$"); plan stop; rm -f "$CH/STOP"
run_job "$C16"; C17=$(newest "^$NAME$"); n=$(count "^$NAME$")
set_state "$C16" PENDING; rm -f "$CH/STOP"; plan stop; clear_runs
run_job "$C16"
t "a job run again after a requeue does not queue a second successor" [ "$(count "^$NAME$")" = "$n" ]
t "  and says so" has "next job: $C17, queued by an earlier run of this job"
echo "$C16" > "$CH/next.submitting"; rm -f "$CH/next"; set_state "$C16" PENDING; rm -f "$CH/STOP"; plan stop; clear_runs
run_job "$C16"
t "a job run again while it was submitting finds its successor in the queue" bash -c "[ '$(count "^$NAME$")' = '$n' ] && [ \"\$(cat '$CH/next')\" = '$C16 $C17' ] && [ ! -e '$CH/next.submitting' ]"
echo "$C16" > "$CH/next.submitting"; rm -f "$CH/next"; set_state "$C16" PENDING; rm -f "$CH/STOP"; plan stop; clear_runs
echo "slurm_load_jobs error: Socket timed out on send/recv operation" > "$T/slurm/sqdown"
run_job "$C16"
t "a job run again that cannot ask squeue queues no second successor" bash -c "[ '$(count "^$NAME$")' = '$n' ] && [ -e '$CH/next.submitting' ]"
t "  and says the chain ends" all 'squeue did not say whether an earlier run of this job queued the next one' 'no successor could be queued'
rm -f "$T/slurm/sqdown" "$CH/next.submitting"
echo "the partition is closed" > "$T/slurm/refuse-$NAME"; set_state "$C17" PENDING; rm -f "$CH/STOP"; plan stop; clear_runs
run_job "$C17"
t "a job that cannot queue its successor still serves" has "registered runner grid-wayne-$C17-1"
t "  says the chain ends" has 'no successor could be queued, so the chain ends here'
t "  and ends with a failure a person sees" rc_is 1
rm -f "$T/slurm/refuse-$NAME"

echo "== lanes: a second chain for one repository"
OCH="$R/OpenSpineConsortium-other"; L1NAME='^hpcw_runner_OpenSpineConsortium-other$'; L2NAME='^hpcw_runner_OpenSpineConsortium-other\+lane2$'
gr --start --repo OpenSpineConsortium/other --labels a,b --site wayne; P1=$(newest "$L1NAME"); set_state "$P1" RUNNING
for bad in 0 10 x 1x; do
  gr --start --repo OpenSpineConsortium/other --site wayne --lane "$bad"; t "--lane $bad is refused" has '--lane is the number of one of a repository.s chains, 1 to 9'
done
t "  and nothing was submitted for it" [ "$(count "$L2NAME")" = 0 ]
gr --start --repo OpenSpineConsortium/other --site wayne --lane 1; t "--lane 1 is the chain a command without it names, already running" has "a chain for OpenSpineConsortium/other is already queued or running \(job $P1 RUNNING\)"
gr --start --repo OpenSpineConsortium/other --labels a,b --site wayne --lane 2 --constraint none
t "--lane 2 starts a second chain beside the running first" rc_is 0; t "  and says which lane" has 'runner chain for OpenSpineConsortium/other, lane 2: job'
t "  with the same labels, so GitHub hands a job to either" has 'runs-on: \[self-hosted, grid, wayne, a, b\]'
L2=$(newest "$L2NAME")
t "  under a Slurm name of its own, a singleton of it" bash -c "[ -n '$L2' ] && [ '$(J "$L2" dependency)' = singleton ]"
t "  logging under a folder of its own" [ "$(J "$L2" out)" = "$OCH+lane2/runner-$L2.log" ]
t "  whose config names the lane" grep -qx 'lane=2' "$OCH+lane2/config"
t "  and whose job is handed the lane" [ "$(J "$L2" args | tr '[:space:]' ' ' | grep -c -- '--margin 60 --lane 2 --labels a,b ')" = 1 ]
t "  and, with --constraint none, no node feature" bash -c "[ -z '$(J "$L2" constraint)' ] && ! grep -qx -- --constraint '$T/slurm/jobs/$L2/args'"
gr --start --repo OpenSpineConsortium/other --site wayne --lane 2; t "a second --lane 2 is refused while the lane is queued" has "a chain for OpenSpineConsortium/other --lane 2 is already queued or running \(job $L2 PENDING\)"
t "  naming the stop that ends it" has 'grid_runner.sh --stop --repo OpenSpineConsortium/other --lane 2 ends it'
gr --status --repo OpenSpineConsortium/other
t "--status --repo shows every lane of the repository" all 'chain OpenSpineConsortium/other: labels grid,wayne,a,b' 'chain OpenSpineConsortium/other, lane 2: labels grid,wayne,a,b' "job $P1 RUNNING" "job $L2 PENDING"
gr --status --repo OpenSpineConsortium/other --lane 2
t "--status --lane 2 shows that lane alone" bash -c "printf '%s\n' \"\$1\" | grep -q 'lane 2: labels' && ! printf '%s\n' \"\$1\" | grep -q 'other: labels'" _ "$OUT"
gr --gate-off --repo OpenSpineConsortium/other --site wayne --lane 2; t "the ssh gate refuses a lane past the first" has 'the ssh gate speaks for a repository.s first chain alone'
gr --stop --repo OpenSpineConsortium/other --lane 2; t "--stop --lane 2 cancels that lane's queued job" has "cancelled job $L2"
t "  writing the lane's STOP, not the first chain's" bash -c "[ -e '$OCH+lane2/STOP' ] && [ ! -e '$OCH/STOP' ]"
t "  and leaves the first chain's job running" [ "$(J "$P1" state)" = RUNNING ]
gr --start --repo OpenSpineConsortium/other --labels a,b --site wayne --lane 2; L3=$(newest "$L2NAME")
t "the lane starts again" bash -c "[ '$L3' != '$L2' ] && [ ! -e '$OCH+lane2/STOP' ]"
echo "$OCH+lane2" > "$T/apptainer/chain"; clear_runs; plan stop
run_job "$L3"
t "a lane's job ends well" rc_is 0; t "  registering its runner with the chain's labels" has 'registered runner grid-wayne-[0-9]+-1 \(id [0-9]+, labels self-hosted,linux,x64,grid,wayne,a,b\)'
L4=$(newest "$L2NAME")
t "  after queuing its successor under the lane's name, with the lane" bash -c "[ '$L4' != '$L3' ] && [ '$(J "$L4" dependency)' = 'afterany:$L3,singleton' ] && [ \"\$(cat '$T/slurm/jobs/$L4/args')\" = \"\$(cat '$T/slurm/jobs/$L3/args')\" ]"
t "  and the STOP it was given is the lane's, not the first chain's" bash -c "[ -e '$OCH+lane2/STOP' ] && [ ! -e '$OCH/STOP' ]"
run_job "$L4"
t "the successor meets the lane's STOP" has 'STOP is set'; t "  and says how to start that lane again" has 'tools/grid_runner.sh --start --repo OpenSpineConsortium/other --lane 2 starts it again'
t "  queuing nothing more" [ "$(count "$L2NAME")" = 3 ]
gr --stop --repo OpenSpineConsortium/other --now; t "the first chain stops on its own word" has "cancelled job $P1"

echo "== --ro-bind: a chain's runners see a folder of the volume, read-only at its own path"
RB="$T/envs/pixi"; L3NAME='^hpcw_runner_OpenSpineConsortium-other\+lane3$'
gr --start --repo OpenSpineConsortium/other --site wayne --lane 3 --ro-bind "$RB"; B1=$(newest "$L3NAME")
t "a chain started with --ro-bind is queued" bash -c "[ '$RC' = 0 ] && [ -n '$B1' ]"
t "  its job handed the folder" [ "$(J "$B1" args | tr '[:space:]' ' ' | grep -c -- " --ro-bind $RB ")" = 1 ]
t "  and the chain's config records it" grep -qx "ro_binds=$RB" "$OCH+lane3/config"
echo "$OCH+lane3" > "$T/apptainer/chain"; clear_runs; plan done stop
run_job "$B1"
t "its job ends well" rc_is 0; t "  having run one GitHub job" has "== job $B1 ends: 1 GitHub jobs ran"
t "  in a container that saw the folder at its own path, read-only" grep -qx "$RB $RB ro" "$T/apptainer/binds"
t "  and nothing else of the test's folder but the node's own temp" bash -c "! grep -v -x -e '$RB $RB ro' -e '/tmp /tmp/$USER/hpcw_runner_$B1/tmp rw' '$T/apptainer/binds'"
t "  the bind on the runner's own command line" grep -q -- "-B /tmp/$USER/hpcw_runner_$B1/tmp:/tmp -B $RB:$RB:ro .*/home/runner/bin/Runner.Listener run$" "$T/apptainer/calls"
B2=$(newest "$L3NAME")
t "  its successor handed the folder too" bash -c "[ '$B2' != '$B1' ] && [ \"\$(cat '$T/slurm/jobs/$B2/args')\" = \"\$(cat '$T/slurm/jobs/$B1/args')\" ]"
run_job "$B2"; t "  and meeting the lane's STOP" has 'STOP is set'
gr --start --repo OpenSpineConsortium/other --site wayne --lane 3 --ro-bind "$RB"; B3=$(newest "$L3NAME")
mv "$RB" "$RB.gone"; clear_runs; plan stop
run_job "$B3"
t "a node without the folder runs the container without it" bash -c "[ '$RC' = 0 ] && [ -s '$T/apptainer/binds' ] && ! grep -q '$RB' '$T/apptainer/binds'"
t "  and its log says so" has "--ro-bind $RB is not on [^ ]+: the container goes without it"
mv "$RB.gone" "$RB"; run_job "$(newest "$L3NAME")"; t "  its successor meets the lane's STOP" has 'STOP is set'

echo "== autoscale: one runner job for each queued job"
pending() { local j; for j in $(ids "$1"); do [ "$(J "$j" state)" = PENDING ] && echo "$j"; done; return 0; }
AU="$R/autoscale"; TPL=OpenSpineConsortium-symphony-template; RN="^hpcw_auto_$TPL\$"; ON='^hpcw_auto_OpenSpineConsortium-other$'
gr --autoscale --site wayne; t "--autoscale needs --repos" has '--autoscale needs --repos'
gr --autoscale --repos "OpenSpineConsortium" --site wayne; t "  each OWNER/NAME" has '--repos is OWNER/NAME'
gr --autoscale --repos "$GH_REPO" --site wayne --max-total 0; t "  and caps of one at least" has '--max-total is 1 to 1000'
gr --autoscale --repos "$GH_REPO" --site wayne --max-total 1001; t "  and of 1000 at most" has '--max-total is 1 to 1000'
gr --autoscale --repos "$GH_REPO" --site wayne --gres gpu:1; t "  and CPU runner jobs alone" has 'CPU runner jobs on the site.s batch queue alone'
gr --autoscale --repos "$GH_REPO" --site wayne --partition galhp; t "  on the site's batch queue alone" has 'no --gres, no --partition'
echo public > "$T/gh/visibility"
gr --autoscale --repos "$GH_REPO" --site wayne; t "a public repository is refused" has 'refused: .* is public'
t "  and no controller is queued" [ "$(count '^hpcw_autoscale$')" = 0 ]
echo private > "$T/gh/visibility"
gr --autoscale --repos "$GH_REPO,OpenSpineConsortium/other" --site wayne --max-per-repo 2 --max-total 3 --cpus 4 --mem 16G
t "--autoscale queues the controller" rc_is 0; t "  and says what it does" all 'autoscale controller: job' 'at most 2 for one repository and 3 in all'
AC=$(newest '^hpcw_autoscale$')
t "  a singleton of its name" [ "$(J "$AC" dependency)" = singleton ]
t "  small, on the site's worker queue" bash -c "[ '$(J "$AC" cpus)' = 1 ] && [ '$(J "$AC" mem)' = 2G ] && [ '$(J "$AC" time)' = 8:00:00 ] && [ '$(J "$AC" partition)' = '$DEF_PART' ]"
t "  logging under the controller's folder" [ "$(J "$AC" out)" = "$AU/runner-$AC.log" ]
t "  handed its repositories, caps and the runner jobs' size" [ "$(J "$AC" args | tr '[:space:]' ' ' | grep -c -- "--control --repos $GH_REPO,OpenSpineConsortium/other .*--hours 2 --margin 60 --max-per-repo 2 --max-total 3 --every 60 --idle 10 --cpus 4 --mem 16G")" = 1 ]
t "  with its caps written where a person can change them" bash -c "grep -qx 'max_per_repo=2' '$AU/autoscale.conf' && grep -qx 'max_total=3' '$AU/autoscale.conf'"
gr --autoscale --repos "$GH_REPO" --site wayne; t "a second controller is refused while one is queued" has "the controller is already queued or running \(job $AC PENDING\)"
# the queue: a grid job and one asking for GitHub's machines in a queued run, one grid job left in a run in progress,
# and one in a run that reads as pending, the head of a concurrency group that queues its runs, with a run behind it that has no job yet
mkdir -p "$T/gh/runs/$TPL"
echo '{"workflow_runs":[{"id":11}]}' > "$T/gh/runs/$TPL/queued"
echo '{"workflow_runs":[{"id":12}]}' > "$T/gh/runs/$TPL/in_progress"
echo '{"workflow_runs":[{"id":14,"created_at":"2026-11-03T10:05:00Z"},{"id":13,"created_at":"2026-11-03T10:00:00Z"}]}' > "$T/gh/runs/$TPL/pending"
echo '{"jobs":[{"status":"queued","labels":["self-hosted","grid"]}]}' > "$T/gh/runs/$TPL/jobs-13"
echo '{"jobs":[{"status":"queued","labels":["self-hosted","grid"]},{"status":"queued","labels":["ubuntu-latest"]}]}' > "$T/gh/runs/$TPL/jobs-11"
echo '{"jobs":[{"status":"completed","labels":["self-hosted","grid"]},{"status":"queued","labels":["self-hosted","grid","wayne"]},{"status":"queued","labels":["self-hosted","gpu"]}]}' > "$T/gh/runs/$TPL/jobs-12"
clear_runs
run_job "$AC" HPCW_AUTOSCALE_LOOKS=1
t "the controller's job ends well" rc_is 0
AC2=$(newest '^hpcw_autoscale$')
t "  after queuing its successor with the same arguments" bash -c "[ '$AC2' != '$AC' ] && [ '$(J "$AC2" dependency)' = 'afterany:$AC,singleton' ] && [ \"\$(cat '$T/slurm/jobs/$AC2/args')\" = \"\$(cat '$T/slurm/jobs/$AC/args')\" ]"
t "  it counts the three queued jobs these runners can take, the pending run's among them, not GitHub's machine's or a GPU's" has "$GH_REPO: 3 queued, 0 runner jobs \(0 yet to take one\), 2 submitted"
t "  and submits one runner job for each, up to the repository's cap" [ "$(count "$RN")" = 2 ]
t "  none for a repository with nothing queued" [ "$(count "$ON")" = 0 ]
U1=$(pending "$RN" | head -1)
t "  each runner job sized as asked, with no dependency" bash -c "[ '$(J "$U1" cpus)' = 4 ] && [ '$(J "$U1" mem)' = 16G ] && [ '$(J "$U1" time)' = 2:00:00 ] && [ -z '$(J "$U1" dependency)' ]"
t "  on nodes with the site's runner feature" [ "$(J "$U1" constraint)" = avx2 ]
t "  and handed one GitHub job's work" [ "$(J "$U1" args | tr '[:space:]' ' ' | grep -c -- "--once --repo $GH_REPO .*--hours 2 --margin 60 --cpus 4 --mem 16G .*--idle 10 ")" = 1 ]
t "  logging under its repository's folder" [ "$(J "$U1" out)" = "$AU/$TPL/runner-$U1.log" ]
run_job "$AC2" HPCW_AUTOSCALE_LOOKS=1
t "a second look, the two still pending, submits nothing past the cap" [ "$(count "$RN")" = 2 ]
sed -i 's/^max_per_repo=2$/max_per_repo=5/' "$AU/autoscale.conf"
AC3=$(newest '^hpcw_autoscale$'); run_job "$AC3" HPCW_AUTOSCALE_LOOKS=1
t "a cap raised in autoscale.conf counts at the next look, under the cap over all" [ "$(count "$RN")" = 3 ]
sed -i 's/^max_total=3$/max_total=1000/' "$AU/autoscale.conf"
AC3A=$(newest '^hpcw_autoscale$'); run_job "$AC3A" HPCW_AUTOSCALE_LOOKS=1
t "a cap of 1000 is taken as it is" bash -c "grep -qx 'caps=at most 5 a repository, 1000 in all' '$AU/status' && ! printf '%s\n' \"\$1\" | grep -q 'above its bound'" _ "$OUT"
sed -i 's/^max_total=1000$/max_total=5000/' "$AU/autoscale.conf"
AC3B=$(newest '^hpcw_autoscale$'); run_job "$AC3B" HPCW_AUTOSCALE_LOOKS=1
t "a cap above its bound is held to the bound, and said" has 'max_total=5000 in autoscale.conf is above its bound of 1000: 1000 is used'
t "  the bound then counting" grep -qx 'caps=at most 5 a repository, 1000 in all' "$AU/status"
sed -i 's/^max_total=5000$/max_total=3/' "$AU/autoscale.conf"
gr --status
t "--status shows the controller" all 'autoscale: OpenSpineConsortium/symphony-template,OpenSpineConsortium/other, autoscale.conf asking at most 5 runner jobs a repository and 3 in all \(bounds 1000 each\)' 'caps in force: at most 5 a repository' "controller job $(newest '^hpcw_autoscale$') PENDING" "runner jobs for $TPL: 0 running, 3 pending"
echo "== autoscale: a runner job serves one GitHub job, or none"
echo "$AU/$TPL/jobs/$U1" > "$T/apptainer/chain"; clear_runs; plan done
run_job "$U1"
t "a runner job ends well" rc_is 0; t "  having registered one runner" has "registered runner grid-wayne-$U1-1 "
t "  and run one GitHub job" has "== job $U1 ends: 1 GitHub jobs ran"
t "  queuing nothing after it" [ "$(count "$RN")" = 3 ]
t "  its state in a folder of its own" grep -q "\"job\":\"$U1\"" "$AU/$TPL/jobs/$U1/status.json"
U2=$(pending "$RN" | head -1); echo 1000000 > "$T/clock"; clear_runs; plan "clock=$((1000000 + 11 * 60))"
run_job "$U2"
t "a runner job that takes no job within its idle minutes ends" rc_is 0; t "  ending its idle runner" has "ending the idle runner grid-wayne-$U2-1"
t "  with its registration deleted and no GitHub job counted" bash -c "[ -n '$(deleted)' ] && grep -q '0 GitHub jobs ran' '$AU/$TPL/runner-$U2.log'"
echo "== autoscale: stopping it"
U3=$(pending "$RN" | tail -1); AC4=$(newest '^hpcw_autoscale$')
gr --autoscale-stop --site wayne
t "--autoscale-stop cancels the controller's queued job and the runner jobs not started" has "cancelled job $AC4, $U3"
t "  and writes STOP" [ -e "$AU/STOP" ]
run_job "$AC4" HPCW_AUTOSCALE_LOOKS=1
t "a controller job that meets STOP ends" has 'STOP is set'; t "  queuing no successor" [ -z "$(pending '^hpcw_autoscale$')" ]
gr --start --repo OpenSpineConsortium/other --site wayne --lane 4; L4=$(newest '^hpcw_runner_OpenSpineConsortium-other\+lane4$')
t "a chain still starts beside it" [ -n "$L4" ]; gr --stop --repo OpenSpineConsortium/other --lane 4 --now
gr --autoscale --repos "$GH_REPO" --site wayne; t "--autoscale after a stop starts again" rc_is 0; t "  and takes STOP away" [ ! -e "$AU/STOP" ]
gr --autoscale-stop --site wayne --now; t "--autoscale-stop --now cancels the running controller too" has 'cancelled job'

echo "== autoscale: runner jobs placed by hpcworker's race, and pending jobs placed again"
# a stand-in for framework/bin/hpcworker: its version, a placement on prip/primary (or none, STANDIN_PLACE=fail)
# and one move by job replace, each call written down; it never sees a token
HWS="$T/bin/hpcw-standin"
{ printf '#!/bin/bash\n'
  printf '{ [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ]; } && echo "hpcworker TOKEN-IN-ENV $*" >> "%s/slurm/leaks"\n' "$T"
  printf 'echo "$*" >> "%s/hpcw.calls"\n' "$T"
  printf 'case "$1 $2" in\n'
  printf '  "job version") echo "HPCW-JOB version ${STANDIN_FRAMEWORK:-31} interface 2";;\n'
  printf '  "job place") [ "${STANDIN_PLACE:-}" = fail ] && { echo "HPCW-JOB refused x: no candidate placement answered"; exit 1; }\n'
  printf '    echo "HPCW-JOB placement $6 chose prip/primary (never preempted)"; echo "HPCW-JOB options --partition=prip --qos=primary --account=wsu --no-requeue --open-mode=append";;\n'
  printf '  "job replace") echo "HPCW-JOB moved 4242 hpcw_auto_x reqp/requeue -> prip/primary (never preempted), estimate a -> b"; echo "HPCW-JOB replace looked at 1 pending job(s), moved 1";;\n'
  printf '  "job probe") [ -n "${SLURM_JOB_ID:-}" ] || { echo "run it inside a Slurm job"; exit 1; }\n'
  printf '    echo "HPCW-JOB probe msa1 fail: stat: cannot stat /home/x: No such file or directory"; echo "HPCW-JOB probe alh1 ok"; echo "HPCW-JOB probe asked 2 node(s)";;\n'
  printf 'esac\n'; } > "$HWS"
chmod 755 "$HWS"; : > "$T/hpcw.calls"
gr --autoscale --repos "$GH_REPO" --site wayne --hpcworker /nowhere/hpcworker; t "--hpcworker that is not there is refused" has 'hpcworker /nowhere/hpcworker is not there'
gr --autoscale --repos "$GH_REPO" --site wayne --hpcworker relative/hpcworker; t "  and one that is no absolute path" has 'is an absolute path'
export STANDIN_FRAMEWORK=30
gr --autoscale --repos "$GH_REPO" --site wayne --hpcworker "$HWS"; t "  and one older than framework 31" has 'is framework 30; placing runner jobs needs 31 or later'
unset STANDIN_FRAMEWORK
t "  starting no controller" [ -z "$(pending '^hpcw_autoscale$')" ]
gr --autoscale --repos "$GH_REPO" --site wayne --cpus 4 --mem 16G --hpcworker "$HWS"
t "--autoscale takes an hpcworker of framework 31" rc_is 0; t "  and says its race places the runner jobs" has 'each runner job is placed by'
AC5=$(newest '^hpcw_autoscale$')
t "  handing it to the controller" [ "$(J "$AC5" args | tr '[:space:]' ' ' | grep -c -- "--hpcworker $HWS")" = 1 ]
t "  and writing it in autoscale.conf" bash -c "grep -qx 'placement=$HWS' '$AU/autoscale.conf' && grep -qx 'replace_every=300' '$AU/autoscale.conf'"
for j in $(pending "$RN"); do set_state "$j" CANCELLED; done
clear_runs; before=$(count "$RN")
run_job "$AC5" HPCW_AUTOSCALE_LOOKS=1
t "the controller's job ends well" rc_is 0
U5=$(newest "$RN")
t "  each runner job placed where the race said" bash -c "[ '$(count "$RN")' -gt '$before' ] && [ '$(J "$U5" partition)' = prip ] && [ '$(J "$U5" qos)' = primary ] && [ '$(J "$U5" extra)' = '--account=wsu --no-requeue --open-mode=append ' ]"
t "  sized as asked" bash -c "[ '$(J "$U5" cpus)' = 4 ] && [ '$(J "$U5" mem)' = 16G ] && [ '$(J "$U5" time)' = 2:00:00 ]"
t "  the race asked for that size" grep -q -- "job place --class runner --name hpcw_auto_$TPL --time 2:00:00 --cpus 4 --mem 16G" "$T/hpcw.calls"
t "  and the log says where each went" has "$GH_REPO: placed job [0-9]+ on prip/primary \(never preempted\)"
t "the look ran job replace --runners in the controller's job" grep -qx 'job replace --runners' "$T/hpcw.calls"
t "  each move a line of its log" has 'HPCW-JOB moved 4242 hpcw_auto_x reqp/requeue -> prip/primary'
t "  after job probe, inside the controller's job" [ "$(grep -E '^job (probe|replace)' "$T/hpcw.calls" | head -1)" = "job probe --max 6" ]
t "  a node whose probe failed is a line of its log" has 'HPCW-JOB probe msa1 fail: stat: cannot stat'
if has 'HPCW-JOB probe alh1 ok'; then no "  and a node that passed is none"; else ok "  and a node that passed is none"; fi
t "  and no token reached hpcworker" no_leak
for j in $(pending "$RN"); do set_state "$j" CANCELLED; done
AC6=$(newest '^hpcw_autoscale$'); n=$(grep -c '^job replace' "$T/hpcw.calls") np=$(grep -c '^job probe' "$T/hpcw.calls")
run_job "$AC6" HPCW_AUTOSCALE_LOOKS=1 STANDIN_PLACE=fail
U6=$(newest "$RN")
t "a race that places nothing leaves the runner job on the site's batch queue" bash -c "[ '$(J "$U6" partition)' = '$DEF_PART' ] && [ '$(J "$U6" qos)' = '$DEF_QOS' ]"
t "  and says so" has 'hpcworker placed no runner job'
sed -i 's/^replace_every=300$/replace_every=0/' "$AU/autoscale.conf"
AC7=$(newest '^hpcw_autoscale$'); run_job "$AC7" HPCW_AUTOSCALE_LOOKS=1
t "replace_every=0 in autoscale.conf stops job replace" [ "$(grep -c '^job replace' "$T/hpcw.calls")" = "$((n + 1))" ]
t "  and job probe with it" [ "$(grep -c '^job probe' "$T/hpcw.calls")" = "$((np + 1))" ]
gr --autoscale-stop --site wayne --now
gr --autoscale --repos "$GH_REPO" --site wayne --hpcworker none
t "--hpcworker none keeps the batch queue" has "runner jobs keep the site's batch queue: --hpcworker none"
t "  and hands the controller none" [ "$(J "$(newest '^hpcw_autoscale$')" args | grep -c -- '--hpcworker')" = 0 ]
gr --autoscale-stop --site wayne --now

echo "== autoscale: --ro-bind reaches every runner job"
gr --autoscale --repos "$GH_REPO" --site wayne --hpcworker none --ro-bind "$RB"; AC8=$(newest '^hpcw_autoscale$')
t "--autoscale --ro-bind hands the controller the folder" [ "$(J "$AC8" args | tr '[:space:]' ' ' | grep -c -- " --ro-bind $RB ")" = 1 ]
t "  and autoscale.conf records it" grep -qx "ro_binds=$RB" "$AU/autoscale.conf"
U7=$(newest "$RN"); run_job "$AC8" HPCW_AUTOSCALE_LOOKS=1; U8=$(newest "$RN")
t "  whose look queues a runner job" bash -c "[ -n '$U8' ] && [ '$U8' != '$U7' ]"
t "  handed the folder" [ "$(J "$U8" args | tr '[:space:]' ' ' | grep -c -- " --ro-bind $RB ")" = 1 ]
echo "$AU/$TPL/jobs/$U8" > "$T/apptainer/chain"; clear_runs; plan done
run_job "$U8"
t "  which runs its runner with the folder read-only at its own path" bash -c "[ '$RC' = 0 ] && grep -qx '$RB $RB ro' '$T/apptainer/binds'"
gr --autoscale-stop --site wayne --now

echo "== the merge train"
TR="$R/train"; sha() { printf '%040d' "$1"; }
gr --train --site wayne; t "--train needs --repos" has '--train needs --repos'
gr --train --repos "$GH_REPO" --site wayne
t "--train queues the train's job" rc_is 0; TJ=$(newest '^hpcw_train$')
t "  a small singleton" bash -c "[ '$(J "$TJ" dependency)' = singleton ] && [ '$(J "$TJ" cpus)' = 1 ] && [ '$(J "$TJ" mem)' = 1G ] && [ '$(J "$TJ" time)' = 8:00:00 ]"
t "  handed its repositories and the queue its successor needs" [ "$(J "$TJ" args | tr '[:space:]' ' ' | grep -c -- "--train-job --repos $GH_REPO .*--every 60 --partition $DEF_PART --qos $DEF_QOS ")" = 1 ]
gr --train --repos "$GH_REPO" --site wayne; t "a second train is refused while one is queued" has "the train is already queued or running \(job $TJ PENDING\)"
pr() { # NUMBER CREATED STATE DRAFT ARMED LABELS(JSON) ISSUE_LABELS(JSON)
  printf '{"number":%s,"isDraft":%s,"createdAt":"%s","headRefOid":"%s","baseRefName":"main","mergeStateStatus":"%s","autoMergeRequest":%s,"labels":{"nodes":%s},"closingIssuesReferences":{"nodes":[{"labels":{"nodes":%s}}]}}' \
    "$1" "$4" "$2" "$(sha "$1")" "$3" "$([ "$5" = 1 ] && echo '{"enabledAt":"2026-11-03T20:00:00Z"}' || echo null)" "$6" "$7"
}
nodes() { printf '{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[%s]}}}}\n' "$(IFS=,; echo "$*")" > "$T/gh/graphql/$TPL"; }
green() { printf '{"total_count":3,"check_runs":[{"name":"check","status":"completed","conclusion":"success"},{"name":"gate","status":"completed","conclusion":"success"},{"name":"owner-ok","status":"completed","conclusion":"skipped"}]}\n' > "$T/gh/checks/$(sha "$1")"; }
mkdir -p "$T/gh/graphql" "$T/gh/rules" "$T/gh/checks"
echo '[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"check"},{"context":"gate"},{"context":"owner-ok"}]}}]' > "$T/gh/rules/$TPL-main"
nodes "$(pr 5 2026-11-03T10:00:00Z CLEAN true 1 '[]' '[]')" "$(pr 6 2026-11-03T10:01:00Z CLEAN false 0 '[]' '[]')" \
  "$(pr 7 2026-11-03T10:02:00Z CLEAN false 1 '[]' '[]')" "$(pr 8 2026-11-03T11:00:00Z BLOCKED false 1 '[]' '[{"name":"blocker"}]')" \
  "$(pr 9 2026-11-03T09:00:00Z DIRTY false 1 '[]' '[]')" "$(pr 10 2026-11-03T09:30:00Z BEHIND false 1 '[]' '[]')" \
  "$(pr 11 2026-11-03T09:40:00Z UNSTABLE false 1 '[]' '[]')" "$(pr 12 2026-11-03T09:50:00Z CLEAN false 1 '[]' '[]')"
green 5; green 6; green 7; green 8
echo '{"total_count":2,"check_runs":[{"name":"check","status":"completed","conclusion":"failure"},{"name":"gate","status":"completed","conclusion":"success"}]}' > "$T/gh/checks/$(sha 11)"
echo '{"total_count":1,"check_runs":[{"name":"check","status":"completed","conclusion":"success"},{"name":"owner-ok","status":"completed","conclusion":"skipped"}]}' > "$T/gh/checks/$(sha 12)"
rm -f "$T/gh/merged" "$T/gh/updated" "$T/gh/comments"
run_job "$TJ" HPCW_AUTOSCALE_LOOKS=1
t "the train's job ends well" rc_is 0
TJ2=$(newest '^hpcw_train$')
t "  after queuing its successor with the same arguments" bash -c "[ '$TJ2' != '$TJ' ] && [ '$(J "$TJ2" dependency)' = 'afterany:$TJ,singleton' ] && [ \"\$(cat '$T/slurm/jobs/$TJ2/args')\" = \"\$(cat '$T/slurm/jobs/$TJ/args')\" ]"
t "  it merges the blocker first, though it is the newest, at the head it judged" [ "$(cat "$T/gh/merged" 2>/dev/null)" = "8 $(sha 8)" ]
t "  says so" has "merged #8 at 000000000000, a blocker"
t "  and ends the look there, the default branch having moved" bash -c "[ ! -e '$T/gh/updated' ] && [ ! -e '$T/gh/comments' ]"
nodes "$(pr 5 2026-11-03T10:00:00Z CLEAN true 1 '[]' '[]')" "$(pr 6 2026-11-03T10:01:00Z CLEAN false 0 '[]' '[]')" \
  "$(pr 7 2026-11-03T10:02:00Z CLEAN false 1 '[]' '[]')" \
  "$(pr 9 2026-11-03T09:00:00Z DIRTY false 1 '[]' '[]')" "$(pr 10 2026-11-03T09:30:00Z BEHIND false 1 '[]' '[]')" \
  "$(pr 11 2026-11-03T09:40:00Z UNSTABLE false 1 '[]' '[]')" "$(pr 12 2026-11-03T09:50:00Z CLEAN false 1 '[]' '[]')"
run_job "$TJ2" HPCW_AUTOSCALE_LOOKS=1
t "the next look tells the oldest, in conflict, once" bash -c "[ \"\$(cut -f1 '$T/gh/comments')\" = 9 ] && grep -q 'conflicts with main at 000000000000' '$T/gh/comments'"
t "  brings the default branch into the one GitHub calls behind" [ "$(cat "$T/gh/updated" 2>/dev/null)" = "10 $(sha 10)" ]
t "  passes by a failed check and a required check missing, and merges the oldest green one, the draft and the unarmed left alone" [ "$(tail -1 "$T/gh/merged")" = "7 $(sha 7)" ]
t "  one a look" [ "$(wc -l < "$T/gh/merged")" = 2 ]
nodes "$(pr 9 2026-11-03T09:00:00Z DIRTY false 1 '[]' '[]')" "$(pr 10 2026-11-03T09:30:00Z BEHIND false 1 '[]' '[]')" \
  "$(pr 11 2026-11-03T09:40:00Z UNSTABLE false 1 '[]' '[]')" "$(pr 12 2026-11-03T09:50:00Z CLEAN false 1 '[]' '[]')"
TJ3=$(newest '^hpcw_train$'); run_job "$TJ3" HPCW_AUTOSCALE_LOOKS=1
t "a look with nothing green merges nothing" [ "$(wc -l < "$T/gh/merged")" = 2 ]
t "  and tells or updates no second time for the same head" bash -c "[ \$(wc -l < '$T/gh/comments') = 1 ] && [ \$(wc -l < '$T/gh/updated') = 1 ]"
echo '{"total_count":1,"check_runs":[{"name":"check","status":"completed","conclusion":"success"},{"name":"gate","status":"in_progress","conclusion":null},{"name":"owner-ok","status":"completed","conclusion":"skipped"}]}' > "$T/gh/checks/$(sha 12)"
TJ4=$(newest '^hpcw_train$'); run_job "$TJ4" HPCW_AUTOSCALE_LOOKS=1
t "  nor a check still going" [ "$(wc -l < "$T/gh/merged")" = 2 ]
green 12; touch "$T/gh/refuse-merge"
TJ5=$(newest '^hpcw_train$'); run_job "$TJ5" HPCW_AUTOSCALE_LOOKS=1
t "a merge GitHub refuses is said, not counted" bash -c "printf '%s\n' \"\$1\" | grep -q '#12 is green but the merge was refused' && [ \$(wc -l < '$TR/merged') = 2 ]" _ "$OUT"
rm -f "$T/gh/refuse-merge"
gr --status
t "--status shows the train and what it landed in the last hour" all "merge train: $GH_REPO" "train job $(newest '^hpcw_train$') PENDING" 'merged in the last hour: 2, in all: 2'
TJ6=$(newest '^hpcw_train$')
gr --train-stop --site wayne; t "--train-stop cancels the train's queued job" has "cancelled job $TJ6"; t "  and writes STOP" [ -e "$TR/STOP" ]
run_job "$TJ6" HPCW_AUTOSCALE_LOOKS=1
t "a train job that meets STOP ends, merging nothing" bash -c "printf '%s\n' \"\$1\" | grep -q 'STOP is set' && [ \$(wc -l < '$T/gh/merged') = 2 ]" _ "$OUT"
# the latest run of each check decides: a draft's failed check before a ready run that passed stands against nothing
nodes "$(pr 21 2026-11-03T08:00:00Z CLEAN false 1 '[]' '[]')"
echo '{"total_count":5,"check_runs":[{"id":10,"name":"check","status":"completed","conclusion":"failure"},{"id":12,"name":"check","status":"completed","conclusion":"success"},{"id":11,"name":"gate","status":"completed","conclusion":"success"},{"id":13,"name":"owner-ok","status":"completed","conclusion":"skipped"},{"id":9,"name":"gate","status":"completed","conclusion":"cancelled"}]}' > "$T/gh/checks/$(sha 21)"
gr --train --repos "$GH_REPO" --site wayne; TJ7=$(newest '^hpcw_train$'); run_job "$TJ7" HPCW_AUTOSCALE_LOOKS=1
t "an earlier failed run of a check gives way to the latest, which passed" [ "$(tail -1 "$T/gh/merged")" = "21 $(sha 21)" ]
echo '{"total_count":3,"check_runs":[{"id":20,"name":"check","status":"completed","conclusion":"success"},{"id":22,"name":"check","status":"completed","conclusion":"failure"},{"id":21,"name":"gate","status":"completed","conclusion":"success"}]}' > "$T/gh/checks/$(sha 22)"
nodes "$(pr 22 2026-11-03T08:00:00Z CLEAN false 1 '[]' '[]')"
TJ8=$(newest '^hpcw_train$'); run_job "$TJ8" HPCW_AUTOSCALE_LOOKS=1
t "  and a latest run that failed holds the head, though an earlier one passed" [ "$(tail -1 "$T/gh/merged")" = "21 $(sha 21)" ]
# --ready: a ready pull request auto-merge was never armed for
nodes "$(pr 23 2026-11-03T08:00:00Z CLEAN false 0 '[]' '[]')"; green 23
TJ9=$(newest '^hpcw_train$'); run_job "$TJ9" HPCW_AUTOSCALE_LOOKS=1
t "without --ready an unarmed pull request is left alone" [ "$(tail -1 "$T/gh/merged")" = "21 $(sha 21)" ]
gr --train-stop --site wayne --now; gr --train --repos "$GH_REPO" --site wayne --ready
t "--train --ready says it takes every ready pull request" has 'the first ready pull request whose head is green'
TJ10=$(newest '^hpcw_train$')
t "  and hands --ready to its job" [ "$(J "$TJ10" args | tr '[:space:]' ' ' | grep -c -- " --ready ")" = 1 ]
run_job "$TJ10" HPCW_AUTOSCALE_LOOKS=1
t "  whose look merges the ready one auto-merge was never armed for" [ "$(tail -1 "$T/gh/merged")" = "23 $(sha 23)" ]
TJ11=$(newest '^hpcw_train$')
t "  and whose successor keeps --ready" [ "$(J "$TJ11" args | tr '[:space:]' ' ' | grep -c -- " --ready ")" = 1 ]
gr --status; t "--status says so" has 'every ready pull request, armed or not'
gr --train-stop --site wayne --now

echo "== the end"
t "every job the test submitted had a wall time and ran from the runner folder" bash -c "[ ! -e '$T/slurm/refused' ]"
t "no stand-in was asked for what it does not know" bash -c "[ ! -e '$T/apptainer/refused' ]"
t "no token and no registration left any job" no_leak
t "no registration was minted over an earlier one's files" bash -c "[ ! -s '$T/gh/jit/over' ]"
OUT=$(cat "$T/banned.calls" 2>/dev/null); t "no person's command started a program a login node may ban" [ ! -s "$T/banned.calls" ]

echo "== the ssh gate: tools/tests/test_grid_gate.sh, in an environment of its own"
OUT=$(env -i HOME=/tmp USER="$USER" PATH=/usr/local/bin:/usr/bin:/bin LANG=C bash "$REPO/tools/tests/test_grid_gate.sh" 2>&1); RC=$?
printf '%s\n' "$OUT" | tail -1
t "the ssh gate's tests pass" rc_is 0
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
