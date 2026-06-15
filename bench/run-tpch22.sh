#!/usr/bin/env bash
# =============================================================================
# run-tpch22.sh — full 22-query TPC-H comparison for the IN-TREE DuckDB engine.
# =============================================================================
#
# Compares, per TPC-H query, THREE execution paths on the SAME data:
#
#   InnoDB         standard MySQL row store, no acceleration (the correctness
#                  oracle — every other engine's result is checked against it).
#   engine         a plain `ENGINE=DuckDB` table in the in-tree server. There is
#                  NO `SECONDARY_ENGINE=` / `SECONDARY_LOAD` ceremony: analytical
#                  queries auto-offload into DuckDB's vectorized engine. This is
#                  the whole point of this project vs. the loadable plugin.
#   native DuckDB  the DuckDB CLI on a local .duckdb file built from the same
#                  CSVs — the analytical "upper bound".
#
# It also CHECKS CORRECTNESS: for each query the engine result set is reduced to
# an order-independent md5 checksum and compared against InnoDB's. `match?` shows
# yes/no/—(skipped). Timing alone is meaningless if the answer is wrong.
#
# ---- DIALECT NOTE (important) -----------------------------------------------
# The 22 canonical queries come from DuckDB's tpch extension (`tpch_queries()`),
# so they are DuckDB-dialect SQL. Native DuckDB runs them verbatim. The two
# MySQL legs (InnoDB + engine) get a small, mechanical translation pass
# (`to_mysql_dialect`) covering the constructs that actually differ in the
# official TPC-H text:
#   * `date '1994-01-01' + interval '1' year`  -> DATE_ADD(DATE '..', INTERVAL 1 YEAR)
#     and the standalone `interval '3' month` / `interval '1' day` arithmetic.
#   * `extract(year from x)` is left as-is (MySQL supports EXTRACT(YEAR FROM x)).
#   * `substring(x from a for b)` is left as-is (MySQL supports it).
# Most TPC-H queries are plain SQL-92 and need no change. If a translated query
# still can't parse/run on MySQL, that query is marked SKIPPED for BOTH MySQL
# legs (engine + InnoDB) rather than aborting the whole run — native DuckDB
# still reports a time so the suite stays informative.
#
# ---- PREREQUISITE: the engine server image must exist -----------------------
# This is GROUNDWORK. The in-tree engine server image does NOT exist yet — it is
# produced once the in-tree build and the full TPC-H validation are in place
# (see bench/README.md). Until then this script will refuse to run with a clear
# message. The native-DuckDB image (ducksdb-duckdb:1.5.3) and data generation
# already work, so the data path is exercisable today.
#
# Nothing is installed on the host: server, DuckDB CLI, and data-gen all run in
# docker containers. Cleanup is via an EXIT trap.
#
# Env knobs (defaults in parens):
#   SF(1) ITERS(3) CPUS(6) MEM(8g)
#   IMAGE(ducksdb/mysql-engine:9.7)      <-- in-tree engine server (placeholder)
#   DUCKDB_VERSION(1.5.3) INNODB_POOL(2G) QTIMEOUT(300)
#   ONLY("")  -> run only these query numbers, e.g. ONLY="1 6 14"
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

SF=${SF:-1}
ITERS=${ITERS:-3}
CPUS=${CPUS:-6}
MEM=${MEM:-8g}
IMAGE=${IMAGE:-ducksdb/mysql-engine:9.7}
DUCKDB_VERSION=${DUCKDB_VERSION:-1.5.3}
DUCKDB_IMAGE="ducksdb-duckdb:$DUCKDB_VERSION"
INNODB_POOL=${INNODB_POOL:-2G}
QTIMEOUT=${QTIMEOUT:-300}
ONLY=${ONLY:-}

DATA="$HERE/data-sf$SF"; mkdir -p "$DATA"
QDIR="$DATA/queries"      # extracted/translated query text (cached)
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$HERE/results/tpch22-sf${SF}-$TS"; mkdir -p "$OUT"
SUMMARY="$OUT/SUMMARY.txt"

