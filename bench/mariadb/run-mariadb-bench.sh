#!/usr/bin/env bash
# =============================================================================
# run-mariadb-bench.sh — MariaDB-only micro-benchmark (quick smoke test).
# =============================================================================
# The MariaDB ENGINE=DuckDB leg of the 1M-row `facts` micro-benchmark (the
# counterpart to bench/run-engine-bench.sh). Boots the locally-built mariadbd,
# loads the same 1M rows, runs Q1-Q6, server-side timing via SHOW PROFILES
# (min over ITERS). Use it for a fast sanity check before the full TPC-H run.
#
# ---- PREREQUISITES (see bench/mariadb/README.md) ----------------------------
#   1. A built MariaDB 11.4.x with the DuckDB storage engine (`ha_duckdb.so`);
#      point MARIADB_BUILD / MARIADB_SRC at your build + source dirs.
#   2. The 1M-row facts CSV at $CSV (default $REPO/bench/data/facts.csv, which
#      is committed in this repo).
#
# Run inside ducksdb-builder, mounting the MariaDB build at /work and repo /repo:
#   docker run --rm \
#     -v "$PWD/mariadb-bench":/work \
#     -v "$PWD/ducksdb-mysql-engine":/repo ducksdb-builder:latest \
#     bash -lc 'ITERS=5 bash /repo/bench/mariadb/run-mariadb-bench.sh'
#
# Env knobs (defaults in parens):
#   ITERS(5)
#   MARIADB_BUILD(/work/DuckdbBuildOf_mariadb-server)
#   MARIADB_SRC(/work/mariadb-server)
#   REPO(/repo)  CSV($REPO/bench/data/facts.csv)
# =============================================================================
set -uo pipefail
ITERS=${ITERS:-5}
MARIADB_BUILD=${MARIADB_BUILD:-/work/DuckdbBuildOf_mariadb-server}
MARIADB_SRC=${MARIADB_SRC:-/work/mariadb-server}
REPO=${REPO:-/repo}
MB=$MARIADB_BUILD; SRC=$MARIADB_SRC
CSV=${CSV:-$REPO/bench/data/facts.csv}; D=/tmp/mdb-data; S=/tmp/mdb.sock
export DEBIAN_FRONTEND=noninteractive

# ---- preflight --------------------------------------------------------------
[ -x "$MB/sql/mariadbd" ] || {
  echo "ERROR: mariadbd not found at $MB/sql/mariadbd"
  echo "  Set MARIADB_BUILD to your MariaDB + DuckDB-engine build dir."
  echo "  See bench/mariadb/README.md for how to build it."; exit 2; }
[ -f "$CSV" ] || { echo "ERROR: facts CSV not found at $CSV"; exit 3; }

apt-get update -qq >/dev/null 2>&1; apt-get install -y libaio1t64 libnuma1 >/dev/null 2>&1

minv(){ printf '%s\n' "$@" | sort -n | head -1; }
SCHEMA='id BIGINT PRIMARY KEY, d_year INT, category INT, region INT, quantity INT,
        price DECIMAL(12,2), discount DECIMAL(5,2), ts DATETIME'
DIM="(0,1.00),(1,1.10),(2,1.20),(3,1.30),(4,1.40),(5,1.50),(6,1.60),(7,1.70),(8,1.80),(9,1.90)"
QUERIES=(
  "Q1 scan+filter+sum|SELECT SUM(price*quantity) FROM facts WHERE d_year=2022"
  "Q2 groupby+avg|SELECT category, COUNT(*), SUM(quantity), AVG(price) FROM facts GROUP BY category ORDER BY category"
  "Q3 filter+group+order|SELECT region, d_year, SUM(price*quantity*(1-discount/100)) rev FROM facts WHERE discount>5 GROUP BY region, d_year ORDER BY rev DESC LIMIT 20"
  "Q4 wide aggregate|SELECT COUNT(*), MIN(price), MAX(price), AVG(quantity) FROM facts"
  "Q5 count distinct|SELECT COUNT(DISTINCT category) FROM facts WHERE region<5"
  "Q6 star join+group|SELECT f.region, SUM(f.price*f.quantity*d.w) rev FROM facts f JOIN region_dim d ON f.region=d.region WHERE f.d_year=2022 GROUP BY f.region ORDER BY f.region"
)

rm -rf "$D"; mkdir -p "$D"
"$MB/scripts/mariadb-install-db" --no-defaults --builddir="$MB" --srcdir="$SRC" --datadir="$D" --auth-root-authentication-method=normal >/tmp/idb.log 2>&1
"$MB/sql/mariadbd" --no-defaults --user=root --basedir="$MB" --datadir="$D" --lc-messages-dir="$MB/sql/share" \
   --plugin-dir="$MB/storage/duckdb" --plugin-load-add=ha_duckdb.so \
   --socket="$S" --skip-networking --secure-file-priv="" --local-infile=1 >/tmp/mdb.log 2>&1 &
MPID=$!; trap 'kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null' EXIT
for i in $(seq 1 90); do "$MB/client/mariadb" --no-defaults -S "$S" -uroot -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
C(){ "$MB/client/mariadb" --no-defaults -S "$S" -uroot --local-infile=1 "$@"; }
C -e "SELECT 1" >/dev/null 2>&1 || { echo "mariadbd not up"; tail -20 /tmp/mdb.log; exit 1; }

echo "[mdb] loading ENGINE=DuckDB (1M rows) ..."
C -e "DROP DATABASE IF EXISTS wd; CREATE DATABASE wd; USE wd;
      CREATE TABLE facts ($SCHEMA) ENGINE=DuckDB;
      LOAD DATA LOCAL INFILE '$CSV' INTO TABLE facts FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n';
      CREATE TABLE region_dim (region INT PRIMARY KEY, w DECIMAL(5,2)) ENGINE=DuckDB;
      INSERT INTO region_dim VALUES $DIM;" 2>>/tmp/load.err
echo "[mdb] rows=$(C -N -B wd -e 'SELECT COUNT(*) FROM facts' 2>/dev/null)"

myprof(){ local sql="$1" t=() r; for _ in $(seq 1 "$ITERS"); do
    r=$(C -N -B wd -e "SET profiling=1; $sql; SHOW PROFILES;" 2>/dev/null | grep -iE "FROM facts" | awk '{print $2}' | sort -n | head -1); t+=("${r:-9999}"); done
  minv "${t[@]}"; }

printf '\n%-24s %16s\n' "query" "MariaDB DuckDB(s)"
printf '%-24s %16s\n' "------------------------" "----------------"
for e in "${QUERIES[@]}"; do
  name="${e%%|*}"; sql="${e#*|}"
  printf '%-24s %16s\n' "$name" "$(myprof "$sql")"
done
echo "[mdb] server-side via SHOW PROFILES, min of $ITERS."
