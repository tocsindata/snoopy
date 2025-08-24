# Snoopy — LAMP bootstrap & ops toolkit

This repo provides opinionated Bash scripts to bootstrap a LAMP-like stack, manage updates, create/restores of backups, and import targeted files from external repos. It’s designed for Ubuntu servers (Jammy+), runs with clear logging, and uses conservative safety defaults.

---

## TL;DR (Quick Start)

1. **Put scripts** in your scripts directory (e.g., `/home/<user>/scripts/`).
2. **Edit `config.sh`** (variables only). Set all required values.
3. **Run the installer** as root:

   ```bash
   sudo /home/<user>/scripts/install.sh
   ```
4. **(Optional) Create import manifest:** `/home/<user>/imports/manifest.psv`.
5. **Add cron jobs** (repo check & backup) as shown below.

> **Note:** `config.sh` must contain variables only (no logic). All derivation/logic lives in the scripts.

---

## Directory Layout (suggested)

```
/home/<user>/
  ├─ scripts/
  │   ├─ install.sh                # LAMP + vhost + repo deploy
  │   ├─ functions.sh              # shared helpers (no set -e here)
  │   ├─ snoopy-repo-check.sh      # cron-safe remote HEAD checker
  │   ├─ snoopy-backup.sh          # root-only, daily backup
  │   ├─ snoopy-restore.sh         # root-only, dry-run by default
  │   └─ snoopy-import.sh          # targeted single-file imports
  ├─ imports/
  │   └─ manifest.psv              # pipe-separated import rules
  └─ ... (web root under /home/<user> per mode below)

/var/log/snoopy/                    # central logs (auto-pruned >7 days)
/var/lock/                          # locks: snoopy.* (TTL auto-unlock)
/root/backups/<user>/               # full backups (keep last 7)
/root/backups/<user>/singlefile/    # per-file import backups (keep 12)
/tmp/snoopy/                        # tmp/state (SNOOPY_TMP_DIR)
```

---

## Files & Scripts

### `config.sh` (variables only)

Define all configuration here — **no logic**. Examples of key sections:

* **General:** `SNOOPY_HOME_USERNAME`, `SNOOPY_USER`, `SNOOPY_GROUP`, `SNOOPY_HOME`, `SNOOPY_BIN_DIR`, `SNOOPY_SCRIPTS_DIR`, `SNOOPY_TMP_DIR`.
* **Web Root:** `SNOOPY_WEB_ROOT_MODE` (`home|public_html|public`), `SNOOPY_WEB_ROOT_DIR` (installer will derive if NULL), `SNOOPY_DOMAIN`.
* **Apache2:** `APACHE_CONF_DIR`, `ADMINER_PASS_FILE_NAME`.
* **PHP:** `INSTALL_PHP` (`true/false`), `PHP_VERSION` (e.g., `8.2`), `PHP_EXTRA_MODULES` (space-separated).
* **GitHub:** `GITHUB_REPO_URL`, `GITHUB_BRANCH`, `GITHUB_CLONE_DIR`, `GITHUB_REPO_PUBLIC`, `GITHUB_ACCESS_TOKEN` (if private).
* **Logging:** `LOG_DIR`, `LOG_LEVEL`, `LOG_RETENTION_DAYS` (script prunes >7 days).
* **Notifications:** `SEND_EMAIL`, `EMAIL_TO`, `EMAIL_SUBJECT`, `EMAIL_BODY`, `SEND_SLACK`, `SLACK_WEBHOOK_URL`, `SLACK_MESSAGE` (used as a **header/prefix** for all script notices).

> Required vs Optional variables are validated at runtime via `verify`, `verify_optional`, and `require_when` in `functions.sh`.

### `functions.sh`

Shared helpers: logging, `check_root`, `parse_bool`, `verify/verify_optional/require_when`, `ensure_web_root`, `create_apache_vhost`, package installers, repo clone/update, reboot notifications, etc. Purposefully **no `set -e`** here; only entrypoints use `set -e`.

### `install.sh`

One-time (or occasional) **bootstrap**:

