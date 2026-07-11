#!/usr/bin/env bash
# =============================================================================
# run-mariadb-tpch22.sh — independent MariaDB-only TPC-H run.
# =============================================================================
# The MariaDB `ENGINE=DuckDB` leg of the 4-engine comparison, on the SAME host
# and SAME data as bench/run-tpch22.sh, for apples-to-apples numbers. It boots
# the locally-built `mariadbd` with only the DuckDB plugin, loads the 8 TPC-H
# tables as ENGINE=DuckDB, and times all 22 queries (warm wall-clock, min over
# ITERS, 1 warmup excluded). It touches neither InnoDB nor the in-tree MySQL
# engine — this is MariaDB on its own.
#
# ---- PREREQUISITES (see bench/mariadb/README.md) ----------------------------
#   1. A built MariaDB 11.4.x with the DuckDB storage engine (`ha_duckdb.so`).
#      This tree is NOT committed (gigabytes of third-party source + binaries);
#      point MARIADB_BUILD / MARIADB_SRC at your build + source dirs.
#   2. Generated TPC-H data + MySQL-dialect queries at $REPO/bench/data-sf$SF.
#      Produce them first (fast, skips the slow InnoDB leg):
#          SF=$SF SKIP_INNODB=1 bench/run-tpch22.sh
#
# Run inside ducksdb-builder (Ubuntu 24.04), mounting the MariaDB build at /work
# and this repo at /repo:
#   docker run --rm \
#     -v "$PWD/mariadb-bench":/work \
#     -v "$PWD/ducksdb-mysql-engine":/repo ducksdb-builder:latest \
#     bash -lc 'SF=10 ITERS=3 bash /repo/bench/mariadb/run-mariadb-tpch22.sh'
#
# Env knobs (defaults in parens):
#   SF(10) ITERS(3) NO_CLEAN(0)
#   MARIADB_BUILD(/work/DuckdbBuildOf_mariadb-server)
#   MARIADB_SRC(/work/mariadb-server)
#   REPO(/repo)  -> reads $REPO/bench/data-sf$SF/{*.csv,queries/q*.sql}
#   NO_CLEAN=1   -> CSVs are already quote-free (e.g. SF100); load in place
#                   instead of copying (a 130GB duplicate won't fit at SF100).
# =============================================================================
set -uo pipefail
ITERS=${ITERS:-3}
SF=${SF:-10}
MARIADB_BUILD=${MARIADB_BUILD:-/work/DuckdbBuildOf_mariadb-server}
MARIADB_SRC=${MARIADB_SRC:-/work/mariadb-server}
REPO=${REPO:-/repo}
MB=$MARIADB_BUILD; SRC=$MARIADB_SRC
DATA=$REPO/bench/data-sf$SF; QDIR=$DATA/queries
D=/tmp/mdb-data; S=/tmp/mdb.sock; CLEAN=/tmp/mdb-clean
export DEBIAN_FRONTEND=noninteractive

# ---- preflight --------------------------------------------------------------
[ -x "$MB/sql/mariadbd" ] || {
  echo "ERROR: mariadbd not found at $MB/sql/mariadbd"
  echo "  Set MARIADB_BUILD to your MariaDB + DuckDB-engine build dir."
  echo "  See bench/mariadb/README.md for how to build it."; exit 2; }
[ -f "$DATA/lineitem.csv" ] || {
  echo "ERROR: no TPC-H data at $DATA"
  echo "  Generate it first:  SF=$SF SKIP_INNODB=1 bench/run-tpch22.sh"; exit 3; }

apt-get update -qq >/dev/null 2>&1; apt-get install -y libaio1t64 libnuma1 >/dev/null 2>&1

ddl(){ case "$1" in
  region)   echo "r_regionkey INT, r_name CHAR(25), r_comment VARCHAR(152), PRIMARY KEY (r_regionkey)";;
  nation)   echo "n_nationkey INT, n_name CHAR(25), n_regionkey INT, n_comment VARCHAR(152), PRIMARY KEY (n_nationkey)";;
  supplier) echo "s_suppkey INT, s_name CHAR(25), s_address VARCHAR(40), s_nationkey INT, s_phone CHAR(15), s_acctbal DECIMAL(15,2), s_comment VARCHAR(101), PRIMARY KEY (s_suppkey)";;
  customer) echo "c_custkey INT, c_name VARCHAR(25), c_address VARCHAR(40), c_nationkey INT, c_phone CHAR(15), c_acctbal DECIMAL(15,2), c_mktsegment CHAR(10), c_comment VARCHAR(117), PRIMARY KEY (c_custkey)";;
  part)     echo "p_partkey INT, p_name VARCHAR(55), p_mfgr CHAR(25), p_brand CHAR(10), p_type VARCHAR(25), p_size INT, p_container CHAR(10), p_retailprice DECIMAL(15,2), p_comment VARCHAR(23), PRIMARY KEY (p_partkey)";;
  partsupp) echo "ps_partkey INT, ps_suppkey INT, ps_availqty INT, ps_supplycost DECIMAL(15,2), ps_comment VARCHAR(199), PRIMARY KEY (ps_partkey, ps_suppkey)";;
  orders)   echo "o_orderkey BIGINT, o_custkey INT, o_orderstatus CHAR(1), o_totalprice DECIMAL(15,2), o_orderdate DATE, o_orderpriority CHAR(15), o_clerk CHAR(15), o_shippriority INT, o_comment VARCHAR(79), PRIMARY KEY (o_orderkey)";;
  lineitem) echo "l_orderkey BIGINT, l_partkey INT, l_suppkey INT, l_linenumber INT, l_quantity DECIMAL(15,2), l_extendedprice DECIMAL(15,2), l_discount DECIMAL(15,2), l_tax DECIMAL(15,2), l_returnflag CHAR(1), l_linestatus CHAR(1), l_shipdate DATE, l_commitdate DATE, l_receiptdate DATE, l_shipinstruct CHAR(25), l_shipmode CHAR(10), l_comment VARCHAR(44), PRIMARY KEY (l_orderkey, l_linenumber)";;
