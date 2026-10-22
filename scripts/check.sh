#!/usr/bin/env bash
# What the required check "check" runs on GitHub's Ubuntu runner (.github/workflows/ci.yml, the job
# suite-linux), in one command for a laptop or a session before a pull request: the framework's
# suite, the grid tools' tests against their stand-ins, the review record's and the required check's
# own tests, and, on a pull request event, the review record (CONTRIBUTING.md). The CentOS 7 lane and
# the version check run in CI alone (the first needs docker, the second the base branch).
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
run() { echo "== $*"; "$@" || { echo "FAIL: $*"; fail=1; }; }
run env HPCW_PYTHON="${HPCW_PYTHON:-python3}" bash framework/tests/run.sh
run bash tools/tests/test_grid_access.sh
run bash tools/tests/test_grid_ci.sh
run bash tools/tests/test_grid_runner.sh
run bash tools/tests/test_grid_gate.sh
run python3 -m unittest discover -s tools/tests -p 'test_*.py'
run python3 tools/review_record.py
if [ "$fail" = 0 ]; then echo "check: passed"; else echo "check: FAILED"; fi
exit "$fail"
