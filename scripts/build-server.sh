#!/usr/bin/env bash
# Configure and build the full MySQL 9.7 server with the in-tree DuckDB engine
# (MANDATORY). Run inside the ducksdb-builder container; project mounted at /work.
#
#   docker run --rm -v "$PWD":/work -e REPO=/work ducksdb-builder:latest \
#       bash -lc 'cd /work && scripts/build-server.sh'
set -euo pipefail

REPO=${REPO:-/work}
MYSQL_SRC="$REPO/vendor/mysql-server"
MYSQL_BUILD="$MYSQL_SRC/build"
DUCKDB_PREFIX="$REPO/vendor/duckdb-prefix"
BOOST_DIR="$REPO/vendor/boost"
BUILD_TYPE="${BUILD_TYPE:-Debug}"
JOBS="${JOBS:-$(nproc)}"

[ -d "$MYSQL_SRC" ]     || { echo "ERROR: $MYSQL_SRC not found"; exit 1; }
[ -f "$DUCKDB_PREFIX/lib/libduckdb.a" ] || { echo "ERROR: DuckDB prefix missing at $DUCKDB_PREFIX"; exit 1; }
[ -L "$MYSQL_SRC/storage/duckdb" ] || { echo "ERROR: storage/duckdb symlink missing (ln -s ../../engine ...)"; exit 1; }

# Apply the in-tree server patches (whole-query pushdown hook). Idempotent:
# git apply --check succeeds only if a patch is NOT yet applied.
for p in "$REPO"/server-patches/*.patch; do
    [ -f "$p" ] || continue
    if git -C "$MYSQL_SRC" apply --check "$p" 2>/dev/null; then
        git -C "$MYSQL_SRC" apply "$p" && echo "[build-server] applied $(basename "$p")"
    else
        echo "[build-server] $(basename "$p") already applied (or not applicable) — skipping"
    fi
done

mkdir -p "$BOOST_DIR"

ENGINE_SKIPS=(
    -DPLUGIN_ROCKSDB=NO
    -DPLUGIN_NDB=NO
    -DPLUGIN_FEDERATED=NO
    -DPLUGIN_ARCHIVE=NO
    -DPLUGIN_BLACKHOLE=NO
    -DPLUGIN_EXAMPLE=NO
    -DWITH_ROUTER=OFF
)
EXTRA_FLAGS=()
[ "$BUILD_TYPE" != "Debug" ] && EXTRA_FLAGS+=( -DMYSQL_MAINTAINER_MODE=OFF )

need_configure=1
if [ -f "$MYSQL_BUILD/CMakeCache.txt" ]; then
    cur_type=$(grep -E "^CMAKE_BUILD_TYPE:" "$MYSQL_BUILD/CMakeCache.txt" | cut -d= -f2 || true)
    if [ "$cur_type" = "$BUILD_TYPE" ]; then
        need_configure=0
        echo "[build-server] reusing existing $BUILD_TYPE configure"
    else
        echo "[build-server] build type ${cur_type:-none} -> $BUILD_TYPE; reconfiguring"
    fi
fi
if [ "$need_configure" = 1 ]; then
    echo "[build-server] cmake configure ($BUILD_TYPE; downloads Boost on first run)"
    DUCKDB_ROOT="$DUCKDB_PREFIX" \
    cmake -S "$MYSQL_SRC" -B "$MYSQL_BUILD" \
          -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
          -DDOWNLOAD_BOOST=1 \
          -DWITH_BOOST="$BOOST_DIR" \
          -DWITH_UNIT_TESTS=OFF \
          -DCMAKE_PREFIX_PATH="$DUCKDB_PREFIX" \
          "${ENGINE_SKIPS[@]}" "${EXTRA_FLAGS[@]}"
fi

echo "[build-server] building server + client tools (-j$JOBS; first build is long)"
# Build all targets — MTR needs mysqld plus the client tools (mysql, mysqladmin,
# mysqltest, mysqlcheck, ...). Deps are cached, so re-runs are incremental.
DUCKDB_ROOT="$DUCKDB_PREFIX" \
cmake --build "$MYSQL_BUILD" -j"$JOBS"

echo "[build-server] done:"
ls -la "$MYSQL_BUILD/runtime_output_directory/mysqld" 2>/dev/null || echo "  (mysqld not found — check build log)"
echo "[build-server] DuckDB engine should be built in. Verify with: SHOW ENGINES;"
