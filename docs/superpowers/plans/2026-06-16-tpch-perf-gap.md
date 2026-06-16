# TPC-H Performance Gap — Closure Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Phase 0 and most fix tasks are independent and SHOULD be dispatched to parallel subagents (worktree-isolated where they edit code).

**Goal:** Close the measured TPC-H SF10 performance gap between this engine and MariaDB's duckdb-engine — on per-query latency (~3.7× slower on the 8 queries we push), ingest time (~13 min vs 33 s), and coverage (8/22 vs 22/22 pushed) — until we are within ~1.5× of standalone-DuckDB warm latency, ingest in under 60 s, and push the large majority of the 22 queries.

**Architecture:** The engine embeds DuckDB per MySQL schema (`common/duckdb_engine_context.cc`), bulk-loads through a per-row `BulkAppender` (`common/duckdb_appender.cc`, driven by `engine/ha_duckdb.cc` `start_bulk_insert`/`write_row`/`end_bulk_insert`), and pushes whole analytical SELECTs down by rebuilding them in DuckDB SQL (`engine/duckdb_pushdown.cc`) and streaming results through a MySQL temp table (`ExecutePushdown`). The gap is attacked on four independent fronts — **data durability/layout (CHECKPOINT), ingest throughput, query-time collation cost, and subquery coverage** — gated by a decisive profiling phase that attributes the gap to named causes before any fix is written.

**Tech Stack:** C++17, DuckDB 1.5.3 (static `bundle-library`), MySQL 9.7 server (patched), CMake, Docker (`ducksdb-builder:latest` build image, `ducksdb-duckdb:1.5.3` native CLI, `ducksdb/mysql:9.7-duckdb-pN` runtime), the TPC-H harness `bench/run-tpch22.sh`.

**Baseline (measured 2026-06-16, SF10, i7-13700H class, 20 threads, warm):**

| Query | MariaDB | Ours (engine) | Native DuckDB warm | Ratio (eng/MariaDB) |
|---|---|---|---|---|
| q1 | 0.253 | 1.645 | 0.41 | 6.5× |
| q3 | 0.134 | 0.488 | — | 3.6× |
| q5 | 0.142 | 0.514 | — | 3.6× |
| q6 | 0.070 | 0.324 | — | 4.6× |
| q10 | 0.253 | 0.976 | — | 3.9× |
| q12 | 0.152 | 0.480 | — | 3.2× |
| q14 | 0.128 | 0.396 | — | 3.1× |
| q19 | 0.207 | 0.155 | — | 0.75× (we win) |
| **8-q total** | **1.34** | **4.98** | — | ~3.7× |

Known attributions so far: native DuckDB warm q1 = 0.41 s (≈ MariaDB, so DuckDB itself is fine); `COLLATE NOCASE` on string GROUP BY keys = +0.3 s on q1 (measured); **no CHECKPOINT exists** → data is uncompressed / lacks min-max statistics (hypothesis for the remaining ~0.9 s and slow ingest). Coverage: only Q1/Q3/Q5/Q6/Q10/Q12/Q14/Q19 push; the other 14 are subqueries that decline.

---

## Phase 0 RESULTS (2026-06-16) — REVISED PRIORITIES (supersede Phases 1-2 below)

Profiling (workflow `wf_c257bf47-2e6`, SF1 lineitem) overturned two premises. Re-ranked plan:

- **CHECKPOINT (old Phase 1): DE-SCOPED.** DuckDB **auto-checkpoints** on bulk load — the engine `.duckdb` is already fully compressed (FSST/Dict/BitPacking, zero uncompressed, `wal_size=0`, stats present). Manual `CHECKPOINT` changed 0 bytes / 0 scan-ms. The "uncompressed/WAL" hypothesis was wrong. (A post-load checkpoint only affects first-query latency, not throughput — not a perf fix.)
- **Plumbing/staging (old Phase 2 staging tasks): DE-SCOPED.** Result stage+send is ≤0.9% (sub-ms).
- **COLLATE (Phase 4): PROMOTED to the top query-time lever.** Plain q1 scan 43 ms vs `COLLATE NOCASE` 87 ms (+102%) at SF1. The only measured in-engine query-time win.
- **Ingest COPY fast-path (Task 3.2): PROMOTED to P0.** 805 s → ~33 s target. Bottleneck is the per-row handler double-handling, not the Appender. (Task 3.1 typed-append cleanup stays as P1 insurance, ~1.3-2×.)
- **Subquery coverage (Phase 5): unchanged**, the strategic latent win (8/22 → more).

