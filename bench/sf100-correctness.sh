#!/usr/bin/env bash
# SF100 correctness oracle: InnoDB is infeasible at 600M rows, so verify the
# ENGINE=DuckDB results against NATIVE DuckDB on the same generated data. Reuses
# the CSVs + native.duckdb produced by bench/run-tpch22.sh (run that first).
#
# Numbers are normalised to 4 decimals before comparison because MySQL's DECIMAL
# display and DuckDB's DOUBLE display differ on division/AVG (same value, e.g.
# 348406.054286 vs 348406.0542857143) — that is a formatting difference, not a
# wrong result. A real value difference > 1e-4 still shows as MISMATCH.
#
#   bench/sf100-correctness.sh        # SF defaults to 100
set -uo pipefail
export LC_ALL=C   # decimal point '.', not the host locale's ',' (printf/sort -n)
SF=${SF:-100}
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd)
DATA="$REPO/bench/data-sf$SF"; QDIR="$DATA/queries"
IMG=${IMAGE:-ducksdb/mysql:9.7-duckdb-v0.2.0}
DK=ducksdb-duckdb:${DUCKDB_VERSION:-1.5.3}
EC=ddc-eng; DC=ddc-duck
TABLES="region nation supplier customer part partsupp orders lineitem"

[ -f "$DATA/tpch.db" ]      || { echo "ERROR: $DATA/tpch.db missing — run bench/run-tpch22.sh SF=$SF first"; exit 1; }
[ -f "$DATA/lineitem.csv" ] || { echo "ERROR: $DATA/lineitem.csv missing — re-export from tpch.db first"; exit 1; }

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

