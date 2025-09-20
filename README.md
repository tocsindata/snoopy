# `scripts/audit.sh` — UserSpice 5 Environment Audit

## Overview

A bash-only, read-only auditor that validates a server’s readiness to host **UserSpice 5**. It checks PHP version/extensions and `php.ini` thresholds, web-server rewrite/HTTPS readiness, system resources, application directory permissions, optional RDS TCP reachability, and enumerates Apache/Nginx vhosts. Outputs human-readable results and (optionally) JSON.

## What it checks

* **PHP**: CLI presence, version (warn on ≥8.4), required/recommended extensions, `php.ini` (`memory_limit`, `post_max_size`, `upload_max_filesize`, `date.timezone`), session path.
* **Web server**: Apache `mod_rewrite`, Nginx `try_files` hint.
* **System resources**: CPU cores, RAM, disk space, inode headroom, `ulimit -n`.
* **App path (optional)**: Presence of `.htaccess`/`index.php`; writability of `users`, `usersc`, `images`, `uploads`, `cache`.
* **RDS reachability (optional)**: TCP probe to `host:port` using `nc` or `/dev/tcp`.
* **VHosts**: Apache/Nginx docroots discovered from live configs.
* **HTTPS/SSL**: Apache `mod_ssl`, :443 listener, firewall (ufw/firewalld) status, per-vhost cert/key paths, Let’s Encrypt presence/expiry, live HTTP/HTTPS probes, Cloudflare proxy hints, redirect guidance.

## Usage

```bash
scripts/audit.sh \
  [--app-path /var/www/html] \
  [--rds mydb.x.rds.amazonaws.com:3306] \
  [--json]
```

## Notable Defaults (override via env)

* `PHP_BIN=php`, minimum PHP **8.1**, warn on **8.4+**
* Size floors: `MIN_PHP_MEMORY_MB=128`, `MIN_PHP_POST_MB=8`, `MIN_PHP_UPLOAD_MB=8`
* System floors: `MIN_RAM_MB=1024`, `MIN_DISK_MB=1024`, `MIN_INODES_PCT_FREE=5`, `MIN_ULIMIT_NOFILE=1024`
* Web user guess: `WEB_USER_GUESS=www-data`

## Output & Exit Codes

* Prints **PASS/WARN/FAIL** with suggested remediation commands (apt/yum/systemctl/Certbot).
* `--json` adds a machine-readable array of findings.
* **Exit 0** if no FAILs; **Exit 1** if any FAIL is recorded.

## Requirements

* Linux shell with standard tools; best results when `php`, `openssl`, `curl`, `apache2ctl/httpd`, `nginx`, `ss/netstat`, and `nc` are available (the script falls back where possible).
* Sufficient permissions to read web-server configs for full vhost discovery.


# `add-domain.sh` — Single-Domain Apache + System User Setup

## What this script does

* Validates an input **FQDN** and derives a **sanitized Linux username** from it (dots → underscores, lowercase).
* Creates a **system user/group** and home at `/home/<username>`, with web root at `/home/<username>/public_html`.
* Drops a simple `index.html` if none exists.
* Generates `/etc/apache2/sites-available/<domain>.conf` with **:80** and **:443** vhosts (snakeoil certs).
* Enables **mod\_rewrite** and **mod\_ssl**, enables the site, runs `apache2ctl configtest`, and **reloads Apache**.
* Saves a randomly generated password to `/root/<username>-password.txt` (mode `600`).

## Requirements

* Run as **root** on **Debian/Ubuntu**-style Apache layout (`apache2ctl`, `a2enmod`, `a2ensite` available).
* Packages: `apache2`, `openssl` (for password generation).
* DNS should already point the domain to this server (needed later for real TLS).

## Usage

```bash
sudo ./vhost-one.sh example.yourdomain.com
# or run without arg and follow the prompt
```

## Files/paths created

* User & home: `/home/<sanitized-username>/`
* Web root: `/home/<sanitized-username>/public_html/`
* VHost: `/etc/apache2/sites-available/<domain>.conf`
* Password (if user newly created): `/root/<sanitized-username>-password.txt`

## Notes & next steps

* The :443 vhost uses **snakeoil** certs for bootstrapping. Replace with Let’s Encrypt:

  ```bash
  sudo certbot --apache -d <domain>
  ```
* If `a2enmod`/`a2ensite` are missing, enable modules/sites manually and reload Apache.
* Re-running is **idempotent** for user, dirs, modules, and site enablement; it won’t clobber existing files.


