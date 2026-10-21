#!/usr/bin/env python3
"""hpcworker site profile: schema, load/validate, render helpers.

One JSON file per deployment describes everything the job templates need to
know about a cluster. It is seeded by hand or by `hpcworker discover`, and
corrected by the probe job. In this repository profiles/<id>.json is composed
from a site module (the university's cluster, sites/<site>/site.json) and a lab
module (one group's deployment there, sites/<site>/labs/<lab>.json) over the
product's own values; `compose-all` writes it and the tests hold it to them. Only the standard library
is used, and only syntax that Python 3.6 accepts: the login node this was
written against runs CentOS 7, whose system python3 is 3.6.

A field the file carries that this version's SCHEMA does not name (written by an
older or a newer release) is ignored and named once in the validate and render
output; it is never an error, so a profile.json already on a cluster keeps
working across releases. `set` still refuses to add such a field.

Command line (used by bin/hpcworker; nothing here runs a container or talks to
a scheduler):
    profile.py validate <profile>
    profile.py get <profile> <dotted.key>
    profile.py shellenv <profile>                 # P_key=value lines for bash eval
    profile.py show <profile>
    profile.py show --layers <id> | <site.json> <lab.json>   # each composed value with the layer and file that set it
    profile.py compose <site.json> <lab.json>      # a site module and a lab module composed, on stdout
    profile.py compose-all [--check] [--root DIR]  # sites/*/labs/*.json -> profiles/<id>.json (--check: compare only)
    profile.py module-schema                       # what a module may carry, as JSON (beethoven-sites pins it)
    profile.py set <profile> <dotted.key> <json-or-string>
    profile.py from-discovery <discover.json> [site]   # a seed profile on stdout
    profile.py render <template> <profile> KEY=VALUE...  # rendered text on stdout
    profile.py guide <template> <profile> RUN=<name>     # the workspace guide (CLAUDE.md) on stdout
    profile.py mapping <profile> KEY=VALUE...      # the render mapping as JSON
    profile.py consent <claude_config_dir> [workspace]   # remote_dialog_seen=.. workspace_trusted=.. (two booleans, nothing else)
    profile.py schema
"""
import json
import os
import posixpath
import re
import shlex
import sys

SCHEMA_VERSION = 1


def framework_version():
    """The integer in ../VERSION (the checkout's, or the installed copy's under ~/.hpcworker): what
    the rendered job and status.json report as "version". The schema version when the file is absent."""
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "VERSION")) as fh:
            v = fh.read().strip()
    except (IOError, OSError):
        return str(SCHEMA_VERSION)
    return v if re.match(r"^\d+$", v) else str(SCHEMA_VERSION)


