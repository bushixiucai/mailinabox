#!/usr/bin/env python3
"""Exercise migration planning and occ's nonstandard success exit status."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPERS = ROOT / 'setup/nextcloud-migration.sh'
MANIFEST = ROOT / 'setup/nextcloud-versions.txt'


class NextcloudMigrationTests(unittest.TestCase):
    def plan(self, version, reinstall='0'):
        return subprocess.run(
            ['bash', '-c', 'source "$1"; nextcloud_plan "$2" "$3" "$4"',
             'test', str(HELPERS), version, str(MANIFEST), reinstall],
            text=True, capture_output=True)

    def test_new_install_uses_only_final_release(self):
        rows = self.plan('').stdout.splitlines()
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0].startswith('34.0.5 8.4 '))

    def test_major_versions_are_not_skipped_and_bridge_is_retained(self):
        result = self.plan('27.1.11.2')
        self.assertEqual(result.returncode, 0, result.stderr)
        stages = [row.split()[:2] for row in result.stdout.splitlines()]
        self.assertEqual(stages, [
            ['28.0.14', '8.2'], ['29.0.16', '8.2'], ['30.0.17', '8.2'],
            ['31.0.14', '8.2'], ['32.0.15', '8.4'], ['33.0.10', '8.4'],
            ['34.0.5', '8.4']])

    def test_current_major_is_patched_before_next_major(self):
        self.assertTrue(self.plan('27.1.10').stdout.startswith('27.1.11 '))

    def test_current_target_is_idempotent(self):
        result = self.plan('34.0.5.1')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertTrue(self.plan('34.0.5.1', '1').stdout.startswith('34.0.5 '))

    def test_unsafe_versions_fail_closed(self):
        for version in ['26.0.13', '35.0.2', '34.0.6', 'unknown', '27']:
            with self.subTest(version=version):
                self.assertNotEqual(self.plan(version).returncode, 0)

    def test_interrupted_upgrade_resumes_from_database_version(self):
        result = self.plan('30.0.17.1')
        self.assertTrue(result.stdout.startswith('31.0.14 8.2 '))

    def test_pins_have_real_sha256_and_nc30_has_no_external_app(self):
        rows = [line.split() for line in MANIFEST.read_text().splitlines()
                if line and not line.startswith('#')]
        self.assertEqual(len(rows), 8)
        for row in rows:
            self.assertEqual(len(row), 9)
            for index in [2, 4, 6, 8]:
                if row[index] != '-':
                    self.assertRegex(row[index], r'^[0-9a-f]{64}$')
            if row[0].startswith('30.'):
                self.assertEqual(row[7:], ['-', '-'])

    def test_occ_status_three_is_success_with_errexit(self):
        for status in [0, 3, 1, 2, 255]:
            with self.subTest(status=status):
                result = subprocess.run(
                    ['bash', '-c', 'set -e; source "$1"; '
                     'sudo() { return "$MOCK_STATUS"; }; '
                     'nextcloud_occ_upgrade 8.2; echo completed', 'test', str(HELPERS)],
                    env={'MOCK_STATUS': str(status), 'PATH': '/usr/bin:/bin'},
                    text=True, capture_output=True)
                self.assertEqual(result.returncode, 0 if status in [0, 3] else status)
                self.assertEqual('completed' in result.stdout, status in [0, 3])


if __name__ == '__main__':
    unittest.main()
