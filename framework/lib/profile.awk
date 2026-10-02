# lib/profile.awk: the site profile for bin/hpcworker on the login node, with no python3 (framework 11).
#
# warrior's banner bans python3 by name ("terminated on sight"), and Beethoven 12's ssh path runs this
# tool there by itself, so what lib/profile.py did on that path is done here instead: the profile read
# as JSON, merged with the schema's defaults and the site's values, checked, and handed to bash. POSIX
# awk only (gawk 4.0 on EL7, gawk 5, mawk 1.3.4), run with LC_ALL=C, so every string is bytes.
# lib/profile.py stays the reference and the tool for a person at a terminal (profile show, set,
# validate, schema; discover's seed). tests/test_profile_awk.py holds the two to the same answers:
# the same P_ variables, the same verdict on every profile in the tests, the same job file and the same
# workspace guide, byte for byte.
#
#   LC_ALL=C awk -f profile.awk < /dev/null, with in the environment:
#     HPCW_P_MODE     env    the profile as shell assignments for bash to eval: P_<key>=<value>, exactly
#                            what `profile.py shellenv` prints, then HPCW_PV_errors and HPCW_PV_note (what
#                            `profile.py validate` would say) and, for a valid profile, the HPCW_M_* and
#                            HPCW_G_* values the job file and the workspace guide are filled from
#                     check  `profile.py validate`'s lines: "ERROR: ..." per problem, else "ok: ...";
#                            exit 1 when there is a problem
#                     get    `profile.py get FILE KEY`: one value, $HOME and $USER expanded
#     HPCW_P_FILE     the profile (an account's profile.json, or a site profile)
#     HPCW_P_SITEDIR  this copy's profiles/ folder (the values a site supplies, profile.py site_values)
#     HPCW_P_KEY      get: the dotted key
#     HOME, USER      expanded in values as profile.py expand() does, and nothing else
#   Exit 3, with one line on stderr, when the file cannot be read or is not JSON.
#
# Every value bash evals is shell-quoted here (shlex.quote's rule) and every name is [A-Za-z0-9_]: bash
# never evals a string from the profile. Known differences from python, all on profiles no site has: a
# repeated key is taken as python takes it (the last value, the first place) but a \u0000 in a string,
# NaN and Infinity are refused rather than read; a value nested three objects deep, which no variable
# hpcworker reads holds, is printed as python's repr only for plain values.

function fail_read(why) { print "hpcworker: " ENVIRON["HPCW_P_FILE"] " " why > "/dev/stderr"; exit 3 }

# ---- the schema: profile.py SCHEMA, in its order (key, type, required, default as JSON; "" = None) ----
function sadd(k, t, r, d) { NSC++; SCK[NSC] = k; SCT[NSC] = t; SCR[NSC] = r; SCD[NSC] = d; SCI[k] = NSC }
function schema_init() {
  sadd("schema_version", "int", 1, "1")
  sadd("site", "str", 1, "")
  sadd("display_name", "str", 0, "\"\"")
  sadd("scheduler", "enum:slurm,pbs,lsf,sge,htcondor", 1, "")
  sadd("submit_host", "str", 0, "\"\"")
  sadd("bin_dir", "str", 0, "\"\"")
  sadd("partition_cpu", "str", 1, "")
  sadd("qos_cpu", "str", 0, "\"\"")
  sadd("partition_cpu_batch", "str", 0, "\"\"")
  sadd("qos_batch", "str", 0, "\"\"")
  sadd("partitions_gpu", "list", 0, "[]")
  sadd("account", "str", 0, "\"\"")
  sadd("max_walltime", "str", 0, "\"\"")
  sadd("node_tmp", "str", 1, "")
  sadd("node_tmp_var", "str", 0, "\"\"")
  sadd("tmpdir_is_node_local", "bool", 0, "false")
  sadd("ipc_dir", "str", 1, "\"/dev/shm\"")
  sadd("shared_state_dir", "str", 1, "")
  sadd("shared_install", "str", 0, "\"\"")
  sadd("runtime", "enum:apptainer,singularity,podman,pyxis", 1, "")
  sadd("runtime_module", "str", 0, "\"\"")
  sadd("runtime_bin", "str", 0, "\"\"")
  sadd("image_store", "dict", 1, "")
  sadd("claude_bin", "str", 1, "")
  sadd("binds", "list", 0, "[]")
  sadd("cache_dir", "str", 0, "\"\"")
  sadd("fakeroot_rung", "int_or_none", 0, "")
  sadd("egress", "dict", 1, "")
  sadd("claude_config_dir", "str", 1, "")
  sadd("consent_markers", "list", 0, "[]")
  sadd("ood_base_url", "str", 0, "\"\"")
  sadd("ood_shell_host", "str", 0, "\"\"")
  sadd("ood_rnode_enabled", "bool_or_none", 0, "")
  sadd("ood_auth", "enum:,http-basic,cookie", 0, "\"\"")
  sadd("vpn_required", "bool", 0, "false")
  sadd("vpn_portal", "str", 0, "\"\"")
  sadd("vpn_app", "str", 0, "\"\"")
  sadd("vpn_help_url", "str", 0, "\"\"")
  sadd("grid_account_help_url", "str", 0, "\"\"")
  sadd("grid_2fa_help_url", "str", 0, "\"\"")
  sadd("ssh_host", "str", 0, "\"\"")
  sadd("ssh_port", "int", 0, "22")
  sadd("ssh_host_key", "str", 0, "\"\"")
  sadd("ssh_relay", "str_or_none", 0, "")
  sadd("browser_key_days", "int_or_none", 0, "")
  sadd("session_title", "str", 0, "\"\"")
  sadd("login_abandon_s", "int", 0, "1200")
  sadd("restricted", "bool", 0, "false")
  sadd("restricted_workspaces", "list", 0, "[]")
  sadd("login_node_rules", "dict", 1, "{\"max_processes\":20,\"poll_floor_seconds\":60}")
  sadd("xdg_runtime_fix", "bool", 0, "true")
  sadd("scheduler_in_worker", "bool", 0, "false")
  sadd("home_filesystem", "str", 0, "\"\"")
  sadd("worker_defaults", "dict", 0, "{\"cpus\":2,\"mem\":\"8G\",\"hours\":8,\"permission_mode\":\"default\",\"capacity\":4}")
  sadd("notes", "str", 0, "\"\"")
  # profile.py FIELDS_FROM_SITE: a field a later version added takes the site profile's value until the account sets its own
  NFS = split("scheduler_in_worker session_title login_abandon_s ood_auth vpn_portal vpn_app vpn_help_url grid_account_help_url restricted restricted_workspaces grid_2fa_help_url ssh_host ssh_port ssh_host_key ssh_relay browser_key_days", FSK, " ")
}

