#!/bin/bash
# Build native Ubuntu packages from locked official PHP and Debian packaging sources.
# Usage: tools/build-php.sh [--prepare-only] [--branch 8.4] [OUTPUT_DIRECTORY]
# Optional: DOCKER_BIN, PHP_BUILD_JOBS (default 4), PHP_SOURCE_CACHE (read-only inputs).
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lock_file=$script_dir/php-build-lock.json

if [ "${1:-}" != --inside-builder ]; then
	branch=8.4
	prepare_only=0
	output=
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--prepare-only) prepare_only=1; shift ;;
			--branch) branch=${2:?Missing branch}; shift 2 ;;
			--help|-h) sed -n '2,4p' "$0"; exit 0 ;;
			-*) echo "Unknown option: $1" >&2; exit 1 ;;
			*) [ -z "$output" ] || { echo 'Only one output directory is allowed.' >&2; exit 1; }; output=$1; shift ;;
		esac
	done
	image=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["branches"][sys.argv[2]]; print(p["base_image"])' "$lock_file" "$branch")
	jobs=${PHP_BUILD_JOBS:-4}
	[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo 'PHP_BUILD_JOBS must be a positive integer.' >&2; exit 1; }
	if [ -z "$output" ]; then output=$(mktemp -d "${TMPDIR:-/tmp}/urmail-php-build.XXXXXX"); fi
	mkdir -p "$output"
	output=$(cd "$output" && pwd)
	[ -z "$(ls -A "$output")" ] || { echo 'Use an empty output directory to avoid mixing builds.' >&2; exit 1; }
	docker_bin=${DOCKER_BIN:-docker}
	if ! command -v "$docker_bin" >/dev/null 2>&1 && [ -x /usr/local/bin/docker ]; then docker_bin=/usr/local/bin/docker; fi
	cache_mount=()
	if [ -n "${PHP_SOURCE_CACHE:-}" ]; then
		cache_dir=$(cd "$PHP_SOURCE_CACHE" && pwd)
		cache_mount=(--mount "type=bind,source=$cache_dir,target=/source-cache,readonly")
	fi
	echo "Building PHP $branch for Ubuntu 22.04 amd64. Output: $output"
	"$docker_bin" run --rm --init --platform linux/amd64 \
		--mount "type=bind,source=$script_dir,target=/input,readonly" \
		--mount "type=bind,source=$output,target=/output" "${cache_mount[@]}" \
		-e PHP_BUILD_BRANCH="$branch" -e PHP_BUILD_JOBS="$jobs" -e PHP_PREPARE_ONLY="$prepare_only" \
		"$image" /bin/bash /input/build-php.sh --inside-builder 2>&1 | tee "$output/build.log"
	exit 0
fi

# Never install build dependencies on the caller's host.
[ -e /.dockerenv ] || { echo 'The internal builder must run in Docker.' >&2; exit 1; }
source /etc/os-release
[ "$ID:$VERSION_ID" = ubuntu:22.04 ]
[ "$(dpkg --print-architecture)" = amd64 ]
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl python3 dpkg-dev quilt \
	build-essential devscripts equivs
mkdir -p /build /output/inputs
cp "$lock_file" /output/php-build-lock.json
sha256sum "$0" > /output/build-script.sha256

python3 - "$lock_file" "$PHP_BUILD_BRANCH" > /build/locked.env <<'PY'
import json, shlex, sys
lock = json.load(open(sys.argv[1]))
branch = lock['branches'][sys.argv[2]]
values = {**{k: v for k, v in branch.items() if isinstance(v, str)}, 'build_date': lock['build_date']}
for kind in ('upstream', 'dsc', 'packaging'):
    for key, value in branch[kind].items():
        values[kind + '_' + key] = value
for key, value in values.items():
    print('locked_' + key + '=' + shlex.quote(value))
PY
source /build/locked.env
fetch_locked() {
	local filename=$1 url=$2 hash=$3
	if [ -f "/source-cache/$filename" ]; then
		cp "/source-cache/$filename" "/output/inputs/$filename"
	else
		curl --fail --location --show-error --retry 4 --retry-delay 3 \
			--connect-timeout 30 --max-time 600 "$url" -o "/output/inputs/$filename"
	fi
	printf '%s  %s\n' "$hash" "/output/inputs/$filename" | sha256sum --check --strict
}
fetch_locked "$locked_upstream_filename" "$locked_upstream_url" "$locked_upstream_sha256"
fetch_locked "$locked_dsc_filename" "$locked_dsc_url" "$locked_dsc_sha256"
fetch_locked "$locked_packaging_filename" "$locked_packaging_url" "$locked_packaging_sha256"

