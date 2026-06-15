#!/usr/bin/env bash
# Build the self-contained distribution image: our built mysqld with the in-tree
# DuckDB engine. Requires a server build first (scripts/build-server.sh; use
# BUILD_TYPE=RelWithDebInfo or Release for a slim image).
#
# Usage: scripts/release-image.sh [image:tag]
#   default tag: ducksdb/mysql:9.7-duckdb-dev
#
# Phase 1 (inside ducksdb-builder): cmake --install -> prune -> strip into the
#   build context dist/distimage/mysql.
# Phase 2 (host): docker build the context.
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
IMAGE=${1:-ducksdb/mysql:9.7-duckdb-dev}
CTX="$REPO/dist/distimage"
BUILDER=${BUILDER:-ducksdb-builder:latest}

[ -x "$REPO/vendor/mysql-server/build/runtime_output_directory/mysqld" ] || {
    echo "ERROR: mysqld not built — run scripts/build-server.sh first"; exit 1; }

BT=$(grep -E "^CMAKE_BUILD_TYPE:" "$REPO/vendor/mysql-server/build/CMakeCache.txt" 2>/dev/null | cut -d= -f2)
echo "=== bundling a ${BT:-unknown}-build mysqld as $IMAGE ==="
[ "$BT" = "Debug" ] && echo "NOTE: Debug build — rebuild with BUILD_TYPE=RelWithDebInfo for a slim release image."

echo "=== phase 1: install + prune + strip (in builder) ==="
docker run --rm -v "$REPO":/work -w /work "$BUILDER" bash -c '
set -euo pipefail
CTX=/work/dist/distimage
I="$CTX/mysql"
rm -rf "$CTX"; mkdir -p "$CTX"
cmake --install /work/vendor/mysql-server/build --prefix "$I" >/tmp/install.log 2>&1 || { tail -20 /tmp/install.log; exit 1; }

# Prune everything not needed to run a server.
( cd "$I" && rm -rf mysql-test man docs include support-files var run \
    mysqlrouter* LICENSE-test README-test README.router share/doc 2>/dev/null || true )

# bin/: keep only the server + a few clients/tools used by the entrypoint.
( cd "$I/bin" && ls | grep -vE "^(mysqld|mysql|mysqladmin|my_print_defaults|mysql_tzinfo_to_sql)$" | xargs -r rm -f )

# plugin/: drop test/example artifacts; keep the real default components.
( cd "$I/lib/plugin" 2>/dev/null && ls | grep -iE "test|example|adt_null" | xargs -r rm -f ) || true

# Strip binaries and shared libraries (the big size win).
find "$I/bin" -type f -exec strip --strip-unneeded {} + 2>/dev/null || true
find "$I/lib" -type f -name "*.so*" -exec strip --strip-unneeded {} + 2>/dev/null || true

cp /work/docker/Dockerfile   "$CTX/Dockerfile"
cp /work/docker/entrypoint.sh "$CTX/entrypoint.sh"
echo "=== staged install size ==="; du -sh "$I"
'

echo "=== phase 2: docker build ==="
docker build -t "$IMAGE" "$CTX"
echo "Built: $IMAGE"
