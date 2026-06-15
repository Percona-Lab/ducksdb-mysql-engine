#!/usr/bin/env bash
# InnoDB vs our in-tree DuckDB engine (automatic whole-query pushdown),
# server-side timings. Runs our freshly built mysqld directly inside the
# ducksdb-builder container (no image needed). Same data, same SQL, two engines:
#   InnoDB                          standard MySQL, no pushdown
#   DuckDB engine (pushdown)        plain ENGINE=DuckDB, queries auto-run in DuckDB
#
# Usage (from the project root, on the host):
#   docker run --rm -v "$PWD":/work -e REPO=/work ducksdb-builder:latest \
#       bash -lc 'cd /work && bash bench/run-engine-bench.sh'
set -uo pipefail
REPO=${REPO:-/work}
ITERS=${ITERS:-5}
BIN="$REPO/vendor/mysql-server/build/runtime_output_directory"
MYSQLD="$BIN/mysqld"
MYSQL="$BIN/mysql"
CSV="$REPO/bench/data/facts.csv"
DATADIR=/tmp/ebench-data
SOCK=/tmp/ebench.sock

[ -x "$MYSQLD" ] || { echo "ERROR: mysqld not built ($MYSQLD)"; exit 1; }
[ -f "$CSV" ]    || { echo "ERROR: missing $CSV"; exit 1; }

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

echo "[eb] initializing datadir"
rm -rf "$DATADIR"; mkdir -p "$DATADIR"
"$MYSQLD" --no-defaults --initialize-insecure --datadir="$DATADIR" --user=root >/tmp/eb_init.log 2>&1 || { tail -20 /tmp/eb_init.log; exit 1; }

echo "[eb] starting mysqld"
"$MYSQLD" --no-defaults --datadir="$DATADIR" --user=root --socket="$SOCK" \
    --skip-networking --secure-file-priv="" --local-infile=1 >/tmp/eb_run.log 2>&1 &
MPID=$!
trap 'kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null; rm -rf "$DATADIR"' EXIT
for i in $(seq 1 60); do "$MYSQL" --no-defaults -S "$SOCK" -uroot -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -S "$SOCK" -uroot -e "SELECT 1" >/dev/null 2>&1 || { echo "server not up"; tail -30 /tmp/eb_run.log; exit 1; }
q(){ "$MYSQL" --no-defaults -S "$SOCK" -uroot --local-infile=1 "$@"; }

echo "[eb] loading InnoDB + DuckDB tables (1M rows) ..."
for pair in "wi:InnoDB" "wd:DuckDB"; do
  db="${pair%%:*}"; eng="${pair##*:}"
  q -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db; USE $db;
        CREATE TABLE facts ($SCHEMA) ENGINE=$eng;
        LOAD DATA LOCAL INFILE '$CSV' INTO TABLE facts FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n';
        CREATE TABLE region_dim (region INT PRIMARY KEY, w DECIMAL(5,2)) ENGINE=$eng;
        INSERT INTO region_dim VALUES $DIM;" 2>>/tmp/eb_load.err
done
echo "[eb] rows: innodb=$(q -N -B wi -e 'SELECT COUNT(*) FROM facts')  duckdb=$(q -N -B wd -e 'SELECT COUNT(*) FROM facts')"

pcount(){ q -N -B -e "SHOW GLOBAL STATUS LIKE 'Ducksdb_pushdown_count'" | awk '{print $2}'; }
myprof(){ local db="$1" sql="$2" t=() r; for _ in $(seq 1 "$ITERS"); do
    r=$(q -N -B "$db" -e "SET profiling=1; $sql; SHOW PROFILES;" 2>/dev/null | grep -iE "FROM facts" | awk '{print $2}' | sort -n | head -1); t+=("${r:-9999}"); done
  minv "${t[@]}"; }

printf '\n%-24s %12s %16s %10s\n' "query (server-side s)" "InnoDB" "DuckDB engine" "pushdown?"
printf '%-24s %12s %16s %10s\n' "------------------------" "------" "-------------" "---------"
for e in "${QUERIES[@]}"; do
  name="${e%%|*}"; sql="${e#*|}"
  ii=$(myprof wi "$sql")
  c0=$(pcount); ee=$(myprof wd "$sql"); c1=$(pcount)
  pd=$([ "$((c1-c0))" -gt 0 ] && echo yes || echo no)
  printf '%-24s %12s %16s %10s\n' "$name" "${ii:-?}" "${ee:-?}" "$pd"
done
echo; echo "[eb] server-side via SHOW PROFILES, min of $ITERS. 'pushdown?=yes' = ran in DuckDB."
if [ -n "${DUCKSDB_PD_TIMING:-}" ]; then
  echo "[eb] pushdown phase timings (ms) — last samples per query shape:"
  grep '\[pd' /tmp/eb_run.log 2>/dev/null | tail -18 || echo "  (none captured)"
fi
