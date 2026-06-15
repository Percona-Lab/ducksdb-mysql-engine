// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include "duckdb.hpp"

namespace ducksdb_mysql {

// Per-mysqld registry of DuckDB instances, one per MySQL schema.
// Thread-safe. Instances are created lazily on first access and
// reference-counted; the last release on DROP DATABASE removes the file.
class EngineContext {
public:
    // Acquire the DuckDB instance for `schema`. Creates if missing.
    // Caller owns no resource — the Connection() factory below is the right way to use it.
    std::shared_ptr<duckdb::DuckDB> Instance(const std::string &schema);

    // Convenience: create a fresh Connection on the schema's instance.
    std::unique_ptr<duckdb::Connection> Connection(const std::string &schema);

    // Called on DROP DATABASE — closes the instance and deletes the .duckdb file.
    int Drop(const std::string &schema);

    // For SHOW STATUS LIKE 'Ducksdb_open_instances'
    size_t OpenInstanceCount() const;

    // Path on disk for `schema`. Absolute, under mysqld's datadir.
    static std::string FilePathFor(const std::string &schema);

    static EngineContext &Get();

    EngineContext(const EngineContext &) = delete;
    EngineContext &operator=(const EngineContext &) = delete;

private:
    EngineContext() = default;
    mutable std::shared_mutex mu_;
    std::unordered_map<std::string, std::shared_ptr<duckdb::DuckDB>> instances_;
};

}  // namespace ducksdb_mysql
