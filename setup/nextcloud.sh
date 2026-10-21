#!/bin/bash
# Nextcloud contacts/calendar installation and sequential database migration.

source setup/functions.sh
source /etc/mailinabox.conf
source setup/nextcloud-migration.sh

NEXTCLOUD_MANIFEST=setup/nextcloud-versions.txt
nextcloud_ver=34.0.5
NEXTCLOUD_ROOT=/usr/local/lib/owncloud
NEXTCLOUD_MAINTENANCE=/var/lib/mailinabox/php-maintenance

echo "Installing Nextcloud (contacts/calendar)..."

# Read only the configuration, without bootstrapping an old core with a new PHP.
CURRENT_NEXTCLOUD_VER=""
if [ -f "$STORAGE_ROOT/owncloud/config.php" ]; then
	CURRENT_NEXTCLOUD_VER=$(php"$PHP_VER" -r 'include($argv[1]); echo $CONFIG["version"] ?? "";' "$STORAGE_ROOT/owncloud/config.php")
	if [ -z "$CURRENT_NEXTCLOUD_VER" ]; then
		echo "Existing Nextcloud configuration has no version. Refusing a fresh installation." >&2
		exit 1
	fi
fi
REINSTALL_NEXTCLOUD=0
[ -d "$NEXTCLOUD_ROOT" ] || REINSTALL_NEXTCLOUD=1
NEXTCLOUD_PLAN=$(nextcloud_plan "$CURRENT_NEXTCLOUD_VER" "$NEXTCLOUD_MANIFEST" "$REINSTALL_NEXTCLOUD")

# Existing data must only be changed behind the persistent web/cron maintenance
# gate. The orchestration script preserves this gate on every failure.
if [ -n "$CURRENT_NEXTCLOUD_VER" ] && [ -n "$NEXTCLOUD_PLAN" ] && [ ! -e "$NEXTCLOUD_MAINTENANCE" ]; then
	echo "Run sudo setup/upgrade-php.sh before migrating Nextcloud." >&2
	exit 1
fi

install_nextcloud_php() {
	local runtime=$1
	require_safe_php_candidate "$runtime"
	apt_install php"$runtime"-cli php"$runtime"-sqlite3 php"$runtime"-gd php"$runtime"-curl \
		php"$runtime"-xml php"$runtime"-mbstring php"$runtime"-zip php"$runtime"-apcu \
		php"$runtime"-intl php"$runtime"-imagick php"$runtime"-gmp php"$runtime"-bcmath
	require_safe_php "$runtime"
	tools/editconf.py /etc/php/"$runtime"/mods-available/apcu.ini -c ';' apc.enabled=1 apc.enable_cli=1
}

# Install PHP 8.2 only when a pre-31 database actually needs the bridge.
# New installations use the final PHP runtime directly.
if [ -n "$CURRENT_NEXTCLOUD_VER" ] && [[ "$NEXTCLOUD_PLAN" == *" 8.2 "* ]]; then
	install_nextcloud_php 8.2
fi
install_nextcloud_php "$PHP_VER"
apt_install curl php"$PHP_VER" php"$PHP_VER"-fpm

# Before replacing any code, keep a complete copy of storage and a consistent
# SQLite backup. Restoration must restore data, configuration and code together.
BACKUP_DIRECTORY=""
if [ -n "$NEXTCLOUD_PLAN" ]; then
	mkdir -p "$STORAGE_ROOT/owncloud-backup"
	BACKUP_DIRECTORY=$(mktemp -d "$STORAGE_ROOT/owncloud-backup/upgrade-XXXXXXXX")
