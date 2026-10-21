#!/usr/bin/env python3
"""Run the unmodified orchestrator inside a cached, network-isolated container.

All service/package commands and application setup scripts are fixtures. Absolute
system paths are confined to the disposable container, never mapped to the host.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DOCKER = shutil.which('docker') or '/usr/local/bin/docker'
IMAGE = 'python:3.10-slim'


class PHPUpgradeOrchestrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.isfile(DOCKER):
            raise unittest.SkipTest('Docker is unavailable')
        probe = subprocess.run([DOCKER, 'image', 'inspect', IMAGE], capture_output=True)
        if probe.returncode:
            raise unittest.SkipTest('Cached test container is unavailable; no image is pulled')

    def exercise(self, failure='', service_exists='no', initial_nginx=True):
        with tempfile.TemporaryDirectory() as temporary:
            fixture = pathlib.Path(temporary)
            checkout = fixture / 'checkout'
            (checkout / 'setup').mkdir(parents=True)
            (checkout / 'bin').mkdir()
            for name in ['upgrade-php.sh', 'functions.sh']:
                shutil.copyfile(ROOT / 'setup' / name, checkout / 'setup' / name)
            for name in ['web', 'webmail', 'nextcloud', 'zpush']:
                (checkout / 'setup' / (name + '.sh')).write_text(
                    f'echo "stage {name}" >> /events\n'
                    f'if [ "$FAILURE" = "{name}" ]; then false; fi\n'
                    + ('cp /work/bin/nginx.fixture /work/bin/nginx\n' if name == 'web' else ''))
            commands = {
                'apt-get': 'echo "apt $*" >> /events\n',
                'apt-cache': 'printf "  Candidate: 8.4.27-1\\n"\n',
                'php8.4': 'echo 8.4.27\n',
                'pgrep': 'exit 1\n',
                'nginx': 'echo "nginx $*" >> /events\n',
                'systemctl': '''echo "systemctl $*" >> /events
case "$1" in
    list-unit-files) printf 'php8.0-fpm.service enabled\\nphp8.4-fpm.service masked\\n' ;;
    cat) [ "$SERVICE_EXISTS" = yes ] ;;
    restart)
        if [ "$2" = php8.4-fpm.service ]; then
            python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.bind("/run/php/mailinabox-fpm.sock")'
        fi ;;
esac
''',
            }
            for name, body in commands.items():
                path = checkout / 'bin' / (name + '.fixture' if name == 'nginx' else name)
                path.write_text('#!/bin/bash\n' + body)
                path.chmod(0o755)
                if name == 'nginx' and initial_nginx:
                    shutil.copyfile(path, checkout / 'bin/nginx')
                    (checkout / 'bin/nginx').chmod(0o755)
            (fixture / 'run.sh').write_text('''#!/bin/bash
set -e
cp -a /fixture/checkout /work
export PATH=/work/bin:$PATH
mkdir -p /storage /etc/nginx/conf.d /run/php /usr/local/lib/mailinabox/env/bin /etc/default /etc/postfix
cat > /etc/default/postgrey <<'POSTGREY'
POSTGREY_OPTS="--inet=127.0.0.1:10023 --delay=0"
POSTGREY
cat > /etc/postfix/main.cf <<'POSTFIX'
smtpd_sender_restrictions = reject_non_fqdn_sender, permit_sasl_authenticated
smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination
# Preserve operator settings byte for byte.
POSTFIX
sha256sum /etc/default/postgrey /etc/postfix/main.cf > /mail-config-before.sha256
printf 'STORAGE_ROOT=/storage\\n' > /etc/mailinabox.conf
cat > /usr/sbin/php-fpm8.4 <<'PHP'
#!/bin/bash
[ "$1" != -v ] || echo 'PHP 8.4.27 (fpm-fcgi)'
PHP
chmod +x /usr/sbin/php-fpm8.4
cat > /usr/local/lib/mailinabox/env/bin/python3 <<'GENERATOR'
#!/bin/bash
cat >/dev/null
echo "regenerate marker=$([ -e /var/lib/mailinabox/php-maintenance ] && echo closed || echo open)" >> /events
if [ "$FAILURE" = reopening ] && [ ! -e /var/lib/mailinabox/php-maintenance ]; then exit 31; fi
GENERATOR
chmod +x /usr/local/lib/mailinabox/env/bin/python3
set +e
bash /work/setup/upgrade-php.sh
result=$?
sha256sum --check --strict /mail-config-before.sha256
echo MAIL_CONFIG_UNCHANGED
echo "RESULT=$result"
[ ! -e /var/lib/mailinabox/php-maintenance ] || echo 'MARKER=closed'
cat /events
exit 0
''')
            result = subprocess.run(
                [DOCKER, 'run', '--rm', '--network', 'none', '-v', temporary + ':/fixture:ro',
                 '-e', 'FAILURE=' + failure, '-e', 'SERVICE_EXISTS=' + service_exists,
                 IMAGE, 'bash', '/fixture/run.sh'], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("MAIL_CONFIG_UNCHANGED", result.stdout)
            return result.stdout

    def test_application_failure_keeps_maintenance_and_never_starts_fpm(self):
        output = self.exercise('webmail')
        self.assertIn('RESULT=1', output)
        self.assertIn('MARKER=closed', output)
        self.assertIn('systemctl stop php8.4-fpm.service', output)
        self.assertNotIn('systemctl unmask', output)
        self.assertNotIn('stage nextcloud', output)
        self.assertLess(output.index('regenerate marker=closed'), output.index('stage web'))

    def test_reopening_failure_restores_maintenance_and_stops_fpm(self):
        output = self.exercise('reopening')
        self.assertIn('RESULT=1', output)
        self.assertIn('MARKER=closed', output)
        self.assertIn('regenerate marker=open', output)
        self.assertIn('systemctl stop php8.4-fpm.service', output)
        self.assertLess(output.index('regenerate marker=open'), output.rindex('regenerate marker=closed'))

    def test_fresh_install_can_install_nginx_after_maintenance_preflight(self):
        output = self.exercise(initial_nginx=False)
        self.assertIn('RESULT=0', output)
        self.assertLess(output.index('stage web'), output.index('nginx -t'))

    def test_fresh_install_does_not_restart_missing_management_unit(self):
        output = self.exercise()
        self.assertIn('RESULT=0', output)
        self.assertNotIn('MARKER=closed', output)
        self.assertNotIn('systemctl try-restart', output)
        self.assertIn('systemctl restart php8.4-fpm.service', output)
        self.assertLess(output.index('systemctl mask --now php8.4-fpm.service'), output.index('stage web'))


if __name__ == '__main__':
    unittest.main()
