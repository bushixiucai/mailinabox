#!/bin/bash
# Shared, side-effect-free helpers for the archive-based Nextcloud migration.

nextcloud_plan() {
	python3 - "$1" "$2" "${3:-0}" <<'PY'
import pathlib
import sys

current, manifest, reinstall = sys.argv[1:]
rows = [line.split() for line in pathlib.Path(manifest).read_text().splitlines()
        if line.strip() and not line.startswith('#')]
if not current:
    print(' '.join(rows[-1]))
    sys.exit(0)
try:
    installed = tuple(map(int, current.split('.')[:3]))
    if len(installed) != 3:
        raise ValueError()
except ValueError:
    sys.exit('Invalid installed Nextcloud version: ' + current)
if installed[0] < 27:
    sys.exit('Upgrade older Mail-in-a-Box installations to Nextcloud 27 first.')
target = tuple(map(int, rows[-1][0].split('.')))
if installed > target:
    sys.exit('Refusing to downgrade Nextcloud: ' + current)
for row in rows:
    version = tuple(map(int, row[0].split('.')))
    if version[0] < installed[0]:
        continue
    if version[0] == installed[0] and version < installed:
        sys.exit('Installed maintenance release is newer than the pinned migration step.')
    if version > installed or (reinstall == '1' and version == installed):
        print(' '.join(row))
PY
}

nextcloud_occ_upgrade() {
	local result=0
	# occ uses exit status 3 for an already-current database. Keep set -e enabled.
	sudo -u www-data "php$1" /usr/local/lib/owncloud/occ upgrade || result=$?
	if [ "$result" -ne 0 ] && [ "$result" -ne 3 ]; then
		echo "Nextcloud upgrade failed (exit $result). PHP maintenance remains active." >&2
		return "$result"
	fi
}

nextcloud_download() {
	local url=$1 hash=$2 destination=$3
	wget --quiet --timeout=60 --tries=3 -O "$destination" "$url"
	if ! printf '%s  %s\n' "$hash" "$destination" | sha256sum --check --strict; then
		rm -f "$destination"
		echo "Nextcloud archive checksum mismatch: $url" >&2
		return 1
	fi
}
