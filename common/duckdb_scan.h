// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <memory>
#include <string>
#include "duckdb.hpp"

namespace ducksdb_mysql {

// Sequential scan over a DuckDB table.
//   Init() — issue the SELECT, pull the first chunk
//   Next() — hand back the current row's (chunk, row); advance across chunks
class ScanCursor {
public:
    ScanCursor(duckdb::Connection &conn, const std::string &table);
    ~ScanCursor();

    // Issues `SELECT <select_list> FROM table [WHERE <where_sql>] [ORDER BY
    // <order_sql>]`. select_list is the projected column list built by the
    // handler (or "*"); empty where = full scan.
    int Init(const std::string &select_list = "*", const std::string &where_sql = "",
             const std::string &order_sql = "");
    // Writes the current row's chunk + offset through the out-params.
    // Returns 0 on success, HA_ERR_END_OF_FILE at EOF, HA_ERR_GENERIC on error.
    int Next(duckdb::DataChunk **chunk_out, size_t *row_out);

private:
    duckdb::Connection &conn_;
    std::string table_;
    std::unique_ptr<duckdb::QueryResult> result_;
    std::unique_ptr<duckdb::DataChunk> chunk_;
    size_t row_in_chunk_ = 0;
};

}  // namespace ducksdb_mysql
