#!/usr/bin/env python3
"""hpcworker accounts (framework 21): what one Claude account on the grid says about itself.

Runs on a compute node only (a job of `hpcworker accounts usage`, or a worker in auto mode); the
login node never starts python3. Standard library only, and only syntax Python 3.6 accepts.

    accounts_read.py who SLOT AUTH_FILE OUT    `claude auth status` -> SLOT.who.json
    accounts_read.py use SLOT PROBE_FILE OUT   one probe's stream-json -> SLOT.use.json
    accounts_read.py pick ACCOUNTS_DIR CURRENT [THRESHOLD]
                                               the slot auto mode moves to, or nothing

who keeps four keys of Claude Code's answer and nothing else: whether it is signed in with a Claude
subscription (the rule of lib/adapters/common.sh hpcw_claude_signin: loggedIn, authMethod "claude.ai",
apiProvider "firstParty" or none, and no apiKeySource), the e-mail and the plan. use keeps the last
rate_limit_event of the probe, the way the Symphony template's tools/pool.py reads one: the five-hour
and seven-day windows' use as a fraction and when each resets, the per-model weekly windows, and
whether the call was refused. No credential is ever read; the probe is Claude Code's own output.
"""
import json
import os
import sys
from datetime import datetime, timezone

SLOTS = tuple(str(n) for n in range(1, 33))
WINDOWS = ("five_hour", "seven_day")
MODEL_WINDOWS = {"seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet"}
THRESHOLD = 0.9


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value):
    """An ISO-8601 string or seconds since the epoch -> an aware datetime, or None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value, timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    if not isinstance(value, str) or not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    for shape in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            # 3.6's %z takes no colon in the offset
            return datetime.strptime(text[:-3] + text[-2:] if text[-3:-2] == ":" else text, shape)
        except ValueError:
            continue
    return None


def iso(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fraction(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
        return None
    return max(0.0, float(value))


def window(utilization, resets):
    used = fraction(utilization)
    if used is None:
        return None
    found = {"utilization": round(used, 4)}
    moment = parse_time(resets)
    if moment is not None:
        found["resetsAt"] = iso(moment)
    return found


def messages_in(text):
    found = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict):
            found.append(item)
    return found


def windows_from_event(info):
    """The windows a rate_limit_event's rate_limit_info carries (tools/pool.py's reading)."""
    windows, scoped = {}, []
    unified = info.get("unifiedWindows")
    if isinstance(unified, dict):
        for name in WINDOWS:
            each = unified.get(name)
            if isinstance(each, dict):
                found = window(each.get("utilization"), each.get("resetsAt"))
                if found:
                    windows[name] = found
    kind = info.get("rateLimitType")
    used = info.get("utilization")
    if info.get("status") == "rejected":
        used = 1.0 if fraction(used) is None else max(fraction(used), 1.0)
    if kind in WINDOWS and (info.get("status") == "rejected" or kind not in windows):
        found = window(used, info.get("resetsAt"))
        if found:
            windows[kind] = found
    elif kind in MODEL_WINDOWS:
        found = window(used, info.get("resetsAt"))
        if found:
            found["name"] = MODEL_WINDOWS[kind]
            scoped.append(found)
    return windows, scoped


def reading_of(slot, text):
    """SLOT.use.json from a probe's output: the last rate_limit_event that names a window."""
    messages = messages_in(text)
    record = {"v": 1, "slot": slot, "read_at": now_iso()}
    for message in reversed(messages):
        info = message.get("rate_limit_info") if message.get("type") == "rate_limit_event" else None
        if not isinstance(info, dict):
            continue
        windows, scoped = windows_from_event(info)
        if windows or scoped:
            record["windows"] = windows
            if scoped:
                record["scoped"] = scoped
            if info.get("status") in ("allowed", "allowed_warning", "rejected"):
                record["status"] = info["status"]
            return record
    # no reading: say why in a few words of Claude Code's own result, never more
    why = "Claude Code gave no usage reading"
    for message in reversed(messages):
        if message.get("type") == "result":
            result = message.get("result")
            if message.get("is_error") and isinstance(result, str) and result.strip():
                why = "Claude Code said: " + " ".join(result.split())[:160]
            break
    else:
        tail = [line for line in text.splitlines() if line.strip()][-1:]
        if tail and not tail[0].lstrip().startswith("{"):
            why = "Claude Code said: " + " ".join(tail[0].split())[:160]
    record["error"] = why
    return record


