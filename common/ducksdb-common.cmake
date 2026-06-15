# Copyright (c) 2026 ducksdb-mysql-engine contributors.
# SPDX-License-Identifier: GPL-2.0
#
# Single source of truth for the SHARED DuckDB-bridge layer.
#
# These storage/type/DML/XA/util files are engine-agnostic: they translate
# between the MySQL handler API and DuckDB and are byte-identical between this
# in-tree engine and the sibling `ducksdb-mysql` plugin. Rather than maintaining
# two copies, both build systems INCLUDE this file and consume the variables it
# exports.
#
# Why a .cmake include and not an add_library() target:
#   The engine builds *inside* the patched MySQL tree via MYSQL_ADD_PLUGIN, which
#   expects one linkable plugin compiled from a flat source list (it injects the
#   right compile flags, visibility, and the builtin_<plugin>_plugin symbol). A
#   standalone STATIC/OBJECT library would not pick up those plugin flags and
#   would fight MySQL's plugin machinery. Exporting the source list keeps the
#   shared files compiled with the consumer's exact plugin flags while still
#   living in one directory.
#
# Exported variables (read by the consumer's CMakeLists.txt):
#   DUCKSDB_COMMON_DIR          absolute path of this common/ directory
#   DUCKSDB_COMMON_INCLUDE_DIR  same; add to the plugin target's include dirs so
#                               the sibling-style #include "duckdb_*.h" resolves
#   DUCKSDB_COMMON_SOURCES      absolute paths of the shared .cc files to compile
#                               into the consuming plugin
#
# The one engine/plugin-specific dependency the shared layer has is the
# `extern handlerton *ducksdb_hton;` declared in each tree's own ha_duckdb.h
# (used by duckdb_xa.cc). The consumer must therefore also keep its own engine
# directory on the include path so that header resolves — see engine/CMakeLists.txt.

get_filename_component(DUCKSDB_COMMON_DIR "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
set(DUCKSDB_COMMON_INCLUDE_DIR "${DUCKSDB_COMMON_DIR}")

set(DUCKSDB_COMMON_SOURCES
    "${DUCKSDB_COMMON_DIR}/duckdb_engine_context.cc"
    "${DUCKSDB_COMMON_DIR}/duckdb_types.cc"
    "${DUCKSDB_COMMON_DIR}/duckdb_sql_util.cc"
    "${DUCKSDB_COMMON_DIR}/ddl_convertor.cc"
    "${DUCKSDB_COMMON_DIR}/dml_convertor.cc"
    "${DUCKSDB_COMMON_DIR}/cond_pushdown.cc"
    "${DUCKSDB_COMMON_DIR}/duckdb_scan.cc"
    "${DUCKSDB_COMMON_DIR}/duckdb_appender.cc"
    "${DUCKSDB_COMMON_DIR}/duckdb_xa.cc"
)