# ---- JSON, read whole into node tables -----------------------------------------------------------
# NT[id] o a s n t f z (object, array, string, number, true, false, null); NV[id] a string's decoded bytes
# or a number's text; NN[id] children, NK[id,i] the i-th child's key (an array's: "0", "1", ...), NC[id,i]
# its node, NI[id,key] its place. A repeated key keeps its first place and takes the last value (python).
function readfile(f,   s, line, r) {
  s = ""
  while ((r = (getline line < f)) > 0) s = s line "\n"
  if (r < 0) return "\001"
  close(f)
  return s
}
function jparse(text,   r) {
  JS = text; JP = 1; JL = length(text); JWHY = ""; JBAD = 0
  r = jval(0)
  if (!r) return 0
  jws()
  if (JP <= JL) { JWHY = "extra data after the value"; return 0 }
  return r
}
function jws(   c) { while (JP <= JL) { c = substr(JS, JP, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") JP++; else return } }
function jnew(t, v) { NID++; NT[NID] = t; NV[NID] = v; NN[NID] = 0; return NID }
function jadd(p, k, c,   i) {
  if ((p, k) in NI) { NC[p, NI[p, k]] = c; return }
  i = ++NN[p]; NK[p, i] = k; NC[p, i] = c; NI[p, k] = i
}
function jval(depth,   c, id, k, v, t, n) {
  if (depth > 64) { JWHY = "nested too deeply"; return 0 }
  jws()
  if (JP > JL) { JWHY = "ends too early"; return 0 }
  c = substr(JS, JP, 1)
  if (c == "{") {
    JP++; id = jnew("o", ""); jws()
    if (substr(JS, JP, 1) == "}") { JP++; return id }
    while (1) {
      jws()
      if (substr(JS, JP, 1) != "\"") { JWHY = "has a key that is not a string"; return 0 }
      k = jstr(); if (JBAD) return 0
      jws()
      if (substr(JS, JP, 1) != ":") { JWHY = "lacks a colon after a key"; return 0 }
      JP++
      v = jval(depth + 1); if (!v) return 0
      jadd(id, k, v)
      jws(); c = substr(JS, JP, 1); JP++
      if (c == "}") return id
      if (c != ",") { JWHY = "lacks a comma or a closing brace"; return 0 }
    }
  }
  if (c == "[") {
    JP++; id = jnew("a", ""); jws()
    if (substr(JS, JP, 1) == "]") { JP++; return id }
    n = 0
    while (1) {
      v = jval(depth + 1); if (!v) return 0
      jadd(id, n "", v); n++
      jws(); c = substr(JS, JP, 1); JP++
      if (c == "]") return id
      if (c != ",") { JWHY = "lacks a comma or a closing bracket"; return 0 }
    }
  }
  if (c == "\"") { v = jstr(); if (JBAD) return 0; return jnew("s", v) }
  if (substr(JS, JP, 4) == "true") { JP += 4; return jnew("t", "") }
  if (substr(JS, JP, 5) == "false") { JP += 5; return jnew("f", "") }
  if (substr(JS, JP, 4) == "null") { JP += 4; return jnew("z", "") }
  t = substr(JS, JP, 400)
  if (match(t, /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) { JP += RLENGTH; return jnew("n", substr(t, 1, RLENGTH)) }
  JWHY = "has something that is not a JSON value"
  return 0
}
function hex4(s,   i, d, v) {
  if (length(s) != 4) return -1
  v = 0
  for (i = 1; i <= 4; i++) { d = index("0123456789abcdef", tolower(substr(s, i, 1))) - 1; if (d < 0) return -1; v = v * 16 + d }
  return v
}
function utf8(cp) {
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
function jstr(   t, raw, out, i, c, cp, lo) {
  JBAD = 0
  t = substr(JS, JP)
  if (!match(t, /^"([^"\\]|\\.)*"/)) { JBAD = 1; JWHY = "has a string that does not end"; return "" }
  JP += RLENGTH
  raw = substr(t, 2, RLENGTH - 2)
  if (raw ~ /[\001-\037]/) { JBAD = 1; JWHY = "has a control character inside a string"; return "" }
  if (index(raw, "\\") == 0) return raw
  out = ""
  while ((i = index(raw, "\\")) > 0) {
    out = out substr(raw, 1, i - 1); c = substr(raw, i + 1, 1); raw = substr(raw, i + 2)
    if (c == "\"" || c == "\\" || c == "/") out = out c
    else if (c == "b") out = out "\b"
    else if (c == "f") out = out "\f"
    else if (c == "n") out = out "\n"
    else if (c == "r") out = out "\r"
    else if (c == "t") out = out "\t"
    else if (c == "u") {
      cp = hex4(substr(raw, 1, 4)); if (cp < 0) { JBAD = 1; JWHY = "has a bad \\u escape"; return "" }
      raw = substr(raw, 5)
      if (cp >= 55296 && cp <= 56319 && substr(raw, 1, 2) == "\\u") {
        lo = hex4(substr(raw, 3, 4))
        if (lo >= 56320 && lo <= 57343) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); raw = substr(raw, 7) }
      }
      if (cp == 0) { JBAD = 1; JWHY = "has a NUL character in a string"; return "" }
      out = out utf8(cp)
    } else { JBAD = 1; JWHY = "has a bad escape in a string"; return "" }
  }
  return out raw
}

# ---- the profile as profile.py load() makes it: defaults, then the site's values, then the file ---------
# MK[i] the i-th key, MV[i] its node, MI[key] its place (python's dict.update keeps a key where it was)
function madd(k, id) { if (k in MI) MV[MI[k]] = id; else { MN++; MK[MN] = k; MV[MN] = id; MI[k] = MN } }
function mget(k) { return (k in MI) ? MV[MI[k]] : 0 }
function kid(p, k) { return (p && NT[p] == "o" && ((p, k) in NI)) ? NC[p, NI[p, k]] : 0 }
function merge(   i, id, s, sroot, stxt, k) {
  MN = 0
  for (i = 1; i <= NSC; i++) if (SCD[i] != "") madd(SCK[i], jparse(SCD[i]))
  if (NT[PROOT] != "o") return
  s = kid(PROOT, "site")
  if (s && NT[s] == "s" && NV[s] ~ /^[a-z0-9][a-z0-9-]*$/ && length(NV[s]) <= 32) {
    stxt = readfile(ENVIRON["HPCW_P_SITEDIR"] "/" NV[s] ".json")
    if (stxt != "\001") {
      sroot = jparse(stxt)
      k = kid(sroot, "site")
      if (sroot && NT[sroot] == "o" && k && NT[k] == "s" && NV[k] == NV[s])
        for (i = 1; i <= NFS; i++) { id = kid(sroot, FSK[i]); if (id) madd(FSK[i], id) }
    }
  }
  for (i = 1; i <= NN[PROOT]; i++) madd(NK[PROOT, i], NC[PROOT, i])
}

# ---- python's str(), repr() and truth of a value; shlex.quote; expand() ------------------------------------
function isstr(id) { return id && NT[id] == "s" }
function isint(id) { return id && NT[id] == "n" && NV[id] ~ /^-?[0-9]+$/ }
function isbool(id) { return id && (NT[id] == "t" || NT[id] == "f") }
function isdict(id) { return id && NT[id] == "o" }
function islist(id) { return id && NT[id] == "a" }
function truthy(id) {
  if (!id) return 0
  if (NT[id] == "t") return 1
  if (NT[id] == "f" || NT[id] == "z") return 0
  if (NT[id] == "s") return NV[id] != ""
  if (NT[id] == "n") return (NV[id] + 0) != 0
  return NN[id] > 0
}
function pyfloat(x,   p, s, m, e, d, sign, n, ip, out) {
  if (x == 0) return (sprintf("%g", x) ~ /^-/) ? "-0.0" : "0.0"
  for (p = 0; p <= 16; p++) { s = sprintf("%." p "e", x); if ((s + 0) == x) break }
  sign = ""; if (substr(s, 1, 1) == "-") { sign = "-"; s = substr(s, 2) }
  m = s; sub(/[eE].*/, "", m); e = s; sub(/^[^eE]*[eE]/, "", e); e = e + 0
  d = m; sub(/\./, "", d); sub(/0+$/, "", d); if (d == "") d = "0"
  n = length(d)
  if (e >= -4 && e < 16) {
    if (e >= 0) {
      ip = substr(d, 1, e + 1); while (length(ip) < e + 1) ip = ip "0"
      out = ip "." (n > e + 1 ? substr(d, e + 2) : "0")
    } else {
      out = "0."; for (p = 1; p < -e; p++) out = out "0"
      out = out d
    }
    return sign out
  }
  out = substr(d, 1, 1) (n > 1 ? "." substr(d, 2) : "")
  return sign out "e" (e < 0 ? "-" : "+") (e < 0 ? (-e < 10 ? "0" : "") (-e) : (e < 10 ? "0" : "") e)
}
function pynum(t) {
  if (t ~ /^-?[0-9]+$/) { if (t ~ /^-0+$/) return "0"; return t }
  if (substr(t, 1, 1) == "-" && (t + 0) == 0) return "-0.0"   # awk may drop the sign of a negative zero
  return pyfloat(t + 0)
}
function pyrepr_str(s,   q, out, i, c, n, o) {
  q = SQ; if (index(s, SQ) && !index(s, "\"")) q = "\""
  out = q; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == q) out = out "\\" c
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else if (c == "\t") out = out "\\t"
    else if (c == DEL) out = out "\\x7f"
    else if (c ~ /[\001-\037]/) out = out sprintf("\\x%02x", index(CTRL, c))
    else out = out c
  }
  return out q
}
function pyrepr(id,   j, out) {
  if (NT[id] == "s") return pyrepr_str(NV[id])
  if (NT[id] == "n") return pynum(NV[id])
  if (NT[id] == "t") return "True"
  if (NT[id] == "f") return "False"
  if (NT[id] == "z") return "None"
  if (NT[id] == "a") { out = "["; for (j = 1; j <= NN[id]; j++) out = out (j > 1 ? ", " : "") pyrepr(NC[id, j]); return out "]" }
  out = "{"; for (j = 1; j <= NN[id]; j++) out = out (j > 1 ? ", " : "") pyrepr_str(NK[id, j]) ": " pyrepr(NC[id, j]); return out "}"
}
function pystr(id) {
  if (!id) return "None"
  if (NT[id] == "s") return NV[id]
  if (NT[id] == "n") return pynum(NV[id])
  return pyrepr(id)
}
function shq(s) {
  if (s == "") return SQ SQ
  if (s !~ /[^A-Za-z0-9_@%+=:,.\/-]/) return s
  gsub(SQ, SQ "\"" SQ "\"" SQ, s)
  return SQ s SQ
}
function expand1(s, name, v,   out, tok, i, c) {
  tok = "${" name "}"; out = ""
  while ((i = index(s, tok)) > 0) { out = out substr(s, 1, i - 1) v; s = substr(s, i + length(tok)) }
  s = out s
  tok = "$" name; out = ""
  while ((i = index(s, tok)) > 0) {
    out = out substr(s, 1, i - 1); s = substr(s, i + length(tok)); c = substr(s, 1, 1)
    if (c != "" && c ~ /[A-Za-z0-9_]/) out = out tok; else out = out v
  }
  return out s
}
function expand(s) {
  if ("HOME" in ENVIRON) s = expand1(s, "HOME", ENVIRON["HOME"])
  if ("USER" in ENVIRON) s = expand1(s, "USER", ENVIRON["USER"])
  return s
}
function pjoin(a, b) { if (substr(b, 1, 1) == "/") return b; if (a == "" || substr(a, length(a), 1) == "/") return a b; return a "/" b }
function normpath(p,   init, n, i, c, k, out, parts, stack) {
  if (p == "") return "."
  init = 0
  if (substr(p, 1, 1) == "/") { init = 1; if (substr(p, 1, 2) == "//" && substr(p, 1, 3) != "///") init = 2 }
  n = split(p, parts, "/"); k = 0
  for (i = 1; i <= n; i++) {
    c = parts[i]
    if (c == "" || c == ".") continue
    if (c != ".." || (!init && k == 0) || (k > 0 && stack[k] == "..")) stack[++k] = c
    else if (k > 0) k--
  }
  out = ""; for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") stack[i]
  if (init == 1) out = "/" out; else if (init == 2) out = "//" out
  return out == "" ? "." : out
}
function under(path, folder,   f) {
  if (path == "" || folder == "") return 0
  path = normpath(path); folder = normpath(folder)
  f = folder; sub(/\/+$/, "", f)
  return path == folder || substr(path, 1, length(f) + 1) == f "/"
}
function u8len(s,   t) { t = s; gsub(/[\200-\277]/, "", t); return length(t) }
# python's \s as bytes: ASCII space, \t \n \v \f \r, \x1c-\x1f, and U+0085, U+00A0, U+1680, U+2000-200A, 2028, 2029, 202F, 205F, 3000
function has_ws(s) {
  if (s ~ /[ \t\n\013\f\r\034-\037]/) return 1
  return s ~ /\302\205|\302\240|\341\232\200|\342\200[\200-\212]|\342\200\250|\342\200\251|\342\200\257|\342\201\237|\343\200\200/
}
function has_quote(s) { return index(s, SQ) || index(s, "\"") }
function hostish(s, max) { return s ~ /^[A-Za-z0-9.-]+$/ && length(s) <= max }
function urlish(s, scheme,   r) { if (substr(s, 1, length(scheme)) != scheme) return 0; r = substr(s, length(scheme) + 1); return r != "" && !has_ws(r) && !has_quote(r) }

# ---- profile.py validate(), on the merged profile -------------------------------------------------------
function verr(m) { ERRS[++NE] = m }
function typeok(t, id,   n, i, opts) {
  if (t == "list") return islist(id)
  if (t == "dict") return isdict(id)
  if (t == "int_or_none") return NT[id] == "z" || isint(id)
  if (t == "bool_or_none") return NT[id] == "z" || isbool(id)
  if (t == "str_or_none") return NT[id] == "z" || isstr(id)
  if (t == "int") return isint(id)
  if (t == "bool") return isbool(id)
  if (t == "str") return isstr(id)
  if (substr(t, 1, 5) == "enum:") {
    if (!isstr(id)) return 0
    n = split(substr(t, 6), opts, ",")
    if (substr(t, 6, 1) == ",") { if (NV[id] == "") return 1 }
    for (i = 1; i <= n; i++) if (opts[i] != "" && NV[id] == opts[i]) return 1
    return 0
  }
  return 0
}
function want(t,   w) { if (substr(t, 1, 5) == "enum:") { w = substr(t, 6); gsub(/,/, "/", w); return w } return t }
function walk(id, prefix,   j, p) {   # profile.py _walk: every scalar, named by its dotted path
  if (NT[id] == "o") { for (j = 1; j <= NN[id]; j++) walk(NC[id, j], prefix NK[id, j] "."); return }
  if (NT[id] == "a") { for (j = 1; j <= NN[id]; j++) walk(NC[id, j], prefix (j - 1) "."); return }
  if (NT[id] == "s" && NV[id] ~ /sk-ant-|CLAUDE_CODE_OAUTH_TOKEN=|setup-token/) { p = prefix; sub(/\.+$/, "", p); verr("field " p " looks like it carries a credential; the profile never does") }
}
function validate(   i, k, id, img, t, p, eg, pe, rules, v, nt, s, j, e, keys) {
  NE = 0
  if (NT[PROOT] != "o") { verr("profile is not a JSON object"); return }
  for (i = 1; i <= NSC; i++) {
    k = SCK[i]; id = mget(k)
    if (!id) { if (SCR[i]) verr("missing required field: " k); continue }
    if (!typeok(SCT[i], id)) verr("field " k ": expected " want(SCT[i]) ", got " pyrepr(id))
  }
  img = mget("image_store")
  if (isdict(img)) {
    t = kid(img, "type"); p = kid(img, "path")
    if (!(isstr(t) && (NV[t] == "sandbox" || NV[t] == "sif"))) verr("image_store.type must be one of ('sandbox', 'sif')")
    if (!(isstr(p) && NV[p] != "")) verr("image_store.path must be a non-empty string")
  }
  eg = mget("egress")
  if (isdict(eg)) {
    t = kid(eg, "class")
    if (!(isstr(t) && (NV[t] == "direct" || NV[t] == "http-proxy-auto" || NV[t] == "http-proxy-module" || NV[t] == "none")))
      verr("egress.class must be one of ('direct', 'http-proxy-auto', 'http-proxy-module', 'none')")
    pe = kid(eg, "proxy_env")
    if (pe && !isdict(pe)) verr("egress.proxy_env must be an object")
    if (isdict(pe)) for (j = 1; j <= NN[pe]; j++) {
      e = toupper(NK[pe, j])
      if (e != "HTTPS_PROXY" && e != "HTTP_PROXY" && e != "NO_PROXY") verr("egress.proxy_env may only set https_proxy, http_proxy, no_proxy (got " NK[pe, j] ")")
    }
  }
  rules = mget("login_node_rules")
  if (isdict(rules)) {
    v = kid(rules, "max_processes"); if (!(isint(v) || isbool(v))) verr("login_node_rules.max_processes must be an integer")
    v = kid(rules, "poll_floor_seconds"); if (!(isint(v) || isbool(v))) verr("login_node_rules.poll_floor_seconds must be an integer")
    if (isint(v) && NV[v] + 0 < 60 || NT[v] == "t" || NT[v] == "f") verr("login_node_rules.poll_floor_seconds must be at least 60")
  }
  s = mget("site")
  if (isstr(s) && !(NV[s] ~ /^[a-z0-9][a-z0-9-]*$/ && length(NV[s]) <= 32)) verr("site must be lower-case letters, digits and dashes (it goes into session names)")
  nt = mget("node_tmp")
  if (isstr(nt)) {
    if (substr(NV[nt], 1, 7) == "$TMPDIR" && !truthy(mget("tmpdir_is_node_local"))) verr("node_tmp uses $TMPDIR but tmpdir_is_node_local is false")
    if (!index(NV[nt], "$USER") && !index(NV[nt], "${USER}")) verr("node_tmp should contain $USER so users do not share a directory")
  }
  split("shared_state_dir claude_config_dir", keys, " ")
  for (i = 1; i <= 2; i++) {
    v = mget(keys[i])
    if (isstr(v) && !(substr(NV[v], 1, 1) == "/" || substr(NV[v], 1, 5) == "$HOME" || substr(NV[v], 1, 7) == "${HOME}")) verr(keys[i] " must be absolute or start with $HOME")
  }
  if (NT[mget("scheduler_in_worker")] == "t") {
    v = mget("scheduler"); if (!(isstr(v) && NV[v] == "slurm")) verr("scheduler_in_worker is built for Slurm only (this profile's scheduler is " pystr(v) ")")
    v = mget("runtime"); if (!(isstr(v) && (NV[v] == "apptainer" || NV[v] == "singularity"))) verr("scheduler_in_worker needs apptainer or singularity (this profile's runtime is " pystr(v) ")")
  }
  v = mget("shared_install")
  if (isstr(v) && NV[v] != "" && (substr(NV[v], 1, 1) != "/" || has_ws(NV[v]) || has_quote(NV[v]))) verr("shared_install must be an absolute directory without spaces or quotes (or empty)")
  v = mget("session_title")
  if (isstr(v) && (u8len(NV[v]) > 64 || NV[v] ~ /[\001-\037\177`$\\]/ || has_quote(NV[v]))) verr("session_title must be at most 64 characters without quotes, backslashes, $ or control characters")
  split("vpn_help_url grid_account_help_url grid_2fa_help_url", keys, " ")
  for (i = 1; i <= 3; i++) { v = mget(keys[i]); if (isstr(v) && NV[v] != "" && !urlish(NV[v], "https://")) verr(keys[i] " must be an https address (or empty)") }
  v = mget("vpn_portal"); if (isstr(v) && NV[v] != "" && !hostish(NV[v], 253)) verr("vpn_portal must be a host name (letters, digits, dots and dashes)")
  v = mget("ssh_host"); if (isstr(v) && NV[v] != "" && !hostish(NV[v], 253)) verr("ssh_host must be a host name (letters, digits, dots and dashes)")
  v = mget("ssh_port"); if (isint(v) && (NV[v] + 0 < 1 || NV[v] + 0 > 65535)) verr("ssh_port must be between 1 and 65535")
  v = mget("ssh_host_key")
  if (isstr(v) && NV[v] != "" && !(substr(NV[v], 1, 7) == "SHA256:" && length(NV[v]) == 50 && substr(NV[v], 8) ~ /^[A-Za-z0-9+\/]+$/)) verr("ssh_host_key must be a SHA256: fingerprint as ssh-keygen -l prints it (or empty)")
  v = mget("ssh_relay"); if (isstr(v) && !urlish(NV[v], "wss://") && !urlish(NV[v], "https://")) verr("ssh_relay must be a wss:// or https:// address (or null)")
  v = mget("browser_key_days"); if (isint(v) && (NV[v] + 0 < 1 || NV[v] + 0 > 3650)) verr("browser_key_days must be between 1 and 3650 (or null for no expiry)")
  v = mget("login_abandon_s"); if (isint(v) && NV[v] + 0 != 0 && NV[v] + 0 < 300) verr("login_abandon_s must be 0 (never) or at least 300 seconds")
  v = mget("restricted_workspaces")
  if (islist(v)) for (j = 1; j <= NN[v]; j++) {
    e = NC[v, j]
    if (!(isstr(e) && (NV[e] == "*" || (NV[e] ~ /^[A-Za-z0-9_-]+$/ && length(NV[e]) <= 32)))) verr("restricted_workspaces entries must be worker names or \"*\" (got " pyrepr(e) ")")
  }
  v = mget("binds")
  if (islist(v)) for (j = 1; j <= NN[v]; j++) { e = NC[v, j]; if (!isstr(e) || NV[e] == "" || has_ws(NV[e])) verr("binds entries must be non-empty paths without whitespace (got " pyrepr(e) ")") }
  for (i = 1; i <= MN; i++) walk(MV[i], MK[i] ".")
}
function unknown_note(   i, n, l) {
  n = 0; l = ""
  for (i = 1; i <= MN; i++) if (!(MK[i] in SCI)) { n++; l = l (n > 1 ? ", " : "") MK[i] }
  return n ? "ignored " n " field(s) this version does not know: " l : ""
}

# ---- the outputs ---------------------------------------------------------------------------------------
function emit(name, id,   v, j) {
  gsub(/[^A-Za-z0-9_]/, "_", name)
  if (NT[id] == "t") v = "true"
  else if (NT[id] == "f") v = "false"
  else if (NT[id] == "z") v = ""
  else if (NT[id] == "a") { v = ""; for (j = 1; j <= NN[id]; j++) v = v (j > 1 ? " " : "") expand(pystr(NC[id, j])) }
  else v = expand(pystr(id))
  print "P_" name "=" shq(v)
}
function putv(name, v) { print name "=" shq(v) }
function shellenv(   i, k, id, j, sb, sv, l) {
  for (i = 1; i <= MN; i++) {
    k = MK[i]; if (!(k in SCI)) continue
    id = MV[i]
    if (NT[id] == "o") {
      for (j = 1; j <= NN[id]; j++) {
        sb = NK[id, j]; sv = NC[id, j]
        if (NT[sv] == "o") { for (l = 1; l <= NN[sv]; l++) emit(k "_" sb "_" NK[sv, l], NC[sv, l]) }
        else emit(k "_" sb, sv)
      }
    } else emit(k, id)
  }
}
# what profile.py mapping() and guide_mapping() take from the profile alone (the rest comes from a run's
# own values, which bash adds: lib/profile_sh.sh). Only for a valid profile, as profile.py renders only then
function wdval(k, dflt,   v) { v = kid(mget("worker_defaults"), k); return v ? pystr(v) : dflt }
function pyint(id,   s, neg) {   # python int() of a value, "" when python would refuse it
  if (isint(id)) return pynum(NV[id])
  if (NT[id] == "n") { s = int(NV[id] + 0); return (s == 0) ? "0" : s "" }
  if (NT[id] == "t") return "1"
  if (NT[id] == "f") return "0"
  if (isstr(id)) {
    s = NV[id]; gsub(/^[ \t\n\r\f\013]+|[ \t\n\r\f\013]+$/, "", s)
    if (s ~ /^[-+]?[0-9]+$/) { neg = (substr(s, 1, 1) == "-"); sub(/^[-+]/, "", s); sub(/^0+/, "", s); return (s == "") ? "0" : (neg ? "-" : "") s }
  }
  return ""
}
function mapping_parts(   v, j, b, l, eg, cls, pe, pm, ca, n, cm, bad, h) {
  bad = ""
  putv("HPCW_M_SITE", pystr(mget("site")))
  putv("HPCW_M_SCHEDULER", pystr(mget("scheduler")))
  putv("HPCW_M_STATE_DIR", expand(pystr(mget("shared_state_dir"))))
  putv("HPCW_M_PART_CPU", pystr(mget("partition_cpu")))
  putv("HPCW_M_PART_BATCH", truthy(mget("partition_cpu_batch")) ? pystr(mget("partition_cpu_batch")) : "")
  putv("HPCW_M_PART_BATCH_RAW", pystr(mget("partition_cpu_batch")))
  putv("HPCW_M_QOS_CPU", pystr(mget("qos_cpu")))
  putv("HPCW_M_QOS_BATCH", pystr(mget("qos_batch")))
  putv("HPCW_M_ACCOUNT", truthy(mget("account")) ? pystr(mget("account")) : "")
  putv("HPCW_M_WD_CPUS", wdval("cpus", "2"))
  putv("HPCW_M_WD_MEM", wdval("mem", "8G"))
  v = kid(mget("worker_defaults"), "hours"); h = v ? pyint(v) : "8"
  if (h == "") bad = "worker_defaults.hours is not a whole number"
  putv("HPCW_M_WD_HOURS", h)
  putv("HPCW_M_WD_PM", wdval("permission_mode", "default"))
  putv("HPCW_M_WD_CAP", wdval("capacity", "4"))
  putv("HPCW_M_NODE_TMP", expand(pystr(mget("node_tmp"))))
  putv("HPCW_M_NODE_TMP_VAR", pystr(mget("node_tmp_var")))
  putv("HPCW_M_TMPDIR_LOCAL", truthy(mget("tmpdir_is_node_local")) ? "1" : "0")
  putv("HPCW_M_IPC_DIR", pystr(mget("ipc_dir")))
  putv("HPCW_M_RUNTIME", pystr(mget("runtime")))
  putv("HPCW_M_RUNTIME_BIN", expand(pystr(mget("runtime_bin"))))
  putv("HPCW_M_RUNTIME_MODULE", pystr(mget("runtime_module")))
  putv("HPCW_M_IMAGE", expand(pystr(kid(mget("image_store"), "path"))))
  putv("HPCW_M_IMAGE_TYPE", pystr(kid(mget("image_store"), "type")))
  putv("HPCW_M_CLAUDE_BIN", expand(pystr(mget("claude_bin"))))
  v = mget("binds"); l = ""
  for (j = 1; j <= NN[v]; j++) l = l (j > 1 ? " " : "") "-B " shq(expand(pystr(NC[v, j])))
  putv("HPCW_M_BINDS", l)
  putv("HPCW_M_CCD", expand(pystr(mget("claude_config_dir"))))
  v = mget("consent_markers"); cm = ""; n = 0
  for (j = 1; j <= NN[v]; j++) { if (!isstr(NC[v, j])) bad = "consent_markers holds something that is not a path"; cm = cm (j > 1 ? ":" : "") expand(pystr(NC[v, j])); n++ }
  putv("HPCW_M_CM", cm); putv("HPCW_M_CM_N", n "")
  # egress_exports()
  eg = mget("egress"); v = kid(eg, "class"); cls = v ? pystr(v) : "direct"
  putv("HPCW_M_EGRESS_CLASS", cls)
  l = "# egress class: " cls
  pm = kid(eg, "proxy_module")
  if (isstr(v) && NV[v] == "http-proxy-module" && truthy(pm)) {
    if (!isstr(pm)) bad = "egress.proxy_module is not a string"
    l = l "\nmodule load " shq(pystr(pm)) " 2>/dev/null || echo " SQ "WARN: proxy module " pystr(pm) " did not load" SQ
  }
  pe = kid(eg, "proxy_env")
  if (isdict(pe)) for (j = 1; j <= NN[pe]; j++) l = l "\nexport " tolower(NK[pe, j]) "=" shq(pystr(NC[pe, j])) " " toupper(NK[pe, j]) "=" shq(pystr(NC[pe, j]))
  if (isstr(v) && NV[v] == "direct") l = l "\n# direct: inherited proxy variables are not overridden; the probe measured this class"
  if (isstr(v) && NV[v] == "none") l = l "\necho " SQ "WARN: egress class none: compute nodes were measured unable to reach api.anthropic.com; Remote Control will not register" SQ
  ca = kid(eg, "ca_bundle")
  if (truthy(ca)) { if (!isstr(ca)) bad = "egress.ca_bundle is not a string"; l = l "\nexport NODE_EXTRA_CA_CERTS=" shq(pystr(ca)) }
  putv("HPCW_M_EGRESS_EXPORTS", l)
  v = mget("xdg_runtime_fix"); putv("HPCW_M_XDG", (!v || truthy(v)) ? "1" : "0")
  putv("HPCW_M_SIW", (NT[mget("scheduler_in_worker")] == "t") ? "1" : "0")
  v = mget("login_abandon_s"); putv("HPCW_M_LAS", v ? pystr(v) : "1200")
  v = mget("session_title"); putv("HPCW_M_TITLE_BASE", truthy(v) ? pystr(v) : "Grid worker")
  putv("HPCW_M_BAD", bad)
}
function guide_parts(   sch, word, name, portal, host, terminal, poll, v, cpu, qcpu, batch, qbatch, more, lines, j, n, g, acct, opt, submit, line, siw, ask, home, sd, lab, nl, b, p, what, x, i, m, bi) {
  sch = pystr(mget("scheduler"))
  word = (sch == "slurm") ? "partition" : "queue"
  SN["slurm"] = "Slurm"; SN["pbs"] = "PBS"; SN["lsf"] = "LSF"; SN["sge"] = "Grid Engine"; SN["htcondor"] = "HTCondor"
  SUB["slurm"] = "sbatch"; SUBL["slurm"] = "sbatch -D %s job.sh"
  SUB["pbs"] = "qsub"; SUBL["pbs"] = "cd %s && qsub job.sh"
  SUB["lsf"] = "bsub"; SUBL["lsf"] = "cd %s && bsub < job.sh"
  SUB["sge"] = "qsub"; SUBL["sge"] = "qsub -wd %s job.sh"
  SUB["htcondor"] = "condor_submit"; SUBL["htcondor"] = "cd %s && condor_submit job.sub"
  if (sch in SUB) { submit = SUB[sch]; line = SUBL[sch] } else { submit = "the scheduler's submit command"; line = "submit job.sh from %s" }
  i = index(line, "%s")
  putv("HPCW_G_SUBMIT", submit); putv("HPCW_G_SUBMIT_PRE", substr(line, 1, i - 1)); putv("HPCW_G_SUBMIT_POST", substr(line, i + 2))
  putv("HPCW_G_SCHEDULER_NAME", (sch in SN) ? SN[sch] : sch)
  v = mget("display_name"); name = truthy(v) ? pystr(v) : pystr(mget("site")) " cluster"
  if (substr(tolower(name), 1, 4) != "the ") name = "the " name
  putv("HPCW_G_CLUSTER", name)
  v = mget("ood_base_url"); portal = truthy(v) ? pystr(v) : ""
  v = mget("submit_host"); host = truthy(v) ? pystr(v) : ""
  terminal = portal != "" ? " (for example the shell in the portal, " portal ")" : ""
  v = kid(mget("login_node_rules"), "poll_floor_seconds"); poll = v ? pystr(v) : "60"
  siw = (NT[mget("scheduler_in_worker")] == "t" && sch == "slurm")
  putv("HPCW_G_JOB_RESULTS", siw ? "\n- A job you submitted: have it write its output and results under this workspace (`#SBATCH --output` too, submitted with `-D`), follow it with `squeue -j <id>` or `sacct -j <id>` at most once every " poll " seconds, then read what it wrote and tell the person what came out and where." : "")
  putv("HPCW_G_LOGIN_NODE", host != "" ? " (`" host "`)" : "")
  putv("HPCW_G_POLL_S", poll)
  # guide_scheduling_lines
  cpu = pystr(mget("partition_cpu")); v = mget("qos_cpu"); qcpu = truthy(v) ? pystr(v) : ""
  lines = "- Short and test jobs: " where(word, cpu, qcpu) "."
  v = mget("partition_cpu_batch"); batch = truthy(v) ? pystr(v) : ""
  v = mget("qos_batch"); qbatch = truthy(v) ? pystr(v) : ""
  if (batch != "" && (batch != cpu || qbatch != qcpu)) {
    more = (qbatch == "requeue") ? "; a job there can be stopped and started again, so save progress as it goes" : ""
    lines = lines "\n- Long jobs: " where(word, batch, qbatch) more "."
  }
  v = mget("partitions_gpu"); n = 0; g = ""
  if (islist(v)) for (j = 1; j <= NN[v]; j++) if (truthy(NC[v, j])) { n++; g = g (n > 1 ? " or " : "") "`" pystr(NC[v, j]) "`"; x = pystr(NC[v, j]) }
  if (n == 1) lines = lines "\n- GPU jobs: " word " `" x "`."
  else if (n > 1) lines = lines "\n- GPU jobs: " word "s " g ", in that order of preference."
  v = mget("account"); acct = truthy(v) ? pystr(v) : ""
  if (acct != "") {
    opt = (sch == "slurm") ? "--account=" acct : (sch == "pbs") ? "-A " acct : (sch == "lsf") ? "-P " acct : ""
    lines = lines "\n- Every job names the account `" acct "`" (opt != "" ? " (`" opt "`)" : "") "."
  }
  v = mget("max_walltime"); if (truthy(v)) lines = lines "\n- The longest time a job may ask for: `" pystr(v) "`."
  if (sch == "slurm") {
    lines = lines "\n- `#SBATCH --output` is read relative to the folder a job is submitted from; name that folder with `-D`."
    lines = lines "\n- Chain jobs with `--dependency=afterany:<id>` and read each output yourself; with `afterok`, one failed job leaves the rest waiting for ever."
  }
  putv("HPCW_G_SCHEDULING", lines)
  # guide_submitting_lines
  ask = "write the job script into this workspace and ask the person to submit it from a terminal on the cluster" terminal "."
  if (!siw) lines = "- Check first with `command -v " submit "`: this container may not carry the scheduler's commands. If it does not, " ask
  else {
    lines = "- The cluster's own Slurm commands work in here: `sbatch`, `squeue`, `sacct`, `scancel` and `sinfo` (also in `/opt/hpcw/slurm/bin`). A job you submit runs on the cluster outside this container, with the person's usual environment, and keeps running when this worker's job ends."
    lines = lines "\n- If `command -v sbatch` finds nothing, this node lacked a piece when the worker started (the worker's log says which): " ask
    lines = lines "\n- Cancel only jobs you submitted, by their id (`scancel <id>`); never `scancel -u` or a name pattern, and never this worker's own job (`$HPCW_JOB`)."
    v = pystr(mget("runtime"))
    if (v == "apptainer" || v == "singularity") lines = lines "\n- A job that runs a container keeps the runtime's temporary and cache folders (`APPTAINER_TMPDIR`, `APPTAINER_CACHEDIR`) on the node's local disk inside that job, and removes them at its end."
  }
  putv("HPCW_G_SUBMITTING", lines)
  putv("HPCW_G_IPC", expand(pjoin(pystr(mget("ipc_dir")), "$USER")))
  # guide_data_lines
  home = expand("$HOME"); sd = expand(pystr(mget("shared_state_dir")))
  nl = 0
  v = mget("shared_install"); if (truthy(v)) LAB[++nl] = expand(pystr(v))
  v = kid(mget("image_store"), "path"); if (truthy(v)) LAB[++nl] = expand(pystr(v))
  v = mget("claude_bin"); if (truthy(v)) LAB[++nl] = expand(pystr(v))
  lines = ""; b = mget("binds"); m = 0
  if (islist(b)) for (j = 1; j <= NN[b]; j++) {
    p = expand(pystr(NC[b, j]))
    if (p ~ /^\/[^:]*:\/[^:]*(:[a-z,]*)?$/) { bi = index(substr(p, 2), ":") + 1; p = substr(p, bi + 1); sub(/:[a-z,]*$/, "", p) }
    if (p == home && under(sd, p)) what = "the person's home folder, where this workspace is"
    else if (p == home) what = "the person's home folder; keep it for small files"
    else if (under(sd, p)) what = "the person's folder on the lab's storage, where this workspace is; large inputs and results go here"
    else { what = "a folder the site profile shares with workers"; for (i = 1; i <= nl; i++) if (under(LAB[i], p)) { what = "the lab's shared folder for workers (the container and hpcworker itself); read it, never change it"; break } }
    m++; lines = lines (m > 1 ? "\n" : "") "- `" p "`: " what "."
  }
  if (m == 0) lines = "- only this workspace: the site profile shares no other folder with workers."
  putv("HPCW_G_DATA", lines)
}
function where(word, part, qos) { return word " `" part "`" (qos != "" ? ", QoS `" qos "`" : "") }
function jdump(id,   j, o) {   # json.dumps of a list or an object, for `get` (no key hpcworker gets is one)
  if (NT[id] == "s") return "\"" NV[id] "\""
  if (NT[id] == "n") return NV[id]
  if (NT[id] == "t") return "true"
  if (NT[id] == "f") return "false"
  if (NT[id] == "z") return "null"
  if (NT[id] == "a") { o = "["; for (j = 1; j <= NN[id]; j++) o = o (j > 1 ? ", " : "") jdump(NC[id, j]); return o "]" }
  o = "{"; for (j = 1; j <= NN[id]; j++) o = o (j > 1 ? ", " : "") "\"" NK[id, j] "\": " jdump(NC[id, j]); return o "}"
}

BEGIN {
  SQ = sprintf("%c", 39)
  CTRL = ""; for (i = 1; i < 32; i++) CTRL = CTRL sprintf("%c", i); DEL = sprintf("%c", 127)
  schema_init()
  mode = ENVIRON["HPCW_P_MODE"]
  txt = readfile(ENVIRON["HPCW_P_FILE"])
  if (txt == "\001") fail_read("cannot be read")
  PROOT = jparse(txt)
  if (!PROOT) fail_read("is not JSON: it " JWHY)
  merge()
  if (mode == "get") {
    n = split(ENVIRON["HPCW_P_KEY"], parts, ".")
    id = (NT[PROOT] == "o") ? mget(parts[1]) : 0
    for (i = 2; i <= n && id; i++) {
      if (NT[id] == "o") id = kid(id, parts[i])
      else if (NT[id] == "a" && parts[i] ~ /^[0-9]+$/ && parts[i] + 0 < NN[id]) id = NC[id, parts[i] + 1]
      else id = 0
    }
    if (!id || NT[id] == "z") print ""
    else if (NT[id] == "o" || NT[id] == "a") print jdump(id)
    else if (NT[id] == "t") print "true"
    else if (NT[id] == "f") print "false"
    else print expand(pystr(id))
    exit 0
  }
  validate()
  note = unknown_note()
  if (mode == "check") {
    for (i = 1; i <= NE; i++) print "ERROR: " ERRS[i]
    if (NE == 0) print "ok: " pystr(mget("site")) " (" pystr(mget("scheduler")) ", " pystr(mget("runtime")) ")" (note != "" ? "; " note : "")
    exit (NE > 0) ? 1 : 0
  }
  if (mode == "env") {
    shellenv()
    errs = ""; for (i = 1; i <= NE; i++) errs = errs (i > 1 ? "\n" : "") ERRS[i]
    putv("HPCW_PV_errors", errs)
    putv("HPCW_PV_note", note)
    if (NE == 0) { mapping_parts(); guide_parts() }
    exit 0
  }
  print "hpcworker: profile.awk: unknown mode " mode > "/dev/stderr"
  exit 2
}
