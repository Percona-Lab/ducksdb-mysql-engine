// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "ha_duckdb.h"

#include <mysql/plugin.h>
#include <new>  // std::nothrow
#include <string>
#include "mysqld_error.h"
#include "sql/handler.h"
#include "sql/key.h"  // key_restore

#include "cond_pushdown.h"
#include "ddl_convertor.h"
#include "dml_convertor.h"
#include "duckdb_appender.h"
#include "duckdb_engine_context.h"
#include "duckdb_pushdown.h"  // PushdownSelect (whole-query pushdown hook)
#include "duckdb_scan.h"
#include "duckdb_sql_util.h"
#include "duckdb_types.h"
#include "duckdb_xa.h"
#include "sql/table.h"

handlerton *ducksdb_hton = nullptr;

ha_duckdb::ha_duckdb(handlerton *hton, TABLE_SHARE *table_arg)
    : handler(hton, table_arg) {}

ha_duckdb::~ha_duckdb() = default;

static handler *ducksdb_create_handler(handlerton *hton, TABLE_SHARE *table,
                                        bool /*partitioned*/, MEM_ROOT *mem_root) {
    return new (mem_root) ha_duckdb(hton, table);
}

// Extract schema and table from MySQL's path-style "name" arg ("./db/tbl").
static void parse_db_table(const char *name, std::string &db, std::string &tbl) {
    std::string s(name);
    auto last = s.find_last_of('/');
    if (last == std::string::npos) {
        db.clear();
        tbl = s;
        return;
    }
    // Guard last==0 so `last - 1` doesn't wrap (unsigned) when the path
    // begins with '/'.
    auto prev = (last == 0) ? std::string::npos : s.find_last_of('/', last - 1);
    db = (prev == std::string::npos) ? s.substr(0, last)
                                     : s.substr(prev + 1, last - prev - 1);
    tbl = s.substr(last + 1);
}

static void ducksdb_drop_database(handlerton *, const char *path) {
    std::string p(path);
    // path looks like "<datadir>/db/" (often with a trailing slash)
    while (!p.empty() && p.back() == '/') p.pop_back();
    auto last = p.find_last_of('/');
    std::string db = (last == std::string::npos) ? p : p.substr(last + 1);
    if (!db.empty()) ducksdb_mysql::DropSchema(db);
}

int ha_duckdb::create(const char *name, TABLE *form, HA_CREATE_INFO *create_info,
                      dd::Table * /*table_def*/) {
    std::string db, tbl;
    parse_db_table(name, db, tbl);
    try {
        auto sql = ducksdb_mysql::BuildCreateTableSQL(db, tbl, form, create_info);
        auto conn = ducksdb_mysql::EngineContext::Get().Connection(db);
        auto r = conn->Query(sql);
        if (r->HasError()) {
            my_error(ER_GET_ERRMSG, MYF(0), 0, r->GetError().c_str(), "DuckDB");
            return HA_ERR_GENERIC;
        }
    } catch (const std::exception &e) {
        my_error(ER_GET_ERRMSG, MYF(0), 0, e.what(), "DuckDB");
        return HA_ERR_GENERIC;
    }
    return 0;
}

int ha_duckdb::delete_table(const char *name, const dd::Table * /*table_def*/) {
    std::string db, tbl;
    parse_db_table(name, db, tbl);
    try {
        auto conn = ducksdb_mysql::EngineContext::Get().Connection(db);
        auto r = conn->Query(ducksdb_mysql::BuildDropTableSQL(db, tbl));
        if (r->HasError()) {
            my_error(ER_GET_ERRMSG, MYF(0), 0, r->GetError().c_str(), "DuckDB");
            return HA_ERR_GENERIC;
        }
    } catch (const std::exception &e) {
        my_error(ER_GET_ERRMSG, MYF(0), 0, e.what(), "DuckDB");
        return HA_ERR_GENERIC;
    }
    return 0;
}