DB="t22-db-$$"; DK="t22-dk-$$"; NET="t22-net-$$"
cleanup(){
  docker rm -f "$DB" "$DK" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log(){ echo "[t22] $*" | tee -a "$SUMMARY" >&2; }
minv(){ printf '%s\n' "$@" | sort -n | head -1; }
elapsed(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }

# -----------------------------------------------------------------------------
# 0. Preflight: the engine server image must exist.
# -----------------------------------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  cat >&2 <<EOF
[t22] ERROR: in-tree engine server image '$IMAGE' not found.

  This harness is GROUNDWORK and needs the in-tree DuckDB-engine server image,
  which is produced once the in-tree build and TPC-H validation are in place.

  Build that image first (see bench/README.md), or point this script at it:
      IMAGE=<your-engine-image> bench/run-tpch22.sh

  To smoke-test only the data-generation + native-DuckDB path before the
  engine exists, set a throwaway IMAGE and expect the MySQL legs to no-op.
EOF
  exit 2
fi

if [ "$(uname -m)" != "x86_64" ]; then
  log "WARN: host arch $(uname -m) != x86_64; the native-DuckDB image pulls a linux-amd64 CLI."
fi

log "profile: SF=$SF ITERS=$ITERS  image=$IMAGE  duckdb=$DUCKDB_VERSION"
log "resources: CPUS=$CPUS MEM=$MEM innodb_pool=$INNODB_POOL  qtimeout=${QTIMEOUT}s"
docker network create "$NET" >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 1. TPC-H schema. Standard 8 tables. MySQL DDL (typed) + DuckDB DDL.
#    Money -> DECIMAL(15,2), dates -> DATE, ids -> INT/BIGINT, strings -> CHAR/VARCHAR.
#    Order of columns matches DuckDB's dbgen CSV export exactly (see COPY below).
# -----------------------------------------------------------------------------
# tables in load order (FK-friendly: parents before children)
TABLES="region nation supplier customer part partsupp orders lineitem"

ddl_mysql(){ # $1=table -> column list + PK for MySQL (engine-agnostic body)
  case "$1" in
    region)   echo "r_regionkey INT, r_name CHAR(25), r_comment VARCHAR(152), PRIMARY KEY (r_regionkey)";;
    nation)   echo "n_nationkey INT, n_name CHAR(25), n_regionkey INT, n_comment VARCHAR(152), PRIMARY KEY (n_nationkey)";;
    supplier) echo "s_suppkey INT, s_name CHAR(25), s_address VARCHAR(40), s_nationkey INT, s_phone CHAR(15), s_acctbal DECIMAL(15,2), s_comment VARCHAR(101), PRIMARY KEY (s_suppkey)";;
    customer) echo "c_custkey INT, c_name VARCHAR(25), c_address VARCHAR(40), c_nationkey INT, c_phone CHAR(15), c_acctbal DECIMAL(15,2), c_mktsegment CHAR(10), c_comment VARCHAR(117), PRIMARY KEY (c_custkey)";;
    part)     echo "p_partkey INT, p_name VARCHAR(55), p_mfgr CHAR(25), p_brand CHAR(10), p_type VARCHAR(25), p_size INT, p_container CHAR(10), p_retailprice DECIMAL(15,2), p_comment VARCHAR(23), PRIMARY KEY (p_partkey)";;
    partsupp) echo "ps_partkey INT, ps_suppkey INT, ps_availqty INT, ps_supplycost DECIMAL(15,2), ps_comment VARCHAR(199), PRIMARY KEY (ps_partkey, ps_suppkey)";;
    orders)   echo "o_orderkey BIGINT, o_custkey INT, o_orderstatus CHAR(1), o_totalprice DECIMAL(15,2), o_orderdate DATE, o_orderpriority CHAR(15), o_clerk CHAR(15), o_shippriority INT, o_comment VARCHAR(79), PRIMARY KEY (o_orderkey)";;
    lineitem) echo "l_orderkey BIGINT, l_partkey INT, l_suppkey INT, l_linenumber INT, l_quantity DECIMAL(15,2), l_extendedprice DECIMAL(15,2), l_discount DECIMAL(15,2), l_tax DECIMAL(15,2), l_returnflag CHAR(1), l_linestatus CHAR(1), l_shipdate DATE, l_commitdate DATE, l_receiptdate DATE, l_shipinstruct CHAR(25), l_shipmode CHAR(10), l_comment VARCHAR(44), PRIMARY KEY (l_orderkey, l_linenumber)";;
  esac
}

