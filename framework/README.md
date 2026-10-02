# hpcworker

Your own Claude Code, running as a batch job on your university's cluster, open in claude.ai/code
or the Claude app on your phone. Version 11.

Version 11 is the cluster side of Beethoven 12.0.0, which reaches the grid over ssh without the VPN
first, and through the Open OnDemand portal (version 10's path) only when no ssh bridge is there. It
adds the browser's key: `hpcworker browser-key add`, run once over the student's first ssh sign-in
(password and code), writes one `authorized_keys` line whose only command is `hpcworker gate`, and the
gate lets that key do eight fixed things and never a Claude sign-in (see "The browser's key" and "The
gate" below). `worker watch --json` streams a worker's state as lines; `connect` and `claude login
--plain` work over a plain ssh exec with no terminal, the code arriving on standard input; `claude
login --profile SITE` sets up an account that never was; and the site profile is read, and the job
file and the workspace guide are filled, by awk and bash (`lib/profile.awk`, `lib/profile_sh.sh`), so no
command on the extension's path starts python3 at all, the first connect included (see "The login
node"). Everything Beethoven 11.0.0 and 10.0.0 use still works: see "Version 11 and what it keeps".

**Folders above the copy (framework 12).** A folder above the lab's copy that others may change is refused only when the lab owns it (`chmod +t` on it fixes that). A folder above the lab's own folders that belongs to someone else, such as the CephFS scaffold folders at Wayne State that are owned by root or by another lab's user and are writable by everyone, is reported by `browser-key check` and by `diag` as a note for the university and does not refuse a key: the lab's shared code already runs from under those folders in every version, so refusing every student's key over them would protect nobody. Ask the university for `chmod +t` on them.


Version 10 is the cluster side of Beethoven 11.0.0 (the wire contract is
`../docs/V11_CONTRACT.md`): one line, `hpcworker connect`, sets the account up, records the Remote
Control answer, starts the worker and signs in to Claude; a worker says it is `queued` the moment the
scheduler takes it; every run keeps a plain-words `progress.log`; `worker status` opens with one line
for a person and has a `--json` form; a job left waiting for the Claude sign-in stops itself after 20
minutes; and `hpcworker login-setup` (unproven on the grid) is the one-time key step for an account
whose portal terminal asks for a password. Everything the 10.0.0 extension and a framework 9 worker
use still works: see "Version 10 and what it keeps" below.

The cluster-side half of Beethoven, the browser extension. Bash, coreutils, awk, sed and grep on the
login node (the system `python3` only for `profile show|set|validate|schema` and a discovered seed, typed
by a person at a terminal); nothing installed; nothing running on the login node beyond the one
`sbatch`, `squeue` or `scancel` an action needs and, for connect's sign-in, `srun` relayed by bash (see
"The login node" below: warrior's banner bans `python3` among others). Claude Code runs inside a container on a compute node and registers itself with
Anthropic over outbound HTTPS (Claude Code's Remote Control); the browser extension in
`../extension/` only starts, watches and stops that job through your Open OnDemand portal.

## Install: the lab's shared copy, or a copy of your own

An account has the command one of two ways. Everything after the install (`probe`, `claude login`,
`worker start|stop|status`, `diag`) is the same `~/.hpcworker/bin/hpcworker` either way.

**The lab's shared copy** (Wayne State, and any site whose profile names `shared_install`). The lab
keeps one copy of this framework on its shared storage, published by `tools/deploy_shared.sh`, and
every account uses it; nothing of the code is copied into the home:

```
bash /rs/rs_grp_oschome/shared/beethoven/hpcworker/current/bin/hpcworker install --shared /rs/rs_grp_oschome/shared/beethoven/hpcworker/current --profile wayne
```

(Until 2026-09-30 the lab folder was `/rs/rs_grp_oschome/shared/ashley`; that name is now a link to
`shared/beethoven`, and Beethoven 4.0.0 to 7.0.0 still run this command with it. Versions 7 and 8 keep
the spelling already on record, so the old command changes nothing; see "The rename" below.)

That is the whole install, and it is the command the extension runs through the portal's shell. It
writes four things into `~/.hpcworker` and nothing else: `bin/hpcworker`, a short launcher
that runs the shared copy (a regular file, never a link, so a copy or an upload onto it cannot reach
the shared tree); `shared`, one line naming the shared directory (the marker); `profile.json`, copied
from the shared copy's `profiles/<site>.json` and kept if one is there; and `log/`. The consent marker
(`~/.hpcworker/consent`) stays there too, and the run directories stay under `shared_state_dir`. `DIR`
may be left out when the profile names it (`hpcworker install --shared --profile wayne`).
`hpcworker version` then says `11 (shared copy at DIR)`, and `hpcworker diag` names the shared
directory and the numbered directory it resolves to.

- Run `install` again (through the launcher, or from a checkout) and it stays on the shared copy: it
  rewrites the launcher, the marker and the `~/.bashrc` block, keeps the profile, and says
  `launcher and marker refreshed (nothing copied)`, the same words every time.
- Over a copy of your own (the older way), `install --shared` moves `bin/hpcworker`, `lib/`, `jobs/`,
  `profiles/`, `VERSION` and `README.md` into `~/.hpcworker/replaced/<time>/`, never deleting them,
  and leaves the profile, the consent marker and the state directory alone. It refuses, changing
  nothing, while a worker of yours may still run from that copy (a queued successor, a heartbeat under
  three minutes old, a job submitted that has not reported, a probe under way): a running job reads
  `lib/` again on every call into its container. Stop the worker first.
- A shared directory this account cannot use is refused with exit code 3 and one sentence, changing
  nothing: `hpcworker: the shared copy at DIR cannot be used from this account: <why>. Nothing was
  changed.` (it does not exist or this account may not open it, it has no `VERSION`, it lacks
  `bin/hpcworker`, `lib/` or the job template, or it is not an absolute path). When the account cannot
  read the directory at all, bash itself refuses before hpcworker runs (`Permission denied`, exit 126;
  `No such file or directory`, exit 127). The extension falls back to a copy of the student's own on
  any of the three. If the shared copy later becomes unreadable, the launcher says so and exits 3.
- **At Wayne State the student's account must be in the group `oschome`.** The volume
  `/rs/rs_grp_oschome` is `drwxrws---` with no access for others, so an account outside the group
  cannot reach the shared copy, the image, `claude` or its own `shared_state_dir` under it; a copy of
  its own does not change that. The group has two members today (2026-09-29): the maintainer and the
  group's owner. Adding a student is for C&IT or the group owner.

A worker job names the numbered directory the shared copy resolves to (`current` is followed one link
when the command starts, never further: `/rs/rs_grp_oschome` is itself a link to the volume's physical
path, which stays out of jobs and messages). A running worker and the successors it queues keep that
version while `current` moves on; `worker start` picks up the new one. So a published version is
never removed while a worker may still name it.

**The rename (2026-09-30).** The lab folder at Wayne State was `/rs/rs_grp_oschome/shared/ashley`
until the VS Code tool it came with was renamed Beethoven for VS Code; it is now
`/rs/rs_grp_oschome/shared/beethoven`, and `shared/ashley` is a relative link to it, kept until every
build older than Beethoven 8.0.0 is retired (Beethoven 4.0.0 to 7.0.0 carry the old name in their
bundled profile and run `install --shared` with it). The sign-in folder moved the same way:
`~/.beethoven/claude`, reached also as `~/.ashley/claude`. Two spellings of one shared copy (the same
last name under one physical parent) are one copy to `install --shared`: the spelling on record wins
(the one the running copy's site profile names, else the account's marker), so the older command
rewrites the launcher and the marker with the bytes they already have, and its message names the
folder as it was given, which an older panel then hides as before. A different folder is never
taken for it.

**A copy of your own** (a site with no shared copy, or `--own`): the command copies itself into
`~/.hpcworker`.

```
git clone <this repository> && bash <the checkout>/framework/bin/hpcworker install --profile wayne
```

At a university without a profile: `hpcworker install --discover` seeds one from the login node,
`hpcworker probe` corrects it from a compute node, and you edit the rest (`hpcworker profile set`).
Run `install` again whenever you pull a newer checkout: over the same version it refreshes the files
and says so, over an older one it replaces them and says `upgraded 4 -> 5`; `profile.json` and
everything under the state directory stay as they are either way. A copy of your own in
`~/.hpcworker` (the extension uploads one when the shared copy cannot be used) takes over from a
shared copy: `install` run from it moves the marker into `~/.hpcworker/replaced/<time>/`, and
`install --own` does the same from anywhere.

Either way, `hpcworker install` also puts `~/.hpcworker/bin` on PATH for terminals through one
managed block in `~/.bashrc` (rewritten in place on every install, never duplicated; `--no-shell-path`
leaves the file alone, and a custom `HPCW_HOME` only prints the one-line hint). The extension never
depends on it: it calls the command by its full path. A terminal opened before the install needs
`export PATH="$HOME/.hpcworker/bin:$PATH"` once.

### Publishing the shared copy (the lab's maintainer)

```
tools/deploy_shared.sh --dry-run     # what would change, nothing written
tools/deploy_shared.sh               # publish framework/ as v<VERSION> and point current at it
```

From the repository on the maintainer's machine, over `ssh wsu-grid` (BatchMode; `--host`, `--root`,
`--group`, `--site` for another cluster; `--here` on the cluster itself). It publishes exactly
`bin/`, `lib/`, `jobs/`, `profiles/`, `VERSION` and `README.md` (no tests), checked first: `VERSION`
must match the `VERSION=` line of `bin/hpcworker`, every file must have LF endings, every script must
pass `bash -n`. On the cluster it is file work on the login node and nothing else (tar, chmod,
setfacl, one link; no scheduler call, no container, no temp file under `/tmp`):

```
ROOT/v10/         one directory per framework version, read-only for everyone
ROOT/current      a relative link to v10, switched in one rename (ln -s, then mv -T)
ROOT/deploy.log   one line per publish
```

`ROOT` is the directory above `current` in the site profile's `shared_install`
(`/rs/rs_grp_oschome/shared/beethoven/hpcworker` at Wayne State). The group is the one that owns the
directory above `ROOT` (`oschome`): read and traverse, no write; others nothing. The volume carries
POSIX ACLs with a group-writable default, so the script sets the group and mask entries (and the
directories' defaults) to read as well, and prints `getfacl` to show it. Running it again with the
same files changes nothing and says so; a changed `README.md` alone is updated in place; any other
difference under the same version is refused (publish it as the next integer version, or `--replace`,
which keeps the old directory as `v<N>.replaced-<time>`). Older versions are never removed by it.

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
   one, which picks the session up again. `hpcworker worker status` says where it is in one line
   ("Your worker is in line for a computer (6 min so far).", "Your worker is online (ready 7 min after
   you asked).") and gives the link to open in Claude (claude.ai/code, or Code in the Claude app,
   where the session is listed by its title, "Wayne State grid"). `worker start --wait [MIN]` and
   `worker watch` follow it until it is online.
   The first start also puts a `CLAUDE.md` in the worker's folder: what Claude Code there needs to
   know about the cluster (see "The workspace guide"); it is yours to edit and is never replaced.
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
`environment_url`; `hpcworker worker status` prints the environment link. Version 10's fields are in
"Where a worker is" below.

## The extension's line: `hpcworker connect` (version 10)

```
hpcworker connect [--name NAME] [--profile SITE] [--consent INSTALL_ID]
                  [--login auto|always|fresh|never] [--permission-mode default|acceptEdits|plan] [--no-chain]
```

Beethoven 11.0.0 types this one line into the portal's shell with `exec` (so the shell ends when
connect ends), naming the lab's shared copy by its full path. In order:

1. **Setup.** When the account does not already run the shared copy the site profile names (no
   marker, a marker naming another folder, no launcher, a copy of its own, or no `profile.json`), it
   runs the shared install for that folder with `--profile SITE`, with all its guards, but without
   the `~/.bashrc` block (the extension never needs it). `HPCW-STEP setup changed` or `setup ready`.
2. **Consent** (with `--consent`): `~/.hpcworker/consent` becomes `yes <ISO-8601 UTC> <install id>`,
   written atomically, mode 0600. `HPCW-STEP consent`.
3. **Restricted.** A `.restricted` marker in the workspace, or the profile's `restricted: true` or
   `restricted_workspaces` (names, or `"*"`): nothing is submitted.
4. **The worker.** `worker start`'s own check (one squeue over the job and its successor): a job of
   the run in line or running is kept, otherwise one is submitted (`HPCW-STEP queued <job> new|kept
   <run dir>`; the running one is named when there are two).
5. **The sign-in**, by `--login`: `auto` skips it when the newest `status.json` of any run that
   carries Claude Code's answer says `loggedIn: true` (read before this start writes its queued file,
   so a returning Connect after a Stop does not sign in again); `always` runs it (Claude Code answers
   at once when it is signed in); `fresh` runs `claude auth logout` first ("Use another account");
   `never` skips it. The sitting is framework 9's plain one (`lib/login_plain.sh`), with the lines
   listed under "The panel's sign-in" below, on `partition_cpu`.
6. `HPCW-STEP done`, exit 0.

Each `HPCW-STEP` line appears at most once, whole, at the start of a line, in that order. A failure
ends connect with `HPCW-STEP failed <code> <sentence>` and the code's exit status: `usage` 2 (nothing
done), `setup` 3, `restricted` 4, `refused` 5 (sbatch's message on one line), `signin-node` 6 (no
computer for the sitting within 600 s), `signin-code`, `signin-timeout` and `signin` 7 (after the
sitting's own `HPCW-LOGIN-FAILED:` line; the worker keeps its place in line), `other` 1. Under connect
anything that would have been an `hpcworker: ...` error becomes `failed other`.

**One writer, and the keepalive.** The sitting's allocation (`srun`, its own messages too) runs into
a pipe, and `lib/relay.sh` copies it to the terminal one whole line at a time; when 20 s pass with
nothing written and no part of a line waiting, it writes `HPCW-LOGIN: still waiting` (at the first
of its once-a-second ticks within half a second of the 20 s, so the gap is 19.5 to 20.5 s). A part of
a line left waiting five seconds is written as a line of its own (at the fifth of the relay's ticks
after the one that brought its last byte, 5 to 6 s after it). The relay is bash and nothing else
(the first framework 10 build relayed with `python3`, which warrior bans), and it never reads with a
timer: bash 4.2's `read -t` can drop what it had read of a line when the timer fires (bash 4.2.46
built from source dropped the `SIGNED` of a split `SIGNED-IN` line). So it blocks in a plain `read`,
and connect starts `relay.sh --ticks` beside srun, writing a 6-byte tick line into the same pipe once
a second (coreutils `sleep 1` between ticks, the only program either half starts). When the portal's
shell is cut, srun, the ticker and the relay are all in the terminal's process group and end with its
SIGHUP; the ticker also stops when srun's side of the pipe has ended or the relay is gone. The sitting
writes the same line itself, under connect only, while it waits for the link and for the code. The
portal's shell closes a connection with no activity (Open OnDemand's default is 300 s), and the wait
for the sign-in computer alone can be ten minutes. `claude login --plain`, which the 10.0.0 extension
types, prints no keepalive and is otherwise framework 9's. The terminal's echo is turned off on the
login node too while the sitting runs, so a pasted code is not shown whatever `srun --pty` does with
an output that is a pipe. That last point, and `srun --pty` with its output piped at all, have not
been run on the grid.

**Time.** Connect ends within 840 s of its start: at most 600 s for the sign-in computer, then a code
budget of `min(600, 840 - seconds already spent)`, never under 120 s. The extension cuts any shell
sitting at 15 minutes.

```
HPCW-STEP setup changed
HPCW-STEP consent
HPCW-STEP queued 40501234 new /rs/rs_grp_oschome/st1234/hpcworker/worker
HPCW-STEP signin
HPCW-LOGIN: requesting a compute node
HPCW-LOGIN: still waiting
HPCW-LOGIN: on asx15; checking whether you are signed in already
HPCW-LOGIN: starting Claude Code's sign-in; waiting for the sign-in link
AUTH-URL: https://claude.ai/oauth/authorize?code=true&client_id=...
HPCW-LOGIN: paste the code from that page
HPCW-LOGIN: code received, checking
SIGNED-IN alex@wayne.edu max
HPCW-STEP signed-in alex@wayne.edu max
HPCW-STEP done
```

A returning Connect after a Stop, signed in on the grid: `setup ready`, `consent`, `queued <job> new
<run dir>`, `signed-in <email> <plan>`, `done`, with no allocation.

The other verbs the extension types: `worker status --json` (below), `worker stop` (unchanged), `worker
restrict --name N` (writes `<state_dir>/workspaces/N/.restricted`, mode 0644, `restricted <time> by
hpcworker worker restrict`; says `worker N: marked restricted (<path>); it will not start there until
the marker is removed` or `worker N: already marked restricted (<path>)`; never stops a running worker),
and `claude consent --record INSTALL_ID` (the marker as connect writes it, no question asked, no
profile needed; a malformed id is refused with exit 2).

## Where a worker is: `queued`, `progress.log`, `worker status` (version 10)

**The queued file.** `worker start` writes `status.json` the moment the scheduler takes the job,
atomically and before it prints anything: `{"version":10, ..., "state":"queued", "message":"waiting
for a computer", "needs":"nothing", "hint":"Your worker is in line for a computer.", "submitted_at":
..., "title":"Wayne State grid", "renewal":false, ...}` (all the keys, in order, in the contract). It
removes the last job's `node` file before it submits, and appends "Asked the grid for a computer" to
`progress.log`, kept to its last 400 lines. The job's first act replaces the file: the `node` file,
then `status.json` with `node` and `got_computer_at`, keeping `submitted_at` when the queued file
names this job; a chain successor (named first in `next.id`) says `renewal: true` and takes its
`submitted_at` from `scontrol show job` (`SubmitTime`, read as local time). The job also writes
`started_at` (= `got_computer_at`), `ends_at` (`got_computer_at` plus the job's hours), `online_at`
(its first registration with a link) and `title`, and `stop_reason` (`request` or
`login_abandoned`) when it is `stopped`. `connection.json` gains `title` and `online_at`. Every
framework 9 field is kept.

**The session title** is the profile's `session_title` ("Wayne State grid"), or "Wayne State grid ·
NAME" for a worker not named `worker` ("Grid worker" when the profile names none); it is what Claude
Code is asked for with `--name` (it was `<site>-<run>`), `status.json` `title` and `requested_name`.

**`progress.log`** in the run folder: `<YYYY-MM-DDTHH:MM:SSZ> <sentence>`, one line per event, one
write each: "Asked the grid for a computer" (worker start), "Got a computer", "Connecting to Claude",
"Online: <link>", "Waiting for your Claude sign-in", "Reconnecting", "Renewing", "Ended", "Stopped",
"Stopped: waiting for your Claude sign-in timed out", "Couldn't start: <message>" (the job, or worker
status for a request the grid dropped). The job's output also gets `<H:MM> Online. Open in Claude:
<link>` (the node's local time) when it first registers.

**`worker status`.** While the worker is in line (status `queued`, or none yet, and no `node` file) it
asks the scheduler ONCE (`squeue -h -j <job> -o '%T|%r|%S|%N'`) and writes the answer into the queued
file: `scheduler_state`, `reason`, `expected_start` (only a time in the future, as UTC), `checked_at`,
and `got_computer_at` once Slurm says RUNNING. A job the scheduler no longer lists, with no `node`
file, becomes `error`, "the grid ended the request before it started". A scheduler that does not answer
changes nothing. Once the job has a computer, nothing is asked: its files say where it is. It writes
only while the file still says `queued` for that job and no `node` file exists, through a temporary
name of its own, so it never writes over the job. The first line, for a person:

| State | Line |
|---|---|
| queued | `Your worker is in line for a computer (6 min so far).` |
| starting, running, need_consent | `Your worker has a computer and is connecting to Claude.` |
| online (asked by a person) | `Your worker is online (ready 7 min after you asked).` |
| online otherwise | `Your worker is online.` |
| need_login | `Your worker is waiting for your Claude sign-in.` |
| preempted, a successor queued / none | `Your worker is renewing itself; it is back in a few minutes.` / `Your worker has ended. hpcworker connect starts it again.` |
| stopped (the sign-in abandon / otherwise) | `Your worker stopped: waiting for your Claude sign-in timed out.` / `Your worker is stopped.` |
| error | `Your worker couldn't start: <message>.` |
| no status yet | `Your worker has been asked for and has not reported yet.` |

When it is online, `Open in Claude: <link>  Look for Wayne State grid.` follows. `--details` adds
framework 9's lines (job, node, heartbeat, session, sign-in, chain) and the times. `--json` prints one
object on one line: `{"v":1,"run","job","next_job","state_dir","status","connection","scheduler","line"}`
(framework 9's `run`, `job`, `next_job`, `status` and `connection` as they were; `scheduler` is what the
one call learned, or `null` when it did not ask). `worker start --wait [MIN]` and `worker watch
[--minutes MIN]` read `status.json` and `progress.log` every 5 s (files only), print each new progress
line, ask the scheduler at most once a minute and only while the worker is in line, and end online
with the line above and the link (exit 0), stopped or failed (1), waiting for the sign-in (3) or out of
time (2; 30 minutes unless given).

`worker stop` of a worker still in line (its queued file, no `node` file) does not wait 45 s for a job
that cannot read the stop file: it asks the scheduler at once, cancels, and writes `stopped`
(`stop_reason` `request`) itself, unless the job reached a computer in the meantime, which then writes
its own stop. It says `worker NAME: stopped (it was still in line for a computer; cancelled at the
scheduler: <id>; the chain ended)`.

**The sign-in abandon.** A job still in `need_login` after the profile's `login_abandon_s` (1200 s)
stops itself: `stopped`, `stop_reason` `login_abandoned`, message "stopped: waiting for your Claude
sign-in timed out", its queued successor cancelled, `stop.done` touched, and it leaves. So a first run
abandoned on Anthropic's page does not hold a slot on the worker partition. The time counts from the
job's own start when it started signed out (Remote Control never started), and otherwise from the
moment it began waiting, so a sign-in lost hours into a job gets the full 20 minutes. `0` turns it off.
Two things keep it from stopping a student who is signing in: before it stops, the job asks Claude
Code once more whether it is signed in (a sign-in that landed since the once-a-minute check carries
on to online), and `connect` touches `signin.pending` in the worker's folder when its sitting starts
and when it ends, which moves the clock (a student still on Anthropic's page, or one who pressed
"Sign in again", gets the full time from there). A TERM that lands inside it hands back to it, as on
the stop path.

## The one-time key step: `hpcworker login-setup` (version 10; UNPROVEN ON THE GRID)

Designed from how Open OnDemand's Shell app runs ssh and tried against the mock portal and the unit
tests only. No student without a key has run it on the real grid; until one has, it is a design.

The portal's Shell app runs, as the student and on the OnDemand server, `ssh <host>` with nothing
else, so the ssh client reads the student's `~/.ssh/config` and, when no `IdentityFile` applies to
the host, tries its default key files. An account with a key there that authorises itself (the
maintainer's: an `id_rsa` made on the grid in 2022) gets in; a student who never made one is asked
for a password, which Beethoven never types. The student types the password into the grid's own
terminal page once; then Beethoven types (or the student pastes) one line there:

```
bash /rs/rs_grp_oschome/shared/beethoven/hpcworker/current/bin/hpcworker login-setup
```

It refuses outside a session that came in through ssh (`SSH_CONNECTION` with four fields and an IP
literal first), from this same computer, under an agent or without a terminal, as root, when the home
folder (or the folder a home that is a link names) can be written by others (sshd would ignore any key
in it), when `~/.ssh/config` or `~/.ssh/authorized_keys` is a link to another file (a dotfiles
repository, say: it is left alone), and when `~/.ssh/config` holds our start line without our end line
(nothing is guessed). Each of those refusals changes nothing; a later step that stops puts back what
the earlier ones did (the key it made, the config file, `~/.ssh`'s mode, or `~/.ssh` itself when it
made it). It notes, without refusing, when the terminal's address is not one the profile's portal name
resolves to (the portal's server may sit behind another name). Then: `~/.ssh` (made 0700 if
missing, put right if not private); the key `~/.ssh/beethoven_ed25519` and `.pub` (ed25519, no
passphrase, comment `beethoven-login-setup <user> <date>`, 0600 and 0644), made once and reused, and
never a file of that name it did not make; one managed block appended to `~/.ssh/config` (rewritten in
place on a later run, the file's mode kept but never group- or other-writable):

```
# >>> beethoven login-setup (managed; "hpcworker login-setup --remove" removes this block) >>>
Host warrior warrior.* <this node's short and full names>
    IdentityFile ~/.ssh/beethoven_ed25519
    IdentityFile ~/.ssh/id_rsa
    IdentityFile ~/.ssh/id_ecdsa
    IdentityFile ~/.ssh/id_ecdsa_sk
    IdentityFile ~/.ssh/id_ed25519
    IdentityFile ~/.ssh/id_ed25519_sk
    IdentityFile ~/.ssh/id_dsa
# <<< beethoven login-setup <<<
```

(an `IdentityFile` that applies stops the client from adding its default keys, so they are listed
after ours and every key the student already uses keeps working; `ssh -G` must read the new file and
name our key, for every plain name in the block, before it replaces the old one); and one line in
`~/.ssh/authorized_keys` (0600), found again on a later run by its exact form (our options, an
ed25519 key, our comment), so a line of the student's that merely mentions the tag is never taken
for ours:

```
from="<address>",no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 <key> beethoven-login-setup <user> <date>
```

`<address>` is the client address of the terminal it runs in: the OnDemand server. The key therefore
opens the account only from that address, never from elsewhere on the internet; a run from a new
address adds it (at most four, the newest kept). That limits where the key is used from, not who uses
it: the key is a file with no passphrase in the student's own account, readable by anything that runs
as the student, and anyone who obtained it and could open a connection from the OnDemand server (every
grid user's portal shell starts there) could use it. So the worker job hides it from Claude Code: an
empty file of the job's own is bound over `~/.ssh/beethoven_ed25519` inside the container
(`hpcw_hide_login_key`; tested here, not yet run under Apptainer on the grid), and the residual risk is
for the lab lead to put to C&IT with the password-each-time question. The student's other keys and
lines are never touched, read out or printed, and no key material is printed at all. The last line is
exactly one of `Done. The grid will not ask again.` (exit 0) or a `Stopped: ...` sentence (exit 2 to
7, with nothing changed: what an earlier step did is put back);
`login-setup --remove` takes the line, the block and the two key files away (`Done. Removed
Beethoven's grid key.` or `Nothing to remove.`). It is safe to run twice. If the OnDemand server's
address changes, the password prompt simply returns and the step appears once more. Nothing about the
key ever reaches the browser. Assumed and not seen: that the OnDemand server's ssh reads the same home
folder's `~/.ssh` (the Files app and the Shell land in the same home today), and that Wayne State's
Shell app runs plain `ssh` (an `OOD_SSH_WRAPPER` passing `-i` or `-F` would bypass the block). Where
the site's ssh does not offer the key for any reason, the step changes nothing that matters and the
password prompt stays.

## The ssh path: Beethoven's own sign-in, without the VPN (version 11)

Beethoven 12.0.0 first tries the grid's ssh port from the internet (`ssh_host`, `ssh_port`, pinned to
`ssh_host_key`), through a bridge on the student's computer, and falls back to the portal on the VPN
only when there is none. Its first sign-in is the student's own: the AccessID, the password and the
Google Authenticator code, typed into Beethoven's sign-in sheet and sent only inside that encrypted
session. Over that session it runs lines of this tool, each by the shared copy's full path, as 11.0.0
does through the portal. Beethoven 12.0.0 asks sshd for a pseudo-terminal (echo off) for the key line
and the Claude sign-in, as 11.0.0's portal terminal had one; both lines also work over a plain exec with
no terminal, which is what the end-to-end test runs:

```
bash '<shared>/bin/hpcworker' browser-key add <keytype> <base64>          the browser's key (next section)
bash '<shared>/bin/hpcworker' install --shared '<shared>' --profile <site>   the account set up for the lab's copy
exec bash '<shared>/bin/hpcworker' connect --name <name> --profile <site> [--consent <id>] --login auto ...
bash '<shared>/bin/hpcworker' claude login --plain [--profile <site>]     the Claude sign-in alone, when wanted
```

Every later connection signs in with the browser's key and runs only what the gate allows.

**`connect` and `claude login --plain` with or without a terminal.** With a terminal on standard input
(the portal's Shell, a person, Beethoven 12's pty) the Claude sign-in sitting runs as in version 10: echo
off on the login node and `srun --pty`. With none (a plain ssh exec) `srun` is asked for no pseudo-terminal at all
(`adapter_interactive` with `HPCW_ALLOC_PTY=0`; LSF's `bsub -I` in place of `-Is`, written from the
documentation and not run): the code then travels on a pipe from the session's standard input through
`srun` to the sitting's standard input, where no terminal can echo it, and the sitting itself
(`lib/login_plain.sh`) is unchanged: it reads the code with `read`, gives Claude Code its own terminal
with `script`, never copies Claude Code's screen to its output, and already runs with a standard input
that is not a terminal (its `stty -echo` is only for one that is). Measured against the fake scheduler
only (`tests/test_connect.py`, `PlainExec`): one `srun` without `--pty`, the code read from standard
input, never written back. Not run on the grid: `srun` without `--pty` relaying standard input to the
sitting on Wayne State's Slurm 23.02.

**`claude login --profile SITE`.** An account with no `profile.json` (one that never connected) is set
up for the lab's shared copy first, as connect's first step does (the shared install with all its
guards, without the `~/.bashrc` block), and the sitting then runs as for any account. `SITE` may be left
out when exactly one site profile of the copy names that copy as its shared copy. Under `--plain` the
setup says `HPCW-LOGIN: this account is set up for the lab's copy at <dir>` before the sitting's lines,
or one `HPCW-LOGIN-FAILED: <sentence>` (exit 1) when it cannot be done.

## The browser's key: `hpcworker browser-key` (version 11; UNPROVEN ON THE GRID)

Tried against a real OpenSSH server (StrictModes on, `restrict` honoured) under WSL and in the unit
tests, never on Wayne State's OpenSSH 7.4 with a student's account. Until a key has signed in to the
real grid, it is a design.

```
hpcworker browser-key add TYPE BASE64 [COMMENT | SHA256:CHECK]
hpcworker browser-key remove
hpcworker browser-key check
```

`add` writes exactly one line into `~/.ssh/authorized_keys`:

```
restrict,command="<shared copy>/bin/hpcworker gate" <ssh-ed25519|ecdsa-sha2-nistp256> <base64> beethoven-browser <YYYY-MM-DD UTC>
```

`<shared copy>` is the site profile's `shared_install` as it spells it (the lab's `current` link, never
the numbered directory behind it, so the key follows the lab's updates), and the command must run from
that copy; at a site with no shared copy the line names the copy that ran (an account's own
`~/.hpcworker`). `restrict` takes away a terminal, port, agent and X11 forwarding and `~/.ssh/rc`;
`command=` makes the gate the only thing the key can run. The key is the browser's public key (the
private half never leaves the browser): `ssh-ed25519` or `ecdsa-sha2-nistp256`, checked whole (its
prefix, its length, the decoded size, and `ssh-keygen -l`, which also refuses an EC point off the curve;
where `ssh-keygen` cannot read a key from a pipe at all, which is first asked of a known-good key, the
shell's checks are what there is). A `SHA256:` word is a check: a key whose fingerprint does not start
with it is refused. A comment is ignored (the line carries its own).

It changes nothing and prints one `HPCW-KEY refused <code> <sentence>` line (the sentence is for the
student) when: the words are not one whole key (`key`, exit 2); it runs under Claude Code or another
agent, inside a batch job, through the gate (`HPCW_GATE`, which the gate sets for every verb it hands on;
not `SSH_ORIGINAL_COMMAND`, which a site's own ForceCommand would set for the student's own sign-in too),
or with neither a terminal nor an ssh connection (`agent`, 2: Beethoven's own session has an ssh
connection, with or without a terminal; a person has a terminal);
as root (`root`, 2); the home folder is missing, a link, or writable by group or others (`home`, 3:
sshd's StrictModes would ignore every key there); `~/.ssh` is a link, someone else's, or writable by
group or others (`ssh-dir`, 4; made at 700 when missing, an acceptable mode of the student's left as it
is); `authorized_keys` is a link, not a plain file, someone else's, writable by group or others, holds
a NUL byte, or cannot be locked or written (`authorized-keys`, 7); another copy runs than the one the
site profile names, or the copy cannot be named safely, or **anyone but its owner can change the copy,
or rename anything in a folder above it** (`copy`, 8, naming the folder or file). Otherwise it removes
every line of its own form (an older key of this account's, the same key on another date), keeps every
other line byte for byte and in its place, writes through a temporary file at 600 in `~/.ssh` and one
rename, keeps the file it replaced as `authorized_keys.beethoven-prev` (600; a link of that name is
replaced, never followed) with every line of the student's own and none of Beethoven's (so putting it
back can never bring back a key that was replaced or forgotten), clears the worker names the gate's cap
counted (below: this is the student's own sign-in), runs
`restorecon` where SELinux labels homes, and prints `HPCW-KEY added SHA256:<fingerprint>` (exit 0; the
same line when the key was there already, with nothing rewritten). One account, one browser key: a new
computer's key replaces the last one. A line of the student's own that merely mentions
`beethoven-browser` is never taken for ours: ours is recognised only in exactly the form above.

**The copy the key runs.** Every key line names a command in the lab's copy, so whoever can change that
copy can run anything in every enrolled account the moment its key is used. `add` therefore refuses
unless the copy's own folders and files can be changed by their owner alone: the folder that holds the
`current` link (re-pointing the link re-points every key), the numbered directory, `bin/`, `lib/`,
`lib/adapters/`, `jobs/` and `profiles/` (a profile names the image and the `claude` a worker runs),
and each file in them, each owned by the copy's owner or root, none a link but `current`.
`tools/deploy_shared.sh` publishes the copy that way (group read and traverse, no write). **Every folder
from `/` down to the copy is judged as well, and one that others may write to is refused** unless it is
sticky (`chmod +t`: then only an entry's owner may rename or remove it). Whoever can rename a folder
above the copy can put another `current/bin/hpcworker` in its place, and every enrolled key's forced
command would run it in its own account at Beethoven's next poll, from anywhere on the internet; the
portal path of 11.0 has the same weakness, but only when the student types a command, and the key path
should not be opened on top of it. At Wayne State this README records the volume `/rs/rs_grp_oschome`
as `drwxrws---` (group-writable, not sticky) since 2026-09-29; if that is still so, `browser-key add`
refuses there until its owner (C&IT) sets the sticky bit or removes group write on it, and Greg does the
same for any folder of his between it and the copy (`shared`, `shared/beethoven`, `hpcworker`). Before
any student enrols, the lab lead runs `hpcworker browser-key check` (read only): one line per folder or
file that others may change, then `ok` or `refused`. Not measured on the grid: the modes of
`/rs/rs_grp_oschome`, `shared` and `shared/beethoven` today.

`remove` takes our line out (`HPCW-KEY removed`, or `HPCW-KEY none`), with the same guards; the gate's
`forget` does the same for the key itself, and neither leaves the line in `authorized_keys.beethoven-prev`.
`check` (read only, anyone) prints one line per folder or file that others than its owner may change,
`copy: ...` or `above the copy: ... (chmod +t or chmod go-w on it, by its owner)`, then `HPCW-KEY check
ok <copy>` (exit 0) or `HPCW-KEY check refused <copy>` (exit 8). Withdrawing a student's approval in the
access service does not remove the line: the gate never asks the access service. The student's Forget,
`browser-key remove`, or removing the line by hand does.

An expiry is the site's choice: `browser_key_days` in the site profile (none at Wayne State). Past it the
gate removes the line on the key's next use and answers `HPCW-KEY expired` (exit 125).

## The gate: what the browser's key may do (version 11)

`hpcworker gate` is the line's forced command. It reads `SSH_ORIGINAL_COMMAND`, the line the ssh client
sent, and accepts exactly this, as bash and nothing else (it runs no `python3`; the verbs it hands on to
are this tool's own):

| The client sends | The gate runs | Prints |
|---|---|---|
| `version` | itself | `HPCW-GATE ok <framework> <due\|never\|-> <account> claude=<yes\|no\|unknown>` (due: the expiry date; claude: the newest Claude Code answer any run recorded, from the files) |
| `status NAME` | `worker status --name NAME --json --poll-floor 60` | its one JSON line (section "Where a worker is") |
| `watch NAME` | `worker watch --name NAME --json --minutes 30 --poll-floor 60` | JSON lines (next section) |
| `connect NAME SITE ID\|- MODE chain\|no-chain` | `connect --name NAME --profile SITE --permission-mode MODE [--consent ID] [--no-chain] --login never` | the `HPCW-STEP` lines, never `signin` |
| `stop NAME` | `worker stop --name NAME` | `worker NAME: stopped (...)` |
| `restrict NAME` | `worker restrict --name NAME` | `worker NAME: marked restricted (...)` |
| `read NAME FILE` | itself; FILE `status.json`, `connection.json`, `progress.log` or `node` | the file's bytes (`progress.log`'s last 256 KB; the others at most 256 KB); exit 1 `HPCW-GATE missing`, 3 `not-plain` (a link, a folder) or `too-large`, on stderr |
| `forget` | itself | `HPCW-KEY forgotten` \| `none` \| `stuck` (7) |

Anything else is `HPCW-GATE refused`, exit 126, with nothing run: an empty or absent command (a shell
asked for), more than 200 bytes, any character outside `A-Z a-z 0-9 . _ -` and single spaces (so no
quote, newline, tab, `;`, `|`, `$`, glob or non-ASCII byte, judged byte by byte whatever locale the
client sent), a word longer than 64 or one that starts with `-` (only the lone `-` that means "no install
id" is a word of its own), a worker name outside `^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$`, a site outside
`^[a-z0-9][a-z0-9-]{0,31}$`, an install id that is not 32 hex characters, a mode other than `default`,
`acceptEdits` or `plan`, any other file to `read`, and any word given to `gate` itself. `--login never`
is written last on connect's line, so no earlier word could outrank it; and connect pins it again
itself whenever `HPCW_GATE` (which the gate sets) or, as a second wall, `SSH_ORIGINAL_COMMAND` is in its
environment, as do `claude login`, `claude consent` (the sitting), the sitting's own `_exec login` and
connect's sign-in step, which all refuse there (`HPCW-LOGIN-FAILED: the Claude sign-in never runs
through Beethoven's browser key`); `claude consent --record` refuses under `HPCW_GATE` (connect records
the answer itself). A site whose sshd forced a command for every session would therefore have the
Claude sign-in refused everywhere; no such site is known, and whether warrior's sshd sets a ForceCommand
is not measured.
The verb runs in a fresh bash started by `env` without `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`,
`CDPATH`, `GLOBIGNORE` or `PROMPT_COMMAND`, and a job a gate's connect submits gets none of the gate's
variables.

**The caps** (one small file per account, `<shared_state_dir>/.gate/caps`, 600 in a 700 folder, under a
lock): at most **3 worker names** through the key, each counting for **7 days after its last use** (a
name used once may be used again; `restrict` takes no name; and the student's own sign-in, which runs
`browser-key add`, clears them all, so a renamed worker is never locked out for longer than it takes to
sign in once), at most **12 actions in any hour** (every connect through the gate, whether or not it
submitted, and a `restrict` of a name that has no run), and at most **2 watches at once** (slot folders
`.gate/watch.1|2`, taken only for a run that exists and given back when the watch ends however it ends;
one older than 35 minutes is a leftover). Past a cap: `HPCW-GATE limit names|hourly|watch` (or `busy`
when the file cannot be locked or is not a plain file), exit 123, nothing run. And whoever asks, the scheduler hears about a worker in line
at most once a minute: the gate's `status` and `watch` pass `--poll-floor 60`, which skips the one
`squeue` when the queued file says it was asked less than 60 s ago, by any command.

**sshd and the account's own files.** sshd runs the forced command through the account's login shell
(`$SHELL -c '<copy>/bin/hpcworker gate'`). bash started by sshd reads `~/.bashrc` first on Debian's and
some other builds (whether warrior's does is not measured), so whatever the student's own `~/.bashrc`
prints comes before the gate's own lines: a reader takes the line that starts `HPCW-` (or, for `status`
and `watch`, the lines that start `{"v":1`) and ignores the rest. `read` prints a file's bytes after
whatever was printed before them, so a worker's state is read with `status`, and `read` is for
`progress.log` and the others as text. The key holder cannot change that file.

**What a copied key can and cannot do.** The browser keeps its key and does not let it be exported, so
this is for the case it is copied anyway. Until the line is removed (by `forget`, `browser-key remove`,
an expiry, or by hand), whoever holds the key can, from anywhere: learn the framework version, the
account name and whether Claude Code on the grid is signed in; read four run files of the account's
workers (states, times, job ids and nodes, the session link, and the e-mail and plan Claude Code
reports); set the account up for the lab's shared copy; start a worker under at most three names, at
most twelve times an hour, in the student's own Claude sign-in and usage limit; record the Remote
Control answer; stop a worker; mark a workspace restricted; and remove the key's own line. They cannot
open a shell or run any other command, get a terminal, forward a port or the agent, copy a file in or
out, read any other file (not `job.token`, `rc.log`, the workspace, `~/.ssh` or Claude Code's folder),
sign in to Claude or sign the worker in to another Claude account, add another key, or change the
profile; and a session link it reads opens only in the student's own Claude account. All of this holds
only while the lab's copy, and every folder above it, can be changed by its owner alone ("The copy the
key runs", above), which is why `browser-key add` refuses otherwise.

## `worker watch --json` (version 11)

`hpcworker worker watch --name NAME --json [--minutes MIN] [--poll-floor S]` writes one JSON line per
change and nothing else:

```
{"v":1,"event":"status","final":false,"run":"worker","job":"40501234","next_job":"","state_dir":"...","status":{...},"connection":null,"scheduler":{...},"line":"Your worker is in line for a computer (3 min so far)."}
{"v":1,"event":"keepalive","at":"2026-10-02T14:03:20Z"}
{"v":1,"event":"status","final":true,"run":"worker",...,"line":"Your worker is online."}
```

A status line (the fields of `worker status --json`, after `event` and `final`) comes at the start, each
time the worker's `state`, `needs`, `job`, `node`, `environment_url`, `message`, `scheduler_state`,
`reason`, `expected_start`, `next_job` or `stop_reason` changes (a heartbeat alone is no change), and at
the end with `final: true`. A keepalive line comes when 20 s pass with nothing written. `status.json` is
read every 5 s with bash builtins alone (no process is started for the look); the scheduler is asked at
most once a minute and only while the worker is in line (and, with `--poll-floor`, not within that many
seconds of anyone's last ask). It ends with `final: true` and exit 0 online with its link, 1 stopped,
error, or ended with no successor queued, 2 out of time (30 minutes unless given). `need_login` is a
change like any other and the watch goes on: through the gate nothing signs in, and a sign-in made
elsewhere brings the worker online. When the reader goes away (the ssh channel closed) the watch ends at
its next line, a change or the next keepalive, so within 20 s; a hang-up ends it at once; through the gate
its watch slot is given back either way, and a watch that never started (no such run, no profile) takes
none.
With no run folder it prints `hpcworker: no worker named NAME ...` on standard error, exit 1. Without
`--json`, `worker watch` is version 10's, for a person.

## Version 11 and what it keeps

Every verb, flag, file and line Beethoven 11.0.0 and 10.0.0 use is unchanged (docs/V11_CONTRACT.md):
`connect` with its `HPCW-STEP` grammar, exit statuses, keepalive, relay, budgets and `--pty` when there
is a terminal; `worker status --json` byte for byte (the same function prints it, with no prefix); `worker
stop`, `worker restrict`, `claude consent --record`, `install --shared`, `login-setup`, `claude login
--plain` with every line (a set-up account sees no new line; `--profile` and the setup line are new and
only for an account with no profile); the queued file and every `status.json` field; `progress.log`;
`VERSION` is 11. One thing a reader could notice and neither 11.0.0 nor 10.0.0 reads: `~/.hpcworker`
gains `profile.env` (the profile as shell variables, 600), made again from the profile whenever it does
not match, so deleting it is harmless. The job file and the workspace guide are now filled by bash
(`lib/profile_sh.sh`) instead of `profile.py`, with the same bytes for every profile the tests hold
(`tests/test_profile_awk.py`); `hpcworker profile show|set|validate|schema` still use `profile.py`, and
`hpcworker profile check [FILE]` gives `validate`'s verdict with no python3.

## Version 10 and what it keeps

The 10.0.0 extension and a worker started by framework 9 keep working when the lab's copy moves to
version 10. Every verb, flag, file and output line 10.0.0 uses is unchanged: `install --shared`,
`discover`, `probe`, `worker start` (with "worker N submitted as job ID" and "worker N already has job
ID (STATE); nothing submitted", one squeue; a scheduler that does not answer is never read as "no job
alive": nothing is submitted then, and two starts at once wait for one lock, so a worker is never
submitted beside one still in line), `worker stop` ("worker
N: stopped (...)"), `claude login --plain` (every line, the 15-minute "already signed in" shortcut, no
keepalive), every framework 9 field of `status.json` and `connection.json`, `next.id`, the consent
marker of any content and the stop file 10.0.0 writes through Files. A framework 9 `status.json`,
without the new fields, is read by `worker status` as it is ("Your worker is online."), with no
scheduler call. 10.0.0 does not know `queued`: it treats such a run as not live, and its automatic
start asks `worker start` at most once a minute, which answers "already has job ID (PENDING); nothing
submitted"; its panel says "Starting your worker..." meanwhile. 10.0.0 never restarts a `stopped`
worker, so the sign-in abandon cannot loop under it. Values that change and that 10.0.0 only shows:
`requested_name` is now the title, the starting `hint` no longer says "about a minute", the resume
window is four hours, `VERSION` is 10.

## The site profile's keys for the extension (version 10)

`ood_base_url` (the portal the welcome page offers), `ood_auth` (`http-basic` at Wayne State: a hint
for Details; the extension tests the channel itself), `vpn_portal` (`protect.wayne.edu`), `vpn_app`
(`GlobalProtect`), `vpn_help_url` and `grid_account_help_url` (https addresses; the latter, Wayne
State's KB 20199 in TeamDynamix's standard form, was not fetched), `session_title` (`Wayne State
grid`), `login_abandon_s` (1200; 0 or at least 300), `restricted` and `restricted_workspaces`. Each is
optional and checked by `profile validate`. An account's `profile.json` copied before version 10 takes
these from the site profile of the same name in the copy it runs from (`FIELDS_FROM_SITE`), until the
account sets its own. The worker partition is not changed (the lab lead's choice).

Version 11 adds, each optional, checked by `validate` and taken from the site profile the same way:
`ssh_host` (`grid.wayne.edu`: the login node's public ssh name; empty means no ssh path), `ssh_port`
(22), `ssh_host_key` (`SHA256:kLTz1xK6anQ1denM+31kDEryQtgan2P76r9aLno+K3s`, the fingerprint the grid's
`ssh-rsa` host key had from the internet on 2026-10-02; Beethoven refuses any other), `ssh_relay`
(`null`: no relay; a `wss://` or `https://` address otherwise), `grid_2fa_help_url` (KB 20242, the
university's page on the grid's Google Authenticator code, which a password sign-in asks for), and
`browser_key_days` (days a browser key stays valid, or `null`/absent for no expiry; Wayne State sets
none). `vpn_portal`, `vpn_help_url` (KB 20314) and `grid_account_help_url` (KB 20199) are kept as they
were.

What you should know before step 4, and the command tells you: files the worker reads and every
command's output go to Anthropic; while you are connected the transcript is also stored on
Anthropic's servers (30 days on a personal plan, five years if model training is on); no BAA covers
a personal plan, so patient data, FERPA records, IRB data and export-controlled material stay out of
the worker's directory; Remote Control draws from your plan's shared usage limit.

## What the framework enforces (cluster etiquette)

- Nothing runs on the login node beyond one scheduler command per action (and connect's sign-in
  sitting, `srun` relayed by bash), and nothing on its banned list for longer than a moment (see "The
  login node" below). Every subcommand that would run a container or Claude Code refuses to do so
  outside a job and says why. `discover` stays
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
  named `hpcworker_<id>`, `hpcw_<id>` or `hpcw_probe_<id>`. Version 10 adds two exceptions, each for
  a file of the tool's own: `connect` removes its outcome file under `~/.hpcworker/log`, and
  `login-setup --remove` (or a `login-setup` that stops after making its key) removes the key pair
  whose public half says `login-setup` made it, with its own config block and authorized_keys line.
  `login-setup` and, from version 11, `browser-key add|remove` and the gate's `forget` and expiry are
  the only subcommands that write under `~/.ssh`, each only its own line (and `login-setup` its own key
  and config block); `login-setup` refuses to run under an agent or without a terminal, `browser-key`
  under an agent, in a job, through the gate, or with neither a terminal nor an ssh connection. The gate
  writes its own `.gate` folder under the state directory and nothing else. The one subcommand that replaces a file
  of yours, `install --force` (profile.json), refuses to run under an agent (`CLAUDECODE`,
  `BEETHOVEN_REQUEST_ID` and kin, and their older `ASHLEY_` names) or without a terminal. No subcommand
  can remove `~/.beethoven` (or `~/.ashley`, its old name), the profile, or a Claude Code configuration
  directory.

## The login node: what runs there, and the banned list

warrior's banner (`/etc/motd`) reads: "The following programs are banned from running on warrior and
will be terminated on sight: bedtools, conda, CONVERGE_Studio, fastq-dump, gcc, gfortran g++, icc,
ifort, lsdyna, make, md5sum, namd2, namd3, node, pip, python, python2, python3, python-notebook, R,
rsync, zellij". What each line the extension types runs there (measured against the fake scheduler
under WSL by `tests/test_login_node.py`, which puts a stand-in for every banned name first on PATH and
fails if one is looked for; every program not named below is coreutils, `grep`, `sed` or `awk`,
running for milliseconds):

| line | python3 | longer than a moment |
|---|---|---|
| `install --shared` | none | nothing |
| `claude consent --record` | none | nothing |
| `connect` | none | the sitting: `srun` (up to 600 s for a computer, 840 s in all), the relay (bash builtins) and its ticker (bash, `sleep 1` a second) |
| `worker status --json` | none | nothing (one `squeue` under `timeout 20`, only while in line; with `--poll-floor 60`, not within a minute of the last) |
| `worker stop` | none | for a running worker, bash waits up to 45 s for its `stop.done` (`sleep 5` between looks); one `squeue`, one `scancel` |
| `worker restrict` | none | nothing |
| `login-setup` | none | nothing (`ssh-keygen`, `ssh -G`, `getent` under `timeout 5`, `restorecon` where present) |
| `discover`, `probe`, `diag` | none | nothing (one `sinfo` under `timeout 10`; one `squeue` for a probe on record, one `sbatch`) |
| `browser-key add` (version 11) | none | nothing (`sha256sum`, `base64`, two `ssh-keygen -l`, one `stat` over the copy's files, `restorecon` where present) |
| gate `version`, `read`, `forget` | none | nothing |
| gate `status`, `stop`, `restrict` | none | as `worker status`, `stop`, `restrict` |
| gate `watch` | none | up to 30 minutes, bash alone: a look at `status.json` every 5 s with builtins and a `sleep`, one `squeue` a minute at most while in line, a keepalive line every 20 s; it ends within 20 s when its reader goes |
| gate `connect` | none | nothing (never an `srun`) |

Measured by `tests/test_login_node.py` under WSL (2026-10-02, fixer run): every line in the table above,
the first connect of a never-set-up account, the gate's eight verbs, `browser-key add`, and the first
command after `profile.json` changed, started no `python3` at all, and looked up no program on the
banned list. Reading Wayne State's site profile with awk took 25 to 35 ms more than sourcing the tool
(about 55 ms), and loading it, filling the job file and the workspace guide 130 to 210 ms in all, with
gawk 5.2 and with mawk 1.3.4 (`profile.py shellenv` alone took 110 ms on the same machine). Not measured
on warrior (gawk 4.0.2, bash 4.2.46, CephFS).

**How (version 11).** `lib/profile.awk` reads the profile as JSON (every escape, `\u` and surrogate
pairs, refusing anything that is not JSON), merges it as `profile.py load()` does (the schema's
defaults, then the site profile's values for `FIELDS_FROM_SITE`, then the account's own file), checks it
as `profile.py validate()` does, and prints three things for bash to `eval`, every value shell-quoted by
`shlex.quote`'s rule and every name `[A-Za-z0-9_]`: the `P_<key>=<value>` lines `profile.py shellenv`
printed, the verdict (`HPCW_PV_errors`, `HPCW_PV_note`), and for a valid profile the values the job file
and the guide are filled from (`HPCW_M_*`, `HPCW_G_*`). `lib/profile_sh.sh` fills `jobs/worker.sbatch.tpl`
(`hpcw_render`) and `jobs/workspace-guide.md.tpl` (`hpcw_guide`) from them as `profile.py render` and
`guide` did: the same values, the same refusals (a quote or a line break in a value, a run name out of
pattern, `CHAIN` not 0 or 1, an invalid profile), each placeholder replaced once, and the values handed to
awk in an environment of their own (`env -i`), so nothing in the caller's environment can fill one.
`tests/test_profile_awk.py` holds the two implementations together: the awk schema is compared with
`profile.py`'s `SCHEMA` line by line, and for Wayne State's profile and profiles bent to reach every
branch (escapes and non-ASCII text, an older account's file, other schedulers, a proxy, binds, every
rule `validate` names) the P_ lines, the verdict and its words, the job file and the guide are compared
byte for byte. The awk output is kept in `~/.hpcworker/profile.env` (600) under a SHA-256 of what it
depends on (the account's `profile.json`, the site profile, `profile.awk` and `profile_sh.sh`, `$HOME`,
`$USER` and the copy's directory; `sha256sum`, not on the banned list; `md5sum` is), and read back while
that is unchanged. The job file is filled afresh at every start (framework 11's earlier `job.key` is gone:
there is no python3 left to save, and a file reused from a folder others might change was the one thing
it added to trust). Known differences from `profile.py`, all on profiles no site has: a `\u0000`,
`NaN` and `Infinity` are refused rather than read, a value with a trailing line break in a key `validate`
matches by pattern is refused rather than accepted, and a value nested three objects deep (which no
variable the tool reads holds) prints as python's repr only for plain values.

Taken off python3 in version 10: the relay (it was `python3` for the whole sitting, which the
banner's "terminated on sight" would have ended mid-sign-in), the `status.json` patch that `worker
status` makes on each poll while a worker is in line and that `worker stop` makes for a worker still
in line (awk, refusing any file that is not the flat queued file it patches), and the six plain
top-level profile reads on the way to a worker (`site`, `shared_install`, `shared_state_dir`,
`submit_host`, `ood_shell_host`, `ood_base_url`: the short awk reader, and `lib/profile.awk` for a value
with an escape in it). Taken off in version 11: `shellenv`, `render`, `guide` and `validate`, as above.

Still `python3`, never on a line the extension types: `profile show|set|validate|schema` and `install
--discover` (a person at a terminal), the maintainer's `tools/deploy_shared.sh` (one `validate` per site
profile when it publishes; `hpcworker profile check FILE` gives the same verdict without it), the
probe's and the worker's own reads on the compute node (`hpcw_workspace_trusted`), and, at a PBS site
only, the `qstat` JSON parse in `lib/adapters/pbs.sh`. `diag` reports whether `python3` is there and
no longer runs it.

## Always on

`worker start` renders `job.sbatch` and submits it. When the job has confirmed the container and the
sign-in status, it submits the same file again with a dependency on itself (`afterany`, never
`afterok`, plus `singleton` so two links never run at once) and records the successor in `next.id`:
one successor per link, once, also across a Slurm requeue of the same job. When the wall time or a
preemption ends a link, the scheduler starts the successor, which runs `claude remote-control
--continue` in the same directory when `connection.json` is younger than four hours (version 10;
Anthropic says a session can be resumed "for about four hours"; it was seven days) (tried once per
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

## The workspace guide (version 8)

Claude Code reads a `CLAUDE.md` in the folder it works in at the start of every session. `worker
start` writes one into the worker's workspace (`<shared_state_dir>/workspaces/<name>/CLAUDE.md`)
from `jobs/workspace-guide.md.tpl`, filled from the site profile (`hpcw_guide` in `lib/profile_sh.sh`, as `lib/profile.py guide` did): what the
machine is (a compute node under the site's scheduler, the worker started by hpcworker), how to run
work (light work in the worker, heavy or long work as its own job, never on the login node, the
partitions and QoS, the account, node-local `/tmp`, sockets under `ipc_dir`), which folders the
container sees and what each is (told apart from the profile's own facts: the home, the folder that
holds `shared_state_dir`, the lab's shared folder), how results go back (a path; a file sent in the
session when Claude Code has a tool for it; Google Drive, Docs or Sheets only through a connector the
person turned on themselves), and what never goes in (PHI, FERPA records, IRB data without approval,
export-controlled material, credentials). Under 60 lines, plain ASCII.

It is written only when the workspace has no `CLAUDE.md`, so a workspace made before version 8 gets
one at its next start, and a file already there is never replaced: edit it freely, or leave it empty
to go without one. The write refuses an existing name (bash's noclobber), so two starts at the same
moment cannot write over each other. `hpcworker worker guide [--name N]` prints the current text and
writes nothing; to take a newer text, move yours aside and start the worker again.

Whether the container can reach the scheduler follows the site profile's `scheduler_in_worker`
(version 9, next section). With it, the guide says the Slurm commands are there; without it, the
guide tells Claude Code to check `command -v sbatch` first and, when it is missing, to write the job
script into the workspace for the person to submit from a terminal.

## Slurm inside the worker (version 9)

With `scheduler_in_worker: true` in the site profile (Wayne State sets it; the default is false, so
every other site is unchanged), the worker job binds the host's own Slurm client into the container,
and Claude Code there can submit and watch jobs itself (`sbatch`, `squeue`, `sacct`, `scancel`,
`sinfo`; not `scontrol`, whose host binary needs `libreadline.so.6`, which the Debian bookworm image
does not have). The binds are the set measured on asx1 on 2026-09-28 for the lab's VS Code tool,
whose worker has carried them since: `/usr/bin` under `/opt/host/bin` (never all of the host's
`/usr/bin` on the container's PATH), `/usr/lib64/slurm`, the munge library into `/usr/lib` (a default
search folder, so no `LD_LIBRARY_PATH`), `/etc/slurm`, the munge socket's folder `/var/run/munge`,
and an `/etc/passwd` and `/etc/group` that are the container's own plus the host's entries for the
user `slurm.conf` names as `SlurmUser`, `munge` and the person (without the slurm user the client
stops at "Invalid user for SlurmUser slurm"). All read-only except the socket.
`lib/adapters/common.sh` `hpcw_slurm_in_container` makes them on the compute node at the start of
each job, under the job's `/dev/shm` directory (node-local, not swept like `/tmp`, removed with the
job); the job adds them to every container start and puts the wrappers' folder,
`/opt/hpcw/slurm/bin`, first on the container's PATH (`APPTAINERENV_PREPEND_PATH`).

The wrappers run each host command with the host's PATH and `LD_LIBRARY_PATH` and the `TMPDIR` the
job was given, and without the container's `APPTAINER_` and `SINGULARITY_` variables, the worker's
`XDG_RUNTIME_DIR` or the worker job's own `SLURM_` variables (`SLURM_CONF` is kept). A job submitted
from inside therefore starts much as if submitted from a terminal: on the host, not in the
container, with the person's module libraries (without the wrapper's `LD_LIBRARY_PATH` it would get
the container's, `/.singularity.d/libs`, as the check job showed), and not steered by the worker's
`SLURM_CPUS_PER_TASK` or `SLURM_MEM_PER_NODE`, which a new job would otherwise inherit and its `srun`
would read. Such a job keeps running when the worker's job ends. The rest of Claude Code's
environment goes along unchanged, the worker's own variables included (`HPCW_JOB`, `HPCW_NODE_TMP`,
`HPCW_BINDS`, `CLAUDE_CONFIG_DIR`): only hpcworker's own helpers read the `HPCW_` ones, and only
Claude Code reads `CLAUDE_CONFIG_DIR`. The agent markers Claude Code sets (`CLAUDECODE`) stay too, so
the tool's destructive subcommands still refuse inside such a job. Inside the container a host
library folder the container cannot see is simply absent, so the client loads what the host's own
copy loads, or the container's newer system library.

When a piece is missing on the node, the worker starts without it: the job log names the piece,
`status.json` carries `"scheduler_in_worker": false` and a `scheduler_note`, `hpcworker worker
status` prints the note, and `hpcworker diag` reports `hpcw.slurm-in-worker` from the newest
heartbeat. Only Slurm with Apptainer or Singularity is built; `validate` refuses the flag for another
scheduler or runtime.

An account's `profile.json` is a copy of the site profile, made at install and kept since, so one
installed before version 9 does not carry the field. Such a field (`FIELDS_FROM_SITE` in
`lib/profile.py`; this is its only member) takes the value in the site profile of the same name in
the copy the command runs from, until the account sets its own: `hpcworker profile set
scheduler_in_worker false` turns it off for one account, and `profile set` of any other field writes
neither the site's value nor the default into the account's file, so a later publish still reaches it.

The workspace guide follows the flag. With it, the running-work lines say the Slurm commands are
here (and in `/opt/hpcw/slurm/bin`), that a submitted job runs outside the container and outlives the
worker, what to do when `command -v sbatch` finds nothing, to cancel only its own jobs and by id
(never `scancel -u`, never the worker's own job, `$HPCW_JOB`), and the lab's rule for containers in
jobs (`APPTAINER_TMPDIR` and `APPTAINER_CACHEDIR` on the node's local disk); "Handing results back"
gains one line: a submitted job writes its output and results under the workspace, is followed with
`squeue -j` or `sacct -j` at most once a minute, and what came out, and where, goes back to the
person. Without the flag the text is version 8's. A workspace that already has a `CLAUDE.md` keeps
it (the guide is never replaced); version 8's text there already says to check `command -v sbatch`
first, which now finds the command. `hpcworker worker guide` prints the new text.

Measured and not: the check job (`tests/grid/slurm_in_container.sbatch`, job 40518457; "What was run
on the Wayne State grid") ran the binds and wrappers from inside the container. Two changes came
after it and have not been run on the grid: `scontrol` dropped, and the host's `LD_LIBRARY_PATH` in
the wrappers. A worker's Claude Code submitting a real job from a Remote Control session has not been
run, nor a SIF image (the user lists are then read with one `cat` inside the image instead of from
the image folder).

## Files

```
bin/hpcworker            the command (bash)
lib/profile.py           site profile schema, validation, template rendering, the two-key consent reader (python3, stdlib, 3.6+): the reference, and the tool for a person at a terminal
lib/profile.awk          version 11: the site profile read, merged and checked with no python3, for bash to eval (POSIX awk)
lib/profile_sh.sh        version 11: the job file and the workspace guide filled from it (bash), as profile.py render and guide did
lib/login_plain.sh       the panel's sign-in sitting (claude auth login under a pty, a line contract on stdout)
lib/relay.sh             connect's one writer to the terminal during the sitting: whole lines and the keepalive (bash builtins only), and its once-a-second ticker (--ticks)
lib/browser_key.sh       version 11: browser-key add|remove|check and the gate, with its caps (bash, coreutils, grep, sed, awk)
lib/adapters/common.sh   scheduler and runtime detection, node-local temp, the container exec line, the registration parser, needs/hint, the guarded remove
lib/adapters/slurm.sh    Slurm (run for real on the Wayne State grid)
lib/adapters/pbs.sh      PBS Pro / OpenPBS (documented commands; fixture-tested only)
lib/adapters/lsf.sh      IBM Spectrum LSF (documented commands; fixture-tested only)
profiles/wayne.json      Wayne State University
jobs/probe.sbatch        the ten-minute probe (five minutes of budgets inside the container) -> <state_dir>/probe/probe.json
jobs/worker.sbatch.tpl   the worker job, rendered per start from the profile
jobs/workspace-guide.md.tpl  the CLAUDE.md a new worker workspace gets, filled from the profile (see below)
jobs/build_image.sbatch  a SIF with Claude Code pinned, for sites without an image (not run at Wayne State)
tests/run.sh             bash -n for every script, then the unittest suite
tests/grid/slurm_in_container.sbatch  the maintainer's grid check for scheduler_in_worker (one 5-minute job; not published)
../tools/deploy_shared.sh  publishes bin/ lib/ jobs/ profiles/ VERSION README.md as the lab's shared copy
```

`~/.hpcworker` on a shared copy: `bin/hpcworker` (the launcher), `shared` (the marker), `profile.json`,
`log/`, `profile.env` (version 11: the profile as shell variables, made again whenever it does not
match), and when there is one, `consent`, `discover.json` and `replaced/<time>/` (a copy of the
account's own, or a marker, moved aside by an install). On a copy of its own: the files above under
`bin/`, `lib/`, `jobs/`, `profiles/`, plus `VERSION`, `README.md`, `profile.json` and `log/`. A worker
job carries both: `HPCW_HOME` (the account's folder: profile, consent marker) and `HPCW_CODE` (where
`lib/` is: the shared copy's numbered directory, or `~/.hpcworker`); so does the probe's `probe.env`.
Site profiles and job templates are also where a later workflow engine's cluster templates would go
(one file per site, one template per kind of job); nothing of that is built.

The state directory also holds `.gate/` (version 11: the gate's `caps` file, its lock and its watch
slots; 700) and `workspaces/`. Run directory (`<shared_state_dir>/<name>/`): `job.sbatch`, `job.id`, `next.id` (successor id and
the id that queued it), `chain.log`, `node`, `progress.log` (version 10), `status.json` (state `queued`
(version 10), `starting`, `need_login`,
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
   header block in `profile.py:header_lines` and the same in `hpcw_render` (`lib/profile_sh.sh`;
   `tests/test_profile_awk.py` holds them together), and fixtures under `tests/fixtures/`.

## What is Wayne-State-specific

Only `profiles/wayne.json`: partitions `secp/secondary` (starts at once) and `reqp/requeue`, GPU
partitions `gmsap` and `gvohp`, `module load apptainer/1.2.2` at `/wsu/el7/gnu7/apptainer/1.2.2/bin`,
the shared sandbox image and `claude` under `/rs/rs_grp_oschome/shared/beethoven`, the lab's shared
copy of this framework (`shared_install`, `/rs/rs_grp_oschome/shared/beethoven/hpcworker/current`, which
every account must be in the group `oschome` to read, like everything else on that volume), the CephFS state
directory `/rs/rs_grp_oschome/$USER/hpcworker`, node temp at `/tmp/$USER/hpcworker_$SLURM_JOB_ID`
(never `$TMPDIR`), `claude_config_dir` `$HOME/.beethoven/claude` (the sign-in Beethoven for VS Code
already made; the framework starts Claude Code there, reads `claude auth status` and the two consent
booleans), that tool's consent markers (`.beethoven-remote-consent`, and `.ashley-remote-consent`, its
name before the rename) honoured beside hpcworker's own, the portal
`https://ondemand.grid.wayne.edu` behind the VPN, the 20-process login-node cap, and the Panasas home
(new images at this site should be SIF).

`scheduler_in_worker` is on: the host's Slurm client is bound into the worker's container (the set
measured on asx1 for the lab's VS Code tool; see "Slurm inside the worker").

## Tests

```
bash framework/tests/run.sh                      # under WSL or Linux (or in a job on a compute node)
HPCW_PYTHON=python bash framework/tests/run.sh   # on a Windows checkout (the Store's python3 alias is a stub)
```

Never on warrior's login node: the suite is `python3` for minutes, and the banner bans `python3` there
(versions up to 9 ran it on the login node, when it took a second).

Version 10's tests run against a scratch account and a fake scheduler on PATH (`tests/fakegrid.py`:
sbatch, squeue, scancel and scontrol keeping their jobs in a file, and an srun that plays the sign-in
sitting): `test_connect.py` (each HPCW-STEP order, the login modes, a job already in line, every
failure code, the keepalive, the relay and its ticker with an empty PATH, and a cut shell: connect as
the session leader of a pseudo-terminal that hangs up mid-sitting, after which nothing of the sitting
is left running), `test_login_node.py` (every
line the extension types with each banned program a failing stand-in on PATH and each `python3` call
named and timed, none expected since version 11; the awk `status.json` patch and profile reads against
`profile.py`'s answers),
`test_status.py` (the queued file, `worker status` and its
one scheduler call, every person-facing line, stop of a worker in line, restrict, consent --record,
watch, and what 10.0.0 and a framework 9 worker still find), `test_job.py` (the rendered job run whole
against a stand-in runtime and Claude Code: online then stopped, a renewal, the sign-in abandon; Linux
only) and `test_login_setup.py` (in a scratch HOME; Linux only, it needs POSIX file modes). On a
Windows checkout the Linux-only ones are skipped; run the suite under WSL for all of them.

Version 11 adds `test_browser_key.py` (Linux only: POSIX modes, a pseudo-terminal, `ssh-keygen`; the
lab's layout with a `current` link, a stand-in for every banned program first on PATH: `browser-key
add` from Beethoven's session and from a terminal, every form of the key, the fingerprint check, every
other line kept, the same key again, a second key replacing the first, umask 000; 33 hostile keys; each
refusal (an agent, a job, the gate, a pipeline, home, `~/.ssh`, `authorized_keys`, the lock); every
part of the copy writable by group or by others, a link inside it, a folder above it (refused unless
sticky), another copy run; `remove` and `check`; `authorized_keys.beethoven-prev` never keeping a line of
ours; then the gate through a stand-in for
`bin/hpcworker` that prints the words it was handed: every accepted line and its exact argv, `--login
never` last, 84 hostile lines under three locales, a hostile environment, `version`, the expiry,
`read`, `forget`, the three caps (a name ageing out after seven days, the student's own sign-in
clearing them, a restrict of no run taking no name) and the watch slots (none for a run that does not
exist); and the real verbs against the fake scheduler with no python3 on PATH),
`test_profile_awk.py` (`lib/profile.awk` and `lib/profile_sh.sh` against `profile.py`, byte for byte, as
"The login node" says), `test_watch_json.py` (each line of `worker watch --json`, the keepalive, a
heartbeat that is no change, the ends and their exit statuses, the poll floor, a reader that goes and a
hang-up giving back the slot), `PlainExec` in `test_connect.py` (connect and `claude login --plain`
with no terminal: no `--pty`, the code from standard input and never written back; the setup of an
account never set up; no sign-in under the gate), the gate's verbs and `browser-key add` in the
login-node audit, and the new profile keys in `test_profile.py`.

Under bash 4.2 (EL7's, the version warrior runs): put a bash 4.2.46 built from source first on PATH and
run the suite the same way; `tests/run.sh` hands that bash to every test.

`tests/e2e_sshd.sh` (not part of `run.sh`; Linux, an OpenSSH `sshd` this account can run,
`HPCW_E2E_SSHD`) runs the whole key path against a real sshd on 127.0.0.1 with StrictModes on and the
grid's algorithms: an unrestricted stand-in for the student's password session adds the browser's key
over a plain exec; the key signs in and sshd runs only the gate (`forced-command (key-option)` in its
log, `key options: command` and nothing else for our line); 25 hostile lines, no command, sftp, a
terminal and stdio forwarding refused; connect with the Claude sign-in over the session, the code on
standard input, `srun` without `--pty`; the gate's status, read, connect (no `srun`), the names cap,
watch to the end and a watch whose channel closed giving back its slot; a second computer's key
replacing the first; `forget`. It never touches the account's own `~/.ssh` or `~/.hpcworker` (their
checksums are compared before and after) and uses none of its keys or config. `HPCW_E2E_BASH` runs the
copy under another bash.

## What was run on the Wayne State grid

2026-10-02 (version 11): nothing. No framework code ran on the grid for this version, and version 11
was not published (the extension's build made three connections to the grid's ssh port, which ended
at its banner or its answer to the unauthenticated "none" request; none signed in). The build's record
of the same day says framework 10 is the published `current` (`/rs/rs_grp_oschome/shared/beethoven/
hpcworker/current`); this README did not record that publish. Not measured there, and each needed
before a student relies on it: `lib/profile.awk` under warrior's gawk 4.0.2 (gawk 5 and mawk 1.3.4
were tested); a key line of
this form accepted by the grid's OpenSSH 7.4 with StrictModes and its home folders (and whether `$HOME`
there is a link, which `browser-key add` refuses); `ecdsa-sha2-nistp256` and `ssh-ed25519` user keys
accepted by 7.4; `restrict` and the forced command on 7.4 (local tests used 9.6); whether warrior's bash
reads `~/.bashrc` for a forced command (Ubuntu's does); `ssh-keygen -l -f /dev/stdin` on 7.4 (where it
cannot read a key from a pipe, the shell's own checks stand); the modes of `/rs/rs_grp_oschome` and of
`shared`, `shared/beethoven` and the published copy (`hpcworker browser-key check` says them in one
command); `srun` without `--pty` relaying standard input to the sitting; and whether the grid's sshd
accepts `SSH_ORIGINAL_COMMAND` exactly as sent.

2026-10-01 (version 10): nothing. No version 10 code has run on the grid or against the portal, and
the shared copy was not published (`tools/deploy_shared.sh` was not run). Not measured there: `connect`
end to end; `srun --pty` with its output piped to the relay, and the echo of a pasted code under it;
Open OnDemand's idle limit against the keepalive; `squeue -j` with `%r|%S` and `scontrol`'s SubmitTime
on Wayne State's Slurm; a worker writing the queued file's successor fields, `ends_at` and
`progress.log` on a compute node; the sign-in abandon on `reqp`; and `login-setup` for a student
without a key (the key step is unproven until such a student has run it).

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

2026-09-28/29 (the maintainer's own run, the phone host of the lab's VS Code tool, job 40496445 on
asx15): Remote Control registered from an `sbatch` job under a pseudo-terminal with the consent
already on record, and printed the block shown above. Open question 1 is answered yes.

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

2026-09-29 (version 5, the lab's shared copy; user go2432): `tools/deploy_shared.sh` from a Windows
checkout over `ssh wsu-grid` published `/rs/rs_grp_oschome/shared/ashley/hpcworker/v5` (13 files)
and `current -> v5`; run again it said `v5 is already published with these files` and changed
nothing. The new tree inherited the volume's group-writable default ACL; after the script the
directories read `group::r-x`, `mask::r-x`, the files `r--` (`r-x` for `bin/hpcworker` and the
`.sbatch` files), `other::---` throughout, nothing group-writable, `v5` read-only for its owner too.
(The first run set the entries with setfacl's `rX`, which marked every file executable for the group
because the inherited group entry still carried an execute bit; the script now sets them per kind of
file.) Then the maintainer's account, with the command a student's install runs:
`bash .../current/bin/hpcworker install --shared .../current --profile wayne` said `switched to the
shared copy of hpcworker 5 ...; your own copy (version 4) was moved to
~/.hpcworker/replaced/20260929-173150 (nothing deleted)`; `profile.json` kept byte for byte (same
md5), one `~/.bashrc` block. Over ssh, `bash -lc 'hpcworker version'` says `5 (shared copy at
/rs/rs_grp_oschome/shared/ashley/hpcworker/current)`, `hpcworker worker status --name worker` reads
the stopped worker's state as before, the command resolves its code to
`/rs/rs_grp_oschome/shared/ashley/hpcworker/v5` (not the volume's physical path), and a worker job
rendered to stdout (not submitted) carries that directory as `HPCW_CODE` and `~/.hpcworker` as
`HPCW_HOME`. v5 was then published once more with `--replace` for two small changes to `bin/hpcworker`:
`same_dir` now also requires both directories to exist, and the note an install of an account's own
copy prints about the site's shared copy now appears only when the account can open that copy. The
first copy is kept beside it as `v5.replaced-<time>`, which no job names, since no worker started
between the two.
No job was submitted or cancelled and nothing of ours is under warrior's `/tmp`. The 120
unit tests pass on a Windows checkout (eight skipped: the six pty scenarios, the `current` link and
the unreadable directory, which need Linux) and under WSL (none skipped). Not measured: a worker or
probe job running from the shared copy (the next `worker start` is the first), what an account
outside `oschome` sees (no such account was at hand), and whether the portal's Files app reads
through the `current` link.

2026-09-30 (version 7, the rename; user go2432): with no `ashley_`, `beethoven_` or `hpcw_` job queued
or running and the account's worker and probe finished, `/rs/rs_grp_oschome/shared/ashley` was moved
to `shared/beethoven` and a relative link `ashley -> beethoven` left in its place (one `mv -T`, one
`ln -s`, on the login node); the lab's `library.json` and the account's `config.env` and `READY` name
the new folder, and copies of every rewritten file are kept in the account. `tools/deploy_shared.sh`
over `ssh wsu-grid` (from WSL) derived its root from the new `shared_install` and published
`shared/beethoven/hpcworker/v7`, `current -> v7`; `hpcworker version` through the old spelling's
`current` answers 7 too. v7 was published once more with `--replace` minutes later (no job had named
it), for the order of the spelling rule above; the first copy is kept as `v7.replaced-<time>`. The
account's `profile.json` (framework 5's `wayne.json`, without `shared_install`, the same in every
other key) became framework 7's, the old one kept in `~/.hpcworker/replaced/20260930-beethoven-rename/`,
and `install --shared <new folder> --profile wayne` moved the launcher and the marker to the new name.
Then Beethoven 7.0.0's own line, `bash '/rs/rs_grp_oschome/shared/ashley/hpcworker/current/bin/hpcworker'
install --shared '/rs/rs_grp_oschome/shared/ashley/hpcworker/current' --profile 'wayne'`, said `hpcworker
7: shared copy at /rs/rs_grp_oschome/shared/ashley/hpcworker/current; launcher and marker refreshed
(nothing copied) (recorded under the folder's new name)`, and the launcher, the marker, `profile.json`,
`~/.bashrc` and the account's `config.env` kept their bytes (SHA-256 before and after), the file list
under `~/.hpcworker` too; `hpcworker version` says `7 (shared copy at
/rs/rs_grp_oschome/shared/beethoven/hpcworker/current)`. A ten-minute job on asx13 (40513153,
`secp/secondary`, 7 s, not a worker) started the lab's container once with the lab folder named and
bound by its old spelling and once by its new one: both ran `node v22.23.3` and `claude 2.1.283`, read
framework 7 through `current`, and reached the sign-in folder as `~/.ashley/claude` and as
`~/.beethoven/claude`; so apptainer 1.2.2 binds a folder named through a link. Nothing of ours under
warrior's `/tmp`. The 121 unit tests pass under WSL (none skipped, among them the new one for the two
spellings) and on a Windows checkout (the link, pty and permission tests skipped there). Not measured:
a worker or probe of framework 7 running on the grid, and whether the portal's Files app lists the old
spelling (a link) as a folder.

2026-09-30 (framework 9, `scheduler_in_worker`): one check job, 40518457 on asx1 (`secp/secondary`,
five minutes asked, under one used, not a worker), from a copy of the framework under
`/rs/rs_grp_oschome/go2432/tmp/hpcw9_check`. On the node: `/usr/bin/sbatch`, `/usr/lib64/slurm`,
`/etc/slurm`, `/var/run/munge/munge.socket.2` and `/usr/lib64/libmunge.so.2 -> libmunge.so.2.0.0`
present, `SlurmUser=slurm`. `hpcw_slurm_in_container` bound them and wrote the user lists and
wrappers under `/dev/shm/go2432/hpcw_40518457/slurm`; inside the container (Debian 12, as go2432)
`command -v` found every wrapper in `/opt/hpcw/slurm/bin`, first on PATH, and `slurm` (9114) and
`munge` (9113) were in `/etc/passwd`. `squeue -u go2432` listed the account's jobs, this one among
them (exit 0); `sinfo -s` listed the partitions (exit 0); `sacct -j 40518457 -X` showed it RUNNING
on asx1 in `secp`/`secondary` (exit 0); `sbatch --test-only -p secp -q secondary` was answered by the
controller ("Job 40518458 to start at 2026-09-30T11:52:33 using 1 processors on nodes asx1 in
partition secp"; `--test-only` submits nothing) (exit 0); `scancel --version` said `slurm 23.02.6`.
`scontrol show job` failed: `/opt/host/bin/scontrol: error while loading shared libraries:
libreadline.so.6` (exit 127); scontrol gets no wrapper since. The environment a submitted job would
start from (the sbatch wrapper with `env` in place of sbatch): the host's PATH, `TMPDIR` the job's
own (`/rs/rs_grp_oschome/go2432/tmp`), `SLURM_CONF` and no other `SLURM_` variable (36 inside the
container), no `APPTAINER_` or `SINGULARITY_` variable, but `LD_LIBRARY_PATH=/.singularity.d/libs`
where the host job had the person's module paths; the wrappers carry the host's since. The EXIT trap
removed the node temp and the `/dev/shm` folder. No worker was started. Then `tools/deploy_shared.sh`
published framework 9 as `v9` (`current: v8 -> v9`, 2026-09-30T16:07Z, from c05f595 with the changes
not yet committed; v8 and the older versions kept), and `~/.hpcworker/bin/hpcworker version` over
ssh said `9 (shared copy at /rs/rs_grp_oschome/shared/beethoven/hpcworker/current)`.

Not verified on the grid by the framework itself, because the student's grid sign-in was gone before
the first worker started (`claude auth status` inside the image says `loggedIn: false`): the
registration parse on a live `rc.log` (the parser is unit-tested against the exact block above, with
terminal codes), the consent answer typed from the marker fallback, `--continue` in a successor
after a link ends, a successor actually starting after its parent's wall time, and two Remote Control
hosts on one login. Those need one student session: `hpcworker claude login`, `hpcworker worker
start`, then `hpcworker worker status`. While logged out, `claude remote-control --help` prints only
"You must be logged in to use Remote Control", so the job assumes the documented flags (`--name`,
`--capacity`, `--continue`, `--permission-mode`) until a signed-in probe records them.