int ha_duckdb::rename_table(const char *from, const char *to,
                            const dd::Table * /*from_table_def*/,
                            dd::Table * /*to_table_def*/) {
    std::string fdb, ftbl, tdb, ttbl;
    parse_db_table(from, fdb, ftbl);
    parse_db_table(to, tdb, ttbl);
    // Each schema is a separate DuckDB file; an in-file RENAME can't move a
    // table across schemas. Reject rather than silently leave it in the wrong file.
    if (fdb != tdb) {
        my_error(ER_NOT_SUPPORTED_YET, MYF(0), "cross-schema RENAME for ENGINE=DuckDB");
        return HA_ERR_GENERIC;
    }
    try {
        auto conn = ducksdb_mysql::EngineContext::Get().Connection(fdb);
        auto r = conn->Query(ducksdb_mysql::BuildRenameTableSQL(fdb, ftbl, ttbl));
        if (r->HasError()) {
            my_error(ER_GET_ERRMSG, MYF(0), 0, r->GetError().c_str(), "DuckDB");
            return HA_ERR_GENERIC;
        }
    } catch (const std::exception &e) {
        my_error(ER_GET_ERRMSG, MYF(0), 0, e.what(), "DuckDB");
        return HA_ERR_GENERIC;
    }
    return 0;
}

int ha_duckdb::open(const char *name, int /*mode*/, uint /*test_if_locked*/,
                    const dd::Table * /*table_def*/) {
    // Connections are per-THD (transaction-scoped) now; open() only records the
    // schema/table names. The first DML/scan acquires the connection via txn_conn().
    parse_db_table(name, db_name_, table_name_);
    return 0;
}

int ha_duckdb::close(void) {
    bulk_.reset();
    scan_.reset();
    upd_prep_.reset();
    del_prep_.reset();
    // The DucksdbShare lives on the TABLE_SHARE, not this handler; just drop our
    // cached pointer so a reopen re-resolves it via get_share().
    share_ = nullptr;
    return 0;
}

duckdb::Connection &ha_duckdb::txn_conn() {
    THD *thd = ha_thd();
    auto &state = ducksdb_mysql::GetThdState(thd);
    auto &conn = state.Acquire(db_name_);
    state.Begin();  // idempotent: BEGINs once per transaction
    // Register every statement: the statement-level registration is cleared at
    // each statement boundary, the real-transaction one is idempotent.
    ducksdb_mysql::RegisterTx(thd);
    return conn;
}

void ha_duckdb::start_bulk_insert(ha_rows /*rows*/) {
    try {
        bulk_ = std::make_unique<ducksdb_mysql::BulkAppender>(txn_conn(), table_name_);
    } catch (const std::exception &e) {
        bulk_.reset();  // fall back to per-row INSERT
    }
}

int ha_duckdb::end_bulk_insert() {
    if (!bulk_) return 0;
    int rc = bulk_->Flush();
    bulk_.reset();
    if (rc == 0) invalidate_row_count();  // bulk rows landed: cached count stale
    return rc;
}

ha_rows ha_duckdb::duckdb_row_count() {
    try {
        // Fresh read connection: a COUNT(*) for stats must not begin/register a
        // transaction on the per-THD connection. Sees committed data only, which
        // is fine for optimizer estimates.
        auto conn = ducksdb_mysql::EngineContext::Get().Connection(db_name_);
        auto r = conn->Query("SELECT COUNT(*) FROM " +
                             ducksdb_mysql::QuoteIdent(table_name_));
        if (!r || r->HasError()) return 0;
        auto chunk = r->Fetch();
        if (!chunk || chunk->size() == 0) return 0;
        return static_cast<ha_rows>(chunk->GetValue(0, 0).GetValue<int64_t>());
    } catch (const std::exception &) {
        return 0;
    }
}

ducksdb_mysql::DucksdbShare *ha_duckdb::get_share() {
    if (share_) return share_;
    lock_shared_ha_data();
    auto *s = static_cast<ducksdb_mysql::DucksdbShare *>(get_ha_share_ptr());
    if (!s) {
        s = new (std::nothrow) ducksdb_mysql::DucksdbShare();
        if (s) set_ha_share_ptr(static_cast<Handler_share *>(s));
    }
    unlock_shared_ha_data();
    share_ = s;
    return share_;
}