esac; }
TABLES="region nation supplier customer part partsupp orders lineitem"

minv(){ printf '%s\n' "$@" | sort -n | head -1; }

# Clean CSVs (strip the quotes DuckDB-export adds to some string fields) so the
# data matches the in-tree-engine run exactly.
# NO_CLEAN=1: CSVs are already quote-free (e.g. SF100, cleaned in-place) — load
# directly from $DATA instead of copying (a 130GB duplicate won't fit at SF100).
if [ "${NO_CLEAN:-0}" = 1 ]; then
  CLEAN="$DATA"
else
  rm -rf "$CLEAN"; mkdir -p "$CLEAN"
  for t in $TABLES; do tr -d '"' < "$DATA/$t.csv" > "$CLEAN/$t.csv"; done
fi

rm -rf "$D"; mkdir -p "$D"
"$MB/scripts/mariadb-install-db" --no-defaults --builddir="$MB" --srcdir="$SRC" \
  --datadir="$D" --auth-root-authentication-method=normal >/tmp/idb.log 2>&1 \
  || { echo "install-db FAILED"; tail -20 /tmp/idb.log; exit 1; }
"$MB/sql/mariadbd" --no-defaults --user=root --basedir="$MB" --datadir="$D" \
  --lc-messages-dir="$MB/sql/share" --plugin-dir="$MB/storage/duckdb" \
  --plugin-load-add=ha_duckdb.so --socket="$S" --skip-networking \
  --secure-file-priv="" --local-infile=1 \
  --innodb-buffer-pool-size=2G >/tmp/mdb.log 2>&1 &
MPID=$!; trap 'kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null' EXIT
for i in $(seq 1 90); do "$MB/client/mariadb" --no-defaults -S "$S" -uroot -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
C(){ "$MB/client/mariadb" --no-defaults -S "$S" -uroot "$@"; }
C -e "SELECT 1" >/dev/null 2>&1 || { echo "mariadbd not up"; tail -30 /tmp/mdb.log; exit 1; }
echo "[mdb] mariadbd up; ENGINE=DuckDB plugin loaded:"; C -e "SELECT engine,support FROM information_schema.engines WHERE engine='DuckDB'" 2>&1 | head

echo "[mdb] loading TPC-H SF$SF into ENGINE=DuckDB ..."
C -e "DROP DATABASE IF EXISTS tpch; CREATE DATABASE tpch DEFAULT CHARSET utf8mb4;"
for t in $TABLES; do
  # MariaDB's ENGINE=DuckDB REQUIRES a primary key (ERROR 1173 without one), so
  # keep the PK (unlike our engine, which allows PK-less). The PK index build is
  # the memory-heavy step at SF100.
  C tpch -e "CREATE TABLE $t ($(ddl "$t")) ENGINE=DuckDB DEFAULT CHARSET=utf8mb4;" 2>>/tmp/mdb-load.err \
    || { echo "CREATE $t FAILED"; tail -8 /tmp/mdb-load.err; exit 1; }
  C tpch -e "LOAD DATA INFILE '$CLEAN/$t.csv' INTO TABLE $t FIELDS TERMINATED BY '|';" 2>>/tmp/mdb-load.err \
    || { echo "LOAD $t FAILED"; tail -8 /tmp/mdb-load.err; exit 1; }
done
echo "[mdb] lineitem rows=$(C -N -B tpch -e 'SELECT COUNT(*) FROM lineitem' 2>/dev/null)"

printf '\nQ#     MariaDB(s)\n---    ----------\n'
total=0
for n in $(seq 1 22); do
  f=$(printf '%s/q%02d.mysql.sql' "$QDIR" "$n")
  [ -f "$f" ] || f=$(printf '%s/q%02d.duckdb.sql' "$QDIR" "$n")
  sql=$(cat "$f")
  # warmup
  C -N tpch -e "$sql" >/dev/null 2>/tmp/mdb-q.err
  times=()
  for _ in $(seq 1 "$ITERS"); do
    t0=$(date +%s.%N)
    C -N tpch -e "$sql" >/dev/null 2>/dev/null
    rc=$?
    t1=$(date +%s.%N)
    [ $rc -eq 0 ] && times+=("$(awk "BEGIN{print $t1-$t0}")") || times+=("ERR")
  done
  best=$(minv "${times[@]}")
  printf 'Q%-5d %s\n' "$n" "$best"
  case "$best" in ERR) ;; *) total=$(awk "BEGIN{print $total+$best}");; esac
done
printf '%s\n' "------------------------"
printf 'MariaDB 22-q total: %.3f s (min of %d warm iters/query)\n' "$total" "$ITERS"
