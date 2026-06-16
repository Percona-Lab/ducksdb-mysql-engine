// Copyright (c) 2026 ducksdb-mysql-engine contributors.
// SPDX-License-Identifier: GPL-2.0

#include "duckdb_pushdown.h"

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "my_base.h"  // HA_POS_ERROR
#include "my_bitmap.h"
#include "mysql/strings/m_ctype.h"
#include "mysqld_error.h"
#include "scope_guard.h"
#include "sql/enum_query_type.h"
#include "sql/field.h"
#include "sql/item.h"
#include "sql/item_cmpfunc.h"
#include "sql/item_func.h"
#include "sql/item_sum.h"
#include "sql/query_options.h"  // TMP_TABLE_ALL_COLUMNS
#include "sql/query_result.h"
#include "sql/sql_class.h"
#include "sql/sql_lex.h"
#include "sql/sql_optimizer.h"
#include "sql/sql_select.h"     // count_field_types
#include "sql/sql_tmp_table.h"  // create_tmp_table / free_tmp_table
#include "sql/table.h"
#include "sql/temp_table_param.h"
#include "sql/visible_fields.h"  // Query_block::visible_fields()
#include "sql_string.h"
#include "template_utils.h"  // down_cast

#include "duckdb.hpp"
#include "duckdb_engine_context.h"
#include "duckdb_sql_util.h"  // QuoteIdent
#include "duckdb_types.h"     // StoreFlatCell, FieldToValue
#include "ha_duckdb.h"        // ducksdb_hton

