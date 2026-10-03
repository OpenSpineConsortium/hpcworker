#!/bin/bash
# hpcworker test runner: shell syntax for every script, then the Python unit tests (stdlib
# unittest: profile schema, adapter parsers against fixtures, the worker template render).
# Runs under WSL or Linux and on a Windows Git Bash checkout; never on warrior's login node (the
# suite is python3 for minutes, and warrior's banner bans python3; a job on a compute node is fine).
#   bash framework/tests/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); ROOT=$(cd "$HERE/.." && pwd)
PY="${HPCW_PYTHON:-}"
if [ -z "$PY" ]; then for p in python3 python; do command -v "$p" >/dev/null 2>&1 && { PY="$p"; break; }; done; fi
[ -n "$PY" ] || { echo "no python found"; exit 1; }
# a plain ssh gives a shell without LANG; python 3.6 would then read files and pipes as ASCII
export PYTHONIOENCODING=utf-8
# and a batch job may have no locale at all: python 3.6 (no PEP 538) then encodes argv and the environment
# of every child as ASCII, and the tests that hand a child "wé" died in subprocess before the code under test
# ran (job 40554626 on kbt2, 2026-10-03). CentOS 7 has en_US.UTF-8 and no C.UTF-8, so the first one present
if [ -z "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" ]; then
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do locale -a 2>/dev/null | grep -qx "$l" && { export LANG="$l"; break; }; done
fi
fail=0
echo "== bash -n"
for f in "$ROOT"/bin/hpcworker "$ROOT"/lib/*.sh "$ROOT"/lib/adapters/*.sh "$ROOT"/jobs/*.sbatch "$ROOT"/tests/run.sh "$ROOT"/tests/e2e_sshd.sh "$ROOT"/tests/grid/*; do
  if bash -n "$f"; then echo "ok   $(basename "$f")"; else echo "FAIL $(basename "$f")"; fail=1; fi
done
# the template is bash once rendered: render it for the Wayne State profile and syntax-check the
# result. HOME/USER are set inside python because Git Bash rewrites a POSIX HOME for a native python.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if "$PY" -X utf8 -c 'import os, sys; os.environ["HOME"] = "/home/test"; os.environ["USER"] = "test"; sys.path.insert(0, sys.argv[1]); import profile as P; sys.stdout.buffer.write(P.render(open(sys.argv[2], encoding="utf-8").read(), P.mapping(P.load(sys.argv[3]), {"RUN": "worker"})).encode("utf-8"))' "$ROOT/lib" "$ROOT/jobs/worker.sbatch.tpl" "$ROOT/profiles/wayne.json" > "$tmp" && bash -n "$tmp"; then echo "ok   worker.sbatch.tpl (rendered)"; else echo "FAIL worker.sbatch.tpl (rendered)"; fail=1; fi
# -U: Git Bash's grep otherwise drops the CR of a CRLF line before matching, and the check never fails there
if grep -U -q $'\r' "$ROOT"/bin/hpcworker "$ROOT"/lib/*.sh "$ROOT"/lib/adapters/*.sh "$ROOT"/jobs/* "$ROOT"/lib/*.py "$ROOT"/lib/*.awk "$ROOT"/tests/e2e_sshd.sh "$ROOT"/tests/grid/* 2>/dev/null; then echo "FAIL CR line endings present"; fail=1; else echo "ok   line endings LF"; fi
echo "== python unittest ($($PY --version 2>&1))"
# on Windows a native python's first "bash" can be WSL's, which cannot read C:/ paths: hand the tests this bash
BASH_BIN=$(command -v bash); command -v cygpath >/dev/null 2>&1 && BASH_BIN=$(cygpath -w "$BASH_BIN")
( cd "$HERE" && HPCW_PYTHON="$PY" HPCW_BASH="$BASH_BIN" "$PY" -X utf8 -m unittest discover -s . -p 'test_*.py' -v 2>&1 ) || fail=1
[ $fail = 0 ] && echo "ALL OK" || { echo "FAILURES"; exit 1; }
