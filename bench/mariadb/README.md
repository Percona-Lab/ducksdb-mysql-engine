# bench/mariadb — the MariaDB `ENGINE=DuckDB` leg (independent run)

The `MariaDB+DuckDB` column in [`docs/tpch_engine_comparison.md`](../../docs/tpch_engine_comparison.md)
comes from here. These scripts run **MariaDB on its own** — they boot a locally
built `mariadbd` with only the DuckDB storage-engine plugin, load the standard
TPC-H tables as `ENGINE=DuckDB`, and time the queries. They touch neither InnoDB
nor the in-tree MySQL engine, so the numbers are directly comparable to a
`bench/run-tpch22.sh` run on the same host and the same generated data.

| Script | What it runs |
|---|---|
| `run-mariadb-tpch22.sh` | Full 22-query TPC-H suite, warm wall-clock, min over `ITERS` (1 warmup excluded). |
| `run-mariadb-bench.sh` | The 1M-row `facts` micro-benchmark (Q1–Q6), server-side `SHOW PROFILES` timing — a quick smoke test. |

## Versions this was built against

| Component | Version |
|---|---|
| MariaDB server | **11.4.13** (stable base) |
| DuckDB storage-engine plugin | `github.com/MariaDB/duckdb-engine` @ commit **`612480e439c2869aa4cd860d15bd4f60ce090467`** (not in stock 11.4.13) |
| Embedded DuckDB | **1.5.x** static bundle (the plugin's `third_parties/duckdb` submodule), comparable to the native `ducksdb-duckdb:1.5.3` reference leg |

## Prerequisite: a built MariaDB with the DuckDB engine (NOT committed)

The MariaDB source checkout and its build directory are **deliberately excluded**
from this repo — they are gigabytes of third-party GPL source plus build
artifacts (a ~230 MB `mariadbd`, a ~95 MB `ha_duckdb.so`, CMake caches, object
files). You supply them and point the scripts at them with env vars.

Build once (outside the container, or in your own MariaDB build image):

```bash
git clone --branch 11.4 https://github.com/MariaDB/server mariadb-server
# add the DuckDB engine plugin; CMake fetches it at the pinned commit above
cmake -S mariadb-server -B DuckdbBuildOf_mariadb-server \
      -DPLUGIN_DUCKDB=YES -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build DuckdbBuildOf_mariadb-server -j"$(nproc)"
```

You need `DuckdbBuildOf_mariadb-server/{sql/mariadbd,client/mariadb,storage/duckdb/ha_duckdb.so,scripts/mariadb-install-db}`
and the matching `mariadb-server/` source tree.

## Running

Everything runs inside `ducksdb-builder:latest` (no host installs). Mount the
MariaDB build at `/work` and this repo at `/repo`. From the workspace root (the
dir that holds both `mariadb-bench/` and `ducksdb-mysql-engine/`):

**1. Generate the data + MySQL-dialect queries** (fast — skips the slow InnoDB
leg but still writes all 22 `qNN.mysql.sql`). From the engine repo:

```bash
cd ducksdb-mysql-engine
IMAGE=ducksdb/mysql:9.7-duckdb-v0.2.0 SF=10 SKIP_INNODB=1 bench/run-tpch22.sh
```

**2. Run MariaDB against it:**

```bash
cd ..   # workspace root
docker run --rm \
  -v "$PWD/mariadb-bench":/work \
  -v "$PWD/ducksdb-mysql-engine":/repo ducksdb-builder:latest \
  bash -lc 'SF=10 ITERS=3 bash /repo/bench/mariadb/run-mariadb-tpch22.sh'
```

**SF100** (generate the SF100 data first; then load in place — a ~130 GB copy
won't fit — with `NO_CLEAN=1`):

```bash
docker run --rm -v "$PWD/mariadb-bench":/work -v "$PWD/ducksdb-mysql-engine":/repo \
  ducksdb-builder:latest \
  bash -lc 'NO_CLEAN=1 SF=100 ITERS=2 bash /repo/bench/mariadb/run-mariadb-tpch22.sh'
```

## Env knobs

| Var | Default | Meaning |
|-----|---------|---------|
| `SF` | `10` | TPC-H scale factor (reads `$REPO/bench/data-sf$SF`). |
| `ITERS` | `3` | Warm iterations per query (min reported; 1 warmup excluded). |
| `NO_CLEAN` | `0` | `1` = CSVs already quote-free (SF100); load in place, don't copy. |
| `MARIADB_BUILD` | `/work/DuckdbBuildOf_mariadb-server` | MariaDB build dir. |
| `MARIADB_SRC` | `/work/mariadb-server` | MariaDB source dir. |
| `REPO` | `/repo` | This repo, mounted (for `bench/data-sf$SF` + `bench/data/facts.csv`). |

## Fairness notes

- Both engines load the **same** generated CSVs and (for the MySQL/MariaDB legs)
  the **same** dialect-translated queries produced by `bench/run-tpch22.sh`.
- MariaDB's `ENGINE=DuckDB` **requires a primary key** (`ERROR 1173` without one),
  so the PK is kept here — unlike the in-tree engine's PK-less SF100 load.
- MariaDB has no embedded-DuckDB `memory_limit` cap; the in-tree engine runs
  SF100 capped (`DUCKSDB_MEMORY_LIMIT`) so it spills instead of OOM-killing the
  server. Match the memory when comparing (see the Q15 note in the comparison doc).
