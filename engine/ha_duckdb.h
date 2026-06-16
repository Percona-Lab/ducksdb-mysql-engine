// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <memory>
#include <string>
#include <vector>
#include "sql/handler.h"

namespace duckdb {
class Connection;
class PreparedStatement;
}
namespace ducksdb_mysql {
class ScanCursor;
class BulkAppender;

// TABLE_SHARE-scoped state shared by every open ha_duckdb handler for one
// table. Owned by the server (allocated via set_ha_share_ptr, deleted when the
// TABLE_SHARE is freed). Guards the cached optimizer row count so info() and
// records_in_range() don't run SELECT COUNT(*) on a fresh connection per call.
// All access goes through ha_duckdb's get_share() under lock_shared_ha_data().
class DucksdbShare : public Handler_share {
public:
    DucksdbShare() = default;
    ~DucksdbShare() override = default;

    // Last computed COUNT(*). Only meaningful while count_valid_ is true and
    // count_dirty_ is false.
    ha_rows row_count_ = 0;
    bool count_valid_ = false;  // a count has been computed at least once
    bool count_dirty_ = true;   // a write happened since the last compute
};
}  // namespace ducksdb_mysql

extern handlerton *ducksdb_hton;

class ha_duckdb : public handler {
public:
    ha_duckdb(handlerton *hton, TABLE_SHARE *table_arg);
    ~ha_duckdb() override;

    // Bulk-load fast-path entry point, dispatched from the handlerton load_into
    // hook: ingest a server-side CSV directly via DuckDB COPY instead of the
    // row-by-row write path. Sets *handled=true if it ran the load (then
    // *rows_loaded holds the count); returns true only on a real error. Leaves
    // *handled=false (returning false) to fall back to write_row.
    bool load_data_fast(const char *file_path, const class sql_exchange *ex,
                        int dup, bool ignore, ulonglong *rows_loaded,
                        bool *handled);

    const char *table_type() const override { return "DuckDB"; }
    ulonglong table_flags() const override {
        return HA_NULL_IN_KEY | HA_CAN_INDEX_BLOBS |
               HA_PRIMARY_KEY_REQUIRED_FOR_DELETE;
    }
    ulong index_flags(uint, uint, bool) const override {
        return HA_READ_NEXT | HA_READ_RANGE | HA_READ_ORDER;
    }
    uint max_supported_keys() const override { return 64; }
    uint max_supported_key_parts() const override { return 16; }
    uint max_supported_key_length() const override { return 3072; }
    uint max_supported_key_part_length(HA_CREATE_INFO *) const override { return 3072; }

    int open(const char *name, int mode, uint test_if_locked,
             const dd::Table *table_def) override;
    int close(void) override;
    int rnd_init(bool scan) override;
    int rnd_next(uchar *buf) override;
    int rnd_end(void) override;
    int rnd_pos(uchar * /*buf*/, uchar * /*pos*/) override { return HA_ERR_WRONG_COMMAND; }

    // Engine condition pushdown. In stock MySQL 9.7 the server invokes this only
    // for UPDATE/DELETE (and discards the remainder, re-applying the full
    // condition itself), so we translate the safely-pushable, superset part of
    // the condition into a DuckDB WHERE applied during the scan.
    const Item *cond_push(const Item *cond) override;
    int reset() override;

    int index_init(uint idx, bool sorted) override;
    int index_end() override;
    int index_read_map(uchar *buf, const uchar *key, key_part_map keypart_map,
                       enum ha_rkey_function find_flag) override;
    int index_next(uchar *buf) override;
    int index_first(uchar *buf) override;
    int index_last(uchar *buf) override;
    void position(const uchar * /*record*/) override {}
    int info(uint flag) override;
    // Estimated rows in [min_key, max_key] on index `inx`, so the optimizer can
    // cost index ranges vs a full scan (the base default returns a useless 10).
    ha_rows records_in_range(uint inx, key_range *min_key, key_range *max_key) override;
    int write_row(uchar *buf) override;
    int update_row(const uchar *old_data, uchar *new_data) override;
    int delete_row(const uchar *buf) override;
    void start_bulk_insert(ha_rows rows) override;
    int end_bulk_insert() override;
    int truncate(dd::Table *table_def) override;
    THR_LOCK_DATA **store_lock(THD * /*thd*/, THR_LOCK_DATA **to,
                               enum thr_lock_type /*lock_type*/) override { return to; }
    int create(const char *name, TABLE *form, HA_CREATE_INFO *create_info,
               dd::Table *table_def) override;
    int delete_table(const char *name, const dd::Table *table_def) override;
    int rename_table(const char *from, const char *to,
                     const dd::Table *from_table_def, dd::Table *to_table_def) override;

