# Usage

This guide shows how to create `ENGINE=DuckDB` tables, load data, run analytical
queries that execute inside DuckDB, confirm that a query was actually pushed down,
and what is and is not supported. All examples are runnable and follow the rules
the engine actually enforces.

There is no plugin to install and no secondary engine to load. Create a table
with `ENGINE=DuckDB` and use it like any other table.

## Creating tables

```sql
CREATE DATABASE shop;
USE shop;

CREATE TABLE sales (
    id       INT PRIMARY KEY,
    sale_yr  INT,
    region   INT,
    price    DECIMAL(12,2),
    qty      INT
) ENGINE=DuckDB;
```

A primary key is recommended: it is what `UPDATE` and `DELETE` use to locate rows.
Each schema's tables live in a single per-schema file
(`<datadir>/shop.duckdb`), created on first use.

## Loading data

Both `INSERT` and `LOAD DATA` work. `INSERT ... VALUES` and `LOAD DATA` use a fast
bulk-append path internally.

```sql
INSERT INTO sales VALUES
 (1, 2021, 1, 100.00, 10),
 (2, 2021, 1, 200.50, 20),
 (3, 2022, 2, 300.25, 30),
 (4, 2022, 3, 400.00, 40),
 (5, 2022, 2, 500.75, 50),
 (6, 2023, 1, 600.00, 60);
```

```sql
-- Bulk load from a file (one row per line, tab-separated by default).
LOAD DATA INFILE '/path/to/sales.tsv' INTO TABLE sales;
```

`UPDATE`, `DELETE`, and `TRUNCATE` behave normally:

```sql
UPDATE sales SET qty = 99 WHERE id = 2;
DELETE FROM sales WHERE id = 6;
TRUNCATE TABLE sales;
```

## Confirming a query ran in DuckDB

The status variable `Ducksdb_pushdown_count` counts queries whose execution was
taken over by DuckDB. Snapshot it before and after a query to see whether that
query was pushed down:

```sql
SHOW GLOBAL STATUS LIKE 'Ducksdb_pushdown_count';
```

