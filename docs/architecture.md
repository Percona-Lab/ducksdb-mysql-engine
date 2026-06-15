# Architecture

This document describes the components of the DuckDB storage engine, how they fit
together, and the data flow for each important code path: DDL, the write path,
the read path, whole-query pushdown, and transactions. It also explains the
decline contract (when a query is pushed down versus when it falls back to normal
MySQL execution) and the per-schema file model.

## Components

The engine is built into `mysqld` and is organized in three layers: the handler
shim (`engine/`), the shared bridge layer (`common/`), and embedded DuckDB. A
small server patch adds the `pushdown_select` hook that the engine uses for
whole-query offload.

```mermaid
flowchart TB
    client["MySQL client / application"]

    subgraph server["mysqld (MySQL 9.7 server)"]
        sqllayer["SQL layer: parser / resolver / optimizer"]
        joinopt["JOIN::optimize()\n(pushdown_select hook — server patch)"]
        handlerapi["Handler API\n(open/close, rnd_*, index_*,\nwrite/update/delete_row, info)"]
    end

    subgraph engine["engine/ — DuckDB storage engine"]
        ha["ha_duckdb\n(handler + handlerton registration)"]
        pd["duckdb_pushdown\n(whole-query AST→SQL builder,\nExecutePushdown, PlanRegistry)"]
    end

    subgraph common["common/ — shared bridge layer"]
        ctx["EngineContext\n(per-schema DuckDB instance registry)"]
        types["duckdb_types\n(MySQL ↔ DuckDB type mapping)"]
        ddl["ddl_convertor"]
        dml["dml_convertor"]
        scan["duckdb_scan (ScanCursor)"]
        appender["duckdb_appender (BulkAppender)"]
        xa["duckdb_xa\n(per-THD connections, commit/rollback/XA)"]
        cond["cond_pushdown\n(WHERE superset translation)"]
        util["duckdb_sql_util\n(QuoteIdent / FieldLiteral)"]
    end

    subgraph duck["Embedded DuckDB (static library)"]
        instr["DuckDB instances"]
        files[("Per-schema files:\nshop.duckdb, analytics.duckdb, ...")]
    end

    client --> sqllayer --> joinopt
    joinopt -->|"all base tables ENGINE=DuckDB"| pd
    sqllayer --> handlerapi --> ha
    ha --> ddl & dml & scan & appender & cond & util & xa & ctx
    pd --> ctx & types
    ha --> types
    ctx --> instr --> files
    xa --> instr
```

### Layer responsibilities

- **`ha_duckdb`** (`engine/ha_duckdb.cc`, `.h`) — the MySQL `handler` subclass.
  It implements DDL (`create` / `delete_table` / `rename_table`), table open and
  close, sequential scans (`rnd_init` / `rnd_next` / `rnd_end`), index reads
  (`index_init` / `index_read_map` / `index_next` / `index_first` /
  `index_last`), single-row writes (`write_row` / `update_row` / `delete_row`),
  bulk insert (`start_bulk_insert` / `end_bulk_insert`), `truncate`, and
  optimizer statistics (`info` / `records_in_range`). It also registers the
  handlerton callbacks in `ducksdb_init_func`, including the transaction/XA
  callbacks and the `pushdown_select` hook.

- **`duckdb_pushdown`** (`engine/duckdb_pushdown.cc`, `.h`) — the whole-query
  pushdown. `PushdownSelect` is the `handlerton::pushdown_select` callback.
  `BuildPushdownSQLBuilder` is a recursive AST-to-SQL builder (`RenderFrom`,
  `RenderExpr`, `RenderAggregate`, `RenderPredicate`, `RenderSelectItem`) that
  turns the optimized `JOIN` into parameterized DuckDB SQL. `ExecutePushdown` is
  installed as `JOIN::override_executor_func` and streams the DuckDB result back
  through the statement's `Query_result`. `MapCollation` decides how a MySQL
  collation maps into DuckDB. A process-global counter backs the
  `Ducksdb_pushdown_count` status variable.