**Open item:** Phase 0 measured at SF1, where fixed harness overhead dominates small absolute times. The **SF10 per-query gap is real** (engine q1 1.6 s vs native DuckDB 0.41 s = +1.2 s; COLLATE explains ~0.3 s, ~0.9 s unexplained). An **SF10 `[pd]` exec/stage/send breakdown** (in progress) is required to locate that ~0.9 s before adding any new query-side task. Also: re-baseline all SF10 query targets *net of* `docker exec` + mysql-client overhead.

**Revised execution order:** (1) SF10 `[pd]` breakdown → (2) COLLATE strict-binary option [cheap, measured] → (3) ingest COPY fast-path [headline] + typed-append → (4) subquery coverage. CHECKPOINT and staging tasks removed.

---

## How to run the benchmark (used as the "test" throughout)

All numbers come from one harness. Clean **isolated** runs (no declined queries interleaved — they thrash the server and contaminate timings):

```sh
cd /home/corvin/AI_WORK/DUCKS/ducksdb-mysql-engine
# 8 pushed queries, warm (1 warmup + 3 measured), engine + native only:
SF=10 SKIP_INNODB=1 ITERS=3 ONLY="1 3 5 6 10 12 14 19" CPUS=20 MEM=8g \
  QTIMEOUT=120 IMAGE=ducksdb/mysql:9.7-duckdb-pN bash bench/run-tpch22.sh
# SF1 correctness gate (md5 vs InnoDB) after ANY builder/staging change:
SF=1 ITERS=1 ONLY="1 3 5 6 10 12 14 19" CPUS=20 MEM=8g QTIMEOUT=120 \
  IMAGE=ducksdb/mysql:9.7-duckdb-pN bash bench/run-tpch22.sh   # expect passed(match)=8 mismatch=0
```

Build + image cycle (RelWithDebInfo for representative perf; source-only changes need no reconfigure):

```sh
docker run --rm -v "$PWD":/work -e REPO=/work -w /work ducksdb-builder:latest \
  bash -lc 'cmake --build vendor/mysql-server/build --target mysqld -j"$(nproc)"'
BUILD_TYPE=RelWithDebInfo scripts/release-image.sh ducksdb/mysql:9.7-duckdb-pN
```

**Hard rule for every fix phase:** after the perf change, the SF1 correctness gate must still report `passed(match)=8 mismatch=0` and MTR `pushdown_expr` + `engine/test/run-tests.sh` must stay green. A faster wrong answer is a regression.

---

## File Structure

| File | Responsibility | Phases that touch it |
|---|---|---|
| `common/duckdb_engine_context.cc/.h` | Open the per-schema DuckDB instance; **add DBConfig (threads/memory_limit) + post-bulk CHECKPOINT hook** | 1, 2 |
| `common/duckdb_appender.cc/.h` | `BulkAppender` row append + flush; **batching / per-field conversion cost** | 3 (ingest) |
| `engine/ha_duckdb.cc` | `start_bulk_insert`/`write_row`/`end_bulk_insert`/commit; **trigger CHECKPOINT after bulk; optional COPY fast-path** | 1, 3 |
| `engine/duckdb_pushdown.cc` | SQL builder; **collation emission strategy / strict-binary option; subquery rendering** | 4, 5 |
| `common/duckdb_engine_context.cc` | config knobs surfaced as MySQL sysvars | 4 |
| `mysql-test-suite/duckdb/t/*.test` | regression tests for any behavior change | 1,4,5 |
| `docs/usage.md`, `docs/tpch_*` | document new sysvars + refreshed benchmark | 6 |

---

## Phase 0 — Profile & Attribute (DECISIVE; do first; fully parallel)

**Why first:** the remaining ~0.9 s/q1 is unattributed. Every downstream fix is justified or discarded by these measurements. Dispatch all five tasks to **parallel subagents**; none edit shared code.

### Task 0.1: Per-stage timing of each pushed query

**Files:** none (uses existing `DUCKSDB_PD_TIMING` instrumentation in `engine/duckdb_pushdown.cc:1059-1067`, which prints `[pd] build=.. prep=.. exec=.. stage=.. send=..`).

