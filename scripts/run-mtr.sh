#!/usr/bin/env bash
# Run the duckdb MTR suite against the in-tree-built server.
# Usage: scripts/run-mtr.sh [--record] [test_name ...]
# Run inside ducksdb-builder; project mounted at /work.
set -euo pipefail

REPO=${REPO:-/work}
MYSQL_BUILD="$REPO/vendor/mysql-server/build"
MYSQL_TEST="$REPO/vendor/mysql-server/mysql-test"

[ -x "$MYSQL_BUILD/runtime_output_directory/mysqld" ] || {
    echo "ERROR: mysqld not built — run scripts/build-server.sh"; exit 1; }

# Sync our suite into the server's mysql-test tree (copy each run so edits propagate).
rm -rf "$MYSQL_TEST/suite/duckdb"
cp -r "$REPO/mysql-test-suite/duckdb" "$MYSQL_TEST/suite/"

MTR="$MYSQL_BUILD/mysql-test/mtr"
MTR_OPTS="--suite=duckdb --force"
# The engine is built in (MANDATORY) — no plugin to load. Allow running as root.
[ "$(id -u)" = "0" ] && MTR_OPTS="$MTR_OPTS --mysqld=--user=root"

set +e
"$MTR" $MTR_OPTS "$@"
rc=$?
set -e

# When recording, copy freshly written .result files back into the repo suite.
if printf '%s\n' "$@" | grep -q -- '--record'; then
    cp -f "$MYSQL_TEST/suite/duckdb/r/"*.result "$REPO/mysql-test-suite/duckdb/r/" 2>/dev/null || true
    echo "[run-mtr] copied recorded results back to mysql-test-suite/duckdb/r/"
fi
exit $rc
