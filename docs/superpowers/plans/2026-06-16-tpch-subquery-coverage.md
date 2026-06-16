# TPC-H Subquery Coverage (8/22 → 22/22) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Phase 0 (discovery) is parallel — run it via the companion workflow `tpch-subquery-discovery`. The construct phases (1–7) are SEQUENTIAL (they share `engine/duckdb_pushdown.cc` and each needs a server build + correctness gate between them).

**Goal:** Make all 22 TPC-H queries push down to DuckDB and return results byte-identical to InnoDB, by teaching the whole-query structured builder to render subqueries (derived tables, scalar subqueries, semijoins/antijoins, CTEs) instead of declining on the first nested query expression.

**Architecture:** The builder (`engine/duckdb_pushdown.cc`) is a *structured* AST→DuckDB-SQL generator with a strict decline contract (render provably-equivalent SQL or decline; never `Item::print()` fallback). Today it renders exactly one `Query_block` and declines whenever `qb->first_inner_query_expression() != nullptr`. We extend it to render **recursively**: factor the per-block logic into a reusable `RenderQueryBlock`, then teach `RenderFrom` to emit derived tables `(SELECT …) alias`, `RenderExpr`/`RenderPredicate` to emit scalar subqueries `(SELECT …)` and `IN/EXISTS` (and `NOT IN`/`NOT EXISTS`) — handling whatever post-optimization shape `JOIN::optimize` leaves (derived `Table_ref`s, residual `Item_subselect`, or flattened semijoin nests, as determined by Phase 0). Every construct keeps the decline contract; anything not provably equivalent declines and falls back.

**Tech Stack:** C++17, DuckDB 1.5.3 (full SQL incl. derived tables, scalar subqueries, `IN`/`EXISTS`/`SEMI`/`ANTI` joins, CTEs), MySQL 9.7 (post-optimize `JOIN`/`Query_block`/`Query_expression`/`Item_subselect`/semijoin `Table_ref`), the TPC-H harness `bench/run-tpch22.sh`, MTR suite `duckdb`.

**The 14 currently-declined queries and their TPC-H constructs (to confirm in Phase 0):**

| Query | Primary construct(s) | Class |
|---|---|---|
| Q2  | correlated scalar subquery `= (SELECT min(ps_supplycost) …)` | B scalar |
| Q4  | correlated `EXISTS` | C semijoin |
| Q7  | derived table (inline view) + `EXTRACT(year)` | A derived + F func |
| Q8  | derived table (inline view) + `EXTRACT(year)` | A derived + F func |
| Q9  | derived table (inline view) + `EXTRACT(year)` | A derived + F func |
| Q11 | uncorrelated scalar subquery in `HAVING` | B scalar |
| Q13 | derived table + `LEFT OUTER JOIN` | A derived + F outer-join |
| Q15 | CTE/`WITH` (or view) + scalar subquery `= (SELECT max …)` | E cte + B scalar |
| Q16 | `NOT IN (subquery)` + `COUNT(DISTINCT)` | D antijoin |
| Q17 | correlated scalar subquery `< (SELECT 0.2*avg …)` | B scalar |
| Q18 | `IN (SELECT … GROUP BY … HAVING …)` | C semijoin |
| Q20 | nested `IN` + correlated scalar subquery | B + C |
| Q21 | `EXISTS` + `NOT EXISTS` (correlated) | C + D |
| Q22 | derived table + scalar subquery `> (SELECT avg …)` + `NOT EXISTS` + `SUBSTRING` | A + B + D + F |

---

## Phase 0 RESULTS — roadmap corrections (workflow `wf_cb737f5b-594`)

Discovery (5 parallel classifiers + synthesis) confirmed the construct matrix and corrected the plan:

- **C1 — Split Phase 6. The scalar-function leaves move EARLY.** `EXTRACT`, `SUBSTRING`, `NOT_FUNC`
  are pure `RenderExpr`/`RenderPredicate` leaves → **Phase 6a, landed right after Phase 1** (Q7/8/9
  cannot pass their gate without `EXTRACT(YEAR)`). Outer-join nested-tree reconstruction stays late as
  **Phase 6b** with Q13.
