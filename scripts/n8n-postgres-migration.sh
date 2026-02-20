#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

LOG_FILE="${LOG_FILE:-/var/log/n8n-postgres-migration.log}"
DEFAULT_DB_NAME="n8n"
DEFAULT_DB_HOST="localhost"
DEFAULT_DB_PORT="5432"
DEFAULT_DB_SCHEMA="n8n"
DEFAULT_DB_PASSWORDLESS="true"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
  local message="$*"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $message" | tee -a "$LOG_FILE"
}

IMPORT_SUPERUSER_GRANTED="false"
IMPORT_SUPERUSER_USER_IDENT=""

cleanup_import_privileges() {
  if [[ "$IMPORT_SUPERUSER_GRANTED" == "true" && -n "$IMPORT_SUPERUSER_USER_IDENT" ]]; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER USER ${IMPORT_SUPERUSER_USER_IDENT} WITH NOSUPERUSER;" || true
    IMPORT_SUPERUSER_GRANTED="false"
    IMPORT_SUPERUSER_USER_IDENT=""
  fi
}

fail() {
  log "ERROR: $*"
  exit 1
}

trap 'cleanup_import_privileges; fail "Script failed on line $LINENO."' ERR

if [[ "$(id -u)" -ne 0 ]]; then
  fail "This script must be run as root."
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

pg_quote_identifier() {
  printf '"%s"' "${1//\"/\"\"}"
}

pg_quote_literal() {
  printf "'%s'" "${1//\'/\'\'}"
}

strip_quotes() {
  local value="$1"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  echo "$value"
}

detect_n8n_service() {
  if [[ -n "${N8N_SERVICE:-}" ]]; then
    echo "$N8N_SERVICE"
    return
  fi

  mapfile -t services < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^n8n.*\.service$' || true)
  if [[ "${#services[@]}" -eq 0 ]]; then
    mapfile -t services < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^n8n.*\.service$' || true)
  fi

  if [[ "${#services[@]}" -eq 0 ]]; then
    fail "Unable to locate an n8n systemd service. Set N8N_SERVICE to override."
  fi

  if [[ "${#services[@]}" -gt 1 ]]; then
    log "Multiple n8n services detected (${services[*]}). Using ${services[0]}."
  fi

  echo "${services[0]}"
}

SERVICE_NAME="$(detect_n8n_service)"
log "Using service: $SERVICE_NAME"

UNIT_CONTENT="$(systemctl cat "$SERVICE_NAME")"
WORKING_DIR="$(printf '%s\n' "$UNIT_CONTENT" | awk -F= '/^WorkingDirectory=/{print $2; exit}')"
EXEC_START_LINE="$(printf '%s\n' "$UNIT_CONTENT" | awk -F= '/^ExecStart=/{print $2; exit}')"
ENV_FILE_LINE="$(printf '%s\n' "$UNIT_CONTENT" | awk -F= '/^EnvironmentFile=/{print $2; exit}')"

WORKING_DIR="$(strip_quotes "$WORKING_DIR")"
EXEC_START_LINE="$(strip_quotes "$EXEC_START_LINE")"
ENV_FILE_LINE="$(strip_quotes "$ENV_FILE_LINE")"
ENV_FILE_LINE="${ENV_FILE_LINE#-}"
ENV_FILE_LINE="$(printf '%s\n' "$ENV_FILE_LINE" | awk '{print $1}')"

SERVICE_USER="$(systemctl show "$SERVICE_NAME" -p User --value)"
SERVICE_USER="${SERVICE_USER:-root}"
SERVICE_GROUP="$(systemctl show "$SERVICE_NAME" -p Group --value)"
SERVICE_GROUP="${SERVICE_GROUP:-$SERVICE_USER}"

if [[ -n "${EXEC_START_LINE:-}" ]]; then
  read -r -a EXEC_TOKENS <<< "$EXEC_START_LINE"
fi

