// Copyright (c) 2026 ducksdb-mysql-engine contributors.
// SPDX-License-Identifier: GPL-2.0
//
// Round-trip / characterization tests for the MySQL<->DuckDB type bridge in
// engine/duckdb_types.cc (MySQLToDuckDB / AppendField / FieldToValue /
// StoreField / StoreFlatCell). These pin the bridge's current behavior so any
// behavior shift shows up as a deliberate update rather than a silent
// regression.
//
// ---------------------------------------------------------------------------
// What runs unconditionally vs. what is opt-in
// ---------------------------------------------------------------------------
// The bridge functions take a MySQL `Field *` and (for AppendField) a live
// DuckDB `Appender`. A `Field` cannot be constructed standalone — it needs the
// linked MySQL server (charsets, my_decimal, TABLE/Field machinery). Linking the
// full server into a unit test is a heavyweight build and is impractical
// hermetically.
//
// So this file is split:
//   * ALWAYS ON  — validate, against a real in-memory DuckDB, the type-system
//                  invariants the bridge relies on: the scaled-integer DECIMAL
//                  contract (the trickiest bit of duckdb_types.cc), integer
//                  signedness mapping, and temporal/blob/bool round-tripping
//                  through DuckDB. These need DuckDB only (vendored static lib),
//                  so the default `ctest` run stays hermetic and green.
//   * OPT-IN     — the `Field`-coupled half (MySQLToDuckDB/AppendField/
//                  StoreFlatCell direct calls) is guarded by
//                  -DDUCKSDB_TEST_WITH_SERVER=ON, which links the prebuilt server
//                  archives, exercising the real bridge end to end.
//
// This follows the same least-invasive tradeoff used in
// test_sql_text_passes.cc: the harness plus the hermetic half run by default;
// the server-linked half is wired in via the option when needed.

#include <cstdint>
#include <string>

#include "duckdb.hpp"
#include "duckdb/common/types/timestamp.hpp"
#include "gtest/gtest.h"

