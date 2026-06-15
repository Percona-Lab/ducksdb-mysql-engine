// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "duckdb_sql_util.h"

#include "sql/field.h"

namespace ducksdb_mysql {

std::string QuoteIdent(const std::string &s) {
    std::string out = "\"";
    for (char c : s) {
        if (c == '"') out += "\"\"";
        else out += c;
    }
    out += "\"";
    return out;
}

// True for binary string columns (BLOB/BINARY/VARBINARY) — these need byte-exact
// literals, unlike TEXT/CHAR which carry a real character set.
static bool IsBinaryStringField(const Field *f) {
    switch (f->real_type()) {
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB:
        case MYSQL_TYPE_STRING:
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_VAR_STRING:
            return f->charset() == &my_charset_bin;
        default:
            return false;
    }
}

// TODO: parameterize index WHERE. FieldLiteral is not used by the DML
// write path (UPDATE/DELETE bind parameters); it survives only for the index
// WHERE construction in ha_duckdb.cc and should be replaced by bound parameters
// when that path is parameterized.
std::string FieldLiteral(const Field *f) {
    if (f->is_null()) return "NULL";
    String buf;
    const_cast<Field *>(f)->val_str(&buf);
    const unsigned char *p =
        reinterpret_cast<const unsigned char *>(buf.ptr() ? buf.ptr() : "");
    const size_t n = buf.length();

    if (IsBinaryStringField(f)) {
        static const char *kHex = "0123456789ABCDEF";
        std::string out = "unhex('";
        for (size_t i = 0; i < n; ++i) {
            out += kHex[p[i] >> 4];
            out += kHex[p[i] & 0x0F];
        }
        out += "')";
        return out;
    }

    std::string out;
    out.reserve(n + 2);
    out += "'";
    for (size_t i = 0; i < n; ++i) {
        char c = static_cast<char>(p[i]);
        if (c == '\'') out += "''";
        else out += c;
    }
    out += "'";
    return out;
}

}  // namespace ducksdb_mysql
