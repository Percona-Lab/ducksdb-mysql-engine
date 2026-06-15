// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <string>

class Field;

namespace ducksdb_mysql {

// Quote a SQL identifier for DuckDB ("name", with interior " doubled).
std::string QuoteIdent(const std::string &s);

// Render a Field's current value as a DuckDB SQL literal:
//   - NULL              when the field is null
//   - unhex('..')       for binary string columns (BLOB/BINARY/VARBINARY),
//                       preserving every byte including NUL and high bytes
//   - '..'              for everything else, single quotes doubled
// TODO: parameterize index WHERE. Only the index-WHERE path in ha_duckdb.cc
// uses this; the DML write path binds parameters instead.
std::string FieldLiteral(const Field *f);

}  // namespace ducksdb_mysql