ddl_duckdb(){ # $1=table -> column list for native DuckDB (no PK needed)
  case "$1" in
    region)   echo "r_regionkey INTEGER, r_name VARCHAR, r_comment VARCHAR";;
    nation)   echo "n_nationkey INTEGER, n_name VARCHAR, n_regionkey INTEGER, n_comment VARCHAR";;
    supplier) echo "s_suppkey INTEGER, s_name VARCHAR, s_address VARCHAR, s_nationkey INTEGER, s_phone VARCHAR, s_acctbal DECIMAL(15,2), s_comment VARCHAR";;
    customer) echo "c_custkey INTEGER, c_name VARCHAR, c_address VARCHAR, c_nationkey INTEGER, c_phone VARCHAR, c_acctbal DECIMAL(15,2), c_mktsegment VARCHAR, c_comment VARCHAR";;
    part)     echo "p_partkey INTEGER, p_name VARCHAR, p_mfgr VARCHAR, p_brand VARCHAR, p_type VARCHAR, p_size INTEGER, p_container VARCHAR, p_retailprice DECIMAL(15,2), p_comment VARCHAR";;
    partsupp) echo "ps_partkey INTEGER, ps_suppkey INTEGER, ps_availqty INTEGER, ps_supplycost DECIMAL(15,2), ps_comment VARCHAR";;
    orders)   echo "o_orderkey BIGINT, o_custkey INTEGER, o_orderstatus VARCHAR, o_totalprice DECIMAL(15,2), o_orderdate DATE, o_orderpriority VARCHAR, o_clerk VARCHAR, o_shippriority INTEGER, o_comment VARCHAR";;
    lineitem) echo "l_orderkey BIGINT, l_partkey INTEGER, l_suppkey INTEGER, l_linenumber INTEGER, l_quantity DECIMAL(15,2), l_extendedprice DECIMAL(15,2), l_discount DECIMAL(15,2), l_tax DECIMAL(15,2), l_returnflag VARCHAR, l_linestatus VARCHAR, l_shipdate DATE, l_commitdate DATE, l_receiptdate DATE, l_shipinstruct VARCHAR, l_shipmode VARCHAR, l_comment VARCHAR";;
  esac
}

# -----------------------------------------------------------------------------
# 2. Native DuckDB: generate TPC-H, export one CSV per table, also run the
#    native leg. CSVs are cached on SF.
# -----------------------------------------------------------------------------
if ! docker image inspect "$DUCKDB_IMAGE" >/dev/null 2>&1; then
  log "ERROR: native DuckDB image '$DUCKDB_IMAGE' not found."
  log "       build it from the sibling plugin repo's bench/analytical/Dockerfile.duckdb, e.g.:"
  log "       docker build --build-arg DUCKDB_VERSION=$DUCKDB_VERSION -t $DUCKDB_IMAGE -f Dockerfile.duckdb ."
  exit 3
fi

docker run -d --name "$DK" --network "$NET" --cpus "$CPUS" --memory "$MEM" \
  -v "$DATA":/data:rw "$DUCKDB_IMAGE" >/dev/null

if [ ! -f "$DATA/lineitem.csv" ]; then
  log "generating TPC-H SF=$SF + exporting per-table CSVs (slow part) ..."
  COPYS=""
  for t in $TABLES; do
    COPYS="$COPYS COPY $t TO '/data/$t.csv' (FORMAT CSV, DELIMITER '|', HEADER false, DATEFORMAT '%Y-%m-%d');"
  done
  docker exec "$DK" duckdb /data/tpch.db -c "
    INSTALL tpch; LOAD tpch; CALL dbgen(sf=$SF); $COPYS" 2>&1 | tail -3 >&2
