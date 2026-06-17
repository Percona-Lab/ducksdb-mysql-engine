#!/usr/bin/env bash
# Phase-3 pushdown validation: load TPC-H SF1 into ENGINE=DuckDB (schema `duck`)
# and InnoDB (schema `inno`), run the given queries on both, md5-compare the
# (order-independent) result sets, and report pushdown counts + [pd-*] diag.
# Runs INSIDE ducksdb-builder with the repo mounted at /work.
#   docker run --rm -v "$PWD":/work -e REPO=/work \
#       -e QUERIES="4 18 20" ducksdb-builder:latest bash -lc '/work/... ' (see caller)
set -uo pipefail

REPO=${REPO:-/work}
MYSQLD="$REPO/vendor/mysql-server/build/runtime_output_directory/mysqld"
MYSQL="$REPO/vendor/mysql-server/build/runtime_output_directory/mysql"
DATA="$REPO/bench/data-sf1"
QDIR="$DATA/queries"
QUERIES=${QUERIES:-"4 18 20"}
DD=/tmp/pdvd-data
SOCK=/tmp/pdvd.sock

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

# The TPC-H CSVs quote some string fields ("Clerk#..."). DuckDB's load keeps the
# quotes; InnoDB's OPTIONALLY ENCLOSED strips them — divergent data. And loading
# DuckDB WITH enclosing hits a row-path appender crash. So strip the quotes once
# up front and load BOTH engines from the cleaned copies (no enclosing) → both
# store identical unquoted values. TPC-H text never contains a literal '"'.
CLEAN=/tmp/pdvd-clean
rm -rf "$CLEAN"; mkdir -p "$CLEAN"
for t in region nation supplier customer part partsupp orders lineitem; do
  tr -d '"' < "$DATA/$t.csv" > "$CLEAN/$t.csv"
done
DATA="$CLEAN"

rm -rf "$DD"; mkdir -p "$DD"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --datadir="$DD" \
  --secure-file-priv="" >/tmp/pdvd-init.log 2>&1 || { echo "INIT FAILED"; tail -20 /tmp/pdvd-init.log; exit 1; }

export DUCKSDB_PD_TIMING=1
"$MYSQLD" --no-defaults --user=root --datadir="$DD" --socket="$SOCK" --skip-networking \
  --secure-file-priv="" --local-infile=1 --disable-log-bin \
  >/tmp/pdvd-server.log 2>/tmp/pdvd-server.err &
SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null' EXIT

for i in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 1; done
[ -S "$SOCK" ] || { echo "SERVER START FAILED"; tail -30 /tmp/pdvd-server.err; exit 1; }

q(){ "$MYSQL" --no-defaults -uroot --socket="$SOCK" --local-infile=1 "$@"; }

echo "[load] creating schemas + tables + loading SF1 ..."
q -e "CREATE DATABASE duck; CREATE DATABASE inno;"
for eng in DuckDB InnoDB; do
  sch=duck; [ "$eng" = InnoDB ] && sch=inno
  for t in $TABLES; do
    q -e "CREATE TABLE $sch.$t ($(ddl "$t")) ENGINE=$eng;" 2>>/tmp/pdvd-load.err \
      || { echo "CREATE $sch.$t FAILED"; tail -5 /tmp/pdvd-load.err; exit 1; }
    # DuckDB: load WITHOUT enclosing so the native CSV fast-path runs (it auto-
    # strips the "..." quotes the CSV uses on some string fields). InnoDB has no
    # such fast-path, so use OPTIONALLY ENCLOSED BY '"' to strip the same quotes.
    # Both engines therefore store identical unquoted values (md5 comparable).
    encl=""; [ "$eng" = InnoDB ] && encl="OPTIONALLY ENCLOSED BY '\"'"
    q -e "LOAD DATA INFILE '$DATA/$t.csv' INTO TABLE $sch.$t FIELDS TERMINATED BY '|' $encl;" 2>>/tmp/pdvd-load.err \
      || { echo "LOAD $sch.$t FAILED"; tail -5 /tmp/pdvd-load.err; echo "--- server err ---"; tail -40 /tmp/pdvd-server.err; exit 1; }
  done
done
echo "[load] done. row counts:"
for t in $TABLES; do printf '  %-10s duck=%s inno=%s\n' "$t" \
  "$(q -N -e "SELECT COUNT(*) FROM duck.$t")" "$(q -N -e "SELECT COUNT(*) FROM inno.$t")"; done

pc(){ q -N -e "SHOW STATUS LIKE 'Ducksdb_pushdown_count'" | awk '{print $2}'; }

for n in $QUERIES; do
  f=$(printf '%s/q%02d.duckdb.sql' "$QDIR" "$n")
  [ -f "$f" ] || { echo "Q$n: query file missing"; continue; }
  sql=$(cat "$f")
  echo "============================================================"
  echo "Q$n"
  : > /tmp/pdvd-server.err  # reset diag capture window
  before=$(pc)
  # engine (schema duck)
  out_d=$(timeout 120 "$MYSQL" --no-defaults -uroot --socket="$SOCK" -N duck -e "$sql" 2>/tmp/pdvd-q.err)
  rc=$?
  after=$(pc)
  out_i=$(timeout 300 "$MYSQL" --no-defaults -uroot --socket="$SOCK" -N inno -e "$sql" 2>/dev/null)
  if [ $rc -ne 0 ]; then echo "Q$n: ENGINE rc=$rc"; tail -3 /tmp/pdvd-q.err; fi
  md_d=$(printf '%s' "$out_d" | sort | md5sum | awk '{print $1}')
  md_i=$(printf '%s' "$out_i" | sort | md5sum | awk '{print $1}')
  rows_d=$(printf '%s' "$out_d" | grep -c . )
  rows_i=$(printf '%s' "$out_i" | grep -c . )
  match=MISMATCH; [ "$md_d" = "$md_i" ] && match=MATCH
  echo "Q$n: push=$before->$after rows: duck=$rows_d inno=$rows_i  $match"
  if [ "$match" != MATCH ]; then
    echo "--- sample diff (< duck  > inno), first 16 ---"
    diff <(printf '%s' "$out_d" | sort) <(printf '%s' "$out_i" | sort) | head -16
  fi
  echo "--- [pd-*] diagnostics for Q$n ---"
  grep -aE '\[pd-' /tmp/pdvd-server.err | tail -60
  if [ $rc -ne 0 ]; then
    echo "--- server err tail (crash?) for Q$n ---"
    tail -c 12000 /tmp/pdvd-server.err | strings | tail -50
  fi
done
