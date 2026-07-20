#!/usr/bin/env bash
# Run the 22 TPC-H queries against one engine (axis 2: query time).
# Resumable per query. A query exceeding QTIMEOUT is recorded as DNF rather than
# aborting the run.
#   ENGINE=duckdb bash 04-query.sh
#   ENGINE=native bash 04-query.sh     # correctness oracle + ceiling
#   ENGINE=innodb bash 04-query.sh     # expect DNFs above ~SF100

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"

ensure_images
ENGINE=${ENGINE:-duckdb}
case "$ENGINE" in duckdb|innodb|native) ;; *) die "ENGINE must be duckdb, innodb or native";; esac
DB=tpch
QDIR="$DATA_DIR/queries"
OUT="$RESULTS_DIR/queries-$ENGINE-sf$SF"; mkdir -p "$OUT"
RES="$RESULTS_DIR/query-$ENGINE-sf$SF.txt"
TMO=$QTIMEOUT; [ "$ENGINE" = innodb ] && TMO=$QTIMEOUT_INNODB

# ---- 1. extract + translate the 22 canonical queries (cheap, cached) --------
to_mysql_dialect(){
  # DuckDB/Postgres interval arithmetic -> MySQL. Same translation the SF1/SF10
  # harness uses, so query text is identical across all our runs.
  sed -E "
    s/(date '[0-9-]+')[[:space:]]*\+[[:space:]]*interval '([0-9]+)' (year|month|day)/DATE_ADD(\1, INTERVAL \2 \U\3\E)/Ig;
    s/(date '[0-9-]+')[[:space:]]*-[[:space:]]*interval '([0-9]+)' (year|month|day)/DATE_SUB(\1, INTERVAL \2 \U\3\E)/Ig;
    s/interval '([0-9]+)' (year|month|day)/INTERVAL \1 \U\2\E/Ig;
    s/'([^']*)'::date/DATE '\1'/Ig;
  "
}
if [ ! -f "$QDIR/q01.duckdb.sql" ]; then
  log "extracting the 22 canonical queries from DuckDB's tpch extension ..."
  mkdir -p "$QDIR"
  gen=tb-qgen-$$
  docker run -d --name "$gen" -v "$QDIR":/q "$DUCKDB_IMAGE" >/dev/null
  for n in $(seq 1 22); do
    docker exec "$gen" duckdb -noheader -list -c \
      "INSTALL tpch; LOAD tpch; SELECT query FROM tpch_queries() WHERE query_nr=$n;" \
      2>/dev/null > "$QDIR/$(printf 'q%02d' "$n").duckdb.sql"
  done
  docker rm -f "$gen" >/dev/null 2>&1
fi
for n in $(seq 1 22); do
  q=$(printf 'q%02d' "$n")
  [ -f "$QDIR/$q.mysql.sql" ] || to_mysql_dialect < "$QDIR/$q.duckdb.sql" > "$QDIR/$q.mysql.sql"
done

# ---- 2. bring up the target -------------------------------------------------
NATC=tb-native
cleanup(){ server_stop duckdb; server_stop innodb; docker rm -f "$NATC" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ "$ENGINE" = native ]; then
  stop_all_servers          # the engine must not hold the file open
  resolve_sizing
  if [ "$NATIVE_MODE" = attach ]; then
    # Zero-extra-disk mode: query the ENGINE's own .duckdb file, read-only.
    NDB_HOST=$(find_engine_duckdb_file tpch)
    [ -n "$NDB_HOST" ] || die "no tpch.duckdb under $DUCKDB_DATADIR - load the DuckDB engine first, or set NATIVE_MODE=copy"
    log "native leg: attaching the engine's own file read-only ($NDB_HOST)"
    RO="-readonly"
  else
    [ -f "$NATIVE_DB" ] || die "native DB missing: $NATIVE_DB (run 05-native-duckdb.sh)"
    NDB_HOST="$NATIVE_DB"; RO=""
  fi
  docker rm -f "$NATC" >/dev/null 2>&1 || true
  docker run -d --name "$NATC" --cpus "$CPUS" --memory "$MEM" \
    -v "$(dirname "$NDB_HOST")":/nat -v "$TEMP_DIR":/spill "$DUCKDB_IMAGE" >/dev/null
  sleep 2
  run_query(){ # $1=sql -> stdout rows
    timeout "$TMO" docker exec "$NATC" duckdb $RO "/nat/$(basename "$NDB_HOST")" -noheader -list \
      -c "SET temp_directory='/spill'; SET memory_limit='$DUCK_MEM'; SET threads=$CPUS; $1"; }
