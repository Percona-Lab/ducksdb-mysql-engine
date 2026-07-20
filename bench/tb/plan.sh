#!/usr/bin/env bash
# What fits on this node? Prints per-strategy disk needs and a recommended plan.
# Read-only, no side effects.
#   bash plan.sh
#   FREE_GB=1800 RAM_GB=180 bash plan.sh    # model a node you don't have yet

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"

FREE_GB=${FREE_GB:-$(( $(free_bytes "$TB_ROOT") /1024/1024/1024 ))}
RAM_GB=${RAM_GB:-$(( $(node_ram_bytes) /1024/1024/1024 ))}
CORES=${CORES:-$(node_cores)}
CHUNK_GB=${CHUNK_GB:-20}
[ "$FREE_GB" -le 0 ] && FREE_GB=${FREE_GB_FALLBACK:-1800}

# GB per SF unit
G_CSV=1.00; G_DUCK=0.30; G_INNO=1.80
# Spill scales with data but is bounded by how much RAM you have to work with:
# the less RAM, the more of each query's working set lands on disk.
spill_gb(){ awk -v sf="$1" -v ram="$RAM_GB" 'BEGIN{
  s = sf*0.50; cap = ram*4; if (s>cap) s=cap; if (s<20) s=20; printf "%.0f", s }'; }

f(){ awk -v a="$1" 'BEGIN{printf "%.0f", a}'; }
# Require real headroom: filling a disk to 100% during a 20-hour load is how you
# lose the whole run. RESERVE_PCT of free space is held back.
RESERVE_PCT=${RESERVE_PCT:-12}
USABLE_GB=$(awk -v f="$FREE_GB" -v r="$RESERVE_PCT" 'BEGIN{printf "%.0f", f*(100-r)/100}')
fits(){
  local need; need=$(f "$1")
  if   [ "$need" -le "$USABLE_GB" ]; then echo "FITS"
  elif [ "$need" -le "$FREE_GB" ];   then echo "TIGHT"
  else echo "TOO BIG"; fi
}

echo "================================================================="
echo " Capacity plan"
echo "   free disk : ${FREE_GB} GB  (usable ${USABLE_GB} GB after a ${RESERVE_PCT}% reserve)"
echo "   RAM       : ${RAM_GB} GB"
echo "   cores     : ${CORES}"
echo "================================================================="
echo
echo " FITS = fits with headroom | TIGHT = fits only by filling the disk | TOO BIG"
echo
echo "Per-SF-unit footprint: CSV ${G_CSV} GB | DuckDB ${G_DUCK} GB | InnoDB ${G_INNO} GB"
echo "Streaming (01-stream-load.sh) replaces the full CSV with ONE ~${CHUNK_GB} GB chunk."
echo

# ---- strategy table ----------------------------------------------------------
printf '%-46s %10s %9s\n' "strategy" "needs GB" "verdict"
printf '%-46s %10s %9s\n' "----------------------------------------------" "----------" "---------"

for sf in 100 200 500 1000; do
  sp=$(spill_gb "$sf")
  bulk=$(awk -v sf="$sf" -v c="$G_CSV" -v d="$G_DUCK" -v s="$sp" 'BEGIN{print sf*c + sf*d + s}')
  strm=$(awk -v sf="$sf" -v d="$G_DUCK" -v s="$sp" -v k="$CHUNK_GB" 'BEGIN{print sf*d + s + k*2}')
  strm_i=$(awk -v sf="$sf" -v d="$G_DUCK" -v i="$G_INNO" -v s="$sp" -v k="$CHUNK_GB" 'BEGIN{print sf*d + sf*i + s + k*2}')
  printf '%-46s %10s %9s\n' "SF$sf  DuckDB, bulk CSV (01-generate + 02-load)" "$(f "$bulk")" "$(fits "$bulk")"
  printf '%-46s %10s %9s\n' "SF$sf  DuckDB, STREAMED + native attach"        "$(f "$strm")" "$(fits "$strm")"
  printf '%-46s %10s %9s\n' "SF$sf  + InnoDB too (streamed)"                 "$(f "$strm_i")" "$(fits "$strm_i")"
  echo
done

