# Site and lab modules (a pinned copy)

The modules here are copied from `OpenSpineConsortium/beethoven-sites`, where they are written,
reviewed and checked (greg's decision of 2026-10-05: the site modules have their own repository).
`ORIGIN` names the commit they came from, the export and its version, and each file's sha256;
`tests/test_sites.py` fails when a file differs from it. They are never edited here: a change lands in
beethoven-sites, then `bash framework/sites/pull.sh` (`--ref REF` for another merged commit) copies
what that repository's `interface/INTERFACE.json` lists under the export `modules`, from GitHub through
`gh` and never from a checkout, `python3 framework/lib/profile.py compose-all` writes the profiles, and
the copy, `ORIGIN` and the profiles are committed together (the interface standard,
`interface/README.md`).

Each deployment's profile, `profiles/<id>.json`, is composed from three layers:

| Layer | What it is | Where |
|---|---|---|
| product | Beethoven's own values: the sign-in folder Claude Code starts in and the consent markers beside it, `$HOME` as every worker's first bind, the 60 s poll floor, `/dev/shm` for sockets, the worker defaults, how long a worker waits for the sign-in | `PRODUCT` in `lib/profile.py` |
| site | a university's cluster, whoever uses it: scheduler, login node and its process cap, partitions and QoS, node-local temp, the container runtime, egress, the portal, the VPN, ssh and its host key, help links | `sites/<site>/site.json` |
| lab | one group's deployment on that cluster: its state folder, its shared copy of the framework, its image and `claude`, its volume binds, its allocation account, the partition its long workers use, a browser key's lifetime | `sites/<site>/labs/<lab>.json` |

Wayne State today is the site `wayne` and the lab `oschome`, composed into `profiles/wayne.json`, the
file every client and the engine vendor.

## What stays here

hpcworker owns the rules a module follows and the composing: the schema, `FIELD_LAYERS` (the
layers that may set each field), `SUBFIELDS` (the keys an object field holds), `PRODUCT`, and
`compose`, `compose-all` and `show --layers` in `lib/profile.py`. `profile.py module-schema` prints
those rules as data; beethoven-sites pins that output and checks its modules against it with no code
of this repository. That output is committed as `interface/sites/module-schema.json`, the export
`module-schema` (`tests/test_interface.py` fails when it differs from what `profile.py` prints). A
change to the rules lands here first, then beethoven-sites takes the new schema (`tools/pull_schema.sh`
there, which copies that file and runs nothing of this repository) before a module may use it.

In short: a module is data only; it sets only what its layer may set and only keys the schema names,
inside an object field too; objects merge key by key, `binds` add up, anything else a later layer sets
replaces the earlier value; what a module says about itself (`kind`, `module_version`, a lab's `site`,
`lab` and `profile`) stays out of the profile; and the composed profile must pass `profile.py validate`
on its own. Until BEE-208 a site has one lab, whose profile carries the site's id, because the
framework still finds an account's profile by its `site` field.

## Commands

```
python3 lib/profile.py compose sites/wayne/site.json sites/wayne/labs/oschome.json   # the composed profile on stdout
python3 lib/profile.py compose-all            # writes every profiles/<id>.json its modules compose
python3 lib/profile.py compose-all --check    # compares only; the suite runs it (tests/test_sites.py)
python3 lib/profile.py show --layers wayne    # every value with the layer and the file that set it
python3 lib/profile.py module-schema          # the rules a module follows, as data
```

`compose-all` never removes a profile: one no module composes is named and kept.

## Not yet here

These parts of the design (Linear project *U — University Site Modules*) come later: what was
measured kept apart from what is declared (BEE-207; until then the dated measurements stay in
`egress.measured` and in `notes`, which stays in the site module), the rules with their sources
(BEE-206), the site's words for students (BEE-212), the portal and ssh hosts a client matches
(BEE-210), the partition roles as `{partition, qos}` lists, and an account profile that keeps only
the student's own choices and names its profile (BEE-208). Lines of the framework that still spell a
Wayne State value are listed in `tests/site_literals_known.txt` until BEE-202 and BEE-205 remove them.
