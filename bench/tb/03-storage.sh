#!/usr/bin/env bash
# Measure on-disk footprint per engine (axis 3: storage).
# Sizes are measured inside a container because the datadirs are root-owned.
#   bash 03-storage.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"

REPORT="$RESULTS_DIR/storage-sf$SF.txt"

# Sizes are measured INSIDE a container. The server datadirs are written by
# mysqld running as root in its container, so a host-side du/find as a normal
# user cannot traverse them - it silently reports 0 instead of failing, which
# quietly dropped InnoDB out of the storage comparison entirely.
MEASURE_IMAGE=${MEASURE_IMAGE:-alpine}
_measure(){ # $1 = host dir, $2 = sh snippet operating on /t
  [ -d "$1" ] || { echo 0; return; }
  local v
  v=$(docker run --rm -v "$1":/t:ro "$MEASURE_IMAGE" sh -c "$2" 2>/dev/null | tail -1)
  case "$v" in ''|*[!0-9]*) echo 0;; *) echo "$v";; esac
}

dir_bytes(){ _measure "$1" 'du -sb /t 2>/dev/null | cut -f1'; }

# Sum every file matching a busybox-find expression under the mounted dir.
sum_find(){ # $1 = host dir, $2 = find args after the path
  _measure "$1" "find /t $2 -type f 2>/dev/null | xargs -r stat -c%s 2>/dev/null | awk '{s+=\$1}END{print s+0}'"
}

# The TPC-H payload only, excluding MySQL's own system tablespaces - otherwise a
# small SF looks absurd (the system files dwarf the data). This is the number
# that belongs in the comparison.
duckdb_payload_bytes(){ sum_find "$DUCKDB_DATADIR" "-name 'tpch.duckdb' -o -name 'tpch.duckdb.wal'"; }
innodb_payload_bytes(){  sum_find "$INNODB_DATADIR" "-path '*tpch*' -name '*.ibd'"; }

# In streaming mode the CSVs are deleted as they are loaded, so the measured raw
# size is meaningless. Fall back to the known TPC-H size (~1 GB per SF unit).
raw_reference_bytes(){
  local measured=$1
  local theoretical
  theoretical=$(awk -v sf="$SF" 'BEGIN{printf "%.0f", sf*1024*1024*1024}')
  if [ "$measured" -lt $((theoretical/2)) ]; then echo "$theoretical"; else echo "$measured"; fi
}
pct(){ awk -v a="$1" -v b="$2" 'BEGIN{ if(b>0) printf "%.1f%%", (a*100)/b; else printf "-" }'; }
ratio(){ awk -v a="$1" -v b="$2" 'BEGIN{ if(a>0) printf "%.2fx", b/a; else printf "-" }'; }

RAW_MEASURED=$(dir_bytes "$DATA_DIR")
RAW=$(raw_reference_bytes "$RAW_MEASURED")
RAW_NOTE=""
[ "$RAW" != "$RAW_MEASURED" ] && RAW_NOTE="  (theoretical: CSVs were streamed and deleted during load)"
# Payload-only figures are the comparable ones; datadir totals include MySQL's
# own system tablespaces and are reported separately below.
DUCK=$(duckdb_payload_bytes)
INNO=$(innodb_payload_bytes)
DUCK_DIR=$(dir_bytes "$DUCKDB_DATADIR")
INNO_DIR=$(dir_bytes "$INNODB_DATADIR")
NAT=0; [ -f "$NATIVE_DB" ] && NAT=$(stat -c%s "$NATIVE_DB")