ha_rows ha_duckdb::cached_row_count() {
    ducksdb_mysql::DucksdbShare *s = get_share();
    if (!s) return duckdb_row_count();  // no share: fall back, never cache

    // Fast path: return the cached value without touching DuckDB.
    lock_shared_ha_data();
    if (s->count_valid_ && !s->count_dirty_) {
        ha_rows cached = s->row_count_;
        unlock_shared_ha_data();
        return cached;
    }
    // Optimistically clear dirty before recomputing so a write that lands while
    // the COUNT(*) is in flight re-sets it and we won't mark its result clean.
    s->count_dirty_ = false;
    unlock_shared_ha_data();

    // Slow path: recompute outside the share lock (the COUNT(*) can be slow and
    // must not block other handlers), then publish the fresh value — but only as
    // "valid" if no concurrent write re-dirtied the cache while we were counting.
    ha_rows fresh = duckdb_row_count();
    lock_shared_ha_data();
    s->row_count_ = fresh;
    if (!s->count_dirty_) s->count_valid_ = true;  // no write raced us
    unlock_shared_ha_data();
    return fresh;
}

void ha_duckdb::invalidate_row_count() {
    ducksdb_mysql::DucksdbShare *s = get_share();
    if (!s) return;
    lock_shared_ha_data();
    s->count_dirty_ = true;
    unlock_shared_ha_data();
}

int ha_duckdb::info(uint flag) {
    // get_dup_key() asks for the violated key via HA_STATUS_ERRKEY. v1 only has
    // the primary key, so report it so a duplicate surfaces as ER_DUP_ENTRY.
    if (flag & HA_STATUS_ERRKEY) errkey = table->s->primary_key;
    if (flag & HA_STATUS_VARIABLE) {
        // Real row count so the optimizer can cost scans and order joins. Served
        // from the TABLE_SHARE-scoped cache; only recomputed when a write since
        // the last call marked it dirty, so repeated info() calls within one
        // statement don't each open a fresh connection for COUNT(*).
        ha_rows n = cached_row_count();
        stats.records = n;
        stats.deleted = 0;
        stats.mean_rec_length = table->s->reclength;
        stats.data_file_length = static_cast<ulonglong>(n) *
                                 (stats.mean_rec_length ? stats.mean_rec_length : 1);
        stats.index_file_length = 0;
    }
    return 0;
}

ha_rows ha_duckdb::records_in_range(uint inx, key_range *min_key, key_range *max_key) {
    // Use the cached count (avoids a fresh COUNT(*) connection per call); fall
    // back to a direct count only if no estimate has been gathered yet.
    ha_rows total = stats.records ? stats.records : cached_row_count();
    if (total < 2) total = 2;

    const KEY &k = table->key_info[inx];
    const bool unique = (k.flags & HA_NOSAME) != 0;
    const key_part_map full =
        (static_cast<key_part_map>(1) << k.user_defined_key_parts) - 1;
    const bool min_exact = min_key && min_key->flag == HA_READ_KEY_EXACT;
    const bool full_min = min_key && min_key->keypart_map == full;
    const bool full_max = max_key && max_key->keypart_map == full;

    // Equality over the full unique key matches at most one row.
    if (unique && min_exact && min_key && max_key && full_min && full_max) {
        return 1;
    }

    // We have no per-index histograms, so the estimate is shape-based rather
    // than data-driven. Distinguish the three shapes the optimizer asks about so
    // a point probe doesn't cost the same as an open-ended range:
    //   - equality probe (HA_READ_KEY_EXACT on this index): selective, ~1%;
    //   - bounded range (both endpoints present): ~10% (the prior floor);
    //   - one-sided open range (only one endpoint): broad, ~33%.
    // Each is clamped to >=1. These multipliers are deliberately coarse: 10%
    // stays the floor for the common bounded-range case so we never regress the
    // previous behavior, while equality probes are estimated tighter and open
    // ranges looser — both strictly more accurate than a flat 10% for those
    // shapes. Replace with real selectivity once DuckDB stats are wired in.
    ha_rows est;
    if (min_exact && min_key && max_key && min_key->keypart_map == max_key->keypart_map) {
        // Equality probe on (a prefix of) this index. A non-unique key still
        // returns several rows, so estimate ~1% rather than 1.
        est = total / 100;
    } else if (min_key && max_key) {
        est = total / 10;  // bounded range: keep the established 10% floor
    } else {
        est = total / 3;   // one open end: a large fraction of the table
    }
    return est ? est : 1;
}

