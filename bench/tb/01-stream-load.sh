#!/usr/bin/env bash
# Generate and load in chunks: generate part i -> LOAD DATA -> delete -> i+1.
# Peak CSV on disk is one chunk (CHUNK_GB) instead of the whole dataset, which is
# what makes SF1000 fit on a 1.8 TB disk. Resumable at chunk granularity.
#   ENGINE=duckdb bash 01-stream-load.sh
#   ENGINE=innodb CHUNK_GB=10 bash 01-stream-load.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"
resolve_sizing

ENGINE=${ENGINE:-duckdb}
case "$ENGINE" in duckdb|innodb) ;; *) die "ENGINE must be duckdb or innodb";; esac
SQL_ENGINE=$(sql_engine_for "$ENGINE")
DB=tpch
CHUNK_GB=${CHUNK_GB:-20}
if [ "$ENGINE" = innodb ]; then WITH_PK=1; else WITH_PK=${DUCKDB_PK:-0}; fi

# Approximate GB per SF unit, per table (TPC-H distribution; sums to ~1.09).
tbl_gb_per_sf(){ case "$1" in
  lineitem) echo 0.75;; orders) echo 0.17;; partsupp) echo 0.12;;
  customer) echo 0.025;; part) echo 0.024;; supplier) echo 0.0014;;
  nation|region) echo 0.0001;; esac; }

parts_for(){ # $1=table -> number of chunks so each is ~CHUNK_GB
  awk -v sf="$SF" -v g="$(tbl_gb_per_sf "$1")" -v c="$CHUNK_GB" \
    'BEGIN{ n=int((sf*g)/c); if(n<1) n=1; print n }'; }

mkdir -p "$DATA_DIR" "$RESULTS_DIR" "$STATE_DIR"
RES="$RESULTS_DIR/streamload-$ENGINE-sf$SF.txt"

# ---- images (pulled/built automatically on a fresh node) ---------------------
ensure_images

# The generated files must be readable by the server container (mounted ro at
# /data) and deletable by this script - hence --user.
gen_part(){ # $1=table $2=parts $3=part_index
  docker run --rm --user "$(id -u):$(id -g)" \
    --cpus "$CPUS" -v "$DATA_DIR":/out "$GEN_IMAGE" \
    tpchgen-cli csv -s "$SF" --delimiter='|' --tables="$1" \
      --parts="$2" --part="$3" --output-dir=/out -n "$CPUS" --quiet --no-progress
}

# ---- server ------------------------------------------------------------------
log "stream-loading SF=$SF into ENGINE=$SQL_ENGINE (chunk target ${CHUNK_GB} GB, PK=$WITH_PK)"
server_start "$ENGINE"
trap 'server_stop "$ENGINE"' EXIT
Q "$ENGINE" -e "CREATE DATABASE IF NOT EXISTS $DB;" || die "cannot create database"

# Fields clause: pipe-delimited, quoted strings, one header line per part file.
FIELDS="FIELDS TERMINATED BY '|' OPTIONALLY ENCLOSED BY '\"' LINES TERMINATED BY '\n' IGNORE 1 LINES"

{ echo "# stream load: engine=$SQL_ENGINE SF=$SF chunk=${CHUNK_GB}GB  $(date -u +%FT%TZ)"
  printf '%-10s %7s %12s %14s %16s\n' "table" "parts" "seconds" "peak_chunk" "rows"; } | tee "$RES"

grand0=$(date +%s)
for t in $TABLES; do
  nparts=$(parts_for "$t")
  statef="$STATE_DIR/streamload-$ENGINE-sf$SF-$t.parts"
  [ "${FORCE:-0}" = 1 ] && rm -f "$statef"

  # Create the table once, on the first chunk of a fresh table.
  if [ ! -f "$statef" ]; then
    Q "$ENGINE" "$DB" -e "DROP TABLE IF EXISTS $t;" 2>/dev/null
    Q "$ENGINE" "$DB" -e "CREATE TABLE $t ($(ddl_cols "$t" "$WITH_PK")) $(table_opts "$SQL_ENGINE");" \
      2>>"$RESULTS_DIR/streamload-$ENGINE.err" || die "CREATE $t failed"
    : > "$statef"
  fi

  log "$t: $nparts chunk(s)"
  t0=$(date +%s); peak=0
  for i in $(seq 1 "$nparts"); do
    grep -qx "$i" "$statef" 2>/dev/null && continue   # already loaded

    # disk guard: need room for this chunk plus a safety margin
    freeg=$(( $(free_bytes "$DATA_DIR") /1024/1024/1024 ))
    [ "$freeg" -lt $((CHUNK_GB*2+10)) ] && die "only ${freeg} GB free - need ~$((CHUNK_GB*2+10)) GB headroom per chunk"

    gen_part "$t" "$nparts" "$i" >>"$RESULTS_DIR/streamload-$ENGINE.err" 2>&1 \
      || die "generation failed: $t part $i/$nparts"

    f_host="$DATA_DIR/$t/$t.$i.csv"
    [ -s "$f_host" ] || die "expected $f_host after generating part $i"
    sz=$(stat -c%s "$f_host"); [ "$sz" -gt "$peak" ] && peak=$sz

    timeout "$LOAD_TIMEOUT" docker exec "$(container_name "$ENGINE")" \
      mysql -uroot "$DB" -e "LOAD DATA INFILE '/data/$t/$t.$i.csv' INTO TABLE $t $FIELDS;" \
      2>>"$RESULTS_DIR/streamload-$ENGINE.err" \
      || die "LOAD failed: $t part $i/$nparts (see $RESULTS_DIR/streamload-$ENGINE.err)"

    rm -f "$f_host"                 # <-- the whole point: reclaim immediately
    echo "$i" >> "$statef"
    printf '\r    %s: %d/%d chunks loaded (peak chunk %s)   ' "$t" "$i" "$nparts" "$(hr "$peak")" >&2
  done
  echo >&2
  rmdir "$DATA_DIR/$t" 2>/dev/null || true
  t1=$(date +%s)
  rows=$(Q "$ENGINE" -N -B "$DB" -e "SELECT COUNT(*) FROM $t" 2>/dev/null | tail -1)
  printf '%-10s %7s %12s %14s %16s\n' "$t" "$nparts" "$((t1-t0))" "$(hr "$peak")" "${rows:-?}" | tee -a "$RES"
done
grand1=$(date +%s)

{ echo
  echo "TOTAL load_seconds=$((grand1-grand0))  engine=$SQL_ENGINE sf=$SF"
  awk -v k="$CHUNK_GB" -v sf="$SF" 'BEGIN{printf "peak CSV on disk was one chunk (~%s GB) instead of ~%.0f GB\n", k, sf}'; } | tee -a "$RES"
echo "load_${ENGINE}_seconds=$((grand1-grand0))" >> "$RESULTS_DIR/timings.txt"

mark_done "load-$ENGINE-sf$SF"
mark_done "generate-sf$SF"     # data was consumed inline; nothing left to generate
log "OK - streamed load finished in $((grand1-grand0))s"
