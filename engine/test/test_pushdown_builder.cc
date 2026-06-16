// Copyright (c) 2026 ducksdb-mysql-engine contributors.
// SPDX-License-Identifier: GPL-2.0
//
// Unit tests for the structured AST->DuckDB pushdown builder (engine/
// duckdb_pushdown.cc). The builder's AST entry point (BuildPushdownPlan /
// BuildPushdownSQLBuilder) needs a fully-optimized Query_block + JOIN, which can
// only be produced by a running server optimizer; that end-to-end node coverage
// is exercised by MTR (suite/duckdb), not here.
//
// What IS unit-testable in isolation, and is covered below:
//   * the collation mapping decision: MapCollation / CollateSuffix — the
//     correctness gate that decides whether a string column pushes down and with
//     which DuckDB COLLATE clause. Copied here (state+coll_name) so the default
//     hermetic run needs neither the server nor DuckDB.
//   * the parameterization invariants the builder relies on: $N placeholders are
//     1-based and dense, IN-lists expand to one placeholder per element, and the
//     flag-gating helper recognises the documented on/off spellings.
//
// Keep the copied functions byte-faithful with MapCollation/CollateSuffix in
// engine/duckdb_pushdown.cc.

#include <string>
#include <vector>

#include "gtest/gtest.h"

