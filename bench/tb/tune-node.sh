#!/usr/bin/env bash
# Apply host tunables for a long, larger-than-memory run. Saves the originals.
#   bash tune-node.sh --dry-run
#   bash tune-node.sh              # needs sudo for the sysctls
#   PERSIST=1 bash tune-node.sh    # survive a reboot
#   bash tune-node.sh --restore
# swappiness: DuckDB should spill to TEMP_DIR, not have mysqld swapped out.
# dirty ratios: a bulk load otherwise stalls every writer during flushes.

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/config.sh"

MODE=${1:-apply}
case "$MODE" in --dry-run|--restore|--apply|apply) ;; *) die "usage: tune-node.sh [--dry-run|--restore]";; esac
[ "$MODE" = "--apply" ] && MODE=apply

SAVE="$STATE_DIR/node-tunables.orig"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Desired values.
WANT_SWAPPINESS=${WANT_SWAPPINESS:-10}
WANT_DIRTY_BG=${WANT_DIRTY_BG:-5}
WANT_DIRTY=${WANT_DIRTY:-10}
WANT_NOFILE=${WANT_NOFILE:-65536}

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

sysctl_get(){ cat "/proc/sys/${1//./\/}" 2>/dev/null || echo "?"; }

need_change=0
plan(){ # $1=name $2=current $3=wanted
  if [ "$2" = "$3" ]; then printf '  [ ok ] %-32s %s (already set)\n' "$1" "$2"
  else printf '  [SET ] %-32s %s -> %s\n' "$1" "$2" "$3"; need_change=1; fi
}

echo "=============================================================="
echo " Node tunables for a long, large TPC-H run"
echo "=============================================================="
echo

# ---- restore -----------------------------------------------------------------
if [ "$MODE" = "--restore" ]; then
  [ -f "$SAVE" ] || die "nothing to restore: $SAVE not found"
  echo "Restoring from $SAVE:"
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue;; esac
    printf '  %-32s -> %s\n' "$k" "$v"
    if [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ]; then
      $SUDO sysctl -q -w "$k=$v" 2>/dev/null || echo "     (failed - run as root)"
    else
      echo "     (no sudo: run  sudo sysctl -w $k=$v)"
    fi
  done < "$SAVE"
  $SUDO rm -f /etc/sysctl.d/99-tpch-bench.conf /etc/security/limits.d/99-tpch-bench.conf 2>/dev/null || true
  echo; echo "Restored. Persistent drop-ins removed (if they existed)."
  exit 0
fi