def who_of(slot, text):
    """SLOT.who.json from `claude auth status`: four keys, the subscription rule, nothing else."""
    try:
        answer = json.loads(text)
    except ValueError:
        answer = None
    record = {"v": 1, "slot": slot, "checked_at": now_iso(), "signed_in": False}
    if not isinstance(answer, dict):
        # no answer is not "signed out": the check itself failed (the container, a timeout, a refused
        # command), and saying signed out sent the person to sign in again an account that was fine
        record["signed_in"] = None
        record["sign_in"] = "unread"
        tail = [line for line in text.splitlines() if line.strip()][-1:]
        record["error"] = ("Claude Code did not answer the check" +
                           (": " + " ".join(tail[0].split())[:160] if tail else ""))
        return record
    if answer.get("loggedIn") is not True:
        record["sign_in"] = "none"
        return record
    provider = answer.get("apiProvider")
    subscription = ("apiKeySource" not in answer and answer.get("authMethod") == "claude.ai"
                    and provider in (None, "firstParty"))
    record["sign_in"] = "subscription" if subscription else "other"
    record["signed_in"] = subscription
    for key, name in (("email", "email"), ("subscriptionType", "plan")):
        value = answer.get(key)
        if subscription and isinstance(value, str) and 0 < len(value) <= 200:
            record[name] = value
    return record


def held(record, threshold, now):
    """True while one of the account's windows is at or past the threshold and has not reset."""
    if not isinstance(record, dict):
        return False
    if record.get("status") == "rejected":
        return True
    for each in list((record.get("windows") or {}).values()) + list(record.get("scoped") or []):
        if not isinstance(each, dict):
            continue
        used = fraction(each.get("utilization"))
        if used is None or used < threshold:
            continue
        resets = parse_time(each.get("resetsAt"))
        if resets is None or resets > now:
            return True
    return False


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            found = json.load(fh)
    except (OSError, ValueError):
        return None
    return found if isinstance(found, dict) else None


def five_hour(record):
    each = (record or {}).get("windows", {}).get("five_hour") or {}
    used = fraction(each.get("utilization"))
    return 0.0 if used is None else used


def pick(folder, current, threshold=THRESHOLD, now=None):
    """The slot auto mode moves to: none while the current account has room; else the signed-in
    account with the least of its five hours used among those with room, the lower number first."""
    now = now or datetime.now(timezone.utc)
    if not held(load(os.path.join(folder, current + ".use.json")), threshold, now):
        return ""
    best = None
    for slot in SLOTS:
        if slot == current or not os.path.isdir(os.path.join(folder, slot)):
            continue
        who = load(os.path.join(folder, slot + ".who.json"))
        if not who or who.get("signed_in") is not True:
            continue
        use = load(os.path.join(folder, slot + ".use.json"))
        if held(use, threshold, now):
            continue
        if best is None or five_hour(use) < best[0]:
            best = (five_hour(use), slot)
    return best[1] if best else ""


def write(path, record):
    part = "%s.part%d" % (path, os.getpid())
    old = os.umask(0o077)
    try:
        with open(part, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
        os.replace(part, path)
    finally:
        os.umask(old)


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read(4 * 1024 * 1024)


def main(argv):
    if len(argv) == 4 and argv[0] in ("who", "use") and argv[1] in SLOTS:
        text = read_text(argv[2])
        write(argv[3], who_of(argv[1], text) if argv[0] == "who" else reading_of(argv[1], text))
        return 0
    if len(argv) in (3, 4) and argv[0] == "pick" and argv[2] in SLOTS:
        threshold = THRESHOLD
        if len(argv) == 4:
            try:
                threshold = float(argv[3])
            except ValueError:
                return 2
        print(pick(argv[1], argv[2], threshold))
        return 0
    sys.stderr.write(__doc__.split("\n\n")[2] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