else
  log "reusing cached CSVs in $DATA"
fi
log "native lineitem rows: $(docker exec "$DK" duckdb /data/tpch.db -noheader -list -c 'SELECT count(*) FROM lineitem' 2>/dev/null | tail -1)"

# -----------------------------------------------------------------------------
# 3. Extract the 22 canonical queries from DuckDB's tpch extension once.
#    tpch_queries() returns (query_nr, query). One file per query: qNN.duckdb.sql
# -----------------------------------------------------------------------------
if [ ! -f "$QDIR/q01.duckdb.sql" ]; then
  mkdir -p "$QDIR"
  log "extracting 22 canonical queries from tpch_queries() ..."
  for n in $(seq 1 22); do
    docker exec "$DK" duckdb -noheader -list -c \
      "INSTALL tpch; LOAD tpch; SELECT query FROM tpch_queries() WHERE query_nr=$n;" \
      2>/dev/null > "$QDIR/$(printf 'q%02d' "$n").duckdb.sql"
  done
fi

# -----------------------------------------------------------------------------
# 3b. DuckDB -> MySQL dialect translation for the two MySQL legs.
#     Mechanical, line-oriented. Covers the constructs the official queries use.
#     Anything left that MySQL can't parse -> the query is marked SKIPPED later.
# -----------------------------------------------------------------------------
to_mysql_dialect(){ # stdin: duckdb SQL -> stdout: best-effort MySQL SQL
  sed -E "
    # date '..' + interval 'N' unit   ->  DATE_ADD(date '..', INTERVAL N UNIT)
    s/(date '[0-9-]+')[[:space:]]*\+[[:space:]]*interval '([0-9]+)' (year|month|day)/DATE_ADD(\1, INTERVAL \2 \U\3\E)/Ig;
    s/(date '[0-9-]+')[[:space:]]*-[[:space:]]*interval '([0-9]+)' (year|month|day)/DATE_SUB(\1, INTERVAL \2 \U\3\E)/Ig;
    # bare 'interval N unit' in additive position against a column expr (Q1: l_shipdate <= date '..' - interval '..' day handled above)
    s/interval '([0-9]+)' (year|month|day)/INTERVAL \1 \U\2\E/Ig;
    # DuckDB/Postgres-ism sometimes present: 'x'::type cast -> CAST(x AS type) (rare in TPC-H text but cheap to guard)
    s/'([^']*)'::date/DATE '\1'/Ig;
  "
}

# -----------------------------------------------------------------------------
# 4. Boot the in-tree engine server (hosts BOTH InnoDB and ENGINE=DuckDB tables).
# -----------------------------------------------------------------------------
log "starting engine server ($IMAGE) ..."
docker run -d --name "$DB" --network "$NET" --cpus "$CPUS" --memory "$MEM" \
  -v "$DATA":/data:ro "$IMAGE" \
  mysqld --local-infile=1 --innodb-buffer-pool-size="$INNODB_POOL" \
         --net-read-timeout=600 --net-write-timeout=600 >/dev/null
i=0; until docker exec "$DB" mysql -uroot -N -B -e "SELECT 1" 2>/dev/null | grep -q '^1$'; do
  i=$((i+1)); [ "$i" -gt 90 ] && { log "ERROR: server never became ready"; exit 1; }; sleep 2; done

mysql_load(){ # $1=database $2=engine — create the 8 tables and LOAD the CSVs
  local db="$1" eng="$2" t
  docker exec "$DB" mysql -uroot -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db;" 2>>"$OUT/load.err"
  for t in $TABLES; do
    docker exec "$DB" mysql -uroot --local-infile=1 "$db" -e "
      CREATE TABLE $t ($(ddl_mysql "$t")) ENGINE=$eng;
      LOAD DATA LOCAL INFILE '/data/$t.csv' INTO TABLE $t
        FIELDS TERMINATED BY '|' LINES TERMINATED BY '\n';" 2>>"$OUT/load.err"
  done
}