- **C2 — Semijoin/antijoin strategy INVERTED (critical).** Do **not** reconstruct semijoin nests from
  `leaf_tables`/`sj_nests` as the primary path — that is where silent wrong-rows live. Instead **render
  from the surviving original subquery `Query_block`** (via `Item_subselect` / `derived_query_expression()`)
  and **decline** whenever `JOIN::optimize` already collapsed it into a nest we cannot unambiguously
  invert. Phase 0 Task 0.2 (observe what survives at the hook) is therefore a **hard design gate** for
  Phases 4/5, not just informational.
- **C3 — Correlated-field scoping is a shared capability:** qualify every outer ref via
  `Item_field::depended_from`/`used_tables()`, land once in Phase 3, reuse for Q2/Q17/Q20/Q21/Q22.
  Decline if an unqualified field name is ambiguous across the outer+inner FROM union.

**Honest 22/22 assessment — likely-to-remain-declined (decline contract over forced coverage):**
- **Q8** — top-level `sum(CASE…)/sum(volume)` DIV-of-aggregates has a real DECIMAL-scale vs DuckDB-DOUBLE
  divergence; declines on the division unless result-type is provably DOUBLE or explicitly cast.
- **Q17** — `< 0.2*avg()` DECIMAL-vs-DOUBLE boundary + REAL-const gate; strictest reading declines.
- **Q20** — three nested levels (IN→IN→correlated scalar); most fragile chain; conservative path may decline.
So the realistic target is **~19–21/22 fully pushing + matching**, with Q8/Q17/Q20 declining on
*provable-equivalence* grounds (correct fallback), not bugs. (These tie back to the documented decimal
floating-point limitation.)

**Top decline-contract risks (gate, don't force):** (1) `NOT IN` 3-valued logic → render only if both
outer col and inner col are NOT NULL, else decline (Q16); (2) un-invertable semi/anti nest (Q18/20/21);
(3) outer-join ON-vs-WHERE NULL-extension (Q13); (4) correlated mis-scoping with repeated table names
(Q2/17/20/21/22); (5) avg/division DECIMAL divergence (Q8/17).

**Revised landing order:** 1) RenderQueryBlock recursion → 2) Phase 6a leaves (EXTRACT/SUBSTRING/NOT_FUNC)
→ 3) derived tables (ship **Q9** first as the clean proof) → 4) scalar (Q11→Q2→Q17) → 5) semijoin
render-original-or-decline (Q4→Q18) → 6) antijoin NULL-gated (Q16) → 7) outer-join (Q13) → 8) CTE +
composites (Q15, Q20/21/22).

**FIRST PR (highest ROI):** Phase 1 (`RenderQueryBlock`) + Phase 6a `EXTRACT(YEAR)` + Phase 2 derived
tables, shipping **Q9** (cleanest: single `nation`, no self-join, no division — isolates the foundational
machinery from every hazard). **Pre-PR fact to confirm:** whether MySQL 8.0.44 *merges* or *materializes*
the Q9 derived table at the hook (decides if Phase 2 is a gate-relaxation or a `(subselect) AS alias`
emitter) — check via `DUCKSDB_PD_TIMING` structural dump.

---

## How to test (the gate for every phase)

Correctness is the bar; a faster wrong answer is a regression. After each construct phase, build and run the SF1 correctness gate over the queries that phase should unblock (plus the existing 8 as a regression check), then MTR:

```sh
cd /home/corvin/AI_WORK/DUCKS/ducksdb-mysql-engine
# build (source-only changes to duckdb_pushdown.cc need no reconfigure):
docker run --rm -v "$PWD":/work -e REPO=/work -w /work ducksdb-builder:latest \
  bash -lc 'cmake --build vendor/mysql-server/build --target mysqld -j"$(nproc)"'
BUILD_TYPE=RelWithDebInfo scripts/release-image.sh ducksdb/mysql:9.7-duckdb-pN
# correctness: every listed query must show offloaded?=yes AND match?=yes, mismatch=0
SF=1 ITERS=1 ONLY="<existing 8> <newly-unblocked>" CPUS=20 MEM=8g QTIMEOUT=120 \
  IMAGE=ducksdb/mysql:9.7-duckdb-pN bash bench/run-tpch22.sh
docker volume prune -f    # harness leaks anonymous volumes; reclaim
```

**Decline contract reminder:** if a subquery shape cannot be rendered to provably-identical DuckDB SQL, return false (decline) — the query falls back to normal MySQL execution. Wrong rows are never acceptable; an unsupported shape declining is.

---