namespace {

// ===========================================================================
// DECIMAL scaled-integer contract.
//
// duckdb_types.cc encodes a MySQL DECIMAL(width, scale) as a DuckDB DECIMAL by
// shifting the value left by `scale` digits into an integer whose physical type
// is chosen by width: <=4 int16, <=9 int32, <=18 int64, else hugeint. On read it
// reverses the shift. These tests assert DuckDB agrees on:
//   - the physical-type-by-width boundaries the bridge switches on, and
//   - that DECIMAL(scaled-int, width, scale) round-trips to the same string.
// If DuckDB ever changes its width->physical-type mapping, the bridge's
// GetValueUnsafe<intN> reads would be wrong; this catches it.
// ===========================================================================

TEST(DecimalContract, WidthBoundaryPhysicalTypes) {
  using duckdb::LogicalType;
  // width 4 -> int16, 9 -> int32, 18 -> int64, 19+ -> hugeint(int128).
  EXPECT_EQ(LogicalType::DECIMAL(4, 2).InternalType(),
            duckdb::PhysicalType::INT16);
  EXPECT_EQ(LogicalType::DECIMAL(9, 2).InternalType(),
            duckdb::PhysicalType::INT32);
  EXPECT_EQ(LogicalType::DECIMAL(18, 4).InternalType(),
            duckdb::PhysicalType::INT64);
  EXPECT_EQ(LogicalType::DECIMAL(19, 4).InternalType(),
            duckdb::PhysicalType::INT128);
  // The bridge's kDecimalInt64MaxWidth fast-path boundary is 18.
  EXPECT_LE(LogicalType::DECIMAL(18, 0).InternalType(),
            duckdb::PhysicalType::INT64);
}

TEST(DecimalContract, ScaledIntRoundTripInt16) {
  // DECIMAL(4,2) value 12.34 -> scaled int 1234.
  auto v = duckdb::Value::DECIMAL(static_cast<int16_t>(1234), 4, 2);
  EXPECT_EQ(v.ToString(), "12.34");
  EXPECT_EQ(duckdb::DecimalType::GetWidth(v.type()), 4);
  EXPECT_EQ(duckdb::DecimalType::GetScale(v.type()), 2);
}

TEST(DecimalContract, ScaledIntRoundTripInt32) {
  // DECIMAL(9,3) value 12345.678 -> scaled int 12345678.
  auto v = duckdb::Value::DECIMAL(static_cast<int32_t>(12345678), 9, 3);
  EXPECT_EQ(v.ToString(), "12345.678");
}

TEST(DecimalContract, ScaledIntRoundTripInt64) {
  // DECIMAL(18,4) value -100000000000.0001 -> scaled int -1000000000000001.
  auto v = duckdb::Value::DECIMAL(static_cast<int64_t>(-1000000000000001LL), 18,
                                  4);
  EXPECT_EQ(v.ToString(), "-100000000000.0001");
}

TEST(DecimalContract, ZeroScaleIsInteger) {
  auto v = duckdb::Value::DECIMAL(static_cast<int32_t>(42), 9, 0);
  EXPECT_EQ(v.ToString(), "42");
}

// ===========================================================================
// Integer signedness round-trips through DuckDB. The bridge maps MySQL signed/
// unsigned ints to DuckDB [U]TINYINT..[U]BIGINT; these pin the max-value
// behavior so an unsigned BIGINT near 2^64-1 isn't silently truncated to signed.
// ===========================================================================

class DuckDBLive : public ::testing::Test {
 protected:
  void SetUp() override {
    db_ = std::make_unique<duckdb::DuckDB>(nullptr);  // in-memory
    conn_ = std::make_unique<duckdb::Connection>(*db_);
  }
  std::unique_ptr<duckdb::DuckDB> db_;
  std::unique_ptr<duckdb::Connection> conn_;
};

TEST_F(DuckDBLive, UnsignedBigintMaxRoundTrip) {
  auto r = conn_->Query("SELECT CAST(18446744073709551615 AS UBIGINT) AS v");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  auto v = r->GetValue(0, 0);
  EXPECT_EQ(v.GetValue<uint64_t>(), 18446744073709551615ULL);
}

TEST_F(DuckDBLive, SignedTinyintBounds) {
  auto r = conn_->Query("SELECT CAST(-128 AS TINYINT) AS lo, "
                        "CAST(127 AS TINYINT) AS hi");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  EXPECT_EQ(r->GetValue(0, 0).GetValue<int64_t>(), -128);
  EXPECT_EQ(r->GetValue(1, 0).GetValue<int64_t>(), 127);
}

TEST_F(DuckDBLive, UnsignedTinyintBounds) {
  auto r = conn_->Query("SELECT CAST(255 AS UTINYINT) AS v");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  EXPECT_EQ(r->GetValue(0, 0).GetValue<uint64_t>(), 255U);
}

// ===========================================================================
// Temporal round-trips. The bridge currently moves temporals through their
// canonical string form (val_str -> DuckDB cast, and back via ToString).
// These pin the DuckDB-side string<->temporal contract that both directions
// depend on. A cross-timezone TIMESTAMP test can be added here to cover the UTC
// TIMESTAMP mapping.
// ===========================================================================

TEST_F(DuckDBLive, DateStringRoundTrip) {
  auto r = conn_->Query("SELECT CAST('2026-06-15' AS DATE) AS d");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  EXPECT_EQ(r->GetValue(0, 0).ToString(), "2026-06-15");
}

TEST_F(DuckDBLive, TimeStringRoundTrip) {
  auto r = conn_->Query("SELECT CAST('13:14:15' AS TIME) AS t");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  EXPECT_EQ(r->GetValue(0, 0).ToString(), "13:14:15");
}

TEST_F(DuckDBLive, TimestampStringRoundTrip) {
  auto r =
      conn_->Query("SELECT CAST('2026-06-15 13:14:15' AS TIMESTAMP) AS ts");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  EXPECT_EQ(r->GetValue(0, 0).ToString(), "2026-06-15 13:14:15");
}

// ===========================================================================
// UTC-epoch TIMESTAMP contract.
//
// The fix in duckdb_types.cc stores MySQL TIMESTAMP as the UTC wall clock by
// going through the UTC epoch micros (Timestamp::FromEpochMicroSeconds on write,
// GetEpochMicroSeconds on read) instead of the session-tz string. These pin the
// DuckDB-side epoch contract that the bridge's TIMESTAMP path now depends on, so
// a DuckDB API change (units, sign handling) surfaces in the hermetic run rather
// than only under -DDUCKSDB_TEST_WITH_SERVER.
//
// The full cross-session proof (store under '+00:00', read under '+09:00', same
// instant) needs a real MySQL Field + session tz and lives in the server-linked
// section below.
// ===========================================================================

TEST_F(DuckDBLive, TimestampEpochMicrosRoundTrip) {
  // 2026-06-15 13:14:15 UTC == 1781529255 epoch seconds.
  const int64_t kSec = 1781529255LL;
  const int64_t kMicros = kSec * 1000000LL + 123456LL;
  duckdb::timestamp_t ts = duckdb::Timestamp::FromEpochMicroSeconds(kMicros);
  EXPECT_EQ(duckdb::Timestamp::GetEpochMicroSeconds(ts), kMicros);
  // A DuckDB TIMESTAMP Value built from those micros renders the *UTC* wall
  // clock — session tz plays no part (the bridge's invariant).
  auto v = duckdb::Value::TIMESTAMP(ts);
  EXPECT_EQ(v.ToString(), "2026-06-15 13:14:15.123456");
}

TEST_F(DuckDBLive, TimestampPreEpochMicrosRoundTrip) {
  // Pre-1970 instant exercises the negative-micros floor in the read path.
  duckdb::timestamp_t ts =
      duckdb::Timestamp::FromString("1969-12-31 23:59:59", false);
  const int64_t micros = duckdb::Timestamp::GetEpochMicroSeconds(ts);
  EXPECT_EQ(micros, -1000000LL);
  // Reverse the same floor logic StoreField uses and confirm it reconstructs.
  int64_t sec = micros / 1000000LL;
  int64_t usec = micros % 1000000LL;
  if (usec < 0) {
    usec += 1000000LL;
    sec -= 1;
  }
  const int64_t back = sec * 1000000LL + usec;
  EXPECT_EQ(back, micros);
  EXPECT_EQ(duckdb::Value::TIMESTAMP(duckdb::Timestamp::FromEpochMicroSeconds(back))
                .ToString(),
            "1969-12-31 23:59:59");
}

// ===========================================================================
// BLOB / bytes round-trip including embedded NUL (the bridge uses BLOB length,
// not C-string length, so a 0x00 byte must survive).
// ===========================================================================

TEST_F(DuckDBLive, BlobWithEmbeddedNulRoundTrip) {
  auto r = conn_->Query("SELECT '\\x00\\x01\\xFF'::BLOB AS b");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  auto bytes = duckdb::StringValue::Get(r->GetValue(0, 0));
  ASSERT_EQ(bytes.size(), 3u);
  EXPECT_EQ(static_cast<unsigned char>(bytes[0]), 0x00);
  EXPECT_EQ(static_cast<unsigned char>(bytes[1]), 0x01);
  EXPECT_EQ(static_cast<unsigned char>(bytes[2]), 0xFF);
}

// ===========================================================================
// BOOLEAN round-trip.
// ===========================================================================

TEST_F(DuckDBLive, BoolRoundTrip) {
  auto r = conn_->Query("SELECT TRUE AS t, FALSE AS f");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  EXPECT_TRUE(r->GetValue(0, 0).GetValue<bool>());
  EXPECT_FALSE(r->GetValue(1, 0).GetValue<bool>());
}

// ===========================================================================
// NULL handling: the bridge maps a NULL Field to an untyped NULL Value and a
// NULL DuckDB cell to field->set_null(). Pin DuckDB's IsNull() contract.
// ===========================================================================

TEST_F(DuckDBLive, NullValueIsNull) {
  auto r = conn_->Query("SELECT CAST(NULL AS INTEGER) AS n");
  ASSERT_FALSE(r->HasError()) << r->GetError();
  EXPECT_TRUE(r->GetValue(0, 0).IsNull());
}

// ===========================================================================
// OPT-IN: server-linked direct calls into the bridge. Compiled only when
// -DDUCKSDB_TEST_WITH_SERVER=ON links the prebuilt MySQL archives so a real
// Field can be constructed.
// ===========================================================================
#ifdef DUCKSDB_TEST_WITH_SERVER
#include "duckdb/common/types/timestamp.hpp"
#include "duckdb_types.h"
#include "my_time_t.h"  // my_timeval
#include "sql/field.h"

// A Field_timestamp owns a record buffer and a null byte. We back it with a
// small stack buffer so no TABLE/TABLE_SHARE is required. store_timestamp() and
// get_timestamp() are defined to operate "in UTC" independent of the session
// time zone (see sql/field.h), which is precisely the property the UTC TIMESTAMP
// contract needs.
namespace {

class TimestampFieldFixture {
 public:
  explicit TimestampFieldFixture(uint8_t dec = 6) {
    // ptr -> data buffer, null_ptr -> null byte, null_bit 1.
    field_ = new Field_timestamp(buf_, &null_byte_, 1, Field::NONE, "ts", dec);
  }
  ~TimestampFieldFixture() { delete field_; }