# ---- inspect -----------------------------------------------------------------
CUR_SWAP=$(sysctl_get vm.swappiness)
CUR_DBG=$(sysctl_get vm.dirty_background_ratio)
CUR_D=$(sysctl_get vm.dirty_ratio)
CUR_NOFILE_S=$(ulimit -Sn)
CUR_NOFILE_H=$(ulimit -Hn)
THP=$(grep -o '\[.*\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "?")

echo "Current -> desired:"
plan "vm.swappiness"             "$CUR_SWAP" "$WANT_SWAPPINESS"
plan "vm.dirty_background_ratio" "$CUR_DBG"  "$WANT_DIRTY_BG"
plan "vm.dirty_ratio"            "$CUR_D"    "$WANT_DIRTY"

# nofile: a shell may raise its soft limit only up to the hard limit - and we
# only ever RAISE it. A node that already allows more than we ask for is fine;
# lowering it would be an unrequested downgrade.
TARGET_NOFILE=$WANT_NOFILE
if [ "$CUR_NOFILE_H" != "unlimited" ] && [ "$CUR_NOFILE_H" -lt "$WANT_NOFILE" ] 2>/dev/null; then
  TARGET_NOFILE=$CUR_NOFILE_H
fi
if [ "$CUR_NOFILE_S" = "unlimited" ] || { [ "$CUR_NOFILE_S" -ge "$TARGET_NOFILE" ] 2>/dev/null; }; then
  printf '  [ ok ] %-32s %s (already >= %s)\n' "nofile (soft)" "$CUR_NOFILE_S" "$TARGET_NOFILE"
  TARGET_NOFILE=$CUR_NOFILE_S            # nothing to do
else
  plan "nofile (soft)" "$CUR_NOFILE_S" "$TARGET_NOFILE"
fi
printf '  [info] nofile hard limit is %s; containers already get %s via --ulimit\n' "$CUR_NOFILE_H" "$WANT_NOFILE"
printf '  [info] transparent hugepages = %s%s\n' "$THP" \
  "$([ "$THP" = "[always]" ] && echo '  <- consider madvise' || echo '  (fine)')"
echo

if [ "$MODE" = "--dry-run" ]; then
  echo "Dry run - nothing was changed."
  [ "$need_change" = 1 ] && echo "Run 'bash tune-node.sh' to apply." || echo "This node is already tuned."
  exit 0
fi

if [ "$need_change" = 0 ]; then
  echo "Nothing to do - this node is already tuned."
  exit 0
fi

# ---- save originals (once) ---------------------------------------------------
if [ ! -f "$SAVE" ]; then
  { echo "# saved by tune-node.sh on $(date -u +%FT%TZ)"
    echo "vm.swappiness=$CUR_SWAP"
    echo "vm.dirty_background_ratio=$CUR_DBG"
    echo "vm.dirty_ratio=$CUR_D"; } > "$SAVE"
  echo "Saved originals to $SAVE (use --restore to revert)"
fi

# ---- apply sysctls -----------------------------------------------------------
if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
  echo
  echo "No root and no sudo - run these yourself:"
  echo "  sudo sysctl -w vm.swappiness=$WANT_SWAPPINESS"
  echo "  sudo sysctl -w vm.dirty_background_ratio=$WANT_DIRTY_BG"
  echo "  sudo sysctl -w vm.dirty_ratio=$WANT_DIRTY"
else
  echo "Applying sysctls ..."
  for kv in "vm.swappiness=$WANT_SWAPPINESS" \
            "vm.dirty_background_ratio=$WANT_DIRTY_BG" \
            "vm.dirty_ratio=$WANT_DIRTY"; do
    if $SUDO sysctl -q -w "$kv" 2>/dev/null; then printf '  applied %s\n' "$kv"
    else printf '  FAILED  %s (run as root)\n' "$kv"; fi
  done
fi

# ---- raise this shell's soft nofile -------------------------------------------
if [ "$CUR_NOFILE_S" != unlimited ] && [ "$CUR_NOFILE_S" -lt "$TARGET_NOFILE" ] 2>/dev/null; then
  if ulimit -Sn "$TARGET_NOFILE" 2>/dev/null; then
    echo "  raised nofile soft limit to $(ulimit -Sn) for this shell"
  else
    echo "  could not raise nofile here; harness containers still get $WANT_NOFILE"
  fi
else
  echo "  nofile soft limit already $CUR_NOFILE_S - left alone"
fi

# ---- optional persistence ------------------------------------------------------
if [ "${PERSIST:-0}" = 1 ]; then
  echo
  echo "Making it persistent across reboots ..."
  if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
    $SUDO tee /etc/sysctl.d/99-tpch-bench.conf >/dev/null <<EOF
# written by tune-node.sh for the TPC-H benchmark
vm.swappiness = $WANT_SWAPPINESS
vm.dirty_background_ratio = $WANT_DIRTY_BG
vm.dirty_ratio = $WANT_DIRTY
EOF
    $SUDO tee /etc/security/limits.d/99-tpch-bench.conf >/dev/null <<EOF
# written by tune-node.sh for the TPC-H benchmark
* soft nofile $WANT_NOFILE
* hard nofile $WANT_NOFILE
EOF
    echo "  wrote /etc/sysctl.d/99-tpch-bench.conf and /etc/security/limits.d/99-tpch-bench.conf"
    echo "  (the nofile change needs a new login session to take effect)"
  else
    echo "  skipped - needs root"
  fi
fi

echo
echo "=============================================================="
echo " Done. Verify with:  bash tune-node.sh --dry-run"
echo " Revert with:        bash tune-node.sh --restore"
echo "=============================================================="