## File Structure

| File | Responsibility | Phases |
|---|---|---|
| `engine/duckdb_pushdown.cc` | the structured builder — gains `RenderQueryBlock` recursion + derived/subselect/semijoin rendering | 1–7 |
| `engine/duckdb_pushdown.h` | (only if new shared signatures are exported) | 1 |
| `mysql-test-suite/duckdb/t/pushdown_subquery.test` + `r/…` | MTR regression: one minimal case per construct | 2–7 |
| `bench/data-sf1/queries/qNN.mysql.sql` | harness MySQL-dialect translations may need hand-fixes for newly-pushable queries (Q19 precedent) | 2–7 |
| `docs/usage.md` | document newly-supported query shapes + any remaining declines | 7 |

---

## Phase 0 — Discovery (PARALLEL; run via the `tpch-subquery-discovery` workflow)

**Why first:** the builder runs *after* `JOIN::optimize`, which rewrites subqueries (IN/EXISTS → semijoin nests; derived tables → materialized `Table_ref`s; some subqueries stay `Item_subselect`). The exact rendering strategy per construct depends on **what actually survives optimization for each query** — we must observe it, not assume.

### Task 0.1: Capture decline reason + post-optimize structure per query

**Files:** none (read-only; uses `DUCKSDB_PD_TIMING` + ad-hoc instrumentation).

- [ ] **Step 1:** For each of the 14 queries, run it at SF1 against the engine with `DUCKSDB_PD_TIMING=1` and capture the `[pd-decline-at]` reason. (The block gate currently prints `decline("subquery")` for all of them — confirm, and note any that decline for a *different* reason.)
- [ ] **Step 2:** For each query, determine the post-optimize shape by inspecting the `Query_block` the hook receives: does it have derived `Table_ref`s (`tr->is_derived()` / `tr->derived_query_expression()`), residual `Item_subselect` in `where_cond`/`having_cond`/select list, and/or semijoin nests (`tr->m_join_cond`/`sj_nest`, `qb->sj_nests`)? A temporary diagnostic that walks `qb->leaf_tables`, `qb->where_cond()`, and `qb->sj_nests` and logs each node's type is the cleanest way; capture the output per query.
- [ ] **Step 3:** Write the exact target DuckDB SQL for each query (DuckDB runs standard SQL — the canonical `tpch_queries()` form already works natively; the question is what the *builder* must emit from the post-optimize tree to match it).

**Exit criteria:** a per-query spec: `{decline_reason, surviving_constructs[], target_duckdb_sql, construct_class}` and a construct→queries matrix that orders the implementation (derived tables and scalar subqueries first — they are pure recursion; semijoins last — they may require reading flattened nests).

---

## Phase 1 — Recursive rendering infrastructure (foundational; no new queries yet)

### Task 1.1: Extract `RenderQueryBlock`

**Files:** Modify `engine/duckdb_pushdown.cc`.

- [ ] **Step 1:** Refactor the existing top-level block logic (SELECT list, FROM, WHERE, GROUP BY, HAVING, ORDER BY, LIMIT — currently inline in the builder entry) into a function `bool RenderQueryBlock(BuildCtx *ctx, Query_block *qb, std::string *out)` that emits a full parenthesizable `SELECT …`. The existing single-block path becomes `RenderQueryBlock(top_qb)`. No behavior change yet — this is a pure extraction.
- [ ] **Step 2:** Make `BuildCtx` carry the schema/`db` and the params vector so nested blocks share one parameter list and the single-schema guard. Ensure column references inside nested blocks resolve against their own block's tables (qualify with table alias, which the builder already does via `RenderField`).
- [ ] **Step 3:** Build + run the existing 8-query SF1 gate. **Exit:** all 8 still `match=yes` (pure refactor, zero regression). Commit `refactor: extract RenderQueryBlock for recursive rendering`.

---

## Phase 2 — Derived tables / inline views (unblocks Q7/Q8/Q9/Q13/Q22-outer)

### Task 2.1: Render derived `Table_ref`s recursively in `RenderFrom`

**Files:** Modify `engine/duckdb_pushdown.cc` (`RenderFrom`); add MTR `pushdown_subquery.test`.