# `git-pull-userspice.sh` — Read Me (Short)

## Purpose

Provision a clean **UserSpice 5** codebase into `/home/<USER>/public_html` from your fork, and apply canonical file/dir permissions suitable for production.

## What it does

1. Enumerates `/home/*` and prompts you to select a target account.
2. Ensures `public_html` exists; if non-empty, interactively offers to **wipe all contents**.
3. Clones `https://github.com/tocsindata/UserSpice5.git` into the target directory.
4. Sets ownership to `<USER>:www-data`.
5. Applies secure defaults: **dirs 755**, **files 644**.
6. Grants required writability:

   * `users/init.php` → **664** (installer needs write)
   * `usersc/plugins/`, `usersc/widgets/` → **2775** (setgid, collaborative writes)

## Requirements

* Linux with `bash` and `git`.
* Run with sufficient privileges to chown/chmod under `/home/<USER>`.
* Existing user home at `/home/<USER>`.

## Usage

```bash
sudo ./git-pull-userspice.sh
# follow the prompt to select the target account
```

## Outputs & Paths

* Install path: `/home/<USER>/public_html`
* Repo: `tocsindata/UserSpice5`

## Post-install Note

After completing the UserSpice web installer, you **may** tighten:

```bash
chmod 644 /home/<USER>/public_html/users/init.php
```

## Safety

* Destructive when confirmed: will **delete all contents of `public_html`** if you agree.
* Script is idempotent regarding directory creation and permission application.


# `domain-remove.sh` — Read Me (Short)

## Purpose

Safely dismantle an Apache vhost for a given domain and, if desired, remove the associated **sanitized system user** and home directory created by your setup workflow.

## What it does

* Validates the **FQDN**, derives the **sanitized username** (lowercase; dots → underscores).
* **Disables** the Apache site (`a2dissite`), **backs up** the vhost file to `/root/vhost-backups/<domain>.conf.<timestamp>`, then **removes** it.
* Runs `apache2ctl configtest` and **reloads Apache**.
* Optionally **deletes the system user** (via `userdel -r`) and the `/home/<user>/public_html` tree.
* Optionally removes the saved password file and **domain-specific Apache logs**.

## Safety & Confirmation

* Multiple interactive prompts guard destructive steps:

  * Remove vhost?
  * Delete system user and home?
  * Delete stored password file?
  * Delete Apache logs?
* Extra sanity checks prevent accidental deletion (e.g., refuses to act on `root`).

## Requirements

* Run as **root** on Debian/Ubuntu Apache layout (requires `apache2ctl`, `a2dissite`, `systemctl`).
* The domain’s vhost file path: `/etc/apache2/sites-available/<domain>.conf`.

## Usage

```bash
sudo ./domain-remove.sh <domain.example.com>
# or run without an argument and follow the prompts
```

## Affected Paths (typical)

* VHost: `/etc/apache2/sites-available/<domain>.conf` (backed up, then removed)
* Site link: `/etc/apache2/sites-enabled/<domain>.conf` (disabled)
* User home: `/home/<sanitized-username>/` (optional removal)
* Password file: `/root/<sanitized-username>-password.txt` (optional removal)
* Logs: `/var/log/apache2/<domain>_*.log` (optional removal)

## Notes

* This script mirrors the inverse of your `setup.sh`/vhost-creation workflow.
* After vhost removal, ensure DNS/CDN (e.g., Cloudflare) is updated if the domain is being decommissioned.


# `update-php.sh` — Short Read Me

## Purpose

Automate installation or upgrade of **PHP** to a specified or auto-detected **stable** version, including common extensions, across Debian/Ubuntu (APT) and RHEL/Alma/Rocky/Amazon Linux (DNF). Supports **mod\_php** (Ubuntu/Debian) and **php-fpm** modes.

## Key Features

* **Version selection**: `--version X.Y` or `--version X.Y.Z`; otherwise auto-detects latest stable from php.net (skips **X.Y.0** by default).
* **Repo setup**: Adds Ondřej PPA (Ubuntu) or Sury (Debian); enables Remi or AL2023 module streams on DNF-based systems.
* **Extensions**: Installs a practical set (`curl mbstring intl xml zip gd mysql ldap opcache bcmath readline`).
* **Web integration**: Optionally switches **libapache2-mod-php** on Debian/Ubuntu or enables **php-fpm** with Apache.
* **Safety & logging**: Strict mode (`set -euo pipefail`), clear logs, distro detection, and graceful fallbacks.

