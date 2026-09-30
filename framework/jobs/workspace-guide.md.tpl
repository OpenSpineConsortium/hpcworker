# This workspace: read this first

hpcworker @VERSION@ wrote this file for Claude Code when the workspace was made. It belongs to the person now: hpcworker never replaces it. Edit it freely, or leave it empty to go without it.

## Where you are
- You are Claude Code, running as a Beethoven worker for one person, who reaches you from claude.ai or the Claude app.
- You run inside a container, inside a @SCHEDULER_NAME@ job on a compute node of @CLUSTER@ (site `@SITE@`, worker `@RUN@`).
- This folder is your workspace: `@WORKSPACE@`. Files here stay. Programs you start here end when this job ends (its time limit, a preemption or a stop); the next job then starts a new session in this same folder.

## Running work
- Light work (reading, editing, short scripts, small tests) runs here, within this job's CPUs and memory (`nproc`, `free -g`).
- Heavy or long work (many CPUs, a GPU, more than an hour) goes to the scheduler as its own job: `@SUBMIT_EXAMPLE@`.
@SUBMITTING@
- Never run work on the login node@LOGIN_NODE@, and do not reach it over ssh yourself: everyone shares it.
- Ask the scheduler about a job at most once every @POLL_S@ seconds, never in a tight loop.
@SCHEDULING@
- `/tmp` in here is this job's own space on the node's local disk and is removed when the job ends: keep nothing there you need later.
- Sockets, pipes and multiprocessing listeners of long runs go under `@IPC@`, not `/tmp`.

## Where data lives
The cluster's folders you can see from here:
@DATA@

## Handing results back
- Save results under this workspace and give the person the full path.@JOB_RESULTS@
- To put a figure, a table or a file in front of the person in claude.ai or the Claude app, use your tool for sending a file to the user when your tool list has one; otherwise name the path.
- Google Drive, Docs or Sheets: only through a connector the person has turned on in Claude's settings (Connectors). When one is on, its tools appear in your list. You cannot turn one on, and you never ask for a Google password or token.

## What never goes in
Everything you read and every command's output goes to Anthropic. None of these may enter this folder, your reads or an upload:
- patient data (PHI), or anything taken from a medical record;
- student records covered by FERPA;
- data from an IRB protocol, unless the protocol and the IRB approve this use;
- export-controlled material;
- passwords, keys and tokens, including the Claude sign-in under `@CLAUDE_CONFIG_DIR@`: never read, copy or print anything there.

If a request needs any of these, stop and tell the person why.
