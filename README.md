Mail-in-a-Box
=============

By [@JoshData](https://github.com/JoshData) and [contributors](https://github.com/mail-in-a-box/mailinabox/graphs/contributors).

Mail-in-a-Box helps individuals take back control of their email by defining a one-click, easy-to-deploy SMTP+everything else server: a mail server in a box.

**Please see [https://mailinabox.email](https://mailinabox.email) for the project's website and setup guide!**

* * *

Our goals are to:

* Make deploying a good mail server easy.
* Promote [decentralization](http://redecentralize.org/), innovation, and privacy on the web.
* Have automated, auditable, and [idempotent](https://web.archive.org/web/20190518072631/https://sharknet.us/2014/02/01/automated-configuration-management-challenges-with-idempotency/) configuration.
* **Not** make a totally unhackable, NSA-proof server.
* **Not** make something customizable by power users.

Additionally, this project has a [Code of Conduct](CODE_OF_CONDUCT.md), which supersedes the goals above. Please review it when joining our community.


In The Box
----------

Mail-in-a-Box turns a fresh Ubuntu 22.04 LTS 64-bit machine into a working mail server by installing and configuring various components.

It is a one-click email appliance. There are no user-configurable setup options. It "just works."

The components installed are:

* SMTP ([postfix](http://www.postfix.org/)), IMAP ([Dovecot](http://dovecot.org/)), CardDAV/CalDAV ([Nextcloud](https://nextcloud.com/)), and Exchange ActiveSync ([z-push](http://z-push.org/)) servers
* Webmail ([Roundcube](http://roundcube.net/)), mail filter rules (thanks to Roundcube and Dovecot), and email client autoconfig settings (served by [nginx](http://nginx.org/))
* Spam filtering ([spamassassin](https://spamassassin.apache.org/)) and greylisting ([postgrey](http://postgrey.schweikert.ch/))
* DNS ([nsd4](https://www.nlnetlabs.nl/projects/nsd/)) with [SPF](https://en.wikipedia.org/wiki/Sender_Policy_Framework), DKIM ([OpenDKIM](http://www.opendkim.org/)), [DMARC](https://en.wikipedia.org/wiki/DMARC), [DNSSEC](https://en.wikipedia.org/wiki/DNSSEC), [DANE TLSA](https://en.wikipedia.org/wiki/DNS-based_Authentication_of_Named_Entities), [MTA-STS](https://tools.ietf.org/html/rfc8461), and [SSHFP](https://tools.ietf.org/html/rfc4255) policy records automatically set
* TLS certificates are automatically provisioned using [Let's Encrypt](https://letsencrypt.org/) for protecting https and all of the other services on the box
* Backups ([duplicity](http://duplicity.nongnu.org/)), firewall ([ufw](https://launchpad.net/ufw)), intrusion protection ([fail2ban](http://www.fail2ban.org/wiki/index.php/Main_Page)), and basic system monitoring ([munin](http://munin-monitoring.org/))

It also includes system management tools:

* Comprehensive health monitoring that checks each day that services are running, ports are open, TLS certificates are valid, and DNS records are correct
* A control panel for adding/removing mail users, aliases, custom DNS records, configuring backups, etc.
* An API for all of the actions on the control panel

Internationalized domain names are supported and configured easily (but SMTPUTF8 is not supported, unfortunately).

It also supports static website hosting since the box is serving HTTPS anyway. (To serve a website for your domains elsewhere, just add a custom DNS "A" record in you Mail-in-a-Box's control panel to point domains to another server.)

For more information on how Mail-in-a-Box handles your privacy, see the [security details page](security.md).


Installation and fork updates
-----------------------------

This fork supports Ubuntu 22.04 LTS. Its installer and update source are this repository:

```sh
curl -fsSL https://raw.githubusercontent.com/bushixiucai/mailinabox/main/setup.sh | sudo -E bash
```

The entry point clones this fork into `/root/mailinabox` (override with
`MIAB_INSTALL_DIR`), refuses dirty checkouts and defaults to the published `v80` tag. Branch updates use fast-forward only.
It also switches an unmodified upstream checkout to this fork. Set `TAG` explicitly
to use another release tag or branch. Existing installations run the scoped PHP application
upgrade; fresh machines run the complete server installer. The upstream command at
`mailinabox.email/setup.sh` must not be used to update this fork.

### PHP application versions and migration

The target combination is PHP 8.4.27+, Nextcloud 34.0.5, Contacts 8.9.2, Calendar
6.6.3, user_external 4.0.0, Roundcube 1.7.5, CardDAV 5.1.4 and Z-Push 2.7.6.
Mail, calendar, contacts, ActiveSync and existing webmail plugin features are retained.
SMTP, IMAP and the Python management service remain separate.

For an already updated checkout, the scoped upgrade command is:

```sh
sudo setup/upgrade-php.sh
```

When patched packages are unavailable, a release installer first downloads the verified
source-built package bundle from this fork's matching GitHub release. If the bundle is
unavailable, the upgrade builds the official PHP release
using the source and Debian packaging hashes in `tools/php-build-lock.json`. The build
runs in a pinned Ubuntu Docker image; Docker is installed only if needed. The generated
packages preserve the existing FPM paths and extension API. Build dependencies are
recorded, but byte-identical output across changing Ubuntu package archives is not claimed.

You can also build and inspect artifacts before installing them:

```sh
PHP_BUILD_JOBS=4 tools/build-php.sh /absolute/empty-build-output
sudo tools/install-built-php.sh /absolute/empty-build-output
```

The output includes Debian packages, SHA256SUMS, provenance, dependency inventory and
build logs. Installation verifies package identities and keeps FPM masked; the scoped
upgrade subsequently migrates applications before reopening traffic. To update PHP again,
review a new official release, update the lock file and hashes, then rebuild and validate.

The upgrade locks concurrent runs, closes PHP web routes and scheduled Nextcloud
jobs, masks FPM package autostarts, backs up application code, storage and configuration,
then migrates consecutive Nextcloud major versions. PHP 8.2.35+ CLI handles Nextcloud
27 through 31; PHP 8.4.27+ handles the remaining stages. Each stage checks the archive
SHA256, app compatibility and resulting database version. The external IMAP app is
briefly disabled at NC30 without uninstalling its data and restored at NC31. Versions
older than NC27 must first migrate using a compatible older installer.

Private backups are stored under `$STORAGE_ROOT/php-upgrade-backups`; the latest
path is recorded in `/var/lib/mailinabox/php-upgrade-backup`. Ensure sufficient free
space for every intermediate core and an independent server backup before starting.
Any migration failure keeps `/var/lib/mailinabox/php-maintenance` present and PHP
workers stopped. Never remove that marker to bypass an incomplete upgrade. Restore
application code, configuration and database/data together: reverting Git does not
reverse database migrations. Old FPM units remain masked after success.

Before accepting a production upgrade, verify actual FPM and CLI versions, login,
password changes, attachments, CardDAV/CalDAV, remembered sessions, desktop
notifications and ActiveSync clients. Automated checks do not establish device acceptance.

### Focused checks

```sh
python3 -m unittest discover -s tests -p 'test_nextcloud_migration.py'
python3 -m unittest discover -s tests -p 'test_php_*.py'
bash tests/test_php_security.sh  # Debian/Ubuntu dpkg required
bash -n setup/*.sh setup.sh tools/install-built-php.sh
```


Contributing and Development
----------------------------

Mail-in-a-Box is an open source project. Your contributions and pull requests are welcome. See [CONTRIBUTING](CONTRIBUTING.md) to get started. 


The Acknowledgements
--------------------

This project was inspired in part by the ["NSA-proof your email in 2 hours"](http://sealedabstract.com/code/nsa-proof-your-e-mail-in-2-hours/) blog post by Drew Crawford, [Sovereign](https://github.com/sovereign/sovereign) by Alex Payne, and conversations with <a href="https://twitter.com/shevski" target="_blank">@shevski</a>, <a href="https://github.com/konklone" target="_blank">@konklone</a>, and <a href="https://github.com/gregelin" target="_blank">@GregElin</a>.

Mail-in-a-Box is similar to [iRedMail](http://www.iredmail.org/) and [Modoboa](https://github.com/tonioo/modoboa).


The History
-----------

* In 2007 I wrote a relatively popular Mozilla Thunderbird extension that added client-side SPF and DKIM checks to mail to warn users about possible phishing: [add-on page](https://addons.mozilla.org/en-us/thunderbird/addon/sender-verification-anti-phish/), [source](https://github.com/JoshData/thunderbird-spf).
* In August 2013 I began Mail-in-a-Box by combining my own mail server configuration with the setup in ["NSA-proof your email in 2 hours"](http://sealedabstract.com/code/nsa-proof-your-e-mail-in-2-hours/) and making the setup steps reproducible with bash scripts.
* Mail-in-a-Box was a semifinalist in the 2014 [Knight News Challenge](https://www.newschallenge.org/challenge/2014/submissions/mail-in-a-box), but it was not selected as a winner.
* Mail-in-a-Box hit the front page of Hacker News in [April](https://news.ycombinator.com/item?id=7634514) 2014, [September](https://news.ycombinator.com/item?id=8276171) 2014, [May](https://news.ycombinator.com/item?id=9624267) 2015, and [November](https://news.ycombinator.com/item?id=13050500) 2016.
* FastCompany mentioned Mail-in-a-Box a [roundup of privacy projects](http://www.fastcompany.com/3047645/your-own-private-cloud) on June 26, 2015.
