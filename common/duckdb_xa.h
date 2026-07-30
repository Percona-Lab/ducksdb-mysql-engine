// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <map>
#include <memory>
#include <string>
#include "duckdb.hpp"
#include "sql/handler.h"  // handlerton, THD, XID, XA_recover_txn, xa_status_code

namespace ducksdb_mysql {

// Per-THD state: one DuckDB connection per schema touched by the connection,
// plus transaction bookkeeping. Stored at THD->ha_data[ducksdb_hton->slot].
struct ThdState {
    std::map<std::string, std::unique_ptr<duckdb::Connection>> connections;
    bool tx_open = false;    // a BEGIN has been issued on the connections
    // Set at Prepare() when this THD's transaction was handed to the global
    // prepared registry (g_prepared). Internal two-phase commit finishes such a
    // transaction via Commit/Rollback(all=true) on the SAME THD (NOT
    // commit_by_xid, which is only the external-XA path), so we remember which
    // entry to finish. Empty when the transaction was not prepared.
    std::string prepared_xid;

    // Get-or-open the connection for `schema`; begins it if a tx is already open.
    duckdb::Connection &Acquire(const std::string &schema);
    void Begin();
    int Commit();
    int Rollback();
};

ThdState &GetThdState(THD *thd);
// Register this engine with the current (real) transaction so MySQL drives our
// commit/rollback callbacks.
void RegisterTx(THD *thd);
// Roll back and drop any still-prepared XA transactions; call at plugin shutdown
// so their DuckDB connections close before DuckDB's statics are torn down.
void ShutdownXa();

// Handlerton callbacks (signatures verified against mysql-9.7.0 handler.h).
int CloseConnection(handlerton *, THD *thd);
int StartConsistentSnapshot(handlerton *, THD *thd);
int Commit(handlerton *, THD *thd, bool all);
int Rollback(handlerton *, THD *thd, bool all);
int Prepare(handlerton *, THD *thd, bool all);          // returns int in 9.7
xa_status_code CommitByXid(handlerton *, XID *xid);
xa_status_code RollbackByXid(handlerton *, XID *xid);
int Recover(handlerton *, XA_recover_txn *txn_list, uint len, MEM_ROOT *mem_root);

}  // namespace ducksdb_mysql
