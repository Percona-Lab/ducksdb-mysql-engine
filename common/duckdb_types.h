// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include "duckdb.hpp"
#include "sql/field.h"

namespace ducksdb_mysql {

// ---------------------------------------------------------------------------
// Temporal invariant
// ---------------------------------------------------------------------------
// MySQL and DuckDB disagree on what a TIMESTAMP *is*:
//
//   * MySQL TIMESTAMP is UTC-stored: the on-disk value is an absolute instant
//     (Unix epoch seconds). On read/write it is converted to/from the session
//     `time_zone`. So `Field::val_str()` renders a TIMESTAMP in the *session*
//     time zone — two sessions with different `time_zone` see different wall
//     clocks for the same stored instant.
//   * MySQL DATETIME is tz-naive: it stores the wall-clock value verbatim with
//     no zone, and `val_str()` is therefore session-independent.
//   * DuckDB TIMESTAMP is tz-naive (a wall clock, no zone).
//
// The bridge MUST preserve the *instant* for TIMESTAMP regardless of which
// session writes it and which session reads it back. Round-tripping a TIMESTAMP
// through `val_str()` in the session tz makes the DuckDB value session-tz
// dependent — a value written under '+00:00' and read under '+09:00' shifts by
// 9 hours (cross-session corruption).
//
// INVARIANT: TIMESTAMP / TIMESTAMP2 are stored in DuckDB as the UTC wall clock.
//   * write: `Field_timestamp::get_timestamp()` yields the UTC instant as epoch
//     micros (tz-independent by contract); we build a DuckDB TIMESTAMP from
//     those micros via `Timestamp::FromEpochMicroSeconds`.
//   * read:  `Timestamp::GetEpochMicroSeconds` on the DuckDB value yields the
//     UTC instant; `Field::store_timestamp(my_timeval)` writes it back (also
//     tz-independent by contract).
//   We deliberately keep the DuckDB column type as plain TIMESTAMP (not
//   TIMESTAMP_TZ): the stored wall clock is *defined* to be UTC, which is
//   stable across sessions and avoids a hard dependency on DuckDB's ICU
//   extension. Analytical pushdown that compares two TIMESTAMP columns stays
//   consistent because both are in the same (UTC) frame.
//
// DATETIME / DATETIME2 (tz-naive both sides) stay on the existing canonical
// `val_str()` path — there is no instant to preserve, only the wall clock, and
// that round-trips faithfully. DATE and TIME are likewise tz-naive and unchanged.

// One-shot conversion: MySQL Field declaration → DuckDB column type.
// Returns LogicalType::INVALID for unsupported MySQL types.
duckdb::LogicalType MySQLToDuckDB(const Field *f);

// Read a single row value from MySQL `field` and append it to `appender`.
// Returns 0 on success, HA_ERR_* on failure.
int AppendField(duckdb::Appender &appender, const Field *field);

// Convert MySQL `field`'s current value to a DuckDB Value (typed to the mapped
// column type) for binding into a prepared statement. NULL fields become an
// untyped NULL Value (cast on bind).
duckdb::Value FieldToValue(const Field *field);

// Read a Value from `chunk[col_idx][row_idx]` and write into MySQL `field`.
int StoreField(Field *field, const duckdb::Value &value);

// Vectorized fast path: read row `row` of a *flattened* chunk column `vec`
// directly from its data array (no per-cell duckdb::Value allocation) and store
// into MySQL `field`. Temporals and hugeint DECIMAL fall back to StoreField.
// The chunk must have been Flatten()'d first.
int StoreFlatCell(Field *field, duckdb::Vector &vec, size_t row);

}  // namespace ducksdb_mysql
