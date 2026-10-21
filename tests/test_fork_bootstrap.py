#!/usr/bin/env python3
"""Exercise the unmodified fork entry point with real, offline Git repositories.

The optional cached image contains Ubuntu 22.04, Bash and Git. No host system
files, network connections, application services or production data are used.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCKER = shutil.which('docker') or '/usr/local/bin/docker'
IMAGE = os.environ.get('MIAB_BOOTSTRAP_TEST_IMAGE', 'urmail-bootstrap-tests:local')
SCRIPT = r'''
set -Eeuo pipefail
export GIT_TERMINAL_PROMPT=0
unset TAG
# Only platform metadata is simulated; all Git commands and setup.sh are real.
mkdir /platform
cat > /platform/dpkg <<'DPKG'
#!/bin/bash
if [ "$1" = --print-architecture ]; then
    if [ "$CASE" = architecture ]; then echo arm64; else echo amd64; fi
else exec /usr/bin/dpkg "$@"; fi
DPKG
chmod +x /platform/dpkg
export PATH=/platform:$PATH
git config --global user.email fixture@example.test
git config --global user.name Fixture
git config --global protocol.file.allow always
git config --global url.file:///remote.git.insteadOf https://github.com/bushixiucai/mailinabox.git
git init -q -b main /source
cd /source
mkdir setup
echo v77 > VERSION
printf '#!/bin/bash\necho fresh-v77 >> /actions\n' > setup/start.sh
chmod +x setup/start.sh
git add . && git commit -qm v77
git tag v77
echo v80 > VERSION
printf '#!/bin/bash\nprintf "upgrade:%%s\\n" "$(git rev-parse HEAD)" >> /actions\n' > setup/upgrade-php.sh
printf '#!/bin/bash\nprintf "fresh:%%s\\n" "$(git rev-parse HEAD)" >> /actions\n' > setup/start.sh
if [ "$CASE" = fresh_retry ]; then
    cat > setup/start.sh <<'START'
#!/bin/bash
set -euo pipefail
printf 'fresh:%s\n' "$(git rev-parse HEAD)" >> /actions
touch /etc/mailinabox.conf
if [ ! -f /first-full-attempt ]; then
    touch /first-full-attempt
    exit 42
fi
START
fi
chmod +x setup/*.sh
git add . && git commit -qm v80
git tag v80
expected=$(git rev-parse 'refs/tags/v80^{commit}')
old=$(git rev-parse 'refs/tags/v77^{commit}')
git clone -q --bare /source /remote.git
git clone -q file:///remote.git /checkout
export MIAB_INSTALL_DIR=/checkout
touch /etc/mailinabox.conf
cd /checkout
git checkout -q --detach refs/tags/v77
case "$CASE" in
    shadow) git branch v80 refs/tags/v77 ;;
    dirty) echo preserved-local-edit > VERSION ;;
    ahead)
        git checkout -q main
        echo preserved-private-commit > VERSION
        git add VERSION && git commit -qm private
        old=$(git rev-parse HEAD)
        export TAG=main ;;
    fresh|fresh_retry) export MIAB_INSTALL_DIR=/fresh-checkout; rm /etc/mailinabox.conf ;;
esac
set +e
bash /fixture/setup.sh > /bootstrap-output 2>&1
result=$?
set -e
cat /bootstrap-output
case "$CASE" in
    fresh_retry)
        [ "$result" -eq 42 ]
        [ -f /etc/mailinabox.conf ]
        [ -f /var/lib/mailinabox/full-setup-in-progress ]
        [ "$(cat /actions)" = "fresh:$expected" ]
        bash /fixture/setup.sh
        [ ! -e /var/lib/mailinabox/full-setup-in-progress ]
        [ "$(wc -l < /actions)" -eq 2 ]
        [ "$(sort -u /actions)" = "fresh:$expected" ]
        bash /fixture/setup.sh
        [ ! -e /var/lib/mailinabox/full-setup-in-progress ]
        [ "$(wc -l < /actions)" -eq 3 ]
        [ "$(tail -1 /actions)" = "upgrade:$expected" ] ;;
    architecture)
        [ "$result" -ne 0 ]
        grep -F 'supports Ubuntu 22.04 amd64 only' /bootstrap-output
        [ "$(git rev-parse HEAD)" = "$old" ]
        [ ! -e /actions ] ;;
    dirty)
        [ "$result" -ne 0 ]
        grep -F 'The checkout has local changes.' /bootstrap-output
        [ "$(git rev-parse HEAD)" = "$old" ]
        [ "$(cat VERSION)" = preserved-local-edit ]
        [ ! -e /actions ] ;;
    ahead)
        [ "$result" -ne 0 ]
        grep -F 'The local branch contains unpublished commits.' /bootstrap-output
        [ "$(git rev-parse HEAD)" = "$old" ]
        [ "$(cat VERSION)" = preserved-private-commit ]
        [ ! -e /actions ] ;;
    *)
        [ "$result" -eq 0 ]
        [ "$(git -C "$MIAB_INSTALL_DIR" rev-parse HEAD)" = "$expected" ]
        ! git -C "$MIAB_INSTALL_DIR" symbolic-ref -q HEAD
        if [ "$CASE" = fresh ]; then
            [ "$(cat /actions)" = "fresh:$expected" ]
        else
            [ "$(cat /actions)" = "upgrade:$expected" ]
        fi
        if [ "$CASE" = shadow ]; then
            [ "$(git rev-parse refs/heads/v80)" = "$old" ]
        fi
        if [ "$CASE" = repeated ]; then
            bash /fixture/setup.sh
            [ "$(git rev-parse HEAD)" = "$expected" ]
            [ "$(wc -l < /actions)" -eq 2 ]
            [ "$(sort -u /actions)" = "upgrade:$expected" ]
        fi ;;
esac
echo "BOOTSTRAP_OK $CASE"
'''


class ForkBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.isfile(DOCKER):
            raise unittest.SkipTest('Docker is unavailable')
        if subprocess.run([DOCKER, 'image', 'inspect', IMAGE], capture_output=True).returncode:
            raise unittest.SkipTest('Cached Ubuntu/Git fixture image is unavailable; no image is pulled')

    def check_case(self, case):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = pathlib.Path(temporary)
            shutil.copyfile(ROOT / 'setup.sh', fixture / 'setup.sh')
            (fixture / 'test.sh').write_text(SCRIPT)
            result = subprocess.run(
                [DOCKER, 'run', '--rm', '--network', 'none', '--user', '0',
                 '-v', temporary + ':/fixture:ro', '-e', 'CASE=' + case,
                 '--entrypoint', '/bin/bash', IMAGE, '/fixture/test.sh'],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('BOOTSTRAP_OK ' + case, result.stdout)

    def test_v77_detached_uses_v80_scoped_upgrade(self):
        self.check_case('upgrade')

    def test_local_branch_cannot_shadow_release_tag(self):
        self.check_case('shadow')

    def test_dirty_checkout_is_refused_without_losing_edits(self):
        self.check_case('dirty')

    def test_unpublished_main_commit_is_refused_and_preserved(self):
        self.check_case('ahead')

    def test_repeated_v80_keeps_same_release_and_upgrade_scope(self):
        self.check_case('repeated')

    def test_new_install_clones_v80_and_uses_full_setup(self):
        self.check_case('fresh')

    def test_failed_fresh_install_retries_full_before_scoped_updates(self):
        self.check_case('fresh_retry')

    def test_unsupported_architecture_is_refused_before_upgrade(self):
        self.check_case('architecture')


if __name__ == '__main__':
    unittest.main()
