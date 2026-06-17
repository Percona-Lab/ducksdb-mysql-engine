# DuckDB Storage Engine for MySQL — Documentation

This is the documentation set for the in-tree **DuckDB storage engine** for
MySQL 9.7. The engine lets you create ordinary tables with `ENGINE=DuckDB` and
have analytical queries against them execute inside DuckDB's columnar, vectorized
engine **automatically** — there is no `SECONDARY_ENGINE=` declaration and no
`SECONDARY_LOAD` step. You get one server, one SQL interface, and analytical
queries that run in a column store when they can.

The engine is compiled directly into `mysqld` as a built-in (MANDATORY) storage
engine. It registers a small server hook, `handlerton::pushdown_select` (added by
the patches in [`server-patches/`](../server-patches/)), that lets it take over
execution of an entire `SELECT` whose base tables are all `ENGINE=DuckDB`. Such a
query is regenerated in DuckDB's SQL dialect, executed in DuckDB, and the result
is streamed back to the client. Anything the engine cannot translate exactly
declines transparently and falls back to normal MySQL execution, so results are
always correct.

## Quick start

The fastest way to try it is the prebuilt Docker image (MySQL 9.7 with the engine
already built in):

```sh
docker run -d --name mysql-duckdb -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=secret \
  evgeniypatlan/test-images:mysql-9.7-duckdb-v0.2.0

mysql -h 127.0.0.1 -u root -psecret -e "
  CREATE DATABASE shop; USE shop;
  CREATE TABLE sales (id INT PRIMARY KEY, region INT, amount DECIMAL(12,2)) ENGINE=DuckDB;
  INSERT INTO sales VALUES (1,1,100),(2,1,200),(3,2,50);
  SELECT region, SUM(amount) FROM sales GROUP BY region;"
```

See [installation.md](installation.md#quick-start-the-prebuilt-docker-image) for
configuration (passwords, persistent volumes) and [usage.md](usage.md) for the
full query guide.

## What you get

- **Standard DDL/DML.** `CREATE TABLE ... ENGINE=DuckDB`, `INSERT`,
  `LOAD DATA`, `UPDATE`, `DELETE`, `TRUNCATE`, point lookups, and scans all work
  through the normal MySQL handler API.
- **Automatic analytical pushdown.** Aggregations, `GROUP BY`, `COUNT(DISTINCT)`,
  inner/outer joins, derived tables, CTEs, scalar subqueries, and `IN` / `EXISTS`
  / `NOT IN` / `NOT EXISTS` predicates are handed to DuckDB whole and executed
  there. **All 22 standard TPC-H queries push down**, with results identical to
  InnoDB; on SF10 the engine is on par with MariaDB's `ENGINE=DuckDB`.
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
| [installation.md](installation.md) | Running the prebuilt Docker image (quick start), and building from source: prerequisites, the server patch, DuckDB acquisition, initializing a data directory, and building the runtime image. |
| [usage.md](usage.md) | End-user guide: creating tables, loading data, query examples, confirming pushdown, supported types and collations, transactions, and current limitations. |
| [tpch_sf10_mariadb_comparison.md](tpch_sf10_mariadb_comparison.md) | TPC-H SF10 benchmark: the engine vs MariaDB `ENGINE=DuckDB` on the same host (per-query and totals). |

## Repository layout

| Directory | Contents |
|-----------|----------|
| [`engine/`](../engine/) | The handler (`ha_duckdb`) and the whole-query pushdown (`duckdb_pushdown`). |
| [`common/`](../common/) | The shared storage / type-mapping / DML / transaction / utility layer. |
| [`server-patches/`](../server-patches/) | The MySQL server patches the engine depends on (pushdown hook, bulk-load fast path, semijoin suppression). |
| [`cmake/`](../cmake/) | DuckDB acquisition (prebuilt prefix, or built from source via `ExternalProject`). |
| [`engine/test/`](../engine/test/) | Standalone GoogleTest / CTest unit suite. |
| [`mysql-test-suite/`](../mysql-test-suite/) | MySQL Test Runner (MTR) tests, suite name `duckdb`. |
| [`bench/`](../bench/) | Benchmark harness (InnoDB vs. the DuckDB engine vs. native DuckDB). |
