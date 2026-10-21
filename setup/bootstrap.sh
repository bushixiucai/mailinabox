#!/bin/bash
# Compatibility entry point; use the fork-owned installer, never upstream releases.
# curl -fsSL https://raw.githubusercontent.com/bushixiucai/mailinabox/main/setup.sh | sudo -E bash
set -euo pipefail
bootstrap=$(mktemp)
trap 'rm -f "$bootstrap"' EXIT
curl --fail --silent --show-error --location \
	https://raw.githubusercontent.com/bushixiucai/mailinabox/main/setup.sh -o "$bootstrap"
bash "$bootstrap"
