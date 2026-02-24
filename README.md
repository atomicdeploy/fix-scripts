# fix-scripts

This repository provides a production-safe migration script for n8n SQLite-to-PostgreSQL conversions on bare-metal/VM installs (no Docker).

## n8n PostgreSQL migration script

The script runs **on the server** that hosts n8n. It does not create SSH connections itself. Use `scp` (or any file transfer) to copy it to the server and run it as root.

```bash
# from your workstation
scp -i /path/to/key -P 8022 ./scripts/n8n-postgres-migration.sh root@your-host:/tmp/n8n-postgres-migration.sh

# on the server
chmod +x /tmp/n8n-postgres-migration.sh
/tmp/n8n-postgres-migration.sh
```

### What the script does

1. Detects the active n8n systemd service and resolves the install directory, service user, and `.env`.
2. Stops the service, backs up the install directory to `/tmp`, and exports entities via `n8n export:entities`.
3. Ensures the PostgreSQL database/user exist (prompts for password), updates `.env` to use PostgreSQL.
4. Restarts the service, verifies it is running and the port is reachable, then imports entities.
5. Checks systemd status and recent journal logs for errors.
6. Prompts to remove the old `database.sqlite` file once migration succeeds.

### Useful overrides (optional)

Set any of these environment variables before running the script if you need to override detection:

- `N8N_SERVICE` – systemd service name (default: auto-detect `n8n*.service`)
- `N8N_BIN` – path to the n8n binary
- `N8N_DIR` – n8n installation directory
- `ENV_FILE` – path to the n8n `.env` file
- `LOG_FILE` – migration log location (default: `/var/log/n8n-postgres-migration.log`)
- `N8N_PORT_HOST` – host for port checks (default: `127.0.0.1`)
- `DB_PASSWORDLESS` – set to `true` for PostgreSQL passwordless mode (default: `true`)
- `DB_PASSWORDLESS_ALLOW_ALL_PEER` – set to `true` to insert `local all all peer` in `pg_hba.conf` (default: `false`; default inserts `local <DB_NAME> <DB_USER> peer`)

When `DB_PASSWORDLESS=true`, the script switches to the local PostgreSQL socket (`/var/run/postgresql`), removes any legacy n8n-specific `pg_hba.conf` block, and ensures a peer-auth rule exists. By default it adds `local <DB_NAME> <DB_USER> peer`; set `DB_PASSWORDLESS_ALLOW_ALL_PEER=true` to insert `local all all peer`. The script temporarily grants superuser for the import step before revoking it.

## PostgreSQL web UI (phpPgAdmin)

The server can expose phpPgAdmin via Apache using the same alias pattern as phpMyAdmin. The package config installs this alias:

- **Alias**: `/phppgadmin`
- **Document root**: `/usr/share/phppgadmin`
- **Apache config**: `/etc/apache2/conf-available/phppgadmin.conf`

If you need to allow remote access, update the Apache config to replace `Require local` with a restricted IP range (recommended). Only use `Require all granted` if you explicitly accept the security risk.

```bash
sudo sed -i 's/^Require local/Require ip 203.0.113.0\/24/' /etc/apache2/conf-available/phppgadmin.conf
sudo apache2ctl configtest
sudo systemctl reload apache2
```

To allow login with administrative accounts (e.g., `postgres`), disable phpPgAdmin's extra login security and set a password. This weakens protection against brute-force logins, so only do this in trusted environments.

```bash
sudo sed -i "s/\\$conf\\['extra_login_security'\\] = true;/\\$conf['extra_login_security'] = false;/" /etc/phppgadmin/config.inc.php
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '<YOUR_STRONG_PASSWORD>';"
sudo systemctl reload apache2
```

## Reconcile SQLite tables to PostgreSQL

If you suspect SQLite tables were not migrated into PostgreSQL (e.g., data tables missing), copy and run:

```bash
sudo /tmp/reconcile-sqlite-postgres.sh
```

By default it uses the latest `/tmp/database.sqlite.backup-*` file. You can override:

```bash
SQLITE_DB=/tmp/database.sqlite.backup-YYYYMMDD-HHMMSS PG_DB=n8n PG_SCHEMA=n8n sudo /tmp/reconcile-sqlite-postgres.sh
```

If you need to force data reload when counts differ, set:

```bash
FORCE_SYNC_TABLES=true SQLITE_DB=/tmp/database.sqlite.backup-YYYYMMDD-HHMMSS PG_DB=n8n PG_SCHEMA=n8n sudo /tmp/reconcile-sqlite-postgres.sh
```

