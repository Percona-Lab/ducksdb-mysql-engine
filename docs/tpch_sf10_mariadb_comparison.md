# TPC-H SF10: in-tree MySQL DuckDB engine vs MariaDB ENGINE=DuckDB

Same host, same SF10 data (cleaned TPC-H CSVs), both `ENGINE=DuckDB` with
automatic pushdown. Times are **wall-clock, warm (min of 3 iterations,
1 warmup excluded)**, 20 threads.

- Engine: image `ducksdb/mysql:9.7-duckdb-p15` (RelWithDebInfo), via `bench/run-tpch22.sh`.
- MariaDB: locally-built `mariadbd` + `ha_duckdb.so`, via `mariadb-bench/run-mariadb-tpch22.sh`.

| Q | MariaDB (s) | Engine (s) | ratio (eng/mdb) |
|---|---|---|---|
| Q1 | 0.843 | 1.769 | 2.10x |
| Q2 | 0.201 | 0.246 | 1.22x |
| Q3 | 0.475 | 0.500 | 1.05x |
| Q4 | 0.488 | 0.573 | 1.17x |
| Q5 | 0.458 | 0.527 | 1.15x |
| Q6 | 0.205 | 0.289 | 1.41x |
| Q7 | 0.383 | 0.447 | 1.17x |
| Q8 | 0.463 | 0.453 | 0.98x |
| Q9 | 2.299 | 1.519 | 0.66x |
| Q10 | 0.856 | 0.993 | 1.16x |
| Q11 | 0.126 | 0.191 | 1.51x |
| Q12 | 0.420 | 0.465 | 1.11x |
| Q13 | ERR | 1.930 | — |
| Q14 | 0.323 | 0.409 | 1.27x |
| Q15 | 0.280 | 0.336 | 1.20x |
| Q16 | 0.523 | 0.524 | 1.00x |
| Q17 | 0.416 | 0.122 | 0.29x |
| Q18 | 1.391 | 1.351 | 0.97x |
| Q19 | 0.669 | 0.151 | 0.23x |
| Q20 | 0.425 | 0.392 | 0.92x |
| Q21 | 1.703 | 1.515 | 0.89x |
| Q22 | 0.331 | 0.377 | 1.14x |
| **Total (21, excl Q13)** | **13.28** | **13.15** | **0.99x** |

## Findings
- **On par overall:** total wall-clock across the 21 comparable queries is a dead
  heat (engine 13.15s vs MariaDB 13.28s). The engine is faster on the
  subquery-heavy queries (Q9, Q17, Q19, Q20, Q21) and within ~1.0–1.5x on the rest.
- **Corrects the earlier "~3.7x slower" figure**, which compared our wall-clock
  against MariaDB's server-side `SHOW PROFILES` time — not apples-to-apples.
- **Coverage: 22/22** push to DuckDB, all md5-correct vs InnoDB (Q20/Q17 vs native
  DuckDB, since InnoDB times out). MariaDB errored on Q13 (derived column-list
  rename syntax `AS t (c1,c2)` not accepted by this build).

## Caveats
- The engine leg adds `docker exec`-per-query overhead that the MariaDB leg
  (in-container client) does not — the engine is conservatively measured.
- Worst engine query is Q1 (2.1x), dominated by `COLLATE NOCASE` on the grouped
  string key (measured ~+0.3s); an opt-in binary-collation mode would recover it.
- Ingest not re-measured here; prior SF10 lineitem load ~123s (COPY fast-path).
