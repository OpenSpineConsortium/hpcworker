# What hpcworker offers other repositories

This repository is one sealed unit of the Beethoven ecosystem. Another repository reaches it only
through what `INTERFACE.json` lists, at a version, through a copy pinned to a commit on `main`, and
never through a checkout of this tree (the interface standard:
https://github.com/OpenSpineConsortium/beethoven/blob/main/INTERFACES.md). Everything not listed is
private and may change in any pull request.

| Export | Kind | Version | What it is | Taken by |
| --- | --- | --- | --- | --- |
| `contract` | contract | 1 | `contract/`: what a client may type (`cli.json`), the lines it reads (`lines.json`), the files it reads (`status.schema.json`, `connection.schema.json`, `worker-status.schema.json`), the credential and sign-in rules (`rules.json`), and `vectors/`, what the real framework printed and wrote | beethoven-extension, beethoven-desktop, beethoven-agents, beethoven-vscode |
| `contract-text` | text | 1 | `docs/V11_CONTRACT.md` and `docs/V12_CONTRACT.md`, the same contract written for people | beethoven-extension, beethoven-desktop |
| `profiles` | data | 1 | `framework/profiles/*.json`, one composed profile per deployment | beethoven-extension, beethoven-desktop, beethoven-agents |
| `module-schema` | schema | 1 | `sites/module-schema.json`, what a site or lab module may carry (`profile.py module-schema`, committed) | beethoven-sites |
| `testbed` | program | 1 | `testbed/fakebin/`, the fake scheduler this repository's own tests use, for a client's test that runs the real framework behind it | beethoven-desktop, beethoven-extension |
| `framework` | program | 1 | the lab's shared copy as `tools/deploy_shared.sh` publishes it, run as a black box in a client's opt-in test; its interface is `contract` | beethoven-desktop, beethoven-extension |

It takes two things: beethoven-sites' `modules` version 1, pinned in `framework/sites/` by
`framework/sites/pull.sh` with `framework/sites/ORIGIN`; and beethoven-access's `http-api` version 1
(the access service's routes, the grammar of its two plain-text lists and the answers the real Worker
gave), pinned in `interface/access/` by `interface/access/pull.sh` with `interface/access/ORIGIN`.
`tools/grid_access.sh` reads the service's `GET /admin/roster.txt` and `GET /admin/readers.txt` and
codes to that contract; `framework/tests/test_access_contract.py` checks the tool against the copy,
and is skipped, naming the pull, until the copy is there.

## How a client takes an export

With its own `pull.sh` and its own `gh` sign-in, from a commit `main` contains, only the paths this
manifest lists for the export at that commit, into one folder with an `ORIGIN` record (`repository`,
`commit`, `export <id> <version>`, one `sha256` line per file); its own test run fails when the folder
differs from `ORIGIN`. Each file lands at its path below the folder the export's paths share
(`interface/contract/lines.json` at `lines.json`). A client never reads this repository's checkout,
never imports `framework/tests/`, and never runs `framework/` except as the `framework` program behind
the `testbed`.

## How an export changes here

1. The code and the export change in one pull request. `contract/vectors/` is rewritten by the tool,
   never by hand: `python3 framework/tests/vectors.py --write`. Until it is, `test_interface.py` fails,
   so an output never moves silently.
2. An export's `version` goes up when a client must change its code: a field removed, renamed or
   retyped, a line that reads differently, a failure code whose meaning changes, a command that goes
   away. An additive change (a new optional field, a new failure code an older client reads as
   `other`) keeps the version.
3. `interface/sites/module-schema.json` is `python3 framework/lib/profile.py module-schema`, committed;
   `test_interface.py` fails when the two differ.

## What checks it

- `framework/tests/test_interface.py`: the manifest's shape, every path names a file, `interface/`
  holds nothing unlisted; the schemas use only what every client's check reads; every vector is what
  the real writer produces now, passes its schema and the line grammar; every failure code `connect`
  prints is in `lines.json` with its exit status; `rules.json` is the strip list, the agent markers and
  the sign-in verdict the code applies; the module schema is what `profile.py` prints.
- `framework/tests/test_boundary.py`: no tracked file reaches another repository's checkout (with a
  short list of known exceptions, each with its reason, that fails when an entry goes stale), and each
  import equals its `ORIGIN` (an import whose copy is not pulled yet is skipped with its pull command,
  never passed).
- `framework/tests/test_access_contract.py`: every line of the access service's roster and readers
  vectors passes `tools/grid_access.sh`'s own checks, and the service's line patterns are the tool's.

Both run in `framework/tests/run.sh`, so in CI on ubuntu and in the CentOS 7 container, and on the grid.
