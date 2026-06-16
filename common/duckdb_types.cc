// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "duckdb_types.h"

#include "duckdb/common/types/timestamp.hpp"      // Timestamp::FromEpochMicroSeconds
#include "duckdb/common/vector/flat_vector.hpp"    // FlatVector (not in duckdb.hpp)
#include "my_dbug.h"
#include "my_time_t.h"                             // my_timeval
#include "sql-common/my_decimal.h"  // my_decimal, decimal_shift, *2decimal

namespace ducksdb_mysql {

// DuckDB stores DECIMAL as a scaled integer whose physical type is chosen by
// width: <=4 int16, <=9 int32, <=18 int64, else int128 (hugeint). We fast-path
// widths up to 18 with a typed scaled-integer round-trip (no string format/parse)
// and fall back to the string path for hugeint widths.
static constexpr uint kDecimalInt64MaxWidth = 18;

// MySQL TIMESTAMP/TIMESTAMP2 is UTC-stored; preserve the *instant* across
// sessions with different `time_zone` by going through the UTC epoch rather than
// the session-tz string. See the temporal invariant in duckdb_types.h.
//
// Only the UTC-stored TIMESTAMP types take the epoch path below; DATETIME, DATE
// and TIME are tz-naive and stay on the canonical val_str() path.
//
// Read the field's UTC instant as a DuckDB tz-naive TIMESTAMP holding the UTC
// wall clock. Field::get_timestamp() is defined to work in UTC independent of
// the session time zone. Returns true on success; false for the MySQL "zero"
// timestamp (get_timestamp reports no value), in which case *out is untouched.
static inline bool TimestampFieldToUtcValue(const Field *field, duckdb::Value *out) {
    my_timeval tm{};
    int warnings = 0;
    if (field->get_timestamp(&tm, &warnings)) return false;  // zero/NULL instant
    const int64_t micros = tm.m_tv_sec * 1000000LL + tm.m_tv_usec;
    *out = duckdb::Value::TIMESTAMP(duckdb::Timestamp::FromEpochMicroSeconds(micros));
    return true;
}

duckdb::LogicalType MySQLToDuckDB(const Field *f) {
    switch (f->real_type()) {
        case MYSQL_TYPE_TINY:
            return f->is_unsigned() ? duckdb::LogicalType::UTINYINT : duckdb::LogicalType::TINYINT;
        case MYSQL_TYPE_SHORT:
            return f->is_unsigned() ? duckdb::LogicalType::USMALLINT : duckdb::LogicalType::SMALLINT;
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
            return f->is_unsigned() ? duckdb::LogicalType::UINTEGER : duckdb::LogicalType::INTEGER;
        case MYSQL_TYPE_LONGLONG:
            return f->is_unsigned() ? duckdb::LogicalType::UBIGINT : duckdb::LogicalType::BIGINT;
        case MYSQL_TYPE_FLOAT:
            return duckdb::LogicalType::FLOAT;
        case MYSQL_TYPE_DOUBLE:
            return duckdb::LogicalType::DOUBLE;
        case MYSQL_TYPE_NEWDECIMAL: {
            // field_length is the display width (sign, dot, digits). The actual
            // DECIMAL precision lives on Field_new_decimal::precision.
            const auto *dec = static_cast<const Field_new_decimal *>(f);
            return duckdb::LogicalType::DECIMAL(static_cast<uint8_t>(dec->precision),
                                                static_cast<uint8_t>(dec->decimals()));
        }
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_STRING:
        case MYSQL_TYPE_VAR_STRING:
            return duckdb::LogicalType::VARCHAR;
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB:
            return duckdb::LogicalType::BLOB;
        case MYSQL_TYPE_DATE:
        case MYSQL_TYPE_NEWDATE:
            return duckdb::LogicalType::DATE;
        case MYSQL_TYPE_TIMESTAMP:
        case MYSQL_TYPE_TIMESTAMP2:
        case MYSQL_TYPE_DATETIME:
        case MYSQL_TYPE_DATETIME2:
            // Both map to tz-naive DuckDB TIMESTAMP. The semantic difference is
            // the *wall clock we store*: TIMESTAMP holds the UTC instant,
            // DATETIME holds the verbatim wall clock. See duckdb_types.h.
            return duckdb::LogicalType::TIMESTAMP;
        case MYSQL_TYPE_TIME:
        case MYSQL_TYPE_TIME2:
            return duckdb::LogicalType::TIME;
        case MYSQL_TYPE_JSON:
            return duckdb::LogicalType::VARCHAR;  // stored as JSON string
        case MYSQL_TYPE_BOOL:
            return duckdb::LogicalType::BOOLEAN;
        default:
            return duckdb::LogicalType::INVALID;
    }
}

int AppendField(duckdb::Appender &appender, const Field *field) {
    if (field->is_null()) {
        appender.Append(nullptr);
        return 0;
    }
    switch (field->real_type()) {
        case MYSQL_TYPE_TINY:
            if (field->is_unsigned()) appender.Append(static_cast<uint8_t>(field->val_int()));
            else appender.Append(static_cast<int8_t>(field->val_int()));
            return 0;
        case MYSQL_TYPE_SHORT:
            if (field->is_unsigned()) appender.Append(static_cast<uint16_t>(field->val_int()));
            else appender.Append(static_cast<int16_t>(field->val_int()));
            return 0;
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
            if (field->is_unsigned()) appender.Append(static_cast<uint32_t>(field->val_int()));
            else appender.Append(static_cast<int32_t>(field->val_int()));
            return 0;
        case MYSQL_TYPE_LONGLONG:
            if (field->is_unsigned())
                appender.Append(static_cast<uint64_t>(field->val_int()));
            else
                appender.Append(static_cast<int64_t>(field->val_int()));
            return 0;
        case MYSQL_TYPE_FLOAT:
            appender.Append(static_cast<float>(field->val_real()));
            return 0;
        case MYSQL_TYPE_DOUBLE:
            appender.Append(field->val_real());
            return 0;
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_STRING:
        case MYSQL_TYPE_VAR_STRING:
        case MYSQL_TYPE_JSON: {
            String buf;
            field->val_str(&buf);
            const char *p = buf.ptr() ? buf.ptr() : "";
            // Append(const char*, len) copies into the chunk's string heap now,
            // so the stack buffer's lifetime ending here is safe.
            appender.Append(p, static_cast<uint32_t>(buf.length()));
            return 0;
        }
        // DECIMAL: typed scaled-integer path (no string format/parse) for
        // widths up to 18. Hugeint widths use the string path inline below.
        case MYSQL_TYPE_NEWDECIMAL: {
            const auto *df = static_cast<const Field_new_decimal *>(field);
            const uint width = df->precision;
            const uint scale = df->decimals();
            if (width <= kDecimalInt64MaxWidth) {
                my_decimal dec;
                field->val_decimal(&dec);
                decimal_shift(&dec, static_cast<int>(scale));  // ×10^scale → int
                longlong v = 0;
                decimal2longlong(&dec, &v);
                const auto w = static_cast<uint8_t>(width);
                const auto s = static_cast<uint8_t>(scale);
                if (width <= 4)
                    appender.Append(duckdb::Value::DECIMAL(static_cast<int16_t>(v), w, s));
                else if (width <= 9)
                    appender.Append(duckdb::Value::DECIMAL(static_cast<int32_t>(v), w, s));
                else
                    appender.Append(duckdb::Value::DECIMAL(static_cast<int64_t>(v), w, s));
                return 0;
            }
            String buf;  // hugeint width: string round-trip
            field->val_str(&buf);
            const char *p = buf.ptr() ? buf.ptr() : "";
            appender.Append(duckdb::Value(std::string(p, buf.length()))
                                .DefaultCastAs(MySQLToDuckDB(field)));
            return 0;
        }
        // TIMESTAMP/TIMESTAMP2: UTC-stored in MySQL. Go through the UTC epoch so
        // the stored instant is independent of the writing session's time zone
        // (see invariant in duckdb_types.h). val_str() would render in the
        // session tz and corrupt cross-session reads.
        case MYSQL_TYPE_TIMESTAMP:
        case MYSQL_TYPE_TIMESTAMP2: {
            duckdb::Value v;
            if (TimestampFieldToUtcValue(field, &v)) {
                appender.Append(v);
            } else {
                appender.Append(nullptr);  // MySQL zero timestamp → SQL NULL
            }
            return 0;
        }
        // DATETIME/DATE/TIME: tz-naive on both sides; round-trip through MySQL's
        // canonical string form and let DuckDB parse/cast it. MySQL 9.7's Field
        // exposes no public typed getter for these, so the string path is the
        // portable choice and is session-tz-independent for tz-naive types.
        case MYSQL_TYPE_DATE:
        case MYSQL_TYPE_NEWDATE:
        case MYSQL_TYPE_DATETIME:
        case MYSQL_TYPE_DATETIME2:
        case MYSQL_TYPE_TIME:
        case MYSQL_TYPE_TIME2: {
            String buf;
            field->val_str(&buf);
            const char *p = buf.ptr() ? buf.ptr() : "";
            appender.Append(duckdb::Value(std::string(p, buf.length()))
                                .DefaultCastAs(MySQLToDuckDB(field)));
            return 0;
        }
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB: {
            String buf;
            field->val_str(&buf);
            const auto *bp = reinterpret_cast<const uint8_t *>(buf.ptr() ? buf.ptr() : "");
            appender.Append(duckdb::Value::BLOB(bp, buf.length()));
            return 0;
        }
        case MYSQL_TYPE_BOOL:
            appender.Append(static_cast<bool>(field->val_int() != 0));
            return 0;
        default:
            DBUG_PRINT("error", ("ducksdb: AppendField unsupported MySQL type %d", field->real_type()));
            return HA_ERR_UNSUPPORTED;
    }
}

duckdb::Value FieldToValue(const Field *field) {
    if (field->is_null()) return duckdb::Value();  // untyped NULL; cast on bind
    switch (field->real_type()) {
        case MYSQL_TYPE_TINY:
            return field->is_unsigned()
                       ? duckdb::Value::UTINYINT(static_cast<uint8_t>(field->val_int()))
                       : duckdb::Value::TINYINT(static_cast<int8_t>(field->val_int()));
        case MYSQL_TYPE_SHORT:
            return field->is_unsigned()
                       ? duckdb::Value::USMALLINT(static_cast<uint16_t>(field->val_int()))
                       : duckdb::Value::SMALLINT(static_cast<int16_t>(field->val_int()));
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
            return field->is_unsigned()
                       ? duckdb::Value::UINTEGER(static_cast<uint32_t>(field->val_int()))
                       : duckdb::Value::INTEGER(static_cast<int32_t>(field->val_int()));
        case MYSQL_TYPE_LONGLONG:
            return field->is_unsigned()
                       ? duckdb::Value::UBIGINT(static_cast<uint64_t>(field->val_int()))
                       : duckdb::Value::BIGINT(static_cast<int64_t>(field->val_int()));
        case MYSQL_TYPE_FLOAT:
            return duckdb::Value::FLOAT(static_cast<float>(field->val_real()));
        case MYSQL_TYPE_DOUBLE:
            return duckdb::Value::DOUBLE(field->val_real());
        case MYSQL_TYPE_NEWDECIMAL: {
            const auto *df = static_cast<const Field_new_decimal *>(field);
            const uint width = df->precision;
            const uint scale = df->decimals();
            if (width <= kDecimalInt64MaxWidth) {
                my_decimal dec;
                field->val_decimal(&dec);
                decimal_shift(&dec, static_cast<int>(scale));
                longlong v = 0;
                decimal2longlong(&dec, &v);
                const auto w = static_cast<uint8_t>(width);
                const auto s = static_cast<uint8_t>(scale);
                if (width <= 4) return duckdb::Value::DECIMAL(static_cast<int16_t>(v), w, s);
                if (width <= 9) return duckdb::Value::DECIMAL(static_cast<int32_t>(v), w, s);
                return duckdb::Value::DECIMAL(static_cast<int64_t>(v), w, s);
            }
            String buf;
            field->val_str(&buf);
            return duckdb::Value(std::string(buf.ptr() ? buf.ptr() : "", buf.length()))
                .DefaultCastAs(MySQLToDuckDB(field));
        }
        // TIMESTAMP/TIMESTAMP2: bind the UTC instant so a WHERE on a timestamp
        // PK matches the UTC-stored column regardless of session tz.
        case MYSQL_TYPE_TIMESTAMP:
        case MYSQL_TYPE_TIMESTAMP2: {
            duckdb::Value v;
            if (TimestampFieldToUtcValue(field, &v)) return v;
            return duckdb::Value();  // zero timestamp → untyped NULL (cast on bind)
        }
        case MYSQL_TYPE_DATE:
        case MYSQL_TYPE_NEWDATE:
        case MYSQL_TYPE_DATETIME:
        case MYSQL_TYPE_DATETIME2:
        case MYSQL_TYPE_TIME:
        case MYSQL_TYPE_TIME2: {
            String buf;
            field->val_str(&buf);
            return duckdb::Value(std::string(buf.ptr() ? buf.ptr() : "", buf.length()))
                .DefaultCastAs(MySQLToDuckDB(field));
        }
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_STRING:
        case MYSQL_TYPE_VAR_STRING:
        case MYSQL_TYPE_JSON: {
            String buf;
            field->val_str(&buf);
            return duckdb::Value(std::string(buf.ptr() ? buf.ptr() : "", buf.length()));
        }
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB: {
            String buf;
            field->val_str(&buf);
            const auto *bp = reinterpret_cast<const uint8_t *>(buf.ptr() ? buf.ptr() : "");
            return duckdb::Value::BLOB(bp, buf.length());
        }
        case MYSQL_TYPE_BOOL:
            return duckdb::Value::BOOLEAN(field->val_int() != 0);
        default:
            return duckdb::Value();  // unsupported: bind NULL (should not occur)
    }
}

int StoreField(Field *field, const duckdb::Value &value) {
    if (value.IsNull()) {
        field->set_null();
        return 0;
    }
    field->set_notnull();
    switch (field->real_type()) {
        case MYSQL_TYPE_TINY:
        case MYSQL_TYPE_SHORT:
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
        case MYSQL_TYPE_LONGLONG:
            if (field->is_unsigned()) {
                field->store(static_cast<longlong>(value.GetValue<uint64_t>()), true);
            } else {
                field->store(value.GetValue<int64_t>(), false);
            }
            return 0;
        case MYSQL_TYPE_FLOAT:
        case MYSQL_TYPE_DOUBLE:
            field->store(value.GetValue<double>());
            return 0;
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_STRING:
        case MYSQL_TYPE_VAR_STRING:
        case MYSQL_TYPE_JSON: {
            std::string s = value.GetValue<std::string>();
            // DuckDB strings are UTF-8; let MySQL convert into the column charset.
            field->store(s.c_str(), s.size(), &my_charset_utf8mb4_bin);
            return 0;
        }
        // DECIMAL: typed scaled-integer path for widths up to 18 (mirrors
        // AppendField); hugeint widths / non-DECIMAL values use the string path.
        case MYSQL_TYPE_NEWDECIMAL: {
            const auto &t = value.type();
            if (t.id() == duckdb::LogicalTypeId::DECIMAL) {
                const uint8_t width = duckdb::DecimalType::GetWidth(t);
                const uint8_t scale = duckdb::DecimalType::GetScale(t);
                if (width <= kDecimalInt64MaxWidth) {
                    int64_t raw;
                    if (width <= 4)
                        raw = value.GetValueUnsafe<int16_t>();
                    else if (width <= 9)
                        raw = value.GetValueUnsafe<int32_t>();
                    else
                        raw = value.GetValueUnsafe<int64_t>();
                    my_decimal dec;
                    longlong2decimal(static_cast<longlong>(raw), &dec);
                    decimal_shift(&dec, -static_cast<int>(scale));  // ÷10^scale
                    field->store_decimal(&dec);
                    return 0;
                }
            }
            std::string s = value.ToString();  // hugeint / non-decimal fallback
            field->store(s.c_str(), s.size(), &my_charset_bin);
            return 0;
        }
        // TIMESTAMP/TIMESTAMP2: the DuckDB value holds the UTC wall clock (it was
        // written from the UTC epoch). Reverse via the UTC epoch micros and
        // Field::store_timestamp(), which is tz-independent — so the represented
        // instant is identical no matter which session reads it.
        case MYSQL_TYPE_TIMESTAMP:
        case MYSQL_TYPE_TIMESTAMP2: {
            // The bind/append path always produces a TIMESTAMP; cast defensively
            // in case a value of another temporal type reaches here.
            duckdb::Value ts =
                value.type().id() == duckdb::LogicalTypeId::TIMESTAMP
                    ? value
                    : value.DefaultCastAs(duckdb::LogicalType::TIMESTAMP);
            const int64_t micros =
                duckdb::Timestamp::GetEpochMicroSeconds(duckdb::TimestampValue::Get(ts));
            my_timeval tm{};
            tm.m_tv_sec = micros / 1000000LL;
            tm.m_tv_usec = micros % 1000000LL;
            if (tm.m_tv_usec < 0) {  // floor toward -inf for pre-epoch instants
                tm.m_tv_usec += 1000000LL;
                tm.m_tv_sec -= 1;
            }
            field->store_timestamp(&tm);
            return 0;
        }
        // DATETIME/DATE/TIME: tz-naive. DuckDB's canonical string form parses
        // cleanly into the MySQL column via Field::store(str). Mirrors AppendField.
        case MYSQL_TYPE_DATE:
        case MYSQL_TYPE_NEWDATE:
        case MYSQL_TYPE_DATETIME:
        case MYSQL_TYPE_DATETIME2:
        case MYSQL_TYPE_TIME:
        case MYSQL_TYPE_TIME2: {
            std::string s = value.ToString();
            field->store(s.c_str(), s.size(), &my_charset_bin);
            return 0;
        }
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB: {
            auto bytes = duckdb::StringValue::Get(value);
            field->store(bytes.data(), bytes.size(), &my_charset_bin);
            return 0;
        }
        case MYSQL_TYPE_BOOL:
            field->store(value.GetValue<bool>() ? 1 : 0, false);
            return 0;
        default:
            return HA_ERR_UNSUPPORTED;
    }
}

// Read one integer cell using the DuckDB VECTOR's actual physical width, then
// store into the MySQL integer field (whatever its width). On the scan path the
// vector width always equals the field width, so this reads exactly the same
// bytes the old field-keyed read did. On the pushdown path a computed column's
// DuckDB type can be WIDER than the MySQL result field — e.g. DuckDB
// EXTRACT(year FROM …) yields BIGINT while MySQL types EXTRACT(YEAR …) as INT, so
// the staging Field is MYSQL_TYPE_LONG (int32) but the result vector is BIGINT.
// Reading by the vector's true type avoids DuckDB's "Expected vector of type
// INT32, but found vector of BIGINT" fetch error; Field::store(longlong) then
// applies the field's normal range handling. Returns false if the vector type is
// not an integer flavor (caller falls back to the field-keyed path).
static inline bool StoreFlatIntByVectorType(Field *field, duckdb::Vector &vec,
                                            size_t row) {
    const bool uns = field->is_unsigned();
    switch (vec.GetType().id()) {
        case duckdb::LogicalTypeId::TINYINT:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<int8_t>(vec)[row]), false);
            return true;
        case duckdb::LogicalTypeId::SMALLINT:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<int16_t>(vec)[row]), false);
            return true;
        case duckdb::LogicalTypeId::INTEGER:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<int32_t>(vec)[row]), false);
            return true;
        case duckdb::LogicalTypeId::BIGINT:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<int64_t>(vec)[row]), false);
            return true;
        case duckdb::LogicalTypeId::UTINYINT:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<uint8_t>(vec)[row]), true);
            return true;
        case duckdb::LogicalTypeId::USMALLINT:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<uint16_t>(vec)[row]), true);
            return true;
        case duckdb::LogicalTypeId::UINTEGER:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<uint32_t>(vec)[row]), true);
            return true;
        case duckdb::LogicalTypeId::UBIGINT:
            field->store(static_cast<longlong>(duckdb::FlatVector::GetData<uint64_t>(vec)[row]), true);
            return true;
        default:
            (void)uns;
            return false;  // not a fixed-width integer vector
    }
}