- **`EngineContext`** (`common/duckdb_engine_context.cc`, `.h`) — the per-mysqld
  registry that maps each MySQL schema to one DuckDB instance (one `.duckdb`
  file), creating it lazily and serving `Connection()` factories on it. Backs the
  `Ducksdb_open_instances` status variable.

- **`duckdb_types`** (`common/duckdb_types.cc`) — the type bridge:
  `MySQLToDuckDB` (column type mapping), `AppendField` (write a MySQL field into a
  DuckDB Appender), `FieldToValue` (a MySQL field to a bound DuckDB `Value`),
  `StoreField` / `StoreFlatCell` (a DuckDB cell back into a MySQL field).

- **`ddl_convertor`** / **`dml_convertor`** — build DuckDB `CREATE TABLE` /
  `DROP TABLE` / `ALTER TABLE ... RENAME` SQL, and the parameterized
  `UPDATE`/`DELETE` statements plus their bind-parameter packing.

- **`duckdb_scan`** (`ScanCursor`) — runs a materialized `SELECT` against a table
  and iterates the result chunk by chunk.

- **`duckdb_appender`** (`BulkAppender`) — wraps a DuckDB `Appender` for fast
  bulk insert.

- **`duckdb_xa`** — per-THD connection state (`ThdState`) and the transaction /
  XA handlerton callbacks.

- **`cond_pushdown`** — translates the safely-pushable, superset part of a
  handler-level pushed condition (`cond_push`) into a DuckDB `WHERE` applied
  during scans.

### The server patch

The engine depends on one server patch,
[`server-patches/0001-engine-query-pushdown.patch`](../server-patches/0001-engine-query-pushdown.patch),
applied into the MySQL source tree by `scripts/build-server.sh`. It adds:

- `sql/handler.h` — the `pushdown_select_t` typedef and a
  `handlerton::pushdown_select` member. The member is zero-filled by default, so
  it is null for every other engine and ABI-safe.
- `sql/sql_optimizer.cc` — a `single_engine_for_pushdown()` helper that returns
  the common handlerton iff every base table of the query block belongs to the
  same engine, and a call near the tail of `JOIN::optimize()` (gated on
  `!is_explain()`) that invokes that engine's `pushdown_select`. If the engine
  sets `JOIN::override_executor_func`, the optimizer installs a trivial root
  access path and marks the plan ready; the override runs the query instead.
  Declining leaves normal iterator execution untouched.

## Per-schema file model

Each MySQL schema maps to exactly one DuckDB database file. `EngineContext`
computes the path as `<mysql_real_data_home>/<schema>.duckdb` and keeps a
process-wide registry of open instances, created lazily on first use and
protected by a shared mutex.

```mermaid
flowchart LR
    subgraph mysql["MySQL schemas"]
        s1["schema: shop"]
        s2["schema: analytics"]
    end
    subgraph ctx["EngineContext registry"]
        i1["DuckDB instance (shop)"]
        i2["DuckDB instance (analytics)"]
    end
    subgraph dd["datadir"]
        f1[("shop.duckdb")]
        f2[("analytics.duckdb")]
    end
    s1 --> i1 --> f1
    s2 --> i2 --> f2
```

A direct consequence is that a single DuckDB statement cannot span two schemas:
the whole-query pushdown builder enforces a **single-schema guard** (all base
tables must live in the same `.duckdb` file), and cross-schema `RENAME` is
rejected because an in-file rename cannot move a table to a different file.

## DDL path: CREATE TABLE → DuckDB

When a client issues `CREATE TABLE ... ENGINE=DuckDB`, MySQL calls
`ha_duckdb::create`. The handler parses the schema and table name out of the
path-style argument, builds a DuckDB `CREATE TABLE` from the MySQL column
definitions and primary key, and runs it on a connection to that schema's file.
`DROP TABLE`, `RENAME`, and `TRUNCATE` follow the same shape.

