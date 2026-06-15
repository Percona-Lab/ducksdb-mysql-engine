# bench — TPC-H benchmark harness

Benchmarks for the **in-tree DuckDB engine** (`ENGINE=DuckDB` tables that
auto-offload analytical queries into DuckDB — no `SECONDARY_ENGINE=` /
`SECONDARY_LOAD` ceremony, unlike the sibling loadable plugin).

## `run-tpch22.sh` — full 22-query TPC-H suite

Runs the complete official 22-query TPC-H workload and, **per query**, compares
three execution paths over the same data and **checks correctness**:

| Column        | What it measures |
|---------------|------------------|
| `InnoDB(s)`   | Standard MySQL row store, no acceleration. Also the **correctness oracle**. |
| `engine(s)`   | A plain `ENGINE=DuckDB` table in the in-tree server (auto-offload). |
| `native(s)`   | DuckDB CLI on a local file — the analytical upper bound. |
| `offloaded?`  | `yes` if `Ducksdb_secondary_offload_count` rose during the engine run (query actually ran in DuckDB). |
| `match?`      | `yes` if the engine result set equals InnoDB's (order-independent md5). `SKIP`/`—` if the query couldn't run on MySQL. |

Timing alone is meaningless if the answer is wrong — hence `match?`.

### Prerequisites

1. **Docker.** Everything runs in containers; nothing is installed on the host.
2. **Native DuckDB image** `ducksdb-duckdb:1.5.3` (used for data generation and
   the native leg). If you don't have it, build it from the sibling repo's
   `bench/analytical/Dockerfile.duckdb`:
   ```bash
   docker build --build-arg DUCKDB_VERSION=1.5.3 \
     -t ducksdb-duckdb:1.5.3 -f Dockerfile.duckdb .
   ```
3. **The in-tree engine server image** — **this does not exist yet.** It is
   produced once the in-tree build (`ENGINE=DuckDB` CRUD) and the full 22-query
   TPC-H validation are in place. Until that image is built, the harness
   **preflight-fails with a clear message** — this is expected. It is groundwork.

   Once built, point the harness at it:
   ```bash
   IMAGE=ducksdb/mysql-engine:9.7 bench/run-tpch22.sh
   ```

### Running

```bash
# defaults: SF=1, ITERS=3, IMAGE=ducksdb/mysql-engine:9.7
bench/run-tpch22.sh

# bigger scale factor, more iterations
SF=10 ITERS=5 bench/run-tpch22.sh

# only a subset of queries (handy while iterating on the engine)
ONLY="1 6 14" bench/run-tpch22.sh

# custom engine image
IMAGE=my-registry/ducksdb-engine:dev bench/run-tpch22.sh
```

### Environment variables

| Var | Default | Meaning |
|-----|---------|---------|
| `SF` | `1` | TPC-H scale factor (`CALL dbgen(sf=SF)`). |
| `ITERS` | `3` | Timed iterations per query (min reported; 1 warmup excluded). |
| `IMAGE` | `ducksdb/mysql-engine:9.7` | In-tree engine server image (**placeholder until the engine image is built**). |
| `DUCKDB_VERSION` | `1.5.3` | Native DuckDB CLI version (image `ducksdb-duckdb:$VER`). |
| `CPUS` / `MEM` | `6` / `8g` | Per-container resource pins. |
| `INNODB_POOL` | `2G` | InnoDB buffer pool size. |
| `QTIMEOUT` | `300` | Per-query timeout (seconds). |
| `ONLY` | *(empty)* | Space-separated query numbers to run, e.g. `"1 6 14"`. |

### Outputs

A timestamped dir under `bench/results/tpch22-sf<SF>-<ts>/`:

- `SUMMARY.txt` — the per-query table plus the pass/mismatch/skip tally.
- `load.err`, `run.err` — stderr from loads and query runs.
- `mismatch.log` — any query whose engine result diverged from InnoDB, with both checksums.

Extracted/translated queries are cached under `bench/data-sf<SF>/queries/`
(`qNN.duckdb.sql` = verbatim, `qNN.mysql.sql` = MySQL-dialect translation).

## How it works

1. **Data generation.** DuckDB's `tpch` extension (`CALL dbgen(sf=N)`) builds the
   8 standard tables, then exports one `|`-delimited CSV per table. CSVs are
   cached on `SF`.
2. **Queries.** The 22 canonical queries are pulled at runtime from
   `SELECT query FROM tpch_queries()` (DuckDB dialect), cached once.
3. **Schema.** The standard 8 TPC-H tables (region, nation, supplier, customer,
   part, partsupp, orders, lineitem) are created in both an InnoDB database and an
   `ENGINE=DuckDB` database, plus loaded into a native DuckDB file. Money columns
   are `DECIMAL(15,2)`, dates `DATE`, keys `INT`/`BIGINT`, strings `CHAR`/`VARCHAR`.
4. **Execution.** Native DuckDB runs the queries verbatim. The two MySQL legs
   (InnoDB + engine) get the dialect translation below. Each leg is timed (min of
   `ITERS`, one warmup) and the engine's result is checksum-compared to InnoDB's.

### TPC-H-on-MySQL dialect caveats (encoded in `to_mysql_dialect`)

The canonical queries are **DuckDB dialect**. Most are plain SQL-92 and run on
MySQL unchanged. The mechanical translation handles the constructs that actually
differ in the official query text:

- **Interval date arithmetic.** DuckDB/Postgres write
  `date '1994-01-01' + interval '1' year`. MySQL needs
  `DATE_ADD(DATE '1994-01-01', INTERVAL 1 YEAR)` (and `DATE_SUB` for `-`). The
  bare `interval 'N' unit` form is rewritten to `INTERVAL N UNIT`. This affects
  the date-range predicates in **Q1, Q4, Q5, Q6, Q7, Q10, Q12, Q14, Q15, Q20**.
- **`extract(year from x)`** is left as-is — MySQL supports
  `EXTRACT(YEAR FROM x)` (used in Q7, Q8, Q9).
- **`substring(x from a for b)`** is left as-is — MySQL supports the SQL-standard
  form (used in Q22's `substring(c_phone from 1 for 2)`).
- **`'lit'::date` casts** (rare in TPC-H text) are rewritten to `DATE 'lit'`.

If a translated query still fails to parse/run on MySQL, that query is marked
**`SKIP`** for *both* MySQL legs (so the run never aborts), while native DuckDB
still reports a time. Inspect/hand-fix the cached `qNN.mysql.sql` and re-run with
`ONLY=NN` if you want to cover it. Known candidates that may need manual
attention depending on MySQL version: **Q13** (`count(o_orderkey)` correlated
left-join phrasing is portable, but the `not like '%...%'` is fine),
**Q15** (uses a `CREATE VIEW`/`WITH` revenue view — the DuckDB text uses a CTE,
which MySQL 8+ supports), and **Q22** (correlated `avg` subquery — portable).
These are flagged as the most likely to want a second look, not guaranteed
failures.

## Status / groundwork note

This harness is **correct and complete but not yet runnable end-to-end** because
the in-tree engine server image is built later. The data-generation and
native-DuckDB paths are exercisable today. When the engine image lands, the only
change needed is a real `IMAGE=` value.
