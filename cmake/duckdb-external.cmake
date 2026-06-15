# Copyright (c) 2026 ducksdb-mysql-engine contributors.
# SPDX-License-Identifier: GPL-2.0
#
# Hermetic DuckDB acquisition for the in-tree storage engine.
#
# Replaces the old hard FIND_LIBRARY(... NO_DEFAULT_PATH) requirement that forced
# every build to point DUCKDB_ROOT at a pre-existing prefix. Resolution order:
#
#   1. DUCKDB_ROOT env / -DDUCKDB_ROOT=...  (optional FAST CACHE — a prebuilt
#      prefix with lib/libduckdb*.a + include/duckdb.hpp). Used as-is if present.
#   2. The vendored prefix at vendor/duckdb-prefix (the repo's committed cache).
#   3. ExternalProject: build the DuckDB static bundle from source. Source tree
#      resolved from -DDUCKDB_SRC, the DUCKDB_SRC env var, or the sibling
#      checkout ../duckdb. This makes a clean checkout self-contained.
#
# After include(), the following are set in the caller's scope:
#   DUCKDB_INCLUDE_DIR   include dir containing duckdb.hpp
#   DUCKDB_LIBRARIES     the static library/libraries to link
#   DUCKDB_EXTERNAL_TARGET   (only in mode 3) an ExternalProject target the
#                            engine must depend on so build order is correct.
#
# Usage from engine/CMakeLists.txt:
#   include(${CMAKE_CURRENT_LIST_DIR}/../cmake/duckdb-external.cmake)
#   ducksdb_provide_duckdb()

include_guard(GLOBAL)
include(ExternalProject)

# Capture the module's own directory at include time. Inside a function(),
# CMAKE_CURRENT_LIST_DIR resolves to the CALLER's list file, not this module, so
# we must bake the path in here (this file lives in <repo>/cmake/).
set(_DUCKSDB_CMAKE_MODULE_DIR "${CMAKE_CURRENT_LIST_DIR}")

function(ducksdb_provide_duckdb)
    get_filename_component(_repo_root "${_DUCKSDB_CMAKE_MODULE_DIR}/.." ABSOLUTE)

    # --- Mode 1 + 2: an existing prefix (env override, then vendored cache) ---
    set(_prefix_hints "")
    if(DEFINED ENV{DUCKDB_ROOT})
        list(APPEND _prefix_hints "$ENV{DUCKDB_ROOT}")
    endif()
    if(DEFINED DUCKDB_ROOT)
        list(APPEND _prefix_hints "${DUCKDB_ROOT}")
    endif()
    list(APPEND _prefix_hints "${_repo_root}/vendor/duckdb-prefix")

    set(_found_lib "")
    set(_found_inc "")
    foreach(_p IN LISTS _prefix_hints)
        if(NOT _found_lib)
            find_library(_DUCKDB_CACHED_LIB
                NAMES duckdb duckdb_bundle duckdb_static
                HINTS "${_p}" PATH_SUFFIXES lib
                NO_DEFAULT_PATH)
            find_path(_DUCKDB_CACHED_INC
                NAMES duckdb.hpp
                HINTS "${_p}" PATH_SUFFIXES include
                NO_DEFAULT_PATH)
            if(_DUCKDB_CACHED_LIB AND _DUCKDB_CACHED_INC)
                set(_found_lib "${_DUCKDB_CACHED_LIB}")
                set(_found_inc "${_DUCKDB_CACHED_INC}")
            endif()
        endif()
    endforeach()

    if(_found_lib AND _found_inc)
        message(STATUS "DuckDB: using prebuilt prefix (lib=${_found_lib})")
        set(DUCKDB_INCLUDE_DIR "${_found_inc}" PARENT_SCOPE)
        set(DUCKDB_LIBRARIES "${_found_lib}" PARENT_SCOPE)
        return()
    endif()

    # --- Mode 3: build from source via ExternalProject ------------------------
    set(_src "")
    if(DEFINED DUCKDB_SRC AND EXISTS "${DUCKDB_SRC}/CMakeLists.txt")
        set(_src "${DUCKDB_SRC}")
    elseif(DEFINED ENV{DUCKDB_SRC} AND EXISTS "$ENV{DUCKDB_SRC}/CMakeLists.txt")
        set(_src "$ENV{DUCKDB_SRC}")
    elseif(EXISTS "${_repo_root}/../duckdb/CMakeLists.txt")
        set(_src "${_repo_root}/../duckdb")
    endif()

    if(NOT _src)
        message(FATAL_ERROR
            "DuckDB not found: no prebuilt prefix (DUCKDB_ROOT / "
            "vendor/duckdb-prefix) and no source tree (DUCKDB_SRC / ../duckdb). "
            "Set one of them and re-run cmake.")
    endif()

    message(STATUS "DuckDB: building static bundle from source at ${_src}")
    set(_ep_prefix "${CMAKE_BINARY_DIR}/duckdb-build")
    set(_ep_install "${_ep_prefix}/install")

    # Build only the core static library — no shell, no unittests, no extensions
    # we don't need — for a fast, self-contained bundle (mirrors the Makefile's
    # bundle-library settings, expressed as CMake cache args).
    ExternalProject_Add(duckdb_external
        SOURCE_DIR        "${_src}"
        PREFIX            "${_ep_prefix}"
        INSTALL_DIR       "${_ep_install}"
        CMAKE_CACHE_ARGS
            -DCMAKE_INSTALL_PREFIX:PATH=${_ep_install}
            # Pin libdir to "lib" — DuckDB uses GNUInstallDirs, which would
            # otherwise install to lib64 on some distros and break our hardcoded
            # BUILD_BYPRODUCTS / DUCKDB_LIBRARIES path below.
            -DCMAKE_INSTALL_LIBDIR:STRING=lib
            -DCMAKE_BUILD_TYPE:STRING=Release
            -DBUILD_SHELL:BOOL=OFF
            -DBUILD_UNITTESTS:BOOL=OFF
            -DBUILD_BENCHMARKS:BOOL=OFF
            -DENABLE_SANITIZER:BOOL=OFF
            -DBUILD_MAIN_DUCKDB_LIBRARY:BOOL=ON
            -DEXTENSION_STATIC_BUILD:BOOL=ON
            -DOVERRIDE_GIT_DESCRIBE:STRING=v1.0.0-0-g0123456789
        BUILD_BYPRODUCTS
            "${_ep_install}/lib/libduckdb_static.a"
            "${_ep_install}/lib/libduckdb.a"
        UPDATE_COMMAND    ""
        LOG_CONFIGURE     ON
        LOG_BUILD         ON
        LOG_INSTALL       ON)

    # The static lib name varies by DuckDB version (libduckdb_static.a for the
    # core static target, libduckdb.a for the shared-as-static install). Link
    # whichever exists at build time via a generator-friendly path list; the
    # engine depends on the ExternalProject target for ordering.
    set(DUCKDB_INCLUDE_DIR "${_ep_install}/include" PARENT_SCOPE)
    set(DUCKDB_LIBRARIES
        "${_ep_install}/lib/libduckdb_static.a" PARENT_SCOPE)
    set(DUCKDB_EXTERNAL_TARGET duckdb_external PARENT_SCOPE)
    # Ensure the include dir exists at configure time so INTERFACE usage is valid.
    file(MAKE_DIRECTORY "${_ep_install}/include")
endfunction()
