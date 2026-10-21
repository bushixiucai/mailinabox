#!/usr/bin/env python3
"""Exercise the unmodified package consumer using real, tiny Debian archives.

Only OS/architecture metadata is simulated in the cached Python container.
Verification uses real SHA256 and dpkg-deb operations, without package installs,
service operations, network access, or host system mounts.
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
FIXTURE = r'''
import hashlib, json, os, pathlib, shutil, subprocess
root = pathlib.Path('/tmp/package-fixture'); root.mkdir()
platform = root / 'bin'; platform.mkdir()
(platform / 'dpkg').write_text('#!/bin/sh\nif [ "$1" = --print-architecture ]; then echo amd64; else exec /usr/bin/dpkg "$@"; fi\n')
(platform / 'dpkg').chmod(0o755)
for name in ('apt-get', 'systemctl'):
    path = platform / name
    path.write_text('#!/bin/sh\necho "Forbidden install/service operation" >&2\nexit 98\n')
    path.chmod(0o755)
pathlib.Path('/etc/os-release').write_text('ID=ubuntu\nVERSION_ID=22.04\n')
env = os.environ | {'PATH': str(platform) + ':' + os.environ['PATH']}
locked = json.loads(pathlib.Path('/repo/tools/php-build-lock.json').read_text())['branches']['8.4']
packages = ['php8.4', *('php8.4-' + name for name in (
    'cli', 'common', 'fpm', 'bcmath', 'curl', 'gd', 'gmp', 'intl', 'mbstring',
    'opcache', 'readline', 'soap', 'sqlite3', 'xml', 'zip'))]
baseline = root / 'baseline'; baseline.mkdir()
for package in packages:
    tree = root / 'tree'; (tree / 'DEBIAN').mkdir(parents=True)
    architecture = 'all' if package == 'php8.4' else 'amd64'
    (tree / 'DEBIAN/control').write_text(
        f'Package: {package}\nVersion: {locked["package_version"]}\nArchitecture: {architecture}\n'
        'Maintainer: Fixture <fixture@example.test>\nDescription: Offline verification fixture\n')
    subprocess.run(['dpkg-deb', '--build', str(tree), str(baseline / (package + '.deb'))],
                   check=True, capture_output=True)
    shutil.rmtree(tree)
provenance = {key: locked[key] for key in ('php_version', 'package_version', 'upstream', 'dsc', 'packaging')}
provenance.update(status='built', distribution='ubuntu22.04')
(baseline / 'provenance.json').write_text(json.dumps(provenance))
def checksum(output, omit=()):
    lines = []
    for path in sorted(output.iterdir()):
        if path.name != 'SHA256SUMS' and path.name not in omit:
            lines.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ./' + path.name)
    (output / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')
def verify(output, expected, message=''):
    result = subprocess.run(['bash', '/repo/tools/install-built-php.sh', str(output), '--verify-only'],
                            env=env, capture_output=True, text=True)
    assert (result.returncode == 0) == expected, result.stdout + result.stderr
    assert message in result.stdout + result.stderr, result.stdout + result.stderr
    assert not pathlib.Path('/var/lib/mailinabox/php-maintenance').exists()
count = 0
checksum(baseline)
verify(baseline, True, 'Verified 16 source-built PHP packages')
count += 1
for package in packages:
    output = root / ('missing-' + package); shutil.copytree(baseline, output)
    (output / (package + '.deb')).unlink(); checksum(output)
    verify(output, False, 'Missing required build package: ' + package)
    count += 1
output = root / 'unverified-provenance'; shutil.copytree(baseline, output)
checksum(output, omit=('provenance.json',))
verify(output, False, 'Build provenance is not covered')
count += 1
output = root / 'extra-unverified-package'; shutil.copytree(baseline, output)
shutil.copyfile(output / 'php8.4-cli.deb', output / 'extra.deb')
verify(output, False, 'An unverified Debian package exists')
count += 1
output = root / 'tampered-archive'; shutil.copytree(baseline, output)
with (output / 'php8.4-cli.deb').open('ab') as archive: archive.write(b'tampered')
verify(output, False, 'FAILED')
count += 1
output = root / 'wrong-source'; shutil.copytree(baseline, output)
changed = json.loads((output / 'provenance.json').read_text())
changed['packaging']['sha256'] = '0' * 64
(output / 'provenance.json').write_text(json.dumps(changed)); checksum(output)
verify(output, False, 'Source provenance does not match')
count += 1
print(f'{count} real package verification cases passed')
'''


class BuiltPHPVerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.isfile(DOCKER):
            raise unittest.SkipTest('Docker is unavailable')
        if subprocess.run([DOCKER, 'image', 'inspect', IMAGE], capture_output=True).returncode:
            raise unittest.SkipTest('Cached Python fixture image is unavailable; no image is pulled')

    def test_complete_packages_and_checksum_coverage_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = pathlib.Path(temporary) / 'verify.py'
            script.write_text(FIXTURE)
            result = subprocess.run(
                [DOCKER, 'run', '--rm', '--network', 'none', '--user', '0',
                 '-v', str(ROOT) + ':/repo:ro', '-v', temporary + ':/fixture:ro',
                 IMAGE, 'python3', '/fixture/verify.py'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('21 real package verification cases passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