int ha_duckdb::write_row(uchar *buf) {
    // Bulk inserts invalidate the cached count in end_bulk_insert() once flushed.
    if (bulk_) return bulk_->AppendRow(table);
    int rc = ducksdb_mysql::InsertRow(txn_conn(), db_name_, table_name_, table, buf);
    if (rc == 0) invalidate_row_count();  // a row was added: cached count stale
    return rc;
}

int ha_duckdb::truncate(dd::Table * /*table_def*/) {
    try {
        auto conn = ducksdb_mysql::EngineContext::Get().Connection(db_name_);
        auto r = conn->Query("DELETE FROM " + ducksdb_mysql::QuoteIdent(table_name_));
        if (r->HasError()) {
            my_error(ER_GET_ERRMSG, MYF(0), 0, r->GetError().c_str(), "DuckDB");
            return HA_ERR_GENERIC;
        }
    } catch (const std::exception &e) {
        my_error(ER_GET_ERRMSG, MYF(0), 0, e.what(), "DuckDB");
        return HA_ERR_GENERIC;
    }
    invalidate_row_count();  // table emptied: cached count stale
    return 0;
}

int ha_duckdb::update_row(const uchar *old_data, uchar *new_data) {
    duckdb::Connection &conn = txn_conn();
    if (table->s->primary_key == MAX_KEY)  // no PK → literal path reports the error
        return ducksdb_mysql::UpdateRowOnPK(conn, table_name_, table, old_data, new_data);
    try {
        if (!upd_prep_) {
            upd_prep_ = conn.Prepare(ducksdb_mysql::BuildPreparedUpdateSQL(table_name_, table));
            if (!upd_prep_ || upd_prep_->HasError()) {
                upd_prep_.reset();  // fall back to the per-row literal path
                return ducksdb_mysql::UpdateRowOnPK(conn, table_name_, table, old_data, new_data);
            }
        }
        duckdb::vector<duckdb::Value> params;
        ducksdb_mysql::BindUpdateParams(table, old_data, params);
        auto r = upd_prep_->Execute(params);
        if (!r) return HA_ERR_GENERIC;
        if (r->HasError()) return ducksdb_mysql::MapDuckDBError(r->GetError());
    } catch (const std::exception &e) {
        return ducksdb_mysql::MapDuckDBError(e.what());
    }
    // UPDATE leaves COUNT(*) unchanged, but invalidate for uniformity with the
    // other write paths so the cache can never lag a row-shape change.
    invalidate_row_count();
    return 0;
}

int ha_duckdb::delete_row(const uchar *buf) {
    duckdb::Connection &conn = txn_conn();
    if (table->s->primary_key == MAX_KEY)
        return ducksdb_mysql::DeleteRowOnPK(conn, table_name_, table, buf);
    try {
        if (!del_prep_) {
            del_prep_ = conn.Prepare(ducksdb_mysql::BuildPreparedDeleteSQL(table_name_, table));
            if (!del_prep_ || del_prep_->HasError()) {
                del_prep_.reset();
                return ducksdb_mysql::DeleteRowOnPK(conn, table_name_, table, buf);
            }
        }
        duckdb::vector<duckdb::Value> params;
        ducksdb_mysql::BindDeleteParams(table, buf, params);
        auto r = del_prep_->Execute(params);
        if (!r) return HA_ERR_GENERIC;
        if (r->HasError()) return ducksdb_mysql::MapDuckDBError(r->GetError());
    } catch (const std::exception &e) {
        return ducksdb_mysql::MapDuckDBError(e.what());
    }
    invalidate_row_count();  // a row was removed: cached count stale
    return 0;
}

