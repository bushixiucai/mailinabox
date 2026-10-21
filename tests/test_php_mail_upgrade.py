"""Offline regression tests for staged mail upgrades and runtime wrapper refresh."""

import io
import os
import shutil
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class MailUpgradeTests(unittest.TestCase):
    def test_roundcube_plugin_failure_preserves_live_installation(self):
        self.check_roundcube_staging(fail_plugin=True)

    def test_roundcube_complete_staging_retains_previous_installation(self):
        self.check_roundcube_staging(fail_plugin=False)

    def check_roundcube_staging(self, fail_plugin):
        source = (REPO / "setup/webmail.sh").read_text()
        # Exercise the real installation block with tiny local archives and no network.
        block = source[source.index("VERSION="):source.index("# ### Configuring Roundcube")]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            live = root / "roundcubemail"
            live.mkdir()
            (live / "version").write_text("old")
            (live / "preserve-me").write_text("original")
            for name, member in (
                ("roundcube.tgz", "roundcubemail-1.7.5/public_html/index.php"),
                ("carddav.tgz", "carddav/carddav.php"),
            ):
                with tarfile.open(root / name, "w:gz") as archive:
                    data = b"<?php // Offline installation fixture\n"
                    entry = tarfile.TarInfo(member)
                    entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data))
            mocks = r'''
set -euo pipefail
wget_verify() {
    case "$1" in
        *roundcubemail*) cp "$TEST_ROOT/roundcube.tgz" "$3" ;;
        *carddav*) cp "$TEST_ROOT/carddav.tgz" "$3" ;;
        *) return 99 ;;
    esac
}
git_clone() {
    if [ "$FAIL_PLUGIN" = yes ] && [[ "$1" == *html5_notifier* ]]; then return 23; fi
    mkdir -p "$4"
    touch "$4/installed"
}
'''
            result = subprocess.run(
                ["bash", "-c", mocks + block.replace("/usr/local/lib", temporary)],
                env=os.environ | {"TEST_ROOT": temporary, "FAIL_PLUGIN": "yes" if fail_plugin else "no"},
                text=True, capture_output=True,
            )
            if fail_plugin:
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertEqual((live / "version").read_text(), "old")
                self.assertEqual((live / "preserve-me").read_text(), "original")
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((live / "version").read_text().startswith("1.7.5:"))
                self.assertTrue((live / "public_html/index.php").is_file())
                for plugin in ("persistent_login", "html5_notifier"):
                    self.assertTrue((live / "plugins" / plugin / "installed").is_file())
                self.assertTrue((live / "plugins/carddav/carddav.php").is_file())
                previous = list(root.glob("roundcubemail-install.*/previous/preserve-me"))
                self.assertEqual(len(previous), 1)
                self.assertEqual(previous[0].read_text(), "original")

    def test_roundcube_encryption_key_survives_source_replacement(self):
        php = shutil.which("php") or "/opt/homebrew/opt/php@8.4/bin/php"
        if not Path(php).is_file():
            self.skipTest("PHP CLI is unavailable")
        source = (REPO / "setup/webmail.sh").read_text()
        capture = source.split("# Preserve the installation encryption key", 1)[1].split("needs_update=", 1)[0]
        generate = source.split("# Generate a secret key", 1)[1].split("# Create a configuration file.", 1)[0]
        # Keep comments in extracted production code syntactically intact.
        capture = "# Preserve the installation encryption key" + capture
        generate = "# Generate a secret key" + generate
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "config.php"
            secret = "existing-$-key-with-'quote-and-\\slash"
            literal = subprocess.check_output([php, "-r", "echo var_export($argv[1], true);", secret], text=True)
            config.write_text("<?php $config = ['des_key' => " + literal + "];\n")
            script = ('set -euo pipefail\nPHP_VER=8.4\n'
                      'php8.4() { "$TEST_PHP" "$@"; }\n' + capture
                      + '\nrm "$RCM_CONFIG"\n' + generate
                      + '\nprintf "%s" "$RCM_SECRET_KEY_LITERAL"\n')
            result = subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                                    env=os.environ | {"RCM_CONFIG": str(config), "TEST_PHP": php})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, literal)
            decoded = subprocess.check_output([php, "-r", "$key = " + result.stdout + "; echo $key;"], text=True)
            self.assertEqual(decoded, secret)

    def test_zpush_runtime_refresh_preserves_arguments(self):
        source = (REPO / "setup/zpush.sh").read_text()
        block = source.split("# Refresh wrappers even when only the PHP runtime changes.\n", 1)[1]
        block = block.split("# Configure default config.", 1)[0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            (root / "sbin").mkdir()
            php = root / "bin/php8.4"
            php.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n')
            php.chmod(0o755)
            env = os.environ | {"PHP_VER": "8.4", "PATH": str(root / "bin") + ":" + os.environ["PATH"]}
            for command in ("admin", "top"):
                (root / "sbin" / ("z-push-" + command)).write_text("obsolete PHP 8.0 wrapper")
            subprocess.run(
                ["bash", "-c", block.replace("/usr/sbin", str(root / "sbin"))],
                env=env, check=True,
            )
            arguments = ["a b", "*.php", "$literal", ""]
            for command in ("admin", "top"):
                result = subprocess.check_output(
                    [str(root / "sbin" / ("z-push-" + command)), *arguments], env=env, text=True,
                )
                self.assertEqual(
                    result.splitlines(), [f"/usr/local/lib/z-push/z-push-{command}.php", *arguments],
                )


if __name__ == "__main__":
    unittest.main()