- [ ] **Step 1:** In `RenderFrom`, when a `Table_ref` is a derived table (`tr->is_derived()`), render it as `(` + `RenderQueryBlock(tr->derived_query_expression()->first_query_block())` + `) ` + `QuoteIdent(alias)`. Decline if the derived unit is not a simple single query block (e.g. a UNION) or its alias is missing. Remove/loosen the block-level `decline("subquery")` so a block whose only nesting is derived tables proceeds.
- [ ] **Step 2:** Add an MTR case: `SELECT k, SUM(v) FROM (SELECT k, v FROM t WHERE …) d GROUP BY k` over ENGINE=DuckDB tables; assert `Ducksdb_pushdown_count` rose and results are correct.
- [ ] **Step 3:** Build + image + SF1 gate `ONLY="<8> 7 8 9 13"` (and any other derived-only query Phase 0 found). Hand-fix `qNN.mysql.sql` harness translations if needed (Q19 precedent). **Exit:** the derived-table queries `match=yes`; the 8 still pass. Commit.

> Note: Q7/8/9/13 also need `EXTRACT(year …)` (Phase 6) and Q13 needs `LEFT OUTER JOIN` (Phase 6). They may only fully pass after Phase 6 — sequence Phase 6 before re-gating them, or land the func/outer-join support first if Phase 0 shows they block here.

---

## Phase 3 — Scalar subqueries (unblocks Q2/Q11/Q17, parts of Q15/Q20/Q22)

### Task 3.1: Render `Item_subselect` scalar subqueries

**Files:** Modify `engine/duckdb_pushdown.cc` (`RenderExpr` / `RenderPredicate`).

- [ ] **Step 1:** In `RenderExpr`, handle `Item::SUBQUERY_ITEM` (a scalar `Item_singlerow_subselect`): render `(` + `RenderQueryBlock(its query block)` + `)`. Correlated references (outer columns) render via the existing `RenderField` (qualified by the outer table's alias, which is in scope in DuckDB's correlated-subquery semantics — identical to MySQL). Decline non-scalar / row subqueries and any whose inner block declines.
- [ ] **Step 2:** Ensure comparison predicates (`RenderCompare`/`RenderPredicate`) accept a subquery operand (they call `RenderExpr`, so this composes once Step 1 lands). Add MTR: `SELECT … WHERE col < (SELECT 0.2*AVG(x) FROM t2 WHERE t2.k=t1.k)`.
- [ ] **Step 3:** Build + SF1 gate `ONLY="<8> 2 11 17"`. **Exit:** Q2/Q11/Q17 `match=yes`. Commit.

---

## Phase 4 — Semijoins: IN / EXISTS (unblocks Q4/Q18, parts of Q20/Q21)

### Task 4.1: Render `IN (subquery)` and `EXISTS (subquery)`

**Files:** Modify `engine/duckdb_pushdown.cc` (`RenderPredicate`, and possibly `RenderFrom` if Phase 0 shows the optimizer left semijoin *nests* rather than `Item_subselect`).

- [ ] **Step 1:** Strategy is Phase-0-determined:
  - If the construct survives as an `Item_in_subselect`/`Item_exists_subselect` → render `expr IN (SELECT …)` / `EXISTS (SELECT …)` directly via `RenderQueryBlock`.
  - If `JOIN::optimize` flattened it into a **semijoin nest** (the common case for `IN`/`EXISTS`) → render the nest as a DuckDB `SEMI JOIN` (or reconstruct the equivalent `EXISTS`), reading the nest's join condition and inner tables. If the nest shape is not provably reconstructable, **decline**.
- [ ] **Step 2:** MTR: `SELECT … WHERE k IN (SELECT k FROM t2 GROUP BY k HAVING SUM(v) > c)` and an `EXISTS` case.
- [ ] **Step 3:** Build + SF1 gate `ONLY="<8> 4 18"`. **Exit:** Q4/Q18 `match=yes`. Commit.

---

## Phase 5 — Antijoins: NOT IN / NOT EXISTS (unblocks Q16, parts of Q21/Q22)

### Task 5.1: Render `NOT IN` / `NOT EXISTS`

**Files:** Modify `engine/duckdb_pushdown.cc`.