N8N_BIN="${N8N_BIN:-}"
if [[ -z "$N8N_BIN" ]]; then
  for token in "${EXEC_TOKENS[@]:-}"; do
    if [[ "$token" == *n8n ]]; then
      N8N_BIN="$token"
      break
    fi
  done
fi

if [[ -z "$N8N_BIN" ]] && command_exists n8n; then
  N8N_BIN="$(command -v n8n)"
fi

if [[ -z "$N8N_BIN" ]]; then
  fail "Unable to locate n8n binary. Set N8N_BIN to override."
fi

N8N_DIR="${N8N_DIR:-}"
if [[ -z "$N8N_DIR" ]] && [[ -n "$WORKING_DIR" ]]; then
  N8N_DIR="$WORKING_DIR"
fi

if [[ -z "$N8N_DIR" ]] && [[ "$N8N_BIN" == *"/node_modules/.bin/n8n" ]]; then
  N8N_DIR="${N8N_BIN%/node_modules/.bin/n8n}"
fi

if [[ -z "$N8N_DIR" ]]; then
  N8N_DIR="$(dirname "$N8N_BIN")"
fi

ENV_FILE="${ENV_FILE:-${ENV_FILE_LINE:-$N8N_DIR/.env}}"

if [[ -z "$ENV_FILE" ]]; then
  fail "Unable to determine .env location. Set ENV_FILE to override."
fi

if [[ -f "$ENV_FILE" ]]; then
  log "Using environment file: $ENV_FILE"
else
  log "Environment file not found; will create: $ENV_FILE"
fi

USER_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
USER_HOME="${USER_HOME:-/root}"

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

run_n8n_cli() {
  local args=("$@")
  if [[ "$SERVICE_USER" == "root" ]]; then
    (load_env; "$N8N_BIN" "${args[@]}")
  else
    runuser -u "$SERVICE_USER" -- bash -c 'set -a; [ -f "$1" ] && . "$1"; set +a; shift; "$@"' bash "$ENV_FILE" "$N8N_BIN" "${args[@]}"
  fi
}