{
echo "=============================================================="
echo " Storage consumption   SF=$SF   $(date -u +%FT%TZ)"
echo "=============================================================="
echo
echo "TPC-H payload only (excludes MySQL system tablespaces):"
printf '%-28s %14s %12s %10s\n' "component" "size" "vs raw CSV" "compress"
printf '%-28s %14s %12s %10s\n' "----------------------------" "--------------" "------------" "----------"
printf '%-28s %14s %12s %10s%s\n' "raw TPC-H CSV" "$(hr "$RAW")" "100.0%" "1.00x" "$RAW_NOTE"
[ "$DUCK" -gt 0 ] && printf '%-28s %14s %12s %10s\n' "ENGINE=DuckDB (tpch.duckdb)" "$(hr "$DUCK")" "$(pct "$DUCK" "$RAW")" "$(ratio "$DUCK" "$RAW")"
[ "$INNO" -gt 0 ] && printf '%-28s %14s %12s %10s\n' "InnoDB (tpch *.ibd)"         "$(hr "$INNO")" "$(pct "$INNO" "$RAW")" "$(ratio "$INNO" "$RAW")"
[ "$NAT"  -gt 0 ] && printf '%-28s %14s %12s %10s\n' "native DuckDB file"          "$(hr "$NAT")"  "$(pct "$NAT" "$RAW")"  "$(ratio "$NAT" "$RAW")"
echo
echo "Whole datadirs (payload + MySQL system files + logs):"
[ "$DUCK_DIR" -gt 0 ] && printf '  %-26s %14s\n' "DuckDB datadir"  "$(hr "$DUCK_DIR")"
[ "$INNO_DIR" -gt 0 ] && printf '  %-26s %14s\n' "InnoDB datadir"  "$(hr "$INNO_DIR")"
echo

# ---- the headline ratio ------------------------------------------------------
if [ "$DUCK" -gt 0 ] && [ "$INNO" -gt 0 ]; then
  echo "HEADLINE: InnoDB uses $(awk -v i="$INNO" -v d="$DUCK" 'BEGIN{printf "%.2fx", i/d}') the storage of the DuckDB engine"
  echo "          ($(hr "$INNO") vs $(hr "$DUCK") for the same SF$SF dataset)"
  echo
fi

# ---- per-schema DuckDB files -------------------------------------------------
if [ -d "$DUCKDB_DATADIR" ]; then
  echo "-- DuckDB engine: per-schema files --"
  found=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    found=1; printf '  %-40s %14s\n' "${line#* }" "$(hr "${line%% *}")"
  done < <(docker run --rm -v "$DUCKDB_DATADIR":/t:ro "$MEASURE_IMAGE" sh -c \
            "find /t -name '*.duckdb' -type f 2>/dev/null | while read f; do echo \"\$(stat -c%s \"\$f\") \$(basename \"\$f\")\"; done | sort -k2" 2>/dev/null)
  [ "$found" = 0 ] && echo "  (no .duckdb files found - was 02-load.sh ENGINE=duckdb run?)"
  echo "  note: one file per schema; per-table sizes are not separable here."
  echo
fi

# ---- per-table InnoDB tablespaces -------------------------------------------
if [ -d "$INNODB_DATADIR" ]; then
  echo "-- InnoDB: per-table tablespaces (.ibd) --"
  found=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    found=1; printf '  %-40s %14s\n' "${line#* }" "$(hr "${line%% *}")"
  done < <(docker run --rm -v "$INNODB_DATADIR":/t:ro "$MEASURE_IMAGE" sh -c \
            "find /t -path '*tpch*' -name '*.ibd' -type f 2>/dev/null | while read f; do echo \"\$(stat -c%s \"\$f\") \$(basename \"\$f\")\"; done | sort -k2" 2>/dev/null)
  [ "$found" = 0 ] && echo "  (no .ibd files found - was 02-load.sh ENGINE=innodb run?)"
  echo
  # InnoDB overhead that is easy to forget in a comparison:
  redo=$(sum_find "$INNODB_DATADIR" "-name '#ib_redo*' -o -name 'ib_logfile*'")
  undo=$(sum_find "$INNODB_DATADIR" "-name 'undo_*'")
  [ "${redo:-0}" -gt 0 ] && printf '  %-40s %14s\n' "(redo log)" "$(hr "$redo")"
  [ "${undo:-0}" -gt 0 ] && printf '  %-40s %14s\n' "(undo tablespaces)" "$(hr "$undo")"
  echo
fi

echo "-- raw CSV per table --"
for t in $TABLES; do
  f="$DATA_DIR/$t.csv"; [ -s "$f" ] && printf '  %-40s %14s\n' "$t.csv" "$(hr "$(stat -c%s "$f")")"
done
echo
echo "Filesystem free space:"
for p in "$TB_ROOT" "$DATA_DIR" "$TEMP_DIR" "$DUCKDB_DATADIR" "$INNODB_DATADIR"; do
  [ -d "$p" ] && printf '  %-34s %s free\n' "$p" "$(hr "$(free_bytes "$p")")"
done
} | tee "$REPORT"

{ echo "storage_raw_bytes=$RAW"
  echo "storage_duckdb_bytes=$DUCK"
  echo "storage_innodb_bytes=$INNO"
  echo "storage_native_bytes=$NAT"; } >> "$RESULTS_DIR/timings.txt"

log "written: $REPORT"