def code_root():
    """The framework tree this file belongs to (the directory above lib/), as a path spelled with
    forward slashes. abspath, not realpath: a shared copy is reached through links that must stay
    as spelled (/rs/rs_grp_oschome is itself a link at Wayne State)."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__))).replace(os.sep, "/")


# key -> (type, required, default, description). "type" is a python type, a
# tuple of allowed strings, or "list"/"dict"/"int_or_none"/"bool_or_none".
SCHEMA = [
    ("schema_version", int, True, SCHEMA_VERSION, "profile schema version (integer)"),
    ("site", str, True, None, "short site id used in session names, e.g. wayne"),
    ("display_name", str, False, "", "the university's name for messages"),
    ("scheduler", ("slurm", "pbs", "lsf", "sge", "htcondor"), True, None, "scheduler family"),
    ("submit_host", str, False, "", "login node the scheduler client runs on"),
    ("bin_dir", str, False, "", "scheduler client directory, when not on PATH"),
    ("partition_cpu", str, True, None, "CPU partition for interactive and test work"),
    ("qos_cpu", str, False, "", "QoS for partition_cpu"),
    ("partition_cpu_batch", str, False, "", "CPU partition for long workers"),
    ("qos_batch", str, False, "", "QoS for partition_cpu_batch"),
    ("partitions_gpu", "list", False, [], "GPU partitions, in order of preference"),
    ("qos_gpu", str, False, "", "QoS for partitions_gpu"),
    ("account", str, False, "", "allocation account, when the site needs one"),
    ("max_walltime", str, False, "", "longest wall time the CPU partition accepts"),
    ("node_tmp", str, True, None, "node-local temp pattern; $USER and $SLURM_JOB_ID/$HPCW_JOB_ID expand in the job"),
    ("node_tmp_var", str, False, "", "variable that names node-local temp when the site sets one (SLURM_TMPDIR, L_SCRATCH); empty = none trusted"),
    ("tmpdir_is_node_local", bool, False, False, "whether $TMPDIR may be trusted as node-local (false on Wayne State: it is CephFS)"),
    ("ipc_dir", str, True, "/dev/shm", "where sockets and pipes go (never a swept /tmp)"),
    ("shared_state_dir", str, True, None, "shared storage for run directories; $HOME and $USER expand"),
    ("shared_install", str, False, "", "the lab's shared copy of the framework (an absolute directory with bin/, lib/, jobs/, profiles/, VERSION; usually a `current` link to a numbered directory); `hpcworker install --shared` uses it and copies no code into the home; empty = none"),
    ("runtime", ("apptainer", "singularity", "podman", "pyxis"), True, None, "container runtime"),
    ("runtime_module", str, False, "", "module to load for the runtime, if any"),
    ("runtime_bin", str, False, "", "absolute path of the runtime binary, when known"),
    ("image_store", "dict", True, None, "{type: sandbox|sif, path: ...}"),
    ("claude_bin", str, True, None, "path of the claude executable as seen inside the container"),
    ("binds", "list", False, [], "bind mounts for the container; $HOME and $USER expand"),
    ("cache_dir", str, False, "", "runtime cache; empty = under node_tmp"),
    ("fakeroot_rung", "int_or_none", False, None, "predicted --fakeroot rung 1-4, or null"),
    ("egress", "dict", True, None, "{class: direct|http-proxy-auto|http-proxy-module|none, proxy_env: {}, proxy_module: '', ca_bundle: '', measured: {}}"),
    ("claude_config_dir", str, True, None, "CLAUDE_CONFIG_DIR of the student's own Claude Code login; the framework reads two booleans from its .claude.json (remoteDialogSeen, the workspace's hasTrustDialogAccepted) and nothing else"),
    ("consent_markers", "list", False, [], "fallback marker files whose presence records the student's Remote Control consent when Claude Code has not recorded it itself"),
    ("ood_base_url", str, False, "", "Open OnDemand portal URL"),
    ("ood_shell_host", str, False, "", "host the portal's Shell app opens"),
    ("ood_rnode_enabled", "bool_or_none", False, None, "probed: is the /rnode/ reverse proxy on"),
    ("ood_auth", ("", "http-basic", "cookie"), False, "", "how the portal signs in (a hint for the extension's Details; the extension tests the channel itself)"),
    ("vpn_required", bool, False, False, "portal and login node need the VPN"),
    ("vpn_portal", str, False, "", "the VPN portal address a student types into the VPN app (protect.wayne.edu)"),
    ("vpn_app", str, False, "", "the VPN app's name (GlobalProtect)"),
    ("vpn_help_url", str, False, "", "the university's page on setting up the VPN (https)"),
    ("grid_account_help_url", str, False, "", "the university's page on getting a cluster account (https)"),
    ("grid_2fa_help_url", str, False, "", "the university's page on setting up the cluster's two-factor code for a password sign-in (https)"),
    ("ssh_host", str, False, "", "the login node's public ssh name, for Beethoven's ssh path (grid.wayne.edu); empty = no ssh path"),
    ("ssh_port", int, False, 22, "the port of ssh_host"),
    ("node_domain", str, False, "", "the compute nodes' domain (nas.grid.wayne.edu): a node is reached by ssh through the login node, and only while a job of yours runs on it; empty = not known"),
    ("ssh_host_key", str, False, "", "ssh_host's host key fingerprint as ssh-keygen -l prints it (SHA256:...); Beethoven refuses any other key"),
    ("ssh_relay", "str_or_none", False, None, "a relay Beethoven may use to reach ssh_host (a wss:// or https:// address), or null for none"),
    ("browser_key_days", "int_or_none", False, None, "days a browser key's line stays valid; past them the gate removes it (null = no expiry)"),
    ("session_title", str, False, "", "the Remote Control session title a worker asks for (\"Wayne State grid\"; \"<title> · <name>\" for a worker not named worker); empty = \"Grid worker\""),
    ("login_abandon_s", int, False, 1200, "seconds a worker job waits for the Claude sign-in before it stops itself and queues no successor (0 = never)"),
    ("restricted", bool, False, False, "no worker may start on this site's accounts (hpcworker connect refuses)"),
    ("restricted_workspaces", "list", False, [], "worker names that may not start (\"*\" for all); hpcworker connect refuses them"),
    ("login_node_rules", "dict", True, {"max_processes": 20, "poll_floor_seconds": 60}, "{max_processes, poll_floor_seconds}"),
    ("xdg_runtime_fix", bool, False, True, "point XDG_RUNTIME_DIR at ipc_dir/$USER/xdg for Claude Code's bash tool"),
    ("scheduler_in_worker", bool, False, False, "bind the host's scheduler client into the worker's container so Claude Code there can submit and watch jobs (Slurm with apptainer or singularity only; the binds were measured at Wayne State)"),
    ("home_filesystem", str, False, "", "panfs, lustre, gpfs, nfs, cephfs...: parallel homes want SIF over sandbox"),
    ("worker_defaults", "dict", False, {"cpus": 2, "mem": "8G", "hours": 8, "permission_mode": "default", "capacity": 4}, "defaults for hpcworker worker start"),
    ("notes", str, False, "", "free text for the maintainer"),
]

EGRESS_CLASSES = ("direct", "http-proxy-auto", "http-proxy-module", "none")
IMAGE_TYPES = ("sandbox", "sif")
PLACEHOLDER = re.compile(r"@([A-Z][A-Z0-9_]*)@")
# variables the framework expands on the login node; everything else is left
# for the job (SLURM_JOB_ID is not known until the job runs)
LOGIN_SIDE_VARS = ("HOME", "USER")


def expand(value, env=None):
    """Expand $HOME/$USER (and ${HOME}/${USER}) only; leave other $VARS alone."""
    env = os.environ if env is None else env
    if not isinstance(value, str):
        return value
    out = value
    for name in LOGIN_SIDE_VARS:
        val = env.get(name)
        if val is None:
            continue
        out = out.replace("${%s}" % name, val)
        out = re.sub(r"\$%s(?![A-Za-z0-9_])" % name, val.replace("\\", "\\\\"), out)
    return out


def defaults():
    prof = {}
    for key, _typ, _req, default, _desc in SCHEMA:
        if default is not None:
            prof[key] = json.loads(json.dumps(default))
    return prof


def _type_ok(typ, value):
    if typ == "list":
        return isinstance(value, list)
    if typ == "dict":
        return isinstance(value, dict)
    if typ == "int_or_none":
        return value is None or (isinstance(value, int) and not isinstance(value, bool))
    if typ == "bool_or_none":
        return value is None or isinstance(value, bool)
    if typ == "str_or_none":
        return value is None or isinstance(value, str)
    if isinstance(typ, tuple):
        return isinstance(value, str) and value in typ
    if typ is int:
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, typ)


def known_fields():
    return set(key for key, _typ, _req, _default, _desc in SCHEMA)


def unknown_fields(prof):
    """Top-level fields this version's schema does not name, in file order. A profile written by
    another release (an older one that still carried a field since dropped, or a newer one) is
    not an error: the field is ignored and reported once, and everything else works."""
    if not isinstance(prof, dict):
        return []
    known = known_fields()
    return [key for key in prof if key not in known]


def unknown_note(prof):
    """One clause for a message, or '' when every field is known."""
    unk = unknown_fields(prof)
    return "ignored %d field(s) this version does not know: %s" % (len(unk), ", ".join(unk)) if unk else ""


def validate(prof):
    """Return a list of problems (empty when the profile is usable). A field the schema does not
    name is not a problem (see unknown_fields); a wrong type or a missing required field is."""
    errs = []
    if not isinstance(prof, dict):
        return ["profile is not a JSON object"]
    for key, typ, required, _default, _desc in SCHEMA:
        if key not in prof:
            if required:
                errs.append("missing required field: %s" % key)
            continue
        if not _type_ok(typ, prof[key]):
            want = "/".join(typ) if isinstance(typ, tuple) else (typ if isinstance(typ, str) else typ.__name__)
            errs.append("field %s: expected %s, got %r" % (key, want, prof[key]))
    img = prof.get("image_store")
    if isinstance(img, dict):
        if img.get("type") not in IMAGE_TYPES:
            errs.append("image_store.type must be one of %s" % (IMAGE_TYPES,))
        if not isinstance(img.get("path"), str) or not img.get("path"):
            errs.append("image_store.path must be a non-empty string")
    eg = prof.get("egress")
    if isinstance(eg, dict):
        if eg.get("class") not in EGRESS_CLASSES:
            errs.append("egress.class must be one of %s" % (EGRESS_CLASSES,))
        if not isinstance(eg.get("proxy_env", {}), dict):
            errs.append("egress.proxy_env must be an object")
        for k in eg.get("proxy_env", {}) or {}:
            if k.upper() not in ("HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"):
                errs.append("egress.proxy_env may only set https_proxy, http_proxy, no_proxy (got %s)" % k)
    rules = prof.get("login_node_rules")
    if isinstance(rules, dict):
        for k in ("max_processes", "poll_floor_seconds"):
            if not isinstance(rules.get(k), int):
                errs.append("login_node_rules.%s must be an integer" % k)
        if isinstance(rules.get("poll_floor_seconds"), int) and rules["poll_floor_seconds"] < 60:
            errs.append("login_node_rules.poll_floor_seconds must be at least 60")
    if isinstance(prof.get("site"), str) and not ID.fullmatch(prof["site"]):
        errs.append("site must be lower-case letters, digits and dashes (it goes into session names)")
    if isinstance(prof.get("node_tmp"), str):
        nt = prof["node_tmp"]
        if nt.startswith("$TMPDIR") and not prof.get("tmpdir_is_node_local"):
            errs.append("node_tmp uses $TMPDIR but tmpdir_is_node_local is false")
        if "$USER" not in nt and "${USER}" not in nt:
            errs.append("node_tmp should contain $USER so users do not share a directory")
    for key in ("shared_state_dir", "claude_config_dir"):
        v = prof.get(key)
        if isinstance(v, str) and not (v.startswith("/") or v.startswith("$HOME") or v.startswith("${HOME}")):
            errs.append("%s must be absolute or start with $HOME" % key)
    if prof.get("scheduler_in_worker") is True:
        if prof.get("scheduler") != "slurm":
            errs.append("scheduler_in_worker is built for Slurm only (this profile's scheduler is %s)" % prof.get("scheduler"))
        if prof.get("runtime") not in ("apptainer", "singularity"):
            errs.append("scheduler_in_worker needs apptainer or singularity (this profile's runtime is %s)" % prof.get("runtime"))
    si = prof.get("shared_install")
    if isinstance(si, str) and si and (not si.startswith("/") or re.search(r"[\s'\"]", si)):
        errs.append("shared_install must be an absolute directory without spaces or quotes (or empty)")
    # framework 10: the session title goes into the job file inside single quotes and onto Claude Code's command line
    st = prof.get("session_title")
    if isinstance(st, str) and (len(st) > 64 or re.search(r"['\"`$\\\x00-\x1f\x7f]", st)):
        errs.append("session_title must be at most 64 characters without quotes, backslashes, $ or control characters")
    for key in ("vpn_help_url", "grid_account_help_url", "grid_2fa_help_url"):
        v = prof.get(key)
        if isinstance(v, str) and v and not re.match(r"^https://[^\s'\"]+$", v):
            errs.append("%s must be an https address (or empty)" % key)
    vp = prof.get("vpn_portal")
    if isinstance(vp, str) and vp and not re.match(r"^[A-Za-z0-9.-]{1,253}$", vp):
        errs.append("vpn_portal must be a host name (letters, digits, dots and dashes)")
    # framework 11: the ssh path's keys (the extension reads them from the site profile)
    sh = prof.get("ssh_host")
    if isinstance(sh, str) and sh and not re.match(r"^[A-Za-z0-9.-]{1,253}$", sh):
        errs.append("ssh_host must be a host name (letters, digits, dots and dashes)")
    nd = prof.get("node_domain")
    if isinstance(nd, str) and nd and not re.match(r"^[A-Za-z0-9.-]{1,253}$", nd):
        errs.append("node_domain must be a domain name (letters, digits, dots and dashes)")
    sp = prof.get("ssh_port")
    if isinstance(sp, int) and not isinstance(sp, bool) and not 1 <= sp <= 65535:
        errs.append("ssh_port must be between 1 and 65535")
    hk = prof.get("ssh_host_key")
    if isinstance(hk, str) and hk and not re.match(r"^SHA256:[A-Za-z0-9+/]{43}$", hk):
        errs.append("ssh_host_key must be a SHA256: fingerprint as ssh-keygen -l prints it (or empty)")
    rl = prof.get("ssh_relay")
    if isinstance(rl, str) and not re.match(r"^(wss|https)://[^\s'\"]+$", rl):
        errs.append("ssh_relay must be a wss:// or https:// address (or null)")
    bd = prof.get("browser_key_days")
    if isinstance(bd, int) and not isinstance(bd, bool) and not 1 <= bd <= 3650:
        errs.append("browser_key_days must be between 1 and 3650 (or null for no expiry)")
    la = prof.get("login_abandon_s")
    if isinstance(la, int) and not isinstance(la, bool) and la != 0 and la < 300:
        errs.append("login_abandon_s must be 0 (never) or at least 300 seconds")
    rw = prof.get("restricted_workspaces")
    if isinstance(rw, list):
        for w in rw:
            if not isinstance(w, str) or not re.match(r"^(\*|[A-Za-z0-9_-]{1,32})$", w):
                errs.append("restricted_workspaces entries must be worker names or \"*\" (got %r)" % (w,))
    # bind specs travel through a job file as one space-separated string
    for b in prof.get("binds", []) or []:
        if not isinstance(b, str) or re.search(r"\s", b) or not b:
            errs.append("binds entries must be non-empty paths without whitespace (got %r)" % (b,))
    # a profile is a settings file: it must never carry a credential
    for key, val in _walk(prof):
        if isinstance(val, str) and CREDENTIAL.search(val):
            errs.append("field %s looks like it carries a credential; the profile never does" % key)
    return errs


def _walk(obj, prefix=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            for item in _walk(v, prefix + k + "."):
                yield item
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            for item in _walk(v, prefix + str(i) + "."):
                yield item
    else:
        yield prefix.rstrip("."), obj


# Fields a later version added to a site profile, which an account's profile.json (a copy of the site
# profile made when the account was installed, and kept since) does not carry. Until the account sets
# its own value, such a field takes the value of the site profile of the same name in this copy of
# the framework (profiles/<site>.json beside lib/), so a site switches it on for every account by
# publishing a new version, and `hpcworker profile set` still overrides it per account.
FIELDS_FROM_SITE = ("scheduler_in_worker", "session_title", "login_abandon_s", "ood_auth", "vpn_portal", "vpn_app",
                    "vpn_help_url", "grid_account_help_url", "restricted", "restricted_workspaces",
                    # framework 11
                    "grid_2fa_help_url", "ssh_host", "ssh_port", "ssh_host_key", "ssh_relay", "browser_key_days",
                    # framework 25
                    "qos_gpu", "node_domain")


def session_title(prof, run):
    """The Remote Control session title a worker asks for (framework 10): the profile's session_title
    ("Grid worker" when it names none), with " · <name>" for a worker not named "worker". The same rule
    as the extension's contract.ts sessionTitleFor, so both sides look for the same name."""
    base = prof.get("session_title") or "Grid worker"
    return base if run == "worker" else "%s · %s" % (base, run)


