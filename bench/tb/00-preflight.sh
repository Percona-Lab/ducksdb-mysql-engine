#!/usr/bin/env bash
# Validate the node before a long run: CPU/RAM/disk/Docker/images/kernel limits.
# Exits non-zero if the run cannot fit (STRICT=0 to warn instead).
#   bash 00-preflight.sh
#   LEGS="duckdb native" SF=100 bash 00-preflight.sh

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"

LEGS=${LEGS:-"duckdb innodb native"}
STRICT=${STRICT:-1}          # STRICT=0 -> warn instead of failing
fail=0
warn(){ printf '  [WARN] %s\n' "$*"; }
bad(){  printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
ok(){   printf '  [ ok ] %s\n' "$*"; }

echo "=============================================================="
echo " TPC-H terabyte-scale preflight   SF=$SF   legs: $LEGS"
echo "=============================================================="

# ---- 1. Docker ---------------------------------------------------------------
echo; echo "[1/6] container runtime"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then ok "docker usable ($(docker --version | cut -d, -f1))"
  else bad "docker present but not usable by $(id -un) - add the user to the 'docker' group or use sudo"; fi
else bad "docker not found - this harness runs everything in containers"; fi

# ---- 2. CPU / RAM ------------------------------------------------------------
echo; echo "[2/6] cpu & memory"
CORES=$(node_cores); RAM=$(node_ram_bytes)
ok "cores: $CORES"
ok "RAM:   $(hr "$RAM")"
[ "$CORES" -lt 8 ]  && warn "only $CORES cores - a 1 TB run will be painfully slow"
if [ "$RAM" -lt $((64*1024*1024*1024)) ]; then
  bad "RAM $(hr "$RAM") is below the 64 GiB practical floor for SF$SF"
elif [ "$RAM" -lt $((256*1024*1024*1024)) ]; then
  warn "RAM $(hr "$RAM"): workable but DuckDB will spill heavily at SF1000. Make sure TEMP_DIR is fast and large."
fi
resolve_sizing
ok "derived: CPUS=$CPUS  MEM=$MEM  DUCK_MEM=$DUCK_MEM  INNODB_POOL=$INNODB_POOL"
echo "         (DUCK_MEM is deliberately below MEM so a heavy query spills to"
echo "          disk instead of the kernel OOM-killing mysqld.)"

# ---- 3. Disk ----------------------------------------------------------------
# Per-SF-unit estimates (SF1 ~= 1 GB of raw CSV), from the SF100 measurements.
echo; echo "[3/6] disk capacity"
est_gb(){ awk -v sf="$SF" -v p="$1" 'BEGIN{v=sf*p; printf (v<10 ? "%.1f" : "%.0f"), v}'; }
est_int(){ awk -v sf="$SF" -v p="$1" 'BEGIN{printf "%.0f", sf*p}'; }
RAW_GB=$(est_gb 1.0); DUCK_GB=$(est_gb 0.30); INNO_GB=$(est_gb 1.80); TMP_GB=$(est_gb 0.50)
NAT_GB=$DUCK_GB
# integer copies for the arithmetic below (est_gb may return a decimal)
RAW_I=$(est_int 1.0); DUCK_I=$(est_int 0.30); INNO_I=$(est_int 1.80); TMP_I=$(est_int 0.50)
NAT_I=$DUCK_I

# Match the ACTUAL run's footprint, exactly as run-all.sh and plan.sh do:
#  - STREAM=auto materialises only one chunk at a time when the CSV set would
#    exceed 25% of free space, so the generated-CSV cost is ~CHUNK_GB, not full SF.
#  - NATIVE_MODE=attach reuses the engine's own file, so the native leg is 0 GB.
# Without this, preflight summed the naive footprint (full CSV + a native copy)
# and failed runs that genuinely fit.
root_free_gb=$(( $(free_bytes "$TB_ROOT") /1024/1024/1024 ))
_stream=${STREAM:-auto}
if [ "$_stream" = auto ]; then
  _stream=$(awk -v sf="$SF" -v free="$root_free_gb" 'BEGIN{ print (free>0 && sf > free/4) ? 1 : 0 }')
fi
CHUNK_GB=${CHUNK_GB:-20}

if [ "$_stream" = 1 ]; then
  RAW_SHOW="$((CHUNK_GB*2)) (streamed; peak one chunk)"; RAW_I=$((CHUNK_GB*2))
else
  RAW_SHOW="$RAW_GB (full CSV)"
fi
need_gb=$RAW_I
printf '  generated CSV            ~%6s GB\n' "$RAW_SHOW"
case " $LEGS " in *" duckdb "*) printf '  ENGINE=DuckDB datadir    ~%6s GB\n' "$DUCK_GB"; need_gb=$((need_gb+DUCK_I));; esac
case " $LEGS " in *" native "*)
  if [ "${NATIVE_MODE:-attach}" = attach ]; then
    printf '  native DuckDB (attach)   ~%6s GB\n' "0"
  else
    printf '  native DuckDB file       ~%6s GB\n' "$NAT_GB"; need_gb=$((need_gb+NAT_I))
  fi;;
