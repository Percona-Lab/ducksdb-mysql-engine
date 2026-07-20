#!/usr/bin/env bash
# Provide the native DuckDB reference leg.
# NATIVE_MODE=attach (default) opens the engine's own <schema>.duckdb read-only:
# no extra disk, no load phase. NATIVE_MODE=copy builds a separate database from
# the CSVs instead.
#   bash 05-native-duckdb.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"
resolve_sizing
load_format
ensure_images

# ---- NATIVE_MODE=attach: no build, no extra disk ----------------------------
# Probe whether the DuckDB CLI can open the engine's own database file. If it
# can, the native leg needs no separate copy at all (saves ~0.30 GB per SF -
# about 300 GB at SF1000) and skips this entire load phase.
if [ "$NATIVE_MODE" = attach ]; then
  f=$(find_engine_duckdb_file tpch)
  [ -n "$f" ] || die "no tpch.duckdb under $DUCKDB_DATADIR yet - load the DuckDB engine first (01-stream-load.sh), or set NATIVE_MODE=copy"
  stop_all_servers
  log "probing whether $DUCKDB_IMAGE can read the engine's file: $f"
  probe=$(timeout 300 docker run --rm --entrypoint duckdb -v "$(dirname "$f")":/nat "$DUCKDB_IMAGE" \
            -readonly "/nat/$(basename "$f")" -noheader -list \
            -c "SELECT count(*) FROM lineitem;" 2>&1 | tail -2)
  case "$probe" in
    *[0-9]*)
      log "OK - CLI reads the engine file (lineitem count: $probe)"
      log "native leg will attach it read-only; nothing to build. Next: ENGINE=native bash 04-query.sh"
      mark_done "native-sf$SF"; exit 0;;
    *)
      log "CANNOT read the engine's file with this CLI:"; echo "$probe" | sed 's/^/    /' >&2
      log "storage formats differ - falling back is required: re-run with NATIVE_MODE=copy"
      die "attach probe failed (needs ~$(awk -v s="$SF" 'BEGIN{printf "%.0f", s*0.3}') GB for NATIVE_MODE=copy)";;
  esac
fi

# ---- NATIVE_MODE=copy: build a separate reference DB from the CSVs ----------
[ -f "$DATA_DIR/lineitem.csv" ] || die "no CSVs in $DATA_DIR - NATIVE_MODE=copy needs them (01-generate.sh), or use NATIVE_MODE=attach"
mkdir -p "$(dirname "$NATIVE_DB")" "$TEMP_DIR"

need_gb=$(awk -v sf="$SF" 'BEGIN{printf "%.0f", sf*0.35}')
free_gb=$(( $(free_bytes "$(dirname "$NATIVE_DB")") /1024/1024/1024 ))
[ "$free_gb" -lt "$need_gb" ] && die "need ~${need_gb} GB for the native DB, have ${free_gb} GB"

NC=tb-native-build
docker rm -f "$NC" >/dev/null 2>&1 || true
stop_all_servers
log "starting native DuckDB container (memory_limit=$DUCK_MEM, spill=$TEMP_DIR)"
docker run -d --name "$NC" --cpus "$CPUS" --memory "$MEM" \
  -v "$DATA_DIR":/data:ro \
  -v "$(dirname "$NATIVE_DB")":/nat \
  -v "$TEMP_DIR":/spill \
  "$DUCKDB_IMAGE" >/dev/null || die "cannot start $DUCKDB_IMAGE"
trap 'docker rm -f "$NC" >/dev/null 2>&1 || true' EXIT
sleep 2

NDB="/nat/$(basename "$NATIVE_DB")"
D(){ docker exec -i "$NC" duckdb "$NDB" -noheader -list -c "$1"; }
PRE="SET temp_directory='/spill'; SET memory_limit='$DUCK_MEM'; SET threads=$CPUS;"

hdr=false; [ "$HEADER" = 1 ] && hdr=true

log "loading $SF-scale CSVs into $NATIVE_DB (delim='$DELIM' header=$hdr)"
start=$(date +%s)
for t in $TABLES; do
  f="/data/$t.csv"
  [ -s "$DATA_DIR/$t.csv" ] || { log "SKIP $t (no CSV)"; continue; }

  have=$(D "$PRE SELECT count(*) FROM $t;" 2>/dev/null | tail -1)
  case "$have" in ''|*[!0-9]*) have=0;; esac
  if [ "${FORCE:-0}" != 1 ] && [ "$have" -gt 0 ]; then
    log "$t already present ($have rows) - skipping"; continue
  fi

  log "loading $t ..."
  t0=$(date +%s)
  D "$PRE
     DROP TABLE IF EXISTS $t;
     CREATE TABLE $t ($(ddl_duckdb_native "$t"));
     COPY $t FROM '$f' (FORMAT CSV, DELIMITER '$DELIM', HEADER $hdr, QUOTE '\"', DATEFORMAT '%Y-%m-%d');" \
    >/dev/null 2>>"$RESULTS_DIR/native-load.err" \
    || die "native load of $t failed - see $RESULTS_DIR/native-load.err"
  t1=$(date +%s)
  rows=$(D "$PRE SELECT count(*) FROM $t;" 2>/dev/null | tail -1)
  log "  $t: $((t1-t0))s, $rows rows"
done
end=$(date +%s)

log "native DuckDB build finished in $((end-start))s"
[ -f "$NATIVE_DB" ] && log "native DB size: $(hr "$(stat -c%s "$NATIVE_DB")")"
echo "load_native_seconds=$((end-start))" >> "$RESULTS_DIR/timings.txt"
mark_done "native-sf$SF"
log "OK - next: ENGINE=native bash 04-query.sh"
