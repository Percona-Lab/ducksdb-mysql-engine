#!/usr/bin/env bash
# Collect results into a text report, PNG charts, summary.html and a tar.gz
# bundle. Works on partial results.
#   bash report.sh
#   SF=200 bash report.sh
#   bash report.sh --no-bundle

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"

BUNDLE=1; [ "${1:-}" = "--no-bundle" ] && BUNDLE=0
CHARTS="$RESULTS_DIR/charts"; mkdir -p "$CHARTS"

[ -d "$RESULTS_DIR" ] || die "no results directory at $RESULTS_DIR"

# ---- 1. text report ----------------------------------------------------------
log "building the text report ..."
bash "$HERE/06-compare.sh" >/dev/null 2>&1 || log "  (compare had problems - continuing)"
REPORT="$RESULTS_DIR/REPORT-sf$SF.txt"

# ---- 2. charts ---------------------------------------------------------------
log "rendering charts ..."
ensure_report_image
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$RESULTS_DIR":/results -v "$HERE/charts.py":/charts.py:ro \
  "$REPORT_IMAGE" python3 /charts.py --results /results --sf "$SF" --out /results/charts \
  2>&1 | sed 's/^/  /'

# ---- 3. one-page HTML --------------------------------------------------------
log "writing summary.html ..."
HTML="$RESULTS_DIR/summary.html"
{
  cat <<EOF
<!doctype html><meta charset="utf-8">
<title>TPC-H SF$SF results</title>
<style>
 body{font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;max-width:1200px;margin:2rem auto;padding:0 1rem;color:#222}
 h1{margin-bottom:.2rem} .meta{color:#666;font-size:13px;margin-bottom:2rem}
 img{max-width:100%;height:auto;border:1px solid #ddd;border-radius:6px;margin:.5rem 0 2rem}
 pre{background:#f6f8fa;padding:1rem;border-radius:6px;overflow-x:auto;font-size:12.5px;line-height:1.4}
 h2{margin-top:2.5rem;border-bottom:1px solid #eee;padding-bottom:.3rem}
</style>
<h1>TPC-H SF$SF &mdash; engine comparison</h1>
<div class="meta">generated $(date -u +%FT%TZ) &middot; $(node_cores) cores, $(hr "$(node_ram_bytes)") RAM</div>
EOF
  for c in chart-summary chart-query-times chart-load-time chart-storage; do
    f="$CHARTS/$c.png"
    [ -f "$f" ] && printf '<h2>%s</h2>\n<img src="charts/%s.png" alt="%s">\n' \
      "$(echo "$c" | sed 's/chart-//; s/-/ /g')" "$c" "$c"
  done
  echo '<h2>Full report</h2><pre>'
  [ -f "$REPORT" ] && sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$REPORT"
  echo '</pre>'
} > "$HTML"

# ---- 4. bundle ---------------------------------------------------------------
if [ "$BUNDLE" = 1 ]; then
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  TARBALL="$RESULTS_DIR/tpch-results-sf$SF-$ts.tar.gz"
  log "bundling results ..."
  # Exclude the per-query result sets: at SF1000 a few of them are large and
  # they are only needed for the correctness diff, which is already summarised.
  tar czf "$TARBALL" -C "$RESULTS_DIR" \
    --exclude='queries-*/q*.out' \
    --exclude='*.tar.gz' \
    . 2>/dev/null || log "  (tar reported problems - check $TARBALL)"
  log "bundle: $TARBALL ($(hr "$(stat -c%s "$TARBALL" 2>/dev/null || echo 0)"))"
fi

echo
echo "=============================================================="
echo " Results for SF$SF"
echo "=============================================================="
[ -f "$REPORT" ] && sed -n '/AXIS 1/,/^$/p;/AXIS 3/,/^$/p' "$REPORT" | head -30
echo
echo " Text report : $REPORT"
echo " Charts      : $CHARTS/"
ls -1 "$CHARTS" 2>/dev/null | sed 's/^/               /'
echo " HTML        : $HTML"
[ "$BUNDLE" = 1 ] && echo " Bundle      : ${TARBALL:-}"
echo
echo " Copy the bundle to your laptop with:"
echo "   scp <server>:${TARBALL:-$RESULTS_DIR/tpch-results-*.tar.gz} ."
echo "=============================================================="
