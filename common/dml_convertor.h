// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <string>
#include <vector>
#include "duckdb.hpp"
#include "my_inttypes.h"  // uchar

class TABLE;

namespace ducksdb_mysql {

// Map a DuckDB error message to a MySQL handler error code (HA_ERR_FOUND_DUPP_KEY
// for constraint violations, else HA_ERR_GENERIC).
int MapDuckDBError(const std::string &msg);

// Insert a single row using DuckDB's Appender (the fast path even for one-off
// INSERTs in v1). Reads column values from the field pointers in record[0].
int InsertRow(duckdb::Connection &conn, const std::string &schema,
              const std::string &table, TABLE *form, const uchar *row_buf);

// Update/delete a single row keyed on the primary key. Both are implemented
// INTERNALLY on the prepared-statement path (parameters only — no value literals
// are ever concatenated into SQL); they prepare, bind, and execute in one call
// and surface DuckDB errors via MapDuckDBError. Without a primary key there is no
// unique row locator, so both return HA_ERR_WRONG_COMMAND. Signatures are kept
// unchanged so existing call sites need no edits. Return 0 on success.
int UpdateRowOnPK(duckdb::Connection &conn, const std::string &table,
                  TABLE *form, const uchar *old_buf, const uchar *new_buf);
int DeleteRowOnPK(duckdb::Connection &conn, const std::string &table,
                  TABLE *form, const uchar *row_buf);

// Prepared-statement path (parse/plan once, bind+execute per row). The SQL uses
// positional `$1…` placeholders; the Bind* helpers fill a Value vector in the
// matching order. UPDATE sets every column ($1..$N) then matches the PK
// ($N+1..); DELETE matches the PK. Require a primary key.
std::string BuildPreparedUpdateSQL(const std::string &table, TABLE *form);
std::string BuildPreparedDeleteSQL(const std::string &table, TABLE *form);
void BindUpdateParams(TABLE *form, const uchar *old_buf,
                      duckdb::vector<duckdb::Value> &out);
void BindDeleteParams(TABLE *form, const uchar *row_buf,
                      duckdb::vector<duckdb::Value> &out);

}  // namespace ducksdb_mysql
