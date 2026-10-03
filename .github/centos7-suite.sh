#!/bin/bash
# The framework suite inside centos:7, the login node's stack (python 3.6.8, bash 4.2.46,
# util-linux 2.23). CentOS 7 is end-of-life, so yum's mirrorlist is dead: point the repos at
# vault.centos.org first. openssh is installed and the suite runs as a non-root user with a home
# of its own — the browser-key and login-setup suites need ssh-keygen and refuse root, and under
# plain root they would be skipped silently, going green without testing the login-node gate at
# all. No tmux in the image: the job tests take `script`'s fallback, as on a compute node. The
# shell starts with no locale, the grid's own condition; tests/run.sh picks a UTF-8 one itself.
set -uo pipefail
sed -i -e 's|^mirrorlist=|#mirrorlist=|' -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' /etc/yum.repos.d/CentOS-*.repo
yum install -q -y python3 openssh openssh-clients > /dev/null || { echo "yum install failed"; exit 1; }
/usr/bin/python3 --version; bash --version | head -1; ssh-keygen -h 2>&1 | head -1 || true
useradd -m ci || exit 1
# the runner's bind mount stays root-owned; the suite runs in the ci user's own copy
cp -a /src /home/ci/src && chown -R ci:ci /home/ci/src || exit 1
su ci -c 'cd /home/ci/src && HPCW_PYTHON=/usr/bin/python3 bash framework/tests/run.sh'
