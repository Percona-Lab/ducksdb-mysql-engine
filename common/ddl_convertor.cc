// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "ddl_convertor.h"

#include <sstream>
#include <stdexcept>
#include "duckdb_engine_context.h"
#include "duckdb_sql_util.h"
#include "duckdb_types.h"
#include "sql/field.h"
#include "sql/table.h"

namespace ducksdb_mysql {

static std::string DuckDBTypeToSQL(const duckdb::LogicalType &t) {
    return t.ToString();
}

std::string BuildCreateTableSQL(const std::string & /*schema*/, const std::string &table,
                                const TABLE *form, const HA_CREATE_INFO * /*ci*/) {
    std::ostringstream sql;
    sql << "CREATE TABLE " << QuoteIdent(table) << " (";

    bool first = true;
    for (uint i = 0; i < form->s->fields; ++i) {
        Field *f = form->field[i];
        auto dt = MySQLToDuckDB(f);
        if (dt.id() == duckdb::LogicalTypeId::INVALID) {
            throw std::runtime_error(std::string("unsupported MySQL type for column ") +
                                     f->field_name);
        }
        if (!first) sql << ", ";
        first = false;
        sql << QuoteIdent(f->field_name) << " " << DuckDBTypeToSQL(dt);
        if (!f->is_nullable()) sql << " NOT NULL";
    }

    // PRIMARY KEY
    if (form->s->primary_key != MAX_KEY) {
        const KEY &pk = form->key_info[form->s->primary_key];
        sql << ", PRIMARY KEY (";
        for (uint i = 0; i < pk.user_defined_key_parts; ++i) {
            if (i) sql << ", ";
            sql << QuoteIdent(pk.key_part[i].field->field_name);
        }
        sql << ")";
    }

    sql << ")";
    return sql.str();
}

std::string BuildDropTableSQL(const std::string & /*schema*/, const std::string &table) {
    return "DROP TABLE " + QuoteIdent(table);
}

std::string BuildRenameTableSQL(const std::string & /*schema*/, const std::string &from_table,
                                const std::string &to_table) {
    return "ALTER TABLE " + QuoteIdent(from_table) + " RENAME TO " + QuoteIdent(to_table);
}

int DropSchema(const std::string &schema) {
    return EngineContext::Get().Drop(schema);
}

}  // namespace ducksdb_mysql
