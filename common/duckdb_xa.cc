// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "duckdb_xa.h"

#include <mutex>
#include <vector>
#include <mysql/plugin.h>  // thd_get_ha_data, thd_set_ha_data, thd_test_options
#include "duckdb_engine_context.h"
#include "ha_duckdb.h"  // ducksdb_hton
#include "sql/query_options.h"  // OPTION_NOT_AUTOCOMMIT, OPTION_BEGIN
#include "sql/xa.h"  // full xid_t definition (key(), key_length())

namespace ducksdb_mysql {

// In-memory registry of XA-prepared transactions: at PREPARE we hand the THD's
// open DuckDB connections (transactions still open, NOT committed) here keyed by
// the XID, so commit_by_xid / rollback_by_xid can finish them — from any session
// — with correct semantics (real rollback, not a compensating delete). The
// trade-off vs a sidecar log is that prepared transactions do not survive a
// crash/restart (they roll back); see KNOWN-ISSUES / Recover().
static std::mutex g_prepared_mu;
static std::map<std::string, std::vector<std::unique_ptr<duckdb::Connection>>> g_prepared;

static std::string XidKey(const XID *xid) {
    return std::string(reinterpret_cast<const char *>(xid->key()), xid->key_length());
}

// True when the connection is inside an explicit multi-statement transaction
// (BEGIN / autocommit=0), as opposed to a single autocommit statement.
static bool InMultiStmtTx(THD *thd) {
    return thd_test_options(thd, OPTION_NOT_AUTOCOMMIT | OPTION_BEGIN) != 0;
}

duckdb::Connection &ThdState::Acquire(const std::string &schema) {
    auto it = connections.find(schema);
    if (it != connections.end()) return *it->second;
    auto conn = EngineContext::Get().Connection(schema);
    if (tx_open) conn->Query("BEGIN TRANSACTION");
    auto &ref = *conn;
    connections.emplace(schema, std::move(conn));
    return ref;
}

void ThdState::Begin() {
    if (tx_open) return;
    for (auto &kv : connections) kv.second->Query("BEGIN TRANSACTION");
    tx_open = true;
}

int ThdState::Commit() {
    int rc = 0;
    for (auto &kv : connections) {
        auto r = kv.second->Query("COMMIT");
        if (r->HasError()) rc = HA_ERR_GENERIC;
    }
    tx_open = false;
    return rc;
}

int ThdState::Rollback() {
    for (auto &kv : connections) kv.second->Query("ROLLBACK");
    tx_open = false;
    return 0;
}

ThdState &GetThdState(THD *thd) {
    auto *p = static_cast<ThdState *>(thd_get_ha_data(thd, ducksdb_hton));
    if (!p) {
        p = new ThdState();
        thd_set_ha_data(thd, ducksdb_hton, p);
    }
    return *p;
}

void RegisterTx(THD *thd) {
    // Always register for the statement transaction; register for the real
    // (multi-statement) transaction only when one is actually open — otherwise
    // the server asserts in_active_multi_stmt_transaction() in autocommit mode.
    // trans_register_ha is idempotent per (all) flag.
    trans_register_ha(thd, false, ducksdb_hton, nullptr);
    if (InMultiStmtTx(thd)) {
        trans_register_ha(thd, true, ducksdb_hton, nullptr);
    }
}

// Drop the per-THD state (closing its DuckDB connections) and clear ha_data so
// the plugin is no longer held "busy" by this connection — otherwise UNINSTALL
// PLUGIN on the same connection is deferred to shutdown.
static void ResetThdState(THD *thd) {
    auto *p = static_cast<ThdState *>(thd_get_ha_data(thd, ducksdb_hton));
    delete p;
    thd_set_ha_data(thd, ducksdb_hton, nullptr);
}

int CloseConnection(handlerton *, THD *thd) {
    ResetThdState(thd);
    return 0;
}

int StartConsistentSnapshot(handlerton *, THD *thd) {
    try {
        GetThdState(thd).Begin();
    } catch (const std::exception &) {
        return HA_ERR_GENERIC;
    }
    RegisterTx(thd);
    return 0;
}

// The "real" commit/rollback fires when `all` is set, or — in autocommit mode —
// at the statement boundary (all=false but no multi-statement tx is open). A
// statement-level commit inside an explicit transaction is a no-op (we keep the
// DuckDB transaction open until the explicit COMMIT/ROLLBACK).
// These are C-ABI handlerton callbacks: an escaping C++ exception would crash
// mysqld, so every body is wrapped. ResetThdState always runs on the real
// boundary, even on error, so ha_data is never left dangling.
int Commit(handlerton *, THD *thd, bool all) {
    if (!(all || !InMultiStmtTx(thd))) return 0;
    int rc = 0;
    try {
        rc = GetThdState(thd).Commit();
    } catch (const std::exception &) {
        rc = HA_ERR_GENERIC;
    }
    ResetThdState(thd);
    return rc;
}

int Rollback(handlerton *, THD *thd, bool all) {
    if (!(all || !InMultiStmtTx(thd))) return 0;
    int rc = 0;
    try {
        rc = GetThdState(thd).Rollback();
    } catch (const std::exception &) {
        rc = HA_ERR_GENERIC;
    }
    ResetThdState(thd);
    return rc;
}

// PREPARE: hand the THD's open connections (transactions still open) to the
// global registry keyed by XID; do not commit yet.
int Prepare(handlerton *, THD *thd, bool all) {
    if (!all) return 0;  // only the real transaction is prepared
    try {
        auto &state = GetThdState(thd);
        if (!state.tx_open || state.connections.empty()) return 0;
        XID xid;
        thd_get_xid(thd, reinterpret_cast<MYSQL_XID *>(&xid));
        std::string key = XidKey(&xid);
        {
            std::lock_guard<std::mutex> g(g_prepared_mu);
            if (g_prepared.count(key)) return HA_ERR_GENERIC;  // duplicate XID
            auto &slot = g_prepared[key];
            for (auto &kv : state.connections) slot.push_back(std::move(kv.second));
        }
        state.connections.clear();
        state.tx_open = false;  // handed off; the THD no longer owns this tx
        ResetThdState(thd);     // drop the now-empty per-THD state
    } catch (const std::exception &) {
        return HA_ERR_GENERIC;
    }
    return 0;
}

xa_status_code CommitByXid(handlerton *, XID *xid) {
    std::vector<std::unique_ptr<duckdb::Connection>> conns;
    {
        std::lock_guard<std::mutex> g(g_prepared_mu);
        auto it = g_prepared.find(XidKey(xid));
        if (it == g_prepared.end()) return XAER_NOTA;  // unknown XID
        conns = std::move(it->second);
        g_prepared.erase(it);
    }
    try {
        for (size_t i = 0; i < conns.size(); ++i) {
            auto r = conns[i]->Query("COMMIT");
            if (r->HasError()) {
                // Best effort: roll back the branches not yet committed to limit
                // cross-schema inconsistency (DuckDB has no cross-file 2PC).
                for (size_t j = i + 1; j < conns.size(); ++j) conns[j]->Query("ROLLBACK");
                return XAER_RMERR;
            }
        }
    } catch (const std::exception &) {
        return XAER_RMERR;
    }
    return XA_OK;
}

xa_status_code RollbackByXid(handlerton *, XID *xid) {
    std::vector<std::unique_ptr<duckdb::Connection>> conns;
    {
        std::lock_guard<std::mutex> g(g_prepared_mu);
        auto it = g_prepared.find(XidKey(xid));
        if (it == g_prepared.end()) return XAER_NOTA;
        conns = std::move(it->second);
        g_prepared.erase(it);
    }
    try {
        for (auto &c : conns) c->Query("ROLLBACK");
    } catch (const std::exception &) {
        return XAER_RMERR;
    }
    return XA_OK;
}

// Prepared transactions live only in memory, so after a restart there are none
// to recover (they were rolled back when their connections closed). This is the
// documented crash-recovery limitation of the in-memory prepare strategy.
int Recover(handlerton *, XA_recover_txn *, uint, MEM_ROOT *) { return 0; }

void ShutdownXa() {
    std::lock_guard<std::mutex> g(g_prepared_mu);
    for (auto &kv : g_prepared) {
        for (auto &c : kv.second) {
            try {
                c->Query("ROLLBACK");
            } catch (...) {
            }
        }
    }
    g_prepared.clear();
}

}  // namespace ducksdb_mysql
