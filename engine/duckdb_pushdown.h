// Copyright (c) 2026 ducksdb-mysql-engine contributors.
// SPDX-License-Identifier: GPL-2.0
//
// Whole-query pushdown for ENGINE=DuckDB. Registered as the
// primary handlerton's `pushdown_select` callback (a small MySQL 9.7 server patch
// in sql/handler.h + sql/sql_optimizer.cc). When a SELECT's base tables are all
// ENGINE=DuckDB and the block is translatable, the whole query is regenerated as
// DuckDB SQL, executed in DuckDB, and the result streamed back to the client via
// JOIN::override_executor_func — no secondary engine, no SECONDARY_LOAD.
//
// The DuckDB SQL is produced by a structured AST→SQL builder
// (BuildPushdownSQLBuilder): it parameterizes every literal as a DuckDB bind
// value (no string concatenation) and maps MySQL collations to DuckDB collations
// so default-collation tables push down. Any unsupported shape declines and falls
// back to normal MySQL execution.
//
// Plan lifetime is tied to the session: the plan is carried on a THD-keyed
// registry (not a thread_local), so an optimize-without-execute releases the
// DuckDB connection at the THD's next pushdown rather than leaking it onto an
// OS thread that a pool may hand to another session.

#ifndef DUCKSDB_DUCKDB_PUSHDOWN_H
#define DUCKSDB_DUCKDB_PUSHDOWN_H

#include <string>

class THD;
class JOIN;
class Item;
class Query_block;
struct CHARSET_INFO;

namespace duckdb {
class Value;
}  // namespace duckdb

namespace ducksdb_mysql {

// handlerton::pushdown_select callback. Decide whether `join` is a whole-query
// DuckDB candidate; if so, set join->override_executor_func and return false.
// Declining (leaving override unset) also returns false → normal iterator
// execution proceeds (transparent fallback). Returns true only on a real error.
bool PushdownSelect(THD *thd, JOIN *join);

// Number of SELECTs whose execution was taken over by DuckDB pushdown so far
// (process-global). Exposed as the status variable Ducksdb_pushdown_count so
// tests/ops can confirm a query actually ran in DuckDB.
unsigned long long PushdownCount();

// Release any pushdown plan still stashed for `thd` (and its DuckDB connection +
// prepared statement). Normally a plan self-clears at the THD's next optimize or
// at execute; this is the disconnect-time safety net for the optimize-without-
// execute-then-disconnect path. Idempotent; safe when no plan is stashed. Called
// from the engine's close_connection handlerton callback.
void ReleasePushdownPlan(const THD *thd);

// ---------------------------------------------------------------------------
// Pure, server-independent helpers used by the structured builder. Declared here
// so the unit suite (test_pushdown_builder.cc) can exercise them without linking
// the whole server; the AST-walking entry point BuildPushdownPlan stays internal
// to the .cc (it needs THD/Query_block, only reachable in the server build).
// ---------------------------------------------------------------------------

// Collation mapping. Decide how a MySQL column/comparison collation
// renders in DuckDB:
//   * byte-comparable (_bin / binary, MY_CS_BINSORT) → DuckDB's default byte
//     compare: no COLLATE clause needed (kNone, empty suffix).
//   * accent/case-insensitive default-style (_ai_ci / _ci, not case sensitive) →
//     DuckDB `COLLATE NOCASE` (kNoCase).
//   * anything else (case-sensitive non-binary, unknown) → decline (kDecline):
//     the builder must NOT push the query down rather than risk a different
//     ordering/grouping/DISTINCT result.
enum class CollationMap {
  kNone,     // byte compare; no COLLATE suffix
  kNoCase,   // DuckDB COLLATE NOCASE
  kDecline,  // unmappable → caller must decline pushdown
};
CollationMap MapCollation(const CHARSET_INFO *cs);

// SQL suffix for a CollationMap (" COLLATE NOCASE" or ""). kDecline → "".
std::string CollateSuffix(CollationMap m);

// Convert a basic-const MySQL literal Item to an exact DuckDB bind Value.
// Accepts only side-effect-free basic_const_item() literals whose value maps
// EXACTLY: INT (signed/unsigned) and DECIMAL. REAL/DOUBLE and string/temporal
// literals are declined (ULP / charset / parse ambiguity) — returns false and
// leaves *out untouched. NULL literals → typed-NULL Value, returns true.
bool ItemLiteralToValue(Item *it, duckdb::Value *out);

}  // namespace ducksdb_mysql

#endif  // DUCKSDB_DUCKDB_PUSHDOWN_H