# ---- max feasible SF ---------------------------------------------------------
max_sf(){ # $1=per-sf GB (data only), $2=fixed overhead GB -> largest SF that fits
  # Spill is bounded by RAM (~4x), so treat it as a fixed ceiling rather than a
  # per-SF term - otherwise the estimate is pessimistic at large SF.
  awk -v free="$USABLE_GB" -v per="$1" -v fx="$2" -v ram="$RAM_GB" 'BEGIN{
    spill=ram*4; s=int((free-fx-spill)/per); if(s<0)s=0; print s }'; }
sp1000=$(spill_gb 1000)
echo "Largest scale factor that fits (streamed, native attached):"
printf "  DuckDB only ............ SF~%s\n" "$(max_sf "$G_DUCK" "$((CHUNK_GB*2))")"
printf '  DuckDB + InnoDB ........ SF~%s\n' "$(max_sf "$(awk -v d=$G_DUCK -v i=$G_INNO 'BEGIN{print d+i}')" "$((CHUNK_GB*2))")"
echo "  (the InnoDB number is disk-feasible only - its QUERIES will not finish"
echo "   anywhere near that scale; see the recommendation below.)"
echo

# ---- recommendation ----------------------------------------------------------
echo "================================================================="
echo " RECOMMENDED PLAN for ${FREE_GB} GB / ${RAM_GB} GB RAM"
echo "================================================================="
rec_duck=$(awk -v d=$G_DUCK -v s="$sp1000" -v k="$CHUNK_GB" 'BEGIN{print 1000*d + s + k*2}')
if [ "$(f "$rec_duck")" -le "$USABLE_GB" ]; then
cat <<EOF

 PHASE 1 - the headline 1 TB result (DuckDB engine at SF1000)
   Streamed load; the CSV never fully lands on disk. Native leg attaches the
   engine's own file, so it costs no extra space.

     ENGINE=duckdb CHUNK_GB=$CHUNK_GB bash 01-stream-load.sh
     ENGINE=duckdb bash 04-query.sh
     ENGINE=native bash 04-query.sh          # NATIVE_MODE=attach (default)
     bash 03-storage.sh

   Footprint: ~$(f "$rec_duck") GB peak  (DuckDB data $(f "$(awk 'BEGIN{print 1000*0.30}')") GB + spill ~${sp1000} GB + chunk)
   Leaves ~$(( FREE_GB - $(f "$rec_duck") )) GB headroom.

 PHASE 2 - the 3-axis InnoDB comparison, at a scale InnoDB can actually finish
   InnoDB needs ~$(f "$(awk -v i=$G_INNO 'BEGIN{print 1000*i}')") GB at SF1000 - it cannot coexist with Phase 1 on
   this disk, and its queries would not complete anyway. Run it at SF100-200:

     SF=200 ENGINE=innodb CHUNK_GB=$CHUNK_GB bash 01-stream-load.sh
     SF=200 ENGINE=duckdb CHUNK_GB=$CHUNK_GB bash 01-stream-load.sh
     SF=200 ENGINE=innodb bash 04-query.sh
     SF=200 ENGINE=duckdb bash 04-query.sh
     SF=200 bash 03-storage.sh && SF=200 bash 06-compare.sh

   Footprint at SF200: ~$(f "$(awk -v d=$G_DUCK -v i=$G_INNO -v k="$CHUNK_GB" 'BEGIN{print 200*(d+i) + 100 + k*2}')") GB. Delete the SF200 datadirs when done.

 NOTE ON ${RAM_GB} GB RAM AT SF1000
   SF1000 is ~5.5x your RAM, so DuckDB will spill hard on the big joins
   (Q9, Q18, Q21, Q15). That is a legitimate larger-than-memory result, but
   expect long query times and put TEMP_DIR on your fastest NVMe. Budget
   ~${sp1000} GB of spill and keep QTIMEOUT generous.
EOF
else
cat <<EOF

 SF1000 does not fit even streamed (~$(f "$rec_duck") GB needed, ${FREE_GB} GB free).
 Drop to the largest SF that fits, or free up space. Re-run:
     FREE_GB=<new> bash plan.sh
EOF
fi
echo
echo " Always validate first:  SF=1 bash run-all.sh"
echo "================================================================="
