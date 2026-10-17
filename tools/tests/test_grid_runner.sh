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
clear_runs() { rm -f "$T/apptainer/runs" "$T/gh/deleted"; : > "$T/sleeps"; }
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
t "  with everything a job needs on its command line" [ "$(J "$C1" args | tr '\n' ' ')" = "--serve --repo $GH_REPO --runner-dir $R --site wayne --runtime-bin $WAYNE_BIN --runtime-module $WAYNE_MOD --hours 2 --margin 30 --labels gpu --cpus 4 --mem 16G --gres gpu:1 --partition $DEF_PART --qos $DEF_QOS " ]
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
t "  with the same arguments, size and wall time" bash -c "[ \"\$(cat '$T/slurm/jobs/$C2/args')\" = \"\$(cat '$T/slurm/jobs/$C1/args')\" ] && [ '$(J "$C2" time)' = 2:00:00 ] && [ '$(J "$C2" gres)' = gpu:1 ] && [ '$(J "$C2" partition)' = '$DEF_PART' ] && [ '$(J "$C2" qos)' = '$DEF_QOS' ]"
t "  and wrote it down" [ "$(cat "$CH/next")" = "$C1 $C2" ]
t "the wall time and the margin are read from the start time and --hours" has 'wall time ends 1970-01-12T15:46:40Z; the last registration is made before 1970-01-12T15:16:40Z \(30 minutes of margin\)'
t "the container was given the node's GPU, which --gres asked for" has "image 2.338.0, with the node's GPU"
t "three registrations were minted, one at a time" [ "$(n_jit)" = 3 ]
t "  named after the site, the job and their turn" [ "$(jit_requests | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | tr '\n' ' ')" = "grid-wayne-$C1-1 grid-wayne-$C1-2 grid-wayne-$C1-3 " ]
t "  with the chain's labels" [ "$(jit_requests | grep -c '"labels":\["grid","wayne","gpu"\]')" = 3 ]
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
gr --start --repo OpenSpineConsortium/other --labels a,b --site wayne --partition secp --qos secondary
t "a chain for another repository starts beside the first" rc_is 0; t "  with its own labels" has 'runs-on: \[self-hosted, grid, wayne, a, b\]'
O1=$(newest '^hpcw_runner_OpenSpineConsortium-other$'); echo n042 > "$T/slurm/jobs/$O1/node"; set_state "$O1" RUNNING
t "  on the queue --partition and --qos give over the site's" bash -c "[ '$(J "$O1" partition)' = secp ] && [ '$(J "$O1" qos)' = secondary ]"
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