```mermaid
sequenceDiagram
    participant C as Client
    participant S as MySQL SQL layer
    participant H as ha_duckdb
    participant D as ddl_convertor + duckdb_types
    participant X as EngineContext
    participant K as DuckDB (schema file)

    C->>S: CREATE TABLE t (...) ENGINE=DuckDB
    S->>H: create(name, form, create_info)
    H->>H: parse_db_table(name) -> (db, tbl)
    H->>D: BuildCreateTableSQL(db, tbl, form)
    D->>D: MySQLToDuckDB(field) per column (decline INVALID types)
    D-->>H: CREATE TABLE "t" (...)
    H->>X: Connection(db)
    X-->>H: connection on db.duckdb
    H->>K: Query(CREATE TABLE ...)
    K-->>H: ok / error
    H-->>S: 0 / HA_ERR_GENERIC (+ DuckDB message)
```

Unsupported column types cause `BuildCreateTableSQL` to throw, which the handler
turns into a clear error rather than creating a partial table.

## Write path

There are three write shapes. Bulk insert (the `INSERT ... VALUES` /
`LOAD DATA` path) uses a DuckDB `Appender` for speed. `UPDATE` and `DELETE` use
parameterized prepared statements keyed on the primary key. All writes route
through the per-THD, transaction-scoped connection (`txn_conn()`), which begins
the DuckDB transaction once and registers the engine with MySQL's transaction
coordinator.

```mermaid
sequenceDiagram
    participant S as MySQL SQL layer
    participant H as ha_duckdb
    participant A as BulkAppender / dml_convertor
    participant T as ThdState (duckdb_xa)
    participant K as DuckDB (schema file)

    Note over S,H: INSERT (bulk)
    S->>H: start_bulk_insert(rows)
    H->>A: open Appender on table
    loop each row
        S->>H: write_row(buf)
        H->>A: AppendRow(table) via AppendField per column
    end
    S->>H: end_bulk_insert()
    H->>A: Flush()
    H->>H: invalidate cached row count

    Note over S,H: UPDATE / DELETE
    S->>H: update_row(old,new) / delete_row(buf)
    H->>T: txn_conn() (Begin once, RegisterTx)
    H->>A: BuildPreparedUpdateSQL/DeleteSQL (once), Bind params
    A->>K: prepared Execute (PK-located)
    K-->>H: ok / duplicate-key / error
    H->>H: invalidate cached row count
```

The prepared `UPDATE`/`DELETE` plans are created lazily on first use and dropped
at the statement boundary (`reset()`). If the primary key is absent, or the
prepared plan cannot be built, the engine falls back to a per-row prepared
statement built from the row's values (still parameterized, never string
concatenation). DuckDB errors are mapped to MySQL handler codes
(`MapDuckDBError`), so a unique-constraint violation surfaces as `ER_DUP_ENTRY`.

## Read path (point lookup / scan)

A non-pushed query reads rows through the handler API. `rnd_init` opens a
materialized `SELECT` projecting only the columns the optimizer reads (plus the
primary key, so `UPDATE`/`DELETE` can locate rows). Index reads add a `WHERE`
derived from the key and the comparison operator, plus any condition pushed via
`cond_push`. Results are fetched chunk by chunk and decoded directly from
DuckDB's column vectors with typed accessors (`StoreFlatCell`).

```mermaid
sequenceDiagram
    participant S as MySQL SQL layer
    participant H as ha_duckdb
    participant SC as ScanCursor (duckdb_scan)
    participant K as DuckDB (schema file)

    S->>H: rnd_init(scan) / index_read_map(key, flag)
    H->>H: build_projection() (read_set + PK)
    opt index read
        H->>H: WHERE from key parts + cond_push
    end
    H->>SC: Init(select_list, where, order)
    SC->>K: SELECT ... (materialized: Query, not stream)
    K-->>SC: result, first chunk (flattened)
    loop each row
        S->>H: rnd_next / index_next
        H->>SC: Next(&chunk, &row)
        H->>H: StoreFlatCell into record[0]
    end
```