# Cross-check the pinned packaging archive and upstream against the signed source manifest.
python3 - "$lock_file" "$PHP_BUILD_BRANCH" /output/inputs <<'PY'
import json, pathlib, re, sys
branch = json.load(open(sys.argv[1]))['branches'][sys.argv[2]]
dsc = (pathlib.Path(sys.argv[3]) / branch['dsc']['filename']).read_text()
assert re.search(r'^Version: ' + re.escape(branch['packaging_version']) + r'$', dsc, re.M)
for artifact in ('upstream', 'packaging'):
    assert branch[artifact]['sha256'] in dsc, artifact + ' is inconsistent with the pinned .dsc'
PY
tar -C /build -xJf "/output/inputs/$locked_upstream_filename"
cd "/build/php-$locked_php_version"
tar -xJf "/output/inputs/$locked_packaging_filename"
[ "$(cat debian/phpapi)" = "$locked_php_api" ]
dpkg-source --before-build .

# Use a fixed local changelog date, preserving all distribution patches and file layouts.
python3 - "$locked_package_version" "$locked_php_version" "$locked_build_date" <<'PY'
import pathlib, sys
version, php, date = sys.argv[1:]
p = pathlib.Path('debian/changelog')
p.write_text(f'php{php.rsplit(".", 1)[0]} ({version}) jammy; urgency=high\n\n'
             f'  * Rebuild the verified official PHP {php} release for urMail.\n\n'
             f' -- urMail Build <root@localhost>  {date}\n\n' + p.read_text())
PY
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(dpkg-parsechangelog -S Timestamp)
export DEB_BUILD_OPTIONS="nocheck parallel=$PHP_BUILD_JOBS" DEB_BUILD_PROFILES=nocheck
if [ "$PHP_PREPARE_ONLY" = 1 ]; then
	printf 'All locked downloads verified; distribution patches applied; PHP API %s preserved.\n' "$locked_php_api" | tee /output/prepare-checks.txt
	exit 0
fi

mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' debian/control
dpkg-checkbuilddeps
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /output/build-dependencies.tsv
dpkg-buildpackage -b -us -uc -j"$PHP_BUILD_JOBS"
cp /build/*.deb /build/*.buildinfo /build/*.changes /output/

# Verify generated identities, retained extension ABI, and executable CLI/FPM versions.
mkdir /build/runtime
for package in /output/*.deb; do
	[ "$(dpkg-deb -f "$package" Version)" = "$locked_package_version" ]
	case "$(dpkg-deb -f "$package" Architecture)" in amd64|all) ;; *) exit 1 ;; esac
	case "$(dpkg-deb -f "$package" Package)" in
		php"$PHP_BUILD_BRANCH"-cli|php"$PHP_BUILD_BRANCH"-fpm)
			dpkg-deb -f "$package" Provides | grep -q "phpapi-$locked_php_api"
			dpkg-deb -x "$package" /build/runtime ;;
	esac
done
[ "$(/build/runtime/usr/bin/php"$PHP_BUILD_BRANCH" -n -r 'echo PHP_VERSION;')" = "$locked_php_version" ]
/build/runtime/usr/sbin/php-fpm"$PHP_BUILD_BRANCH" -n -v | grep -F "PHP $locked_php_version "

python3 - "$lock_file" "$PHP_BUILD_BRANCH" <<'PY'
import datetime, hashlib, json, pathlib, sys
lock = json.load(open(sys.argv[1])); branch = lock['branches'][sys.argv[2]]
output = pathlib.Path('/output')
result = {**branch, **{key: lock[key] for key in ('base_image', 'distribution', 'architecture')},
          'status': 'built', 'built_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'source_date': lock['build_date'], 'build_command': 'dpkg-buildpackage -b -us -uc',
          'upstream_test_suite': 'skipped (nocheck)',
          'checks': ['locked source SHA256', 'source manifest consistency', 'distribution patches apply',
                     'PHP extension API preserved', 'all package identities', 'CLI and FPM executable versions'],
          'build_script_sha256': hashlib.sha256(pathlib.Path('/input/build-php.sh').read_bytes()).hexdigest()}
(output / 'provenance.json').write_text(json.dumps(result, indent=2) + '\n')
PY
cd /output
sha256sum ./*.deb ./*.buildinfo ./*.changes provenance.json php-build-lock.json build-dependencies.tsv build-script.sha256 > SHA256SUMS
echo "PHP $locked_php_version packages and provenance are complete."