def site_values(site):
    """FIELDS_FROM_SITE as this copy's profiles/<site>.json sets them ({} when there is no such file)."""
    if not isinstance(site, str) or not re.match(r"^[a-z0-9][a-z0-9-]{0,31}$", site):
        return {}
    try:
        with open(os.path.join(code_root(), "profiles", site + ".json"), "r", encoding="utf-8") as fh:
            sp = json.load(fh)
    except (IOError, OSError, ValueError):
        return {}
    if not isinstance(sp, dict) or sp.get("site") != site:
        return {}
    return dict((k, sp[k]) for k in FIELDS_FROM_SITE if k in sp)


def load(path):
    """The profile at PATH over the site's values for FIELDS_FROM_SITE, over the schema's defaults."""
    with open(path, "r", encoding="utf-8") as fh:
        prof = json.load(fh)
    merged = defaults()
    if isinstance(prof, dict):
        merged.update(site_values(prof.get("site")))
    merged.update(prof)
    return merged


def get(prof, dotted):
    cur = prof
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
            cur = cur[int(part)]
        else:
            return None
    return cur


def set_key(prof, dotted, value):
    parts = dotted.split(".")
    cur = prof
    for part in parts[:-1]:
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    cur[parts[-1]] = value


def save(prof, path):
    tmp = path + ".part"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(prof, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


# ----------------------------------------------------------------------------
# site and lab modules (BEE-199): a university's cluster and one lab's deployment on it, kept apart
# and composed into the profiles/<id>.json every consumer reads
# ----------------------------------------------------------------------------

# The layers a composed profile is made of, in the order they are laid down: the product's own values
# (PRODUCT below), the site (a university's cluster, whoever uses it: sites/<site>/site.json) and the
# lab (one group's deployment there: sites/<site>/labs/<lab>.json).
LAYERS = ("product", "site", "lab")

# Which layers may set each field of SCHEMA, the owner first. A module that sets a field its layer may
# not set is refused, so a lab cannot pin another host key and a site cannot name a lab's volume.
FIELD_LAYERS = {
    "schema_version": ("product",),
    "site": ("site",),
    "display_name": ("site",),
    "scheduler": ("site",),
    "submit_host": ("site",),
    "bin_dir": ("site",),
    # the site's partition for short and test work; a lab may send its own elsewhere
    "partition_cpu": ("site", "lab"),
    "qos_cpu": ("site", "lab"),
    # the long worker's partition is the lab lead's choice (Wayne State's notes say so since framework 10)
    "partition_cpu_batch": ("lab",),
    "qos_batch": ("lab",),
    # the site's catalogue; the engine's own jobs choose from it even where a lab runs no GPU worker
    "partitions_gpu": ("site",),
    "qos_gpu": ("site",),
    "account": ("lab",),
    "max_walltime": ("site",),
    "node_tmp": ("site",),
    "node_tmp_var": ("site",),
    "tmpdir_is_node_local": ("site",),
    "ipc_dir": ("product", "site"),
    "shared_state_dir": ("lab",),
    "shared_install": ("lab",),
    "runtime": ("site",),
    "runtime_module": ("site",),
    "runtime_bin": ("site",),
    "image_store": ("lab",),
    "claude_bin": ("lab",),
    "binds": ("product", "site", "lab"),
    "cache_dir": ("site",),
    "fakeroot_rung": ("site",),
    "egress": ("site",),
    # the student's own sign-in and Remote Control answer: never a site's or a lab's to move
    "claude_config_dir": ("product",),
    "consent_markers": ("product",),
    "ood_base_url": ("site",),
    "ood_shell_host": ("site",),
    "ood_rnode_enabled": ("site",),
    "ood_auth": ("site",),
    "vpn_required": ("site",),
    "vpn_portal": ("site",),
    "vpn_app": ("site",),
    "vpn_help_url": ("site",),
    "grid_account_help_url": ("site",),
    "grid_2fa_help_url": ("site",),
    "ssh_host": ("site",),
    "ssh_port": ("site",),
    "node_domain": ("site",),
    "ssh_host_key": ("site",),
    "ssh_relay": ("site",),
    "browser_key_days": ("lab",),
    "session_title": ("site", "lab"),
    "login_abandon_s": ("product", "lab"),
    "restricted": ("lab",),
    "restricted_workspaces": ("lab",),
    # the poll floor is the product's; the process cap a site states (validate keeps the floor >= 60 s)
    "login_node_rules": ("product", "site"),
    "xdg_runtime_fix": ("site",),
    "scheduler_in_worker": ("site",),
    "home_filesystem": ("site",),
    "worker_defaults": ("product", "lab"),
    "notes": ("site", "lab"),
}

# Lists that add up across the layers (the product's $HOME, then the site's, then the lab's volumes);
# every other list a later layer sets replaces the earlier one.
ADDITIVE = ("binds",)
# what no string of a profile, and so of a module, may hold: the shapes of a Claude credential and of
# the way one is made; module_schema publishes it so beethoven-sites refuses such a module before it merges
CREDENTIAL = re.compile(r"(sk-ant-|CLAUDE_CODE_OAUTH_TOKEN=|setup-token)")

# The product's own values, laid down before any module. The sign-in directory Beethoven starts Claude
# Code in and the consent markers beside it are the product's alone; $HOME is every worker's first
# bind; the poll floor is this product's etiquette, and the login node's process cap is not the
# product's to guess, so a site states it; the rest stands until a layer that may set the field does.
PRODUCT = (
    ("schema_version", SCHEMA_VERSION),
    ("ipc_dir", "/dev/shm"),
    ("binds", ["$HOME"]),
    ("claude_config_dir", "$HOME/.beethoven/claude"),
    ("consent_markers", ["$HOME/.beethoven/claude/.beethoven-remote-consent",
                         "$HOME/.beethoven/claude/.ashley-remote-consent"]),
    ("login_abandon_s", 1200),
    ("login_node_rules", {"poll_floor_seconds": 60}),
    ("worker_defaults", {"cpus": 2, "mem": "8G", "hours": 8, "permission_mode": "default", "capacity": 4}),
)

# The keys an object field holds, in the order the composed profile writes them, each with its type
# and whether the composed profile must carry it. Layers merge these objects key by key, so a module's
# misspelt key would otherwise sit beside the product's value and leave it in force; a module may set
# only the keys named here. egress.proxy_env and egress.measured are free below their own key.
SUBFIELDS = {
    "image_store": (("type", IMAGE_TYPES, True), ("path", str, True)),
    "egress": (("class", EGRESS_CLASSES, True), ("proxy_env", "dict", False), ("proxy_module", str, False),
               ("ca_bundle", str, False), ("measured", "dict", False)),
    "login_node_rules": (("max_processes", int, True), ("poll_floor_seconds", int, True)),
    "worker_defaults": (("cpus", int, False), ("mem", str, False), ("hours", int, False),
                        ("permission_mode", str, False), ("capacity", int, False)),
}

# What a module says about itself; none of it reaches the composed profile. A site module's "site" is
# the schema's field of that name; a lab module's "site" names the site it belongs to, and "profile"
# the id of the composed file (profiles/<profile>.json, the name consumers already vendor). An id is
# matched whole (fullmatch: a "$" alone would let a trailing newline through into a file name).
MODULE_KEYS = {"site": ("kind", "module_version"), "lab": ("kind", "module_version", "site", "lab", "profile")}
ID = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
# The framework still finds a deployment's profile by its `site` field (site_values, `connect`'s shared
# copy, the copy's own site, the extension's --profile), so a lab whose profile had another id would be
# served the first lab's values. Until an account keeps only its own choices and names its profile
# (BEE-208), a site has one lab and that lab's profile carries the site's id.
PROFILE_IS_SITE = True


def _type_name(typ):
    return "/".join(typ) if isinstance(typ, tuple) else (typ if isinstance(typ, str) else typ.__name__)


def _owner(key, kind):
    """The words for a module of KIND that sets KEY, which its layer may not set"""
    modules = [layer for layer in FIELD_LAYERS[key] if layer != "product"]
    if not modules:
        return "%s is the product's own value; no module sets it" % key
    return "%s is set by the %s module, not by a %s module" % (key, " or the ".join(modules), kind)


def _copy(value):
    return json.loads(json.dumps(value))


def validate_module(mod, kind):
    """Problems with a site or lab module on its own (empty when it may be composed). Unlike a
    profile, a module refuses a field the schema does not name, or a key inside an object field that
    SUBFIELDS does not: it is written by hand against this version, so an unknown key is a typo,
    never another release's field."""
    if not isinstance(mod, dict):
        return ["the %s module is not a JSON object" % kind]
    errs = []
    if mod.get("kind") != kind:
        errs.append("kind must be %r in a %s module (got %r)" % (kind, kind, mod.get("kind")))
    mv = mod.get("module_version")
    if not (isinstance(mv, int) and not isinstance(mv, bool) and mv >= 1):
        errs.append("module_version must be a whole number from 1 (got %r)" % (mv,))
    ids = ("site",) if kind == "site" else ("site", "lab", "profile")
    for key in ids:
        if not (isinstance(mod.get(key), str) and ID.fullmatch(mod[key])):
            errs.append("%s must be lower-case letters, digits and dashes (got %r)" % (key, mod.get(key)))
    if kind == "lab" and PROFILE_IS_SITE and mod.get("profile") != mod.get("site"):
        errs.append("profile must be %r, the site's id: the framework finds a deployment's profile by its site's id, "
                    "so a site has one lab until BEE-208 (got %r)" % (mod.get("site"), mod.get("profile")))
    types = dict((key, typ) for key, typ, _req, _default, _desc in SCHEMA)
    for key, value in mod.items():
        if key in MODULE_KEYS[kind]:
            continue
        if key not in FIELD_LAYERS:
            errs.append("%s is not a field of this version's profile (hpcworker profile schema lists them)" % key)
            continue
        if kind not in FIELD_LAYERS[key]:
            errs.append(_owner(key, kind))
            continue
        if not _type_ok(types[key], value):
            errs.append("field %s: expected %s, got %r" % (key, _type_name(types[key]), value))
            continue
        subs = dict((name, typ) for name, typ, _req in SUBFIELDS.get(key, ()))
        for sub in value if key in SUBFIELDS else ():
            if sub not in subs:
                errs.append("%s.%s is not a key of %s (it has %s)" % (key, sub, key, ", ".join(n for n, _t, _r in SUBFIELDS[key])))
            elif not _type_ok(subs[sub], value[sub]):
                errs.append("field %s.%s: expected %s, got %r" % (key, sub, _type_name(subs[sub]), value[sub]))
    for key, val in _walk(mod):
        if isinstance(val, str) and CREDENTIAL.search(val):
            errs.append("field %s looks like it carries a credential; a module never does" % key)
    return errs


def _lay(prof, origin, key, value, where):
    """Lay VALUE for KEY over what PROF holds, recording in ORIGIN which layer set each leaf: objects
    merge key by key (keys already there keep their places, new ones follow), an additive list gains
    the entries it lacks, anything else is replaced."""
    def leaves(path, val):
        # a value laid over PATH replaces whatever was recorded there and below it
        for p in [p for p in origin if p[:len(path)] == path]:
            del origin[p]
        record(path, val)

    def record(path, val):
        if isinstance(val, dict) and val:
            for k, v in val.items():
                record(path + (k,), v)
        else:
            origin[path] = where

    def merge(path, old, new):
        if isinstance(old, dict) and isinstance(new, dict):
            out = _copy(old)
            for k, v in new.items():
                out[k] = merge(path + (k,), out[k], v) if k in out else _copy(v)
                if k not in old:
                    leaves(path + (k,), v)
            return out
        leaves(path, new)
        return _copy(new)

    if key in ADDITIVE and isinstance(prof.get(key), list) and isinstance(value, list):
        out = prof[key]
        for item in value:
            if item not in out:
                origin[(key, len(out))] = where
                out.append(_copy(item))
        return
    if key in prof:
        prof[key] = merge((key,), prof[key], value)
    else:
        leaves((key,), value)
        prof[key] = _copy(value)


def compose_layers(site, lab, site_file="site.json", lab_file="lab.json"):
    """(profile, origin) for SITE and LAB, two modules already read: the product's values, then the
    site's, then the lab's, in the schema's key order; ORIGIN maps each leaf's path (a tuple of keys
    and list positions) to (layer, file). Raises ValueError naming every problem, the composed
    profile's own included: a composed profile is read raw by every client, so it must be whole."""
    errs = ["%s: %s" % (site_file, e) for e in validate_module(site, "site")]
    errs += ["%s: %s" % (lab_file, e) for e in validate_module(lab, "lab")]
    if isinstance(site, dict) and isinstance(lab, dict) and site.get("site") != lab.get("site"):
        errs.append("%s: belongs to site %r, not %r" % (lab_file, lab.get("site"), site.get("site")))
    if errs:
        raise ValueError("\n".join(errs))
    prof, origin = {}, {}
    for key, value in PRODUCT:
        _lay(prof, origin, key, value, ("product", "lib/profile.py"))
    for layer, mod, path in (("site", site, site_file), ("lab", lab, lab_file)):
        for key, value in mod.items():
            if key not in MODULE_KEYS[layer]:
                _lay(prof, origin, key, value, (layer, path))
    order = [key for key, _typ, _req, _default, _desc in SCHEMA]
    prof = dict((key, prof[key]) for key in order if key in prof)
    for key, subs in SUBFIELDS.items():
        if isinstance(prof.get(key), dict):
            names = [name for name, _typ, _req in subs]
            value = prof[key]
            prof[key] = dict([(k, value[k]) for k in names if k in value] + [(k, v) for k, v in value.items() if k not in names])
    errs = validate(prof)
    if errs:
        raise ValueError("the profile %s and %s compose is invalid:\n%s" % (site_file, lab_file, "\n".join(errs)))
    return prof, origin


def compose(site, lab, site_file="site.json", lab_file="lab.json"):
    return compose_layers(site, lab, site_file, lab_file)[0]


def profile_text(prof):
    """A composed profile as it is written to profiles/<id>.json: one space of indent, the keys in the
    order given, ASCII, a final newline."""
    return json.dumps(prof, indent=1) + "\n"


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (IOError, OSError, ValueError) as e:
        raise ValueError("%s: could not be read as JSON (%s)" % (path, e))


def _rel(path, root):
    path, root = os.path.abspath(path), os.path.abspath(root)
    return os.path.relpath(path, root).replace(os.sep, "/") if path.startswith(root + os.sep) else path.replace(os.sep, "/")


def _module_tree(root):
    """(site modules, (site.json, lab.json) pairs, problems) under ROOT/sites, sorted: every module is
    read and checked to sit where its ids say (sites/<site>/site.json, sites/<site>/labs/<lab>.json);
    a site folder without its site.json, a file that is not a JSON object and a misplaced module are
    problems, never skipped."""
    sites = os.path.join(root, "sites")
    if not os.path.isdir(sites):
        return [], [], ["%s: no sites folder here (the root is the framework folder, which holds sites/ and profiles/)" % root]
    site_paths, pairs, errs = [], [], []
    for name in sorted(os.listdir(sites)):
        folder = os.path.join(sites, name)
        if not os.path.isdir(folder):
            continue
        site_path = os.path.join(folder, "site.json")
        if not os.path.isfile(site_path):
            errs.append("%s: no site.json" % _rel(folder, root))
            continue
        try:
            site = _read_json(site_path)
        except ValueError as e:
            errs.append(str(e).replace(site_path, _rel(site_path, root)))
            continue
        if not isinstance(site, dict):
            errs.append("%s: the site module is not a JSON object" % _rel(site_path, root))
            continue
        if site.get("site") != name:
            errs.append("%s: its site id must be %r, the folder's name" % (_rel(site_path, root), name))
        site_paths.append(site_path)
        labs = os.path.join(folder, "labs")
        for fn in sorted(os.listdir(labs)) if os.path.isdir(labs) else []:
            if not fn.endswith(".json"):
                continue
            lab_path = os.path.join(labs, fn)
            try:
                lab = _read_json(lab_path)
            except ValueError as e:
                errs.append(str(e).replace(lab_path, _rel(lab_path, root)))
                continue
            if not isinstance(lab, dict):
                errs.append("%s: the lab module is not a JSON object" % _rel(lab_path, root))
                continue
            if lab.get("lab") != fn[:-5] or lab.get("site") != name:
                errs.append("%s: its lab id must be %r and its site %r, as the path says" % (_rel(lab_path, root), fn[:-5], name))
            pairs.append((site_path, lab_path))
    return site_paths, pairs, errs


def modules(root=None):
    """[(site.json, lab.json)] for every lab module under ROOT/sites (the framework tree by default),
    sorted. Raises ValueError naming every misplaced or unreadable module."""
    _sites, pairs, errs = _module_tree(root or code_root())
    if errs:
        raise ValueError("\n".join(errs))
    return pairs


def claimants(root=None):
    """{profile id: [lab module, ...]} for every lab module under ROOT/sites that names one"""
    out = {}
    for _site_path, lab_path in modules(root):
        pid = _read_json(lab_path).get("profile")
        if isinstance(pid, str):
            out.setdefault(pid, []).append(lab_path)
    return out


def compose_all(root=None, check=False):
    """Compose every lab module into ROOT/profiles/<profile>.json (written only where it changed), or
    with CHECK only compare. Returns the problems: a module that is misplaced or does not compose, a
    site module with no lab that does not pass on its own, two modules naming one profile, a file that
    differs (CHECK) and a profile no module names, which is reported and never removed. Nothing is
    written while any module is misplaced, and a profile two modules name is neither written nor
    compared, whichever of them sorts first."""
    root = root or code_root()
    site_paths, pairs, problems = _module_tree(root)
    if problems:
        return problems
    claimed, composed = {}, {}
    for site_path, lab_path in pairs:
        site, lab = _read_json(site_path), _read_json(lab_path)
        if isinstance(lab.get("profile"), str):
            claimed.setdefault(lab["profile"], []).append(_rel(lab_path, root))
        try:
            composed[lab_path] = compose(site, lab, _rel(site_path, root), _rel(lab_path, root))
        except ValueError as e:
            problems.extend(str(e).split("\n"))
    for site_path in site_paths:
        if not any(s == site_path for s, _l in pairs):
            problems += ["%s: %s" % (_rel(site_path, root), e) for e in validate_module(_read_json(site_path), "site")]
    for pid, labs in sorted(claimed.items()):
        if len(labs) > 1:
            problems.append("%s both compose profiles/%s.json" % (" and ".join(labs), pid))
    folder = os.path.join(root, "profiles")
    for site_path, lab_path in pairs:
        if lab_path not in composed:
            continue
        pid = _read_json(lab_path)["profile"]
        if len(claimed[pid]) > 1:
            continue
        target = os.path.join(folder, pid + ".json")
        text = profile_text(composed[lab_path])
        try:
            with open(target, "r", encoding="utf-8", newline="") as fh:
                current = fh.read()
        except (IOError, OSError):
            current = None
        if current == text:
            continue
        if check:
            problems.append("profiles/%s.json %s what %s composes (profile.py compose-all writes it)"
                            % (pid, "is missing," if current is None else "differs from", _rel(lab_path, root)))
            continue
        if not os.path.isdir(folder):
            os.makedirs(folder)
        tmp = target + ".part"
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp, target)
    for fn in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if fn.endswith(".json") and fn[:-5] not in claimed:
            problems.append("profiles/%s: no lab module composes it" % fn)
    return problems


