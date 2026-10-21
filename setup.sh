#!/bin/bash
# Fork-owned entry point. Safe to execute through curl | sudo -E bash.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo 'Run this script with sudo -E bash.' >&2; exit 1; }
SOURCE=https://github.com/bushixiucai/mailinabox.git
if [ -z "${TAG:-}" ]; then
	TAG=v80
fi
MIAB_INSTALL_DIR=${MIAB_INSTALL_DIR:-/root/mailinabox}
source /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 22.04 ] || {
	echo 'This fork supports Ubuntu 22.04 LTS only.' >&2
	exit 1
}
[ "$(dpkg --print-architecture)" = amd64 ] || {
	echo 'The v80 package release supports Ubuntu 22.04 amd64 only.' >&2
	exit 1
}
if ! command -v git >/dev/null 2>&1; then
	apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates
fi
if [ ! -e "$MIAB_INSTALL_DIR" ]; then
	git clone --branch "$TAG" "$SOURCE" "$MIAB_INSTALL_DIR" < /dev/null
fi
cd "$MIAB_INSTALL_DIR"
[ -d .git ] || { echo 'The installation directory is not a Git checkout.' >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || {
	echo 'The checkout has local changes. Commit or preserve them before updating.' >&2
	exit 1
}
# Switch an existing upstream installation to this fork without resetting files.
git remote set-url origin "$SOURCE"
git fetch --prune origin '+refs/heads/*:refs/remotes/origin/*'
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
	git fetch origin "refs/tags/$TAG:refs/tags/$TAG"
	git checkout --detach "refs/tags/$TAG"
	[ "$(git rev-parse HEAD)" = "$(git rev-parse "refs/tags/$TAG^{commit}")" ]
elif git show-ref --verify --quiet "refs/remotes/origin/$TAG"; then
	if [ "$(git symbolic-ref --short -q HEAD || true)" != "$TAG" ]; then
		if git show-ref --verify --quiet "refs/heads/$TAG"; then
			git switch "$TAG"
		else
			git switch --track -c "$TAG" "origin/$TAG"
		fi
	fi
	git merge --ff-only "origin/$TAG"
	[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$TAG")" ] || {
		echo 'The local branch contains unpublished commits. Preserve them before updating.' >&2
		exit 1
	}
else
	echo "The requested fork version was not found: $TAG" >&2
	exit 1
fi
[ -x setup/upgrade-php.sh ] || {
	echo 'The selected version predates the supported fork migration. Use v80 or newer.' >&2
	exit 1
}
printf 'Using fork revision: %s\n' "$(git rev-parse HEAD)"
MIAB_FULL_SETUP_MARKER=/var/lib/mailinabox/full-setup-in-progress
if [ -f /etc/mailinabox.conf ] && [ ! -e "$MIAB_FULL_SETUP_MARKER" ]; then
	# Existing installations only need the scoped PHP application migration.
	bash setup/upgrade-php.sh
else
	# The full installer writes its configuration before all services are ready.
	# Preserve this marker on failure so a public installer retry resumes full setup.
	install -d -m 755 /var/lib/mailinabox
	install -m 644 /dev/null "$MIAB_FULL_SETUP_MARKER"
	bash setup/start.sh
	rm "$MIAB_FULL_SETUP_MARKER"
fi