fi
if [ -n "$NEXTCLOUD_PLAN" ] && [ -n "$CURRENT_NEXTCLOUD_VER" ]; then
	echo "Backing up Nextcloud to $BACKUP_DIRECTORY"
	cp -a "$STORAGE_ROOT/owncloud" "$BACKUP_DIRECTORY/storage"
	if [ -d "$NEXTCLOUD_ROOT" ]; then
		cp -a "$NEXTCLOUD_ROOT" "$BACKUP_DIRECTORY/owncloud-install"
	fi
	python3 - "$STORAGE_ROOT/owncloud/owncloud.db" "$BACKUP_DIRECTORY/storage/owncloud.db" <<'PY'
import pathlib
import sqlite3
import sys
source, destination = sys.argv[1:]
if not pathlib.Path(source).is_file():
    sys.exit('Existing Nextcloud configuration has no SQLite database. Refusing to replace code.')
with sqlite3.connect('file:' + source + '?mode=ro', uri=True) as database:
    if database.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
        sys.exit('Nextcloud SQLite integrity check failed.')
    # Remove the copied main database: sqlite3.backup replaces it consistently,
    # including any committed transactions which were still in a WAL file.
    pathlib.Path(destination).unlink()
    for suffix in ('-wal', '-shm'):
        pathlib.Path(destination + suffix).unlink(missing_ok=True)
    with sqlite3.connect(destination) as backup:
        database.backup(backup)
PY
	# config_is_read_only prevents both database migrations and maintenance changes.
	sed -i -e '/config_is_read_only/d' "$STORAGE_ROOT/owncloud/config.php"
fi

InstallNextcloud() {
	local version=$1 runtime=$2 core_hash=$3
	local contacts_version=$4 contacts_hash=$5 calendar_version=$6 calendar_hash=$7
	local external_version=$8 external_hash=$9
	local stage app app_version app_hash
	stage=$(mktemp -d /usr/local/lib/.nextcloud-stage-XXXXXXXX)
	echo "Preparing Nextcloud $version with PHP $runtime"
	# Verify every archive before changing the live installation or its database.
	nextcloud_download "https://download.nextcloud.com/server/releases/nextcloud-$version.zip" "$core_hash" "$stage/core.zip"
	unzip -q "$stage/core.zip" -d "$stage"
	for app in contacts calendar user_external; do
		case "$app" in
			contacts) app_version=$contacts_version; app_hash=$contacts_hash ;;
			calendar) app_version=$calendar_version; app_hash=$calendar_hash ;;
			user_external) app_version=$external_version; app_hash=$external_hash ;;
		esac
		[ "$app_version" != - ] || continue
		nextcloud_download "https://github.com/nextcloud-releases/$app/releases/download/v$app_version/$app-v$app_version.tar.gz" "$app_hash" "$stage/$app.tgz"
		tar xf "$stage/$app.tgz" -C "$stage/nextcloud/apps/"
	done
	# Check that pinned app metadata really permits this major release.
	python3 - "$stage/nextcloud/apps" "${version%%.*}" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET
apps, major = pathlib.Path(sys.argv[1]), int(sys.argv[2])
for name in ('contacts', 'calendar', 'user_external'):
    manifest = apps / name / 'appinfo/info.xml'
    if not manifest.exists() and name == 'user_external' and major == 30:
        continue
    dependency = ET.parse(manifest).getroot().find('dependencies/nextcloud')
    if dependency is None or not int(dependency.attrib['min-version']) <= major <= int(dependency.attrib['max-version']):
        sys.exit('Incompatible Nextcloud application: ' + name)
