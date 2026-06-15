# ducksdb-mysql-engine

An **in-tree DuckDB storage engine for MySQL 9.7**.

Create a table with `ENGINE=DuckDB` and analytical queries against it execute
inside DuckDB's columnar/vectorized engine **automatically** — no
`SECONDARY_ENGINE=` / `SECONDARY_LOAD` ceremony. One server, one SQL interface.

The engine is built into `mysqld` as a MANDATORY storage engine and registers a
small server hook (`handlerton::pushdown_select`, added by the patch in
`server-patches/`) that lets it take over execution of a whole SELECT whose base
tables are all `ENGINE=DuckDB`: the query is regenerated in DuckDB's dialect, run
in DuckDB, and the result streamed back. Anything it can't translate declines
transparently and falls back to normal MySQL execution.

## Layout

- `engine/` — the handler (`ha_duckdb`) and the whole-query pushdown
  (`duckdb_pushdown`).
- `common/` — the shared storage/type/DML/transaction/util layer.
- `server-patches/` — the MySQL server patch the engine depends on (applied into
  the build tree by `scripts/build-server.sh`).
- `cmake/` — DuckDB acquisition (prebuilt prefix, or built from source via
  `ExternalProject`).
- `engine/test/` — standalone GoogleTest/CTest unit suite.
- `mysql-test-suite/` — MTR tests (`suite=duckdb`).
- `bench/` — benchmark harness (InnoDB vs the DuckDB engine).

## Build & test

```sh
scripts/build-server.sh     # configure + build mysqld with the engine
scripts/run-mtr.sh          # MTR suite=duckdb
engine/test/run-tests.sh    # unit tests
```

DuckDB is resolved from a prebuilt prefix (`DUCKDB_ROOT` / vendored
`vendor/duckdb-prefix`) when available, otherwise built from source — so a clean
checkout builds with no `DUCKDB_ROOT` set.