The scan deliberately materializes the result (`Query`, not a streaming
`SendQuery`) so a full-scan `UPDATE`/`DELETE` that issues per-row writes on the
same connection mid-scan does not deadlock against a busy streaming cursor.

## Whole-query pushdown path

This is the analytical fast path. After the optimizer finishes a query whose base
tables are all `ENGINE=DuckDB`, the server hook calls `PushdownSelect`. The
builder walks the optimized query block and, if every node is translatable,
produces parameterized DuckDB SQL, prepares it once, and stashes the plan in a
per-THD registry. The optimizer then installs `ExecutePushdown` as the override
executor. At execute time the prepared statement runs in DuckDB and the result is
staged into a temporary table and streamed back to the client.

```mermaid
sequenceDiagram
    participant C as Client
    participant J as JOIN::optimize() (server patch)
    participant P as PushdownSelect (duckdb_pushdown)
    participant B as BuildPushdownSQLBuilder
    participant R as PlanRegistry (per-THD)
    participant E as ExecutePushdown (override_executor_func)
    participant K as DuckDB (schema file)
    participant Q as Query_result

    C->>J: SELECT ... FROM duckdb_tables ...
    J->>P: pushdown_select(thd, join)
    P->>B: BuildPushdownSQLBuilder(thd, join)
    B->>B: gates (simple, grouped, no subquery/window/rollup)
    B->>B: RenderFrom / RenderSelectItem / RenderPredicate / RenderAggregate / GROUP BY / ORDER BY / LIMIT
    alt any node not translatable
        B-->>P: false (DECLINE)
        P-->>J: return false, override unset
        J->>J: normal iterator execution (fallback)
    else fully translatable
        B-->>P: SQL + bound params + schema
        P->>K: Connection(db).Prepare(sql)
        P->>R: Put(thd, plan{conn, prepared})
        P-->>J: set override_executor_func, return false
        J->>E: run override executor
        E->>R: Take(thd) -> plan
        E->>K: prepared Execute(params)
        K-->>E: materialized result (chunks)
        E->>E: stage in temp table, StoreFlatCell per cell
        loop each row
            E->>Q: send_data(row)
        end
        E->>E: Ducksdb_pushdown_count += 1
    end
```

### The decline contract

The builder is a **partial function**: every `Render*` helper returns success or
declines, and any decline bubbles up so `BuildPushdownSQLBuilder` returns false
and MySQL executes the query normally. Declining is always safe; emitting SQL
that is not provably identical is not. The builder never concatenates literals —
every literal is bound as a positional DuckDB parameter (`$1`, `$2`, ...), which
removes the escaping and injection surface entirely.

A query is pushed down only when **all** of the following hold:

- It is a simple (non-`UNION`) query block with at least one base table.
- It is grouped or implicitly grouped (an aggregate query) — the worthwhile
  offload case.
- It has no subquery, no window function, and no `ROLLUP`.
- It has no statement parameters.
- Every base table is `ENGINE=DuckDB` and all tables share one schema (one
  `.duckdb` file). Outer joins and nested-join trees decline; an inner join is
  rendered as a cross product plus a `WHERE` conjunct.
- Every select-list item, predicate, `GROUP BY` / `ORDER BY` term, and aggregate
  renders. Supported aggregates are `COUNT`, `COUNT(*)`, `COUNT(DISTINCT)`,
  `SUM`, `SUM(DISTINCT)`, `AVG`, `AVG(DISTINCT)`, `MIN`, `MAX`. Supported scalar
  operators are `+ - * /` and the comparison/`BETWEEN`/`IN`/`IS [NOT] NULL`
  predicates. Every other function (string, date, `CASE`, `CAST`, `GROUP_CONCAT`,
  window aggregates, etc.) declines.
- Every literal maps exactly: integers and `DECIMAL` are bound; `NULL` is bound
  as a typed NULL. `REAL`/`DOUBLE`, string, and temporal literals decline (ULP
  drift, charset, and parse ambiguity respectively).
