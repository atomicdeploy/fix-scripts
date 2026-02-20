#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SQLITE_DB="${SQLITE_DB:-}"
PG_DB="${PG_DB:-n8n}"
PG_SCHEMA="${PG_SCHEMA:-n8n}"
FORCE_SYNC_TABLES="${FORCE_SYNC_TABLES:-false}"

if [[ -z "$SQLITE_DB" ]]; then
  SQLITE_DB="$(ls -t /tmp/database.sqlite.backup-* 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$SQLITE_DB" || ! -f "$SQLITE_DB" ]]; then
  echo "SQLite backup not found. Set SQLITE_DB to the backup path." >&2
  exit 1
fi

echo "Using SQLite backup: $SQLITE_DB"

sqlite_tables=$(sqlite3 "$SQLITE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;") || {
  echo "Failed to read SQLite tables from $SQLITE_DB" >&2
  exit 1
}
pg_tables=$(runuser -u n8n -- psql -d "$PG_DB" -Atc "SELECT tablename FROM pg_tables WHERE schemaname='${PG_SCHEMA}' ORDER BY tablename;") || {
  echo "Failed to read Postgres tables from $PG_DB" >&2
  exit 1
}

missing_tables=()
for table in $sqlite_tables; do
  if ! grep -qx "$table" <<< "$pg_tables"; then
    missing_tables+=("$table")
  fi
done

echo "Missing tables in Postgres: ${#missing_tables[@]}"

convert_schema() {
  local table="$1"
  TABLE="$table" SQLITE_DB="$SQLITE_DB" PG_SCHEMA="$PG_SCHEMA" python - <<'PY'
import os
import re
import sqlite3

db_path = os.environ['SQLITE_DB']
pg_schema = os.environ['PG_SCHEMA']
table = os.environ['TABLE']
conn = sqlite3.connect(db_path)
row = conn.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
if not row or not row[0]:
    raise SystemExit(1)
sql = row[0]
sql = re.sub(r'CREATE TABLE IF NOT EXISTS "([^"]+)"', fr'CREATE TABLE IF NOT EXISTS {pg_schema}."\\1"', sql)
sql = re.sub(r'\bDOUBLE\b', 'double precision', sql, flags=re.I)
sql = re.sub(r'\bREAL\b', 'double precision', sql, flags=re.I)
sql = re.sub(r'\bBOOLEAN\b', 'boolean', sql, flags=re.I)
sql = re.sub(r'\bDATETIME\b', 'timestamp', sql, flags=re.I)
sql = re.sub(r'datetime\(\d+\)', 'timestamp', sql, flags=re.I)
sql = sql.replace("STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW')", 'CURRENT_TIMESTAMP')
print(sql + ';')
PY
}

column_list() {
  local table="$1"
  sqlite3 "$SQLITE_DB" "PRAGMA table_info(\"$table\");" | awk -F'|' '{print $2}' | paste -sd ',' -
}

for table in "${missing_tables[@]}"; do
  echo "Creating table $table"
  schema_sql=$(convert_schema "$table")
  runuser -u n8n -- psql -d "$PG_DB" -v ON_ERROR_STOP=1 -c "$schema_sql"
  echo "Copying data for $table"
  columns=$(column_list "$table")
  sqlite3 -csv -cmd ".nullvalue \\N" "$SQLITE_DB" "SELECT $columns FROM \"$table\";" | \
    runuser -u n8n -- psql -d "$PG_DB" -v ON_ERROR_STOP=1 -c "COPY ${PG_SCHEMA}.\"$table\" ($columns) FROM STDIN WITH (FORMAT csv, NULL '\\N');"
done

for table in $sqlite_tables; do
  sqlite_count=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM \"$table\";")
  pg_count=$(runuser -u n8n -- psql -d "$PG_DB" -Atc "SELECT COUNT(*) FROM ${PG_SCHEMA}.\"$table\";")
  if [[ "$pg_count" == "0" && "$sqlite_count" != "0" ]]; then
    echo "Syncing data for $table (sqlite=$sqlite_count, pg=$pg_count)"
    runuser -u n8n -- psql -d "$PG_DB" -v ON_ERROR_STOP=1 -c "TRUNCATE ${PG_SCHEMA}.\"$table\";"
    columns=$(column_list "$table")
    sqlite3 -csv -cmd ".nullvalue \\N" "$SQLITE_DB" "SELECT $columns FROM \"$table\";" | \
      runuser -u n8n -- psql -d "$PG_DB" -v ON_ERROR_STOP=1 -c "COPY ${PG_SCHEMA}.\"$table\" ($columns) FROM STDIN WITH (FORMAT csv, NULL '\\N');"
  elif [[ "$pg_count" != "$sqlite_count" && "$FORCE_SYNC_TABLES" == "true" ]]; then
    echo "Force syncing data for $table (sqlite=$sqlite_count, pg=$pg_count)"
    runuser -u n8n -- psql -d "$PG_DB" -v ON_ERROR_STOP=1 -c "TRUNCATE ${PG_SCHEMA}.\"$table\";"
    columns=$(column_list "$table")
    sqlite3 -csv -cmd ".nullvalue \\N" "$SQLITE_DB" "SELECT $columns FROM \"$table\";" | \
      runuser -u n8n -- psql -d "$PG_DB" -v ON_ERROR_STOP=1 -c "COPY ${PG_SCHEMA}.\"$table\" ($columns) FROM STDIN WITH (FORMAT csv, NULL '\\N');"
  elif [[ "$pg_count" != "$sqlite_count" ]]; then
    echo "Counts differ for $table (sqlite=$sqlite_count, pg=$pg_count). Set FORCE_SYNC_TABLES=true to reconcile."
  fi
done

pg_tables=$(runuser -u n8n -- psql -d "$PG_DB" -Atc "SELECT tablename FROM pg_tables WHERE schemaname='${PG_SCHEMA}' ORDER BY tablename;")
missing_tables=()
for table in $sqlite_tables; do
  if ! grep -qx "$table" <<< "$pg_tables"; then
    missing_tables+=("$table")
  fi
done

if [[ ${#missing_tables[@]} -ne 0 ]]; then
  echo "Still missing tables: ${missing_tables[*]}" >&2
  exit 1
fi

echo "All SQLite tables are present in Postgres."