def _type_spec(typ):
    if isinstance(typ, tuple):
        return {"type": "enum", "values": list(typ)}
    return {"type": typ if isinstance(typ, str) else typ.__name__}


def module_schema():
    """What a site or lab module may carry, as data (`profile.py module-schema`): each field's type,
    the layers that may set it, whether the composed profile must carry it, its description and, for an
    object field, the keys it holds; the product's own values, the keys a module says about itself, the
    id pattern (matched against the whole id) and the additive lists. The modules' own repository (beethoven-sites) pins this output and
    checks a module against it without any of this code; validate_module is the same rule here, and
    composing is what hpcworker alone does."""
    fields = {}
    for key, typ, req, _default, desc in SCHEMA:
        spec = _type_spec(typ)
        spec["layers"] = list(FIELD_LAYERS[key])
        # a required field must be in the composed profile: the product's value, or a module's
        spec["required"] = bool(req)
        spec["description"] = desc
        if key in SUBFIELDS:
            spec["keys"] = [dict([("name", name)] + list(_type_spec(typ).items()) + [("required", bool(sreq))])
                            for name, typ, sreq in SUBFIELDS[key]]
        fields[key] = spec
    return {
        "schema_version": SCHEMA_VERSION,
        "layers": list(LAYERS),
        "product": dict((key, _copy(value)) for key, value in PRODUCT),
        "module_keys": dict((kind, list(keys)) for kind, keys in sorted(MODULE_KEYS.items())),
        "id_pattern": ID.pattern,
        "id_match": "whole",
        "profile_is_site": PROFILE_IS_SITE,
        "additive": list(ADDITIVE),
        "refused_values": [{"pattern": CREDENTIAL.pattern, "applies_to": "every string anywhere in a module",
                            "why": "a profile is a settings file and never carries a credential"}],
        "fields": fields,
    }


