#!/usr/bin/env bash
# Entrypoint for the MySQL 9.7 + DuckDB engine image. Initializes the datadir on
# first run, then starts mysqld. ENGINE=DuckDB is a built-in engine, so there is
# no plugin to load.
#
# Environment:
#   MYSQL_ROOT_PASSWORD  root password (empty => passwordless root, dev only)
#   MYSQL_DATADIR        data directory (default /var/lib/mysql)
set -euo pipefail

export PATH=/usr/local/mysql/bin:$PATH
DATADIR=${MYSQL_DATADIR:-/var/lib/mysql}
mkdir -p "$DATADIR"

FIRST_INIT=""
if [ ! -d "$DATADIR/mysql" ]; then
    echo "[ducksdb] first run: initializing datadir at $DATADIR"
    mysqld --no-defaults --datadir="$DATADIR" --user=root --initialize-insecure

    PW="${MYSQL_ROOT_PASSWORD:-}"
    FIRST_INIT="$(mktemp)"
    {
        echo "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${PW}';"
        echo "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
        if [ -n "$PW" ]; then
            echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '${PW}';"
        fi
        echo "FLUSH PRIVILEGES;"
    } > "$FIRST_INIT"
    if [ -z "$PW" ]; then
        echo "[ducksdb] NOTE: empty root password. Set MYSQL_ROOT_PASSWORD to secure it."
    fi
fi

echo "[ducksdb] starting mysqld (ENGINE=DuckDB built in)"
# The default CMD is `mysqld`; drop it so it is not passed as an extra arg.
if [ "${1:-}" = "mysqld" ]; then shift; fi
exec mysqld --no-defaults \
    --datadir="$DATADIR" --user=root \
    --bind-address=0.0.0.0 --port=3306 \
    ${FIRST_INIT:+--init-file="$FIRST_INIT"} \
    "$@"