    // v1 ALTER uses MySQL's copy-table path (create new, copy rows, swap, drop old)
    // rather than in-place edits of the DuckDB catalog.
    enum_alter_inplace_result check_if_supported_inplace_alter(
        TABLE * /*altered_table*/, Alter_inplace_info * /*ha_alter_info*/) override {
        return HA_ALTER_INPLACE_NOT_SUPPORTED;
    }

private:
    // Pull the cursor's current row into table->record[0]. Shared by the
    // sequential scan and index reads.
    int fetch_row();

    // Build the projected SELECT column list from table->read_set (plus the
    // primary key, so update_row/delete_row can locate the row). Records the
    // projected field indices in scan_proj_ so fetch_row() maps result columns
    // back to fields. Returns the comma-separated quoted list (or "*"/"1").
    // When the write_set is non-empty (an UPDATE scan whose per-row rewrite
    // needs every column), the full row is projected for correctness.
    std::string build_projection();

    // Field indices (into table->field[]) projected by the current scan, in
    // SELECT order. Result column j corresponds to table->field[scan_proj_[j]].
    std::vector<uint> scan_proj_;

    // DuckDB WHERE translated from a pushed-down condition (cond_push), applied
    // to the scan. Empty = nothing pushed. Cleared by reset() at statement end.
    std::string pushed_where_;

    // Row count from DuckDB (COUNT(*) on a fresh read connection), for
    // optimizer statistics. Returns 0 on any error. This opens a connection, so
    // callers should prefer cached_row_count() to avoid one COUNT(*) per
    // info()/records_in_range() call.
    ha_rows duckdb_row_count();

    // Cached COUNT(*) backed by the TABLE_SHARE-scoped DucksdbShare. Recomputes
    // (via duckdb_row_count()) only when the cache is invalid or a write marked
    // it dirty; otherwise returns the stored value without opening a connection.
    ha_rows cached_row_count();

    // Mark the share's cached row count stale after a write/truncate so the next
    // cached_row_count() recomputes. Safe to call when no share exists yet.
    void invalidate_row_count();

    // Lazily create (under lock_shared_ha_data) and return the TABLE_SHARE-scoped
    // state shared by all handlers for this table. Returns nullptr only if the
    // share could not be allocated.
    ducksdb_mysql::DucksdbShare *get_share();

    // Cached pointer to the shared state for this handler instance (resolved on
    // first use via get_share()); the object itself lives on the TABLE_SHARE.
    ducksdb_mysql::DucksdbShare *share_ = nullptr;

    // The per-THD DuckDB connection for this table's schema, with the current
    // transaction begun and this engine registered. All DML/scan routes through
    // it so reads and writes share one transaction-scoped connection.
    duckdb::Connection &txn_conn();

    std::unique_ptr<ducksdb_mysql::ScanCursor> scan_;
    std::unique_ptr<ducksdb_mysql::BulkAppender> bulk_;
    // Per-statement prepared UPDATE/DELETE: parse/plan once, bind+execute per
    // row. Created lazily on first update_row/delete_row, cleared in reset()
    // (statement boundary) and close().
    std::unique_ptr<duckdb::PreparedStatement> upd_prep_;
    std::unique_ptr<duckdb::PreparedStatement> del_prep_;
    std::string db_name_;
    std::string table_name_;
};
