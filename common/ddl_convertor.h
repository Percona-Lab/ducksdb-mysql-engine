// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <string>
#include "sql/handler.h"

class TABLE;
struct HA_CREATE_INFO;

namespace ducksdb_mysql {

// Build the DuckDB `CREATE TABLE …` SQL from a MySQL table definition.
// Returns the SQL string. Throws std::runtime_error on unsupported features.
std::string BuildCreateTableSQL(const std::string &schema, const std::string &table,
                                const TABLE *form, const HA_CREATE_INFO *create_info);

// Build the DuckDB `DROP TABLE …` SQL.
std::string BuildDropTableSQL(const std::string &schema, const std::string &table);

// Build the DuckDB `ALTER TABLE … RENAME TO …` SQL (same schema).
std::string BuildRenameTableSQL(const std::string &schema, const std::string &from_table,
                                const std::string &to_table);

// Drop a database (closes instance, deletes file). Returns 0 on success.
int DropSchema(const std::string &schema);

}  // namespace ducksdb_mysql
