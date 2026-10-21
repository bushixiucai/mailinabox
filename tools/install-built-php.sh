#!/bin/bash
# Install verified, locally built Debian PHP packages without enabling web workers.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source setup/functions.sh
[ "$EUID" -eq 0 ] || { echo 'Run this script as root.' >&2; exit 1; }
[ "$#" -eq 1 ] || { echo 'Usage: sudo tools/install-built-php.sh BUILD_OUTPUT' >&2; exit 1; }
php_build_output=$(realpath "$1")
[ -f "$php_build_output/SHA256SUMS" ]
[ -f "$php_build_output/provenance.json" ]
(cd "$php_build_output"; sha256sum --check --strict SHA256SUMS)
python3 - "$php_build_output/provenance.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
if p.get('php_version') != '8.4.27' or p.get('package_version') != '8.4.27-1+urmail1':
    sys.exit('Unexpected PHP build provenance. Review a new pinned build before installing.')
if p.get('status') != 'built':
    sys.exit('Build has not completed successfully.')
if p.get('distribution') != 'ubuntu22.04':
    sys.exit('This installer requires an Ubuntu 22.04 build.')
PY
php_build_arch=$(dpkg --print-architecture)
php_build_packages=()
php_build_names=' '
for archive in "$php_build_output"/*.deb; do
	package=$(dpkg-deb -f "$archive" Package)
	case "$package" in
		php8.4|php8.4-cli|php8.4-common|php8.4-fpm|php8.4-bcmath|php8.4-curl|php8.4-gd|php8.4-gmp|php8.4-intl|php8.4-mbstring|php8.4-opcache|php8.4-readline|php8.4-soap|php8.4-sqlite3|php8.4-xml|php8.4-zip) ;;
		*) continue ;;
	esac
	[ "$(dpkg-deb -f "$archive" Version)" = 8.4.27-1+urmail1 ]
	architecture=$(dpkg-deb -f "$archive" Architecture)
	[ "$architecture" = all ] || [ "$architecture" = "$php_build_arch" ]
	php_build_packages+=("$archive")
	php_build_names+="$package "
done
for package in php8.4-cli php8.4-common php8.4-fpm php8.4-sqlite3 php8.4-curl php8.4-xml; do
	[[ "$php_build_names" == *" $package "* ]] || { echo "Missing required build package: $package" >&2; exit 1; }
done

# The existing web application installation is untouched. Keep old and new FPM
# units masked until setup/upgrade-php.sh finishes database and application checks.
install -d -m 755 /var/lib/mailinabox
install -m 644 /dev/null "$PHP_MAINTENANCE_FILE"
for unit in $(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '{print $1}'); do
	systemctl mask --now "$unit"
done
systemctl mask --now "php$PHP_VER-fpm.service"
DEBIAN_FRONTEND=noninteractive apt-get install -y "${php_build_packages[@]}"
require_safe_php "$PHP_VER"
/usr/sbin/php-fpm"$PHP_VER" -t
printf 'Source-built PHP installed with FPM disabled. Next: sudo setup/upgrade-php.sh\n'
