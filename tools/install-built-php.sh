#!/bin/bash
# Install verified, locally built Debian PHP packages without enabling web workers.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source setup/functions.sh
[ "$EUID" -eq 0 ] || { echo 'Run this script as root.' >&2; exit 1; }
source /etc/os-release
[ "$ID:$VERSION_ID" = ubuntu:22.04 ] || { echo 'Ubuntu 22.04 is required.' >&2; exit 1; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'Usage: sudo tools/install-built-php.sh BUILD_OUTPUT [--verify-only]' >&2; exit 1; }
php_build_mode=${2:-install}
[ "$php_build_mode" = install ] || [ "$php_build_mode" = --verify-only ] || exit 1
php_build_output=$(realpath "$1")
[ -f "$php_build_output/SHA256SUMS" ]
[ -f "$php_build_output/provenance.json" ]
(cd "$php_build_output"; sha256sum --check --strict SHA256SUMS)
python3 - "$php_build_output" tools/php-build-lock.json <<'PY'
import json, pathlib, sys
output = pathlib.Path(sys.argv[1])
p = json.loads((output / 'provenance.json').read_text())
locked = json.load(open(sys.argv[2]))['branches']['8.4']
for field in ('upstream', 'dsc', 'packaging'):
    if p.get(field, {}).get('sha256') != locked[field]['sha256']:
        sys.exit('Source provenance does not match the reviewed build lock: ' + field)
checked = {line.split(None, 1)[1].lstrip('*').removeprefix('./')
           for line in (output / 'SHA256SUMS').read_text().splitlines() if line.strip()}
if 'provenance.json' not in checked:
    sys.exit('Build provenance is not covered by the verified checksum manifest.')
if any(archive.name not in checked for archive in output.glob('*.deb')):
    sys.exit('An unverified Debian package exists in the build output.')
if any(p.get(key) != locked[key] for key in ('php_version', 'package_version')):
    sys.exit('Unexpected PHP build provenance. Review a new pinned build before installing.')
if p.get('status') != 'built':
    sys.exit('Build has not completed successfully.')
if p.get('distribution') != 'ubuntu22.04':
    sys.exit('This installer requires an Ubuntu 22.04 build.')
PY
php_build_expected_version=$(python3 -c 'import json; print(json.load(open("tools/php-build-lock.json"))["branches"]["8.4"]["package_version"])')
php_build_arch=$(dpkg --print-architecture)
php_build_packages=()
php_build_names=' '
for archive in "$php_build_output"/*.deb; do
	package=$(dpkg-deb -f "$archive" Package)
	case "$package" in
		php8.4|php8.4-cli|php8.4-common|php8.4-fpm|php8.4-bcmath|php8.4-curl|php8.4-gd|php8.4-gmp|php8.4-intl|php8.4-mbstring|php8.4-opcache|php8.4-readline|php8.4-soap|php8.4-sqlite3|php8.4-xml|php8.4-zip) ;;
		*) continue ;;
	esac
	[ "$(dpkg-deb -f "$archive" Version)" = "$php_build_expected_version" ]
	architecture=$(dpkg-deb -f "$archive" Architecture)
	[ "$architecture" = all ] || [ "$architecture" = "$php_build_arch" ]
	php_build_packages+=("$archive")
	php_build_names+="$package "
done
# Require every core package used by setup and its production PHP modules.
# Independently packaged PECL extensions are installed through the configured repository.
for package in php8.4 php8.4-cli php8.4-common php8.4-fpm php8.4-bcmath php8.4-curl \
	php8.4-gd php8.4-gmp php8.4-intl php8.4-mbstring php8.4-opcache php8.4-readline \
	php8.4-soap php8.4-sqlite3 php8.4-xml php8.4-zip; do
	[[ "$php_build_names" == *" $package "* ]] || { echo "Missing required build package: $package" >&2; exit 1; }
done

if [ "$php_build_mode" = --verify-only ]; then
	printf 'Verified %s source-built PHP packages; no system changes made.\n' "${#php_build_packages[@]}"
	exit 0
fi

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