namespace ducksdb_mysql {

// Process-global count of queries taken over by DuckDB pushdown (see header).
static std::atomic<unsigned long long> g_pushdown_count{0};

namespace {

void RaiseDuckDBError(const char *msg) {
  my_error(ER_GET_ERRMSG, MYF(0), 0, msg, "DuckDB");
}

// Phase timing for tuning, on when DUCKSDB_PD_TIMING is set in the environment.
// Lines go to the server error log; harmless and removable.
using PdClock = std::chrono::steady_clock;
static inline double PdMs(PdClock::time_point a, PdClock::time_point b) {
  return std::chrono::duration<double, std::milli>(b - a).count();
}
static inline bool PdTiming() {
  static const bool on = std::getenv("DUCKSDB_PD_TIMING") != nullptr;
  return on;
}

}  // namespace

// ---------------------------------------------------------------------------
// Collation mapping — pure, unit-tested in test_pushdown_builder.cc.
// ---------------------------------------------------------------------------

CollationMap MapCollation(const CHARSET_INFO *cs) {
  if (cs == nullptr) return CollationMap::kDecline;
  // Byte-comparable: _bin collations and the binary charset. DuckDB's default
  // string comparison is byte-wise, so no COLLATE clause is needed and ordering/
  // grouping/DISTINCT match exactly.
  if (cs->state & MY_CS_BINSORT) return CollationMap::kNone;
  // Case-/accent-insensitive collations (e.g. utf8mb4_0900_ai_ci, the 8.0+
  // default): MY_CS_CSSORT is NOT set (not case sensitive). DuckDB's
  // `COLLATE NOCASE` lower-cases ASCII before comparing — a faithful match for
  // ASCII data and the common default-collation case. Accent sensitivity beyond
  // case is not modeled by NOCASE; we therefore restrict to *_ai_ci collations
  // (accent-insensitive AND case-insensitive) whose ordering NOCASE approximates,
  // and decline accent-sensitive case-insensitive ones to stay correct.
  if (!(cs->state & MY_CS_CSSORT)) {
    const char *name = cs->m_coll_name;
    if (name != nullptr) {
      const std::string n(name);
      // Accent-insensitive, case-insensitive (default family) → NOCASE.
      if (n.find("_ai_ci") != std::string::npos ||
          n.find("_general_ci") != std::string::npos ||
          n.find("_unicode_ci") != std::string::npos) {
        return CollationMap::kNoCase;
      }
    }
  }
  // Case-sensitive non-binary, accent-sensitive _ci, or unknown: decline.
  return CollationMap::kDecline;
}

std::string CollateSuffix(CollationMap m) {
  switch (m) {
    case CollationMap::kNoCase:
      return " COLLATE NOCASE";
    case CollationMap::kNone:
    case CollationMap::kDecline:
    default:
      return std::string();
  }
}

bool ItemLiteralToValue(Item *it, duckdb::Value *out) {
  if (it == nullptr || out == nullptr) return false;
  Item *r = it->real_item();
  if (r == nullptr) return false;
  if (r->type() == Item::NULL_ITEM) {
    *out = duckdb::Value();  // untyped NULL; cast on bind
    return true;
  }
  // Constant temporal values: a DATE literal, or a folded CAST(<lit> AS date) /
  // any const expression whose resolved type is DATE/DATETIME/TIMESTAMP/TIME.
  // These are NOT basic_const_item() (e.g. CAST is a function), so handle them
  // before the basic-const gate. Safe because MySQL DATE/DATETIME literals are
  // wall-clock (no timezone) and DuckDB DATE/TIMESTAMP/TIME are tz-naive: the
  // item's canonical ISO string (val_str) casts unambiguously to the matching
  // DuckDB temporal type. Any parse/range failure (e.g. a >24h or negative TIME
  // that DuckDB TIME cannot hold) throws and we decline.
  if (r->const_item() && r->is_temporal()) {
    duckdb::LogicalType target = duckdb::LogicalType::SQLNULL;
    switch (real_type_to_type(r->data_type())) {
      case MYSQL_TYPE_DATE:
      case MYSQL_TYPE_NEWDATE:
        target = duckdb::LogicalType::DATE;
        break;
      case MYSQL_TYPE_DATETIME:
      case MYSQL_TYPE_TIMESTAMP:
        target = duckdb::LogicalType::TIMESTAMP;
        break;
      case MYSQL_TYPE_TIME:
        target = duckdb::LogicalType::TIME;
        break;
      default:
        return false;  // unsupported temporal flavor (e.g. YEAR): decline
    }
    String tmp;
    String *s = r->val_str(&tmp);
    if (s == nullptr || r->null_value) return false;
    try {
      *out =
          duckdb::Value(std::string(s->ptr(), s->length())).DefaultCastAs(target);
    } catch (const std::exception &) {
      return false;
    }
    return true;
  }
  // Bind any constant the optimizer can evaluate, not just raw literals. MySQL
  // const-folds expressions like `1 + 10` into a cached constant that is neither
  // basic_const_item() nor a FUNC_ITEM, so the structural switch would decline it
  // (this is what blocked TPC-H Q19's `l_quantity <= 1 + 10`). const_item()
  // guarantees a stable, table-independent value for the whole query, and we bind
  // that evaluated value (val_int/val_decimal/val_str) — DuckDB uses the bound
  // value verbatim, so binding the folded constant is exactly equivalent. REAL
  // still declines below (float intermediary risks ULP drift).
  if (!r->const_item()) return false;
  switch (r->result_type()) {
    case INT_RESULT: {
      const longlong v = r->val_int();
      if (r->null_value) return false;
      *out = r->unsigned_flag
                 ? duckdb::Value::UBIGINT(static_cast<uint64_t>(v))
                 : duckdb::Value::BIGINT(static_cast<int64_t>(v));
      return true;
    }
    case DECIMAL_RESULT: {
      // Render the exact decimal string and let DuckDB parse it as DECIMAL —
      // no float intermediary, so no ULP loss.
      String tmp;
      String *s = r->val_str(&tmp);
      if (s == nullptr || r->null_value) return false;
      try {
        *out = duckdb::Value(std::string(s->ptr(), s->length()))
                   .DefaultCastAs(duckdb::LogicalType::DECIMAL(38, 10));
      } catch (const std::exception &) {
        return false;
      }
      return true;
    }
    case STRING_RESULT: {
      // Non-temporal string literal (temporal literals were handled above as
      // typed DuckDB temporal Values). Bind the raw bytes as a DuckDB string.
      // Comparison correctness against a column is governed by that column's
      // COLLATE suffix from RenderField (unmappable collations already decline),
      // so the literal value itself is exact — no escaping/charset divergence.
      String tmp;
      String *s = r->val_str(&tmp);
      if (s == nullptr || r->null_value) return false;
      try {
        *out = duckdb::Value(std::string(s->ptr(), s->length()));
      } catch (const std::exception &) {
        return false;
      }
      return true;
    }
    default:
      // REAL/DOUBLE literals: declined — float intermediary risks ULP drift, so
      // the builder declines the whole query rather than emit a divergent value.
      return false;
  }
}

namespace {

// ===========================================================================
// Structured AST→SQL builder — the sole pushdown SQL generator.
//
// Partial function: every Render* helper returns true on success or false to
// DECLINE; any decline bubbles up so BuildPushdownSQLBuilder returns false and
// MySQL executes the query normally. The builder NEVER emits SQL it cannot prove
// semantically identical — declining is always safe, wrong SQL is not.
//
// Literals are bound as DuckDB positional parameters ($1..$N), never
// concatenated, which removes the escaping/injection surface entirely.
// ===========================================================================

// Mutable state threaded through the recursive descent. `params` accumulates the
// bound literal Values in placeholder order; the placeholder $N for each is its
// 1-based index in `params` after the push (see RenderLiteral).
struct BuildCtx {
  duckdb::vector<duckdb::Value> params;
  Query_block *qb{nullptr};
  // Single-schema guard: all leaf tables must share one DuckDB file.
  const char *db{nullptr};
  size_t dblen{0};
};

// Append a literal as a bound parameter and emit its placeholder ($N).
bool RenderLiteral(BuildCtx *ctx, Item *it, std::string *out) {
  duckdb::Value v;
  if (!ItemLiteralToValue(it, &v)) return false;
  ctx->params.push_back(std::move(v));
  *out = "$" + std::to_string(ctx->params.size());
  return true;
}

// Qualified column reference: "table"."column"[ COLLATE NOCASE].
//
// Collation handling: a string column's collation must map (else decline so
// a case/accent difference can't change ordering/grouping/DISTINCT). When it maps
// to NOCASE we append `COLLATE NOCASE` to the column reference itself, so EVERY
// context the column appears in — comparison, ORDER BY, GROUP BY, DISTINCT — gets
// the case-insensitive semantics MySQL's _ci collation implies. Byte-comparable
// (_bin/binary) columns and non-string columns get no suffix.
bool RenderField(BuildCtx * /*ctx*/, Item *it, std::string *out) {
  Item *r = it->real_item();
  if (r == nullptr || r->type() != Item::FIELD_ITEM) return false;
  const Item_field *f = down_cast<const Item_field *>(r);
  if (f->field == nullptr) return false;
  std::string suffix;
  if (f->field->result_type() == STRING_RESULT &&
      !is_temporal_real_type(f->field->real_type())) {
    const CollationMap cm = MapCollation(f->field->charset());
    if (cm == CollationMap::kDecline) return false;
    suffix = CollateSuffix(cm);
  }
  std::string col;
  if (f->table_name != nullptr && f->table_name[0] != '\0')
    col = QuoteIdent(f->table_name) + ".";
  col += QuoteIdent(f->field_name != nullptr ? f->field_name : "");
  *out = col + suffix;
  return true;
}

// Bare qualified column reference: "table"."column" WITHOUT any COLLATE suffix,
// plus the column's CollationMap. Used by LIKE, where DuckDB's COLLATE does NOT
// affect LIKE/ILIKE matching, so the suffix must be omitted and case-sensitivity
// chosen by operator (LIKE vs ILIKE) instead. Returns false if the item is not a
// plain field. Non-string columns report kNone (byte/exact).
bool RenderFieldBare(Item *it, std::string *out, CollationMap *cm_out) {
  Item *r = it->real_item();
  if (r == nullptr || r->type() != Item::FIELD_ITEM) return false;
  const Item_field *f = down_cast<const Item_field *>(r);
  if (f->field == nullptr) return false;
  CollationMap cm = CollationMap::kNone;
  if (f->field->result_type() == STRING_RESULT &&
      !is_temporal_real_type(f->field->real_type())) {
    cm = MapCollation(f->field->charset());
  }
  std::string col;
  if (f->table_name != nullptr && f->table_name[0] != '\0')
    col = QuoteIdent(f->table_name) + ".";
  col += QuoteIdent(f->field_name != nullptr ? f->field_name : "");
  *out = col;
  if (cm_out != nullptr) *cm_out = cm;
  return true;
}

bool RenderExpr(BuildCtx *ctx, Item *it, std::string *out);
bool RenderPredicate(BuildCtx *ctx, Item *cond, std::string *out);
bool RenderCase(BuildCtx *ctx, Item_func *fn, std::string *out);

// LIKE-vs-ILIKE-vs-decline decision from a column's collation. Pure (no Item
// access), so it is unit-tested in test_pushdown_builder.cc. DuckDB's LIKE is
// always case-sensitive and COLLATE does not influence it, so:
//   * kNoCase (MySQL _ai_ci, case-insensitive) → "ILIKE" (case-insensitive)
//   * kNone   (_bin/binary, byte-exact)        → "LIKE"  (case-sensitive)
//   * kDecline                                 → nullptr (decline)
// Returns the DuckDB operator keyword, or nullptr to decline.
const char *LikeOperatorFor(CollationMap cm) {
  switch (cm) {
    case CollationMap::kNoCase:
      return "ILIKE";
    case CollationMap::kNone:
      return "LIKE";
    case CollationMap::kDecline:
    default:
      return nullptr;
  }
}

// Arithmetic over covered operands: (a OP b).
bool RenderArith(BuildCtx *ctx, Item_func *fn, const char *op,
                 std::string *out) {
  if (fn->argument_count() != 2) return false;
  std::string a, b;
  if (!RenderExpr(ctx, fn->arguments()[0], &a)) return false;
  if (!RenderExpr(ctx, fn->arguments()[1], &b)) return false;
  *out = "(" + a + " " + op + " " + b + ")";
  return true;
}

// A scalar aggregate in the select/having list: COUNT/SUM/AVG/MIN/MAX with the
// COUNT(*) and DISTINCT variants. GROUP_CONCAT/JSON/window aggregates decline.
bool RenderAggregate(BuildCtx *ctx, Item_sum *agg, std::string *out) {
  const char *fnname = nullptr;
  bool distinct = false;
  bool star = false;
  switch (agg->sum_func()) {
    case Item_sum::COUNT_FUNC:
      fnname = "count";
      break;
    case Item_sum::COUNT_DISTINCT_FUNC:
      fnname = "count";
      distinct = true;
      break;
    case Item_sum::SUM_FUNC:
      fnname = "sum";
      break;
    case Item_sum::SUM_DISTINCT_FUNC:
      fnname = "sum";
      distinct = true;
      break;
    case Item_sum::AVG_FUNC:
      fnname = "avg";
      break;
    case Item_sum::AVG_DISTINCT_FUNC:
      fnname = "avg";
      distinct = true;
      break;
    case Item_sum::MIN_FUNC:
      fnname = "min";
      break;
    case Item_sum::MAX_FUNC:
      fnname = "max";
      break;
    default:
      return false;  // GROUP_CONCAT / JSON_*AGG / window / STD / VARIANCE: decline
  }
  // COUNT(*) has one argument that is the special "0"/star sentinel; detect it
  // structurally: an INT_ITEM constant argument with COUNT means COUNT(*).
  std::string arg;
  if (agg->argument_count() == 0) {
    star = true;  // bare COUNT()
  } else if (agg->argument_count() == 1) {
    Item *a = agg->arguments()[0]->real_item();
    if (std::string(fnname) == "count" && a != nullptr &&
        a->type() == Item::INT_ITEM && a->basic_const_item()) {
      star = true;  // COUNT(*) — printed as COUNT(0) post-optimize
    } else if (!RenderExpr(ctx, agg->arguments()[0], &arg)) {
      return false;
    }
  } else {
    return false;  // multi-arg aggregate not in scope
  }
  std::string body =
      std::string(fnname) + "(" + (distinct ? "DISTINCT " : "") +
      (star ? "*" : arg) + ")";
  *out = body;
  return true;
}

// Any scalar expression appearing in SELECT/GROUP BY/ORDER BY/predicate operand.
bool RenderExpr(BuildCtx *ctx, Item *it, std::string *out) {
  if (it == nullptr) return false;
  Item *r = it->real_item();
  if (r == nullptr) return false;  // Item_ref/Item_cache not unwrappable
  // Constants bind as $N params via ItemLiteralToValue — try this FIRST so any
  // constant the optimizer can evaluate (a CAST like CAST('1998-09-02' AS date),
  // a string/temporal literal, or const-folded arithmetic like 1+10) is bound by
  // value rather than falling into the structural switch below (which only knows
  // fields, aggregates, +-*/, CASE). A const we cannot bind (REAL — float ULP
  // drift) declines here without pushing a param and falls through to structural
  // rendering.
  if (r->const_item()) {
    std::string lit;
    if (RenderLiteral(ctx, r, &lit)) {
      *out = std::move(lit);
      return true;
    }
  }
  switch (r->type()) {
    case Item::FIELD_ITEM:
      return RenderField(ctx, r, out);
    case Item::INT_ITEM:
    case Item::DECIMAL_ITEM:
    case Item::NULL_ITEM:
      return RenderLiteral(ctx, r, out);
    case Item::SUM_FUNC_ITEM:
      return RenderAggregate(ctx, down_cast<Item_sum *>(r), out);
    case Item::FUNC_ITEM: {
      auto *fn = down_cast<Item_func *>(r);
      switch (fn->functype()) {
        case Item_func::PLUS_FUNC:
          return RenderArith(ctx, fn, "+", out);
        case Item_func::MINUS_FUNC:
          return RenderArith(ctx, fn, "-", out);
        case Item_func::MUL_FUNC:
          return RenderArith(ctx, fn, "*", out);
        case Item_func::DIV_FUNC:
          return RenderArith(ctx, fn, "/", out);
        case Item_func::CASE_FUNC:
          return RenderCase(ctx, fn, out);
        default:
          return false;  // non-whitelisted scalar function: decline
      }
    }
    default:
      return false;  // string/date/CASE/IF/CAST/subselect/etc.: decline
  }
}

bool RenderPredicate(BuildCtx *ctx, Item *cond, std::string *out);

const char *CmpOpName(Item_func::Functype f, bool flip) {
  switch (f) {
    case Item_func::EQ_FUNC:
      return "=";
    case Item_func::NE_FUNC:
      return "<>";
    case Item_func::LT_FUNC:
      return flip ? ">" : "<";
    case Item_func::LE_FUNC:
      return flip ? ">=" : "<=";
    case Item_func::GT_FUNC:
      return flip ? "<" : ">";
    case Item_func::GE_FUNC:
      return flip ? "<=" : ">=";
    default:
      return nullptr;
  }
}

// Binary comparison: column-vs-literal (either order) or column-vs-column.
bool RenderCompare(BuildCtx *ctx, Item_func *fn, std::string *out) {
  if (fn->argument_count() != 2) return false;
  const char *op = CmpOpName(fn->functype(), false);
  if (op == nullptr) return false;
  std::string a, b;
  if (RenderExpr(ctx, fn->arguments()[0], &a) &&
      RenderExpr(ctx, fn->arguments()[1], &b)) {
    *out = "(" + a + " " + op + " " + b + ")";
    return true;
  }
  return false;
}

bool RenderBetween(BuildCtx *ctx, Item_func *fn, std::string *out) {
  auto *bt = down_cast<Item_func_between *>(fn);
  if (bt->negated) return false;  // NOT BETWEEN: decline
  if (fn->argument_count() != 3) return false;
  std::string col, lo, hi;
  if (!RenderExpr(ctx, fn->arguments()[0], &col)) return false;
  if (!RenderExpr(ctx, fn->arguments()[1], &lo)) return false;
  if (!RenderExpr(ctx, fn->arguments()[2], &hi)) return false;
  *out = "(" + col + " BETWEEN " + lo + " AND " + hi + ")";
  return true;
}

bool RenderIn(BuildCtx *ctx, Item_func *fn, std::string *out) {
  auto *in = down_cast<Item_func_in *>(fn);
  if (in->negated) return false;  // NOT IN: decline
  if (fn->argument_count() < 2) return false;
  // String literals now flow through RenderLiteral (STRING_RESULT). The IN
  // column carries its COLLATE suffix from RenderField; unlike LIKE, DuckDB DOES
  // apply COLLATE to equality/IN comparisons, so a _ai_ci column's IN-list stays
  // case-insensitive. (Confirmed by the duckdb-suite integration test; if a
  // future DuckDB drops COLLATE on IN, this must move to ILIKE-style handling.)
  std::string col;
  if (!RenderExpr(ctx, fn->arguments()[0], &col)) return false;
  std::string vals;
  for (uint i = 1; i < fn->argument_count(); ++i) {
    std::string lit;
    if (!RenderLiteral(ctx, fn->arguments()[i], &lit)) return false;  // literals only
    if (!vals.empty()) vals += ", ";
    vals += lit;
  }
  if (vals.empty()) return false;
  *out = "(" + col + " IN (" + vals + "))";
  return true;
}

// col LIKE pattern. DuckDB LIKE is case-sensitive and unaffected by COLLATE, so
// the case-sensitivity must come from the operator: a _ai_ci column → ILIKE, a
// _bin/binary column → LIKE, anything else declines (see LikeOperatorFor). The
// left operand must be a plain field (so we know its collation); the right must
// be a string literal. Declines: a pattern containing '\\' (DuckDB and MySQL
// differ on backslash escaping), and NOT LIKE (it arrives wrapped in NOT_FUNC,
// which the predicate switch already declines, so this helper only sees bare
// LIKE). ESCAPE clauses also decline.
bool RenderLike(BuildCtx *ctx, Item_func *fn, std::string *out) {
  auto *like = down_cast<Item_func_like *>(fn);
  if (like->escape_was_used_in_parsing()) return false;  // explicit ESCAPE: decline
  if (fn->argument_count() != 2) return false;
  // Left operand: a field whose collation chooses LIKE vs ILIKE.
  std::string col;
  CollationMap cm = CollationMap::kDecline;
  if (!RenderFieldBare(fn->arguments()[0], &col, &cm)) return false;
  // Only string columns: MySQL LIKE on a numeric/temporal column implicitly
  // casts the column to a string first, and DuckDB's implicit cast can differ —
  // so restrict to genuine string fields (RenderFieldBare reports kNone for any
  // non-string field, which would otherwise pick plain LIKE). Decline otherwise.
  {
    const Item_field *lf =
        down_cast<const Item_field *>(fn->arguments()[0]->real_item());
    if (lf->field == nullptr ||
        lf->field->result_type() != STRING_RESULT ||
        is_temporal_real_type(lf->field->real_type()))
      return false;
  }
  const char *op = LikeOperatorFor(cm);
  if (op == nullptr) return false;
  // Right operand: a string literal. Inspect its raw bytes for a backslash
  // BEFORE binding — DuckDB treats '\\' in LIKE as the default escape character
  // while MySQL's default escape is also '\\', but the two diverge on edge cases
  // (e.g. trailing escape), so we conservatively decline any pattern with '\\'.
  Item *pat = fn->arguments()[1]->real_item();
  if (pat == nullptr || pat->result_type() != STRING_RESULT) return false;
  if (!pat->const_item() || pat->is_temporal()) return false;
  String tmp;
  String *s = pat->val_str(&tmp);
  if (s == nullptr || pat->null_value) return false;
  if (memchr(s->ptr(), '\\', s->length()) != nullptr) return false;
  std::string lit;
  if (!RenderLiteral(ctx, fn->arguments()[1], &lit)) return false;
  *out = "(" + col + " " + op + " " + lit + ")";
  return true;
}

bool RenderNullTest(BuildCtx *ctx, Item_func *fn, bool is_null,
                    std::string *out) {
  if (fn->argument_count() != 1) return false;
  std::string col;
  if (!RenderExpr(ctx, fn->arguments()[0], &col)) return false;
  *out = "(" + col + (is_null ? " IS NULL" : " IS NOT NULL") + ")";
  return true;
}

// Item_multi_eq(a, b, c[, const]) → a = b AND a = c [AND a = const]. Members must
// all be fields (plus an optional const_arg). Non-field members decline.
bool RenderMultiEq(BuildCtx *ctx, Item_multi_eq *meq, std::string *out) {
  std::vector<std::string> rendered;
  for (Item_field &f : meq->get_fields()) {
    std::string col;
    if (!RenderField(ctx, &f, &col)) return false;
    rendered.push_back(col);
  }
  std::string const_sql;
  Item *carg = meq->const_arg();
  if (carg != nullptr) {
    if (!RenderLiteral(ctx, carg, &const_sql)) return false;
  }
  if (rendered.empty()) return false;
  if (rendered.size() == 1 && const_sql.empty()) return false;  // nothing to equate
  std::string conj;
  const std::string &anchor = rendered[0];
  for (size_t i = 1; i < rendered.size(); ++i) {
    if (!conj.empty()) conj += " AND ";
    conj += anchor + " = " + rendered[i];
  }
  if (!const_sql.empty()) {
    if (!conj.empty()) conj += " AND ";
    conj += anchor + " = " + const_sql;
  }
  *out = "(" + conj + ")";
  return true;
}

bool RenderPredicate(BuildCtx *ctx, Item *cond, std::string *out) {
  if (cond == nullptr) return false;
  Item *r = cond->real_item();
  if (r == nullptr) return false;

  if (r->type() == Item::COND_ITEM) {
    auto *c = down_cast<Item_cond *>(r);
    const bool is_and = c->functype() == Item_func::COND_AND_FUNC;
    const bool is_or = c->functype() == Item_func::COND_OR_FUNC;
    if (!is_and && !is_or) return false;
    std::string acc;
    bool first = true;
    // Unlike the cond_pushdown.cc superset filter, the whole-query builder is
    // EXACT (it replaces the query, not just prunes rows): every conjunct/
    // disjunct must render or the whole predicate declines.
    for (Item &child : *c->argument_list()) {
      std::string part;
      if (!RenderPredicate(ctx, &child, &part)) return false;
      if (!first) acc += is_and ? " AND " : " OR ";
      acc += part;
      first = false;
    }
    if (first) return false;
    *out = "(" + acc + ")";
    return true;
  }

  if (r->type() == Item::FUNC_ITEM) {
    auto *fn = down_cast<Item_func *>(r);
    switch (fn->functype()) {
      case Item_func::EQ_FUNC:
      case Item_func::NE_FUNC:
      case Item_func::LT_FUNC:
      case Item_func::LE_FUNC:
      case Item_func::GT_FUNC:
      case Item_func::GE_FUNC:
        return RenderCompare(ctx, fn, out);
      case Item_func::BETWEEN:
        return RenderBetween(ctx, fn, out);
      case Item_func::IN_FUNC:
        return RenderIn(ctx, fn, out);
      case Item_func::LIKE_FUNC:
        return RenderLike(ctx, fn, out);
      case Item_func::ISNULL_FUNC:
        return RenderNullTest(ctx, fn, true, out);
      case Item_func::ISNOTNULL_FUNC:
        return RenderNullTest(ctx, fn, false, out);
      case Item_func::MULTI_EQ_FUNC:
        return RenderMultiEq(ctx, down_cast<Item_multi_eq *>(fn), out);
      default:
        return false;
    }
  }
  return false;
}

// Searched CASE: CASE WHEN <pred1> THEN <expr1> ... [ELSE <exprN>] END.
//
// Item_func_case argument layout (see Item_func_case::print): args[0..ncases) are
// WHEN/THEN pairs (args[2k]=WHEN predicate, args[2k+1]=THEN value); a simple-CASE
// operand, when present, sits at get_first_expr_num(); the ELSE value, when
// present, sits at get_else_expr_num(). We render only the SEARCHED form (no
// simple-CASE operand) — DuckDB CASE is SQL-standard so the searched form matches
// exactly. Each WHEN renders via RenderPredicate, each THEN/ELSE via RenderExpr;
// any sub-decline declines the whole CASE.
bool RenderCase(BuildCtx *ctx, Item_func *fn, std::string *out) {
  auto *c = down_cast<Item_func_case *>(fn);
  // Simple CASE (CASE <operand> WHEN ...) is out of scope: its WHEN arms are
  // value comparisons against the operand, not predicates. Decline.
  if (c->get_first_expr_num() != -1) return false;
  const int else_num = c->get_else_expr_num();
  const uint argc = fn->argument_count();
  // For searched CASE the ELSE (if any) is the last argument; the WHEN/THEN pairs
  // fill [0, ncases). ncases is even.
  uint ncases = argc;
  if (else_num != -1) {
    if (static_cast<uint>(else_num) != argc - 1) return false;  // unexpected shape
    ncases = argc - 1;
  }
  if (ncases == 0 || (ncases % 2) != 0) return false;
  std::string body = "CASE";
  for (uint i = 0; i < ncases; i += 2) {
    std::string when_sql, then_sql;
    if (!RenderPredicate(ctx, fn->arguments()[i], &when_sql)) return false;
    if (!RenderExpr(ctx, fn->arguments()[i + 1], &then_sql)) return false;
    body += " WHEN " + when_sql + " THEN " + then_sql;
  }
  if (else_num != -1) {
    std::string else_sql;
    if (!RenderExpr(ctx, fn->arguments()[else_num], &else_sql)) return false;
    body += " ELSE " + else_sql;
  }
  body += " END";
  *out = "(" + body + ")";
  return true;
}

// Render one SELECT-list item with its optional alias.
bool RenderSelectItem(BuildCtx *ctx, Item *it, std::string *out) {
  std::string expr;
  if (!RenderExpr(ctx, it, &expr)) return false;
  // Preserve the visible column alias so the result column names match what the
  // client expects (and what create_tmp_table builds from `visible`).
  const char *alias = it->item_name.is_set() ? it->item_name.ptr() : nullptr;
  if (alias != nullptr && alias[0] != '\0') {
    expr += " AS " + QuoteIdent(alias);
  }
  *out = expr;
  return true;
}

// FROM list: comma-separated base ENGINE=DuckDB tables. Inner joins are rendered
// as a cross product + WHERE conjunct (DuckDB accepts this and it is exactly an
// inner join); outer joins / nested-join trees are out of scope for v1 of the
// builder and decline.
bool RenderFrom(BuildCtx *ctx, std::string *out) {
  std::string from;
  for (Table_ref *tr = ctx->qb->leaf_tables; tr != nullptr;
       tr = tr->next_leaf) {
    TABLE *table = tr->table;
    if (table == nullptr || table->s == nullptr) return false;
    if (table->s->db_type() != ducksdb_hton) return false;
    // Single-schema guard.
    if (ctx->db == nullptr) {
      ctx->db = table->s->db.str;
      ctx->dblen = table->s->db.length;
    } else if (table->s->db.length != ctx->dblen ||
               memcmp(ctx->db, table->s->db.str, ctx->dblen) != 0) {
      return false;  // cross-schema join — different DuckDB files
    }
    // Outer joins change NULL-extension semantics; decline in v1 of the builder.
    if (tr->outer_join != 0 || tr->is_inner_table_of_outer_join())
      return false;
    const char *name = tr->table_name != nullptr ? tr->table_name : "";
    std::string ref = QuoteIdent(name);
    // Carry an alias when the table was aliased (so qualified column refs in the
    // select/where resolve to the same name we render here).
    if (tr->alias != nullptr && tr->alias[0] != '\0' &&
        std::strcmp(tr->alias, name) != 0) {
      ref += " AS " + QuoteIdent(tr->alias);
    }
    if (!from.empty()) from += ", ";
    from += ref;
  }
  if (from.empty()) return false;
  *out = from;
  return true;
}

// Build the whole-query DuckDB SQL from the optimized JOIN via the structured
// visitor. Returns false (decline) on any unsupported node. On success: *sql_out
// is parameterized DuckDB SQL, *params_out holds the bound literals in $N order,
// *db_out is the (single) schema. The SELECT list is rendered from the same
// `join->fields` (non-hidden) slice ExecutePushdown streams back, so the result
// column count/order matches the staging temp table exactly.
bool BuildPushdownSQLBuilder(const THD *thd, JOIN *join, std::string *db_out,
                             std::string *sql_out,
                             duckdb::vector<duckdb::Value> *params_out) {
  Query_block *qb = join->query_block;
  // Log the exact stage we decline at (diagnostic; gated on DUCKSDB_PD_TIMING).
  auto decline = [](const char *why) -> bool {
    if (PdTiming()) {
      fprintf(stderr, "[pd-decline-at] %s\n", why);
      fflush(stderr);
    }
    return false;
  };
  // Block-level gates (same as the TEXT path): no UNION/subquery/window/ROLLUP/
  // params; must be (implicitly) grouped to be a worthwhile offload candidate.
  Query_expression *unit = qb->master_query_expression();
  if (unit == nullptr || !unit->is_simple()) return decline("not-simple/union");
  if (!(qb->is_grouped() || qb->is_implicitly_grouped())) return decline("not-grouped");
  if (qb->first_inner_query_expression() != nullptr) return decline("subquery");
  if (qb->has_windows()) return decline("windows");
  if (qb->olap != UNSPECIFIED_OLAP_TYPE) return decline("rollup");
  if (thd->lex->param_list.elements != 0) return decline("params");
  if (qb->leaf_tables == nullptr) return decline("no-leaf");

  BuildCtx ctx;
  ctx.qb = qb;

  // FROM (also runs the single-schema + ENGINE=DuckDB + outer-join gates).
  std::string from_sql;
  if (!RenderFrom(&ctx, &from_sql)) return decline("from");

  // SELECT list — render from the query block's ORIGINAL resolved select items
  // (visible_fields()), not a post-optimization ref slice. At the pushdown hook
  // these coincide (REF_SLICE_SAVED_BASE), and the column order matches what
  // ExecutePushdown streams back; using the canonical list keeps the builder
  // correct regardless of slice state. Every item must render or we decline.
  std::string select_sql;
  bool first = true;
  for (Item *it : qb->visible_fields()) {
    std::string item_sql;
    if (!RenderSelectItem(&ctx, it, &item_sql)) return decline("select-item");
    if (!first) select_sql += ", ";
    select_sql += item_sql;
    first = false;
  }
  if (first) return decline("empty-select");

  std::string sql = "SELECT ";
  if (qb->is_distinct()) sql += "DISTINCT ";
  sql += select_sql + " FROM " + from_sql;

  // WHERE.
  if (Item *w = qb->where_cond()) {
    std::string where_sql;
    if (!RenderPredicate(&ctx, w, &where_sql)) return decline("where");
    sql += " WHERE " + where_sql;
  }

  // GROUP BY. DuckDB requires EVERY non-aggregated SELECT column to appear in
  // GROUP BY; MySQL relaxes this via functional dependency and its optimizer may
  // have PRUNED FD-determined columns out of group_list. So emit the UNION of the
  // (possibly pruned) group_list and every non-aggregate visible SELECT column.
  // This is semantically identical — the pruned columns are single-valued within
  // each group, so adding them creates no new groups — and is valid for DuckDB.
  if (qb->group_list.elements > 0) {
    std::vector<std::string> keys;
    auto add_key = [&keys](const std::string &s) {
      for (const auto &k : keys)
        if (k == s) return;
      keys.push_back(s);
    };
    for (ORDER *g = qb->group_list.first; g != nullptr; g = g->next) {
      std::string g_sql;
      if (!RenderExpr(&ctx, *g->item, &g_sql)) return decline("group");
      add_key(g_sql);
    }
    for (Item *it : qb->visible_fields()) {
      if (it->has_aggregation()) continue;  // aggregates are not group keys
      std::string s_sql;
      if (!RenderExpr(&ctx, it, &s_sql)) return decline("group-select");
      add_key(s_sql);
    }
    std::string group_sql;
    for (size_t i = 0; i < keys.size(); ++i) {
      if (i) group_sql += ", ";
      group_sql += keys[i];
    }
    if (!keys.empty()) sql += " GROUP BY " + group_sql;
  }

  // HAVING.
  if (Item *h = qb->having_cond()) {
    std::string having_sql;
    if (!RenderPredicate(&ctx, h, &having_sql)) return decline("having");
    sql += " HAVING " + having_sql;
  }

  // ORDER BY with ASC/DESC.
  if (qb->order_list.elements > 0) {
    std::string order_sql;
    bool ofirst = true;
    for (ORDER *o = qb->order_list.first; o != nullptr; o = o->next) {
      std::string o_sql;
      if (!RenderExpr(&ctx, *o->item, &o_sql)) return decline("order");
      // MySQL sorts NULL as the lowest value (NULLs first on ASC, last on DESC).
      // DuckDB's default null ordering is the opposite, so emit it EXPLICITLY to
      // match MySQL regardless of DuckDB's configured default — otherwise an
      // ORDER BY on a nullable column (especially with LIMIT) returns rows in a
      // different order / a different row set.
      o_sql += (o->direction == ORDER_DESC) ? " DESC NULLS LAST"
                                            : " ASC NULLS FIRST";
      if (!ofirst) order_sql += ", ";
      order_sql += o_sql;
      ofirst = false;
    }
    if (!ofirst) sql += " ORDER BY " + order_sql;
  }

  // LIMIT / OFFSET as bound parameters. We only render an EXPLICIT LIMIT/OFFSET.
  const ha_rows limit = qb->get_limit(thd);
  const ha_rows offset = qb->get_offset(thd);
  // Decline ONLY when a FINITE session SQL_SELECT_LIMIT (no explicit clause) would
  // silently cap rows we don't render. The common case — SQL_SELECT_LIMIT=DEFAULT,
  // i.e. unlimited, where get_limit() == HA_POS_ERROR — is safe to push with no
  // LIMIT clause. (The old unconditional gate here declined every no-LIMIT query.)
  if (qb->m_use_select_limit && qb->select_limit == nullptr &&
      limit != HA_POS_ERROR)
    return decline("implicit-select-limit");
  // ha_rows is unsigned 64-bit; DuckDB LIMIT/OFFSET bind as signed BIGINT. A value
  // above INT64_MAX would wrap to a negative bind param (silently wrong results),
  // so decline pushdown rather than emit it (such limits are absurd in practice).
  constexpr ha_rows kInt64Max = static_cast<ha_rows>(INT64_MAX);
  if (limit != HA_POS_ERROR && qb->select_limit != nullptr) {
    if (limit > kInt64Max) return decline("limit-overflow");
    ctx.params.push_back(
        duckdb::Value::BIGINT(static_cast<int64_t>(limit)));
    sql += " LIMIT $" + std::to_string(ctx.params.size());
  }
  if (offset != 0 && qb->offset_limit != nullptr) {
    if (offset > kInt64Max) return decline("offset-overflow");
    ctx.params.push_back(
        duckdb::Value::BIGINT(static_cast<int64_t>(offset)));
    sql += " OFFSET $" + std::to_string(ctx.params.size());
  }

  *db_out = std::string(ctx.db, ctx.dblen);
  *sql_out = std::move(sql);
  *params_out = std::move(ctx.params);
  return true;
}

// ===========================================================================
// Per-statement plan + lifetime: carried on a THD/JOIN-keyed
// registry instead of a thread_local, so an optimize-without-execute releases
// the DuckDB connection + prepared statement deterministically.
// ===========================================================================
struct PushdownPlan {
  std::string db;
  std::string sql;  // diagnostic: the SQL handed to DuckDB
  duckdb::vector<duckdb::Value> params;  // bound literals ($1..$N), builder path
  std::unique_ptr<duckdb::Connection> conn;
  std::unique_ptr<duckdb::PreparedStatement> prep;
  double build_ms{0}, prep_ms{0};  // optimize-phase timings (diagnostic)
};

// Registry keyed by the owning THD (the session/connection), not a thread_local.
// A THD runs its statements serially, so at most one pushdown plan
// is live per THD: PushdownSelect installs it at optimize (after dropping any
// stale plan left by this THD's previous optimize, e.g. one that never executed),
// ExecutePushdown takes+releases it at execute. Tying the key to the THD rather
// than the OS thread is the real fix over thread_local: under a thread pool one
// OS thread serves many THDs, so a thread_local plan could be picked up by the
// wrong session — keying by THD cannot. Guarded by a mutex (distinct THDs run on
// distinct threads but share this map). Taking ownership via unique_ptr releases
// the DuckDB connection + prepared statement deterministically, so an
// optimize-without-execute cannot leak a connection past the THD's next pushdown.
class PlanRegistry {
 public:
  static PlanRegistry &Get() {
    static PlanRegistry inst;
    return inst;
  }
  void Put(const THD *thd, std::unique_ptr<PushdownPlan> plan) {
    std::lock_guard<std::mutex> lk(mu_);
    plans_[thd] = std::move(plan);
  }
  // Hand ownership of the plan to the caller, removing it from the registry. A
  // null return (no entry) is the normal case for a non-pushdown statement.
  std::unique_ptr<PushdownPlan> Take(const THD *thd) {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = plans_.find(thd);
    if (it == plans_.end()) return nullptr;
    std::unique_ptr<PushdownPlan> p = std::move(it->second);
    plans_.erase(it);
    return p;
  }

