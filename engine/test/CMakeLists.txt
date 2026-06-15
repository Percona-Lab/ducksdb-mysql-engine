# Copyright (c) 2026 ducksdb-mysql-engine contributors.
# SPDX-License-Identifier: GPL-2.0
#
# Standalone GoogleTest/CTest harness for the ducksdb-mysql-engine unit suite.
#
# This is a SELF-CONTAINED CMake project (it can be configured directly, without
# the MySQL server build), so it works from a clean checkout:
#
#   cmake -S engine/test -B build/test
#   cmake --build build/test
#   ctest --test-dir build/test --output-on-failure
#
# It is deliberately NOT wired into engine/CMakeLists.txt's MYSQL_ADD_PLUGIN
# build: the engine builds inside the patched MySQL tree (storage/duckdb symlink)
# where adding test executables would fight the server's own test machinery. The
# unit tests instead compile the engine's PURE, server-independent logic in
# isolation. See scripts/run-tests.sh for the one-command entry point.
#
# Targets:
#   ducksdb_text_pass_tests  — tests for the 3 SQL-text passes (no deps;
#                              always built).
#   ducksdb_type_bridge_tests — DuckDB-level type/encoding round-trips (DuckDB
#                              only); the Field-coupled half is opt-in via
#                              -DDUCKSDB_TEST_WITH_SERVER=ON.
#   ducksdb_pushdown_builder_tests — pushdown builder tests (no deps).
#   ducksdb_fuzz_text_passes — robustness/fuzz driver over the 3 passes.

cmake_minimum_required(VERSION 3.16)
project(ducksdb_engine_tests LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

enable_testing()

# --- Options ---------------------------------------------------------------
option(DUCKSDB_TEST_SANITIZE
       "Build the unit tests with -fsanitize=address,undefined" OFF)
option(DUCKSDB_TEST_WITH_SERVER
       "Also build/run the Field-coupled bridge tests (links the prebuilt MySQL \
server archives). Off by default to keep the default run hermetic." OFF)
option(DUCKSDB_TEST_FUZZ_LIBFUZZER
       "Build the text-pass fuzzer with libFuzzer (-fsanitize=fuzzer). When OFF \
a standalone seeded-random driver is built and run under ctest instead." OFF)

if(DUCKSDB_TEST_SANITIZE)
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
endif()

# --- Repo layout -----------------------------------------------------------
get_filename_component(REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")

# --- DuckDB (for the type-bridge round-trip tests) -------------------------
# Prefer the vendored prefix; fall back to $DUCKDB_ROOT as an optional cache.
# This mirrors engine/CMakeLists.txt's resolution but never hard-fails: if no
# DuckDB is found, the DuckDB-dependent target is simply skipped so the pure
# text-pass tests still build and run.
find_path(DUCKDB_INCLUDE_DIR
    NAMES duckdb.hpp
    HINTS "${REPO_ROOT}/vendor/duckdb-prefix/include" ENV DUCKDB_ROOT
    PATH_SUFFIXES include
)
find_library(DUCKDB_LIB
    NAMES duckdb
    HINTS "${REPO_ROOT}/vendor/duckdb-prefix/lib" ENV DUCKDB_ROOT
    PATH_SUFFIXES lib
)

# --- GoogleTest ------------------------------------------------------------
# Use the GoogleTest vendored in the MySQL tree (offline-friendly); fall back to
# FetchContent only if it is absent (requires network — last resort).
set(_VENDORED_GTEST
    "${REPO_ROOT}/vendor/mysql-server/extra/googletest/googletest-1.17.0/googletest")
if(EXISTS "${_VENDORED_GTEST}/CMakeLists.txt")
    set(GOOGLETEST_VERSION 1.17.0)
    set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
    set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    add_subdirectory("${_VENDORED_GTEST}" "${CMAKE_BINARY_DIR}/_gtest" EXCLUDE_FROM_ALL)
    set(GTEST_LIBS gtest)
    set(GTEST_INCLUDE "${_VENDORED_GTEST}/include")
else()
    message(STATUS "Vendored GoogleTest not found — fetching (needs network)")
    include(FetchContent)
    FetchContent_Declare(googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.17.0)
    set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
    set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
    set(GTEST_LIBS gtest)
    set(GTEST_INCLUDE "")
endif()

# Helper: register a gtest executable + ctest case.
function(ducksdb_add_gtest name)
    add_executable(${name} ${ARGN} "${CMAKE_CURRENT_SOURCE_DIR}/test_main.cc")
    target_include_directories(${name} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    if(GTEST_INCLUDE)
        target_include_directories(${name} PRIVATE "${GTEST_INCLUDE}")
    endif()
    target_link_libraries(${name} PRIVATE ${GTEST_LIBS})
    find_package(Threads REQUIRED)
    target_link_libraries(${name} PRIVATE Threads::Threads)
    add_test(NAME ${name} COMMAND ${name})
endfunction()

# --- 3) Pushdown builder tests (always built; no external deps) ------------
ducksdb_add_gtest(ducksdb_pushdown_builder_tests
    "${CMAKE_CURRENT_SOURCE_DIR}/test_pushdown_builder.cc")

# --- 4) MapDuckDBError mirror tests (always built; self-contained mirror) ---
ducksdb_add_gtest(ducksdb_map_duckdb_error_tests
    "${CMAKE_CURRENT_SOURCE_DIR}/test_map_duckdb_error.cc")

# --- 2) Type-bridge round-trip tests (needs DuckDB) ------------------------
if(DUCKDB_LIB AND DUCKDB_INCLUDE_DIR)
    ducksdb_add_gtest(ducksdb_type_bridge_tests
        "${CMAKE_CURRENT_SOURCE_DIR}/test_type_bridge.cc")
    target_include_directories(ducksdb_type_bridge_tests SYSTEM PRIVATE
        "${DUCKDB_INCLUDE_DIR}")
    target_link_libraries(ducksdb_type_bridge_tests PRIVATE
        ${DUCKDB_LIB} ${CMAKE_DL_LIBS})
    if(DUCKSDB_TEST_WITH_SERVER)
        # Field-coupled half: link the prebuilt server archives so a real Field
        # can be constructed. Paths resolved from the existing server build;
        # enabled locally on demand. We don't hard-require it.
        target_compile_definitions(ducksdb_type_bridge_tests PRIVATE
            DUCKSDB_TEST_WITH_SERVER)
        target_include_directories(ducksdb_type_bridge_tests SYSTEM PRIVATE
            "${REPO_ROOT}/vendor/mysql-server/include"
            "${REPO_ROOT}/vendor/mysql-server/sql"
            "${REPO_ROOT}/vendor/mysql-server")
        find_library(MYSQL_SQL_MAIN_LIB
            NAMES sql_main
            HINTS "${REPO_ROOT}/vendor/mysql-server/build/archive_output_directory")
        if(MYSQL_SQL_MAIN_LIB)
            target_link_libraries(ducksdb_type_bridge_tests PRIVATE
                ${MYSQL_SQL_MAIN_LIB})
        else()
            message(WARNING
                "DUCKSDB_TEST_WITH_SERVER=ON but libsql_main.a not found — "
                "build the server first (scripts/build-server.sh)")
        endif()
    endif()
else()
    message(STATUS
        "DuckDB not found (no vendor prefix, no DUCKDB_ROOT) — skipping "
        "ducksdb_type_bridge_tests; pure text-pass tests still run")
endif()