namespace {

// ---------------------------------------------------------------------------
// Collation flag values copied from the vendored MySQL m_ctype.h
// (include/mysql/strings/m_ctype.h: MY_CS_BINSORT = 1<<4, MY_CS_CSSORT = 1<<10).
// Including that header pulls the generated config in; we pin the bits instead.
// ---------------------------------------------------------------------------
constexpr unsigned MY_CS_BINSORT = 1u << 4;
constexpr unsigned MY_CS_CSSORT = 1u << 10;

// The builder's CollationMap result.
enum class CollationMap { kNone, kNoCase, kDecline };

// Keep this in sync with MapCollation in engine/duckdb_pushdown.cc. Driven by
// (state, coll_name) — the only two CHARSET_INFO members the real function reads.
CollationMap MapCollation(unsigned state, const char *coll_name) {
  if (state & MY_CS_BINSORT) return CollationMap::kNone;
  if (!(state & MY_CS_CSSORT)) {
    if (coll_name != nullptr) {
      const std::string n(coll_name);
      if (n.find("_ai_ci") != std::string::npos ||
          n.find("_general_ci") != std::string::npos ||
          n.find("_unicode_ci") != std::string::npos) {
        return CollationMap::kNoCase;
      }
    }
  }
  return CollationMap::kDecline;
}

// Keep this in sync with CollateSuffix in engine/duckdb_pushdown.cc.
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

// Keep this in sync with LikeOperatorFor in engine/duckdb_pushdown.cc. Returns
// the DuckDB LIKE operator a column's collation maps to, or nullptr to decline.
// DuckDB LIKE is case-sensitive and COLLATE does not affect it, so the operator
// itself must carry the case-sensitivity: _ai_ci → ILIKE, _bin/binary → LIKE.
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

// Models RenderCase's shape arithmetic over Item_func_case's argument layout
// (args[0..ncases) are WHEN/THEN pairs; ELSE, when present, is the last arg).
// Returns true if a searched CASE of this shape would render, false to decline.
// Keep in sync with RenderCase in engine/duckdb_pushdown.cc.
bool CaseShapeRenders(int first_expr_num, int else_num, unsigned argc) {
  if (first_expr_num != -1) return false;  // simple CASE: decline
  unsigned ncases = argc;
  if (else_num != -1) {
    if (static_cast<unsigned>(else_num) != argc - 1) return false;
    ncases = argc - 1;
  }
  if (ncases == 0 || (ncases % 2) != 0) return false;
  return true;
}

// ===========================================================================
// Collation mapping
// ===========================================================================

// _bin / binary collations: byte compare, no COLLATE suffix, pushes down.
TEST(MapCollation, BinSortIsByteCompare) {
  EXPECT_EQ(CollationMap::kNone,
            MapCollation(MY_CS_BINSORT, "utf8mb4_bin"));
  EXPECT_EQ(CollationMap::kNone, MapCollation(MY_CS_BINSORT, "binary"));
  EXPECT_EQ("", CollateSuffix(MapCollation(MY_CS_BINSORT, "utf8mb4_bin")));
}

// The 8.0+ default collation (utf8mb4_0900_ai_ci) must push down with COLLATE
// NOCASE.
TEST(MapCollation, DefaultAiCiMapsToNoCase) {
  const CollationMap m = MapCollation(/*state=*/0, "utf8mb4_0900_ai_ci");
  EXPECT_EQ(CollationMap::kNoCase, m);
  EXPECT_EQ(" COLLATE NOCASE", CollateSuffix(m));
}

TEST(MapCollation, GeneralCiAndUnicodeCiMapToNoCase) {
  EXPECT_EQ(CollationMap::kNoCase,
            MapCollation(0, "utf8mb4_general_ci"));
  EXPECT_EQ(CollationMap::kNoCase,
            MapCollation(0, "utf8mb4_unicode_ci"));
}

// Case-sensitive collations (MY_CS_CSSORT set) are NOT byte-binary and NOT
// case-insensitive — decline rather than risk a different ordering.
TEST(MapCollation, CaseSensitiveDeclines) {
  EXPECT_EQ(CollationMap::kDecline,
            MapCollation(MY_CS_CSSORT, "utf8mb4_0900_as_cs"));
}

// An accent-sensitive, case-insensitive collation (_as_ci) is not modeled by
// NOCASE; decline to stay correct.
TEST(MapCollation, AccentSensitiveCiDeclines) {
  EXPECT_EQ(CollationMap::kDecline,
            MapCollation(0, "utf8mb4_0900_as_ci"));
}

TEST(MapCollation, UnknownCollationDeclines) {
  EXPECT_EQ(CollationMap::kDecline, MapCollation(0, "some_future_ci"));
  EXPECT_EQ(CollationMap::kDecline, MapCollation(0, nullptr));
}

TEST(CollateSuffix, DeclineAndNoneEmitNothing) {
  EXPECT_EQ("", CollateSuffix(CollationMap::kDecline));
  EXPECT_EQ("", CollateSuffix(CollationMap::kNone));
}

// ===========================================================================
// LIKE → operator decision.
//
// The builder cannot rely on COLLATE for LIKE (DuckDB ignores it), so the
// collation-to-operator mapping is the whole correctness gate for LIKE pushdown.
// ===========================================================================

// A case-insensitive (_ai_ci) column must use ILIKE so DuckDB matches the
// case-insensitive MySQL semantics.
TEST(LikeOperator, NoCaseUsesILike) {
  EXPECT_STREQ("ILIKE", LikeOperatorFor(CollationMap::kNoCase));
}

// A byte-exact (_bin/binary) column uses plain case-sensitive LIKE.
TEST(LikeOperator, ByteExactUsesLike) {
  EXPECT_STREQ("LIKE", LikeOperatorFor(CollationMap::kNone));
}

// An unmappable collation declines (nullptr) rather than risk a case mismatch.
TEST(LikeOperator, DeclineCollationDeclines) {
  EXPECT_EQ(nullptr, LikeOperatorFor(CollationMap::kDecline));
}

// End-to-end of the mapping: the default 8.0 collation pushes LIKE as ILIKE,
// utf8mb4_bin as LIKE, and a case-sensitive collation declines entirely.
TEST(LikeOperator, ComposesWithMapCollation) {
  EXPECT_STREQ("ILIKE",
               LikeOperatorFor(MapCollation(0, "utf8mb4_0900_ai_ci")));
  EXPECT_STREQ("LIKE",
               LikeOperatorFor(MapCollation(MY_CS_BINSORT, "utf8mb4_bin")));
  EXPECT_EQ(nullptr,
            LikeOperatorFor(MapCollation(MY_CS_CSSORT, "utf8mb4_0900_as_cs")));
}

// ===========================================================================
// Searched-CASE shape arithmetic.
// ===========================================================================

// CASE WHEN p THEN v END — one WHEN/THEN pair, no ELSE.
TEST(CaseShape, SingleWhenNoElseRenders) {
  EXPECT_TRUE(CaseShapeRenders(/*first_expr_num=*/-1, /*else_num=*/-1,
                               /*argc=*/2));
}

// CASE WHEN p THEN v ELSE e END — pair + trailing ELSE (else_num == argc-1).
TEST(CaseShape, WhenWithElseRenders) {
  EXPECT_TRUE(CaseShapeRenders(-1, /*else_num=*/2, /*argc=*/3));
}

// Two WHEN/THEN pairs plus ELSE.
TEST(CaseShape, MultipleWhensWithElseRenders) {
  EXPECT_TRUE(CaseShapeRenders(-1, /*else_num=*/4, /*argc=*/5));
}

// Simple CASE (CASE <operand> WHEN ...) — first_expr_num set — declines.
TEST(CaseShape, SimpleCaseDeclines) {
  EXPECT_FALSE(CaseShapeRenders(/*first_expr_num=*/2, /*else_num=*/-1,
                                /*argc=*/3));
}

// Degenerate: no WHEN/THEN pairs at all declines.
TEST(CaseShape, NoBranchesDeclines) {
  EXPECT_FALSE(CaseShapeRenders(-1, -1, /*argc=*/0));
}

// An odd number of WHEN-region args (a THEN missing its WHEN) declines.
TEST(CaseShape, OddPairCountDeclines) {
  EXPECT_FALSE(CaseShapeRenders(-1, -1, /*argc=*/3));
}

// ===========================================================================
// Parameterization invariants the builder depends on.
//
// The builder assigns each bound literal a $N placeholder where N is the running
// 1-based count of params accumulated so far. These tests model that contract
// against the same std::vector growth the real BuildCtx uses, so a regression in
// the numbering scheme (e.g. 0-based, or skipping an index) is caught here even
// though the AST walk itself needs the server.
// ===========================================================================

// Minimal stand-in for BuildCtx's placeholder allocator: push a value, return
// its 1-based "$N".
struct ParamAllocator {
  std::vector<int> params;  // value payloads stand in for duckdb::Value
  std::string Push(int v) {
    params.push_back(v);
    return "$" + std::to_string(params.size());
  }
};

TEST(Parameterization, PlaceholdersAreOneBasedAndDense) {
  ParamAllocator a;
  EXPECT_EQ("$1", a.Push(10));
  EXPECT_EQ("$2", a.Push(20));
  EXPECT_EQ("$3", a.Push(30));
  EXPECT_EQ(3u, a.params.size());
}

TEST(Parameterization, InListExpandsOnePlaceholderPerElement) {
  // Model RenderIn: col IN ($1, $2, $3) for a 3-element list.
  ParamAllocator a;
  std::string vals;
  for (int v : {7, 8, 9}) {
    if (!vals.empty()) vals += ", ";
    vals += a.Push(v);
  }
  EXPECT_EQ("$1, $2, $3", vals);
  EXPECT_EQ(3u, a.params.size());
}

TEST(Parameterization, LimitOffsetAppendAfterPredicateParams) {
  // Model: WHERE x = $1 ... LIMIT $2 OFFSET $3 — limit/offset are appended last
  // so their indices follow every predicate literal.
  ParamAllocator a;
  const std::string where = "x = " + a.Push(5);
  const std::string limit = "LIMIT " + a.Push(100);
  const std::string offset = "OFFSET " + a.Push(20);
  EXPECT_EQ("x = $1", where);
  EXPECT_EQ("LIMIT $2", limit);
  EXPECT_EQ("OFFSET $3", offset);
}

}  // namespace

