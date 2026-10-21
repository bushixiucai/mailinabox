#!/bin/bash
# Run targeted upstream security regressions against built packages in an isolated container.
# Usage: tools/test-built-php.sh ARTIFACT_DIRECTORY EMPTY_QA_DIRECTORY
set -euo pipefail
php_qa_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "${1:-}" != --inside-qa ]; then
	[ "$#" -eq 2 ] || { echo 'Usage: tools/test-built-php.sh ARTIFACT_DIRECTORY EMPTY_QA_DIRECTORY' >&2; exit 1; }
	php_qa_artifacts=$(cd "$1" && pwd)
	[ -f "$php_qa_artifacts/SHA256SUMS" ]
	[ -f "$php_qa_artifacts/provenance.json" ]
	mkdir -p "$2"
	php_qa_output=$(cd "$2" && pwd)
	[ -z "$(ls -A "$php_qa_output")" ] || { echo 'Use an empty QA directory.' >&2; exit 1; }
	php_qa_image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_image"])' "$php_qa_script_dir/php-build-lock.json")
	php_qa_docker=${DOCKER_BIN:-docker}
	if ! command -v "$php_qa_docker" >/dev/null 2>&1 && [ -x /usr/local/bin/docker ]; then php_qa_docker=/usr/local/bin/docker; fi
	"$php_qa_docker" run --rm --init --platform linux/amd64 \
		--mount "type=bind,source=$php_qa_script_dir,target=/input,readonly" \
		--mount "type=bind,source=$php_qa_artifacts,target=/artifacts,readonly" \
		--mount "type=bind,source=$php_qa_output,target=/qa" \
		"$php_qa_image" /bin/bash /input/test-built-php.sh --inside-qa 2>&1 | tee "$php_qa_output/driver.log"
	exit 0
fi

[ -e /.dockerenv ] || { echo 'The internal QA runner must run in Docker.' >&2; exit 1; }
source /etc/os-release
[ "$ID:$VERSION_ID" = ubuntu:22.04 ]
[ "$(dpkg --print-architecture)" = amd64 ]
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
cd /artifacts
sha256sum --check --strict SHA256SUMS
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl python3 xz-utils

python3 - /input/php-build-lock.json /artifacts/provenance.json > /tmp/php-qa-locked.env <<'PY'
import hashlib, json, pathlib, shlex, sys
lock = json.load(open(sys.argv[1])); branch = lock['branches']['8.4']
provenance = json.load(open(sys.argv[2]))
for key in ('php_version', 'package_version', 'php_api'):
    assert provenance[key] == branch[key], key + ' does not match the reviewed build lock'
assert provenance['status'] == 'built'
assert provenance['distribution'] == lock['distribution'] == 'ubuntu22.04'
assert provenance['architecture'] == lock['architecture'] == 'amd64'
tarball = pathlib.Path('/artifacts/inputs') / branch['upstream']['filename']
assert hashlib.sha256(tarball.read_bytes()).hexdigest() == branch['upstream']['sha256']
for key in ('php_version', 'package_version'):
    print('php_qa_' + key + '=' + shlex.quote(branch[key]))
print('php_qa_tarball=' + shlex.quote(str(tarball)))
PY
source /tmp/php-qa-locked.env

# Jammy's stock php-common is 2:92, while the reviewed packaging requires >=2:95.
# This small support package is pinned from the signed PPA package index. No PPA
# repository is added, and nothing is installed on the Docker host.
php_qa_common_url='https://launchpad.net/~ondrej/+archive/ubuntu/php/+files/php-common_101~+ubuntu22.04.1+deb.sury.org+1_all.deb'
php_qa_common_sha256=335cb409c562417a84634bf3daa42fa3e130a672727d2a25740aebfd19845911
curl --fail --location --show-error --retry 4 --retry-delay 3 --connect-timeout 30 --max-time 300 \
	"$php_qa_common_url" -o /tmp/php-common.deb
printf '%s  %s\n' "$php_qa_common_sha256" /tmp/php-common.deb | sha256sum --check --strict
php_qa_packages=(/tmp/php-common.deb)
for component in cli cgi fpm common mbstring opcache readline; do
	archives=(/artifacts/php8.4-"$component"_*.deb)
	[ "${#archives[@]}" -eq 1 ] && [ -f "${archives[0]}" ]
	[ "$(dpkg-deb -f "${archives[0]}" Package)" = "php8.4-$component" ]
	[ "$(dpkg-deb -f "${archives[0]}" Version)" = "$php_qa_package_version" ]
	[ "$(dpkg-deb -f "${archives[0]}" Architecture)" = amd64 ]
	php_qa_packages+=("${archives[0]}")