std::string ha_duckdb::build_projection() {
    scan_proj_.clear();
    const uint nfields = table->s->fields;
    // If any column is in the write set this scan may feed an UPDATE whose
    // per-row rewrite (UpdateRowOnPK) reads every column from the new record —
    // project the full row so no unread column is written back stale.
    const bool full = bitmap_bits_set(table->write_set) > 0;

    std::vector<bool> want(nfields, false);
    for (uint i = 0; i < nfields; ++i) {
        if (full || bitmap_is_set(table->read_set, i)) want[i] = true;
    }
    // Always include the primary key so update_row/delete_row can build the
    // locating WHERE even when the optimizer left the PK out of the read set.
    if (table->s->primary_key != MAX_KEY) {
        const KEY &pk = table->key_info[table->s->primary_key];
        for (uint i = 0; i < pk.user_defined_key_parts; ++i) {
            want[pk.key_part[i].fieldnr - 1] = true;  // fieldnr is 1-based
        }
    }

    std::string list;
    for (uint i = 0; i < nfields; ++i) {
        if (!want[i]) continue;
        if (!list.empty()) list += ", ";
        list += ducksdb_mysql::QuoteIdent(table->field[i]->field_name);
        scan_proj_.push_back(i);
    }
    // No column needed (e.g. COUNT(*)): select a constant so the row count is
    // still correct; scan_proj_ stays empty so fetch_row stores nothing.
    if (scan_proj_.empty()) return "1";
    return list;
}

int ha_duckdb::fetch_row() {
    duckdb::DataChunk *chunk = nullptr;
    size_t row = 0;
    int rc = scan_->Next(&chunk, &row);
    if (rc) return rc;
    // Storing decoded values into record[0] writes to every column, so allow
    // writes to all columns regardless of the query's write_set. Result column
    // j maps back to the field recorded in scan_proj_[j].
    my_bitmap_map *org = tmp_use_all_columns(table, table->write_set);
    // Result column j (the chunk is flattened) maps to field scan_proj_[j];
    // StoreFlatCell reads it directly from the column vector, no Value per cell.
    for (size_t j = 0; j < scan_proj_.size(); ++j) {
        ducksdb_mysql::StoreFlatCell(table->field[scan_proj_[j]], chunk->data[j], row);
    }
    tmp_restore_column_map(table->write_set, org);
    return 0;
}

const Item *ha_duckdb::cond_push(const Item *cond) {
    // Translate the safely-pushable (superset) part into a DuckDB WHERE; the
    // server still re-applies the full condition, so a superset is correct.
    pushed_where_ = ducksdb_mysql::TranslateCondToSQL(cond, table);
    // Return the whole condition as the remainder: we don't promise to fully
    // evaluate it (and these call sites discard the return regardless).
    return cond;
}

int ha_duckdb::reset() {
    // ha_reset() runs at statement end: drop the pushed condition and the
    // per-statement prepared UPDATE/DELETE so the next statement re-plans
    // against its (possibly different) shape and the current connection.
    pushed_where_.clear();
    upd_prep_.reset();
    del_prep_.reset();
    return 0;
}

int ha_duckdb::rnd_init(bool /*scan*/) {
    std::string sel = build_projection();
    scan_ = std::make_unique<ducksdb_mysql::ScanCursor>(txn_conn(), table_name_);
    return scan_->Init(sel, pushed_where_);
}

int ha_duckdb::rnd_next(uchar * /*buf*/) { return fetch_row(); }

int ha_duckdb::rnd_end(void) {
    scan_.reset();
    return 0;
}

