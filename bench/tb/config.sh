#!/usr/bin/env bash
# Shared config for the terabyte-scale TPC-H harness. Sourced by every script.
# All values overridable from the environment: SF=100 bash 01-generate.sh
# SF-derived paths are recomputed per run and must NOT be pinned in tb.env.

export LC_ALL=C LANG=C

# ---- scale ------------------------------------------------------------------
# SF1000 ~= 1 TB of raw TPC-H CSV, ~6 billion lineitem rows.
SF=${SF:-1000}

# InnoDB's 22-query run is NOT tractable at SF1000 (see README). Run the InnoDB
# *query* comparison at this smaller scale while load/storage are measured at
# the full SF. Set equal to $SF to force a full-scale InnoDB query run.
SF_INNODB_QUERIES=${SF_INNODB_QUERIES:-100}

# ---- paths (override these to point at the big disks) ------------------------
# TB_ROOT holds everything: generated CSVs, engine datadirs, results, temp.
TB_ROOT=${TB_ROOT:-/data/tpch-tb}
RESULTS_DIR=${RESULTS_DIR:-$TB_ROOT/results}     # timings, checksums, reports (per-SF filenames)
STATE_DIR=${STATE_DIR:-$TB_ROOT/state}           # phase checkpoints (per-SF markers)
TEMP_DIR=${TEMP_DIR:-$TB_ROOT/tmp}               # DuckDB spill target - needs to be BIG

# EVERY SF-derived path is recomputed from $SF on each invocation and is
# deliberately NOT exported by setup.sh's tb.env. Pinning them once (as an
# earlier version did) meant `SF=200 bash run-all.sh` silently wrote into the
# SF1000 directories and mixed two datasets together.
export DATA_DIR=$TB_ROOT/data-sf$SF              # generated CSVs
export DUCKDB_DATADIR=$TB_ROOT/mysql-duckdb-sf$SF
export INNODB_DATADIR=$TB_ROOT/mysql-innodb-sf$SF
export NATIVE_DB=$TB_ROOT/native-sf$SF.duckdb

# How to get the "native DuckDB" reference leg:
#   attach - open the ENGINE=DuckDB server's OWN <schema>.duckdb file read-only
#            with the DuckDB CLI. Costs ZERO extra disk and skips a whole load
#            phase. This is the default because at SF1000 a second copy is
#            ~300 GB you probably do not have.
#   copy   - build a separate native database from the CSVs (+~0.30 GB per SF).
# 'attach' requires the engine's embedded DuckDB storage format to be readable
# by $DUCKDB_IMAGE's CLI; 05-native-duckdb.sh probes this and tells you to
# switch to copy if it is not.
NATIVE_MODE=${NATIVE_MODE:-attach}

# ---- images (nothing is installed on the host) ------------------------------
# ENGINE_IMAGE defaults to the PUBLISHED mirror, because `ducksdb/mysql:...` is
# a local-only build tag that does not exist in any registry - on a fresh node
# it cannot be pulled. ensure_images() (lib.sh) pulls this one and builds the
# other two from inline Dockerfiles, so a brand-new node needs nothing staged.
ENGINE_IMAGE=${ENGINE_IMAGE:-evgeniypatlan/test-images:mysql-9.7-duckdb-v0.2.2}
DUCKDB_IMAGE=${DUCKDB_IMAGE:-ducksdb-duckdb:1.5.3}   # built locally if absent
DUCKDB_CLI_VERSION=${DUCKDB_CLI_VERSION:-1.5.3}
GEN_IMAGE=${GEN_IMAGE:-ducksdb-tpchgen:latest}       # built locally if absent
REPORT_IMAGE=${REPORT_IMAGE:-ducksdb-report:latest}  # matplotlib, for the charts

# ---- resource sizing (0 = auto-derive from the node in 00-preflight.sh) ------
CPUS=${CPUS:-0}                 # container CPU pin; 0 = all cores
MEM=${MEM:-0}                   # container memory cap, e.g. 400g; 0 = auto
DUCK_MEM=${DUCK_MEM:-0}         # DuckDB memory_limit, e.g. 300GB; 0 = auto
INNODB_POOL=${INNODB_POOL:-0}   # InnoDB buffer pool, e.g. 200G; 0 = auto

