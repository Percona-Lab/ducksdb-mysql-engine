#!/usr/bin/env bash
# Package the harness for copying to a remote server. Excludes results, state,
# generated data and tb.env.
#   bash make-archive.sh
#   OUT=/tmp/x.tar.gz bash make-archive.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-"$(cd "$HERE/.." && pwd)/tpch-tb-harness.tar.gz"}

cd "$HERE/.." || exit 1
rm -f "$OUT"
tar czf "$OUT" \
  --exclude='tb/results' \
  --exclude='tb/state' \
  --exclude='tb/data-sf*' \
  --exclude='tb/tb.env' \
  --exclude='tb/image-bundle' \
  --exclude='tb/*.tar.gz' \
  tb/ || { echo "tar failed" >&2; exit 1; }

echo "archive: $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "contents:"
tar tzf "$OUT" | sed 's/^/  /'
echo
echo "Copy it over with:"
echo "  scp $OUT <user>@<server>:~/"
echo "Then on the server:"
echo "  tar xzf $(basename "$OUT") && cd tb && bash bootstrap-images.sh"