A convenient pattern (used in the engine's own tests) is to capture the counter,
run the query, then read the delta:

```sql
SELECT VARIABLE_VALUE INTO @before FROM performance_schema.global_status
  WHERE VARIABLE_NAME = 'Ducksdb_pushdown_count';

SELECT region, COUNT(*) c, SUM(qty) sq
  FROM sales WHERE sale_yr >= 2022 GROUP BY region ORDER BY region;

SELECT VARIABLE_VALUE - @before AS pushed FROM performance_schema.global_status
  WHERE VARIABLE_NAME = 'Ducksdb_pushdown_count';
-- pushed = 1  -> the query executed in DuckDB
-- pushed = 0  -> it ran through normal MySQL execution
```

A second status variable, `Ducksdb_open_instances`, reports how many per-schema
DuckDB instances are currently open:

```sql
SHOW GLOBAL STATUS LIKE 'Ducksdb_open_instances';
```

## Query examples

The examples below assume the `sales` table above, reloaded with its six original
rows. Each notes whether it is pushed to DuckDB.

### Scan + filter + aggregate (pushed)

```sql
SELECT COUNT(*) n, SUM(qty) total_qty, SUM(price * qty) revenue
  FROM sales
 WHERE sale_yr >= 2022;
```

This is an implicitly grouped aggregate over a `WHERE` filter with arithmetic in
the select list — fully translatable, so it runs in DuckDB.

### GROUP BY (pushed)

```sql
SELECT region, COUNT(*) c
  FROM sales
 GROUP BY region
 ORDER BY region;
```

```
region  c
1       3
2       2
3       1
```

### Multi-aggregate (pushed)

```sql
SELECT COUNT(*) n, MIN(price) lo, MAX(price) hi, AVG(qty) avg_qty
  FROM sales;
```

```
n   lo      hi      avg_qty
6   100.00  600.00  35.0000
```

### Multi-aggregate with GROUP BY and a computed measure (pushed)

```sql
SELECT region,
       COUNT(*)            c,
       SUM(qty)            sq,
       SUM(price * qty)    rev
  FROM sales
 WHERE sale_yr >= 2022
 GROUP BY region
 ORDER BY region;
```

```
region  c   sq   rev
1       1   60   36000.00
2       2   80   34045.00
3       1   40   16000.00
```

### COUNT(DISTINCT) (pushed)

```sql
SELECT COUNT(DISTINCT region) AS regions,
       COUNT(DISTINCT sale_yr) AS years
  FROM sales;
```

`COUNT(DISTINCT ...)`, `SUM(DISTINCT ...)`, and `AVG(DISTINCT ...)` are all
supported aggregate shapes.

### Star join + group (pushed)

Joins push down when all tables are `ENGINE=DuckDB` and live in the **same
schema**, and the join is an inner join. Add a dimension table and group across
the join:

```sql
CREATE TABLE regions (
    region INT PRIMARY KEY,
    name   VARCHAR(32)
) ENGINE=DuckDB;

INSERT INTO regions VALUES (1,'North'), (2,'South'), (3,'West');

SELECT r.name, COUNT(*) c, SUM(s.price * s.qty) rev
  FROM sales s, regions r
 WHERE s.region = r.region
   AND s.sale_yr >= 2022
 GROUP BY r.name
 ORDER BY r.name;
```

The engine renders the inner join as a cross product plus the equality conjunct,
which is exactly an inner join in DuckDB. (An explicit `JOIN ... ON` inner join
with the same predicate is equally valid.)

### ORDER BY / LIMIT (pushed when aggregated)

```sql
SELECT region, SUM(qty) sq
  FROM sales
 GROUP BY region
 ORDER BY sq DESC
 LIMIT 2;
```

`ORDER BY` direction and an explicit `LIMIT`/`OFFSET` are rendered (the limit and
offset are bound as parameters).

### Point lookup / non-aggregate scan (not pushed, still correct)

```sql
SELECT id, sale_yr, region FROM sales WHERE id = 3;
```

This is not an aggregate query, so the whole-query builder declines and the row is
served through the normal handler read path. `Ducksdb_pushdown_count` does not
change. The result is identical either way.

### EXPLAIN (always a normal plan)

```sql
EXPLAIN SELECT region, COUNT(*) FROM sales GROUP BY region;
```

The pushdown hook is disabled under `EXPLAIN`, so you always get a normal MySQL
plan rather than an opaque pushed query.

## Supported data types

The type bridge (`common/duckdb_types.cc`) maps MySQL column types to DuckDB:

| MySQL type | DuckDB type | Notes |
|------------|-------------|-------|
| `TINYINT` / `SMALLINT` / `MEDIUMINT` / `INT` / `BIGINT` | matching width `TINYINT`…`BIGINT`, unsigned variants for `UNSIGNED` | |
| `FLOAT` | `FLOAT` | |
| `DOUBLE` | `DOUBLE` | |
| `DECIMAL(p,s)` | `DECIMAL(p,s)` | exact scaled-integer round trip for precision ≤ 18; wider precisions use a string round trip |
| `CHAR` / `VARCHAR` | `VARCHAR` | |
| `BINARY` / `VARBINARY` / `BLOB` family | `BLOB` | |
| `DATE` | `DATE` | |
| `DATETIME` | `TIMESTAMP` | stored as the verbatim wall clock |
| `TIMESTAMP` | `TIMESTAMP` | stored via the UTC instant, so reads are independent of session time zone |
| `TIME` | `TIME` | |
| `JSON` | `VARCHAR` | stored as the JSON text |
| `BOOL` | `BOOLEAN` | |

Creating a table with a column type outside this set fails with a clear error
rather than creating a partial table.

### Temporal correctness

`TIMESTAMP` is UTC-stored in MySQL, so it is converted through the UTC epoch — the
stored instant is independent of the writing session's time zone, and any session
reads back the same instant. `DATETIME`, `DATE`, and `TIME` are time-zone-naive
and round-trip through MySQL's canonical string form.

## Collation behavior and pushdown

A query is only pushed down when every string column's collation can be rendered
faithfully in DuckDB. The mapping:

| Collation kind | Behavior |
|----------------|----------|
| `_bin` / binary (byte-comparable) | pushed (DuckDB's default byte comparison matches) |
| accent- and case-insensitive default family (`utf8mb4_0900_ai_ci`, `_general_ci`, `_unicode_ci`) | pushed using `COLLATE NOCASE` |
| case-sensitive non-binary, accent-sensitive `_ci`, or unknown collations | the query declines and runs in normal MySQL |

Declining keeps ordering, grouping, and `DISTINCT` results correct: the engine
never risks a different result by guessing at an unmapped collation.

## What pushes down vs. what declines

Pushed down (when all base tables are `ENGINE=DuckDB` in one schema):

- Aggregate queries (grouped or implicitly grouped): `COUNT`, `COUNT(*)`,
  `COUNT(DISTINCT)`, `SUM`, `SUM(DISTINCT)`, `AVG`, `AVG(DISTINCT)`, `MIN`, `MAX`.
- `WHERE` predicates built from `=`, `<>`, `<`, `<=`, `>`, `>=`, `BETWEEN`, `IN`,
  `IS NULL`, `IS NOT NULL`, combined with `AND` / `OR`.
- Scalar arithmetic `+`, `-`, `*`, `/` in select / predicate operands.
- `GROUP BY`, `HAVING`, `ORDER BY` (with `ASC`/`DESC`), explicit `LIMIT`/`OFFSET`,
  and `DISTINCT`.
- Inner joins within a single schema (rendered as cross product + `WHERE`).
- Integer, `DECIMAL`, and `NULL` literals.

Declines to normal MySQL execution (always still correct):

- Non-aggregate queries (plain row reads, point lookups).
- `UNION`, subqueries, window functions, `ROLLUP`.
- Outer joins, nested-join trees, and cross-schema joins (different `.duckdb`
  files).
- Any non-whitelisted function: string functions, date functions, `CASE` / `IF`,
  `CAST`, `GROUP_CONCAT`, JSON aggregates, statistical aggregates, etc.
- `REAL`/`DOUBLE`, string, and temporal literals (to avoid floating-point,
  charset, and parse ambiguity).
- Columns whose collation does not map (see above).
- Statements with bound parameters, and any query under `EXPLAIN`.

## Transactions

The engine participates in MySQL's transactions. Within a single schema, multiple
statements in a `BEGIN ... COMMIT` block are committed or rolled back together:

```sql
BEGIN;
INSERT INTO sales VALUES (7, 2024, 2, 700.00, 70);
UPDATE sales SET qty = 0 WHERE id = 1;
ROLLBACK;   -- both statements are undone
```

```sql
BEGIN;
INSERT INTO sales VALUES (8, 2024, 1, 800.00, 80);
COMMIT;     -- persisted
```

In autocommit mode each statement commits at its boundary. XA two-phase commit is
supported through the engine's prepare / commit-by-XID / rollback-by-XID
callbacks.

## Current limitations

These follow directly from the implementation:

- **One schema per query for pushdown.** Each schema is a separate `.duckdb`
  file, so a pushed query (or join) cannot span schemas; such queries decline to
  normal execution, and cross-schema `RENAME TABLE` is rejected.
- **`ALTER TABLE` uses the copy path.** In-place `ALTER` is not supported; MySQL
  performs alterations by creating a new table, copying rows, and swapping.
- **`UPDATE`/`DELETE` need a primary key for the prepared fast path.** Without a
  primary key there is no unique row locator for the prepared statement.
- **XA prepared branches are in memory only.** Prepared transactions do not
  survive a server crash or restart — on restart there are none to recover (they
  roll back when their connections close). A multi-schema XA commit is
  best-effort because there is no cross-file two-phase commit.
- **Pushdown is for analytical (aggregate) queries.** Non-aggregate `SELECT`s run
  through the normal row path by design; they are correct but not column-store
  accelerated.
- **Literal and collation gating.** Floating-point, string, and temporal literals
  and unmapped collations cause a query to decline rather than risk a divergent
  result.
