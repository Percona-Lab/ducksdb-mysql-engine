# DuckDB Storage Engine for MySQL — Documentation

This is the documentation set for the in-tree **DuckDB storage engine** for
MySQL 9.7. The engine lets you create ordinary tables with `ENGINE=DuckDB` and
have analytical queries against them execute inside DuckDB's columnar, vectorized
engine **automatically** — there is no `SECONDARY_ENGINE=` declaration and no
`SECONDARY_LOAD` step. You get one server, one SQL interface, and analytical
queries that run in a column store when they can.

The engine is compiled directly into `mysqld` as a built-in (MANDATORY) storage
engine. It registers a small server hook, `handlerton::pushdown_select` (added by
the patch in [`server-patches/`](../server-patches/)), that lets it take over
execution of an entire `SELECT` whose base tables are all `ENGINE=DuckDB`. Such a
query is regenerated in DuckDB's SQL dialect, executed in DuckDB, and the result
is streamed back to the client. Anything the engine cannot translate exactly
declines transparently and falls back to normal MySQL execution, so results are
always correct.

## What you get

- **Standard DDL/DML.** `CREATE TABLE ... ENGINE=DuckDB`, `INSERT`,
  `LOAD DATA`, `UPDATE`, `DELETE`, `TRUNCATE`, point lookups, and scans all work
  through the normal MySQL handler API.
- **Automatic analytical pushdown.** Aggregations, `GROUP BY`, multi-aggregate
  rollups, `COUNT(DISTINCT ...)`, inner-join + group, and `ORDER BY`/`LIMIT`
  queries are handed to DuckDB whole and executed there.
- **Per-schema storage.** Each MySQL schema (database) maps to its own
  `<schema>.duckdb` file in the data directory.
- **Transaction participation.** The engine takes part in MySQL's commit and
  rollback flow, including XA prepare/commit/rollback callbacks.
- **Observability.** Two status variables — `Ducksdb_pushdown_count` and
  `Ducksdb_open_instances` — let you confirm what actually ran in DuckDB.

## Table of contents

| Document | Contents |
|----------|----------|
| [architecture.md](architecture.md) | Components, layering, and the data-flow / sequence diagrams for DDL, writes, reads, whole-query pushdown, and transactions. |
| [installation.md](installation.md) | Prerequisites, building `mysqld` with the engine, the server patch, DuckDB acquisition, initializing a data directory, and a Docker-based path. |
| [usage.md](usage.md) | End-user guide: creating tables, loading data, query examples, confirming pushdown, supported types and collations, transactions, and current limitations. |

## Repository layout

| Directory | Contents |
|-----------|----------|
| [`engine/`](../engine/) | The handler (`ha_duckdb`) and the whole-query pushdown (`duckdb_pushdown`). |
| [`common/`](../common/) | The shared storage / type-mapping / DML / transaction / utility layer. |
| [`server-patches/`](../server-patches/) | The MySQL server patch the engine depends on. |
| [`cmake/`](../cmake/) | DuckDB acquisition (prebuilt prefix, or built from source via `ExternalProject`). |
| [`engine/test/`](../engine/test/) | Standalone GoogleTest / CTest unit suite. |
| [`mysql-test-suite/`](../mysql-test-suite/) | MySQL Test Runner (MTR) tests, suite name `duckdb`. |
| [`bench/`](../bench/) | Benchmark harness (InnoDB vs. the DuckDB engine vs. native DuckDB). |
