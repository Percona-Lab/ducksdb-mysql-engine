#!/usr/bin/env bash
# Build/pull every container image the harness needs.
#   bash bootstrap-images.sh
#   bash bootstrap-images.sh --verify
#   bash bootstrap-images.sh --save DIR    # export for an air-gapped server
#   bash bootstrap-images.sh --load DIR

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"; . "$HERE/lib.sh"

ALL_IMAGES=("$ENGINE_IMAGE" "$DUCKDB_IMAGE" "$GEN_IMAGE" "$REPORT_IMAGE")

show(){
  echo "Image status:"
  for i in "${ALL_IMAGES[@]}"; do
    if docker image inspect "$i" >/dev/null 2>&1; then
      printf '  [ ok ] %-52s %s\n' "$i" "$(docker image inspect -f '{{.Size}}' "$i" | awk '{printf "%.0f MB", $1/1048576}')"
    else
      printf '  [MISS] %-52s\n' "$i"
    fi
  done
}

case "${1:-}" in
  --verify)
    show
    miss=0
    for i in "${ALL_IMAGES[@]}"; do docker image inspect "$i" >/dev/null 2>&1 || miss=$((miss+1)); done
    [ "$miss" -eq 0 ] && { echo; echo "All images present."; exit 0; }
    echo; echo "$miss image(s) missing - run: bash bootstrap-images.sh"; exit 1
    ;;
  --save)
    dir=${2:-./image-bundle}; mkdir -p "$dir" || die "cannot create $dir"
    command -v docker >/dev/null || die "docker not found"
    log "exporting images to $dir (for an air-gapped server) ..."
    for i in "${ALL_IMAGES[@]}"; do
      docker image inspect "$i" >/dev/null 2>&1 || die "$i not present locally - run bootstrap first"
      f="$dir/$(echo "$i" | tr '/:' '__').tar"
      log "  saving $i -> $(basename "$f")"
      docker save "$i" -o "$f" || die "docker save failed for $i"
    done
    log "done. Copy $dir to the server and run: bash bootstrap-images.sh --load $dir"
    du -sh "$dir"
    exit 0
    ;;
  --load)
    dir=${2:-./image-bundle}
    [ -d "$dir" ] || die "no such directory: $dir"
    log "importing images from $dir ..."
    shopt -s nullglob
    found=0
    for f in "$dir"/*.tar; do
      found=1; log "  loading $(basename "$f")"
      docker load -i "$f" >/dev/null || die "docker load failed for $f"
    done
    [ "$found" = 0 ] && die "no .tar files in $dir"
    show; exit 0
    ;;
  ""|--build) ;;
  *) die "unknown option: $1 (see the header for usage)";;
esac

# ---- normal path: pull the engine, build the rest ---------------------------
command -v docker >/dev/null 2>&1 || die "docker not found - install it first"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is $(id -un) in the 'docker' group?)"

log "bootstrapping container images (this takes a few minutes the first time)"
ensure_images          # engine (pull) + duckdb CLI + tpchgen  (see lib.sh)
ensure_report_image    # matplotlib image for the charts

echo
show
echo
echo "Smoke test:"
printf '  duckdb CLI  : '; timeout 60 docker run --rm --entrypoint duckdb "$DUCKDB_IMAGE" --version 2>&1 | head -1
printf '  tpchgen     : '; timeout 60 docker run --rm "$GEN_IMAGE" tpchgen-cli --version 2>&1 | head -1
printf '  matplotlib  : '; timeout 60 docker run --rm "$REPORT_IMAGE" python3 -c "import matplotlib; print('matplotlib', matplotlib.__version__)" 2>&1 | head -1
printf '  engine image: '; docker image inspect -f '{{.Id}}' "$ENGINE_IMAGE" 2>/dev/null | cut -c1-19
echo
echo "All images ready. Next: bash setup.sh"