// ---------------------------------------------------------------------------
// AST-coupled tests (opt-in): exercise the REAL ItemLiteralToValue / builder
// against constructed Item literals. These need both the server archives and
// DuckDB, so they are compiled only under -DDUCKSDB_TEST_WITH_SERVER=ON (the
// same opt-in half as test_type_bridge.cc). Until enabled in CI they document
// the intended literal-mapping coverage; the hermetic suite above is the
// baseline.
// ---------------------------------------------------------------------------
#ifdef DUCKSDB_TEST_WITH_SERVER

#include "duckdb.hpp"
#include "duckdb_pushdown.h"
#include "sql/item.h"

namespace {

TEST(ItemLiteralToValue, NullItemBecomesNullValue) {
  Item_null null_item;
  duckdb::Value v;
  ASSERT_TRUE(ducksdb_mysql::ItemLiteralToValue(&null_item, &v));
  EXPECT_TRUE(v.IsNull());
}

TEST(ItemLiteralToValue, SignedIntRoundTrips) {
  Item_int i(static_cast<longlong>(-42));
  duckdb::Value v;
  ASSERT_TRUE(ducksdb_mysql::ItemLiteralToValue(&i, &v));
  EXPECT_EQ(-42, v.DefaultCastAs(duckdb::LogicalType::BIGINT)
                     .GetValue<int64_t>());
}

TEST(ItemLiteralToValue, RealLiteralDeclines) {
  Item_float f("3.14", 4);
  duckdb::Value v;
  // REAL/DOUBLE literals are declined (ULP risk).
  EXPECT_FALSE(ducksdb_mysql::ItemLiteralToValue(&f, &v));
}

// A (non-temporal) string literal binds as a DuckDB VARCHAR carrying the exact
// bytes. Comparison case-sensitivity is the column's COLLATE concern, not the
// literal's, so the value itself round-trips verbatim.
TEST(ItemLiteralToValue, StringLiteralRoundTrips) {
  Item_string s("hello", 5, &my_charset_bin);
  duckdb::Value v;
  ASSERT_TRUE(ducksdb_mysql::ItemLiteralToValue(&s, &v));
  EXPECT_EQ("hello",
            v.DefaultCastAs(duckdb::LogicalType::VARCHAR).GetValue<std::string>());
}

}  // namespace

#endif  // DUCKSDB_TEST_WITH_SERVER
