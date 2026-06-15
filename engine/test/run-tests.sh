#!/usr/bin/env bash
# Copyright (c) 2026 ducksdb-mysql-engine contributors.
# SPDX-License-Identifier: GPL-2.0
#
# One-command unit-test entry point for the ducksdb-mysql-engine.
# Configures and runs the standalone GoogleTest/CTest harness in engine/test/.
# Hermetic: needs only the vendored DuckDB prefix + vendored GoogleTest — no
# server build, no DUCKDB_ROOT required.
#
# Usage:
#   engine/test/run-tests.sh                 # build + ctest (Debug)
#   engine/test/run-tests.sh --asan          # build + ctest under ASan/UBSan
#   engine/test/run-tests.sh --with-server   # also build the Field-coupled tests
#
# In the ducksdb-builder container (run as root):
#   docker run --rm -v "$PWD":/work -e REPO=/work ducksdb-builder:latest \
#       bash -lc 'git config --global --add safe.directory "*" && \
#                 cd /work && engine/test/run-tests.sh'
#
# NOTE: kept under engine/test/ (this task's owned tree). It is the unit-test
# counterpart to scripts/run-mtr.sh; a follow-up may symlink/move it into
# scripts/ alongside the MTR runner so both run from one place.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO/build/engine-test}"

CMAKE_ARGS=( -S "$HERE" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="${BUILD_TYPE:-Debug}" )

for arg in "$@"; do
    case "$arg" in
        --asan)        CMAKE_ARGS+=( -DDUCKSDB_TEST_SANITIZE=ON ) ;;
        --with-server) CMAKE_ARGS+=( -DDUCKSDB_TEST_WITH_SERVER=ON ) ;;
        --fuzz)        CMAKE_ARGS+=( -DDUCKSDB_TEST_FUZZ_LIBFUZZER=ON ) ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

echo "[run-tests] configure ($BUILD_DIR)"
cmake "${CMAKE_ARGS[@]}"

echo "[run-tests] build"
cmake --build "$BUILD_DIR" -j"$(nproc 2>/dev/null || echo 4)"

echo "[run-tests] ctest"
ctest --test-dir "$BUILD_DIR" --output-on-failure