- [ ] **Step 1:** Boot the engine image with the env var set, load SF10 lineitem (reuse `bench/data-sf10`), run q1/q6/q10 warm three times each, capture stderr `[pd]` lines:

```sh
docker run -d --name pf -v "$PWD/bench/data-sf10":/data:ro -e DUCKSDB_PD_TIMING=1 \
  ducksdb/mysql:9.7-duckdb-p5 mysqld --local-infile=1
# (create tpch_engine schema + ENGINE=DuckDB lineitem/part/orders/customer, LOAD DATA — see harness lines 205-228 for DDL)
# run each query 3x, then:
docker logs pf 2>&1 | grep '\[pd\]'
```

- [ ] **Step 2:** Record, per query, the split: DuckDB `exec` vs `stage`+`send` (our plumbing). **Exit criteria:** a table `query → {exec_ms, stage_ms, send_ms}`. If `stage+send` > 10% of total on any query, plumbing is a target (Phase 5); if it is <5%, plumbing is exonerated and the gap is DuckDB-side (data/SQL).

### Task 0.2: Engine `.duckdb` vs COPY-built `.duckdb` — layout & direct-SQL

**Files:** none (read-only analysis).

- [ ] **Step 1:** After a load, copy the engine's file out of the container and inspect storage vs the harness's COPY-built native file:

```sh
docker cp pf:/var/lib/mysql/tpch_engine.duckdb /tmp/engine.duckdb
ls -l /tmp/engine.duckdb bench/data-sf10/native.duckdb        # size delta = compression proxy
# row-group / compression / stats:
for f in /tmp/engine.duckdb bench/data-sf10/native.duckdb; do
  docker run --rm -i -v /tmp:/t:ro -v "$PWD/bench/data-sf10":/d:ro --entrypoint duckdb \
    ducksdb-duckdb:1.5.3 -readonly "$f" -c "SELECT count(*) row_groups, sum(count) rows FROM pragma_storage_info('lineitem'); PRAGMA database_size;"
done
```

- [ ] **Step 2:** Run the engine's EXACT generated q1 SQL (capture it from a `DUCKSDB_PD_TIMING` `[pd-gen]`/`[pd-sql]` line) directly against `/tmp/engine.duckdb` warm, 3×, and against `native.duckdb` warm 3×. **Exit criteria:** numbers that answer "is the engine `.duckdb` slower to scan than the COPY-built one for identical SQL?" If yes (and especially if its size is much larger / row-groups uncompressed / `has_statistics=false`), CHECKPOINT/compression (Phase 1/2) is confirmed as the primary lever.

### Task 0.3: CHECKPOINT A/B on the engine file

**Files:** none.

- [ ] **Step 1:** Measure scan of the engine file, then `CHECKPOINT`, then re-measure (need a writable copy):

```sh
cp /tmp/engine.duckdb /tmp/engine_ck.duckdb
docker run --rm -i -v /tmp:/t --entrypoint duckdb ducksdb-duckdb:1.5.3 /t/engine_ck.duckdb -c "CHECKPOINT;"
ls -l /tmp/engine.duckdb /tmp/engine_ck.duckdb     # size before/after checkpoint
# warm-time the same generated q1 SQL against each (READ_ONLY, 3 runs, .timer on)
```

- [ ] **Step 2:** **Exit criteria:** the delta (size + warm q1 time) before/after CHECKPOINT. This is the single most important number in Phase 0 — it bounds the win available from Phase 1/2.

### Task 0.4: COLLATE cost across the pushed set

**Files:** none.

- [ ] **Step 1:** For q1/q3/q5/q6/q10/q12, build two warm variants against `native.duckdb`: the plain `tpch_queries()` form and a variant with `COLLATE NOCASE` on every string GROUP BY / ORDER BY / equality key (mirrors `RenderField`). Time both warm (3×). (q1 already measured: 0.41 → ~0.66.)

- [ ] **Step 2:** **Exit criteria:** total COLLATE overhead across the 8 queries (seconds). Justifies Phase 3's effort/priority.

### Task 0.5: Ingest hot-path profile

**Files:** read `common/duckdb_appender.cc:23-41` (AppendRow/Flush), `engine/ha_duckdb.cc:155-171,299`.

- [ ] **Step 1:** Time the SF10 lineitem `LOAD DATA` end-to-end (in progress: task `bt6kpasjw`). Compute rows/sec (60M / seconds) and compare to DuckDB Appender's known throughput (~1–5 M rows/s). 

