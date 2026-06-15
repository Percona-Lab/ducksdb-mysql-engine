// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "dml_convertor.h"

#include <sstream>
#include "duckdb_sql_util.h"
#include "duckdb_types.h"
#include "my_sys.h"        // my_error
#include "mysqld_error.h"  // ER_GET_ERRMSG
#include "sql/field.h"
#include "sql/handler.h"
#include "sql/table.h"

namespace ducksdb_mysql {

// Map a DuckDB exception/error message to a MySQL handler error code so the
// server can report ER_DUP_ENTRY etc. instead of a generic engine error.
int MapDuckDBError(const std::string &msg) {
    if (msg.find("primary key") != std::string::npos ||
        msg.find("PRIMARY KEY") != std::string::npos ||
        msg.find("Duplicate") != std::string::npos ||
        msg.find("duplicate") != std::string::npos ||
        msg.find("unique constraint") != std::string::npos ||
        msg.find("Unique constraint") != std::string::npos) {
        return HA_ERR_FOUND_DUPP_KEY;
    }
    return HA_ERR_GENERIC;
}

// Map a DuckDB error and, when it has no dedicated MySQL representation
// (HA_ERR_GENERIC), push the real message to the client via ER_GET_ERRMSG so it
// is not swallowed — matching the DDL paths in ha_duckdb.cc. For mapped
// codes (e.g. HA_ERR_FOUND_DUPP_KEY) the handler layer formats its own message
// (ER_DUP_ENTRY), so we do NOT also queue ER_GET_ERRMSG to avoid double-report.
static int ReportDuckDBError(const std::string &msg) {
    int code = MapDuckDBError(msg);
    if (code == HA_ERR_GENERIC)
        my_error(ER_GET_ERRMSG, MYF(0), 0, msg.c_str(), "DuckDB");
    return code;
}

int InsertRow(duckdb::Connection &conn, const std::string & /*schema*/,
              const std::string &table, TABLE *form, const uchar * /*row_buf*/) {
    // MySQL has populated record[0]; the Field* pointers read from it.
    try {
        duckdb::Appender appender(conn, table);
        appender.BeginRow();
        for (uint i = 0; i < form->s->fields; ++i) {
            int rc = AppendField(appender, form->field[i]);
            if (rc) {
                appender.Close();
                return rc;
            }
        }
        appender.EndRow();
        appender.Close();
    } catch (const std::exception &e) {
        return ReportDuckDBError(e.what());
    }
    return 0;
}

// UpdateRowOnPK / DeleteRowOnPK keep their original signatures (so ha_duckdb.cc
// call sites need no edits) but are implemented INTERNALLY on the prepared-
// statement path — no SQL is ever built from value literals. Each call
// prepares the parameterized statement, binds the row's values, and executes;
// DuckDB caches plans, and the per-row prepare is the safe (injection-free)
// fallback used when the handler's cached PreparedStatement could not be built.
// A DuckDB error is surfaced through MapDuckDBError instead of HA_ERR_GENERIC.
// Without a primary key there is no unique row locator → HA_ERR_WRONG_COMMAND.

int UpdateRowOnPK(duckdb::Connection &conn, const std::string &table,
                  TABLE *form, const uchar *old_buf, const uchar * /*new_buf*/) {
    if (form->s->primary_key == MAX_KEY) return HA_ERR_WRONG_COMMAND;
    try {
        auto stmt = conn.Prepare(BuildPreparedUpdateSQL(table, form));
        if (!stmt || stmt->HasError())
            return ReportDuckDBError(stmt ? stmt->GetError() : std::string());
        duckdb::vector<duckdb::Value> params;
        BindUpdateParams(form, old_buf, params);
        auto r = stmt->Execute(params);
        if (!r) return HA_ERR_GENERIC;
        if (r->HasError()) return ReportDuckDBError(r->GetError());
    } catch (const std::exception &e) {
        return ReportDuckDBError(e.what());
    }
    return 0;
}

int DeleteRowOnPK(duckdb::Connection &conn, const std::string &table,
                  TABLE *form, const uchar *row_buf) {
    if (form->s->primary_key == MAX_KEY) return HA_ERR_WRONG_COMMAND;
    try {
        auto stmt = conn.Prepare(BuildPreparedDeleteSQL(table, form));
        if (!stmt || stmt->HasError())
            return ReportDuckDBError(stmt ? stmt->GetError() : std::string());
        duckdb::vector<duckdb::Value> params;
        BindDeleteParams(form, row_buf, params);
        auto r = stmt->Execute(params);
        if (!r) return HA_ERR_GENERIC;
        if (r->HasError()) return ReportDuckDBError(r->GetError());
    } catch (const std::exception &e) {
        return ReportDuckDBError(e.what());
    }
    return 0;
}

// --- Prepared-statement path -------------------------------------------------

std::string BuildPreparedDeleteSQL(const std::string &table, TABLE *form) {
    const KEY &pk = form->key_info[form->s->primary_key];
    std::ostringstream sql;
    sql << "DELETE FROM " << QuoteIdent(table) << " WHERE ";
    for (uint i = 0; i < pk.user_defined_key_parts; ++i) {
        if (i) sql << " AND ";
        sql << QuoteIdent(pk.key_part[i].field->field_name) << " = $" << (i + 1);
    }
    return sql.str();
}

std::string BuildPreparedUpdateSQL(const std::string &table, TABLE *form) {
    const KEY &pk = form->key_info[form->s->primary_key];
    std::ostringstream sql;
    sql << "UPDATE " << QuoteIdent(table) << " SET ";
    uint p = 0;
    for (uint i = 0; i < form->s->fields; ++i) {
        if (i) sql << ", ";
        sql << QuoteIdent(form->field[i]->field_name) << " = $" << (++p);
    }
    sql << " WHERE ";
    for (uint i = 0; i < pk.user_defined_key_parts; ++i) {
        if (i) sql << " AND ";
        sql << QuoteIdent(pk.key_part[i].field->field_name) << " = $" << (++p);
    }
    return sql.str();
}

// Append the PK column values read from `rec` (handling old/new record offset).
static void BindPK(TABLE *form, const uchar *rec, duckdb::vector<duckdb::Value> &out) {
    const KEY &pk = form->key_info[form->s->primary_key];
    const ptrdiff_t off = (rec ? rec : form->record[0]) - form->record[0];
    for (uint i = 0; i < pk.user_defined_key_parts; ++i) {
        Field *kf = pk.key_part[i].field;
        if (off) kf->move_field_offset(off);
        out.push_back(FieldToValue(kf));
        if (off) kf->move_field_offset(-off);
    }
}

void BindDeleteParams(TABLE *form, const uchar *row_buf,
                      duckdb::vector<duckdb::Value> &out) {
    BindPK(form, row_buf, out);
}

void BindUpdateParams(TABLE *form, const uchar *old_buf,
                      duckdb::vector<duckdb::Value> &out) {
    // SET: every column's new value (from record[0]); WHERE: PK from old record.
    for (uint i = 0; i < form->s->fields; ++i)
        out.push_back(FieldToValue(form->field[i]));
    BindPK(form, old_buf, out);
}

}  // namespace ducksdb_mysql
