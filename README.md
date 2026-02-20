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

Copy the script from this repo:

```bash
scp -i /path/to/key -P 8022 ./scripts/reconcile-sqlite-postgres.sh root@your-host:/tmp/reconcile-sqlite-postgres.sh
ssh -i /path/to/key -P 8022 root@your-host "chmod +x /tmp/reconcile-sqlite-postgres.sh"
```
