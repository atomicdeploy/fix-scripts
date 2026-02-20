#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

LOG_FILE="${LOG_FILE:-/var/log/n8n-postgres-migration.log}"
DEFAULT_DB_NAME="n8n"
DEFAULT_DB_HOST="localhost"
DEFAULT_DB_PORT="5432"
DEFAULT_DB_SCHEMA="n8n"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
  local message="$*"
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $message" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR: $*"
  exit 1
}

trap 'fail "Script failed on line $LINENO."' ERR

if [[ "$(id -u)" -ne 0 ]]; then
  fail "This script must be run as root."
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
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
    runuser -u "$SERVICE_USER" -- bash -c 'set -a; [ -f "$1" ] && . "$1"; set +a; shift; exec "$@"' bash "$ENV_FILE" "$N8N_BIN" "${args[@]}"
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

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    log "Creating PostgreSQL role ${DB_USER}."
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v "db_user=${DB_USER}" -v "db_pass=${DB_PASSWORD}" -c "CREATE USER :\"db_user\" WITH PASSWORD :'db_pass';"
  else
    log "PostgreSQL role ${DB_USER} already exists."
  fi

  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    log "Creating PostgreSQL database ${DB_NAME}."
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v "db_name=${DB_NAME}" -c "CREATE DATABASE :\"db_name\";"
  else
    log "PostgreSQL database ${DB_NAME} already exists."
  fi

  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -v "db_name=${DB_NAME}" -v "db_user=${DB_USER}" -c "GRANT ALL PRIVILEGES ON DATABASE :\"db_name\" TO :\"db_user\";"
  runuser -u postgres -- psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -v "db_schema=${DB_SCHEMA}" -v "db_user=${DB_USER}" -c "CREATE SCHEMA IF NOT EXISTS :\"db_schema\" AUTHORIZATION :\"db_user\";"
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

log "Exporting n8n entities to $EXPORT_DIR."
mkdir -p "$EXPORT_DIR"
run_n8n_cli export:entities --outputDir="$EXPORT_DIR" --includeExecutionHistoryDataTables=true

DB_NAME="${DB_POSTGRESDB_DATABASE:-$DEFAULT_DB_NAME}"
DB_USER="${DB_POSTGRESDB_USER:-$DEFAULT_DB_NAME}"
DB_HOST="${DB_POSTGRESDB_HOST:-$DEFAULT_DB_HOST}"
DB_PORT="${DB_POSTGRESDB_PORT:-$DEFAULT_DB_PORT}"
DB_SCHEMA="${DB_POSTGRESDB_SCHEMA:-$DEFAULT_DB_SCHEMA}"

if [[ -n "${DB_POSTGRESDB_PASSWORD:-}" ]]; then
  DB_PASSWORD="$DB_POSTGRESDB_PASSWORD"
else
  read -r -s -p "Enter password for PostgreSQL user ${DB_USER}: " DB_PASSWORD
  echo
fi

[[ -z "$DB_PASSWORD" ]] && fail "PostgreSQL password cannot be empty."

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
run_n8n_cli import:entities --inputDir "$EXPORT_DIR" --truncateTables true

log "Checking systemd status and recent logs for errors."
systemctl --no-pager status "$SERVICE_NAME"
if journalctl -u "$SERVICE_NAME" -n 50 --no-pager | grep -Ei "error|fatal" >/dev/null; then
  fail "Detected errors in journalctl output."
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