def layers_lines(prof, origin):
    """`profile.py show --layers`: every value of the composed profile, one leaf a line, with the
    layer and the file that set it, and after them the schema's defaults the profile leaves to the
    reader (layer "default"), the way `spack config blame` shows a configuration's sources."""
    rows = []

    def walk(path, val):
        if isinstance(val, dict) and val:
            for k, v in val.items():
                walk(path + (k,), v)
        elif isinstance(val, list) and val:
            for i, v in enumerate(val):
                walk(path + (i,), v)
        else:
            p = path
            while p and p not in origin:
                p = p[:-1]
            layer, where = origin.get(p, ("?", "?"))
            rows.append((name(path), layer, where, json.dumps(val)))

    def name(path):
        # an object's key may hold a dot (egress.measured's are host names): such a key is quoted
        return ".".join(json.dumps(x) if isinstance(x, str) and re.search(r'[.\s"]', x) else str(x) for x in path)

    for key, val in prof.items():
        walk((key,), val)
    for key, _typ, _req, default, _desc in SCHEMA:
        if key not in prof:
            rows.append((key, "default", "lib/profile.py", json.dumps(default)))
    width = [max(len(r[i]) for r in rows) for i in range(3)]
    return ["%-*s  %-*s  %-*s  %s" % (width[0], r[0], width[1], r[1], width[2], r[2], r[3]) for r in rows]


def shellenv(prof):
    """P_<key>=<value> lines a bash script can eval. Lists become
    space-separated strings; dicts flatten to P_<key>_<sub>. Values are
    shell-quoted; $HOME/$USER are expanded here so bash never evals a profile
    string. Fields this version does not know are left out."""
    lines = []
    known = known_fields()

    def emit(name, val):
        # a nested key such as egress.measured."api.anthropic.com" must still be a bash name
        name = re.sub(r"[^A-Za-z0-9_]", "_", name)
        if isinstance(val, bool):
            val = "true" if val else "false"
        elif val is None:
            val = ""
        elif isinstance(val, list):
            val = " ".join(expand(str(x)) for x in val)
        else:
            val = expand(str(val))
        lines.append("P_%s=%s" % (name, shlex.quote(val)))

    for key, val in prof.items():
        if key not in known:
            continue
        if isinstance(val, dict):
            for sub, sv in val.items():
                if isinstance(sv, dict):
                    for sub2, sv2 in sv.items():
                        emit("%s_%s_%s" % (key, sub, sub2), sv2)
                else:
                    emit("%s_%s" % (key, sub), sv)
        else:
            emit(key, val)
    return "\n".join(lines) + "\n"


# ----------------------------------------------------------------------------
# job template rendering
# ----------------------------------------------------------------------------