int StoreFlatCell(Field *field, duckdb::Vector &vec, size_t row) {
    if (!duckdb::FlatVector::Validity(vec).RowIsValid(row)) {
        field->set_null();
        return 0;
    }
    field->set_notnull();
    switch (field->real_type()) {
        case MYSQL_TYPE_TINY:
        case MYSQL_TYPE_SHORT:
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
        case MYSQL_TYPE_LONGLONG:
            // Read by the DuckDB vector's true integer width (handles a result
            // column that is wider than the MySQL field, e.g. EXTRACT→BIGINT into
            // an INT field). Falls back to the value path for non-integer vectors
            // (e.g. a DECIMAL/HUGEINT result feeding an integer field).
            if (StoreFlatIntByVectorType(field, vec, row)) return 0;
            return StoreField(field, vec.GetValue(row));
        case MYSQL_TYPE_FLOAT:
            field->store(static_cast<double>(duckdb::FlatVector::GetData<float>(vec)[row]));
            return 0;
        case MYSQL_TYPE_DOUBLE:
            field->store(duckdb::FlatVector::GetData<double>(vec)[row]);
            return 0;
        case MYSQL_TYPE_VARCHAR:
        case MYSQL_TYPE_STRING:
        case MYSQL_TYPE_VAR_STRING:
        case MYSQL_TYPE_JSON: {
            const duckdb::string_t &s = duckdb::FlatVector::GetData<duckdb::string_t>(vec)[row];
            field->store(s.GetData(), s.GetSize(), &my_charset_utf8mb4_bin);
            return 0;
        }
        case MYSQL_TYPE_TINY_BLOB:
        case MYSQL_TYPE_MEDIUM_BLOB:
        case MYSQL_TYPE_LONG_BLOB:
        case MYSQL_TYPE_BLOB: {
            const duckdb::string_t &s = duckdb::FlatVector::GetData<duckdb::string_t>(vec)[row];
            field->store(s.GetData(), s.GetSize(), &my_charset_bin);
            return 0;
        }
        case MYSQL_TYPE_NEWDECIMAL: {
            const auto &t = vec.GetType();
            if (t.id() == duckdb::LogicalTypeId::DECIMAL) {
                const uint8_t width = duckdb::DecimalType::GetWidth(t);
                const uint8_t scale = duckdb::DecimalType::GetScale(t);
                if (width <= kDecimalInt64MaxWidth) {
                    int64_t raw;
                    if (width <= 4)
                        raw = duckdb::FlatVector::GetData<int16_t>(vec)[row];
                    else if (width <= 9)
                        raw = duckdb::FlatVector::GetData<int32_t>(vec)[row];
                    else
                        raw = duckdb::FlatVector::GetData<int64_t>(vec)[row];
                    my_decimal dec;
                    longlong2decimal(static_cast<longlong>(raw), &dec);
                    decimal_shift(&dec, -static_cast<int>(scale));
                    field->store_decimal(&dec);
                    return 0;
                }
            }
            return StoreField(field, vec.GetValue(row));  // hugeint fallback
        }
        case MYSQL_TYPE_BOOL:
            field->store(duckdb::FlatVector::GetData<bool>(vec)[row] ? 1 : 0, false);
            return 0;
        // TIMESTAMP/TIMESTAMP2: typed fast path. The flat vector holds timestamp_t
        // (UTC wall clock, microsecond units). Reverse to the UTC instant and
        // store via the tz-independent Field::store_timestamp().
        case MYSQL_TYPE_TIMESTAMP:
        case MYSQL_TYPE_TIMESTAMP2: {
            if (vec.GetType().id() == duckdb::LogicalTypeId::TIMESTAMP) {
                const duckdb::timestamp_t ts =
                    duckdb::FlatVector::GetData<duckdb::timestamp_t>(vec)[row];
                const int64_t micros = duckdb::Timestamp::GetEpochMicroSeconds(ts);
                my_timeval tm{};
                tm.m_tv_sec = micros / 1000000LL;
                tm.m_tv_usec = micros % 1000000LL;
                if (tm.m_tv_usec < 0) {
                    tm.m_tv_usec += 1000000LL;
                    tm.m_tv_sec -= 1;
                }
                field->store_timestamp(&tm);
                return 0;
            }
            return StoreField(field, vec.GetValue(row));  // unexpected type: safe path
        }
        // DATETIME/DATE/TIME (no public typed Field getter) and anything else:
        // build a Value and reuse the canonical StoreField path. Correctness over
        // speed.
        default:
            return StoreField(field, vec.GetValue(row));
    }
}

}  // namespace ducksdb_mysql