int ha_duckdb::index_init(uint idx, bool /*sorted*/) {
    active_index = idx;
    return 0;
}

int ha_duckdb::index_end(void) {
    scan_.reset();
    active_index = MAX_KEY;
    return 0;
}

static const char *cmp_for_find_flag(enum ha_rkey_function f) {
    switch (f) {
        case HA_READ_KEY_EXACT: return "=";
        case HA_READ_KEY_OR_NEXT: return ">=";
        case HA_READ_AFTER_KEY: return ">";
        case HA_READ_KEY_OR_PREV: return "<=";
        case HA_READ_BEFORE_KEY: return "<";
        default: return nullptr;
    }
}

int ha_duckdb::index_read_map(uchar * /*buf*/, const uchar *key,
                              key_part_map keypart_map,
                              enum ha_rkey_function find_flag) {
    const char *op = cmp_for_find_flag(find_flag);
    if (!op) return HA_ERR_WRONG_COMMAND;
    KEY &ki = table->key_info[active_index];

    // Unpack the active key parts into record[0] so we can read their values.
    uint klen = 0;
    for (uint i = 0; i < ki.user_defined_key_parts; ++i) {
        if (!(keypart_map & (1UL << i))) break;
        klen += ki.key_part[i].store_length;
    }
    key_restore(table->record[0], const_cast<uchar *>(key), &ki, klen);

    std::string where;
    for (uint i = 0; i < ki.user_defined_key_parts; ++i) {
        if (!(keypart_map & (1UL << i))) break;
        if (!where.empty()) where += " AND ";
        Field *kf = ki.key_part[i].field;
        where += ducksdb_mysql::QuoteIdent(kf->field_name);
        where += " ";
        where += op;
        where += " ";
        where += ducksdb_mysql::FieldLiteral(kf);
    }
    std::string order = ducksdb_mysql::QuoteIdent(ki.key_part[0].field->field_name);

    // AND any pushed-down condition with the key predicate.
    if (!pushed_where_.empty()) {
        where = where.empty()
                    ? pushed_where_
                    : "(" + where + ") AND (" + pushed_where_ + ")";
    }

    std::string sel = build_projection();
    scan_ = std::make_unique<ducksdb_mysql::ScanCursor>(txn_conn(), table_name_);
    int rc = scan_->Init(sel, where, order);
    if (rc) return rc;
    rc = fetch_row();
    // A missing exact key is reported as KEY_NOT_FOUND, not plain EOF.
    if (rc == HA_ERR_END_OF_FILE) return HA_ERR_KEY_NOT_FOUND;
    return rc;
}

int ha_duckdb::index_next(uchar * /*buf*/) {
    if (!scan_) return HA_ERR_END_OF_FILE;
    return fetch_row();
}

// index_first / index_last back the optimizer's MIN()/MAX() shortcuts and
// ordered index scans: open an ordered scan and return the first row.
int ha_duckdb::index_first(uchar * /*buf*/) {
    KEY &ki = table->key_info[active_index];
    std::string order = ducksdb_mysql::QuoteIdent(ki.key_part[0].field->field_name);
    std::string sel = build_projection();
    scan_ = std::make_unique<ducksdb_mysql::ScanCursor>(txn_conn(), table_name_);
    int rc = scan_->Init(sel, pushed_where_, order);
    if (rc) return rc;
    return fetch_row();
}

int ha_duckdb::index_last(uchar * /*buf*/) {
    KEY &ki = table->key_info[active_index];
    std::string order =
        ducksdb_mysql::QuoteIdent(ki.key_part[0].field->field_name) + " DESC";
    std::string sel = build_projection();
    scan_ = std::make_unique<ducksdb_mysql::ScanCursor>(txn_conn(), table_name_);
    int rc = scan_->Init(sel, pushed_where_, order);
    if (rc) return rc;
    return fetch_row();
}

