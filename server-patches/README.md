# Server patches

In-tree MySQL 9.7 server patches that this engine depends on. They are applied
automatically by `scripts/build-server.sh` (idempotently) into
`vendor/mysql-server/` before the build. `vendor/` is gitignored, so these patch
files are the tracked source of truth.

## 0001-engine-query-pushdown.patch

Adds a whole-query pushdown hook so a storage engine can take over
execution of a whole SELECT whose base tables all belong to it — the mechanism
behind automatic `ENGINE=DuckDB` analytical pushdown (no secondary engine).

- `sql/handler.h` — `pushdown_select_t` typedef + `handlerton::pushdown_select`
  member (zero-filled default → null for all other engines; ABI-safe for a
  built-in MANDATORY engine).
- `sql/sql_optimizer.cc` — a `single_engine_for_pushdown()` helper and a call at
  the tail of `JOIN::optimize()` (after `push_to_engines()`, before
  `set_plan_state(PLAN_READY)`), gated on `!is_explain()`: if every base table
  belongs to one engine offering `pushdown_select`, invoke it. The engine may set
  `JOIN::override_executor_func` (which the executor already checks in
  `sql/sql_union.cc`). Declining leaves normal iterator execution untouched.

The engine side lives in `engine/duckdb_pushdown.{h,cc}` and registers the hook in
`ducksdb_init_func` (`engine/ha_duckdb.cc`).
