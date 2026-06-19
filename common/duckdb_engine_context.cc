// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "duckdb_engine_context.h"

#include <cstdlib>  // getenv
#include <filesystem>
#include "sql/mysqld.h"  // for `mysql_real_data_home`

namespace ducksdb_mysql {

// Build the DuckDB instance config. The embedded engine runs INSIDE mysqld, so
// DuckDB's own working set sits on top of mysqld's process memory and the
// result-staging temp table. When the server is under a hard memory limit
// (a container cgroup, ulimit, etc.) DuckDB's default memory_limit (≈80% of the
// detected RAM) can leave too little headroom for that overhead — the kernel
// OOM-kills mysqld before DuckDB spills (observed on TPC-H Q15 at SF100). Two
// env knobs make this tunable without a server restart-time sysvar:
//   DUCKSDB_MEMORY_LIMIT  e.g. "28GB" or "60%" — cap DuckDB so it SPILLS to disk
//                         (leaving room for mysqld) instead of being OOM-killed.
//   DUCKSDB_TEMP_DIR      spill directory (defaults to the data dir, which is
//                         writable and has the table data's disk budget).
// Unset memory_limit → DuckDB's default (unchanged behavior).
static void ConfigureInstance(duckdb::DBConfig &config) {
    if (const char *ml = std::getenv("DUCKSDB_MEMORY_LIMIT"); ml && *ml) {
        config.SetOptionByName("memory_limit", duckdb::Value(std::string(ml)));
    }
    const char *td = std::getenv("DUCKSDB_TEMP_DIR");
    config.SetOptionByName(
        "temp_directory",
        duckdb::Value(std::string((td && *td) ? td : mysql_real_data_home)));
}

EngineContext &EngineContext::Get() {
    static EngineContext instance;
    return instance;
}

std::string EngineContext::FilePathFor(const std::string &schema) {
    std::filesystem::path p(mysql_real_data_home);
    p /= (schema + ".duckdb");
    return p.string();
}

std::shared_ptr<duckdb::DuckDB> EngineContext::Instance(const std::string &schema) {
    {
        std::shared_lock<std::shared_mutex> r(mu_);
        auto it = instances_.find(schema);
        if (it != instances_.end()) return it->second;
    }
    std::unique_lock<std::shared_mutex> w(mu_);
    auto it = instances_.find(schema);
    if (it != instances_.end()) return it->second;
    duckdb::DBConfig config;
    ConfigureInstance(config);
    auto db = std::make_shared<duckdb::DuckDB>(FilePathFor(schema), &config);
    instances_.emplace(schema, db);
    return db;
}

std::unique_ptr<duckdb::Connection> EngineContext::Connection(const std::string &schema) {
    auto db = Instance(schema);
    return std::make_unique<duckdb::Connection>(*db);
}

int EngineContext::Drop(const std::string &schema) {
    // NOTE: MySQL takes an exclusive MDL on the schema for DROP DATABASE, so no
    // handler is concurrently using this instance here. A caller that still
    // holds a shared_ptr from a prior Instance() keeps the DuckDB object alive;
    // on Linux the open inode survives the unlink. Cross-platform-safe teardown
    // (wait for refcount==1 / rename-then-delete) is deferred — Drop() is not yet
    // wired to a DROP DATABASE hook (lands with the handler in a later phase).
    std::unique_lock<std::shared_mutex> w(mu_);
    instances_.erase(schema);  // shared_ptr destroyed → DuckDB closes
    std::error_code ec;
    std::filesystem::remove(FilePathFor(schema), ec);
    return ec ? 1 : 0;
}

size_t EngineContext::OpenInstanceCount() const {
    std::shared_lock<std::shared_mutex> r(mu_);
    return instances_.size();
}

}  // namespace ducksdb_mysql