PY
	if [ -f "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
		# There is no officially compatible user_external release for NC30.
		# Disable it without uninstalling its tables, then restore it at NC31.
		if [ "${version%%.*}" = 30 ] && [ -d "$NEXTCLOUD_ROOT/apps/user_external" ]; then
			sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" config:system:delete user_backends
			sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" app:disable user_external
		fi
	fi
	chmod 750 "$stage/nextcloud/"{apps,config}
	ln -sf "$STORAGE_ROOT/owncloud/config.php" "$stage/nextcloud/config/config.php"
	chown -R www-data:www-data "$stage/nextcloud"
	if [ -d "$NEXTCLOUD_ROOT" ]; then
		mv "$NEXTCLOUD_ROOT" "$BACKUP_DIRECTORY/before-$version"
	fi
	mv "$stage/nextcloud" "$NEXTCLOUD_ROOT"
	rm -rf "$stage"
	if [ -f "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
		nextcloud_occ_upgrade "$runtime"
		sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" app:enable contacts
		sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" app:enable calendar
		if [ "$external_version" != - ]; then
			sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" app:enable user_external
		fi
		nextcloud_occ_upgrade "$runtime"
		sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" db:add-missing-indices
		sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" db:add-missing-primary-keys
		# Cron jobs will not execute in application maintenance mode. The outer
		# PHP maintenance gate still blocks web requests and scheduled jobs.
		sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" maintenance:mode --off
		for _ in 1 2 3; do
			sudo -u www-data php"$runtime" -f "$NEXTCLOUD_ROOT/cron.php"
		done
		sudo -u www-data php"$runtime" "$NEXTCLOUD_ROOT/occ" status --output=json | python3 -c '
import json, sys
status = json.load(sys.stdin)
if not status.get("installed") or status.get("needsDbUpgrade") or status.get("versionstring") != sys.argv[1]:
    sys.exit("Nextcloud did not finish the expected migration.")
' "$version"
	fi
}

if [ -n "$NEXTCLOUD_PLAN" ]; then
	while read -r version runtime core_hash contacts_version contacts_hash calendar_version calendar_hash external_version external_hash; do
		# On a fresh install there are no old database compatibility constraints.
		if [ -z "$CURRENT_NEXTCLOUD_VER" ]; then runtime=$PHP_VER; fi
		InstallNextcloud "$version" "$runtime" "$core_hash" "$contacts_version" "$contacts_hash" "$calendar_version" "$calendar_hash" "$external_version" "$external_hash"
	done <<< "$NEXTCLOUD_PLAN"
fi

# ### Configuring Nextcloud

# Setup Nextcloud if the Nextcloud database does not yet exist. Running setup when
# the database does exist wipes the database and user data.
if [ ! -f "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
	# Create user data directory
	mkdir -p "$STORAGE_ROOT/owncloud"

	# Create an initial configuration file.
	instanceid=oc$(echo "$PRIMARY_HOSTNAME" | sha1sum | fold -w 10 | head -n 1)
	cat > "$STORAGE_ROOT/owncloud/config.php" <<EOF;
<?php
\$CONFIG = array (
  'datadirectory' => '$STORAGE_ROOT/owncloud',

  'instanceid' => '$instanceid',

  'forcessl' => true, # if unset/false, Nextcloud sends a HSTS=0 header, which conflicts with nginx config

  'overwritewebroot' => '/cloud',
  'overwrite.cli.url' => '/cloud',
  'user_backends' => array(
    array(
      'class' => '\OCA\UserExternal\IMAP',
      'arguments' => array(
        '127.0.0.1', 143, null, null, false, false
       ),
    ),
  ),
  'memcache.local' => '\OC\Memcache\APCu',
);
?>
EOF

	# Create an auto-configuration file to fill in database settings
	# when the install script is run. Make an administrator account
	# here or else the install can't finish.
	adminpassword=$(dd if=/dev/urandom bs=1 count=40 2>/dev/null | sha1sum | fold -w 30 | head -n 1)
	cat > /usr/local/lib/owncloud/config/autoconfig.php <<EOF;
<?php
\$AUTOCONFIG = array (
  # storage/database
  'directory' => '$STORAGE_ROOT/owncloud',
  'dbtype' => 'sqlite3',

  # create an administrator account with a random password so that
  # the user does not have to enter anything on first load of Nextcloud
  'adminlogin'    => 'root',
  'adminpass'     => '$adminpassword',
);
?>
EOF

	# Set permissions
	chown -R www-data:www-data "$STORAGE_ROOT/owncloud" /usr/local/lib/owncloud

	# Execute Nextcloud's setup step, which creates the Nextcloud sqlite database.
	# It also wipes it if it exists. And it updates config.php with database
	# settings and deletes the autoconfig.php file.
	(cd /usr/local/lib/owncloud || exit; sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/index.php;)
fi

# Update config.php.
# * trusted_domains is reset to localhost by autoconfig starting with ownCloud 8.1.1,
#   so set it here. It also can change if the box's PRIMARY_HOSTNAME changes, so
#   this will make sure it has the right value.
# * Some settings weren't included in previous versions of Mail-in-a-Box.
# * We need to set the timezone to the system timezone to allow fail2ban to ban
#   users within the proper timeframe
# * We need to set the logdateformat to something that will work correctly with fail2ban
# * mail_domain' needs to be set every time we run the setup. Making sure we are setting
#   the correct domain name if the domain is being change from the previous setup.
# Use PHP to read the settings file, modify it, and write out the new settings array.
TIMEZONE=$(cat /etc/timezone)
CONFIG_TEMP=$(/bin/mktemp)
php"$PHP_VER" <<EOF > "$CONFIG_TEMP" && mv "$CONFIG_TEMP" "$STORAGE_ROOT/owncloud/config.php";
<?php
include("$STORAGE_ROOT/owncloud/config.php");

\$CONFIG['config_is_read_only'] = false;
\$CONFIG['appstoreenabled'] = false; # https://discourse.mailinabox.email/t/problems-with-z-push-and-nextcloud-likely-after-package-updates-today/16460/21

\$CONFIG['trusted_domains'] = array('$PRIMARY_HOSTNAME');

\$CONFIG['memcache.local'] = '\OC\Memcache\APCu';
\$CONFIG['overwrite.cli.url'] = 'https://${PRIMARY_HOSTNAME}/cloud';

\$CONFIG['logtimezone'] = '$TIMEZONE';
\$CONFIG['logdateformat'] = 'Y-m-d H:i:s';

\$CONFIG['user_backends'] = array(
  array(
    'class' => '\OCA\UserExternal\IMAP',
    'arguments' => array(
      '127.0.0.1', 143, null, null, false, false
    ),
  ),
);

\$CONFIG['mail_domain'] = '$PRIMARY_HOSTNAME';
\$CONFIG['mail_from_address'] = 'administrator'; # just the local part, matches the required administrator alias on mail_domain/$PRIMARY_HOSTNAME
\$CONFIG['mail_smtpmode'] = 'sendmail';
\$CONFIG['mail_smtpauth'] = true; # if smtpmode is smtp
\$CONFIG['mail_smtphost'] = '127.0.0.1'; # if smtpmode is smtp
\$CONFIG['mail_smtpport'] = '587'; # if smtpmode is smtp
\$CONFIG['mail_smtpsecure'] = ''; # if smtpmode is smtp, must be empty string
\$CONFIG['mail_smtpname'] = ''; # if smtpmode is smtp, set this to a mail user
\$CONFIG['mail_smtppassword'] = ''; # if smtpmode is smtp, set this to the user's password

echo "<?php\n\\\$CONFIG = ";
var_export(\$CONFIG);
echo ";";
?>
EOF
chown www-data:www-data "$STORAGE_ROOT/owncloud/config.php"

# Enable/disable apps. Note that this must be done after the Nextcloud setup.
# The firstrunwizard gave Josh all sorts of problems, so disabling that.
# user_external is what allows Nextcloud to use IMAP for login. The contacts
# and calendar apps are the extensions we really care about here.
hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/console.php app:disable firstrunwizard
hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/console.php app:enable user_external
hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/console.php app:enable contacts
hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/console.php app:enable calendar

# When upgrading, run the upgrade script again now that apps are enabled. It seems like
# the first upgrade at the top won't work because apps may be disabled during upgrade?
# Check for success (0=ok, 3=no upgrade needed).
nextcloud_occ_upgrade "$PHP_VER"

# Disable default apps that we don't support
sudo -u www-data \
	php"$PHP_VER" /usr/local/lib/owncloud/occ app:disable photos dashboard activity \
	| (grep -v "No such app enabled" || /bin/true)

# Set PHP FPM values to support large file uploads
# (semicolon is the comment character in this file, hashes produce deprecation warnings)
tools/editconf.py /etc/php/"$PHP_VER"/fpm/php.ini -c ';' \
	upload_max_filesize=1G \
	post_max_size=1100M \
	output_buffering=16384 \
	memory_limit=512M \
	max_execution_time=600 \
	short_open_tag=On

# Set Nextcloud recommended opcache settings
tools/editconf.py /etc/php/"$PHP_VER"/cli/conf.d/10-opcache.ini -c ';' \
	opcache.enable=1 \
	opcache.enable_cli=1 \
	opcache.interned_strings_buffer=8 \
	opcache.max_accelerated_files=10000 \
	opcache.memory_consumption=128 \
	opcache.save_comments=1 \
	opcache.revalidate_freq=1

# Migrate users_external data from <0.6.0 to version 3.0.0
# (see https://github.com/nextcloud/user_external).
# This version was probably in use in Mail-in-a-Box v0.41 (February 26, 2019) and earlier.
# We moved to v0.6.3 in 193763f8. Ignore errors - maybe there are duplicated users with the
# correct backend already.
sqlite3 "$STORAGE_ROOT/owncloud/owncloud.db" "UPDATE oc_users_external SET backend='127.0.0.1';" || /bin/true

# Set up a general cron job for Nextcloud.
# Also add another job for Calendar updates, per advice in the Nextcloud docs
# https://docs.nextcloud.com/server/24/admin_manual/groupware/calendar.html#background-jobs
cat > /etc/cron.d/mailinabox-nextcloud << EOF;
#!/bin/bash
# Mail-in-a-Box
*/5 * * * *	www-data	[ ! -e /var/lib/mailinabox/php-maintenance ] && php$PHP_VER -f /usr/local/lib/owncloud/cron.php
*/5 * * * *	www-data	[ ! -e /var/lib/mailinabox/php-maintenance ] && php$PHP_VER -f /usr/local/lib/owncloud/occ dav:send-event-reminders
EOF
chmod +x /etc/cron.d/mailinabox-nextcloud

# We also need to change the sending mode from background-job to occ.
# Or else the reminders will just be sent as soon as possible when the background jobs run.
hide_output sudo -u www-data php"$PHP_VER" -f /usr/local/lib/owncloud/occ config:app:set dav sendEventRemindersMode --value occ

# Now set the config to read-only.
# Do this only at the very bottom when no further occ commands are needed.
sed -i'' "s/'config_is_read_only'\s*=>\s*false/'config_is_read_only' => true/" "$STORAGE_ROOT/owncloud/config.php"

# Rotate the nextcloud.log file
cat > /etc/logrotate.d/nextcloud <<EOF
# Nextcloud logs
$STORAGE_ROOT/owncloud/nextcloud.log {
		size 10M
		create 640 www-data www-data
		rotate 30
		copytruncate
		missingok
		compress
}
EOF

# There's nothing much of interest that a user could do as an admin for Nextcloud,
# and there's a lot they could mess up, so we don't make any users admins of Nextcloud.
# But if we wanted to, we would do this:
# ```
# for user in $(management/cli.py user admins); do
#	 sqlite3 $STORAGE_ROOT/owncloud/owncloud.db "INSERT OR IGNORE INTO oc_group_user VALUES ('admin', '$user')"
# done
# ```

# Enable PHP modules and restart PHP.
restart_service php"$PHP_VER"-fpm
