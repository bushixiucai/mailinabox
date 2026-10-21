#!/bin/bash
# Run on Ubuntu/Debian: exercises repository and runtime safety gates without installing PHP.
set -euo pipefail
cd "$(dirname "$0")/.."
source setup/functions.sh
passed=0
apt-cache() {
	case "$2" in
		*-cli) printf '  Candidate: %s\n' "$CLI_CANDIDATE" ;;
		*-fpm) printf '  Candidate: %s\n' "$FPM_CANDIDATE" ;;
	esac
}
expect_candidate() {
	local expected=$1
	CLI_CANDIDATE=$2 FPM_CANDIDATE=$3
	if require_safe_php_candidate 8.4 >/dev/null 2>&1; then actual=0; else actual=1; fi
	[ "$actual" = "$expected" ] || { echo "Unexpected result for $CLI_CANDIDATE / $FPM_CANDIDATE"; exit 1; }
	passed=$((passed + 1))
}
expect_candidate 0 '8.4.27-1+ubuntu22.04.1' '8.4.27-1+ubuntu22.04.1'
expect_candidate 0 '1:8.4.28-1' '1:8.4.28-1'
expect_candidate 1 '8.4.26-1' '8.4.27-1'
expect_candidate 1 '8.4.27-1' '8.4.26-1'
expect_candidate 1 '(none)' '8.4.27-1'
expect_candidate 1 '8.4.27-1' '(none)'
expect_candidate 1 '8.5.12-1' '8.5.12-1'
if php_security_floor 8.0 >/dev/null 2>&1; then exit 1; fi
passed=$((passed + 1))
php8.4() { printf '%s' "$ACTUAL_PHP"; }
for ACTUAL_PHP in 8.4.27 8.4.28; do
	require_safe_php 8.4
	passed=$((passed + 1))
done
for ACTUAL_PHP in 8.4.26 8.5.12; do
	if require_safe_php 8.4 >/dev/null 2>&1; then exit 1; fi
	passed=$((passed + 1))
done
# A maintenance restart must not execute service or load a vulnerable runtime.
PHP_MAINTENANCE_FILE=$(mktemp)
trap 'rm -f "$PHP_MAINTENANCE_FILE"' EXIT
service() { echo 'Unexpected service start' >&2; return 99; }
ACTUAL_PHP=8.4.26
restart_service php8.4-fpm
passed=$((passed + 1))
printf '%s PHP security gate cases passed.\n' "$passed"