log "loading InnoDB (db: tpch_innodb) ..."
mysql_load tpch_innodb InnoDB
log "loading ENGINE=DuckDB (db: tpch_engine) ..."
mysql_load tpch_engine DuckDB
log "rows: innodb.lineitem=$(docker exec "$DB" mysql -uroot -N -B tpch_innodb -e 'SELECT COUNT(*) FROM lineitem' 2>/dev/null)  engine.lineitem=$(docker exec "$DB" mysql -uroot -N -B tpch_engine -e 'SELECT COUNT(*) FROM lineitem' 2>/dev/null)"

# -----------------------------------------------------------------------------
# 5. Native DuckDB: load CSVs into a local .duckdb file for the native leg.
# -----------------------------------------------------------------------------
log "loading DuckDB(native) ..."
docker exec "$DK" rm -f /data/native.duckdb 2>/dev/null || true
{
  for t in $TABLES; do
    echo "CREATE TABLE $t ($(ddl_duckdb "$t"));"
    echo "COPY $t FROM '/data/$t.csv' (FORMAT CSV, DELIMITER '|', DATEFORMAT '%Y-%m-%d');"
  done
} | docker exec -i "$DK" duckdb /data/native.duckdb >/dev/null 2>>"$OUT/load.err"

# -----------------------------------------------------------------------------
# 6. Timing + correctness helpers.
# -----------------------------------------------------------------------------
# Offload counter delta — same global status var the plugin exposes; the in-tree
# engine is assumed to expose it too. A positive delta == the query ran in DuckDB.
ocount(){ docker exec "$DB" mysql -uroot -N -B -e \
  "SHOW GLOBAL STATUS LIKE 'Ducksdb_secondary_offload_count'" 2>/dev/null | awk '{print $2}'; }

# Order-independent checksum of a result set: sort rows, md5. Tab-separated,
# NULLs normalized, so InnoDB vs engine compare cleanly regardless of row order.
checksum_mysql(){ # $1=db $2=sql -> md5 (or empty on failure)
  docker exec "$DB" mysql -uroot -N "$1" -e "$2" 2>/dev/null \
    | LC_ALL=C sort | md5sum | awk '{print $1}'
}

# Wall-clock min over ITERS for a MySQL leg (1 warmup not counted).
time_mysql(){ # $1=db $2=sql -> min seconds, or empty on error/timeout
  local db="$1" sql="$2" t0 t1 times=() rc
  timeout "$QTIMEOUT" docker exec "$DB" mysql -uroot -N "$db" -e "$sql" >/dev/null 2>>"$OUT/run.err" || return 1
  for _ in $(seq 1 "$ITERS"); do
    t0=$(date +%s.%N)
    timeout "$QTIMEOUT" docker exec "$DB" mysql -uroot -N "$db" -e "$sql" >/dev/null 2>>"$OUT/run.err"
    rc=$?; t1=$(date +%s.%N)
    [ "$rc" -ne 0 ] && return 1
    times+=("$(elapsed "$t0" "$t1")")
  done
  minv "${times[@]}"
}

# Native DuckDB leg.
time_duckdb(){ # $1=sql -> min seconds
  local sql="$1" t0 t1 times=()
  docker exec "$DK" duckdb /data/native.duckdb -c "$sql" >/dev/null 2>>"$OUT/run.err"
  for _ in $(seq 1 "$ITERS"); do
    t0=$(date +%s.%N)
    timeout "$QTIMEOUT" docker exec "$DK" duckdb /data/native.duckdb -c "$sql" >/dev/null 2>>"$OUT/run.err"
    t1=$(date +%s.%N); times+=("$(elapsed "$t0" "$t1")")
  done
  minv "${times[@]}"
}

# -----------------------------------------------------------------------------
# 7. Run the suite.
# -----------------------------------------------------------------------------
QNUMS=$(seq 1 22)
[ -n "$ONLY" ] && QNUMS="$ONLY"