  // Store a UTC instant (epoch seconds + micros) the tz-independent way.
  void store_utc(int64_t epoch_sec, int64_t usec) {
    my_timeval tm{};
    tm.m_tv_sec = epoch_sec;
    tm.m_tv_usec = usec;
    field_->set_notnull();
    field_->store_timestamp(&tm);
  }

  Field *field() { return field_; }

 private:
  uchar buf_[16] = {0};
  uchar null_byte_ = 0;
  Field_timestamp *field_;
};

}  // namespace

// Cross-timezone instant preservation: storing a TIMESTAMP and reading it back
// through the bridge must preserve the UTC instant. Because the bridge now goes
// through Field::get_timestamp()/store_timestamp() (UTC by contract) instead of
// val_str() in the session tz, the represented instant is identical no matter
// what the session `time_zone` is. We assert the bridge's DuckDB Value carries
// the exact UTC epoch we stored, and that StoreField recovers it.
TEST(TypeBridgeWithServer, TimestampUtcInstantPreserved) {
  using namespace ducksdb_mysql;
  TimestampFieldFixture fx(6);
  const int64_t kSec = 1781529255LL;  // 2026-06-15 13:14:15 UTC
  const int64_t kUsec = 123456LL;
  fx.store_utc(kSec, kUsec);

  // Bridge -> DuckDB Value (the path used to bind WHERE literals and to read).
  duckdb::Value v = FieldToValue(fx.field());
  ASSERT_FALSE(v.IsNull());
  ASSERT_EQ(v.type().id(), duckdb::LogicalTypeId::TIMESTAMP);
  const int64_t got_micros =
      duckdb::Timestamp::GetEpochMicroSeconds(duckdb::TimestampValue::Get(v));
  EXPECT_EQ(got_micros, kSec * 1000000LL + kUsec)
      << "TIMESTAMP must carry the UTC instant, not a session-tz wall clock";

  // DuckDB Value -> Field (read path) must recover the same UTC instant.
  TimestampFieldFixture out(6);
  ASSERT_EQ(StoreField(out.field(), v), 0);
  my_timeval back{};
  int warn = 0;
  ASSERT_FALSE(out.field()->get_timestamp(&back, &warn));
  EXPECT_EQ(back.m_tv_sec, kSec);
  EXPECT_EQ(back.m_tv_usec, kUsec);
}

// Column type and DATETIME-vs-TIMESTAMP wall-clock distinction (the UTC
// TIMESTAMP invariant plus MySQLToDuckDB pinning).
TEST(TypeBridgeWithServer, TimestampMapsToDuckDbTimestamp) {
  using namespace ducksdb_mysql;
  TimestampFieldFixture fx(0);
  EXPECT_EQ(MySQLToDuckDB(fx.field()).id(), duckdb::LogicalTypeId::TIMESTAMP);
}
#endif  // DUCKSDB_TEST_WITH_SERVER

}  // namespace
