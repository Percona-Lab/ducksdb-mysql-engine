#!/usr/bin/env bash
# Generate the TPC-H dataset as pipe-delimited CSV via tpchgen-cli in a container.
# Resumable; one file per table. Use 01-stream-load.sh instead when the full CSV
# set will not fit on disk.
#   bash 01-generate.sh
#   SF=1 bash 01-generate.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"
resolve_sizing

GEN_TABLES=${TABLES:-"region nation supplier customer part partsupp orders lineitem"}
mkdir -p "$DATA_DIR" || die "cannot create DATA_DIR=$DATA_DIR"

# ---- disk guard --------------------------------------------------------------
need_gb=$(awk -v sf="$SF" 'BEGIN{printf "%.0f", sf*1.05}')
free_gb=$(( $(free_bytes "$DATA_DIR") /1024/1024/1024 ))
log "generating SF=$SF into $DATA_DIR"
log "estimated CSV size ~${need_gb} GB, free ${free_gb} GB"
[ "$free_gb" -lt "$need_gb" ] && die "not enough space in $DATA_DIR: need ~${need_gb} GB, have ${free_gb} GB"

# ---- images (pulled/built automatically on a fresh node) ---------------------
ensure_images

# ---- generate ---------------------------------------------------------------
# tpchgen-cli writes one file per table into --output-dir. We generate the whole
# set in one invocation (it parallelises internally), then verify per table.
if is_done "generate-sf$SF"; then
  log "generation already complete (marker present) - skipping. FORCE=1 to redo."
else
  start=$(date +%s)
  log "running tpchgen-cli (this is the long part: expect 2-6 h at SF1000) ..."
  # NOTE: 'csv' is a SUBCOMMAND, not --format=csv. Pipe delimiter avoids the
  # comma-in-comment quoting mess; --user keeps output owned by the caller so
  # the host can delete files afterwards.
  docker run --rm \
    --cpus "$CPUS" \
    --user "$(id -u):$(id -g)" \
    -v "$DATA_DIR":/out \
    "$GEN_IMAGE" \
    tpchgen-cli csv -s "$SF" --delimiter='|' --output-dir=/out \
      -n "$CPUS" --quiet --no-progress \
    2>&1 | tee -a "$RESULTS_DIR/generate.log"
  rc=${PIPESTATUS[0]}
  [ "$rc" -ne 0 ] && die "tpchgen-cli failed (rc=$rc) - see $RESULTS_DIR/generate.log"
  end=$(date +%s)
  echo "generate_seconds=$((end-start))" >> "$RESULTS_DIR/timings.txt"
  log "generation finished in $((end-start))s"
fi

# ---- normalise filenames + verify -------------------------------------------
# tpchgen-cli may emit <table>.csv or <table>.tbl depending on version; settle
# on <table>.csv so the loaders have one convention.
for t in $GEN_TABLES; do
  [ -f "$DATA_DIR/$t.csv" ] && continue
  for cand in "$DATA_DIR/$t.tbl" "$DATA_DIR/$t.dat"; do
    [ -f "$cand" ] && { log "renaming $(basename "$cand") -> $t.csv"; mv "$cand" "$DATA_DIR/$t.csv"; break; }
  done
done

missing=0
echo; printf '%-10s %14s %s\n' "table" "size" "path"
for t in $GEN_TABLES; do
  f="$DATA_DIR/$t.csv"
  if [ -s "$f" ]; then printf '%-10s %14s %s\n' "$t" "$(hr "$(stat -c%s "$f")")" "$f"
  else printf '%-10s %14s %s\n' "$t" "MISSING" "$f"; missing=$((missing+1)); fi
done
[ "$missing" -gt 0 ] && die "$missing table(s) missing - inspect $RESULTS_DIR/generate.log"

# ---- record the format manifest so loaders stay in sync ----------------------
# Auto-detect header + delimiter from the first line of a table with known cols.
first=$(head -1 "$DATA_DIR/region.csv")
if echo "$first" | grep -qi 'r_regionkey\|regionkey'; then HEADER=1; else HEADER=0; fi
case "$first" in *'|'*) DELIM='|';; *) DELIM=',';; esac
# Plain key=value, no shell quoting games - lib.sh parses this with grep, and a
# stray quote here used to break the loaders silently.
cat > "$DATA_DIR/.format" <<EOF
# written by 01-generate.sh - parsed (not sourced) by lib.sh load_format()
DELIM=$DELIM
HEADER=$HEADER
EOF
log "format manifest: DELIM='$DELIM' HEADER=$HEADER  ($DATA_DIR/.format)"

total=$(du -sb "$DATA_DIR" 2>/dev/null | cut -f1)
log "dataset total: $(hr "$total")"
echo "dataset_bytes=$total" >> "$RESULTS_DIR/timings.txt"
mark_done "generate-sf$SF"
log "OK - next: bash 02-load.sh ENGINE=duckdb"
