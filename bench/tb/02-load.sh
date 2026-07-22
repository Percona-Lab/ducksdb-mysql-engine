#!/usr/bin/env bash
# Load pre-generated CSVs into one engine, timing each table (axis 1: load time).
# Resumable: a table whose row count already matches is skipped.
#   ENGINE=duckdb bash 02-load.sh
#   ENGINE=innodb bash 02-load.sh
# DuckDB is loaded without a PK by default (DUCKDB_PK=1 to override); at SF1000 a
# PK on lineitem exhausts memory and native DuckDB has none either.

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"

ENGINE=${ENGINE:-duckdb}
case "$ENGINE" in duckdb|innodb) ;; *) die "ENGINE must be duckdb or innodb";; esac
SQL_ENGINE=$(sql_engine_for "$ENGINE")
DB=tpch

# DuckDB: PK off by default (memory). InnoDB: always on.
if [ "$ENGINE" = innodb ]; then WITH_PK=1; else WITH_PK=${DUCKDB_PK:-0}; fi

[ -f "$DATA_DIR/lineitem.csv" ] || die "no data in $DATA_DIR - run 01-generate.sh first"
FIELDS=$(load_fields_clause)
RES="$RESULTS_DIR/load-$ENGINE-sf$SF.txt"

log "loading SF=$SF into ENGINE=$SQL_ENGINE (PK=$WITH_PK)"
log "fields clause: $FIELDS"
server_start "$ENGINE"
trap 'server_stop "$ENGINE"' EXIT

Q "$ENGINE" -e "CREATE DATABASE IF NOT EXISTS $DB;" || die "cannot create database"

# Expected row counts, so resume can tell "already loaded" from "half loaded".
expected_rows(){ # $1=table -> rows at this SF (TPC-H cardinalities)
  case "$1" in
    region)   echo 5;;
    nation)   echo 25;;
    supplier) awk -v s="$SF" 'BEGIN{printf "%.0f", 10000*s}';;
    customer) awk -v s="$SF" 'BEGIN{printf "%.0f", 150000*s}';;
    part)     awk -v s="$SF" 'BEGIN{printf "%.0f", 200000*s}';;
    partsupp) awk -v s="$SF" 'BEGIN{printf "%.0f", 800000*s}';;
    orders)   awk -v s="$SF" 'BEGIN{printf "%.0f", 1500000*s}';;
    lineitem) awk -v s="$SF" 'BEGIN{printf "%.0f", 6000000*s}';;  # ~6.001e6*SF
  esac
}

table_rows(){ Q "$ENGINE" -N -B "$DB" -e "SELECT COUNT(*) FROM $1" 2>/dev/null | tail -1; }

{ echo "# load timings: engine=$SQL_ENGINE SF=$SF pk=$WITH_PK  $(date -u +%FT%TZ)"
  printf '%-10s %14s %16s %14s\n' "table" "seconds" "rows" "csv_size"; } | tee "$RES"

grand_start=$(date +%s); total_rows=0; failed=0
for t in $TABLES; do
  f="/data/$t.csv"
  host_f="$DATA_DIR/$t.csv"
  [ -s "$host_f" ] || { log "SKIP $t (no CSV)"; continue; }

  # --- resume check ---
  if [ "${FORCE:-0}" != 1 ]; then
    have=$(table_rows "$t" 2>/dev/null || echo 0); have=${have:-0}
    want=$(expected_rows "$t")
    if [ "$have" -gt 0 ] && [ "$have" -ge "$want" ]; then
      log "$t already loaded ($have rows) - skipping"
      printf '%-10s %14s %16s %14s\n' "$t" "skipped" "$have" "-" | tee -a "$RES"
      total_rows=$((total_rows+have)); continue
    fi
    [ "$have" -gt 0 ] && { log "$t partially loaded ($have/$want) - recreating"; }
  fi

  Q "$ENGINE" "$DB" -e "DROP TABLE IF EXISTS $t;" 2>/dev/null
  Q "$ENGINE" "$DB" -e "CREATE TABLE $t ($(ddl_cols "$t" "$WITH_PK")) $(table_opts "$SQL_ENGINE");" \
    2>>"$RESULTS_DIR/load-$ENGINE.err" || { log "CREATE $t FAILED"; failed=$((failed+1)); continue; }

  log "loading $t ($(hr "$(stat -c%s "$host_f")")) ..."
  t0=$(date +%s)
  timeout "$LOAD_TIMEOUT" docker exec "$(container_name "$ENGINE")" \
    mysql -uroot "$DB" -e "LOAD DATA INFILE '$f' INTO TABLE $t $FIELDS;" \
    2>>"$RESULTS_DIR/load-$ENGINE.err"
  rc=$?; t1=$(date +%s)
  if [ "$rc" -ne 0 ]; then
    log "LOAD $t FAILED (rc=$rc) - see $RESULTS_DIR/load-$ENGINE.err"
    printf '%-10s %14s %16s %14s\n' "$t" "FAILED" "-" "-" | tee -a "$RES"
    failed=$((failed+1)); continue
  fi
  rows=$(table_rows "$t"); total_rows=$((total_rows+${rows:-0}))
  printf '%-10s %14s %16s %14s\n' "$t" "$((t1-t0))" "${rows:-?}" "$(hr "$(stat -c%s "$host_f")")" | tee -a "$RES"
done
grand_end=$(date +%s)

{ printf '%-10s %14s %16s\n' "TOTAL" "$((grand_end-grand_start))" "$total_rows"
  echo
  echo "engine=$SQL_ENGINE sf=$SF pk=$WITH_PK load_seconds=$((grand_end-grand_start)) rows=$total_rows failed=$failed"; } | tee -a "$RES"

echo "load_${ENGINE}_seconds=$((grand_end-grand_start))" >> "$RESULTS_DIR/timings.txt"
[ "$failed" -gt 0 ] && die "$failed table(s) failed to load - see $RESULTS_DIR/load-$ENGINE.err"

mark_done "load-$ENGINE-sf$SF"
log "OK - load took $((grand_end-grand_start))s. Next: bash 03-storage.sh"