* Validates config and derives `SNOOPY_WEB_ROOT_DIR` from `SNOOPY_WEB_ROOT_MODE` if needed.
* Installs base packages, Apache, and optional PHP stack.
* Ensures web root exists; writes Apache vhost for `SNOOPY_DOMAIN` with `DocumentRoot` set to the derived web root; reloads Apache.
* Clones or updates the configured repo and deploys it to the web root (excludes `.git`).
* Handles reboot-required notifications at the end.

### `snoopy-repo-check.sh`

**Cron-safe** remote HEAD check:

* Compares remote `HEAD` (for `GITHUB_BRANCH`) vs last-seen SHA under `$SNOOPY_TMP_DIR/state/repo/`.
* Notifies Slack/email when new commits appear or when the repo is “quiet” for too long.
* **Default quiet threshold:** 30 days (override via `--notify-if-quiet NDAYS`).
* **Lock:** `/var/lock/snoopy.repo-check.lock` with TTL **2h** auto-unlock.

### `snoopy-backup.sh` (root-only)

Daily **full backup** of key assets:

* Snapshots web root; **keeps directory stubs** for caches/logs but **excludes their contents**.
* Saves Apache vhost (and enabled/disabled state), minimal PHP INIs, crontabs, and scripts.
* Writes `manifest.json`, `filelist.txt`, `checksums.sha256`.
* **Retention:** keep last **7** backups; prune older.
* **Lock:** `/var/lock/snoopy.backup.lock` (TTL **12h**).

### `snoopy-restore.sh` (root-only)

Safe **restore** tool (dry-run by default):

* Mode: `all`, `webroot`, or `vhost`.
* Dry-run shows changes without applying. Use `--apply` to execute.
* Web root restores are **atomic** (rsync then swap) and reset owners/permissions.

### `snoopy-import.sh` (root-only)

**Targeted single-file import** from other repos using a manifest:

* Supports `--list`, `--dry-run <name|all>`, `--apply <name>`, `--apply-all`.
* Uses **sparse checkout** to fetch only the specified file(s).
* Destination must be under `/home/<user>/`.
* Backs up each destination to `/root/backups/<user>/singlefile/` and keeps **12** most recent per dest.
* **Lock (cron mode):** `/var/lock/snoopy.import.lock` (TTL **1h**).

---

## Import Manifest (pipe-separated)

**Path:** `/home/<user>/imports/manifest.psv`

**Columns (pipe `|` separated, fixed order):**

```
name | repo_url | ref | src_path | dest_path | owner | group | mode | post_cmd | repo_public | repo_token
```

* `name`: short unique id for the rule
* `repo_url`: HTTPS Git repo URL (can differ from main repo)
* `ref`: branch, tag, or commit SHA to fetch
* `src_path`: path inside the repo (e.g., `public_html/index.php`)
* `dest_path`: absolute path (must resolve under `/home/<user>`)
* `owner`, `group`, `mode`: ownership/permissions to set (optional but recommended)
* `post_cmd`: optional shell command after install (e.g., `systemctl reload apache2`)
* `repo_public`: `true` for public, otherwise `false`
* `repo_token`: literal token if private; `true` to reuse **global** `GITHUB_ACCESS_TOKEN` from config; `false`/`NULL` for none

**Examples:**

```
# name | repo_url | ref | src_path | dest_path | owner | group | mode | post_cmd | repo_public | repo_token
prod-index | https://github.com/org/private-repo.git | main | public_html/index.php | /home/<user>/public/index.php | www-data | www-data | 0644 | systemctl reload apache2 | false | <READ_ONLY_TOKEN>
favicon    | https://github.com/org/public-assets.git | v1.2.3 | assets/favicon.ico    | /home/<user>/public/favicon.ico | www-data | www-data | 0644 | NULL | true | false
```

> The import script never prints tokens. It performs atomic writes and keeps per-destination backups (12 most recent).

---

## Cron Jobs

Edit with `crontab -e` (as the appropriate user):

* **Repo check (service user):** once daily at 04:17

  ```cron
  17 4 * * * /home/<user>/scripts/snoopy-repo-check.sh --notify-if-quiet 30 >> /dev/null 2>&1
  ```

* **Full backup (root):** once daily at 03:12

  ```cron
  12 3 * * * /home/<user>/scripts/snoopy-backup.sh >> /dev/null 2>&1
  ```