## Requirements

* Run as **root**.
* Internet access to package repos and php.net JSON.
* Package managers: **apt** or **dnf** available.

## Usage

```bash
# Auto-detect latest stable (skips .0 minors)
sudo ./update-php.sh

# Pin a branch or exact patch
sudo ./update-php.sh --version 8.3
sudo ./update-php.sh --version 8.3.12

# Allow .0 minors
sudo ./update-php.sh --allow-dot-zero

# Choose integration mode
sudo ./update-php.sh --fpm
sudo ./update-php.sh --mod-php                 # Debian/Ubuntu only

# Specify Apache service name when needed
sudo ./update-php.sh --apache-service httpd    # RHEL/Alma/Rocky/AMZ
```

## What It Does (Flow)

1. Detect OS and package manager; set appropriate Apache service.
2. Determine target PHP version (CLI `--version` or fetch from php.net).
3. Configure package repositories (Ondřej/Sury on apt; Remi/AL modules on dnf).
4. Install PHP for the requested **series** and the listed **extensions**.
5. If requested, switch **mod\_php** (a2dismod/a2enmod) or enable **php-fpm** and restart Apache.
6. Print summary (`php -v`) and ensure services are enabled/restarted.

## Notes

* By default, **`SKIP_DOT_ZERO=1`** avoids `.0` minor releases (can be overridden with `--allow-dot-zero`).
* On Amazon Linux 2023, you must provide `--version` to pick the stream (e.g., `8.3`).
* For RHEL-family, Apache integration is via **php-fpm + proxy\_fcgi** (mod\_php is uncommon).


# `cert.sh` — Short Read Me

## Purpose

Automate **Let’s Encrypt** certificate issuance and renewal for Apache (webroot `http-01`) non-interactively. Detects and fixes snakeoil/staging/mis-chained certs, discovers vhosts, validates webroots, and patches Apache configs to use the issued LE certs.

## Key Capabilities

* **Vhost discovery & parsing**: Reads Apache configs (`apache2ctl/httpd`) to find `ServerName`/`ServerAlias`, :80/:443 blocks, and document roots.
* **Webroot preflight**: Writes a temporary token under `.well-known/acme-challenge/` and verifies it via HTTP before requesting a cert.
* **Issuance/Renewal logic**: Renews when `< RENEW_DAYS` remain, when SANs change, or when served issuer is not production Let’s Encrypt.
* **Auto-patching**: Inserts or normalizes :443 blocks, replaces `SSLCertificateFile`/`KeyFile` with LE paths, removes deprecated `ChainFile`, and can disable `default-ssl` snakeoil.
* **Operational checks**: Verifies local 443 listener, external reachability, Cloudflare proxy presence (with optional wait), IPv6 hints.
* **Safety**: Single-instance lock; configtest + reloads (and restart fallback) after changes.

## Defaults (tunable in script)

* `CERT_EMAIL="info@tocsindata.com"`
* `RENEW_DAYS=30`
* `STAGING=0` (production ACME by default)
* `APACHE_RELOAD_CMD="systemctl reload apache2"`
* `FORCE_DISABLE_DEFAULT_SSL=1`
* `PREF_CHALLENGE="http-01"`

## Requirements

* Run as **root**.
* Packages: `certbot`, `apache2ctl` or `httpd`, `openssl`, `curl` (and `nc` for reachability checks recommended).
* Apache vhosts present and resolvable via DNS; port **80** reachable for `http-01`.

## How It Works (Flow)

1. Sanity checks (443 listener, external reachability, tools present).
2. Collect and parse vhost configs → build domain groups (primary + aliases) and webroots.
3. **Preflight** each domain’s webroot via HTTP token fetch.
4. Run `certbot certonly` (production unless `STAGING=1`) with per-domain `-w` roots.
5. Patch vhosts to LE `fullchain.pem`/`privkey.pem`, reload Apache, verify served fingerprint.
6. Handle Cloudflare (optional wait/probe). Summarize outcome.

## Usage

```bash
sudo ./cert.sh
# Non-interactive; discovers all Apache vhosts and (re)issues as needed.
```

## Notes

* If behind **Cloudflare**, temporarily gray-cloud DNS or switch to DNS-01; the script warns and performs a post-issue probe with a short wait.
* The script does not manage cron; schedule it yourself (e.g., daily) to keep certificates current.
