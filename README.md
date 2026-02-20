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