> `snoopy-import.sh` is usually run ad hoc. If you schedule it, keep the lock and TTL in mind and prefer `--apply-all` with a small window.

---

## Locks, Logs, and State

* **Locks** live under `/var/lock/` with per-script names and **auto-unlock** if older than a TTL.

  * repo-check: **2h**
  * backup: **12h**
  * import: **1h**
* **Logs** live under `$LOG_DIR` (default `/var/log/snoopy`) and are **auto-pruned >7 days**.
* **State** files live under `$SNOOPY_TMP_DIR` (e.g., last-seen remote SHA for repo-check).
* **Slack header:** `SLACK_MESSAGE` is a prefix; each script appends a specific message (e.g., `“… — repo-check: new commits on main”`).

---

## Backup Details

* Included:

  * Web root (from `SNOOPY_WEB_ROOT_DIR`)
  * Apache vhost `sites-available/<domain>.conf` + enabled/disabled state
  * PHP Apache INIs under `/etc/php/*/apache2/` (if present)
  * Crontabs for root and service user
  * `config.sh`, `functions.sh`, and all `snoopy-*.sh` scripts
  * A snapshot copy of `imports/manifest.psv`
* **Excludes:** contents of any directories matching: `cache/`, `caches/`, `tmp/`, `log/`, `logs/`, `security_log/` (the folders themselves are kept)
* **Retention:** last **7** runs (daily). Pruning happens at the end of a successful backup.

---

## Restore Details

* Default is **dry-run**. Use `--apply` to write.
* Modes: `all` (webroot+vhost), `webroot`, `vhost`.
* Respects ownership/permissions exactly as captured.
* Webroot sync is atomic and followed by ownership fix.

---

## Install Details

* **Deriving web root:** If `SNOOPY_WEB_ROOT_DIR` is `NULL`, `install.sh` derives it from `SNOOPY_WEB_ROOT_MODE` (`home|public_html|public`).
* **Apache vhost:** DocumentRoot is the derived web root; `AllowOverride All`, `Options -Indexes +FollowSymLinks` by default.
* **PHP:** If `INSTALL_PHP=true`, installs `PHP_VERSION` plus commonly used modules. On Jammy, you may need the Ondřej PPA for newer versions.
* **Repo deploy:** Clones/updates to `GITHUB_CLONE_DIR`, then rsyncs into the web root (excludes `.git`).

---

## Safety & Security

* **Run as root** for backup/restore/import. Repo-check can run as the service user.
* **Tokens:** Allowed as literals in the import manifest; never printed to logs. For public imports set `repo_public=true` and `repo_token=false`.
* **Destination allow-list:** Imports must resolve under `/home/<user>/`.
* **Locks:** Prevent overlapping runs; stale locks are auto-cleared according to TTL.

---

## Troubleshooting

* **PHP install fails:** Your Ubuntu release may need the `ppa:ondrej/php` PPA. Add it, then re-run `install.sh`.
* **Apache reload errors:** Check `/var/log/apache2/error.log` and the vhost file in `sites-available`.
* **Repo auth issues:** Verify `GITHUB_REPO_PUBLIC` and token placement (`GITHUB_ACCESS_TOKEN` in config, or per-entry tokens in manifest).
* **Import skipped:** Ensure `dest_path` resolves under `/home/<user>` and `src_path` exists in the repo/ref.
* **Quiet repo alerts:** Adjust with `--notify-if-quiet NDAYS` on the cron line.

---

## Typical Workflow

1. Fill out `config.sh` with required values.
2. Run `install.sh` as root to bootstrap Apache/PHP, vhost, and deploy the main repo.
3. Add `snoopy-repo-check.sh` and `snoopy-backup.sh` to cron.
4. Create `imports/manifest.psv` to manage targeted file imports; use `snoopy-import.sh --list/--dry-run/--apply` as needed.
5. Use `snoopy-restore.sh` (dry-run first) to roll back to a prior backup if needed.

---

## Conventions

* `install.sh` and other entrypoints use `set -e` (fail fast). Shared `functions.sh` does **not**.
* All scripts use `tee` to log to `$LOG_DIR` and prune logs >7 days.
* All cron-able scripts use `/var/lock/snoopy.*` with TTL-based auto-unlock.

---