- [ ] **Step 2:** Determine whether the bottleneck is (a) MySQL CSV→record pipeline + per-row `write_row` dispatch, (b) per-field `AppendField` type conversion (`common/duckdb_appender.cc:27`), or (c) the final `Flush()` + commit + (absent) checkpoint. Use `perf top`/`perf record` on the mysqld PID during a load if available in the builder image; otherwise instrument `AppendRow`/`Flush` with a row counter + wall clock behind an env flag. **Exit criteria:** a named dominant cost for ingest, deciding Phase 3's approach (batch tuning vs COPY fast-path).

---

## Phase 1 — Durability/Layout: CHECKPOINT after bulk load (highest expected ROI)

**Hypothesis (from "no CHECKPOINT exists"):** bulk-appended data is never compressed and carries no column statistics, so DuckDB scans read bloated data and cannot prune row groups by `l_shipdate` — inflating every scan-heavy query AND the on-disk file. A single post-bulk `CHECKPOINT` compresses and builds stats. Confirm with Phase 0.3 before heavy investment, but the change itself is small.

### Task 1.1: CHECKPOINT after `end_bulk_insert`

**Files:**
- Modify: `engine/ha_duckdb.cc` (`end_bulk_insert`, ~line 163)
- Possibly add helper: `common/duckdb_engine_context.cc/.h` (a `Checkpoint(schema)` that runs `CHECKPOINT` on a fresh connection)

- [ ] **Step 1: Add a `Checkpoint` helper** in `common/duckdb_engine_context.cc`:

```cpp
// Force-compress + build statistics on the schema's DuckDB file. Run after a
// bulk load so subsequent scans read compressed, statistics-bearing row groups
// instead of WAL-resident uncompressed data.
int EngineContext::Checkpoint(const std::string &schema) {
    auto conn = Connection(schema);
    auto r = conn->Query("CHECKPOINT");
    return r->HasError() ? 1 : 0;
}
```
Declare `int Checkpoint(const std::string &schema);` in `common/duckdb_engine_context.h`.

- [ ] **Step 2: Call it after the bulk flush+commit** in `engine/ha_duckdb.cc::end_bulk_insert` (after the existing `bulk_->Flush()` and transaction commit). Guard so it only runs when a bulk actually occurred. Show the exact added lines in context when implementing.

- [ ] **Step 3: Build** (`cmake --build ... --target mysqld`), **re-image** to `ducksdb/mysql:9.7-duckdb-p6`.

- [ ] **Step 4: Measure** — re-run the isolated 8-query SF10 warm gate on `p6`. **Exit criteria:** scan-heavy q1/q6/q10 drop toward the native warm baseline (target q1 ≤ ~0.8 s). Engine `.duckdb` file size shrinks materially.

- [ ] **Step 5: Correctness** — SF1 gate `passed(match)=8 mismatch=0`; MTR + unit tests green.

- [ ] **Step 6: Commit** `perf: checkpoint after bulk load to compress + build statistics`.

### Task 1.2: Pin DuckDB resources (threads/memory_limit) for parity & predictability

**Files:** Modify `common/duckdb_engine_context.cc:22-34` (instance creation) to pass a `duckdb::DBConfig`.