 private:
  std::mutex mu_;
  std::map<const THD *, std::unique_ptr<PushdownPlan>> plans_;
};

// JOIN::override_executor_func: run the whole query in DuckDB and stream the
// (small, aggregated) result back through the statement's Query_result. Returns
// true on error.
bool ExecutePushdown(JOIN *join, Query_result *qr) {
  THD *thd = join->thd;
  // Take the plan stashed by PushdownSelect; its unique_ptr releases the DuckDB
  // connection + prepared statement when this function returns (any path).
  std::unique_ptr<PushdownPlan> plan = PlanRegistry::Get().Take(thd);
  if (plan == nullptr || plan->prep == nullptr) {
    RaiseDuckDBError("pushdown plan missing");
    return true;
  }

  // Execute the already-parsed+bound statement (no re-parse, no second
  // connection, no second SQL generation). Force a materialized result.
  const auto te0 = PdClock::now();
  std::unique_ptr<duckdb::QueryResult> qres;
  try {
    // Bound literals (builder path) or empty (text path).
    qres = plan->prep->Execute(plan->params, /*allow_stream_result=*/false);
  } catch (const std::exception &e) {
    RaiseDuckDBError(e.what());
    return true;
  }
  if (qres == nullptr || qres->HasError()) {
    RaiseDuckDBError(qres ? qres->GetError().c_str() : "DuckDB query failed");
    return true;
  }
  auto &res = static_cast<duckdb::MaterializedQueryResult &>(*qres);
  const auto te1 = PdClock::now();  // DuckDB execute done

  // Stage the result in a temp table whose visible columns match the query
  // output 1:1 with the DuckDB result columns (the select list was printed from
  // these same visible items, in order).
  mem_root_deque<Item *> visible(thd->mem_root);
  for (Item *it : *join->fields)
    if (!it->hidden) visible.push_back(it);
  if (res.ColumnCount() != visible.size()) {
    RaiseDuckDBError("pushdown column count mismatch");
    return true;
  }

  Temp_table_param tmp_param;
  count_field_types(join->query_block, &tmp_param, visible,
                    /*reset_with_sum_func=*/false, /*save_sum_fields=*/true);
  tmp_param.skip_create_table = true;  // only Field buffers, not storage
  // TMP_TABLE_ALL_COLUMNS forces exactly one result field per visible item,
  // regardless of aggregation. Without it, create_tmp_table skips a field for any
  // item that aggregates but is not a bare Item_sum (e.g. post-aggregation
  // arithmetic `100*sum(x)/sum(y)`): it routes such items to outer_sum_func_count
  // and sets store_column=false, so visible_field_ptr() ends up shorter than
  // `visible` and vf[i] reads out of bounds. The aggregation is already computed
  // by DuckDB — we only need a typed slot per output column to fill ourselves, so
  // the all-columns mode is exactly right here (it also leaves the original query
  // items unmodified).
  TABLE *table = create_tmp_table(thd, &tmp_param, visible, /*group=*/nullptr,
                                  /*distinct=*/false, /*save_sum_fields=*/true,
                                  thd->variables.option_bits | TMP_TABLE_ALL_COLUMNS,
                                  HA_POS_ERROR, "duckdb_pushdown");
  if (table == nullptr) {
    RaiseDuckDBError("pushdown temp table failed");
    return true;
  }
  // Defensive: the staging logic below indexes vf[0..visible.size()); a shorter
  // field array would read out of bounds. With TMP_TABLE_ALL_COLUMNS this holds,
  // but verify rather than trust. NOTE: this returns BEFORE the cleanup scope
  // guard below is established, so it must free the table by hand (no double-free
  // — the guard does not exist yet). Any new early return inserted between
  // create_tmp_table and the guard must likewise free the table manually.
  if (static_cast<size_t>(table->visible_field_count()) != visible.size()) {
    close_tmp_table(table);
    free_tmp_table(table);
    RaiseDuckDBError("pushdown staging field-count mismatch");
    return true;
  }
  // Canonical teardown: close_tmp_table() drops the storage handler (create_tmp_table
  // allocates one even with skip_create_table=true), then free_tmp_table() releases
  // the table. free_tmp_table() alone asserts !has_storage_handler() in debug.
  auto cleanup = create_scope_guard([table] {
    close_tmp_table(table);
    free_tmp_table(table);
  });

  Field **vf = table->visible_field_ptr();
  mem_root_deque<Item *> out_items(thd->mem_root);
  for (size_t i = 0; i < visible.size(); ++i) {
    Item *it = new (thd->mem_root) Item_field(vf[i]);
    if (it == nullptr) return true;
    out_items.push_back(it);
  }

  const auto te2 = PdClock::now();  // staging (temp table + items) done
  my_bitmap_map *org_w = tmp_use_all_columns(table, table->write_set);
  my_bitmap_map *org_r = tmp_use_all_columns(table, table->read_set);
  // Restore the column maps on EVERY exit from here on (including an exception
  // thrown by a DuckDB call below): leaving write_set/read_set pointing at
  // all_set would corrupt the table teardown that the cleanup guard runs.
  auto map_guard = create_scope_guard([&] {
    tmp_restore_column_map(table->write_set, org_w);
    tmp_restore_column_map(table->read_set, org_r);
  });
  // Stream the result chunk by chunk, reading each column's vector with typed
  // accessors (StoreFlatCell) instead of building a duckdb::Value per cell.
  // DuckDB's Fetch/Flatten/GetValue can throw; keep exceptions from escaping
  // into the MySQL executor (which is not exception-safe across the C ABI).
  uint64_t nrows = 0;
  bool err = false;
  try {
    while (!err) {
      auto chunk = res.Fetch();
      if (chunk == nullptr || chunk->size() == 0) break;
      chunk->Flatten();  // ensure FLAT vectors for the typed accessors
      assert(chunk->ColumnCount() == visible.size());
      const size_t n = chunk->size();
      for (size_t r = 0; r < n && !err; ++r) {
        for (size_t c = 0; c < visible.size(); ++c)
          StoreFlatCell(vf[c], chunk->data[c], r);
        if (qr->send_data(thd, out_items)) err = true;
        ++nrows;
      }
    }
  } catch (const std::exception &e) {
    RaiseDuckDBError(e.what());
    return true;
  } catch (...) {
    RaiseDuckDBError("unexpected DuckDB exception during result streaming");
    return true;
  }
  if (err) return true;

  if (PdTiming()) {
    const auto te3 = PdClock::now();
    fprintf(stderr,
            "[pd] build=%.2f prep=%.2f exec=%.2f stage=%.2f send=%.2f "
            "rows=%llu cols=%zu\n",
            plan->build_ms, plan->prep_ms, PdMs(te0, te1), PdMs(te1, te2),
            PdMs(te2, te3), (unsigned long long)nrows, visible.size());
    fprintf(stderr, "[pd-sql] %s\n", plan->sql.c_str());
    fflush(stderr);
  }

  join->send_records = nrows;
  g_pushdown_count.fetch_add(1, std::memory_order_relaxed);
  return false;
}

}  // namespace

unsigned long long PushdownCount() {
  return g_pushdown_count.load(std::memory_order_relaxed);
}

void ReleasePushdownPlan(const THD *thd) {
  // Drop the plan (if any) for this THD; the returned unique_ptr's destructor
  // releases the DuckDB connection + prepared statement. Idempotent.
  PlanRegistry::Get().Take(thd);
}

bool PushdownSelect(THD *thd, JOIN *join) {
  if (join == nullptr || join->query_block == nullptr) return false;
  // Drop any stale plan this THD's previous optimize may have left (e.g. a query
  // that optimized but never executed). Take() releases it — and its DuckDB
  // connection — via the returned unique_ptr destructor.
  PlanRegistry::Get().Take(thd);

  const auto t0 = PdClock::now();
  std::string db, sql;
  duckdb::vector<duckdb::Value> params;
  // Structured AST→SQL builder: parameterized literals, collations mapped.
  // Declines (returns false) on any unsupported shape → normal MySQL execution.
  if (!BuildPushdownSQLBuilder(thd, join, &db, &sql, &params)) {
    if (PdTiming()) {
      fprintf(stderr, "[pd-decline] BuildPushdownSQL returned false\n");
      fflush(stderr);
    }
    return false;  // not a candidate — normal execution
  }
  if (PdTiming()) {
    fprintf(stderr, "[pd-gen] db=%s sql=%s\n", db.c_str(), sql.c_str());
    fflush(stderr);
  }
  const auto t1 = PdClock::now();

  // Parse+bind ONCE against DuckDB and keep the prepared statement (and its
  // connection) for ExecutePushdown to execute directly. Any failure → decline
  // and let MySQL execute normally (zero correctness risk). The plan (and thus
  // the connection) is owned by the registry until execute or release, so an
  // optimize that never executes cannot leak it.
  try {
    auto plan = std::make_unique<PushdownPlan>();
    plan->conn = EngineContext::Get().Connection(db);
    auto prep = plan->conn->Prepare(sql);
    if (prep == nullptr || prep->HasError()) {
      if (PdTiming()) {
        fprintf(stderr, "[pd-prepare-fail] %s\n",
                prep ? prep->GetError().c_str() : "null prepared statement");
        fflush(stderr);
      }
      return false;  // plan freed here
    }
    plan->build_ms = PdMs(t0, t1);
    plan->prep_ms = PdMs(t1, PdClock::now());
    if (PdTiming()) plan->sql = sql;
    plan->db = std::move(db);
    plan->params = std::move(params);
    plan->prep = std::move(prep);
    PlanRegistry::Get().Put(thd, std::move(plan));
  } catch (const std::exception &) {
    return false;  // any partially-built plan is freed by its unique_ptr
  }

  join->override_executor_func = &ExecutePushdown;
  return false;
}

}  // namespace ducksdb_mysql
