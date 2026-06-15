# Copyright (c) 2026 ducksdb-mysql-engine contributors.
# SPDX-License-Identifier: GPL-2.0
#
# In-tree DuckDB storage engine for MySQL 9.7 (MANDATORY, built into mysqld).
# The engine is symlinked into <server-tree>/storage/duckdb, so MySQL's
# storage-engine scan picks up this CMakeLists automatically.
#
# DuckDB is provided by cmake/duckdb-external.cmake: it prefers a
# prebuilt prefix (DUCKDB_ROOT env/cache or the vendored vendor/duckdb-prefix) as
# a fast cache, and otherwise builds the DuckDB static bundle from source via an
# ExternalProject — so a clean checkout builds with no DUCKDB_ROOT set.

ADD_DEFINITIONS(-DMYSQL_SERVER)

# In-tree, this directory is reached through the symlink <server-tree>/storage/
# duckdb -> engine/. CMake keeps the symlink path in CMAKE_CURRENT_SOURCE_DIR, so
# "../cmake" / "../common" would resolve inside the server tree (storage/) rather
# than the engine repo. Resolve the symlink to the real engine/ dir (and repo
# root) so the sibling INCLUDEs work both standalone and in-tree.
get_filename_component(_ducksdb_engine_dir "${CMAKE_CURRENT_LIST_FILE}" REALPATH)
get_filename_component(_ducksdb_engine_dir "${_ducksdb_engine_dir}" DIRECTORY)
get_filename_component(_ducksdb_repo_dir "${_ducksdb_engine_dir}/.." ABSOLUTE)

# Resolve DuckDB (sets DUCKDB_INCLUDE_DIR, DUCKDB_LIBRARIES, and possibly
# DUCKDB_EXTERNAL_TARGET when building from source).
INCLUDE(${_ducksdb_repo_dir}/cmake/duckdb-external.cmake)
ducksdb_provide_duckdb()
SET(DUCKDB_LIB ${DUCKDB_LIBRARIES})

# Shared storage/type/DML/XA/util layer lives in ../common (single
# source of truth shared with the sibling ducksdb-mysql plugin). It exports
# DUCKSDB_COMMON_SOURCES (absolute paths) + DUCKSDB_COMMON_INCLUDE_DIR.
INCLUDE(${_ducksdb_repo_dir}/common/ducksdb-common.cmake)

# Engine-specific shim only: the handler entry point (ha_duckdb) and the
# whole-query pushdown (duckdb_pushdown) that distinguishes
# this in-tree engine from the sibling plugin. Everything else comes from common/.
SET(DUCKDB_SOURCES
    ha_duckdb.cc
    duckdb_pushdown.cc   # whole-query pushdown to DuckDB
    ${DUCKSDB_COMMON_SOURCES}
)

# Plugin name MUST match `mysql_declare_plugin(ducksdb)` in ha_duckdb.cc — for a
# MANDATORY built-in engine the linker resolves `builtin_ducksdb_plugin` from it.
# The user-visible SQL engine name ("DuckDB") comes from the plugin descriptor,
# not this identifier.
MYSQL_ADD_PLUGIN(ducksdb ${DUCKDB_SOURCES}
    STORAGE_ENGINE
    MANDATORY
    LINK_LIBRARIES ${DUCKDB_LIB} dl pthread
)

IF(TARGET ducksdb)
    # Resolve includes both ways:
    #   - common/ sources include each other ("duckdb_types.h", …) and the
    #     engine's own "ha_duckdb.h" (for the ducksdb_hton extern in duckdb_xa.cc)
    #   - engine/ sources include the shared headers ("duckdb_scan.h", …)
    # so both directories must be on the plugin target's include path. The plugin
    # source dir (engine/) is implicit; add common/ explicitly.
    TARGET_INCLUDE_DIRECTORIES(ducksdb PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${DUCKSDB_COMMON_INCLUDE_DIR}
    )
    # DuckDB headers are treated as system headers so their warnings don't trip
    # MySQL's -Werror; our own sources are still warned normally.
    TARGET_INCLUDE_DIRECTORIES(ducksdb SYSTEM PRIVATE ${DUCKDB_INCLUDE_DIR})
    IF(DEFINED RAPIDJSON_INCLUDE_DIR)
        TARGET_INCLUDE_DIRECTORIES(ducksdb SYSTEM PRIVATE ${RAPIDJSON_INCLUDE_DIR})
    ENDIF()
    # When DuckDB is built from source (no prebuilt prefix), the engine must wait
    # for the ExternalProject to finish before linking against its static lib.
    IF(DEFINED DUCKDB_EXTERNAL_TARGET)
        ADD_DEPENDENCIES(ducksdb ${DUCKDB_EXTERNAL_TARGET})
    ENDIF()
ENDIF()
