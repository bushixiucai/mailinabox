#!/bin/bash
#
# Z-Push: The Microsoft Exchange protocol server
# ----------------------------------------------
#
# Mostly for use on iOS which doesn't support IMAP IDLE.
#
# Although Ubuntu ships Z-Push (as d-push) it has a dependency on Apache
# so we won't install it that way.
#
# Thanks to http://frontender.ch/publikationen/push-mail-server-using-nginx-and-z-push.html.

source setup/functions.sh # load our functions
source /etc/mailinabox.conf # load global vars

if [ -d /usr/local/lib/z-push ] && [ ! -e "$PHP_MAINTENANCE_FILE" ]; then
	echo 'Use setup/upgrade-php.sh to upgrade an existing Z-Push installation.' >&2
	exit 1
fi
require_safe_php_candidate "$PHP_VER"

# Prereqs.

echo "Installing Z-Push (Exchange/ActiveSync server)..."
apt_install \
       php"${PHP_VER}"-soap php"${PHP_VER}"-imap libawl-php php"$PHP_VER"-xml php"${PHP_VER}"-intl
require_safe_php "$PHP_VER"

phpenmod -v "$PHP_VER" imap

# Copy Z-Push into place.
VERSION=2.7.6
TARGETHASH=a0591c8c58b2cdb3ba25cd7a9115a40a3f76a72c
needs_update=0 #NODOC
if [ ! -f /usr/local/lib/z-push/version ]; then
	needs_update=1 #NODOC
elif [[ $VERSION != $(cat /usr/local/lib/z-push/version) ]]; then
	# checks if the version
	needs_update=1 #NODOC
fi
if [ $needs_update == 1 ]; then
	ZPUSH_STAGING=$(mktemp -d /usr/local/lib/z-push-install.XXXXXX)
	# Download
	wget_verify "https://github.com/Z-Hub/Z-Push/archive/refs/tags/$VERSION.zip" $TARGETHASH "$ZPUSH_STAGING/z-push.zip"

	# Complete extraction before replacing the installed tree.
	unzip -q "$ZPUSH_STAGING/z-push.zip" -d "$ZPUSH_STAGING"
	rm -f "$ZPUSH_STAGING/z-push.zip"
	if [ -d /usr/local/lib/z-push ]; then
		mv /usr/local/lib/z-push "$ZPUSH_STAGING/previous"
	fi
	if ! mv "$ZPUSH_STAGING/Z-Push-$VERSION/src" /usr/local/lib/z-push; then
		if [ -d "$ZPUSH_STAGING/previous" ]; then
			mv "$ZPUSH_STAGING/previous" /usr/local/lib/z-push
		fi
		exit 1
	fi
	if [ -d "$ZPUSH_STAGING/previous" ]; then
		echo "Previous Z-Push installation retained at $ZPUSH_STAGING/previous"
	fi

	echo $VERSION > /usr/local/lib/z-push/version
fi

# Refresh wrappers even when only the PHP runtime changes.
for command in admin top; do
	cat > /usr/sbin/z-push-$command <<EOF;
#!/bin/bash
exec php"$PHP_VER" /usr/local/lib/z-push/z-push-$command.php "\$@"
EOF
	chmod 755 /usr/sbin/z-push-$command
done

# Configure default config.
sed -i "s^define('TIMEZONE', .*^define('TIMEZONE', '$(cat /etc/timezone)');^" /usr/local/lib/z-push/config.php
sed -i "s/define('BACKEND_PROVIDER', .*/define('BACKEND_PROVIDER', 'BackendCombined');/" /usr/local/lib/z-push/config.php
sed -i "s/define('USE_FULLEMAIL_FOR_LOGIN', .*/define('USE_FULLEMAIL_FOR_LOGIN', true);/" /usr/local/lib/z-push/config.php
sed -i "s/define('LOGLEVEL', .*/define('LOGLEVEL', LOGLEVEL_ERROR);/" /usr/local/lib/z-push/config.php

# Configure BACKEND
rm -f /usr/local/lib/z-push/backend/combined/config.php
cp conf/zpush/backend_combined.php /usr/local/lib/z-push/backend/combined/config.php

# Configure IMAP
rm -f /usr/local/lib/z-push/backend/imap/config.php
cp conf/zpush/backend_imap.php /usr/local/lib/z-push/backend/imap/config.php
sed -i "s%STORAGE_ROOT%$STORAGE_ROOT%" /usr/local/lib/z-push/backend/imap/config.php

# Configure CardDav
rm -f /usr/local/lib/z-push/backend/carddav/config.php
cp conf/zpush/backend_carddav.php /usr/local/lib/z-push/backend/carddav/config.php

# Configure CalDav
rm -f /usr/local/lib/z-push/backend/caldav/config.php
cp conf/zpush/backend_caldav.php /usr/local/lib/z-push/backend/caldav/config.php

# Configure Autodiscover
rm -f /usr/local/lib/z-push/autodiscover/config.php
cp conf/zpush/autodiscover_config.php /usr/local/lib/z-push/autodiscover/config.php
sed -i "s/PRIMARY_HOSTNAME/$PRIMARY_HOSTNAME/" /usr/local/lib/z-push/autodiscover/config.php
sed -i "s^define('TIMEZONE', .*^define('TIMEZONE', '$(cat /etc/timezone)');^" /usr/local/lib/z-push/autodiscover/config.php

# Some directories it will use.

mkdir -p /var/log/z-push
mkdir -p /var/lib/z-push
chmod 750 /var/log/z-push
chmod 750 /var/lib/z-push
chown www-data:www-data /var/log/z-push
chown www-data:www-data /var/lib/z-push

# Add log rotation

cat > /etc/logrotate.d/z-push <<EOF;
/var/log/z-push/*.log {
	weekly
	missingok
	rotate 52
	compress
	delaycompress
	notifempty
}
EOF

# Restart service.

restart_service php"$PHP_VER"-fpm

# Fix states after upgrade

if [ $needs_update == 1 ]; then
	hide_output php"$PHP_VER" /usr/local/lib/z-push/z-push-admin.php -a fixstates
fi