run_n8n_cli_sqlite_export() {
  local args=("$@")
  if [[ "$SERVICE_USER" == "root" ]]; then
    (load_env; env DB_TYPE=sqlite DB_SQLITE_DATABASE="$SQLITE_DB_PATH" "$N8N_BIN" "${args[@]}")
  else
    runuser -u "$SERVICE_USER" -- bash -c 'set -a; [ -f "$1" ] && . "$1"; set +a; shift; "$@"' bash "$ENV_FILE" env DB_TYPE=sqlite DB_SQLITE_DATABASE="$SQLITE_DB_PATH" "$N8N_BIN" "${args[@]}"
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"
  local escaped_value="${value//\\/\\\\}"
  escaped_value="${escaped_value//&/\\&}"
  escaped_value="${escaped_value//|/\\|}"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

ensure_postgres() {
  command_exists psql || fail "psql not found. Please install PostgreSQL client/server."
  if ! systemctl is-active --quiet postgresql; then
    log "PostgreSQL service not active. Starting..."
    systemctl start postgresql
  fi

  local db_user_ident
  local db_name_ident
  local db_schema_ident
  db_user_ident="$(pg_quote_identifier "$DB_USER")"
  db_name_ident="$(pg_quote_identifier "$DB_NAME")"
  db_schema_ident="$(pg_quote_identifier "$DB_SCHEMA")"

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    log "Creating PostgreSQL role ${DB_USER}."
    if [[ "$DB_PASSWORDLESS" == "true" ]]; then
      runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE USER ${db_user_ident};"
    else
      local db_pass_literal
      db_pass_literal="$(pg_quote_literal "$DB_PASSWORD")"
      runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE USER ${db_user_ident} WITH PASSWORD ${db_pass_literal};"
    fi
  else
    log "PostgreSQL role ${DB_USER} already exists."
    if [[ "$DB_PASSWORDLESS" == "true" ]]; then
      runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER USER ${db_user_ident} PASSWORD NULL;"
    fi
  fi

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    log "Creating PostgreSQL database ${DB_NAME}."
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${db_name_ident};"
  else
    log "PostgreSQL database ${DB_NAME} already exists."
  fi

  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE ${db_name_ident} TO ${db_user_ident};"
  runuser -u postgres -- psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "CREATE SCHEMA IF NOT EXISTS ${db_schema_ident} AUTHORIZATION ${db_user_ident};"

  if [[ "$DB_PASSWORDLESS" == "true" ]]; then
    local hba_file
    hba_file="$(runuser -u postgres -- psql -tAc "SHOW hba_file")"
    if [[ -z "$hba_file" ]]; then
      fail "Unable to locate pg_hba.conf for passwordless configuration."
    fi
    local db_user_regex
    local hba_mode
    local hba_owner
    local hba_group
    local hba_tmp
    local hba_base
    local hba_filter_pattern
    local hba_peer_rule_pattern
    db_user_regex="$(printf '%s' "$DB_USER" | sed 's/[][\\.^$*+?()|{}]/\\\\&/g')"
    hba_mode="$(stat -c %a "$hba_file")"
    hba_owner="$(stat -c %u "$hba_file")"
    hba_group="$(stat -c %g "$hba_file")"
    hba_tmp="$(mktemp)"
    hba_base="$(mktemp)"
    hba_peer_rule_pattern='^local[[:space:]]+all[[:space:]]+all[[:space:]]+peer'
    # Use \\( and \\) to match the literal parentheses in the marker comment.
    hba_filter_pattern='n8n passwordless access|local socket peer authentication \(migration script\)'
    hba_filter_pattern+="|^local[[:space:]]+all[[:space:]]+${db_user_regex}[[:space:]]+(peer|trust)"
    hba_filter_pattern+="|^host[[:space:]]+all[[:space:]]+${db_user_regex}[[:space:]]+127\\.0\\.0\\.1/32[[:space:]]+trust"
    hba_filter_pattern+="|^host[[:space:]]+all[[:space:]]+${db_user_regex}[[:space:]]+::1/128[[:space:]]+trust"
    if ! grep -v -E "$hba_filter_pattern" "$hba_file" > "$hba_base"; then
      if [[ ! -f "$hba_base" ]]; then
        rm -f "$hba_tmp" "$hba_base"
        fail "Failed to filter pg_hba.conf rules."
      fi
    fi
    if ! grep -q -E "$hba_peer_rule_pattern" "$hba_base"; then
      # Add general peer auth for local socket connections if no such rule exists.
      cat > "$hba_tmp" <<EOF
# local socket peer authentication (migration script)
local all all peer
EOF
      cat "$hba_base" >> "$hba_tmp"
    else
      cat "$hba_base" > "$hba_tmp"
    fi
    cat "$hba_tmp" > "$hba_file"
    chown "$hba_owner:$hba_group" "$hba_file"
    chmod "$hba_mode" "$hba_file"
    rm -f "$hba_tmp" "$hba_base"
    systemctl reload postgresql
  fi
}

find_sqlite_db() {
  local candidate=""
  load_env
  if [[ -n "${DB_SQLITE_DATABASE:-}" ]]; then
    candidate="$DB_SQLITE_DATABASE"
  elif [[ -n "${N8N_USER_FOLDER:-}" ]]; then
    candidate="$N8N_USER_FOLDER/database.sqlite"
  else
    candidate="$USER_HOME/.n8n/database.sqlite"
  fi

  if [[ -f "$candidate" ]]; then
    echo "$candidate"
    return
  fi

  find "$N8N_DIR" "$USER_HOME" -maxdepth 4 -name database.sqlite 2>/dev/null | head -n 1 || true
}

ensure_sqlite_secrets_table() {
  local db_path="$1"
  if [[ -z "$db_path" || ! -f "$db_path" ]]; then
    return
  fi
  if ! command_exists sqlite3; then
    log "sqlite3 not found; skipping SQLite table checks."
    return
  fi
  if [[ -z "$(sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table' AND name='secrets_provider_connection';")" ]]; then
    log "Creating missing secrets_provider_connection table in SQLite."
    sqlite3 "$db_path" <<'SQL'
CREATE TABLE IF NOT EXISTS secrets_provider_connection (
  providerKey TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  encryptedSettings TEXT,
  isEnabled BOOLEAN NOT NULL DEFAULT 0,
  createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
SQL
  fi

  if [[ -z "$(sqlite3 "$db_path" "SELECT name FROM sqlite_master WHERE type='table' AND name='project_secrets_provider_access';")" ]]; then
    log "Creating missing project_secrets_provider_access table in SQLite."
    sqlite3 "$db_path" <<'SQL'
CREATE TABLE IF NOT EXISTS project_secrets_provider_access (
  providerKey TEXT NOT NULL,
  projectId TEXT NOT NULL,
  createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (providerKey, projectId)
);
SQL
  fi
}

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_DIR="/tmp/n8n-backup-${TIMESTAMP}"
EXPORT_DIR="/tmp/n8n-export-${TIMESTAMP}"

log "Stopping n8n service."
systemctl stop "$SERVICE_NAME"

load_env
N8N_USER_FOLDER="${N8N_USER_FOLDER:-$USER_HOME/.n8n}"

log "Creating backup at $BACKUP_DIR."
mkdir -p "$BACKUP_DIR"
if command_exists rsync; then
  rsync -a "$N8N_DIR"/ "$BACKUP_DIR"/
else
  cp -a "$N8N_DIR"/. "$BACKUP_DIR"/
fi

if [[ -d "$N8N_USER_FOLDER" && "$N8N_USER_FOLDER" != "$N8N_DIR" && "$N8N_USER_FOLDER" != "$N8N_DIR/"* ]]; then
  log "Backing up n8n user folder at $N8N_USER_FOLDER."
  if command_exists rsync; then
    rsync -a "$N8N_USER_FOLDER"/ "$BACKUP_DIR/user-folder"/
  else
    mkdir -p "$BACKUP_DIR/user-folder"
    cp -a "$N8N_USER_FOLDER"/. "$BACKUP_DIR/user-folder"/
  fi
fi

SQLITE_DB_PATH="$(find_sqlite_db)"
ensure_sqlite_secrets_table "$SQLITE_DB_PATH"

log "Exporting n8n entities to $EXPORT_DIR."
mkdir -p "$EXPORT_DIR"
chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$EXPORT_DIR"
EXPORT_CMD="run_n8n_cli"
if [[ "${DB_TYPE:-}" == "postgresdb" && -n "${SQLITE_DB_PATH:-}" ]]; then
  log "PostgreSQL config detected in .env; overriding to SQLite for export."
  EXPORT_CMD="run_n8n_cli_sqlite_export"
fi
if ! $EXPORT_CMD export:entities --outputDir="$EXPORT_DIR" --includeExecutionHistoryDataTables=true 2>&1 | tee -a "$LOG_FILE"; then
  fail "n8n export:entities failed."
fi

DB_NAME="${DB_POSTGRESDB_DATABASE:-$DEFAULT_DB_NAME}"
DB_USER="${DB_POSTGRESDB_USER:-$DEFAULT_DB_NAME}"
DB_HOST="${DB_POSTGRESDB_HOST:-$DEFAULT_DB_HOST}"
DB_PORT="${DB_POSTGRESDB_PORT:-$DEFAULT_DB_PORT}"
DB_SCHEMA="${DB_POSTGRESDB_SCHEMA:-$DEFAULT_DB_SCHEMA}"
DB_PASSWORDLESS="${DB_PASSWORDLESS:-$DEFAULT_DB_PASSWORDLESS}"

if [[ "$DB_PASSWORDLESS" == "true" ]]; then
  DB_PASSWORD=""
  log "PostgreSQL passwordless mode enabled; no password will be set."
  if [[ -z "$DB_HOST" || "$DB_HOST" == "localhost" || "$DB_HOST" == "127.0.0.1" ]]; then
    DB_HOST="/var/run/postgresql"
  fi
else
  if [[ -n "${DB_POSTGRESDB_PASSWORD:-}" ]]; then
    DB_PASSWORD="$DB_POSTGRESDB_PASSWORD"
  else
    read -r -s -p "Enter password for PostgreSQL user ${DB_USER}: " DB_PASSWORD
    echo
  fi

  [[ -z "$DB_PASSWORD" ]] && fail "PostgreSQL password cannot be empty."
fi

ensure_postgres

log "Updating environment file with PostgreSQL settings."
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
cp "$ENV_FILE" "${ENV_FILE}.bak.${TIMESTAMP}"
set_env_value DB_TYPE "postgresdb"
set_env_value DB_POSTGRESDB_DATABASE "$DB_NAME"
set_env_value DB_POSTGRESDB_HOST "$DB_HOST"
set_env_value DB_POSTGRESDB_PORT "$DB_PORT"
set_env_value DB_POSTGRESDB_USER "$DB_USER"
set_env_value DB_POSTGRESDB_PASSWORD "$DB_PASSWORD"
set_env_value DB_POSTGRESDB_SCHEMA "$DB_SCHEMA"

log "Ensuring ownership for n8n directories."
chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$N8N_DIR"
if [[ -d "$N8N_USER_FOLDER" && "$N8N_USER_FOLDER" != "$N8N_DIR" && "$N8N_USER_FOLDER" != "$N8N_DIR"/* ]]; then
  chown -R "$SERVICE_USER":"$SERVICE_GROUP" "$N8N_USER_FOLDER"
fi

log "Starting n8n service."
systemctl start "$SERVICE_NAME"

log "Waiting for n8n service to become active."
for _ in {1..30}; do
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    break
  fi
  sleep 2
done

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl --no-pager status "$SERVICE_NAME" || true
  fail "n8n service failed to start."
fi

load_env
N8N_PORT="${N8N_PORT:-5678}"
N8N_PORT_HOST="${N8N_PORT_HOST:-127.0.0.1}"
if command_exists nc; then
  if ! nc -z -w 3 "$N8N_PORT_HOST" "$N8N_PORT"; then
    log "Warning: n8n port $N8N_PORT not reachable yet on $N8N_PORT_HOST."
  fi
fi

log "Validating n8n CLI availability."
run_n8n_cli --version >/dev/null

log "Importing entities from $EXPORT_DIR."
db_user_ident="$(pg_quote_identifier "$DB_USER")"
IMPORT_SUPERUSER_USER_IDENT="$db_user_ident"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER USER ${db_user_ident} WITH SUPERUSER;"
IMPORT_SUPERUSER_GRANTED="true"
if ! run_n8n_cli import:entities --inputDir "$EXPORT_DIR" --truncateTables true 2>&1 | tee -a "$LOG_FILE"; then
  cleanup_import_privileges
  fail "n8n import:entities failed."
fi
cleanup_import_privileges

log "Checking systemd status and recent logs for errors."
systemctl --no-pager status "$SERVICE_NAME"
SERVICE_START_TIME="$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE_NAME")"
if [[ -n "$SERVICE_START_TIME" ]] && journalctl -u "$SERVICE_NAME" --since "$SERVICE_START_TIME" --no-pager | grep -Ei "error|fatal" >/dev/null; then
  fail "Detected errors in journalctl output since service start."
fi

SQLITE_DB_PATH="$(find_sqlite_db)"
if [[ -n "$SQLITE_DB_PATH" && -f "$SQLITE_DB_PATH" ]]; then
  read -r -p "Migration complete. Remove old SQLite DB at $SQLITE_DB_PATH? [y/N]: " REMOVE_SQLITE
  if [[ "$REMOVE_SQLITE" =~ ^[Yy]$ ]]; then
    rm -f "$SQLITE_DB_PATH"
    log "Removed SQLite database at $SQLITE_DB_PATH."
  else
    log "SQLite database retained at $SQLITE_DB_PATH."
  fi
else
  log "SQLite database not found; nothing to remove."
fi

log "Migration completed successfully."
