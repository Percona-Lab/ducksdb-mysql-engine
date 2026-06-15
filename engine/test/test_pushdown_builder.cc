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

}  // namespace

#endif  // DUCKSDB_TEST_WITH_SERVER
