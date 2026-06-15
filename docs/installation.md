# Installation

This guide covers building `mysqld` with the DuckDB storage engine compiled in,
acquiring DuckDB, applying the required server patch, initializing a data
directory, and starting the server. A Docker-based path is included.

The engine is **built into the server** as a MANDATORY storage engine — there is
no loadable plugin to `INSTALL`. Once `mysqld` is built and running, `ENGINE=DuckDB`
is available immediately.

## Prerequisites

- A C++ toolchain capable of building MySQL 9.7 (a recent GCC or Clang).
- CMake and a build tool (`make` or `ninja`).
- The MySQL 9.7 source tree, checked out under `vendor/mysql-server/` in this
  repository. The build scripts expect it there.
- The engine sources symlinked into the server tree at
  `vendor/mysql-server/storage/duckdb`. Create it with:

  ```sh
  ln -s ../../engine vendor/mysql-server/storage/duckdb
  ```

  MySQL's storage-engine scan then picks up `engine/CMakeLists.txt` automatically.
- DuckDB, provided one of three ways (see below). A clean checkout can build with
  none of these set, because the build falls back to building DuckDB from source.

> `vendor/` is gitignored. The tracked sources of truth are the engine code under
> `engine/` and `common/`, the patch files under `server-patches/`, and the build
> scripts under `scripts/`.

## How DuckDB is acquired

`cmake/duckdb-external.cmake` resolves DuckDB in this order:

1. **Prebuilt prefix** — `DUCKDB_ROOT` (environment variable or
   `-DDUCKDB_ROOT=...`) pointing at a prefix that contains
   `lib/libduckdb*.a` and `include/duckdb.hpp`. Used as-is when present (fastest).
2. **Vendored prefix** — `vendor/duckdb-prefix` in the repository, if present.
3. **Build from source** — an `ExternalProject` that builds the DuckDB static
   bundle. The source tree is resolved from `-DDUCKDB_SRC`, the `DUCKDB_SRC`
   environment variable, or a sibling `../duckdb` checkout.

This means you do not need to set `DUCKDB_ROOT` for a clean checkout that has a
DuckDB source tree available; the build will produce the static library itself.

## The server patch

The engine depends on one server patch,
[`server-patches/0001-engine-query-pushdown.patch`](../server-patches/0001-engine-query-pushdown.patch),
which adds the `handlerton::pushdown_select` hook to the server. The build script
applies it idempotently before configuring. To apply it manually:

```sh
cd vendor/mysql-server
git apply ../../server-patches/0001-engine-query-pushdown.patch
```

`git apply --check` succeeds only when the patch is not yet applied, so re-running
the build script never double-applies it.

## Building the server

The supplied script `scripts/build-server.sh` applies the patch, configures the
MySQL build, and builds `mysqld` plus the client tools. It expects the engine
symlink and a DuckDB prefix to be in place (it checks for
`vendor/duckdb-prefix/lib/libduckdb.a`).

```sh
# from the repository root
scripts/build-server.sh
```

Useful environment variables understood by the script:

| Variable | Default | Meaning |
|----------|---------|---------|
| `REPO` | `/work` | Repository root. |
| `BUILD_TYPE` | `Debug` | CMake build type (`Debug` / `Release` / ...). |
| `JOBS` | `$(nproc)` | Parallel build jobs. |

The script configures the build roughly as follows (shown so you can run an
equivalent configure by hand if you are not using the script):

```sh
cmake -S vendor/mysql-server -B vendor/mysql-server/build \
      -DCMAKE_BUILD_TYPE=Debug \
      -DDOWNLOAD_BOOST=1 -DWITH_BOOST=vendor/boost \
      -DWITH_UNIT_TESTS=OFF \
      -DCMAKE_PREFIX_PATH=vendor/duckdb-prefix \
      -DPLUGIN_ROCKSDB=NO -DPLUGIN_NDB=NO -DPLUGIN_FEDERATED=NO \
      -DPLUGIN_ARCHIVE=NO -DPLUGIN_BLACKHOLE=NO -DPLUGIN_EXAMPLE=NO \
      -DWITH_ROUTER=OFF

cmake --build vendor/mysql-server/build -j"$(nproc)"
```

The first build is long (it downloads Boost and may build DuckDB from source);
subsequent builds are incremental.

When the build finishes, the server is at
`vendor/mysql-server/build/runtime_output_directory/mysqld`. Verify the engine is
built in:

```sql
SHOW ENGINES;
-- or:
SELECT engine, support FROM information_schema.engines WHERE engine='DuckDB';
```

`DuckDB` should appear as a supported engine.

## Initializing a data directory and starting the server

Use the freshly built `mysqld`. The DuckDB per-schema files
(`<schema>.duckdb`) are created in this same data directory as you create
`ENGINE=DuckDB` tables.

```sh
BUILD=vendor/mysql-server/build
DATADIR="$PWD/data"

# Initialize a fresh data directory (insecure: no root password — for local dev).
"$BUILD/runtime_output_directory/mysqld" \
    --initialize-insecure --datadir="$DATADIR"

# Start the server.
"$BUILD/runtime_output_directory/mysqld" --datadir="$DATADIR"
```

Connect with the built client and confirm the engine:

```sh
"$BUILD/runtime_output_directory/mysql" -u root
```

```sql
SELECT engine, support FROM information_schema.engines WHERE engine='DuckDB';
```

## Docker-based path

The build and test scripts are written to run inside a builder container with the
repository mounted at `/work`. Building the server:

```sh
docker run --rm -v "$PWD":/work -e REPO=/work ducksdb-builder:latest \
    bash -lc 'cd /work && scripts/build-server.sh'
```

Running the MySQL Test Runner (MTR) `duckdb` suite against the built server:

```sh
docker run --rm -v "$PWD":/work -e REPO=/work ducksdb-builder:latest \
    bash -lc 'cd /work && scripts/run-mtr.sh'
```

`scripts/run-mtr.sh` copies the repository's `mysql-test-suite/duckdb` into the
server's test tree and runs `--suite=duckdb`. Pass test names to run a subset, or
`--record` to refresh `.result` files:

```sh
scripts/run-mtr.sh engine_smoke
scripts/run-mtr.sh --record auto_pushdown
```

The engine is built in (MANDATORY), so there is no plugin to load; the runner
allows running as `root` inside the container.

## Running the unit tests

The standalone GoogleTest / CTest suite under `engine/test/` is hermetic — it
needs only the vendored DuckDB prefix and GoogleTest, not a full server build:

```sh
engine/test/run-tests.sh                 # build + ctest (Debug)
engine/test/run-tests.sh --asan          # under AddressSanitizer / UBSan
engine/test/run-tests.sh --with-server   # also build the Field-coupled tests
```

These cover the collation mapping and literal conversion
(`test_pushdown_builder.cc`), the type bridge (`test_type_bridge.cc`), and the
DuckDB error mapping (`test_map_duckdb_error.cc`).
