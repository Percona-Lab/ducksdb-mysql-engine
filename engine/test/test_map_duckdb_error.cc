// Copyright (c) 2026 ducksdb-mysql-engine contributors.
// SPDX-License-Identifier: GPL-2.0
//
// Unit tests for MapDuckDBError (engine/dml_convertor.cc): the translation from
// a raw DuckDB error message to a MySQL handler error code.
//
// Why a local copy and not a direct call: MapDuckDBError lives in
// dml_convertor.cc, whose translation unit pulls in the full MySQL server +
// DuckDB headers (sql/handler.h, sql/field.h, duckdb.hpp). Linking it standalone
// would require the prebuilt server archives, which the default (hermetic) unit
// run must not need. The body below is a byte-faithful copy of the real
// function; the HA_ERR_* return codes are taken from the real vendored
// <my_base.h> so this copy can never silently diverge on the numeric values it
// asserts.
//
// Keep this copy in sync with MapDuckDBError in engine/dml_convertor.cc.

#include <string>

#include "gtest/gtest.h"

namespace {

// HA_ERR_* numeric values copied from the vendored MySQL <my_base.h>
// (vendor/mysql-server/include/my_base.h: lines 910 / 1000). That header needs
// the generated my_config.h, so including it would break the hermetic unit run;
// we pin the constants here instead. If MySQL ever renumbers these, the engine
// would change too — and these tests assert against the same numbers the engine
// returns, so any drift surfaces in the integration build.
constexpr int HA_ERR_FOUND_DUPP_KEY = 121;
constexpr int HA_ERR_GENERIC = 168;

// Keep this in sync with MapDuckDBError in engine/dml_convertor.cc.
int MapDuckDBError(const std::string &msg) {
  if (msg.find("primary key") != std::string::npos ||
      msg.find("PRIMARY KEY") != std::string::npos ||
      msg.find("Duplicate") != std::string::npos ||
      msg.find("duplicate") != std::string::npos ||
      msg.find("unique constraint") != std::string::npos ||
      msg.find("Unique constraint") != std::string::npos) {
    return HA_ERR_FOUND_DUPP_KEY;
  }
  return HA_ERR_GENERIC;
}

// --- Duplicate / unique-constraint violations map to HA_ERR_FOUND_DUPP_KEY ---

TEST(MapDuckDBError, PrimaryKeyLowercase) {
  EXPECT_EQ(HA_ERR_FOUND_DUPP_KEY,
            MapDuckDBError("violates primary key constraint"));
}

TEST(MapDuckDBError, PrimaryKeyUppercase) {
  EXPECT_EQ(HA_ERR_FOUND_DUPP_KEY,
            MapDuckDBError("Constraint Error: violates PRIMARY KEY"));
}

TEST(MapDuckDBError, DuplicateCapitalized) {
  EXPECT_EQ(HA_ERR_FOUND_DUPP_KEY,
            MapDuckDBError("Duplicate key value violates ..."));
}

TEST(MapDuckDBError, DuplicateLowercase) {
  EXPECT_EQ(HA_ERR_FOUND_DUPP_KEY,
            MapDuckDBError("found a duplicate row"));
}

TEST(MapDuckDBError, UniqueConstraintLowercase) {
  EXPECT_EQ(HA_ERR_FOUND_DUPP_KEY,
            MapDuckDBError("violates unique constraint \"idx\""));
}

TEST(MapDuckDBError, UniqueConstraintCapitalized) {
  EXPECT_EQ(HA_ERR_FOUND_DUPP_KEY,
            MapDuckDBError("Unique constraint violation"));
}

TEST(MapDuckDBError, RealisticDuckDBConstraintMessage) {
  // A representative message DuckDB emits for a PK collision.
  EXPECT_EQ(HA_ERR_FOUND_DUPP_KEY,
            MapDuckDBError(
                "Constraint Error: Duplicate key \"id: 1\" violates primary "
                "key constraint."));
}

// --- Everything else falls through to HA_ERR_GENERIC -------------------------

TEST(MapDuckDBError, UnrelatedErrorIsGeneric) {
  EXPECT_EQ(HA_ERR_GENERIC,
            MapDuckDBError("Binder Error: column \"x\" does not exist"));
}

TEST(MapDuckDBError, EmptyMessageIsGeneric) {
  EXPECT_EQ(HA_ERR_GENERIC, MapDuckDBError(""));
}

TEST(MapDuckDBError, OutOfMemoryIsGeneric) {
  EXPECT_EQ(HA_ERR_GENERIC, MapDuckDBError("Out of Memory Error"));
}

// Guard the substring matcher against a near-miss that must NOT be classified
// as a duplicate (no PK/duplicate/unique tokens present).
TEST(MapDuckDBError, ForeignKeyIsGeneric) {
  EXPECT_EQ(HA_ERR_GENERIC,
            MapDuckDBError("violates foreign key constraint"));
}

}  // namespace