done
apt-get install -y --no-install-recommends "${php_qa_packages[@]}"
[ "$(php8.4 -n -r 'echo PHP_VERSION;')" = "$php_qa_php_version" ]
php-cgi8.4 -n -v | grep -F "PHP $php_qa_php_version "
php-fpm8.4 -n -v | grep -F "PHP $php_qa_php_version "
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /qa/installed-packages.tsv

mkdir -p /work/bin /work/source
tar -C /work/source -xJf "$php_qa_tarball"
cd "/work/source/php-$php_qa_php_version"
# Multipart helpers launch CGI with -n. Explicitly load the packaged shared
# mbstring module so that their encoding tests exercise conversion, as a static
# upstream mbstring build would. All listeners remain inside this private container.
cat > /work/bin/php-cgi <<'SH'
#!/bin/sh
exec /usr/bin/php-cgi8.4 -n -d extension=mbstring "$@"
SH
chmod 755 /work/bin/php-cgi
export TEST_PHP_EXECUTABLE=/usr/bin/php8.4 TEST_PHP_CGI_EXECUTABLE=/work/bin/php-cgi
export TEST_PHP_FPM_EXECUTABLE=/usr/sbin/php-fpm8.4 TEST_FPM_RUN_AS_ROOT=1
export NO_INTERACTION=1 REPORT_EXIT_STATUS=1 TEST_PHP_JUNIT=/qa/junit.xml
php_qa_tests=(
	Zend/tests/oom*.phpt
	tests/basic/oom_rfc1867_*.phpt
	sapi/cli/tests/oom_shutdown_function_next_request.phpt
	sapi/cli/tests/oom_request_parsing_next_request.phpt
	ext/session/tests/user_session_module/gh9584.phpt
	sapi/fpm/tests/ghsa-54hq-v5wp-fqgv-max-*.phpt
)
[ "${#php_qa_tests[@]}" -eq 82 ]
printf '%s\n' "${php_qa_tests[@]}" > /qa/selected-tests.txt
php_qa_status=0
php8.4 run-tests.php -q -j2 --offline --no-color --no-progress --show-diff \
	-w /qa/failed-tests.txt -W /qa/all-results.txt "${php_qa_tests[@]}" \
	2>&1 | tee /qa/upstream-tests.log || php_qa_status=$?
export PHP_QA_RUNNER_STATUS=$php_qa_status
find . -type f \( -name '*.diff' -o -name '*.exp' -o -name '*.out' -o -name '*.log' \) \
	-print0 | tar --null -T - -czf /qa/test-details.tar.gz
python3 - /input/php-build-lock.json <<'PY'
import datetime, hashlib, json, os, pathlib, sys, xml.etree.ElementTree as ET
output = pathlib.Path('/qa'); lock = json.load(open(sys.argv[1])); branch = lock['branches']['8.4']
summary = {'php_version': branch['php_version'], 'package_version': branch['package_version'],
           'selected_tests': 82, 'runner_exit_status': int(os.environ['PHP_QA_RUNNER_STATUS']),
           'php_common_sha256': '335cb409c562417a84634bf3daa42fa3e130a672727d2a25740aebfd19845911',
           'cgi_extra_extensions': ['mbstring'], 'completed_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
           'test_script_sha256': hashlib.sha256(pathlib.Path('/input/test-built-php.sh').read_bytes()).hexdigest()}
try:
    root = ET.parse(output / 'junit.xml').getroot()
    cases = list(root.iter('testcase'))
    skipped = [case.attrib['name'] for case in cases if case.find('skipped') is not None]
    failures = [case.attrib['name'] for case in cases if case.find('failure') is not None]
    errors = [case.attrib['name'] for case in cases if case.find('error') is not None or case.find('warning') is not None]
    allowed_skips = ('oom_hard_limit_exceeded.phpt', 'oom_soft_limit_in_callback.phpt')
    unexpected_skips = [name for name in skipped if not any(part in name for part in allowed_skips)]
    passed = len(cases) - len(skipped) - len(failures) - len(errors)
    summary.update(total=len(cases), passed=passed, failed=len(failures), errors=len(errors),
                   skipped=len(skipped), skipped_tests=skipped, failed_tests=failures,
                   error_tests=errors, unexpected_skips=unexpected_skips)
    summary['success'] = (len(cases) == 82 and passed >= 80 and not failures and not errors
                          and not unexpected_skips and summary['runner_exit_status'] == 0)
except Exception as error:
    summary.update(success=False, report_error=str(error))
(output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
sys.exit(0 if summary['success'] else 1)
PY
