#!/usr/bin/env python3
"""hpcworker site profile: schema, load/validate, render helpers.

One JSON file per university describes everything the job templates need to
know about a cluster. It is seeded by hand (profiles/<site>.json) or by
`hpcworker discover`, and corrected by the probe job. Only the standard library
is used, and only syntax that Python 3.6 accepts: the login node this was
written against runs CentOS 7, whose system python3 is 3.6.

Command line (used by bin/hpcworker; nothing here runs a container or talks to
a scheduler):
    profile.py validate <profile>
    profile.py get <profile> <dotted.key>
    profile.py shellenv <profile>                 # P_key=value lines for bash eval
    profile.py show <profile>
    profile.py set <profile> <dotted.key> <json-or-string>
    profile.py from-discovery <discover.json> [site]   # a seed profile on stdout
    profile.py render <template> <profile> KEY=VALUE...  # rendered text on stdout
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


# key -> (type, required, default, description). "type" is a python type, a
# tuple of allowed strings, or "list"/"dict"/"int_or_none"/"bool_or_none".
SCHEMA = [
    ("schema_version", int, True, SCHEMA_VERSION, "profile schema version (integer)"),
    ("site", str, True, None, "short site id used in session names, e.g. wayne"),
    ("email_domain", str, False, "", "the institution's e-mail domain (a site licence names it; the panel binds a domain key to it)"),
    ("display_name", str, False, "", "the university's name for messages"),
    ("scheduler", ("slurm", "pbs", "lsf", "sge", "htcondor"), True, None, "scheduler family"),
    ("submit_host", str, False, "", "login node the scheduler client runs on"),
    ("bin_dir", str, False, "", "scheduler client directory, when not on PATH"),
    ("partition_cpu", str, True, None, "CPU partition for interactive and test work"),
    ("qos_cpu", str, False, "", "QoS for partition_cpu"),
    ("partition_cpu_batch", str, False, "", "CPU partition for long workers"),
    ("qos_batch", str, False, "", "QoS for partition_cpu_batch"),
    ("partitions_gpu", "list", False, [], "GPU partitions, in order of preference"),
    ("account", str, False, "", "allocation account, when the site needs one"),
    ("max_walltime", str, False, "", "longest wall time the CPU partition accepts"),
    ("node_tmp", str, True, None, "node-local temp pattern; $USER and $SLURM_JOB_ID/$HPCW_JOB_ID expand in the job"),
    ("node_tmp_var", str, False, "", "variable that names node-local temp when the site sets one (SLURM_TMPDIR, L_SCRATCH); empty = none trusted"),
    ("tmpdir_is_node_local", bool, False, False, "whether $TMPDIR may be trusted as node-local (false on Wayne State: it is CephFS)"),
    ("ipc_dir", str, True, "/dev/shm", "where sockets and pipes go (never a swept /tmp)"),
    ("shared_state_dir", str, True, None, "shared storage for run directories; $HOME and $USER expand"),
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
    ("vpn_required", bool, False, False, "portal and login node need the VPN"),
    ("login_node_rules", "dict", True, {"max_processes": 20, "poll_floor_seconds": 60}, "{max_processes, poll_floor_seconds}"),
    ("xdg_runtime_fix", bool, False, True, "point XDG_RUNTIME_DIR at ipc_dir/$USER/xdg for Claude Code's bash tool"),
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
    if isinstance(typ, tuple):
        return isinstance(value, str) and value in typ
    if typ is int:
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, typ)


def validate(prof):
    """Return a list of problems (empty when the profile is usable)."""
    errs = []
    if not isinstance(prof, dict):
        return ["profile is not a JSON object"]
    known = set()
    for key, typ, required, _default, _desc in SCHEMA:
        known.add(key)
        if key not in prof:
            if required:
                errs.append("missing required field: %s" % key)
            continue
        if not _type_ok(typ, prof[key]):
            want = "/".join(typ) if isinstance(typ, tuple) else (typ if isinstance(typ, str) else typ.__name__)
            errs.append("field %s: expected %s, got %r" % (key, want, prof[key]))
    for key in prof:
        if key not in known:
            errs.append("unknown field: %s" % key)
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
    if isinstance(prof.get("site"), str) and not re.match(r"^[a-z0-9][a-z0-9-]{0,31}$", prof["site"]):
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
    # bind specs travel through a job file as one space-separated string
    for b in prof.get("binds", []) or []:
        if not isinstance(b, str) or re.search(r"\s", b) or not b:
            errs.append("binds entries must be non-empty paths without whitespace (got %r)" % (b,))
    # a profile is a settings file: it must never carry a credential
    for key, val in _walk(prof):
        if isinstance(val, str) and re.search(r"(sk-ant-|CLAUDE_CODE_OAUTH_TOKEN=|setup-token)", val):
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


def load(path):
    with open(path, "r") as fh:
        prof = json.load(fh)
    merged = defaults()
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
    with open(tmp, "w") as fh:
        json.dump(prof, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def shellenv(prof):
    """P_<key>=<value> lines a bash script can eval. Lists become
    space-separated strings; dicts flatten to P_<key>_<sub>. Values are
    shell-quoted; $HOME/$USER are expanded here so bash never evals a profile
    string."""
    lines = []

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
        "PERMISSION_MODE": str(o.get("PERMISSION_MODE", wd.get("permission_mode", "default"))),
        "CAPACITY": str(o.get("CAPACITY", wd.get("capacity", 4))),
        "HEARTBEAT_S": str(o.get("HEARTBEAT_S", 30)),
        "AUTH_EVERY_S": str(o.get("AUTH_EVERY_S", 300)),
        # how often a job waiting in need_login asks `claude auth status` again (the panel signs in, then starts or waits)
        "LOGIN_RECHECK_S": str(o.get("LOGIN_RECHECK_S", 60)),
        "RESUME_WINDOW_S": str(o.get("RESUME_WINDOW_S", 4 * 3600)),
        "HPCW_HOME": hpcw_home,
    }
    m["HEADER"] = header_lines(prof, m)
    for k, v in m.items():
        if k in ("HEADER", "EGRESS_EXPORTS"):
            continue
        if "'" in v or "\n" in v:
            raise ValueError("value for %s may not contain a quote or newline: %r" % (k, v))
    return m


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


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "schema":
        for key, typ, req, default, desc in SCHEMA:
            want = "/".join(typ) if isinstance(typ, tuple) else (typ if isinstance(typ, str) else typ.__name__)
            print("%-22s %-28s %s%s" % (key, want, "required. " if req else "", desc))
        return 0
    if cmd == "from-discovery":
        with open(argv[2]) as fh:
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
        with open(argv[2]) as fh:
            tpl = fh.read()
        prof = load(argv[3])
        errs = validate(prof)
        if errs:
            sys.stderr.write("profile invalid:\n  " + "\n  ".join(errs) + "\n")
            return 1
        sys.stdout.write(render(tpl, mapping(prof, _kv_args(argv[4:]))))
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
            print("ok: %s (%s, %s)" % (prof.get("site"), prof.get("scheduler"), prof.get("runtime")))
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
        set_key(prof, argv[3], val)
        errs = validate(prof)
        if errs:
            sys.stderr.write("refusing: the change makes the profile invalid:\n  " + "\n  ".join(errs) + "\n")
            return 1
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
