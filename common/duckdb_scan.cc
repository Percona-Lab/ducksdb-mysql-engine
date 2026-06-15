// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "duckdb_scan.h"

#include "dml_convertor.h"  // MapDuckDBError
#include "duckdb_sql_util.h"
#include "my_dbug.h"
#include "my_sys.h"         // my_error
#include "mysqld_error.h"   // ER_GET_ERRMSG
#include "sql/handler.h"    // HA_ERR_*

namespace ducksdb_mysql {

ScanCursor::ScanCursor(duckdb::Connection &conn, const std::string &table)
    : conn_(conn), table_(table) {}

ScanCursor::~ScanCursor() = default;

int ScanCursor::Init(const std::string &select_list, const std::string &where_sql,
                     const std::string &order_sql) {
    try {
        std::string sql =
            "SELECT " + (select_list.empty() ? std::string("*") : select_list) +
            " FROM " + QuoteIdent(table_);
        if (!where_sql.empty()) sql += " WHERE " + where_sql;
        if (!order_sql.empty()) sql += " ORDER BY " + order_sql;
        // Materialize (Query, not SendQuery): a streaming result would hold the
        // connection busy, so a full-scan UPDATE/DELETE that issues per-row SQL
        // on the same connection mid-scan would fail. Query() buffers all rows,
        // freeing the connection for those interleaved writes.
        result_ = conn_.Query(sql);
        if (result_->HasError()) {
            const std::string &msg = result_->GetError();
            DBUG_PRINT("error", ("ducksdb: scan init failed: %s", msg.c_str()));
            // Surface the real DuckDB message instead of a generic engine error.
            my_error(ER_GET_ERRMSG, MYF(0), 0, msg.c_str(), "DuckDB");
            return MapDuckDBError(msg);
        }
        chunk_ = result_->Fetch();
        // Flatten so the handler can read column vectors by direct row index
        // (FlatVector) instead of allocating a Value per cell. Cheap when the
        // materialized chunk's vectors are already flat.
        if (chunk_ && chunk_->size()) chunk_->Flatten();
        row_in_chunk_ = 0;
    } catch (const std::exception &e) {
        my_error(ER_GET_ERRMSG, MYF(0), 0, e.what(), "DuckDB");
        return MapDuckDBError(e.what());
    }
    return 0;
}

int ScanCursor::Next(duckdb::DataChunk **chunk_out, size_t *row_out) {
    try {
        if (!chunk_) return HA_ERR_END_OF_FILE;
        if (row_in_chunk_ >= chunk_->size()) {
            chunk_ = result_->Fetch();
            if (!chunk_ || chunk_->size() == 0) return HA_ERR_END_OF_FILE;
            chunk_->Flatten();
            row_in_chunk_ = 0;
        }
        *chunk_out = chunk_.get();
        *row_out = row_in_chunk_++;
    } catch (const std::exception &e) {
        my_error(ER_GET_ERRMSG, MYF(0), 0, e.what(), "DuckDB");
        return MapDuckDBError(e.what());
    }
    return 0;
}

}  // namespace ducksdb_mysql