- Every string column's collation maps (see below); otherwise it declines so a
  case or accent difference cannot change ordering, grouping, or `DISTINCT`.
- `EXPLAIN` is excluded by the server hook, so `EXPLAIN` always shows a normal
  plan.

Because the optimizer hook only fires when every base table belongs to one
engine, non-`ENGINE=DuckDB` queries are never offered to the engine in the first
place, and a mixed-engine join is never a candidate.

### Collation mapping

`MapCollation` decides how a column's collation renders in DuckDB:

| MySQL collation kind | DuckDB rendering | Result |
|----------------------|------------------|--------|
| `_bin` / `binary` (byte-comparable) | default byte compare, no `COLLATE` | push down |
| accent- and case-insensitive default family (`_ai_ci`, `_general_ci`, `_unicode_ci`) | `COLLATE NOCASE` | push down |
| case-sensitive non-binary, accent-sensitive `_ci`, or unknown | — | decline |

This keeps ordering, grouping, and `DISTINCT` semantics faithful for the common
default-collation and binary cases, and conservatively declines anything whose
ordering `NOCASE` does not approximate.

### Plan lifetime

The prepared plan (and its DuckDB connection) is owned by a registry keyed by the
owning `THD`, not by a thread-local. A `THD` runs its statements serially, so at
most one plan is live per session. `PushdownSelect` drops any stale plan, installs
the new one, and `ExecutePushdown` takes and releases it (its `unique_ptr`
releases the connection deterministically). The `close_connection` handlerton
callback releases any plan left by an optimize-without-execute, so a connection
cannot leak past disconnect even under a thread pool.

## Transaction / commit (XA) flow

Each connection (`THD`) keeps one DuckDB connection per schema it has touched,
held in a `ThdState` stored on `THD->ha_data`. The first DML or scan begins the
DuckDB transaction (once) and registers the engine with MySQL's transaction
coordinator, so MySQL drives the engine's commit and rollback.

```mermaid
sequenceDiagram
    participant C as Client
    participant S as MySQL transaction coordinator
    participant H as ha_duckdb / duckdb_xa
    participant T as ThdState (per-THD connections)
    participant K as DuckDB

    C->>H: first DML/scan in statement
    H->>T: Acquire(schema) + Begin (BEGIN TRANSACTION once)
    H->>S: trans_register_ha (statement, and real txn if open)

    alt COMMIT / autocommit statement end
        C->>S: COMMIT
        S->>H: Commit(thd, all)
        H->>T: COMMIT on each connection
        H->>H: ResetThdState (close connections)
    else ROLLBACK
        C->>S: ROLLBACK
        S->>H: Rollback(thd, all)
        H->>T: ROLLBACK on each connection
    end

    Note over S,H: XA two-phase
    C->>S: XA PREPARE
    S->>H: Prepare(thd, all)
    H->>H: hand open connections to XID-keyed registry (not committed)
    C->>S: XA COMMIT / XA ROLLBACK (any session)
    S->>H: CommitByXid / RollbackByXid
    H->>K: COMMIT / ROLLBACK on the prepared connections
```

A statement-level commit inside an explicit `BEGIN ... COMMIT` transaction is a
no-op; the DuckDB transaction stays open until the explicit `COMMIT`/`ROLLBACK`.
The handlerton callbacks are C-ABI boundaries, so each body is wrapped to never
let a C++ exception escape into `mysqld`.

For XA, `Prepare` hands the THD's still-open connections to an in-memory registry
keyed by the XID; `CommitByXid` / `RollbackByXid` can finish them from any
session with real DuckDB semantics. Because the prepared state lives only in
memory, prepared branches do not survive a crash or restart — `Recover` returns
none, which is the documented limitation of the in-memory strategy. Each schema
is a separate DuckDB file with no cross-file two-phase commit, so a multi-schema
XA commit is best-effort: if one branch fails to commit, the remaining
not-yet-committed branches are rolled back to limit divergence.