cleanup(){ docker rm -f "$EC" "$DC" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup

echo "[cc] starting engine ($IMG) with server-side INFILE fast-load, DuckDB memory_limit=${DUCK_MEM:-28GB} ..."
# Cap the EMBEDDED DuckDB below the container memory so it spills to disk instead
# of letting the kernel OOM-kill mysqld (the ~12GB headroom covers mysqld + the
# result-staging overhead). Native standalone DuckDB needs no such cap.
docker run -d --name "$EC" --cpus "${CPUS:-20}" --memory "${MEM:-40g}" \
  -e DUCKSDB_MEMORY_LIMIT="${DUCK_MEM:-28GB}" -e DUCKSDB_TEMP_DIR=/var/lib/mysql \
  -v "$DATA":/data:ro "$IMG" \
  mysqld --local-infile=1 --secure-file-priv=/data --skip-log-bin \
         --net-read-timeout=600 --net-write-timeout=600 >/dev/null
i=0; until docker exec "$EC" mysql -uroot -N -B -e "SELECT 1" 2>/dev/null | grep -q '^1$'; do
  i=$((i+1)); [ "$i" -gt 120 ] && { echo "engine never ready"; docker logs "$EC" | tail; exit 1; }; sleep 2; done

echo "[cc] loading ENGINE=DuckDB via COPY fast-path (server-side INFILE) ..."
docker exec "$EC" mysql -uroot -e "DROP DATABASE IF EXISTS tpch; CREATE DATABASE tpch;"
for t in $TABLES; do
  # Drop the PRIMARY KEY for the load: at SF100 DuckDB's PK (ART) index build on
  # 600M rows blows the memory_limit. The PK is irrelevant for analytical scans
  # and native DuckDB has none either, so this keeps the comparison apples-to-apples.
  cols=$(ddl "$t" | sed -E 's/, *PRIMARY KEY *\([^)]*\)//')
  docker exec "$EC" mysql -uroot tpch -e "
    CREATE TABLE $t ($cols) ENGINE=DuckDB;
    LOAD DATA INFILE '/data/$t.csv' INTO TABLE $t FIELDS TERMINATED BY '|' LINES TERMINATED BY '\n';" 2>/tmp/cc-load.err \
    || { echo "LOAD $t FAILED"; tail -5 /tmp/cc-load.err; exit 1; }
done
echo "[cc] engine.lineitem rows=$(docker exec "$EC" mysql -uroot -N -B tpch -e 'SELECT COUNT(*) FROM lineitem' 2>/dev/null)"

# round every plain decimal field to 4dp (pipe-delimited); leaves ints/text alone
norm(){ awk 'BEGIN{FS=OFS="|"}{for(i=1;i<=NF;i++) if($i ~ /^-?[0-9]+\.[0-9]+$/) $i=sprintf("%.4f",$i); print}'; }
minv(){ printf '%s\n' "$@" | sort -n | head -1; }
ITERS=${ITERS:-2}
OUT=/tmp/cc-sf$SF; rm -rf "$OUT"; mkdir -p "$OUT"
# Engine-phase order: Q15 (the CTE) is run LAST. At SF100 it is double-inlined
# (referenced twice) and can OOM-kill the engine container; running it last means
# a crash there doesn't poison the other 21, and reveals whether it's the only
# query that doesn't fit. Override with SEQ=... if needed.
SEQ=${SEQ:-"1 2 3 4 5 6 7 8 9 10 11 12 13 14 16 17 18 19 20 21 22 15"}
NATDB=/data/tpch.db   # the complete gen DB (native.duckdb from the failed run is incomplete)

# === PHASE 1: engine — run all 22, capture normalised result + min timing, then
# tear the engine down BEFORE starting native (the two DuckDB instances must NOT
# be resident together — at SF100 each holds ~20-30GB and concurrently they
# global-OOM a 62GB box). ===
echo "[cc] PHASE 1: engine queries (Q15 last) ..."
for n in $SEQ; do
  ef=$(printf '%s/q%02d.mysql.sql' "$QDIR" "$n"); [ -f "$ef" ] || ef=$(printf '%s/q%02d.duckdb.sql' "$QDIR" "$n")
  esql=$(cat "$ef")
  timeout 1800 docker exec "$EC" mysql -uroot -N tpch -e "$esql" 2>/dev/null | sed 's/\t/|/g' | norm | sort > "$OUT/eng-$n.txt"
  et=()
  for _ in $(seq 1 "$ITERS"); do
    t0=$(date +%s.%N); timeout 1800 docker exec "$EC" mysql -uroot -N tpch -e "$esql" >/dev/null 2>&1; t1=$(date +%s.%N)
    et+=("$(awk "BEGIN{print $t1-$t0}")")
  done
  minv "${et[@]}" > "$OUT/eng-t-$n"
  printf '  Q%-2d engine %ss  rows=%s\n' "$n" "$(cat "$OUT/eng-t-$n")" "$(grep -c . "$OUT/eng-$n.txt")"
done
docker rm -f "$EC" >/dev/null 2>&1

# === PHASE 2: native DuckDB (engine is gone, full box available) ===
echo "[cc] PHASE 2: native DuckDB queries ..."
docker run -d --name "$DC" --memory "${NAT_MEM:-40g}" -v "$DATA":/data:rw "$DK" >/dev/null; sleep 2
for n in $(seq 1 22); do
  nsql=$(cat "$(printf '%s/q%02d.duckdb.sql' "$QDIR" "$n")")
  timeout 1800 docker exec "$DC" duckdb "$NATDB" -noheader -list -c "$nsql" 2>/dev/null | norm | sort > "$OUT/nat-$n.txt"
  nt=()
  for _ in $(seq 1 "$ITERS"); do
    t0=$(date +%s.%N); timeout 1800 docker exec "$DC" duckdb "$NATDB" -noheader -list -c "$nsql" >/dev/null 2>&1; t1=$(date +%s.%N)
    nt+=("$(awk "BEGIN{print $t1-$t0}")")
  done
  minv "${nt[@]}" > "$OUT/nat-t-$n"
  printf '  Q%-2d native %ss  rows=%s\n' "$n" "$(cat "$OUT/nat-t-$n")" "$(grep -c . "$OUT/nat-$n.txt")"
done
docker rm -f "$DC" >/dev/null 2>&1

# === PHASE 3: compare offline ===
printf '\nQ#    eng(s)   nat(s)  eng/nat  eng_rows nat_rows  result\n'
printf -- '---  ------- --------  -------  -------- --------  ------\n'
pass=0; fail=0; etot=0; ntot=0
for n in $(seq 1 22); do
  ebest=$(cat "$OUT/eng-t-$n"); nbest=$(cat "$OUT/nat-t-$n")
  er=$(grep -c . "$OUT/eng-$n.txt"); nr=$(grep -c . "$OUT/nat-$n.txt")
  em=$(md5sum < "$OUT/eng-$n.txt" | awk '{print $1}'); nm=$(md5sum < "$OUT/nat-$n.txt" | awk '{print $1}')
  if [ "$em" = "$nm" ]; then res=MATCH; pass=$((pass+1)); else res=MISMATCH; fail=$((fail+1)); fi
  ratio=$(awk "BEGIN{if($nbest>0)printf \"%.2fx\",$ebest/$nbest; else print \"-\"}")
  printf 'Q%-3d %7.3f %8.3f  %7s  %8s %8s  %s\n' "$n" "$ebest" "$nbest" "$ratio" "$er" "$nr" "$res"
  etot=$(awk "BEGIN{print $etot+$ebest}"); ntot=$(awk "BEGIN{print $ntot+$nbest}")
done
printf -- '---\n'
printf 'TOT  %7.3f %8.3f  %7s\n' "$etot" "$ntot" "$(awk "BEGIN{printf \"%.2fx\",$etot/$ntot}")"
printf '\n[cc] correctness: MATCH=%d  MISMATCH=%d  of 22 (engine vs native DuckDB, numbers normalised to 4dp)\n' "$pass" "$fail"
printf '[cc] result sets saved under %s for diffing mismatches.\n' "$OUT"
printf '[cc] timings: min wall-clock over %d iters (1 warmup, excl.); engine via docker-exec mysql, native via docker-exec duckdb.\n' "$ITERS"
