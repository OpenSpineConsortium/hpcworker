# hpcworker

Your own Claude Code, running as a batch job on your university's cluster, open in claude.ai/code
or the Claude app on your phone. Version 1.

The cluster-side half of Ashley Bridge. Bash plus the system `python3`, nothing installed, nothing
running on the login node except the one `sbatch`, `squeue` or `scancel` an action needs. Claude Code
runs inside a container on a compute node and registers itself with Anthropic over outbound HTTPS
(Claude Code's Remote Control); the browser extension in `../extension/` only starts, watches and
stops that job through your Open OnDemand portal.

## Install, in one line

```
git clone <this repository> && bash ashley-bridge/framework/bin/hpcworker install --profile wayne
```

At a university without a profile: `hpcworker install --discover` seeds one from the login node,
`hpcworker probe` corrects it from a compute node, and you edit the rest (`hpcworker profile set`).

## The path, in your words

1. `hpcworker diag` tells you what is in place and what is not, one line per check.
2. `hpcworker probe` spends five minutes on a compute node and writes `probe.json`: can the node
   reach Anthropic, does the container run, is tmux there, is your sign-in there.
3. `hpcworker claude login`, once. Claude Code itself signs you in, on a compute node, with your own
   Claude account (Pro or Max). hpcworker never sees the credential; Claude Code keeps it.
4. `hpcworker claude consent`, once. Claude Code asks whether to enable Remote Control; you answer
   `y` yourself, and hpcworker records only that you did.
5. `hpcworker worker start`. A job starts; when it is up, open claude.ai/code (or Code in the Claude
   app) and find the session named `<site>-<job id>`. `hpcworker worker status` shows the state.
6. `hpcworker worker stop` when you are done. The job ends cleanly at its wall time anyway; start it
   again within four hours and it resumes the same session.

What you should know before step 5, and the command tells you: files the worker reads and every
command's output go to Anthropic; while you are connected the transcript is also stored on
Anthropic's servers (30 days on a personal plan, five years if model training is on); no BAA covers
a personal plan, so patient data, FERPA records, IRB data and export-controlled material stay out of
the worker's directory; Remote Control draws from your plan's shared usage limit.

## What the framework enforces (cluster etiquette)

- Nothing runs on the login node beyond one scheduler command per action. Every subcommand that
  would run a container or Claude Code refuses to do so outside a job and says why.
- State is read from files the job writes (`status.json`, `connection.json`, `rc.log`) under the
  shared state directory; no client polls the scheduler in a loop, and the profile's poll floor
  (60 s or more) is part of the schema.
- Container temp and cache live on the compute node's local disk, in a directory named by the
  profile (`node_tmp`), removed by a trap however the job ends. `$TMPDIR` is not trusted unless the
  profile says it is node-local (at Wayne State it points at CephFS). Sockets and pipes go under
  `/dev/shm`, because `/tmp` is swept on a schedule the job does not control.
- Claude Code gets a clean environment: its own `CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER=1`, no
  `ANTHROPIC_*` or `CLAUDE_CODE_OAUTH_TOKEN*` variable (one would outrank the sign-in and switch
  Remote Control off), and the feature-flag variables left alone (Remote Control needs them).
- No token on a command line, in argv, in a job file, in a log, or in `--export`. The per-job token
  the worker mints is written 0600 into the run directory and referenced by path only.
- The one-time "Enable Remote Control?" question is answered by the job only from a marker file the
  student wrote themselves (`~/.hpcworker/consent`, or the site's own marker); without it the job
  waits in state `need_consent` and says what to do.

## Files

```
bin/hpcworker            the command (bash)
lib/profile.py           site profile schema, validation, template rendering (python3, stdlib, 3.6+)
lib/adapters/common.sh   scheduler and runtime detection, node-local temp, the container exec line
lib/adapters/slurm.sh    Slurm (run for real on the Wayne State grid)
lib/adapters/pbs.sh      PBS Pro / OpenPBS (documented commands; fixture-tested only)
lib/adapters/lsf.sh      IBM Spectrum LSF (documented commands; fixture-tested only)
profiles/wayne.json      Wayne State University
jobs/probe.sbatch        the five-minute probe -> <state_dir>/probe/probe.json
jobs/worker.sbatch.tpl   the worker job, rendered per start from the profile
jobs/build_image.sbatch  a SIF with Claude Code pinned, for sites without an image (not run at Wayne State)
tests/run.sh             bash -n for every script, then the unittest suite
```

Run directory (`<shared_state_dir>/<name>/`): `job.sbatch`, `job.id`, `node`, `status.json` (state
`starting`, `need_login`, `need_consent`, `running`, `online`, `stopped`, `preempted`, `error`;
heartbeat every 30 s; `claude_login` carries `loggedIn`, `email`, `subscriptionType` and nothing
else), `connection.json` (session name, link if printed, node, job, pid, token path), `rc.log`
(Claude Code's terminal), `job.token` (0600), `in_image.sh` and `launch.sh` (the exact command lines
the job ran), `stop` (touch it, or `hpcworker worker stop`).

## Adding a university

1. `hpcworker install --discover` on its login node, or copy `profiles/wayne.json` and edit. The
   schema is `hpcworker profile schema`; `hpcworker profile validate` must pass.
2. `hpcworker probe`, then set `egress.class` (and `proxy_env`), `tmpdir_is_node_local`, `runtime_bin`
   or `runtime_module` from `probe.json`.
3. An image: `jobs/build_image.sbatch` builds a SIF from `docker://node:22-bookworm` with Claude Code
   pinned to a version, or point `image_store` at one your center provides.
4. A scheduler other than Slurm, PBS or LSF: add `lib/adapters/<family>.sh` with the eight calls
   (`adapter_detect_scheduler`, `adapter_detect_runtime`, `adapter_submit`, `adapter_status`,
   `adapter_cancel`, `adapter_attach`, `adapter_node_tmp`, `adapter_runtime_exec`) plus
   `adapter_interactive` and `adapter_run_short`, a header block in `profile.py:header_lines`, and
   fixtures under `tests/fixtures/`.

## What is Wayne-State-specific

Only `profiles/wayne.json`: partitions `secp/secondary` (starts at once) and `reqp/requeue`, GPU
partitions `gmsap` and `gvohp`, `module load apptainer/1.2.2` at `/wsu/el7/gnu7/apptainer/1.2.2/bin`,
the shared sandbox image and `claude` under `/rs/rs_grp_oschome/shared/ashley`, the CephFS state
directory `/rs/rs_grp_oschome/$USER/hpcworker`, node temp at `/tmp/$USER/hpcworker_$SLURM_JOB_ID`
(never `$TMPDIR`), `claude_config_dir` `$HOME/.ashley/claude` (the sign-in the Ashley product already
made; the framework starts Claude Code there and reads only `claude auth status`), the Ashley consent
marker honoured beside hpcworker's own, the portal `https://ondemand.grid.wayne.edu` behind the VPN,
the 20-process login-node cap, and the Panasas home (new images at this site should be SIF).

The Slurm client is not bound into the container by this version, so the worker's Claude cannot
submit jobs of its own yet; Ashley's measured bind set is the template for that.

## Tests

```
bash framework/tests/run.sh
```

## What was run on the Wayne State grid (2026-09-28, user go2432)

Verified: `install --profile wayne`; `discover` (about 1 s of CPU, 2.2 s wall on warrior); `diag`;
the 54 unit tests on the login node's python (0.4 s); three probe jobs on `secp/secondary`, each
starting within a minute on asx15, `probe.json` written (node `/tmp` is xfs with 483 GB free,
`$TMPDIR` is CephFS and not node-local, `/dev/shm` 126 GB, user namespaces on and `unshare -U`
works, `/run/user/<uid>` absent so the XDG fix is needed and is writable inside the image, tmux 2.9a
and `script` present, apptainer 1.2.2 runs the sandbox in about 1 s with node v22.23.3 and Claude
Code 2.1.283, egress direct: api.anthropic.com 404, platform.claude.com 200, claude.ai 403, no DNS
record for statsig.anthropic.com); two worker jobs (`hpcw_worker`, 1 h, `secp/secondary`): the
container ran, `status.json` heartbeats every 30-35 s, `claude auth status` was read, `scancel
--batch --signal=TERM` produced state `preempted` and a clean exit, and `hpcworker worker stop`
produced state `stopped` with the job leaving on its own within 5 s.

Not verified, because the student's grid sign-in was gone before the first worker started
(`claude auth status` inside the image said `loggedIn: false`, `authMethod: none`; Ashley's own
worker on the same login reported the same at 02:51 UTC): whether `claude remote-control` registers
from an `sbatch` job under tmux, the consent-marker answer, the session name and link in
`connection.json`, `--continue` after a restart, and two Remote Control hosts on one login. Those
need one student session: `hpcworker claude login`, `hpcworker claude consent`, `hpcworker worker
start`, then `hpcworker worker status`. While logged out, `claude remote-control --help` prints
only "You must be logged in to use Remote Control", so the job assumes the documented flags
(`--name`, `--capacity`, `--continue`, `--permission-mode`) until a signed-in probe records them.
