# hpcworker

Your own Claude Code, running as a batch job on your university's cluster, open in claude.ai/code
or the Claude app on your phone. Version 2.

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

Run `install` again whenever you pull a newer checkout: over the same version it refreshes the
files and says so, over an older one it replaces them and says `upgraded 1 -> 2`; `profile.json`
and everything under the state directory stay as they are either way.

## The path, in your words

1. `hpcworker diag` tells you what is in place and what is not, one line per check.
2. `hpcworker probe` spends up to ten minutes on a compute node (its calls inside the container have
   budgets that add up to five) and writes `probe.json`: can the node reach Anthropic, does the
   container run, is tmux there, is your sign-in there. A second `hpcworker probe` while one is
   queued or running submits nothing.
3. `hpcworker claude login`, once, in one sitting. Claude Code itself signs you in, on a compute node,
   with your own Claude account (Pro or Max); hpcworker never sees the credential. Then, unless you
   answered it before, Claude Code asks "Enable Remote Control? (y/n)": type y, wait for "Connected",
   press Ctrl+C. Claude Code records that answer itself, and your workers use it.
4. `hpcworker worker start`. A job starts, and stays started: before it ends, each job queues the next
   one, which picks the session up again. `hpcworker worker status` shows the state and the link to
   open in Claude (claude.ai/code, or Code in the Claude app, where the session is listed by name).
5. `hpcworker worker stop` when you are done. That ends the chain: the running job leaves on its
   own and cancels the queued one; the command waits up to 45 s for the job's word and asks the
   scheduler only then.

`hpcworker claude consent` still exists for a sign-in that skipped the question: it repeats only that
question. It writes a fallback marker only when Claude Code did not record the answer itself. When a
marker already exists (the panel writes one; see below), the login sitting does not ask it again.

## The panel's sign-in: `hpcworker claude login --plain`

The extension drives the same sign-in through the portal's shell, so it needs lines it can read
rather than a full-screen terminal. `--plain` prints nothing else: it asks for the same short
allocation, runs `claude auth login` inside the image under a pseudo-terminal (`script`, the helper
the worker job uses; `lib/login_plain.sh`), and writes on stdout, one line each:

```
HPCW-LOGIN: requesting a compute node
HPCW-LOGIN: on asx1; checking whether you are signed in already
HPCW-LOGIN: starting Claude Code's sign-in; waiting for the sign-in link
HPCW-LOGIN: a menu appeared; chose the first entry         only when a screen asked for Enter first
AUTH-URL: https://claude.ai/oauth/authorize?...            Anthropic's public authorize page
HPCW-LOGIN: paste the code from that page
HPCW-LOGIN: code received, checking                        a fixed line, never the code
HPCW-LOGIN: that code was not accepted; paste it again     once per code Claude Code rejected
SIGNED-IN student@wayne.edu max                            exit 0
HPCW-LOGIN-FAILED: <one plain sentence>                    exit 1
```

The code the student pastes travels through the shell to Claude Code's terminal and is never
echoed: the terminal's echo is off for the whole sitting and Claude Code's screen is never copied to
stdout (it is matched against a few patterns only). A rejected code gives "that code was not
accepted; paste it again" once per code, judged from what Claude Code drew after that code went in:
the screen is redrawn whole on every change, so counting the words on screen would count frames.
Whether Claude Code keeps the previous rejection on screen while the next code is typed is not
measured; if it does, that stale line can count for the new code once, early, never more. The
transcript lives under `/dev/shm` for that sitting, mode 0600, and is removed with it; nothing is
written to shared storage.

**An assumption, not a measurement.** A menu before the link (a login method, a first-run screen)
is answered with Enter, which takes the highlighted first entry, and the panel is told:
`HPCW-LOGIN: a menu appeared; chose the first entry`. That the first entry is the Claude account is
a guess: the real `claude auth login` screen has not been run under the sitting yet, only the
stand-in in the tests, which draws the menu the measured flow drew. If that line shows up and the
sign-in then goes wrong, the guess is the first suspect. Enter is pressed at most once every 3 s and
six times in all, never while the link is up; a repeat prints `the menu is still up; pressed Enter
again`.

