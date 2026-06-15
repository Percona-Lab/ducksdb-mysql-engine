// Copyright (c) 2026 ducksdb-mysql contributors.
// SPDX-License-Identifier: GPL-2.0

#include "cond_pushdown.h"

#include <cstdio>
#include "duckdb_sql_util.h"
#include "sql/field.h"
#include "sql/item.h"
#include "sql/item_cmpfunc.h"
#include "sql/item_func.h"
#include "sql/table.h"
#include "template_utils.h"  // down_cast

namespace ducksdb_mysql {

// A column of `table` whose type we can compare with DuckDB-matching semantics
// (integers + DECIMAL; FLOAT/DOUBLE excluded to avoid cast/ULP differences).
static bool NumericField(const Item *it, const TABLE *table, std::string *col) {
    if (it->type() != Item::FIELD_ITEM) return false;
    const Field *f = down_cast<const Item_field *>(it)->field;
    if (!f || f->table != table) return false;
    switch (f->real_type()) {
        case MYSQL_TYPE_TINY:
        case MYSQL_TYPE_SHORT:
        case MYSQL_TYPE_INT24:
        case MYSQL_TYPE_LONG:
        case MYSQL_TYPE_LONGLONG:
        case MYSQL_TYPE_NEWDECIMAL:
            *col = QuoteIdent(f->field_name);
            return true;
        default:
            return false;
    }
}

// Any column of `table` (IS [NOT] NULL is type-independent and exact).
static bool AnyField(const Item *it, const TABLE *table, std::string *col) {
    if (it->type() != Item::FIELD_ITEM) return false;
    const Field *f = down_cast<const Item_field *>(it)->field;
    if (!f || f->table != table) return false;
    *col = QuoteIdent(f->field_name);
    return true;
}

// Render a basic literal constant (int / DECIMAL) as a bare numeric SQL literal.
// Only basic_const_item() literals are accepted, so val_*() is side-effect free
// and never an unbound parameter or a deferred expression.
static bool NumericLiteral(Item *it, std::string *out) {
    if (!it->basic_const_item()) return false;
    switch (it->result_type()) {
        case INT_RESULT: {
            const longlong v = it->val_int();
            if (it->null_value) return false;
            *out = it->unsigned_flag
                       ? std::to_string(static_cast<unsigned long long>(v))
                       : std::to_string(static_cast<long long>(v));
            return true;
        }
        case DECIMAL_RESULT: {
            String tmp;
            String *s = it->val_str(&tmp);
            if (!s || it->null_value) return false;
            *out = std::string(s->ptr(), s->length());
            return true;
        }
        default:
            return false;  // string/real/temporal literals: not pushed
    }
}

static const char *CmpOp(Item_func::Functype f, bool flip) {
    switch (f) {
        case Item_func::EQ_FUNC: return "=";
        case Item_func::NE_FUNC: return "<>";
        case Item_func::LT_FUNC: return flip ? ">" : "<";
        case Item_func::LE_FUNC: return flip ? ">=" : "<=";
        case Item_func::GT_FUNC: return flip ? "<" : ">";
        case Item_func::GE_FUNC: return flip ? "<=" : ">=";
        default: return nullptr;
    }
}

static std::string Compare(Item_func *fn, const TABLE *table) {
    if (fn->argument_count() != 2) return "";
    Item *a = fn->arguments()[0];
    Item *b = fn->arguments()[1];
    std::string col, lit;
    if (NumericField(a, table, &col) && NumericLiteral(b, &lit)) {
        const char *op = CmpOp(fn->functype(), false);
        return op ? col + " " + op + " " + lit : "";
    }
    if (NumericField(b, table, &col) && NumericLiteral(a, &lit)) {
        const char *op = CmpOp(fn->functype(), true);
        return op ? col + " " + op + " " + lit : "";
    }
    return "";
}

static std::string Between(Item_func *fn, const TABLE *table) {
    auto *bt = down_cast<Item_func_between *>(fn);
    if (bt->negated) return "";  // NOT BETWEEN: skip
    if (fn->argument_count() != 3) return "";
    std::string col, lo, hi;
    if (NumericField(fn->arguments()[0], table, &col) &&
        NumericLiteral(fn->arguments()[1], &lo) &&
        NumericLiteral(fn->arguments()[2], &hi)) {
        return "(" + col + " >= " + lo + " AND " + col + " <= " + hi + ")";
    }
    return "";
}

static std::string In(Item_func *fn, const TABLE *table) {
    auto *in = down_cast<Item_func_in *>(fn);
    if (in->negated) return "";  // NOT IN: skip
    std::string col;
    if (fn->argument_count() < 2 || !NumericField(fn->arguments()[0], table, &col))
        return "";
    std::string vals;
    for (uint i = 1; i < fn->argument_count(); ++i) {
        std::string lit;
        if (!NumericLiteral(fn->arguments()[i], &lit)) return "";  // all-or-nothing
        if (!vals.empty()) vals += ", ";
        vals += lit;
    }
    if (vals.empty()) return "";
    return col + " IN (" + vals + ")";
}

static std::string NullTest(Item_func *fn, const TABLE *table, bool is_null) {
    if (fn->argument_count() != 1) return "";
    std::string col;
    if (!AnyField(fn->arguments()[0], table, &col)) return "";
    return col + (is_null ? " IS NULL" : " IS NOT NULL");
}

std::string TranslateCondToSQL(const Item *cond, const TABLE *table) {
    if (!cond) return "";

    if (cond->type() == Item::COND_ITEM) {
        auto *c = const_cast<Item_cond *>(down_cast<const Item_cond *>(cond));
        const bool is_and = c->functype() == Item_func::COND_AND_FUNC;
        const bool is_or = c->functype() == Item_func::COND_OR_FUNC;
        if (!is_and && !is_or) return "";
        std::string out;
        bool first = true;
        for (Item &child : *c->argument_list()) {
            std::string part = TranslateCondToSQL(&child, table);
            if (part.empty()) {
                if (is_or) return "";  // OR: a missing branch would over-restrict
                continue;              // AND: dropping a conjunct stays a superset
            }
            if (!first) out += is_and ? " AND " : " OR ";
            out += part;
            first = false;
        }
        if (first) return "";
        return "(" + out + ")";
    }

    if (cond->type() != Item::FUNC_ITEM) return "";
    auto *fn = const_cast<Item_func *>(down_cast<const Item_func *>(cond));
    switch (fn->functype()) {
        case Item_func::EQ_FUNC:
        case Item_func::NE_FUNC:
        case Item_func::LT_FUNC:
        case Item_func::LE_FUNC:
        case Item_func::GT_FUNC:
        case Item_func::GE_FUNC:
            return Compare(fn, table);
        case Item_func::BETWEEN:
            return Between(fn, table);
        case Item_func::IN_FUNC:
            return In(fn, table);
        case Item_func::ISNULL_FUNC:
            return NullTest(fn, table, true);
        case Item_func::ISNOTNULL_FUNC:
            return NullTest(fn, table, false);
        default:
            return "";
    }
}

}  // namespace ducksdb_mysql