else
  server_start "$ENGINE"
  run_query(){ timeout "$TMO" docker exec "$(container_name "$ENGINE")" mysql -uroot -N "$DB" -e "$1"; }
fi

# Normalise numbers to 4dp so MySQL DECIMAL vs DuckDB DOUBLE formatting
# differences (348406.054286 vs 348406.0542857143) do not read as mismatches.
norm(){ awk 'BEGIN{FS=OFS="|"}{for(i=1;i<=NF;i++) if($i ~ /^-?[0-9]+\.[0-9]+$/) $i=sprintf("%.4f",$i); print}'; }

# ---- 3. run -----------------------------------------------------------------
{ echo "# query timings: engine=$ENGINE SF=$SF iters=$ITERS timeout=${TMO}s  $(date -u +%FT%TZ)"
  printf '%-6s %12s %10s %12s\n' "query" "seconds" "rows" "status"; } | tee "$RES"

n_ok=0; n_dnf=0; n_err=0; total=0
for n in $QUERY_SEQ; do
  q=$(printf 'q%02d' "$n")
  tfile="$OUT/$q.time"; rfile="$OUT/$q.out"

  if [ "${FORCE:-0}" != 1 ] && [ -f "$tfile" ]; then
    best=$(cat "$tfile"); rows=$(grep -c . "$rfile" 2>/dev/null || echo 0)
    printf '%-6s %12s %10s %12s\n' "Q$n" "$best" "$rows" "cached" | tee -a "$RES"
    case "$best" in DNF|ERR) ;; *) total=$(awk "BEGIN{print $total+$best}"); n_ok=$((n_ok+1));; esac
    continue
  fi

  if [ "$ENGINE" = native ]; then sql=$(cat "$QDIR/$q.duckdb.sql"); else sql=$(cat "$QDIR/$q.mysql.sql"); fi

  # warmup (also captures the result set for the correctness comparison)
  run_query "$sql" 2>/dev/null | sed 's/\t/|/g' | norm | LC_ALL=C sort > "$rfile"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 124 ]; then
    echo DNF > "$tfile"; n_dnf=$((n_dnf+1))
    printf '%-6s %12s %10s %12s\n' "Q$n" "DNF" "-" ">${TMO}s" | tee -a "$RES"; continue
  elif [ "$rc" -ne 0 ]; then
    echo ERR > "$tfile"; n_err=$((n_err+1))
    printf '%-6s %12s %10s %12s\n' "Q$n" "ERR" "-" "rc=$rc" | tee -a "$RES"; continue
  fi

  times=()
  for _ in $(seq 1 "$ITERS"); do
    t0=$(date +%s.%N)
    run_query "$sql" >/dev/null 2>&1; rc=$?
    t1=$(date +%s.%N)
    [ "$rc" -eq 0 ] && times+=("$(elapsed "$t0" "$t1")")
  done
  if [ "${#times[@]}" -eq 0 ]; then
    echo DNF > "$tfile"; n_dnf=$((n_dnf+1))
    printf '%-6s %12s %10s %12s\n' "Q$n" "DNF" "-" "timed iters failed" | tee -a "$RES"; continue
  fi
  best=$(minv "${times[@]}"); echo "$best" > "$tfile"
  rows=$(grep -c . "$rfile" 2>/dev/null || echo 0)
  total=$(awk "BEGIN{print $total+$best}"); n_ok=$((n_ok+1))
  printf '%-6s %12s %10s %12s\n' "Q$n" "$best" "$rows" "ok" | tee -a "$RES"
done

{ echo
  printf 'finished=%d  DNF=%d  ERR=%d  of 22\n' "$n_ok" "$n_dnf" "$n_err"
  printf 'sum of finished queries: %.3f s\n' "$total"
  echo "engine=$ENGINE sf=$SF iters=$ITERS timeout=${TMO}s"
  [ "$n_dnf" -gt 0 ] && echo "NOTE: $n_dnf queries exceeded ${TMO}s. That is a result, not a failure."; } | tee -a "$RES"

echo "query_${ENGINE}_finished=$n_ok" >> "$RESULTS_DIR/timings.txt"
echo "query_${ENGINE}_total_seconds=$total" >> "$RESULTS_DIR/timings.txt"
mark_done "query-$ENGINE-sf$SF"
log "written: $RES  (result sets under $OUT for the correctness diff)"
