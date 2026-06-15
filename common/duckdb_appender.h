// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <string>
#include "duckdb.hpp"

class TABLE;

namespace ducksdb_mysql {

// Owns a long-lived duckdb::Appender for the duration of a MySQL bulk insert
// (LOAD DATA, multi-row INSERT). Created at start_bulk_insert, flushed and
// destroyed at end_bulk_insert.
class BulkAppender {
public:
    BulkAppender(duckdb::Connection &conn, const std::string &table);
    ~BulkAppender();

    int AppendRow(TABLE *form);
    int Flush();

private:
    duckdb::Appender appender_;
};

}  // namespace ducksdb_mysql