- [ ] **Step 1:** Mirror Phase 4 for the negated forms (`Item_func` with negation, or an antijoin nest). **Correctness caution:** `NOT IN` with NULLs has three-valued-logic semantics; render `NOT IN`/`NOT EXISTS` only when DuckDB's semantics provably match MySQL's for the operand nullability, else decline. Verify against InnoDB with NULL-bearing data in the MTR case.
- [ ] **Step 2:** MTR: a `NOT IN` and a `NOT EXISTS` case, including a NULL row, compared to the row path.
- [ ] **Step 3:** Build + SF1 gate `ONLY="<8> 16"`. **Exit:** Q16 `match=yes`. Commit.

---

## Phase 6 — Supporting scalar functions + outer join (unblocks Q7/8/9 fully, Q13, Q22's SUBSTRING)

### Task 6.1: `EXTRACT(year)`, `SUBSTRING`, and `LEFT OUTER JOIN`

**Files:** Modify `engine/duckdb_pushdown.cc` (`RenderExpr` function switch; `RenderFrom` outer-join handling).

- [ ] **Step 1:** Add `EXTRACT(YEAR FROM <date>)` (MySQL `Item_extract` / `YEAR()`), rendering to DuckDB `EXTRACT(year FROM …)` / `year(…)` — confirm identical results for DATE. Add `SUBSTRING(s, pos, len)` → DuckDB `substring` (1-based, identical). Decline other extract units / 2-arg substring variants unless provably equivalent.
- [ ] **Step 2:** Render `LEFT OUTER JOIN` in `RenderFrom` (currently declined): emit `t1 LEFT JOIN t2 ON <cond>`, reading `tr->outer_join` and the join condition. Keep declining full/right/nested-outer trees unless Phase 0 shows Q13 needs only a single left join. Verify NULL-extension semantics match (DuckDB LEFT JOIN = MySQL LEFT JOIN).
- [ ] **Step 3:** Build + SF1 gate `ONLY="<8> 7 8 9 13"`. **Exit:** Q7/Q8/Q9/Q13 `match=yes`. Commit.

---

## Phase 7 — CTE / WITH (Q15) + close out (Q20, Q21, Q22 full)

### Task 7.1: CTE rendering and the remaining composites

**Files:** Modify `engine/duckdb_pushdown.cc`; `docs/usage.md`.

- [ ] **Step 1:** Q15 uses a `WITH revenue AS (…)` CTE (or a view). Render `WITH <name> AS (RenderQueryBlock) <main>` if MySQL exposes it as a derived/CTE `Table_ref` (Phase 0 confirms); otherwise the CTE may already arrive as a derived table (Phase 2 covers it). The scalar `= (SELECT max …)` is Phase 3.
- [ ] **Step 2:** Q20/Q21/Q22 are composites of the above (nested IN + correlated scalar; EXISTS+NOT EXISTS; derived + scalar + NOT EXISTS + SUBSTRING). With Phases 2–6 landed they should push; gate each and fix the residual construct that declines.
- [ ] **Step 3:** Build + **full** SF1 gate `ONLY=""` (all 22). **Exit:** `passed(match)=22 mismatch=0`. Update `docs/usage.md` (now-supported shapes; any intentional residual declines). Commit.

---

## Phase 8 — Validate at scale + headline

- [ ] **Step 1:** SF10 full-22 run (warm, isolated) to get the 22-query total vs MariaDB's 4.30 s. Record per-query + total. (Expect the per-query embedded penalty to persist; coverage is the win here.)
- [ ] **Step 2:** Update `docs/tpch_sf10_query_benchmark.md` with the 22/22 comparison. Commit.

---

## Self-review notes

- **Spec coverage:** every one of the 14 maps to ≥1 phase (matrix above); the 8 existing are the regression check in every gate.
- **Decline contract is the safety net:** any construct Phase 0 reveals as not-provably-equivalent (e.g. a semijoin nest we can't reconstruct, `NOT IN` with NULL ambiguity, a UNION-derived table) **declines** and the query falls back — correct but unpushed. Hitting 22/22 is the goal; correctness is the hard constraint. If a query can't be made provably-equivalent, it stays declined and that is documented, not forced.
- **Sequencing:** Phases 1→7 are ordered by dependency (recursion infra → derived → scalar → semijoin → antijoin → funcs → composites). Phase 6 (funcs/outer-join) may need to precede the Phase-2 re-gate of Q7/8/9/13 — land func support when Phase 0 shows it blocks.
- **Why not `Item::print()`:** rejected previously (cutover to structured builder); `print()` emits MySQL-dialect SQL that can diverge in DuckDB. We keep the structured, provably-equivalent renderer.
