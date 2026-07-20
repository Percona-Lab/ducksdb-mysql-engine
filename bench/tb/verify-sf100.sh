#!/usr/bin/env bash
# SF100 three-way verification: InnoDB vs ENGINE=DuckDB vs native DuckDB on load
# time, query time and storage, plus a memory A/B on Q15.
#
# The Q15 A/B answers whether the 1309s SF100 result was caused by the
# DUCKSDB_MEMORY_LIMIT cap or by the CTE defect fixed in server patch 0004. It
# re-runs Q15 alone under the ORIGINAL cap; if it is fast there, memory was not
# the cause.
#
#   bash verify-sf100.sh
#   INNODB_QTIMEOUT=900 bash verify-sf100.sh     # tighter cap, faster run
#   SKIP_INNODB=1 bash verify-sf100.sh           # DuckDB + native only
#
# Resumable: every phase is checkpointed, so a re-run continues where it stopped.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export SF=${SF:-100}
. "$HERE/config.sh"; . "$HERE/lib.sh"

INNODB_QTIMEOUT=${INNODB_QTIMEOUT:-1800}   # per-query cap for the InnoDB leg
CAP_MEM=${CAP_MEM:-28GB}                   # the original SF100 memory cap
SKIP_INNODB=${SKIP_INNODB:-0}
CAP_RESULTS="$TB_ROOT/results-q15cap"      # kept apart so it cannot clobber

banner(){ echo; echo "############################################################"; echo "# $*"; echo "############################################################"; }
phase(){ local m="$1" d="$2"; shift 2
  if is_done "$m"; then log "SKIP  $d"; return 0; fi
  banner "$d"; "$@" || die "phase failed: $d"; }

banner "SF$SF verification   root=$TB_ROOT   innodb cap=${INNODB_QTIMEOUT}s"
echo "Expect roughly: generate ~30m, DuckDB load ~45m, InnoDB load ~3-5h,"
echo "DuckDB+native queries ~20m, InnoDB queries ~$((22*INNODB_QTIMEOUT/3600))h worst case."
echo

bash "$HERE/00-preflight.sh" || die "preflight failed (STRICT=0 to override)"
ensure_images

phase "generate-sf$SF"      "generate SF$SF"        bash "$HERE/01-generate.sh"
phase "load-duckdb-sf$SF"   "load ENGINE=DuckDB"    env ENGINE=duckdb bash "$HERE/02-load.sh"
phase "query-duckdb-sf$SF"  "query ENGINE=DuckDB"   env ENGINE=duckdb bash "$HERE/04-query.sh"
phase "native-sf$SF"        "native reference"      bash "$HERE/05-native-duckdb.sh"
phase "query-native-sf$SF"  "query native DuckDB"   env ENGINE=native bash "$HERE/04-query.sh"

# Q15 alone under the original memory cap, into a separate results dir.
if ! is_done "q15cap-sf$SF"; then
  banner "Q15 under the original ${CAP_MEM} cap (memory A/B)"
  mkdir -p "$CAP_RESULTS"
  env ENGINE=duckdb QUERY_SEQ=15 DUCK_MEM="$CAP_MEM" FORCE=1 \
      RESULTS_DIR="$CAP_RESULTS" bash "$HERE/04-query.sh" \
    && mark_done "q15cap-sf$SF" || log "capped Q15 run had problems (continuing)"
fi

if [ "$SKIP_INNODB" != 1 ]; then
  phase "load-innodb-sf$SF"  "load InnoDB (long pole)" env ENGINE=innodb bash "$HERE/02-load.sh"
  phase "query-innodb-sf$SF" "query InnoDB (capped)" \
        env ENGINE=innodb QTIMEOUT_INNODB="$INNODB_QTIMEOUT" bash "$HERE/04-query.sh"
fi

banner "storage + report"
bash "$HERE/03-storage.sh" >/dev/null 2>&1 || log "storage measurement had problems"
bash "$HERE/06-compare.sh" >/dev/null 2>&1 || log "compare had problems"
bash "$HERE/report.sh" --no-bundle >/dev/null 2>&1 || log "report had problems"

# ---- verdict -----------------------------------------------------------------
T="$RESULTS_DIR/timings.txt"
getv(){ [ -f "$T" ] && grep -E "^$1=" "$T" | tail -1 | cut -d= -f2 || true; }
qt(){ local f; f="$RESULTS_DIR/queries-$1-sf$SF/q$(printf '%02d' "$2").time"
      [ -f "$f" ] && cat "$f" || echo "-"; }
hrs(){ awk -v s="${1:-0}" 'BEGIN{ if(s<=0){print "-";exit} printf "%dh%02dm", s/3600, (s%3600)/60 }'; }

banner "VERDICT"
echo "-- AXIS 1: LOAD TIME --"
printf '  %-24s %s\n' "ENGINE=DuckDB" "$(hrs "$(getv load_duckdb_seconds)")"
printf '  %-24s %s\n' "InnoDB"        "$(hrs "$(getv load_innodb_seconds)")"

echo; echo "-- AXIS 3: STORAGE --"
for k in raw duckdb innodb; do
  v=$(getv storage_${k}_bytes)
  [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && printf '  %-24s %s\n' "$k" "$(hr "$v")"
done
d=$(getv storage_duckdb_bytes); i=$(getv storage_innodb_bytes)
[ -n "$d" ] && [ -n "$i" ] && [ "$d" -gt 0 ] 2>/dev/null && [ "$i" -gt 0 ] 2>/dev/null && \
  awk -v a="$i" -v b="$d" 'BEGIN{printf "  => InnoDB uses %.2fx the DuckDB engine storage\n", a/b}'

echo; echo "-- AXIS 2: QUERY TIME --"
printf '  %-6s %12s %12s %12s\n' "Q" "innodb" "duckdb" "native"
dnf=0; fin=0
for n in $(seq 1 22); do
  a=$(qt innodb "$n")
  printf '  %-6s %12s %12s %12s\n' "Q$n" "$a" "$(qt duckdb "$n")" "$(qt native "$n")"
  case "$a" in DNF|ERR) dnf=$((dnf+1));; -) ;; *) fin=$((fin+1));; esac
done
[ "$((fin+dnf))" -gt 0 ] && printf '  InnoDB finished %d/22, DNF %d (cap %ss)\n' "$fin" "$dnf" "$INNODB_QTIMEOUT"

echo; echo "-- Q15 MEMORY A/B --"
q15_free=$(qt duckdb 15)
q15_cap="-"; f="$CAP_RESULTS/queries-duckdb-sf$SF/q15.time"; [ -f "$f" ] && q15_cap=$(cat "$f")
printf '  Q15, auto memory (%s):  %s s\n' "${DUCK_MEM:-auto}" "$q15_free"
printf '  Q15, capped at %-8s %s s\n' "$CAP_MEM:" "$q15_cap"
printf '  (the previously published SF100 figure was 1309 s)\n'
case "$q15_cap" in
  -|DNF|ERR) echo "  INCONCLUSIVE - the capped run did not produce a time";;
  *) awk -v c="$q15_cap" 'BEGIN{
       if (c+0 < 60)
         print "  => FAST even under the original cap: memory was NOT the cause.\n     The 1309 s figure is explained by the CTE defect fixed in patch 0004,\n     so the \"~4 s with matched memory\" claim needs correcting.";
       else
         print "  => STILL SLOW under the cap: memory pressure was a real factor;\n     the published explanation stands, with 0004 as a separate win." }';;
esac
echo
echo "Artifacts: $RESULTS_DIR   (capped Q15: $CAP_RESULTS)"
