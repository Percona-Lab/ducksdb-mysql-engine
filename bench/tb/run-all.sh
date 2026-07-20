#!/usr/bin/env bash
# Orchestrate the phases in dependency order, skipping completed ones.
# Safe to re-run after an interruption.
#   bash run-all.sh
#   SF=1 bash run-all.sh                  # end-to-end validation in minutes
#   LEGS="duckdb native" bash run-all.sh
# STREAM=auto materialises the full CSV set only when it comfortably fits.

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"

LEGS=${LEGS:-"duckdb innodb native"}
SKIP_INNODB_QUERIES=${SKIP_INNODB_QUERIES:-1}   # default: do NOT query InnoDB at full SF
START=$(date +%s)

# STREAM=auto: materialise the whole CSV set only when it comfortably fits
# (<25% of free space). Otherwise stream generate->load->delete per chunk, which
# is what makes SF1000 possible on a 1.8 TB disk. Bulk is preferred when it fits
# because one generation pass then feeds every engine.
STREAM=${STREAM:-auto}
if [ "$STREAM" = auto ]; then
  _free_gb=$(( $(free_bytes "$TB_ROOT") /1024/1024/1024 ))
  # SF may be fractional (e.g. SF=0.01 for a smoke test), so compare in awk -
  # [ ] would fail with "integer expression expected".
  STREAM=$(awk -v sf="$SF" -v free="$_free_gb" 'BEGIN{ print (free>0 && sf > free/4) ? 1 : 0 }')
fi
log "mode: $([ "$STREAM" = 1 ] && echo 'STREAMED (generate->load->delete per chunk)' || echo 'bulk CSV (generate once, load each engine)')"
banner(){ echo; echo "############################################################"; echo "# $*"; echo "############################################################"; }
phase(){ # phase <marker> <description> <command...>
  local marker="$1" desc="$2"; shift 2
  if is_done "$marker"; then log "SKIP  $desc (already done; FORCE=1 to redo)"; return 0; fi
  banner "$desc"
  "$@" || die "phase failed: $desc"
}

banner "TPC-H terabyte harness  SF=$SF  legs='$LEGS'  root=$TB_ROOT"

# 0. preflight (always runs - cheap, and the node may have changed)
banner "preflight"
LEGS="$LEGS" bash "$HERE/00-preflight.sh" || die "preflight failed - fix the issues above or set STRICT=0"

banner "bootstrap container images"
. "$HERE/lib.sh"; ensure_images

# 1. generate (bulk mode only - streaming generates inline, per chunk)
[ "$STREAM" = 0 ] && phase "generate-sf$SF" "generate SF$SF dataset" bash "$HERE/01-generate.sh"

# 2. DuckDB engine: load -> query
case " $LEGS " in *" duckdb "*)
  if [ "$STREAM" = 1 ]; then
    phase "load-duckdb-sf$SF" "stream generate+load ENGINE=DuckDB" env ENGINE=duckdb bash "$HERE/01-stream-load.sh"
  else
    phase "load-duckdb-sf$SF" "load ENGINE=DuckDB" env ENGINE=duckdb bash "$HERE/02-load.sh"
  fi
  phase "query-duckdb-sf$SF" "query ENGINE=DuckDB" env ENGINE=duckdb bash "$HERE/04-query.sh"
;; esac

# 3. native DuckDB: build -> query (correctness oracle + ceiling)
case " $LEGS " in *" native "*)
  phase "native-sf$SF" "build native DuckDB reference" bash "$HERE/05-native-duckdb.sh"
  phase "query-native-sf$SF" "query native DuckDB" env ENGINE=native bash "$HERE/04-query.sh"
;; esac

# 4. InnoDB: load (always worth it - axis 1 + axis 3), query only if asked
case " $LEGS " in *" innodb "*)
  # Disk sanity: InnoDB needs ~1.8 GB per SF unit. Refuse rather than fill the
  # disk 14 hours into a load.
  _need=$(awk -v sf="$SF" 'BEGIN{printf "%.0f", sf*1.8}')
  _free=$(( $(free_bytes "$TB_ROOT") /1024/1024/1024 ))
  if [ "$_free" -gt 0 ] && [ "$_need" -gt "$_free" ]; then
    log "SKIP  InnoDB: needs ~${_need} GB but only ${_free} GB free."
    log "      Run the InnoDB comparison at a smaller scale, e.g.:"
    log "        SF=200 LEGS='duckdb innodb' SKIP_INNODB_QUERIES=0 bash run-all.sh"
  else
    if [ "$STREAM" = 1 ]; then
      phase "load-innodb-sf$SF" "stream generate+load InnoDB (long pole)" env ENGINE=innodb bash "$HERE/01-stream-load.sh"
    else
      phase "load-innodb-sf$SF" "load InnoDB (long pole)" env ENGINE=innodb bash "$HERE/02-load.sh"
    fi
    if [ "$SKIP_INNODB_QUERIES" = 1 ]; then
      log "SKIP  InnoDB query run at SF$SF (SKIP_INNODB_QUERIES=1)."
      log "      Run the InnoDB query comparison as its own smaller pipeline, e.g.:"
      log "        SF=$SF_INNODB_QUERIES LEGS='duckdb innodb native' SKIP_INNODB_QUERIES=0 bash run-all.sh"
    else
      phase "query-innodb-sf$SF" "query InnoDB" env ENGINE=innodb bash "$HERE/04-query.sh"
    fi
  fi
;; esac

# 5. storage + report
banner "measure storage"
bash "$HERE/03-storage.sh" || log "storage measurement had problems (continuing)"
banner "final report"
bash "$HERE/06-compare.sh" || log "report generation had problems"

END=$(date +%s)
banner "DONE in $(awk -v s=$((END-START)) 'BEGIN{printf "%dh%02dm", s/3600, (s%3600)/60}')"
echo "Report:    $RESULTS_DIR/REPORT-sf$SF.txt"
echo "Artifacts: $RESULTS_DIR"
echo
echo "Optional, separate experiment (small scale, not part of the 1 TB run):"
echo "  bash $HERE/07-replication-spike.sh"