// close_connection hook: release any pushdown plan stashed for this THD (a query
// that optimized but never executed before the session went away — otherwise its
// DuckDB connection leaks past disconnect), then run the storage-engine
// per-connection teardown.
static int ducksdb_close_connection(handlerton *hton, THD *thd) {
    ducksdb_mysql::ReleasePushdownPlan(thd);
    return ducksdb_mysql::CloseConnection(hton, thd);
}

static int ducksdb_init_func(void *p) {
    ducksdb_hton = static_cast<handlerton *>(p);
    ducksdb_hton->state = SHOW_OPTION_YES;
    ducksdb_hton->db_type = DB_TYPE_UNKNOWN;
    ducksdb_hton->create = ducksdb_create_handler;
    ducksdb_hton->drop_database = ducksdb_drop_database;

    // XA / two-phase-commit participation: MySQL 9.7 has no dedicated 2PC/XA
    // hton flag — the engine takes part by providing the prepare / commit_by_xid
    // / rollback_by_xid / recover callbacks below.
    ducksdb_hton->flags = HTON_NO_FLAGS;
    ducksdb_hton->close_connection = ducksdb_close_connection;
    ducksdb_hton->start_consistent_snapshot = ducksdb_mysql::StartConsistentSnapshot;
    ducksdb_hton->commit = ducksdb_mysql::Commit;
    ducksdb_hton->rollback = ducksdb_mysql::Rollback;
    ducksdb_hton->prepare = ducksdb_mysql::Prepare;
    ducksdb_hton->commit_by_xid = ducksdb_mysql::CommitByXid;
    ducksdb_hton->rollback_by_xid = ducksdb_mysql::RollbackByXid;
    ducksdb_hton->recover = ducksdb_mysql::Recover;

    // whole-query pushdown: when a SELECT's base tables are
    // all ENGINE=DuckDB, run it inside DuckDB and stream the result back. Invoked
    // by the server hook added in sql/sql_optimizer.cc (JOIN::optimize tail).
    ducksdb_hton->pushdown_select = ducksdb_mysql::PushdownSelect;
    return 0;
}

static int ducksdb_deinit_func(void * /*p*/) {
    // Roll back any still-prepared XA branches and close their connections while
    // DuckDB's statics are still alive.
    ducksdb_mysql::ShutdownXa();
    return 0;
}

struct st_mysql_storage_engine ducksdb_storage_engine = {MYSQL_HANDLERTON_INTERFACE_VERSION};

static int show_open_instances(THD *, SHOW_VAR *var, char *buf) {
    var->type = SHOW_LONGLONG;
    var->value = buf;
    *reinterpret_cast<long long *>(buf) =
        static_cast<long long>(ducksdb_mysql::EngineContext::Get().OpenInstanceCount());
    return 0;
}

static int show_pushdown_count(THD *, SHOW_VAR *var, char *buf) {
    var->type = SHOW_LONGLONG;
    var->value = buf;
    *reinterpret_cast<long long *>(buf) =
        static_cast<long long>(ducksdb_mysql::PushdownCount());
    return 0;
}

static SHOW_VAR ducksdb_status_vars[] = {
    {"Ducksdb_open_instances", reinterpret_cast<char *>(show_open_instances),
     SHOW_FUNC, SHOW_SCOPE_GLOBAL},
    {"Ducksdb_pushdown_count", reinterpret_cast<char *>(show_pushdown_count),
     SHOW_FUNC, SHOW_SCOPE_GLOBAL},
    {nullptr, nullptr, SHOW_LONG, SHOW_SCOPE_GLOBAL},
};

mysql_declare_plugin(ducksdb){
    MYSQL_STORAGE_ENGINE_PLUGIN,
    &ducksdb_storage_engine,
    "DuckDB",
    "ducksdb-mysql contributors",
    "DuckDB storage engine for MySQL",
    PLUGIN_LICENSE_GPL,
    ducksdb_init_func,
    nullptr,
    ducksdb_deinit_func,
    0x0001, // 0.1
    ducksdb_status_vars,
    nullptr,
    nullptr,
    0,
} mysql_declare_plugin_end;