# Fractions used when auto-deriving (of total node RAM).
# DuckDB runs *inside* mysqld, so its cap must leave headroom for the server
# itself plus result staging - that is what MEM_FRACTION_DUCK reserves.
MEM_FRACTION_CONTAINER=${MEM_FRACTION_CONTAINER:-0.85}
MEM_FRACTION_DUCK=${MEM_FRACTION_DUCK:-0.60}
MEM_FRACTION_INNODB=${MEM_FRACTION_INNODB:-0.65}

# ---- run behaviour ----------------------------------------------------------
ITERS=${ITERS:-2}                     # timed iterations/query (min reported, 1 warmup)
QTIMEOUT=${QTIMEOUT:-7200}            # per-query timeout, seconds (2h)
QTIMEOUT_INNODB=${QTIMEOUT_INNODB:-7200}
LOAD_TIMEOUT=${LOAD_TIMEOUT:-172800}  # per-table load timeout (48h ceiling)
# Graceful shutdown budget. After a 1 TB load the DuckDB checkpoint on shutdown
# is NOT instant; killing the server early leaves the data stranded in the WAL.
SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT:-600}
# Q15 last: it is referenced twice and can blow memory; running it last means a
# failure there does not poison the other 21.
QUERY_SEQ=${QUERY_SEQ:-"1 2 3 4 5 6 7 8 9 10 11 12 13 14 16 17 18 19 20 21 22 15"}

export TABLES="region nation supplier customer part partsupp orders lineitem"

# String-column collation for the InnoDB + ENGINE=DuckDB tables. Empty = server
# default (case-insensitive, e.g. utf8mb4_0900_ai_ci). Native DuckDB compares
# byte-wise, so a _ci collation makes the engine emit COLLATE NOCASE and run
# string GROUP BY / ORDER BY / DISTINCT slower than native (measured ~1.6x on
# TPC-H Q1). Set TABLE_COLLATE=utf8mb4_bin for a byte-wise, apples-to-apples
# comparison against native (and to remove that tax); it applies to InnoDB and
# the engine equally, so the comparison stays fair.
TABLE_COLLATE=${TABLE_COLLATE:-}
table_opts(){ printf 'ENGINE=%s%s' "$1" "${TABLE_COLLATE:+ DEFAULT CHARSET=utf8mb4 COLLATE=$TABLE_COLLATE}"; }

# ---- derived ----------------------------------------------------------------
mkdir -p "$RESULTS_DIR" "$STATE_DIR" 2>/dev/null || true

# Best-effort, unprivileged: raise this shell's SOFT open-file limit toward the
# hard limit. Needs no root and helps host-side tooling during a long run. The
# server containers get --ulimit nofile=65536:65536 regardless (see lib.sh), and
# the sysctls that do need root live in tune-node.sh.
_raise_nofile(){
  local want=65536 hard
  hard=$(ulimit -Hn 2>/dev/null) || return 0
  [ "$hard" = unlimited ] || { [ "$hard" -lt "$want" ] 2>/dev/null && want=$hard; }
  [ "$(ulimit -Sn)" -lt "$want" ] 2>/dev/null && ulimit -Sn "$want" 2>/dev/null
  return 0
}
_raise_nofile