esac
case " $LEGS " in *" innodb "*) printf '  InnoDB datadir           ~%6s GB\n' "$INNO_GB"; need_gb=$((need_gb+INNO_I));; esac
printf '  DuckDB spill / temp      ~%6s GB\n' "$TMP_GB"; need_gb=$((need_gb+TMP_I))
printf '  ----------------------------------\n'
printf '  TOTAL estimated need     ~%6s GB\n' "$need_gb"

# Check each distinct filesystem once.
declare -A seen
for pair in "TB_ROOT:$TB_ROOT" "DATA_DIR:$DATA_DIR" "TEMP_DIR:$TEMP_DIR" \
            "DUCKDB_DATADIR:$DUCKDB_DATADIR" "INNODB_DATADIR:$INNODB_DATADIR"; do
  name=${pair%%:*}; path=${pair#*:}
  mkdir -p "$path" 2>/dev/null || { bad "cannot create $name at $path"; continue; }
  fs=$(df -P "$path" 2>/dev/null | awk 'NR==2{print $6}')
  [ -n "${seen[$fs]:-}" ] && continue
  seen[$fs]=1
  freeb=$(free_bytes "$path")
  printf '  %-16s %-28s free %s on %s\n' "$name" "$path" "$(hr "$freeb")" "$fs"
done

# The binding constraint is the filesystem holding TB_ROOT (unless split out).
root_free_gb=$(( $(free_bytes "$TB_ROOT") /1024/1024/1024 ))
if [ "$root_free_gb" -lt "$need_gb" ]; then
  bad "free space on $TB_ROOT is ${root_free_gb} GB but the run needs ~${need_gb} GB"
  echo "         -> point TB_ROOT/DATA_DIR/INNODB_DATADIR at bigger disks, or drop a leg"
  echo "            e.g. LEGS=\"duckdb native\" (skips the ~${INNO_GB} GB InnoDB copy)"
else
  ok "free space ${root_free_gb} GB >= estimated need ${need_gb} GB"
fi

# Spill target should be fast. Warn if it looks like it is on spinning rust.
tmpsrc=$(df -P "$TEMP_DIR" 2>/dev/null | awk 'NR==2{print $1}')
rot=$(lsblk -ndo ROTA "$tmpsrc" 2>/dev/null | head -1)
[ "$rot" = "1" ] && warn "TEMP_DIR ($TEMP_DIR) looks like a rotational disk - spilling will be very slow"

# ---- 4. Images ---------------------------------------------------------------
echo; echo "[4/6] container images"
for img in "$ENGINE_IMAGE" "$DUCKDB_IMAGE" "$GEN_IMAGE" "$REPORT_IMAGE"; do
  if docker image inspect "$img" >/dev/null 2>&1; then ok "present: $img"
  else
    warn "not present locally: $img (will need 'docker pull $img')"
    if docker manifest inspect "$img" >/dev/null 2>&1; then ok "  ...pullable from the registry"
    else ok "  ...will be built locally by bootstrap-images.sh / ensure_images"; fi
  fi
done

# ---- 5. Kernel / limits ------------------------------------------------------
echo; echo "[5/6] kernel & limits"
nofile=$(ulimit -n)
[ "$nofile" -lt 65536 ] && warn "open-file soft limit is $nofile - fix with: bash tune-node.sh" || ok "open files: $nofile"
swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '?')
[ "$swappiness" != '?' ] && [ "$swappiness" -gt 10 ] && warn "vm.swappiness=$swappiness - a big query should spill to TEMP_DIR, not swap. Fix with: bash tune-node.sh"
thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' || echo '?')
[ "$thp" = "[always]" ] && warn "transparent hugepages = always - 'madvise' is usually better for DB workloads"
dbg=$(cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo '?')
[ "$dbg" != '?' ] && [ "$dbg" -gt 15 ] && warn "vm.dirty_ratio=$dbg - a 1 TB load will stall on flushes. Fix with: bash tune-node.sh"
overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo '?')
ok "vm.overcommit_memory=$overcommit  vm.swappiness=$swappiness  THP=$thp"