- [ ] **Step 1:** Open the instance with an explicit config (defaults already ~match: nproc=20; this makes it deterministic and configurable, and lets us cap memory like MariaDB's 8 GiB for apples-to-apples):

```cpp
duckdb::DBConfig cfg;
cfg.SetOptionByName("threads", duckdb::Value::BIGINT(/*from sysvar, default = cores*/));
cfg.SetOptionByName("memory_limit", duckdb::Value("8GiB"));   // sysvar-driven; default unlimited
auto db = std::make_shared<duckdb::DuckDB>(FilePathFor(schema), &cfg);
```

- [ ] **Step 2:** Build, image, **measure** — confirm no regression vs p6 (parity check, not a win by itself). **Exit criteria:** times within noise of p6; memory capped. Commit `perf: configure DuckDB threads/memory_limit explicitly`.

---

## Phase 2 — Query-time scan layout (only if Phase 0.2/0.3 shows residual layout cost after CHECKPOINT)

### Task 2.1: Verify row-group pruning on `l_shipdate`

**Files:** none (analysis) → possibly `engine/ha_duckdb.cc` (load ordering).

- [ ] **Step 1:** With the p6 (checkpointed) file, `EXPLAIN ANALYZE` the generated q1/q6 against it; confirm the scan prunes row groups by the `l_shipdate` predicate (look for reduced rows scanned). 

- [ ] **Step 2:** If pruning is weak because rows were appended in CSV order (not clustered by date), evaluate a post-load `CREATE TABLE ... AS SELECT ... ORDER BY l_shipdate` reclustering ONLY if Phase 0 shows it matters. **Exit criteria:** decision (recluster or not) backed by EXPLAIN ANALYZE rows-scanned numbers. Do not recluster speculatively (YAGNI).

---

## Phase 3 — Ingest throughput (target SF10 load < 60 s)

**Measured baseline:** SF10 `lineitem` `LOAD DATA` = **805 s** (60M rows ≈ 74.5k rows/s) vs MariaDB's 33 s `COPY` — **~24× slower**. DuckDB's Appender alone sustains 1–5M rows/s, so ~74.5k rows/s means the bottleneck is upstream of DuckDB (MySQL CSV→record pipeline + per-row `write_row` dispatch + per-field `AppendField` conversion), not DuckDB itself. Phase 0.5 confirms which; if it is the row pipeline, Task 3.2 (COPY fast-path) is the only route to ~33 s.

Approach chosen by Phase 0.5's dominant-cost finding.

### Task 3.1 (if per-field conversion / batching dominates): tune the Appender path

**Files:** Modify `common/duckdb_appender.cc` (`AppendRow`/`AppendField`/`Flush`), `engine/ha_duckdb.cc` (bulk lifecycle).

- [ ] **Step 1:** Eliminate per-row overhead: ensure `AppendField` does no per-row allocation (reuse buffers), and that `Flush()` is called once at end (not per row). Verify the appender runs inside a single transaction (it does — `state.Begin()` once) and that nothing forces a per-row WAL flush.
- [ ] **Step 2:** Measure load time. **Exit criteria:** rows/sec improvement; record new SF10 load seconds. Commit.

### Task 3.2 (if the MySQL row pipeline dominates): COPY fast-path for `LOAD DATA`

**Files:** Modify `engine/ha_duckdb.cc` (detect a `LOAD DATA` bulk and, when the source file is readable by the engine, issue a DuckDB `COPY lineitem FROM '<file>' (FORMAT CSV, ...)` instead of streaming rows). This mirrors MariaDB's "in-engine COPY".

- [ ] **Step 1:** Spike feasibility: can the engine see the `LOAD DATA` source path and column/format mapping from the handler API? If yes, prototype `COPY` for the common case (local infile, matching column order) and fall back to the appender otherwise.
- [ ] **Step 2:** Measure. **Exit criteria:** SF10 load approaches MariaDB's 33 s. This is the highest-effort, highest-reward ingest item; gate it behind the Phase 0.5 finding that the row pipeline (not conversion) is the bottleneck. Commit, with a correctness load-and-count check.

---

## Phase 4 — Collation cost (recover the measured ~0.3 s/grouped query)

### Task 4.1: Strict-binary collation option

**Files:** Modify `engine/duckdb_pushdown.cc` (`MapCollation`/`RenderField`), `common/duckdb_engine_context.cc` (sysvar), tests.

- [ ] **Step 1:** Confirm `_bin`/binary columns already emit no `COLLATE` (they do — `MapCollation`). Add a session sysvar `ducksdb_assume_binary_collation` (default OFF). When ON, case-insensitive collations render WITHOUT `COLLATE NOCASE` — a documented opt-in for ASCII/uppercase data (TPC-H) that recovers the comparator cost. Default OFF preserves the strict correctness invariant.
- [ ] **Step 2:** Add an MTR case proving: OFF → grouped query on a mixed-case column groups case-insensitively (NOCASE); ON → groups case-sensitively. Build/image/measure with the option ON over the 8 queries.
- [ ] **Step 3:** **Exit criteria:** with the option ON, grouped queries recover the Phase-0.4 COLLATE overhead, SF1 results still correct for ASCII data. Document in `docs/usage.md`. Commit.

---

## Phase 5 — Coverage: subquery tier (largest; its own track, parallelizable from the start)

The 14 declined queries are subqueries (Q2/4/7/8/9/11/13/15/16/17/18/20/21/22). Per the earlier Phase-3 spike, implement staged recursive pushdown. This is large enough to be its **own plan**; this phase establishes the decomposition and the first milestone so a dedicated subagent track can start immediately.

### Task 5.1: Classify the 14 and pick the first wave

**Files:** none (analysis) → `engine/duckdb_pushdown.cc`.

- [ ] **Step 1:** For each declined query, capture the `[pd-decline-at]` reason (run each at SF1 with `DUCKSDB_PD_TIMING=1`). Group by construct: (a) derived/inline views, (b) `IN`/`EXISTS` flattened to semijoin nests, (c) scalar/correlated subselects, (d) others (e.g. `EXTRACT`, `SUBSTRING`, views).
- [ ] **Step 2:** **Exit criteria:** a construct→queries matrix and the first wave = the largest single construct class.

### Task 5.2: Block-level recursion over derived tables (first construct)

**Files:** Modify `engine/duckdb_pushdown.cc` (the block gate at `~764` currently `decline("subquery")` for `first_inner_query_expression() != nullptr`; replace with recursive rendering of derived tables in `RenderFrom`).

- [ ] **Step 1:** Render a derived-table FROM entry by recursively rendering its inner query block as a parenthesized subquery, with its own decline contract. Add an MTR test (a simple `FROM (SELECT ... GROUP BY ...) t`).
- [ ] **Step 2:** SF1 correctness gate including the now-pushable queries; build/image/measure. **Exit criteria:** ≥1 previously-declined query pushes + md5-matches. Commit. Iterate per construct (semijoin nests, then scalar subselects) as follow-on tasks.

### Task 5.3: Runaway-fallback guard (operational)

**Files:** Modify `engine/ha_duckdb.cc` or the server-patch hook site.

- [ ] **Step 1:** When a multi-table query over ENGINE=DuckDB tables declines pushdown, the row-by-row fallback at SF10 runs away (observed: it poisons the benchmark server). Add a guard/heuristic (e.g., a configurable warning, or surface that the query did not push) so operators can detect non-pushed analytical queries. **Exit criteria:** a non-pushed multi-table SELECT is observable (status var / log) rather than silently slow. Commit.

---

## Phase 6 — Re-benchmark, document, and compare

### Task 6.1: Full refreshed comparison

- [ ] **Step 1:** Re-run isolated 8-query SF10 warm on the final image; re-run the full 22 (now with more pushed) using a short `QTIMEOUT` so any still-declined queries fail fast. Capture per-query + totals + ingest seconds.
- [ ] **Step 2:** Update `docs/tpch_sf10_query_benchmark.md` and a new `docs/tpch_sf10_ingestion_benchmark.md` with the refreshed table vs MariaDB and the methodology. **Exit criteria:** documented before/after; per-query within ~1.5× native warm; ingest < 60 s; coverage count stated. Commit.

---

## Subagent / parallelism map (per user request: max models, many subagents)

- **Wave A (parallel, read-only, opus):** Tasks 0.1, 0.2, 0.3, 0.4, 0.5 — five subagents, no code edits, each returns a measurement table. Barrier: collect all five → attribute the gap.
- **Wave B (parallel, worktree-isolated, opus):** Task 1.1 (CHECKPOINT) ‖ Task 1.2 (config) ‖ Task 4.1 (collation option) ‖ Task 5.1+5.2 (subquery track). These touch different files (`ha_duckdb.cc`/`engine_context` vs `duckdb_pushdown.cc`) — use `isolation: worktree` to avoid build collisions, then integrate sequentially with a build+gate after each merge.
- **Wave C (sequential, gated by Phase 0.5):** Task 3.1 or 3.2 (ingest) — chosen by the profiling result; build+measure.
- **Wave D:** Task 6.1 — single subagent, final re-benchmark + docs.
- **Discipline:** every code-merge is followed by build → SF1 correctness gate (`passed(match)=8 mismatch=0`) → MTR/unit → isolated SF10 warm measure. No phase advances on a red gate.

## Expected outcome (targets, not promises — Phase 0 may re-rank these)

1. **CHECKPOINT (Phase 1):** biggest expected per-query win; scan-heavy queries toward native warm; smaller `.duckdb`.
2. **Ingest (Phase 3):** SF10 load 13 min → < 60 s (COPY fast-path can approach 33 s).
3. **Collation (Phase 4):** −~0.3 s on grouped queries when opted in.
4. **Coverage (Phase 5):** push the majority of the 22 → a meaningful 22-query total vs MariaDB's 4.30 s.
