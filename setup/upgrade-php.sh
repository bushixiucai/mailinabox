#!/bin/bash
# Upgrade the PHP applications without reconfiguring SMTP, IMAP, DNS or certificates.
(
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source setup/functions.sh
[ "${EUID}" -eq 0 ] || { echo 'Run this script as root.' >&2; exit 1; }
source /etc/mailinabox.conf

# Refresh repositories before selecting packages or the locked source build.
apt-get update -qq

exec 9>/var/lock/mailinabox-php-upgrade.lock
flock -n 9 || { echo 'Another PHP upgrade is running.' >&2; exit 1; }
install -d -m 755 /var/lib/mailinabox
php_upgrade_backup="$STORAGE_ROOT/php-upgrade-backups/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$php_upgrade_backup"
printf '%s\n' "$php_upgrade_backup" > /var/lib/mailinabox/php-upgrade-backup
# Preserve the original web configuration and unit states before closing routes.
if [ -d /etc/nginx ]; then
	tar -C / -czf "$php_upgrade_backup/nginx-original.tar.gz" etc/nginx
fi
systemctl list-unit-files 'php*-fpm.service' > "$php_upgrade_backup/fpm-unit-states.txt"
install -m 644 /dev/null "$PHP_MAINTENANCE_FILE"

# Regenerate from the new checkout, not a management daemon using an old module.
regenerate_web() {
	if [ -x /usr/local/lib/mailinabox/env/bin/python3 ]; then
		PYTHONPATH="$PWD/management" /usr/local/lib/mailinabox/env/bin/python3 - <<'PY'
from utils import load_environment
from web_update import do_web_update
print(do_web_update(load_environment()), end='')
PY
	fi
}

# A failure deliberately leaves the maintenance marker and PHP workers stopped.
trap 'install -m 644 /dev/null "$PHP_MAINTENANCE_FILE"; systemctl stop "php$PHP_VER-fpm.service" 2>/dev/null || true; echo "PHP upgrade did not complete. Maintenance remains enabled. Backup: $php_upgrade_backup" >&2' ERR
if [ -f /etc/cron.d/mailinabox-nextcloud ]; then
	mv /etc/cron.d/mailinabox-nextcloud "$php_upgrade_backup/nextcloud.cron"
fi
for unit in $(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '{print $1}'); do
	systemctl mask --now "$unit"
done
# Mask the final unit before apt can create and automatically start it.
systemctl mask --now "php$PHP_VER-fpm.service"
# Apply maintenance responses before package operations can change code.
regenerate_web
if command -v nginx >/dev/null 2>&1; then nginx -t; fi
# Wait for any already-started background jobs before copying their databases.
if pgrep -f '(^|/)(php[0-9.]*)([[:space:]]).*owncloud/(cron.php|occ)' >/dev/null; then
	echo 'Nextcloud background jobs are still running. Retry when they have finished.' >&2
	exit 1
fi

# Preserve the complete application data and configuration before any schema migration.
for directory in /etc/php /etc/nginx /usr/local/lib/owncloud /usr/local/lib/roundcubemail /usr/local/lib/z-push; do
	if [ -d "$directory" ]; then
		tar -C / -czf "$php_upgrade_backup/$(basename "$directory")-$(echo "$directory" | tr / _).tar.gz" "${directory#/}"
	fi
done
cp -a /etc/mailinabox.conf "$php_upgrade_backup/"
for directory in "$STORAGE_ROOT/owncloud" "$STORAGE_ROOT/mail/roundcube" /var/lib/z-push; do
	if [ -d "$directory" ]; then
		tar -C / -czf "$php_upgrade_backup/data-$(echo "$directory" | tr / _).tar.gz" "${directory#/}"
	fi
done

# Rebuild the locked official release if patched distribution packages lag behind.
# Keep builds isolated and install only the resulting PHP packages, never Apache.
if ! require_safe_php_candidate "$PHP_VER"; then
	php_upgrade_build="$php_upgrade_backup/php-build"
	mkdir -p "$php_upgrade_build"
	php_upgrade_release=$(git describe --tags --exact-match 2>/dev/null || true)
	php_upgrade_source_version=$(python3 -c 'import json,sys; print(json.load(open("tools/php-build-lock.json"))["branches"][sys.argv[1]]["php_version"])' "$PHP_VER")
	php_upgrade_bundle="php-$php_upgrade_source_version-ubuntu22.04-amd64.tar.xz"
	php_upgrade_release_url="https://github.com/bushixiucai/mailinabox/releases/download/$php_upgrade_release"
	php_upgrade_fetched=0
	if [ -n "$php_upgrade_release" ] && [ "$(dpkg --print-architecture)" = amd64 ]; then
		if curl -fLsS --retry 3 --connect-timeout 20 --max-time 300 "$php_upgrade_release_url/$php_upgrade_bundle" -o "$php_upgrade_build/$php_upgrade_bundle" && \
			curl -fLsS --retry 3 --connect-timeout 20 --max-time 300 "$php_upgrade_release_url/$php_upgrade_bundle.sha256" -o "$php_upgrade_build/$php_upgrade_bundle.sha256"; then
			(cd "$php_upgrade_build"; sha256sum --check --strict "$php_upgrade_bundle.sha256")
			tar -xJf "$php_upgrade_build/$php_upgrade_bundle" -C "$php_upgrade_build"
			php_upgrade_fetched=1
		fi
	fi
	if [ "$php_upgrade_fetched" = 0 ]; then
		if ! command -v docker >/dev/null 2>&1 && [ ! -x /usr/local/bin/docker ]; then
			apt_install docker.io
		fi
		php_upgrade_build="$php_upgrade_build/source"
		PHP_BUILD_JOBS=${PHP_BUILD_JOBS:-4} tools/build-php.sh "$php_upgrade_build"
	fi
	tools/install-built-php.sh "$php_upgrade_build"
fi
require_safe_php_candidate "$PHP_VER"

# These scripts defer all PHP restarts while the maintenance marker exists.
source setup/web.sh
source setup/webmail.sh
source setup/nextcloud.sh
source setup/zpush.sh
require_safe_php "$PHP_VER"
/usr/sbin/php-fpm"$PHP_VER" -t

regenerate_web
nginx -t
# Reload the generator in the running management daemon before reopening traffic.
if systemctl cat mailinabox.service >/dev/null 2>&1; then
	systemctl try-restart mailinabox.service
fi

# Old FPM services must remain unable to start after a reboot or package update.
for unit in $(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '{print $1}'); do
	if [ "$unit" != "php$PHP_VER-fpm.service" ]; then
		systemctl mask --now "$unit"
	fi
done
systemctl unmask "php$PHP_VER-fpm.service"
systemctl enable "php$PHP_VER-fpm.service"
systemctl restart "php$PHP_VER-fpm.service"
[ -S /run/php/mailinabox-fpm.sock ]

# Opening web traffic is the last step. If regeneration fails, close it again.
rm "$PHP_MAINTENANCE_FILE"
if ! regenerate_web || ! nginx -t; then
	install -m 644 /dev/null "$PHP_MAINTENANCE_FILE"
	regenerate_web || true
	systemctl stop "php$PHP_VER-fpm.service"
	exit 1
fi
trap - ERR
printf 'PHP applications upgraded. Backup: %s\n' "$php_upgrade_backup"
)