printf '\n%-5s %10s %10s %12s %-10s %-7s\n' \
  "Q#" "InnoDB(s)" "engine(s)" "native(s)" "offloaded?" "match?" | tee -a "$SUMMARY"
printf '%-5s %10s %10s %12s %-10s %-7s\n' \
  "---" "---------" "---------" "----------" "----------" "------" | tee -a "$SUMMARY"

n_ok=0; n_skip=0; n_mismatch=0
for n in $QNUMS; do
  qf="$QDIR/$(printf 'q%02d' "$n").duckdb.sql"
  [ -s "$qf" ] || { printf '%-5s %10s %10s %12s %-10s %-7s\n' "Q$n" "—" "—" "—" "—" "noquery" | tee -a "$SUMMARY"; n_skip=$((n_skip+1)); continue; }

  duck_sql=$(cat "$qf")
  mysql_sql=$(to_mysql_dialect < "$qf")
  # persist the translated text for auditing / manual fixups
  printf '%s' "$mysql_sql" > "$QDIR/$(printf 'q%02d' "$n").mysql.sql"

  # --- native DuckDB (always attempted; verbatim dialect) ---
  nat=$(time_duckdb "$duck_sql"); nat=${nat:-ERR}

  # --- InnoDB (correctness oracle) ---
  ii=$(time_mysql tpch_innodb "$mysql_sql")
  if [ -z "$ii" ]; then
    # MySQL couldn't run the translated query -> skip BOTH MySQL legs, keep native.
    printf '%-5s %10s %10s %12s %-10s %-7s\n' "Q$n" "SKIP" "SKIP" "$nat" "—" "—" | tee -a "$SUMMARY"
    n_skip=$((n_skip+1)); continue
  fi

  # --- engine (auto-offload; bracket with offload counter) ---
  c0=$(ocount)
  ee=$(time_mysql tpch_engine "$mysql_sql")
  c1=$(ocount)
  if [ -z "$ee" ]; then
    printf '%-5s %10s %10s %12s %-10s %-7s\n' "Q$n" "$ii" "ERR" "$nat" "—" "—" | tee -a "$SUMMARY"
    n_skip=$((n_skip+1)); continue
  fi
  off=no; [ -n "$c0" ] && [ -n "$c1" ] && [ "$((c1 - c0))" -gt 0 ] && off=yes

  # --- correctness: engine result vs InnoDB result ---
  cs_i=$(checksum_mysql tpch_innodb "$mysql_sql")
  cs_e=$(checksum_mysql tpch_engine "$mysql_sql")
  if [ -n "$cs_i" ] && [ "$cs_i" = "$cs_e" ]; then
    match=yes; n_ok=$((n_ok+1))
  else
    match=NO; n_mismatch=$((n_mismatch+1))
    echo "Q$n MISMATCH innodb=$cs_i engine=$cs_e" >> "$OUT/mismatch.log"
  fi

  printf '%-5s %10s %10s %12s %-10s %-7s\n' "Q$n" "$ii" "$ee" "$nat" "$off" "$match" | tee -a "$SUMMARY"
done

# -----------------------------------------------------------------------------
# 8. Footer.
# -----------------------------------------------------------------------------
{
  echo
  echo "[t22] passed(match)=$n_ok  mismatch=$n_mismatch  skipped=$n_skip   of 22"
  echo "[t22] times are min wall-clock over $ITERS iters (1 warmup, excl.)."
  echo "[t22] 'offloaded?=yes' = Ducksdb_secondary_offload_count rose => query ran in DuckDB."
  echo "[t22] 'match?' compares an order-independent md5 of the engine vs InnoDB result set."
  echo "[t22] SKIP = the DuckDB-dialect query did not run on MySQL after translation"
  echo "      (see $QDIR/qNN.mysql.sql to hand-fix); native DuckDB still timed it."
  echo "[t22] artifacts: $OUT   (SUMMARY.txt, load.err, run.err, mismatch.log)"
} | tee -a "$SUMMARY"

[ "$n_mismatch" -eq 0 ] || exit 1
exit 0
