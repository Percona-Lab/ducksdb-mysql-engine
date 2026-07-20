#!/usr/bin/env bash
# Assemble the three-axis report (load time, storage, query time) plus the
# correctness diff. Works on partial results.
#   bash 06-compare.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"

REPORT="$RESULTS_DIR/REPORT-sf$SF.txt"
T="$RESULTS_DIR/timings.txt"
getv(){ [ -f "$T" ] && grep -E "^$1=" "$T" | tail -1 | cut -d= -f2 || true; }
secs_hr(){ awk -v s="${1:-0}" 'BEGIN{ if(s<=0){print "-"; exit}
  h=int(s/3600); m=int((s%3600)/60); sec=s%60;
  if(h>0) printf "%dh%02dm", h, m; else if(m>0) printf "%dm%02ds", m, sec; else printf "%ds", sec }'; }

{
echo "================================================================="
echo " TPC-H SF$SF — engine comparison report"
echo " generated $(date -u +%FT%TZ)   node: $(node_cores) cores, $(hr "$(node_ram_bytes)") RAM"
echo "================================================================="
echo

# ---------------- axis 1: load time ----------------
echo "-- AXIS 1: LOAD TIME ----------------------------------------------"
ld=$(getv load_duckdb_seconds); li=$(getv load_innodb_seconds); ln=$(getv load_native_seconds)
printf '  %-30s %12s\n' "ENGINE=DuckDB (COPY fast path)" "$(secs_hr "$ld")"
printf '  %-30s %12s\n' "InnoDB (bulk LOAD DATA)"        "$(secs_hr "$li")"
printf '  %-30s %12s\n' "native DuckDB"                  "$(secs_hr "$ln")"
if [ -n "$ld" ] && [ -n "$li" ] && [ "${ld:-0}" -gt 0 ]; then
  echo
  printf '  => InnoDB took %s the DuckDB engine load time\n' \
    "$(awk -v i="$li" -v d="$ld" 'BEGIN{printf "%.2fx", i/d}')"
fi
echo

# ---------------- axis 3: storage ----------------
echo "-- AXIS 3: STORAGE ------------------------------------------------"
sraw=$(getv storage_raw_bytes); sd=$(getv storage_duckdb_bytes)
si=$(getv storage_innodb_bytes); sn=$(getv storage_native_bytes)
if [ -n "$sraw" ]; then
  printf '  %-30s %12s\n' "raw CSV"                "$(hr "${sraw:-0}")"
  [ "${sd:-0}" -gt 0 ] && printf '  %-30s %12s  (%s of raw)\n' "ENGINE=DuckDB datadir" "$(hr "$sd")" "$(awk -v a="$sd" -v b="$sraw" 'BEGIN{printf "%.0f%%", a*100/b}')"
  [ "${si:-0}" -gt 0 ] && printf '  %-30s %12s  (%s of raw)\n' "InnoDB datadir"        "$(hr "$si")" "$(awk -v a="$si" -v b="$sraw" 'BEGIN{printf "%.0f%%", a*100/b}')"
  [ "${sn:-0}" -gt 0 ] && printf '  %-30s %12s  (%s of raw)\n' "native DuckDB file"    "$(hr "$sn")" "$(awk -v a="$sn" -v b="$sraw" 'BEGIN{printf "%.0f%%", a*100/b}')"
  if [ "${sd:-0}" -gt 0 ] && [ "${si:-0}" -gt 0 ]; then
    echo
    printf '  => InnoDB uses %s the storage of the DuckDB engine\n' \
      "$(awk -v i="$si" -v d="$sd" 'BEGIN{printf "%.2fx", i/d}')"
  fi
else
  echo "  (not measured - run 03-storage.sh)"
fi
echo

# ---------------- axis 2: query time ----------------
echo "-- AXIS 2: QUERY TIME ---------------------------------------------"
qt(){ # $1=engine $2=qnum -> value or empty
  local f
  f="$RESULTS_DIR/queries-$1-sf$SF/$(printf 'q%02d' "$2").time"
  [ -f "$f" ] && cat "$f" || echo ""; }
engines=""
for e in innodb duckdb native; do
  [ -d "$RESULTS_DIR/queries-$e-sf$SF" ] && engines="$engines $e"
done
if [ -z "$engines" ]; then
  echo "  (no query runs found - run 04-query.sh)"
else
  printf '  %-6s' "Q"
  for e in $engines; do printf ' %14s' "$e"; done; printf '\n'
  printf '  %-6s' "------"
  for e in $engines; do printf ' %14s' "--------------"; done; printf '\n'
  declare -A sums; for e in $engines; do sums[$e]=0; done
  for n in $(seq 1 22); do
    printf '  %-6s' "Q$n"
    for e in $engines; do
      v=$(qt "$e" "$n"); [ -z "$v" ] && v="-"
      printf ' %14s' "$v"
      case "$v" in ''|-|DNF|ERR) ;; *) sums[$e]=$(awk -v a="${sums[$e]}" -v b="$v" 'BEGIN{print a+b}');; esac
    done
    printf '\n'
  done
  printf '  %-6s' "SUM"
  for e in $engines; do printf ' %14s' "$(awk -v s="${sums[$e]}" 'BEGIN{printf "%.1f", s}')"; done; printf '\n'
  echo
  for e in $engines; do
    dnf=0; err=0; fin=0
    for n in $(seq 1 22); do
      v=$(qt "$e" "$n")
      case "$v" in "") ;; DNF) dnf=$((dnf+1));; ERR) err=$((err+1));; *) fin=$((fin+1));; esac
    done
    printf '  %-8s finished %2d/22, DNF %d, ERR %d\n' "$e:" "$fin" "$dnf" "$err"
  done
  echo "  (SUM covers only finished queries - a DNF is excluded, so a small SUM"
  echo "   next to a large DNF count means the engine mostly did not finish.)"
fi
echo

# ---------------- correctness ----------------
echo "-- CORRECTNESS: DuckDB engine vs native DuckDB ---------------------"
de="$RESULTS_DIR/queries-duckdb-sf$SF"; na="$RESULTS_DIR/queries-native-sf$SF"
if [ -d "$de" ] && [ -d "$na" ]; then
  match=0; mismatch=0; skipped=0
  for n in $(seq 1 22); do
    q=$(printf 'q%02d' "$n")
    a="$de/$q.out"; b="$na/$q.out"
    if [ -s "$a" ] && [ -s "$b" ]; then
      ha=$(md5sum < "$a" | awk '{print $1}'); hb=$(md5sum < "$b" | awk '{print $1}')
      if [ "$ha" = "$hb" ]; then match=$((match+1))
      else mismatch=$((mismatch+1)); echo "  Q$n MISMATCH  engine=$ha native=$hb"; fi
    else skipped=$((skipped+1)); fi
  done
  echo "  MATCH=$match  MISMATCH=$mismatch  skipped=$skipped  of 22"
  echo "  (numbers normalised to 4 dp before hashing, order-independent)"
else
  echo "  (need both ENGINE=duckdb and ENGINE=native query runs)"
fi
echo
echo "Raw artifacts: $RESULTS_DIR"
echo "================================================================="
} | tee "$REPORT"

log "written: $REPORT"
