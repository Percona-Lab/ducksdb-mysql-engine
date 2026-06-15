// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "duckdb_appender.h"

#include "dml_convertor.h"  // MapDuckDBError
#include "duckdb_types.h"
#include "sql/handler.h"  // HA_ERR_*
#include "sql/table.h"

namespace ducksdb_mysql {

BulkAppender::BulkAppender(duckdb::Connection &conn, const std::string &table)
    : appender_(conn, table) {}

BulkAppender::~BulkAppender() {
    try {
        appender_.Close();
    } catch (...) {
    }
}

int BulkAppender::AppendRow(TABLE *form) {
    try {
        appender_.BeginRow();
        for (uint i = 0; i < form->s->fields; ++i) {
            int rc = AppendField(appender_, form->field[i]);
            if (rc) return rc;
        }
        appender_.EndRow();
    } catch (const std::exception &e) {
        return MapDuckDBError(e.what());
    }
    return 0;
}

int BulkAppender::Flush() {
    try {
        appender_.Flush();
    } catch (const std::exception &e) {
        return MapDuckDBError(e.what());
    }
    return 0;
}

}  // namespace ducksdb_mysql