The script also resets sequences to the current max IDs (for tables with identity/serial columns). You can disable that if needed:

```bash
RESET_SEQUENCES=false SQLITE_DB=/tmp/database.sqlite.backup-YYYYMMDD-HHMMSS PG_DB=n8n PG_SCHEMA=n8n sudo /tmp/reconcile-sqlite-postgres.sh
```

## Second server (Digitalogic) bootstrap

Use the same n8n layout as the primary server, but update hostnames to `automation.digitalogic.ir`.

Key steps:

1. **PostgreSQL**: Upgrade existing data (do not drop) and ensure a 16/main cluster on port 5432.
   ```bash
   pg_ctlcluster 14 main start
   sudo -u postgres pg_dumpall > /tmp/pg_backup_14.sql
   pg_ctlcluster 14 main stop
   # drop empty 16/main if it exists (keep data if it is in use)
   pg_dropcluster --stop 16 main
   pg_upgradecluster -v 16 14 main
   pg_ctlcluster 16 main start
   ```
   After verifying the migrated data, remove old clusters/packages so only 16 remains:
   ```bash
   pg_dropcluster --stop 14 main
   pg_dropcluster --stop 17 main || true
   pg_dropcluster --stop 18 main || true
   apt-get purge -y postgresql-14 postgresql-client-14 postgresql-17 postgresql-client-17 postgresql-18 postgresql-client-18
   apt-get autoremove -y
   ```
2. **Node.js + n8n**:
   ```bash
   curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
   apt-get install -y nodejs
   npm install -g n8n
   ```
3. **n8n user + service**:
   ```bash
   # Use the same UID/GID as server1 to keep ownership consistent for shared backups.
   groupadd -g 982 n8n
   useradd -m -u 994 -g 982 -G www-data -s /bin/bash n8n
   # create /var/lib/n8n, /var/lib/n8n/.n8n/.env, /var/lib/n8n/n8n-start.sh, and /etc/systemd/system/n8n.service
   install -d -m 750 -o n8n -g n8n /var/lib/n8n
   install -d -m 755 -o n8n -g n8n /var/lib/n8n/.n8n
   ```
4. **Apache vhost**: mirror `automation.yektayar.ir.conf` but update to `automation.digitalogic.ir` and `digitalogic.ir` certs.

5. **Let’s Encrypt cert merge**: if `digitalogic.ir-0001` is a duplicate of `digitalogic.ir`, update Apache references and archive the extra cert:
   ```bash
   sed -i 's/digitalogic.ir-0001/digitalogic.ir/g' /etc/apache2/sites-available/000-default-ssl.conf /etc/apache2/sites-available/000-default-le-ssl.conf /etc/apache2/sites-available/panel.digitalogic.ir.conf
   apache2ctl configtest
   systemctl reload apache2
   mkdir -p /tmp/letsencrypt-backup
   mv /etc/letsencrypt/renewal/digitalogic.ir-0001.conf /tmp/letsencrypt-backup/ || true
   mv /etc/letsencrypt/archive/digitalogic.ir-0001 /tmp/letsencrypt-backup/ || true
   mv /etc/letsencrypt/live/digitalogic.ir-0001 /tmp/letsencrypt-backup/ || true
   ```

6. **Wildcard cert with lego (recommended)**: `certbot-dns-arvancloud` is deprecated, so use `lego` with ArvanCloud DNS.
   ```bash
   # install lego
   TAG=$(curl -s https://api.github.com/repos/go-acme/lego/releases/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])")
   if [ -z "$TAG" ]; then
     echo "Failed to determine lego release tag" >&2
     exit 1
   fi
   FILE="lego_${TAG}_linux_amd64.tar.gz"
   URL="https://github.com/go-acme/lego/releases/download/${TAG}/${FILE}"
   TMP=$(mktemp -d)
   curl -fsSL "$URL" -o "$TMP/$FILE"
   tar -xzf "$TMP/$FILE" -C "$TMP"
   install -m 755 "$TMP/lego" /usr/local/bin/lego
   rm -rf "$TMP"

   # /tmp/arvancloud_key.txt should contain: "apikey YOUR_TOKEN_HERE" on a single line
   export ARVANCLOUD_API_KEY=$(awk '{print $2}' /tmp/arvancloud_key.txt)
   /usr/local/bin/lego --dns arvancloud \
     --domains digitalogic.ir \
     --domains '*.digitalogic.ir' \
     --email admin@digitalogic.ir \
     --path /etc/letsencrypt/lego \
     --accept-tos run
   ```
   If the API key lacks DNS permissions for the zone, the run will return **401 Unauthenticated** and must be retried with a key that has DNS record access for `digitalogic.ir`.

   Certificates will be stored under `/etc/letsencrypt/lego/certificates/_.digitalogic.ir.*` (no `/root/.lego` usage). Sync them into the Apache live path:
   ```bash
   /usr/local/bin/lego-sync-digitalogic.sh
   systemctl reload apache2
   ```
   If `/root/.lego` exists from a prior run, move it into `/etc/letsencrypt/lego` and remove the old path.