log(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Phase checkpointing: every long phase records a marker so a re-run skips it.
# Use FORCE=1 to ignore existing markers and redo a phase.
done_marker(){ echo "$STATE_DIR/$1.done"; }
is_done(){ [ "${FORCE:-0}" != 1 ] && [ -f "$(done_marker "$1")" ]; }
mark_done(){ date -u +%Y-%m-%dT%H:%M:%SZ > "$(done_marker "$1")"; }

# Human-readable bytes.
hr(){ awk -v b="$1" 'BEGIN{u="B KB MB GB TB PB"; split(u,a," "); i=1;
  while(b>=1024 && i<6){b/=1024;i++} printf "%.1f%s", b, a[i]}'; }

# Total RAM / cores of this node.
node_ram_bytes(){ awk '/MemTotal/{print $2*1024}' /proc/meminfo; }
node_cores(){ nproc; }

# Free bytes on the filesystem holding $1 (creates the dir if needed).
free_bytes(){ mkdir -p "$1" 2>/dev/null || true; df -PB1 "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# Resolve the auto-sized values. Safe to call repeatedly.
resolve_sizing(){
  local ram cores
  ram=$(node_ram_bytes); cores=$(node_cores)
  [ "$CPUS" = 0 ] && CPUS=$cores
  [ "$MEM" = 0 ] && MEM="$(awk -v r="$ram" -v f="$MEM_FRACTION_CONTAINER" 'BEGIN{printf "%dg", (r*f)/1073741824}')"
  [ "$DUCK_MEM" = 0 ] && DUCK_MEM="$(awk -v r="$ram" -v f="$MEM_FRACTION_DUCK" 'BEGIN{printf "%dGB", (r*f)/1073741824}')"
  [ "$INNODB_POOL" = 0 ] && INNODB_POOL="$(awk -v r="$ram" -v f="$MEM_FRACTION_INNODB" 'BEGIN{printf "%dG", (r*f)/1073741824}')"
  export CPUS MEM DUCK_MEM INNODB_POOL
}

# ---- TPC-H DDL --------------------------------------------------------------
# WITH_PK=1 -> include PRIMARY KEY (InnoDB always; DuckDB only when you need
# UPDATE/DELETE, e.g. the replication spike). At SF1000 a PK on lineitem is a
# 6-billion-row index build - see README before enabling it for DuckDB.
ddl_cols(){ # $1=table  $2=with_pk(0|1)
  local t=$1 pk=${2:-0} body
  case "$t" in
    region)   body="r_regionkey INT, r_name CHAR(25), r_comment VARCHAR(152)";       [ "$pk" = 1 ] && body="$body, PRIMARY KEY (r_regionkey)";;
    nation)   body="n_nationkey INT, n_name CHAR(25), n_regionkey INT, n_comment VARCHAR(152)"; [ "$pk" = 1 ] && body="$body, PRIMARY KEY (n_nationkey)";;
    supplier) body="s_suppkey INT, s_name CHAR(25), s_address VARCHAR(40), s_nationkey INT, s_phone CHAR(15), s_acctbal DECIMAL(15,2), s_comment VARCHAR(101)"; [ "$pk" = 1 ] && body="$body, PRIMARY KEY (s_suppkey)";;
    customer) body="c_custkey INT, c_name VARCHAR(25), c_address VARCHAR(40), c_nationkey INT, c_phone CHAR(15), c_acctbal DECIMAL(15,2), c_mktsegment CHAR(10), c_comment VARCHAR(117)"; [ "$pk" = 1 ] && body="$body, PRIMARY KEY (c_custkey)";;
    part)     body="p_partkey INT, p_name VARCHAR(55), p_mfgr CHAR(25), p_brand CHAR(10), p_type VARCHAR(25), p_size INT, p_container CHAR(10), p_retailprice DECIMAL(15,2), p_comment VARCHAR(23)"; [ "$pk" = 1 ] && body="$body, PRIMARY KEY (p_partkey)";;
    partsupp) body="ps_partkey INT, ps_suppkey INT, ps_availqty INT, ps_supplycost DECIMAL(15,2), ps_comment VARCHAR(199)"; [ "$pk" = 1 ] && body="$body, PRIMARY KEY (ps_partkey, ps_suppkey)";;
    orders)   body="o_orderkey BIGINT, o_custkey INT, o_orderstatus CHAR(1), o_totalprice DECIMAL(15,2), o_orderdate DATE, o_orderpriority CHAR(15), o_clerk CHAR(15), o_shippriority INT, o_comment VARCHAR(79)"; [ "$pk" = 1 ] && body="$body, PRIMARY KEY (o_orderkey)";;
    lineitem) body="l_orderkey BIGINT, l_partkey INT, l_suppkey INT, l_linenumber INT, l_quantity DECIMAL(15,2), l_extendedprice DECIMAL(15,2), l_discount DECIMAL(15,2), l_tax DECIMAL(15,2), l_returnflag CHAR(1), l_linestatus CHAR(1), l_shipdate DATE, l_commitdate DATE, l_receiptdate DATE, l_shipinstruct CHAR(25), l_shipmode CHAR(10), l_comment VARCHAR(44)"; [ "$pk" = 1 ] && body="$body, PRIMARY KEY (l_orderkey, l_linenumber)";;
  esac
  echo "$body"
}

ddl_duckdb_native(){ # native DuckDB types (no PK)
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