def hours_to_time(hours, scheduler):
    hours = int(hours)
    if scheduler == "slurm":
        return "%d-%02d:00:00" % (hours // 24, hours % 24)
    if scheduler == "lsf":
        return "%d:00" % hours
    return "%02d:00:00" % hours  # pbs walltime


def header_lines(prof, m):
    """Scheduler directives for the worker job, from the profile and the run
    settings. Slurm is the tested path; PBS and LSF directives are written
    from the documented options and have not been run on a real cluster."""
    sch = prof["scheduler"]
    acct = prof.get("account") or ""
    if sch == "slurm":
        lines = [
            "#SBATCH --job-name=%s" % m["JOB_NAME"],
            "#SBATCH --partition=%s" % m["PARTITION"],
        ]
        if m.get("QOS"):
            lines.append("#SBATCH --qos=%s" % m["QOS"])
        if acct:
            lines.append("#SBATCH --account=%s" % acct)
        lines += [
            "#SBATCH --nodes=1",
            "#SBATCH --ntasks=1",
            "#SBATCH --cpus-per-task=%s" % m["CPUS"],
            "#SBATCH --mem=%s" % m["MEM"],
            "#SBATCH --time=%s" % m["TIME"],
            # relative to the run directory: hpcworker submits with -D <run dir>
            "#SBATCH --output=slurm_%j.out",
            "#SBATCH --open-mode=append",
            # 120 s warning before the wall time or a preemption, delivered to the batch shell
            "#SBATCH --signal=B:TERM@120",
            "#SBATCH --requeue" if m.get("REQUEUE") == "1" else "#SBATCH --no-requeue",
            # one worker of this name at a time
            "#SBATCH --dependency=singleton",
        ]
        return "\n".join(lines)
    if sch == "pbs":
        # PBS Pro / OpenPBS (documented options; untested on a real PBS site)
        lines = ["#PBS -N %s" % m["JOB_NAME"], "#PBS -q %s" % m["PARTITION"]]
        if acct:
            lines.append("#PBS -A %s" % acct)
        lines += [
            "#PBS -l select=1:ncpus=%s:mem=%s" % (m["CPUS"], m["MEM"].lower().replace("g", "gb")),
            "#PBS -l walltime=%s" % m["TIME"],
            "#PBS -j oe",
            "#PBS -o pbs.out",
            "#PBS -r %s" % ("y" if m.get("REQUEUE") == "1" else "n"),
        ]
        return "\n".join(lines)
    if sch == "lsf":
        # IBM Spectrum LSF (documented options; untested on a real LSF site)
        lines = ["#BSUB -J %s" % m["JOB_NAME"], "#BSUB -q %s" % m["PARTITION"]]
        if acct:
            lines.append("#BSUB -P %s" % acct)
        lines += [
            "#BSUB -n %s" % m["CPUS"],
            "#BSUB -R span[hosts=1]",
            "#BSUB -M %s" % m["MEM"].upper().replace("G", "000"),
            "#BSUB -W %s" % m["TIME"],
            "#BSUB -o lsf_%J.out",
        ]
        if m.get("REQUEUE") == "1":
            lines.append("#BSUB -r")
        return "\n".join(lines)
    raise ValueError("no header template for scheduler %s" % sch)


def egress_exports(prof):
    """Shell lines the job runs so the container sees the site's proxy, and
    only that. Nothing here may set ANTHROPIC_BASE_URL or a credential."""
    eg = prof.get("egress") or {}
    lines = ["# egress class: %s" % eg.get("class", "direct")]
    cls = eg.get("class")
    if cls == "http-proxy-module" and eg.get("proxy_module"):
        lines.append("module load %s 2>/dev/null || echo 'WARN: proxy module %s did not load'" % (shlex.quote(eg["proxy_module"]), eg["proxy_module"]))
    for k, v in (eg.get("proxy_env") or {}).items():
        # only the three proxy variables pass validate(); both cases, as curl and Node differ
        lines.append("export %s=%s %s=%s" % (k.lower(), shlex.quote(str(v)), k.upper(), shlex.quote(str(v))))
    if cls == "direct":
        lines.append("# direct: inherited proxy variables are not overridden; the probe measured this class")
    if cls == "none":
        lines.append("echo 'WARN: egress class none: compute nodes were measured unable to reach api.anthropic.com; Remote Control will not register'")
    if eg.get("ca_bundle"):
        lines.append("export NODE_EXTRA_CA_CERTS=%s" % shlex.quote(eg["ca_bundle"]))
    return "\n".join(lines)


def mapping(prof, overrides=None):
    """The @KEY@ -> value table for jobs/worker.sbatch.tpl."""
    o = dict(overrides or {})
    wd = prof.get("worker_defaults") or {}
    run = o.get("RUN", "worker")
    if not re.match(r"^[A-Za-z0-9_-]{1,32}$", run):
        raise ValueError("run name must be letters, digits, _ or - (got %r)" % run)
    hours = int(o.get("HOURS", wd.get("hours", 8)))
    state_dir = expand(prof["shared_state_dir"])
    run_dir = posixpath.join(state_dir, run)
    partition = o.get("PARTITION") or prof.get("partition_cpu_batch") or prof["partition_cpu"]
    if "QOS" in o:
        qos = o["QOS"]
    elif partition == prof.get("partition_cpu_batch"):
        qos = prof.get("qos_batch", "")
    else:
        qos = prof.get("qos_cpu", "")
    requeue = o.get("REQUEUE", "1" if qos and qos == prof.get("qos_batch") and prof.get("qos_batch") == "requeue" else "0")
    binds = [expand(b) for b in prof.get("binds", [])]
    bind_args = " ".join("-B %s" % shlex.quote(b) for b in binds)
    # the tool's own marker lives under HPCW_HOME, the same directory `hpcworker claude consent`
    # writes to, so an overridden HPCW_HOME still has its consent honoured by the job
    hpcw_home = expand(o.get("HPCW_HOME") or "$HOME/.hpcworker")
    # where the job sources lib/ from: what `hpcworker worker start` passes (the directory its own
    # code is in: a shared copy's numbered directory, or ~/.hpcworker), else the tree this file is in
    hpcw_code = expand(o.get("HPCW_CODE") or code_root())
    markers = [expand(x) for x in prof.get("consent_markers", [])]
    markers.append(posixpath.join(hpcw_home, "consent"))
    chain = str(o.get("CHAIN", "1"))
    if chain not in ("0", "1"):
        raise ValueError("CHAIN must be 0 or 1 (got %r)" % chain)
    m = {
        "VERSION": framework_version(),
        "SITE": prof["site"],
        "SCHEDULER": prof["scheduler"],
        "CHAIN": chain,
        "RUN": run,
        "JOB_NAME": "hpcw_%s" % run,
        "RUN_DIR": run_dir,
        "STATE_DIR": state_dir,
        "WORKSPACE": posixpath.join(state_dir, "workspaces", run),
        "PARTITION": partition,
        "QOS": qos,
        "CPUS": str(o.get("CPUS", wd.get("cpus", 2))),
        "MEM": str(o.get("MEM", wd.get("mem", "8G"))),
        "HOURS": str(hours),
        "TIME": o.get("TIME") or hours_to_time(hours, prof["scheduler"]),
        "REQUEUE": requeue,
        "NODE_TMP": expand(prof["node_tmp"]),
        "NODE_TMP_VAR": prof.get("node_tmp_var", ""),
        "TMPDIR_IS_NODE_LOCAL": "1" if prof.get("tmpdir_is_node_local") else "0",
        "IPC_DIR": prof["ipc_dir"],
        "RUNTIME": prof["runtime"],
        "RUNTIME_BIN": expand(prof.get("runtime_bin", "")),
        "RUNTIME_MODULE": prof.get("runtime_module", ""),
        "IMAGE": expand(prof["image_store"]["path"]),
        "IMAGE_TYPE": prof["image_store"]["type"],
        "CLAUDE_BIN": expand(prof["claude_bin"]),
        "BINDS": bind_args,
        "CLAUDE_CONFIG_DIR": expand(prof["claude_config_dir"]),
        "CONSENT_MARKERS": ":".join(markers),
        "EGRESS_CLASS": (prof.get("egress") or {}).get("class", "direct"),
        "EGRESS_EXPORTS": egress_exports(prof),
        "XDG_FIX": "1" if prof.get("xdg_runtime_fix", True) else "0",
        "SCHED_IN_WORKER": "1" if prof.get("scheduler_in_worker") is True else "0",
        "PERMISSION_MODE": str(o.get("PERMISSION_MODE", wd.get("permission_mode", "default"))),
        "CAPACITY": str(o.get("CAPACITY", wd.get("capacity", 4))),
        "HEARTBEAT_S": str(o.get("HEARTBEAT_S", 30)),
        "AUTH_EVERY_S": str(o.get("AUTH_EVERY_S", 300)),
        # how often a job waiting in need_login asks `claude auth status` again (the panel signs in, then starts or waits)
        "LOGIN_RECHECK_S": str(o.get("LOGIN_RECHECK_S", 60)),
        # the three retries of the first `claude auth status`, this far apart (a credential still being written)
        "AUTH_RETRY_S": str(o.get("AUTH_RETRY_S", 10)),
        # framework 10: Anthropic says a session can be resumed "for about four hours" (was seven days)
        "RESUME_WINDOW_S": str(o.get("RESUME_WINDOW_S", 4 * 3600)),
        # framework 10: a job still waiting for the Claude sign-in this long stops itself and queues no successor
        "LOGIN_ABANDON_S": str(o.get("LOGIN_ABANDON_S", prof.get("login_abandon_s", 1200))),
        # framework 19: a job whose Remote Control has printed no link this long restarts it once, and the second
        # time stops, with Claude Code's last words as the error, and queues no successor
        "REGISTER_TIMEOUT_S": str(o.get("REGISTER_TIMEOUT_S", 600)),
        # framework 10: the session title (status.json "title", Claude Code's --name)
        "TITLE": session_title(prof, run),
        "HPCW_HOME": hpcw_home,
        "HPCW_CODE": hpcw_code,
    }
    m["HEADER"] = header_lines(prof, m)
    for k, v in m.items():
        if k in ("HEADER", "EGRESS_EXPORTS"):
            continue
        if "'" in v or "\n" in v:
            raise ValueError("value for %s may not contain a quote or newline: %r" % (k, v))
    return m


# ----------------------------------------------------------------------------
# the workspace guide: jobs/workspace-guide.md.tpl, the CLAUDE.md a new worker workspace gets
# ----------------------------------------------------------------------------

SCHEDULER_NAMES = {"slurm": "Slurm", "pbs": "PBS", "lsf": "LSF", "sge": "Grid Engine", "htcondor": "HTCondor"}
# the submit command, and a whole submit line run from anywhere (%s is the workspace)
SUBMIT_LINES = {
    "slurm": ("sbatch", "sbatch -D %s job.sh"),
    "pbs": ("qsub", "cd %s && qsub job.sh"),
    "lsf": ("bsub", "cd %s && bsub < job.sh"),
    "sge": ("qsub", "qsub -wd %s job.sh"),
    "htcondor": ("condor_submit", "cd %s && condor_submit job.sub"),
}


def _under(path, folder):
    """PATH is FOLDER or lies inside it (a string test on normalised forward-slash paths)."""
    if not path or not folder:
        return False
    path, folder = posixpath.normpath(path), posixpath.normpath(folder)
    return path == folder or path.startswith(folder.rstrip("/") + "/")


def _bind_inside(bind):
    """A bind as the container sees it: "src:dst[:opts]" -> dst; a plain path -> itself (a Windows
    drive spelling in the tests, C:/..., is a plain path)."""
    m = re.match(r"^(/[^:]*):(/[^:]*)(:[a-z,]*)?$", bind)
    return m.group(2) if m else bind


def guide_data_lines(prof):
    """One Markdown list line per bind, saying what the folder is, from facts the profile already
    carries: the home, the folder holding shared_state_dir (where the workspaces are), the folder
    holding the lab's shared copy, image or claude_bin, or else a folder the profile shares."""
    home = expand("$HOME")
    state_dir = expand(prof["shared_state_dir"])
    lab = [expand(x) for x in (prof.get("shared_install") or "", (prof.get("image_store") or {}).get("path") or "", prof.get("claude_bin") or "") if x]
    lines = []
    for b in prof.get("binds", []) or []:
        p = _bind_inside(expand(b))
        if p == home and _under(state_dir, p):
            what = "the person's home folder, where this workspace is"
        elif p == home:
            what = "the person's home folder; keep it for small files"
        elif _under(state_dir, p):
            what = "the person's folder on the lab's storage, where this workspace is; large inputs and results go here"
        elif any(_under(x, p) for x in lab):
            what = "the lab's shared folder for workers (the container and hpcworker itself); read it, never change it"
        else:
            what = "a folder the site profile shares with workers"
        lines.append("- `%s`: %s." % (p, what))
    return lines or ["- only this workspace: the site profile shares no other folder with workers."]


def guide_scheduling_lines(prof):
    """Markdown list lines: which partitions (queues) and QoS to use, the account, the longest wall
    time, and for Slurm the two rules that cost this lab time (-D for --output, afterany)."""
    sch = prof["scheduler"]
    word = "partition" if sch == "slurm" else "queue"

    def where(part, qos):
        return "%s `%s`%s" % (word, part, ", QoS `%s`" % qos if qos else "")

    cpu, qcpu = prof["partition_cpu"], prof.get("qos_cpu") or ""
    lines = ["- Short and test jobs: %s." % where(cpu, qcpu)]
    batch, qbatch = prof.get("partition_cpu_batch") or "", prof.get("qos_batch") or ""
    if batch and (batch, qbatch) != (cpu, qcpu):
        more = "; a job there can be stopped and started again, so save progress as it goes" if qbatch == "requeue" else ""
        lines.append("- Long jobs: %s%s." % (where(batch, qbatch), more))
    gpus = [g for g in prof.get("partitions_gpu") or [] if g]
    qgpu = prof.get("qos_gpu") or ""
    qgpu_text = ", QoS `%s`" % qgpu if qgpu else ""
    if len(gpus) == 1:
        lines.append("- GPU jobs: %s `%s`%s." % (word, gpus[0], qgpu_text))
    elif gpus:
        lines.append("- GPU jobs: %ss %s, in that order of preference%s." % (word, " or ".join("`%s`" % g for g in gpus), qgpu_text))
    acct = prof.get("account") or ""
    if acct:
        opt = {"slurm": "--account=%s", "pbs": "-A %s", "lsf": "-P %s"}.get(sch)
        lines.append("- Every job names the account `%s`%s." % (acct, " (`%s`)" % (opt % acct) if opt else ""))
    if prof.get("max_walltime"):
        lines.append("- The longest time a job may ask for: `%s`." % prof["max_walltime"])
    if sch == "slurm":
        lines.append("- `#SBATCH --output` is read relative to the folder a job is submitted from; name that folder with `-D`.")
        lines.append("- Chain jobs with `--dependency=afterany:<id>` and read each output yourself; with `afterok`, one failed job leaves the rest waiting for ever.")
        lines.append("- `hpcworker job submit --project <project> --name <name> --class cpu|batch|gpu -- <script>` fills in the partition, QoS, account and output above and keeps each job's id and log; `hpcworker job status --project <project>` reads them back.")
    return lines


def scheduler_in_worker(prof):
    """The profile asks for the host's scheduler client inside the worker's container, and this
    version can bind it there (Slurm only)."""
    return prof.get("scheduler_in_worker") is True and prof.get("scheduler") == "slurm"


def guide_submitting_lines(prof, submit, terminal):
    """Markdown list lines on reaching the scheduler from inside the worker. Without
    scheduler_in_worker, the one line every version since 8 has written: check first, else hand the
    script to the person. With it: the client is here, what a submitted job is, the fallback when
    a piece was missing on the node, what not to cancel, and the lab's rule for containers in jobs."""
    ask = "write the job script into this workspace and ask the person to submit it from a terminal on the cluster%s." % terminal
    if not scheduler_in_worker(prof):
        return ["- Check first with `command -v %s`: this container may not carry the scheduler's commands. If it does not, %s" % (submit, ask)]
    lines = [
        "- The cluster's own Slurm commands work in here: `sbatch`, `squeue`, `sacct`, `scancel` and `sinfo` (also in `/opt/hpcw/slurm/bin`). A job you submit runs on the cluster outside this container, with the person's usual environment, and keeps running when this worker's job ends.",
        "- If `command -v sbatch` finds nothing, this node lacked a piece when the worker started (the worker's log says which): %s" % ask,
        "- Cancel only jobs you submitted, by their id (`scancel <id>`); never `scancel -u` or a name pattern, and never this worker's own job (`$HPCW_JOB`).",
    ]
    if prof.get("runtime") in ("apptainer", "singularity"):
        lines.append("- A job that runs a container keeps the runtime's temporary and cache folders (`APPTAINER_TMPDIR`, `APPTAINER_CACHEDIR`) on the node's local disk inside that job, and removes them at its end.")
    return lines


def guide_mapping(prof, overrides=None):
    """The @KEY@ -> value table for jobs/workspace-guide.md.tpl. Plain words for a person and for
    Claude Code; the multi-line values (SCHEDULING, DATA) are whole Markdown list lines. Nothing here
    is a credential: paths, partition names and sentences only."""
    o = dict(overrides or {})
    run = o.get("RUN", "worker")
    if not re.match(r"^[A-Za-z0-9_-]{1,32}$", run):
        raise ValueError("run name must be letters, digits, _ or - (got %r)" % run)
    sch = prof["scheduler"]
    workspace = posixpath.join(expand(prof["shared_state_dir"]), "workspaces", run)
    submit, line = SUBMIT_LINES.get(sch, ("the scheduler's submit command", "submit job.sh from %s"))
    name = prof.get("display_name") or "%s cluster" % prof["site"]
    if not name.lower().startswith("the "):
        name = "the " + name
    portal = prof.get("ood_base_url") or ""
    host = prof.get("submit_host") or ""
    terminal = " (for example the shell in the portal, %s)" % portal if portal else ""
    poll = str((prof.get("login_node_rules") or {}).get("poll_floor_seconds", 60))
    # a line of its own under "Handing results back" only where Claude Code can submit jobs itself;
    # it carries its own line break so the section is unchanged elsewhere
    results = ""
    if scheduler_in_worker(prof):
        results = ("\n- A job you submitted: have it write its output and results under this workspace (`#SBATCH --output` too, submitted with `-D`),"
                   " follow it with `squeue -j <id>` or `sacct -j <id>` at most once every %s seconds, then read what it wrote and tell the person what came out and where." % poll)
    return {
        "VERSION": framework_version(),
        "SITE": prof["site"],
        "RUN": run,
        "CLUSTER": name,
        "SCHEDULER_NAME": SCHEDULER_NAMES.get(sch, sch),
        "WORKSPACE": workspace,
        "SUBMIT": submit,
        "SUBMIT_EXAMPLE": line % workspace,
        "SUBMITTING": "\n".join(guide_submitting_lines(prof, submit, terminal)),
        "JOB_RESULTS": results,
        "LOGIN_NODE": " (`%s`)" % host if host else "",
        "POLL_S": poll,
        "SCHEDULING": "\n".join(guide_scheduling_lines(prof)),
        "IPC": expand(posixpath.join(prof["ipc_dir"], "$USER")),
        "DATA": "\n".join(guide_data_lines(prof)),
        "CLAUDE_CONFIG_DIR": expand(prof["claude_config_dir"]),
    }


def render(template_text, m):
    def sub(match):
        key = match.group(1)
        if key not in m:
            raise KeyError("unresolved placeholder @%s@" % key)
        return m[key]
    out = PLACEHOLDER.sub(sub, template_text)
    left = PLACEHOLDER.findall(out)
    if left:
        raise KeyError("placeholders left after rendering: %s" % ", ".join(sorted(set(left))))
    return out


# ----------------------------------------------------------------------------
# a seed profile from phase-1 discovery (the probe job corrects it)
# ----------------------------------------------------------------------------

def from_discovery(d, site="mysite"):
    prof = defaults()
    prof["site"] = site
    prof["display_name"] = ""
    prof["scheduler"] = (d.get("scheduler") or {}).get("family") or "slurm"
    prof["submit_host"] = d.get("host", "")
    parts = [p for p in d.get("partitions", []) if p.get("avail", "up") == "up"]
    default_part = ""
    for p in parts:
        if p.get("default"):
            default_part = p["name"]
            break
    if not default_part and parts:
        default_part = parts[0]["name"]
    prof["partition_cpu"] = default_part or "REPLACE_ME"
    prof["partition_cpu_batch"] = default_part
    prof["partitions_gpu"] = [p["name"] for p in parts if re.search(r"gpu|g[a-z]*p$", p["name"])]
    prof["qos_cpu"] = ""
    prof["qos_batch"] = ""
    rt = d.get("runtime") or {}
    cands = rt.get("candidates") or []
    mods = rt.get("modules") or []
    if cands:
        prof["runtime"] = "singularity" if cands[0]["name"] == "singularity" else cands[0]["name"]
        prof["runtime_bin"] = cands[0]["path"]
    elif mods:
        prof["runtime"] = "singularity" if mods[0].startswith("singularity") else mods[0].split("/")[0]
        prof["runtime_module"] = mods[0]
    else:
        prof["runtime"] = "apptainer"
    if rt.get("pyxis"):
        prof["notes"] = "srun --container-image (Pyxis) is available; the pyxis runtime is not implemented yet"
    env = d.get("env") or {}
    if env.get("SLURM_TMPDIR"):
        prof["node_tmp_var"] = "SLURM_TMPDIR"
        prof["node_tmp"] = "$SLURM_TMPDIR/$USER/hpcworker_$HPCW_JOB_ID"
    else:
        # $TMPDIR is not trusted until the probe shows it is local to the node
        prof["node_tmp"] = "/tmp/$USER/hpcworker_$HPCW_JOB_ID"
    prof["shared_state_dir"] = "$HOME/hpcworker"
    home_fs = d.get("home_fs", "")
    prof["home_filesystem"] = home_fs
    sif_better = home_fs.lower() in ("panfs", "lustre", "gpfs", "beegfs")
    prof["image_store"] = {"type": "sif" if sif_better else "sandbox", "path": "$HOME/hpcworker/images/claude-node22.sif" if sif_better else "$HOME/hpcworker/images/claude-node22"}
    prof["claude_bin"] = "/usr/local/bin/claude"
    prof["binds"] = ["$HOME"]
    prof["claude_config_dir"] = "$HOME/.claude"
    prof["consent_markers"] = []
    proxy = {}
    for k in ("https_proxy", "no_proxy"):
        if env.get(k):
            proxy[k] = env[k]
    prof["egress"] = {"class": "http-proxy-auto" if proxy else "direct", "proxy_env": proxy, "proxy_module": "", "ca_bundle": "", "measured": {}}
    prof["login_node_rules"] = {"max_processes": 20, "poll_floor_seconds": 60}
    prof["xdg_runtime_fix"] = True
    prof["notes"] = (prof.get("notes", "") + " seeded from discovery on %s; run hpcworker probe and fix partition, QoS, image and egress" % d.get("host", "?")).strip()
    return prof


# ----------------------------------------------------------------------------

def consent_flags(config_dir, workspace=""):
    """The two booleans Claude Code itself records in <config dir>/.claude.json:
    remoteDialogSeen (the student answered "Enable Remote Control?") and
    projects[workspace].hasTrustDialogAccepted. Nothing else in that file is
    looked at or returned; an unreadable or unparseable file reads as
    (False, False)."""
    seen = trusted = False
    try:
        with open(os.path.join(expand(config_dir), ".claude.json")) as fh:
            j = json.load(fh)
        if isinstance(j, dict):
            seen = j.get("remoteDialogSeen") is True
            proj = (j.get("projects") or {}).get(workspace) if workspace else None
            trusted = isinstance(proj, dict) and proj.get("hasTrustDialogAccepted") is True
    except (OSError, ValueError):
        pass
    return seen, trusted


def _kv_args(args):
    out = {}
    for a in args:
        if "=" not in a:
            raise SystemExit("expected KEY=VALUE, got %r" % a)
        k, v = a.split("=", 1)
        out[k] = v
    return out


def _utf8_stdout():
    """Text on stdout as UTF-8, whatever the locale: a plain ssh leaves LANG unset, and python 3.6
    would then refuse any character outside ASCII (framework 10's session title for a worker not
    named "worker" carries a middle dot). Newlines stay LF."""
    enc = (getattr(sys.stdout, "encoding", "") or "").lower().replace("-", "").replace("_", "")
    if enc != "utf8" and hasattr(sys.stdout, "buffer"):
        import io
        sys.stdout.flush()
        sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", newline="\n")


def _emit(text, stream=None):
    """TEXT as UTF-8 bytes with its LF newlines: a Windows console's text mode would write CRLF, and a
    path python decoded with surrogateescape (a plain ssh's C locale) goes out as the bytes it was."""
    stream = stream or sys.stdout
    stream.flush()
    stream.buffer.write(text.encode("utf-8", "surrogateescape"))
    stream.flush()


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    _utf8_stdout()
    cmd = argv[1]
    if cmd == "schema":
        for key, typ, req, default, desc in SCHEMA:
            want = "/".join(typ) if isinstance(typ, tuple) else (typ if isinstance(typ, str) else typ.__name__)
            print("%-22s %-28s %s%s" % (key, want, "required. " if req else "", desc))
        return 0
    if cmd == "from-discovery":
        with open(argv[2], encoding="utf-8") as fh:
            d = json.load(fh)
        prof = from_discovery(d, argv[3] if len(argv) > 3 else "mysite")
        json.dump(prof, sys.stdout, indent=1, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if cmd == "consent":
        seen, trusted = consent_flags(argv[2], argv[3] if len(argv) > 3 else "")
        print("remote_dialog_seen=%s workspace_trusted=%s" % (str(seen).lower(), str(trusted).lower()))
        return 0
    if cmd == "render":
        # the template carries a few non-ASCII marks ("Connected ·"); read as UTF-8 whatever the locale
        with open(argv[2], encoding="utf-8") as fh:
            tpl = fh.read()
        prof = load(argv[3])
        errs = validate(prof)
        if errs:
            sys.stderr.write("profile invalid:\n  " + "\n  ".join(errs) + "\n")
            return 1
        if unknown_fields(prof):
            sys.stderr.write("profile: %s\n" % unknown_note(prof))
        sys.stdout.write(render(tpl, mapping(prof, _kv_args(argv[4:]))))
        return 0
    if cmd == "guide":
        # the template is ASCII; read and written as UTF-8 all the same, whatever locale a plain ssh left
        with open(argv[2], encoding="utf-8") as fh:
            tpl = fh.read()
        prof = load(argv[3])
        errs = validate(prof)
        if errs:
            sys.stderr.write("profile invalid:\n  " + "\n  ".join(errs) + "\n")
            return 1
        text = render(tpl, guide_mapping(prof, _kv_args(argv[4:])))
        sys.stdout.flush()
        sys.stdout.buffer.write(text.encode("utf-8"))
        return 0
    if cmd == "compose":
        if len(argv) != 4:
            raise SystemExit("usage: profile.py compose <site.json> <lab.json>")
        try:
            prof = compose(_read_json(argv[2]), _read_json(argv[3]), argv[2], argv[3])
        except ValueError as e:
            _emit("refusing:\n  %s\n" % str(e).replace("\n", "\n  "), sys.stderr)
            return 1
        _emit(profile_text(prof))
        return 0
    if cmd == "module-schema":
        _emit(json.dumps(module_schema(), indent=1) + "\n")
        return 0
    if cmd == "compose-all":
        args, root = argv[2:], None
        if "--root" in args:
            i = args.index("--root")
            if i + 1 >= len(args) or args[i + 1].startswith("-"):
                raise SystemExit("usage: profile.py compose-all [--check] [--root <framework dir>]")
            root = args[i + 1]
            del args[i:i + 2]
        if args not in ([], ["--check"]):
            raise SystemExit("usage: profile.py compose-all [--check] [--root <framework dir>]")
        problems = compose_all(root, check=bool(args))
        _emit("".join("ERROR: %s\n" % p for p in problems) or "ok: every profile is what its modules compose\n")
        return 1 if problems else 0
    if cmd == "show" and len(argv) > 2 and argv[2] == "--layers":
        # show --layers <id> (a profile the checkout's modules compose) | show --layers <site.json> <lab.json>
        try:
            if len(argv) == 5:
                site_path, lab_path = argv[3], argv[4]
            elif len(argv) == 4:
                labs = claimants().get(argv[3], [])
                if not labs:
                    _emit("no lab module under %s composes the profile %s\n" % (os.path.join(code_root(), "sites"), argv[3]), sys.stderr)
                    return 1
                if len(labs) > 1:
                    _emit("refusing: %s all name the profile %s (profile.py compose-all reports it)\n"
                          % (", ".join(_rel(l, code_root()) for l in labs), argv[3]), sys.stderr)
                    return 1
                lab_path = labs[0]
                site_path = os.path.join(os.path.dirname(os.path.dirname(lab_path)), "site.json")
            else:
                raise SystemExit("usage: profile.py show --layers <id> | show --layers <site.json> <lab.json>")
            root = code_root()
            prof, origin = compose_layers(_read_json(site_path), _read_json(lab_path), _rel(site_path, root), _rel(lab_path, root))
        except ValueError as e:
            _emit("refusing:\n  %s\n" % str(e).replace("\n", "\n  "), sys.stderr)
            return 1
        _emit("\n".join(layers_lines(prof, origin)) + "\n")
        return 0
    path = argv[2] if len(argv) > 2 else None
    if not path:
        raise SystemExit("profile path required")
    prof = load(path)
    if cmd == "validate":
        errs = validate(prof)
        for e in errs:
            print("ERROR: " + e)
        if not errs:
            note = unknown_note(prof)
            print("ok: %s (%s, %s)%s" % (prof.get("site"), prof.get("scheduler"), prof.get("runtime"), "; " + note if note else ""))
        return 1 if errs else 0
    if cmd == "get":
        v = get(prof, argv[3])
        if isinstance(v, (dict, list)):
            print(json.dumps(v))
        elif isinstance(v, bool):
            print("true" if v else "false")
        elif v is None:
            print("")
        else:
            print(expand(str(v)))
        return 0
    if cmd == "shellenv":
        sys.stdout.write(shellenv(prof))
        return 0
    if cmd == "show":
        json.dump(prof, sys.stdout, indent=1, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    if cmd == "set":
        raw = argv[4]
        try:
            val = json.loads(raw)
        except ValueError:
            val = raw
        # a field already in the file that this version does not know is tolerated; adding one is a typo until proven otherwise
        top = argv[3].split(".")[0]
        if top not in known_fields():
            sys.stderr.write("refusing: %s is not a field of this version's profile (hpcworker profile schema lists them)\n" % top)
            return 1
        set_key(prof, argv[3], val)
        errs = validate(prof)
        if errs:
            sys.stderr.write("refusing: the change makes the profile invalid:\n  " + "\n  ".join(errs) + "\n")
            return 1
        # a field the site supplies stays out of the account's file (neither the site's value nor the
        # schema's default is written there) until the account sets it: a later publish still reaches it
        with open(path, "r", encoding="utf-8") as fh:
            own = json.load(fh)
        for key in FIELDS_FROM_SITE:
            if key != top and isinstance(own, dict) and key not in own:
                prof.pop(key, None)
        save(prof, path)
        print("set %s" % argv[3])
        return 0
    if cmd == "mapping":
        json.dump(mapping(prof, _kv_args(argv[3:])), sys.stdout, indent=1, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    sys.stderr.write("unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