7. **Post-renew hooks**: generate a combined PEM, update Webmin, and notify a webhook.
   ```bash
   cat > /usr/local/bin/lego-post-hook.sh <<'SCRIPT'
   #!/usr/bin/env bash
   set -euo pipefail
   DOMAIN=example.com # replace with your domain
   live_dir=/etc/letsencrypt/live/$DOMAIN
   combined=$live_dir/combined.pem
   cat "$live_dir/fullchain.pem" "$live_dir/privkey.pem" > "$combined"
   test -s "$combined"
   chmod 600 "$combined"
   ln -sf "$combined" /etc/webmin/miniserv.pem
   # Optional: replace with your webhook URL, or remove this line.
   curl -fsS -X POST https://example.com/webhook/cert-renew || true
   SCRIPT
   chmod 750 /usr/local/bin/lego-post-hook.sh
   ```
   Wire the hook into the renew cron with a wrapper script:
   ```bash
   cat > /usr/local/bin/lego-sync-digitalogic.sh <<'SCRIPT'
   #!/usr/bin/env bash
   set -euo pipefail
   DOMAIN=example.com # replace with your domain
   cert_dir=/etc/letsencrypt/lego/certificates
   live_dir=/etc/letsencrypt/live/$DOMAIN
   cert_prefix=_${DOMAIN} # lego prefixes wildcard cert files with '_' by default
   install -d -m 700 -o root -g root "$live_dir"
   install -m 644 -o root -g root "$cert_dir/${cert_prefix}.crt" "$live_dir/cert.pem"
   install -m 644 -o root -g root "$cert_dir/${cert_prefix}.issuer.crt" "$live_dir/chain.pem"
   cat "$cert_dir/${cert_prefix}.crt" "$cert_dir/${cert_prefix}.issuer.crt" > "$live_dir/fullchain.pem"
   chmod 644 "$live_dir/fullchain.pem"
   install -m 600 -o root -g root "$cert_dir/${cert_prefix}.key" "$live_dir/privkey.pem"
   SCRIPT
   chmod 750 /usr/local/bin/lego-sync-digitalogic.sh

   cat > /usr/local/bin/lego-renew-digitalogic.sh <<'SCRIPT'
   #!/usr/bin/env bash
   set -euo pipefail
   DOMAIN=example.com # replace with your domain
   EMAIL=your-email@example.com # replace with your email for Let's Encrypt notices
   . /etc/letsencrypt/lego/arvancloud.env
   /usr/local/bin/lego --dns arvancloud --domains "$DOMAIN" --domains "*.${DOMAIN}" --email "$EMAIL" --accept-tos --path /etc/letsencrypt/lego renew --days 30
   /usr/local/bin/lego-sync-digitalogic.sh
   /usr/local/bin/lego-post-hook.sh
   systemctl reload apache2
   SCRIPT
   chmod 750 /usr/local/bin/lego-renew-digitalogic.sh

   cat > /etc/cron.d/lego-renew-digitalogic <<'CRON'
   SHELL=/bin/bash
   PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

   30 3 * * * root /usr/local/bin/lego-renew-digitalogic.sh
   CRON
   chmod 644 /etc/cron.d/lego-renew-digitalogic
   # If lego renew fails, the previous cert remains; rerun lego-sync/lego-post-hook manually after resolving the error.
   ```

Copy the script from this repo:

```bash
scp -i /path/to/key -P 8022 ./scripts/reconcile-sqlite-postgres.sh root@your-host:/tmp/reconcile-sqlite-postgres.sh
ssh -i /path/to/key -P 8022 root@your-host "chmod +x /tmp/reconcile-sqlite-postgres.sh"
```