The sitting times out after ten minutes, the wait for a node after ten more, and both end in a
`HPCW-LOGIN-FAILED` sentence. `--plain` never runs `claude remote-control`: the worker job answers
that question itself (next paragraph). A worker heartbeat younger than 15 minutes that already says
`loggedIn` answers `SIGNED-IN` without an allocation. The probe job does not run the sitting:
`probe.json` records `login_flow` as not probed, and the sitting itself is the test (a dry run in
an unseeded throwaway directory measured Claude Code's first-run screens, not the student's sitting,
and it pushed two probes past their wall time; dry mode stays in `lib/login_plain.sh` for the unit
tests only).

**The consent marker.** The worker job accepts `~/.hpcworker/consent` (`$HPCW_HOME/consent`; the
site's `consent_markers` too) with any content: the panel writes `yes <time> <install id>` through
the portal's Files API when the student allows Remote Control there, `hpcworker claude consent`
writes a timestamp. When Claude Code asks "Enable Remote Control?" in the worker's terminal, the job
answers y once from that marker or from Claude Code's own `remoteDialogSeen`; the workspace trust is
pre-accepted as before. `need_consent` is written only when neither exists. A worker started seconds
after a sign-in finished asks `claude auth status` four times, 10 s apart, before saying `need_login`,
and then again every minute while it waits.

**`status.json` for the panel.** Besides the fields below, every heartbeat carries `needs` (one of
`login`, `consent`, `nothing`: the one thing the student must do now; `consent` is set as soon as no
record exists while the job is on its way, so the panel can write the marker before Claude Code
asks) and `hint` (one sentence in plain words for that). `connection.json` keeps `session_name` and
`environment_url`; `hpcworker worker status` prints the environment link.

What you should know before step 4, and the command tells you: files the worker reads and every
command's output go to Anthropic; while you are connected the transcript is also stored on
Anthropic's servers (30 days on a personal plan, five years if model training is on); no BAA covers
a personal plan, so patient data, FERPA records, IRB data and export-controlled material stay out of
the worker's directory; Remote Control draws from your plan's shared usage limit.

## What the framework enforces (cluster etiquette)

- Nothing runs on the login node beyond one scheduler command per action. Every subcommand that
  would run a container or Claude Code refuses to do so outside a job and says why. `discover` stays
  under a second of CPU: the module list comes from a glob of `$MODULEPATH` (the authoritative
  `module avail`, 0.76 s of CPU on Wayne State's login node, and the QoS query run only with `--full`).
- State is read from files the job writes (`status.json`, `connection.json`, `rc.log`) under the
  shared state directory; no client polls the scheduler in a loop, and the profile's poll floor
  (60 s or more) is part of the schema. `worker start` asks the scheduler once about the running job
  and its queued successor together; `worker stop` waits for the job's own `stop.done`, asks once,
  and cancels in one call only what the scheduler still holds; `probe` asks once whether the last
  probe is still queued or running before it submits another.
- Container temp and cache live on the compute node's local disk, in a directory named by the
  profile (`node_tmp`), removed by a trap however the job ends. `$TMPDIR` is not trusted unless the
  profile says it is node-local (at Wayne State it points at CephFS). Sockets and pipes go under
  `/dev/shm`, because `/tmp` is swept on a schedule the job does not control.
- Claude Code gets a clean environment: its own `CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER=1`, no
  `ANTHROPIC_*` or `CLAUDE_CODE_OAUTH_TOKEN*` variable (one would outrank the sign-in and switch
  Remote Control off), and the feature-flag variables left alone (Remote Control needs them).
- No token on a command line, in argv, in a job file, in a log, or in `--export`. The per-job token
  the worker mints is written 0600 into the run directory and referenced by path only. `probe.json`
  (it carries the plan and the e-mail of the sign-in) is 0600 in a 0700 directory.
- Consent is Claude Code's own record: `"remoteDialogSeen": true` in `<claude_config_dir>/.claude.json`,
  which Claude Code writes when the student answers its question. That boolean, and the workspace's
  `hasTrustDialogAccepted`, are the only two things the framework reads from that file; the marker
  files (`~/.hpcworker/consent`, or the site's own) are the fallback. The file is written only to add
  `hasCompletedOnboarding`, a theme and trust for the worker's workspace, only in the login sitting and
  when a session is about to start for a signed-in student, never removing a key and never touching a
  file it cannot parse. A worker without a recorded answer waits in state `need_consent` and says what
  to do.
- Nothing is ever deleted outside the run directories under the state directory and a job's own
  node-local temp and `/dev/shm` directory, and those go through one helper that refuses any path not
  named `hpcworker_<id>`, `hpcw_<id>` or `hpcw_probe_<id>`. The one subcommand that replaces a file
  of yours, `install --force` (profile.json), refuses to run under an agent (`CLAUDECODE`,
  `ASHLEY_REQUEST_ID` and kin) or without a terminal. No subcommand can remove `~/.ashley`, the
  profile, or a Claude Code configuration directory.

## Always on

`worker start` renders `job.sbatch` and submits it. When the job has confirmed the container and the
sign-in status, it submits the same file again with a dependency on itself (`afterany`, never
`afterok`, plus `singleton` so two links never run at once) and records the successor in `next.id`:
one successor per link, once, also across a Slurm requeue of the same job. When the wall time or a
preemption ends a link, the scheduler starts the successor, which runs `claude remote-control
--continue` in the same directory when `connection.json` is younger than seven days (tried once per
link) and otherwise registers afresh; the environment id is stable per machine, so a fresh
registration from the same login joins the same environment. `--no-chain` starts a single job. The
chain is armed only after the container check passes, so a broken setup never loops through
failing jobs.

**Stopping, in order.** `worker stop` touches `stop` and waits, reading the run directory only, up
to 45 s. The running link notices the file within 5 s, ends its session (Remote Control
deregisters), cancels its successor, writes `stopped` into `status.json` and, as its last act,
touches `stop.done`; a successor that starts and finds `stop` ends the chain itself. Then, and only
then, the command asks the scheduler once about both ids and cancels what is still there. The job's
TERM trap stays armed through all of that: a TERM that lands inside the stop path (the command's
cancel, a preemption at the same moment) hands back to the path instead of writing a state of its
own, so `stopped` is the last status written and `preempted` is never written over a stop. The
opposite was measured on job 40501099 (2026-09-29), where a cancel 15 s into the stop turned the
recorded state into `preempted`; the unit tests now send real TERMs into the rendered stop path.

## Files

```
bin/hpcworker            the command (bash)
lib/profile.py           site profile schema, validation, template rendering, the two-key consent reader (python3, stdlib, 3.6+)
lib/login_plain.sh       the panel's sign-in sitting (claude auth login under a pty, a line contract on stdout)
lib/adapters/common.sh   scheduler and runtime detection, node-local temp, the container exec line, the registration parser, needs/hint, the guarded remove
lib/adapters/slurm.sh    Slurm (run for real on the Wayne State grid)
lib/adapters/pbs.sh      PBS Pro / OpenPBS (documented commands; fixture-tested only)
lib/adapters/lsf.sh      IBM Spectrum LSF (documented commands; fixture-tested only)
profiles/wayne.json      Wayne State University
jobs/probe.sbatch        the ten-minute probe (five minutes of budgets inside the container) -> <state_dir>/probe/probe.json
jobs/worker.sbatch.tpl   the worker job, rendered per start from the profile
jobs/build_image.sbatch  a SIF with Claude Code pinned, for sites without an image (not run at Wayne State)
tests/run.sh             bash -n for every script, then the unittest suite
```

Run directory (`<shared_state_dir>/<name>/`): `job.sbatch`, `job.id`, `next.id` (successor id and
the id that queued it), `chain.log`, `node`, `status.json` (state `starting`, `need_login`,
`need_consent`, `running`, `online`, `stopped`, `preempted`, `error`; `needs` and `hint` for the
panel; heartbeat every 30 s;
`claude_login` carries `loggedIn`, `email`, `subscriptionType` and nothing else; `session_name`,
`environment_url`, `environment_id`, `requested_name`, `consent`, `consent_source`,
`workspace_trusted`, `chain`, `next_job`, `chain_note`), `connection.json` (the same session fields
plus node, job, pid, token path, permission mode, capacity), `rc.log` (Claude Code's terminal),
`job.token` (0600), `in_image.sh` and `launch.sh` (the exact command lines the job ran), `stop`
(touch it, or `hpcworker worker stop`), `stop.done` (the job's last act after it wrote `stopped`).

The registration block Claude Code 2.1.283 prints, and what the job takes from it:

```
·✔︎· Connected · phone · HEAD
    Capacity: 1/32 · New sessions will be created in the current directory
    asx10-hazy-meadow                                  -> session_name
Continue coding in the Claude mobile app or https://claude.ai/code?environment=env_01X...   -> environment_url, environment_id
```

## Adding a university

1. `hpcworker install --discover` on its login node, or copy `profiles/wayne.json` and edit. The
   schema is `hpcworker profile schema`; `hpcworker profile validate` must pass. A field the file
   carries that the installed version does not know (written by an older or a newer release) is
   not an error: `validate` names it once (`ok: ...; ignored 1 field(s) this version does not know: ...`)
   and every command leaves it out, so a `profile.json` already on a cluster keeps working after an
   upgrade. `profile set` still refuses to add a field the schema does not name.
2. `hpcworker probe`, then set `egress.class` (and `proxy_env`), `tmpdir_is_node_local`, `runtime_bin`
   or `runtime_module` from `probe.json`.
3. An image: `jobs/build_image.sbatch` builds a SIF from `docker://node:22-bookworm` with Claude Code
   pinned to a version, or point `image_store` at one your center provides.
4. A scheduler other than Slurm, PBS or LSF: add `lib/adapters/<family>.sh` with the eight calls
   (`adapter_detect_scheduler`, `adapter_detect_runtime`, `adapter_submit`, `adapter_status`,
   `adapter_cancel`, `adapter_attach`, `adapter_node_tmp`, `adapter_runtime_exec`) plus
   `adapter_interactive`, `adapter_run_short`, `adapter_status_many` and `adapter_submit_after`, a
   header block in `profile.py:header_lines`, and fixtures under `tests/fixtures/`.

## What is Wayne-State-specific

Only `profiles/wayne.json`: partitions `secp/secondary` (starts at once) and `reqp/requeue`, GPU
partitions `gmsap` and `gvohp`, `module load apptainer/1.2.2` at `/wsu/el7/gnu7/apptainer/1.2.2/bin`,
the shared sandbox image and `claude` under `/rs/rs_grp_oschome/shared/ashley`, the CephFS state
directory `/rs/rs_grp_oschome/$USER/hpcworker`, node temp at `/tmp/$USER/hpcworker_$SLURM_JOB_ID`
(never `$TMPDIR`), `claude_config_dir` `$HOME/.ashley/claude` (the sign-in the Ashley product already
made; the framework starts Claude Code there, reads `claude auth status` and the two consent
booleans), the Ashley consent marker honoured beside hpcworker's own, the portal
`https://ondemand.grid.wayne.edu` behind the VPN, the 20-process login-node cap, and the Panasas home
(new images at this site should be SIF).

The Slurm client is not bound into the container by this version, so the worker's Claude cannot
submit jobs of its own yet; Ashley's measured bind set is the template for that.

## Tests

```
bash framework/tests/run.sh                      # on the grid (system python3)
HPCW_PYTHON=python bash framework/tests/run.sh   # on a Windows checkout (the Store's python3 alias is a stub)
```

## What was run on the Wayne State grid

2026-09-28 (first build, user go2432): `install --profile wayne`; `discover`; `diag`; the unit tests
on the login node's python; three probe jobs on `secp/secondary`, each starting within a minute on
asx15, `probe.json` written (node `/tmp` is xfs with 483 GB free, `$TMPDIR` is CephFS and not
node-local, `/dev/shm` 126 GB, user namespaces on and `unshare -U` works, `/run/user/<uid>` absent so
the XDG fix is needed and is writable inside the image, tmux 2.9a and `script` present, apptainer
1.2.2 runs the sandbox in about 1 s with node v22.23.3 and Claude Code 2.1.283, egress direct:
api.anthropic.com 404, platform.claude.com 200, claude.ai 403, no DNS record for
statsig.anthropic.com); two worker jobs (`hpcw_worker`, 1 h, `secp/secondary`): the container ran,
`status.json` heartbeats every 30-35 s, `claude auth status` was read, `scancel --batch
--signal=TERM` produced state `preempted` and a clean exit, and `hpcworker worker stop` produced
state `stopped` with the job leaving on its own within 5 s.

2026-09-28/29 (the maintainer's own run, Ashley's phone host, job 40496445 on asx15): Remote Control
registered from an `sbatch` job under a pseudo-terminal with the consent already on record, and
printed the block shown above. Open question 1 is answered yes.

2026-09-29 (this revision, user go2432, student not signed in on the grid): `install --profile wayne`
kept the existing profile; the 73 unit tests pass on the login node's python 3.6.8 (0.9 s) and on a
Windows checkout; `discover` costs 0.08 s of CPU (user 0.04 s + sys 0.04 s, 0.23 s wall) and
`discover --full` 1.54 s, both listing `apptainer/1.2.2` and the three singularity modules; `diag`
gives 17 checks; `install --force` without a terminal refuses and changes nothing. Probe job 40499792
(`secp/secondary`, asx1): `probe.json` written 0600 in a 0700 directory, no "command not found" line,
`sbatch on node=true`, egress direct, `loggedIn=false`, `workspace_trusted=true` (the trust key an
earlier run had written), `remote_control_help_head` = the "must be logged in" error. Worker job
40500019 (`secp/secondary`, 1 h, asx1): container ran, `claude auth status` read, state `need_login`
as expected; the chain armed from the compute node (successor 40500052 with `afterany:40500019`,
recorded in `next.id` and `chain.log`); a second `worker start` answered "already has job 40500052
(PENDING)" from one squeue over both ids; `worker stop` made the job cancel its successor and leave on
its own within 5 s (state `stopped`, "the chain ended"), one squeue afterwards showed nothing named
`hpcw_*`, sacct shows 40500019 COMPLETED after 57 s. `~/.ashley/claude/.claude.json` kept its
mtime (2026-09-28 23:04:09) through every command and both jobs. Nothing of the user's under the
login node's `/tmp`.

2026-09-29 (this stream: the panel's sign-in, `needs`/`hint`, the consent marker; user go2432, whose
grid sign-in the maintainer had redone that morning): `install --profile wayne` kept the profile and
copied `lib/login_plain.sh`; `diag` 17 checks, consent recorded by Claude Code. Worker job 40501099
(`secp/secondary`, 1 h, `--no-chain`, asx1): the container ran, `claude auth status` said `loggedIn`
true (plan max) on the first ask, and Remote Control registered from the framework's own job for the
first time, 72 s after the job started: `rc.log` carried the block above with `wayne-40501099` and an
`environment=env_01A6...` link, parsed into `connection.json` (`session_name`, `environment_url`) and
`status.json` (`state: online`, `needs: nothing`, `hint: "Your worker is online: open it in Claude."`,
`consent_source: claude_config`, `workspace_trusted: true`); `hpcworker worker status` printed the
link; `hpcworker claude login --plain` on the login node answered `HPCW-LOGIN: already signed in (a
worker confirmed it 293s ago)` and `SIGNED-IN <email> max` from that heartbeat without an allocation;
`worker stop` made the job leave within 5 s, one squeue showed nothing named `hpcw_*`, nothing under
warrior's `/tmp` or `/dev/shm`. Found there and fixed: the CLI's one `scancel` after `stop.done`
landed while the job was still writing its state, and the TERM trap, finding `stop` already removed,
rewrote `stopped` as `preempted` (the job log shows no "stopped" line, then the cancel, then
"preempted: left cleanly"); the trap now treats `stop.done` like `stop`, and the stop path disarms it
first. Not reached, because the sign-in was present: `need_login` and `needs: login` (unit tests
only). The probe did not run to the end: job 40501098 and job 40501100, the second one submitted by
mistake one second later (`hpcworker probe --wait` submits a fresh probe rather than waiting for one),
ran at the same time in the one probe directory and both hit the 5 min limit after their second line,
inside the first container call and before any of the new dry-run code; the collision in the shared
directory is the likely cause but is not established; `probe.json` is absent now (a fresh probe
removes the earlier result), so `login_flow` is unverified on the grid and one `hpcworker probe`
(5 min) settles both. The plain sitting itself was measured against a stand-in claude only (under
Linux `script` 2.39 on WSL, 2.38 is the image's, and 2.23 on the login node, which is where the
`stty sane` in its launcher comes from), never against Claude Code's real sign-in screen with a code.
The 94 unit tests pass on the login node's python 3.6.8 with `LANG` unset, under WSL, and on a
Windows checkout (six pty scenarios skipped there).

2026-09-29 (version 2: the reviewers' findings closed; user go2432, signed in on the grid, plan max):
`hpcworker install --profile wayne` from a fresh checkout over the version-1 copy said `upgraded 1 ->
2 at ~/.hpcworker` and kept the profile; run again it said `files refreshed (same version)`; `diag`
17 checks. Probe job 40501174 (`secp/secondary`, asx1, queued 2 min): finished in 3 min 33 s under the
ten-minute wall time and wrote `probe.json` (version 2, `login_flow` "not probed", `remote_control_flags`
now the signed-in list: `--capacity --continue --debug --debug-file --help --name --permission-mode
--remote-control-session-name-prefix --session-id --spawn --verbose`, egress direct, loggedIn true);
its first exec took 29 s where the 04:06 probe on the same node took 1 s, and its two 30 s in-image
calls (the XDG fix, curl) came back empty, so those two now share one exec with a 60 s budget (sum
still 300 s); probe job 40501182 under that change (asx1 again) finished in 51 s with `xdg in image:
writable`, `curl in image: 404` and a first exec of 9 s. A second `hpcworker probe` while the first
was PENDING answered "still PENDING; nothing submitted". Worker job 40501175 (`secp/secondary`, 1 h, chain on, asx13): container ran, loggedIn
true on the first ask, successor 40501176 queued; the job tried `--continue` because `connection.json`
was 77 min old and **Claude Code 2.1.283 refused it beside `--capacity`** ("--session-id and
--continue cannot be used with --spawn, --capacity, or --create-session-in-dir"), backed off 20 s,
registered afresh and was `online` 45 s after the job began; the launcher now leaves `--capacity` out
of a resume (what capacity a resumed session has is not measured). The registration block named the
session `wayne-40501099`, the previous link's name, not the requested `wayne-40501175`; not explained
(the environment is the same one, `env_01A6...`). `hpcworker worker stop` returned after 12 s with
"the job left on its own within 10s; the chain ended": the job's log shows `chain: successor 40501176
cancelled`, `stopped (stop file)`, then the cleanup line; `status.json` reads `stopped` (`needs`
nothing, `next_job` empty, `chain_note` "chain ended by request"), `stop.done` exists, `stop` and
`next.id` are gone, `rc.log` ends with Claude Code's "Environment preserved" after the Ctrl-C, the
command sent no scancel (nothing was left at the scheduler), one squeue afterwards showed nothing
named `hpcw_*`, and nothing of ours was under warrior's `/tmp`. The 104 unit tests pass under WSL and
on a Windows checkout (six pty scenarios skipped there), including four that send real TERMs into
the rendered stop path and one that drives the sitting with three wrong codes each drawn in two
frames; the first WSL run caught the sitting crediting a burst of codes to the last one only, which
is why rejections are now matched to codes in order. Still not measured: the real `claude auth login` screen under the sitting (the menu-before-
the-link answer is an assumption, see above), and a TERM landing inside a live job's stop path on the
grid (the unit tests cover it; the live stop finished before any signal).

Not verified on the grid by the framework itself, because the student's grid sign-in was gone before
the first worker started (`claude auth status` inside the image says `loggedIn: false`): the
registration parse on a live `rc.log` (the parser is unit-tested against the exact block above, with
terminal codes), the consent answer typed from the marker fallback, `--continue` in a successor
after a link ends, a successor actually starting after its parent's wall time, and two Remote Control
hosts on one login. Those need one student session: `hpcworker claude login`, `hpcworker worker
start`, then `hpcworker worker status`. While logged out, `claude remote-control --help` prints only
"You must be logged in to use Remote Control", so the job assumes the documented flags (`--name`,
`--capacity`, `--continue`, `--permission-mode`) until a signed-in probe records them.