# ---- 6. Feasibility guidance -------------------------------------------------
echo; echo "[6/6] plan sanity"
# InnoDB's 22-query run is tractable up to roughly SF100; beyond that most
# queries exceed any sane timeout (at SF10 it already missed 6/22 at 180 s).
INNODB_QUERY_CEILING=${INNODB_QUERY_CEILING:-100}
case " $LEGS " in *" innodb "*)
  if awk -v sf="$SF" -v c="$INNODB_QUERY_CEILING" 'BEGIN{exit !(sf<=c)}'; then
    ok "InnoDB queries are tractable at SF$SF - safe to run them here"
  else
    warn "SF$SF is above the ~SF$INNODB_QUERY_CEILING ceiling where InnoDB can finish TPC-H."
    echo "         At SF10 InnoDB already timed out on 6/22 queries at 180 s."
    echo "         Keep SKIP_INNODB_QUERIES=1 here (load + storage are still measured),"
    echo "         and run the InnoDB query comparison separately at SF$SF_INNODB_QUERIES."
  fi;;
esac
echo
# Estimates are anchored on the SF1000 measurements and scaled linearly, so a
# smoke run does not get told it will take six hours.
est(){ awk -v sf="$SF" -v lo="$1" -v hi="$2" 'BEGIN{
  l=lo*sf/1000; h=hi*sf/1000;
  if      (h < 1.0/60) printf "%.0f-%.0f s",   l*3600, h*3600;
  else if (h < 1.0)    printf "%.0f-%.0f min", l*60,   h*60;
  else                 printf "%.1f-%.1f h",   l,      h }'; }
echo "  Estimated wall-clock at SF$SF (scaled from SF1000 measurements):"
printf '    generate CSVs .................... %s\n' "$(est 2 6)"
printf '    load ENGINE=DuckDB (COPY path) ... %s\n' "$(est 3 6)"
case " $LEGS " in *" innodb "*) printf '    load InnoDB ...................... %s  <-- the long pole\n' "$(est 12 30)";; esac
printf '    22 queries, DuckDB engine ........ %s\n' "$(est 1 3)"
echo

echo "=============================================================="
if [ "$fail" -gt 0 ]; then
  echo " PREFLIGHT FAILED: $fail blocking issue(s) above."
  [ "$STRICT" = 1 ] && exit 1
  echo " (STRICT=0 - continuing anyway)"
else
  echo " PREFLIGHT OK - safe to run 01-generate.sh"
fi
echo "=============================================================="
mark_done "preflight"
