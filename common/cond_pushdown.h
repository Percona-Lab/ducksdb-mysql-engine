// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#pragma once

#include <string>

struct TABLE;
class Item;

namespace ducksdb_mysql {

// Translate a MySQL WHERE condition tree into a DuckDB SQL predicate that is a
// SUPERSET-safe filter: every row satisfying `cond` also satisfies the returned
// expression. Returns "" when nothing is safely pushable.
//
// Safety rationale: the server pushes conditions only for UPDATE/DELETE and
// always re-applies the full condition itself (it discards cond_push's
// remainder), so returning a superset is correct — it merely prunes rows early
// in DuckDB. We therefore only translate predicates we can render with matching
// semantics: integer/DECIMAL comparisons (=, <>, <, <=, >, >=), BETWEEN, IN,
// and IS [NOT] NULL, over columns of `table`. AND drops un-pushable conjuncts
// (weaker → still a superset); OR is pushed only when every branch translates
// (dropping a branch would make it stricter). Operands must be basic literal
// constants; FLOAT/DOUBLE columns are skipped to avoid cast/ULP mismatches.
std::string TranslateCondToSQL(const Item *cond, const TABLE *table);

}  // namespace ducksdb_mysql
