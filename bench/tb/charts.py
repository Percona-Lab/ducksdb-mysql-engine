#!/usr/bin/env python3
"""Render charts from a benchmark results directory.

Runs inside $REPORT_IMAGE (python + matplotlib); nothing is installed on the
host. Everything is optional: whatever legs/phases are missing are simply not
plotted, so this works after a partial run.

    python3 charts.py --results /path/results --sf 1000 --out /path/results/charts

Produces:
    chart-query-times.png   per-query time, grouped bars, log scale, DNF marked
    chart-load-time.png     load time per engine
    chart-storage.png       on-disk footprint per engine + compression
    chart-summary.png       one-page overview of all three axes
"""
import argparse
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ENGINES = ["innodb", "duckdb", "native"]
LABEL = {
    "innodb": "InnoDB",
    "duckdb": "MySQL + DuckDB engine",
    "native": "native DuckDB",
}
COLOR = {"innodb": "#b0464a", "duckdb": "#2f6db0", "native": "#4c9a63"}
QN = list(range(1, 23))


def read_timings(results):
    """Parse timings.txt into {key: value}. Last occurrence wins."""
    out = {}
    path = os.path.join(results, "timings.txt")
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            m = re.match(r"^([A-Za-z0-9_]+)=(.*)$", line.strip())
            if m:
                out[m.group(1)] = m.group(2).strip()
    return out


def fnum(d, key):
    try:
        return float(d[key])
    except (KeyError, ValueError, TypeError):
        return None


def read_queries(results, sf, engine):
    """-> {qnum: float | 'DNF' | 'ERR'} for whatever was recorded."""
    d = os.path.join(results, "queries-%s-sf%s" % (engine, sf))
    if not os.path.isdir(d):
        return {}
    out = {}
    for n in QN:
        p = os.path.join(d, "q%02d.time" % n)
        if not os.path.exists(p):
            continue
        v = open(p).read().strip()
        if v in ("DNF", "ERR"):
            out[n] = v
        else:
            try:
                out[n] = float(v)
            except ValueError:
                pass
    return out


def human_bytes(b):
    b = float(b)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or unit == "TB":
            return "%.1f %s" % (b, unit)
        b /= 1024


def human_secs(s):
    s = float(s)
    if s >= 3600:
        return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
    if s >= 60:
        return "%dm%02ds" % (s // 60, s % 60)
    return "%.1fs" % s


# --------------------------------------------------------------------------- #
def chart_query_times(results, sf, outdir):
    data = {e: read_queries(results, sf, e) for e in ENGINES}
    present = [e for e in ENGINES if data[e]]
    if not present:
        return None

    # DNF bars are drawn at the tallest finite value so they are visibly "off
    # the chart" rather than silently absent.
    finite = [v for e in present for v in data[e].values() if isinstance(v, float)]
    if not finite:
        return None
    dnf_h = max(finite) * 1.6

    fig, ax = plt.subplots(figsize=(16, 6.5))
    width = 0.8 / len(present)
    x = np.arange(len(QN))
    any_dnf = False

    for i, e in enumerate(present):
        heights, hatches = [], []
        for n in QN:
            v = data[e].get(n)
            if isinstance(v, float):
                heights.append(max(v, 1e-3)); hatches.append(None)
            elif v in ("DNF", "ERR"):
                heights.append(dnf_h); hatches.append("////"); any_dnf = True
            else:
                heights.append(0.0); hatches.append(None)
        off = (i - (len(present) - 1) / 2) * width
        bars = ax.bar(x + off, heights, width, label=LABEL[e],
                      color=COLOR[e], edgecolor="white", linewidth=0.3)
        for b, h in zip(bars, hatches):
            if h:
                b.set_hatch(h); b.set_edgecolor("#333333"); b.set_alpha(0.55)

    ax.set_yscale("log")
    ax.set_xticks(x); ax.set_xticklabels(["Q%d" % n for n in QN], fontsize=9)
    ax.set_ylabel("query time (s, log scale) - lower is better")
    ax.set_title("TPC-H SF%s: per-query time" % sf)
    ax.grid(axis="y", ls=":", alpha=0.4); ax.set_axisbelow(True)
    if any_dnf:
        ax.axhline(dnf_h, color="#333333", lw=0.8, ls=":")
        ax.text(0.1, dnf_h * 1.05, "hatched = DNF (exceeded the timeout) or ERR",
                fontsize=8, color="#333333")
    ax.legend(ncol=len(present), fontsize=9, loc="upper center",
              bbox_to_anchor=(0.5, -0.08), frameon=False)
    fig.tight_layout()
    p = os.path.join(outdir, "chart-query-times.png")
    fig.savefig(p, dpi=150, bbox_inches="tight"); plt.close(fig)
    return p


def chart_load_time(results, outdir):
    t = read_timings(results)
    rows = [(LABEL[e], fnum(t, "load_%s_seconds" % e), COLOR[e])
            for e in ENGINES]
    rows = [r for r in rows if r[1] is not None]
    if not rows:
        return None
    fig, ax = plt.subplots(figsize=(8, 4.5))
    names = [r[0] for r in rows]; vals = [r[1] for r in rows]; cols = [r[2] for r in rows]
    bars = ax.barh(names, vals, color=cols, height=0.55)
    for b, v in zip(bars, vals):
        ax.text(b.get_width() * 1.01, b.get_y() + b.get_height() / 2,
                human_secs(v), va="center", fontsize=10)
    ax.set_xlabel("load time (s) - lower is better")
    ax.set_title("Load time")
    ax.grid(axis="x", ls=":", alpha=0.4); ax.set_axisbelow(True)
    ax.set_xlim(0, max(vals) * 1.25)
    fig.tight_layout()
    p = os.path.join(outdir, "chart-load-time.png")
    fig.savefig(p, dpi=150, bbox_inches="tight"); plt.close(fig)
    return p


def chart_storage(results, outdir):
    t = read_timings(results)
    raw = fnum(t, "storage_raw_bytes")
    rows = [("raw CSV", raw, "#888888")]
    for e in ENGINES:
        v = fnum(t, "storage_%s_bytes" % e)
        if v:
            rows.append((LABEL[e], v, COLOR[e]))
    rows = [r for r in rows if r[1]]
    if len(rows) < 2:
        return None
    fig, ax = plt.subplots(figsize=(8, 4.5))
    names = [r[0] for r in rows]; vals = [r[1] for r in rows]; cols = [r[2] for r in rows]
    bars = ax.barh(names, vals, color=cols, height=0.55)
    for b, v in zip(bars, vals):
        lbl = human_bytes(v)
        if raw and v != raw:
            lbl += "  (%.2fx smaller)" % (raw / v)
        ax.text(b.get_width() * 1.01, b.get_y() + b.get_height() / 2, lbl,
                va="center", fontsize=10)
    ax.set_xlabel("on-disk size (bytes) - lower is better")
    ax.set_title("Storage consumption (TPC-H payload)")
    ax.grid(axis="x", ls=":", alpha=0.4); ax.set_axisbelow(True)
    ax.set_xlim(0, max(vals) * 1.45)
    fig.tight_layout()
    p = os.path.join(outdir, "chart-storage.png")
    fig.savefig(p, dpi=150, bbox_inches="tight"); plt.close(fig)
    return p


def chart_summary(results, sf, outdir):
    """One page: load, storage, and query totals side by side."""
    t = read_timings(results)
    fig, axes = plt.subplots(1, 3, figsize=(16, 4.6))
    fig.suptitle("TPC-H SF%s - summary" % sf, fontsize=13)

    # load
    ax = axes[0]
    rows = [(LABEL[e], fnum(t, "load_%s_seconds" % e), COLOR[e]) for e in ENGINES]
    rows = [r for r in rows if r[1] is not None]
    if rows:
        ax.bar([r[0] for r in rows], [r[1] for r in rows], color=[r[2] for r in rows])
        for i, r in enumerate(rows):
            ax.text(i, r[1], human_secs(r[1]), ha="center", va="bottom", fontsize=9)
        ax.set_ylabel("seconds"); ax.set_ylim(0, max(r[1] for r in rows) * 1.25)
    else:
        ax.text(.5, .5, "no load data", ha="center", transform=ax.transAxes)
    ax.set_title("Load time"); ax.tick_params(axis="x", labelrotation=20, labelsize=8)

    # storage
    ax = axes[1]
    rows = [("raw CSV", fnum(t, "storage_raw_bytes"), "#888888")]
    rows += [(LABEL[e], fnum(t, "storage_%s_bytes" % e), COLOR[e]) for e in ENGINES]
    rows = [r for r in rows if r[1]]
    if len(rows) >= 2:
        # Pick the unit from the largest value: at SF1000 that is GB/TB, but a
        # smoke run at SF=0.01 is megabytes and would otherwise print "0.0".
        mx = max(r[1] for r in rows)
        unit, div = next((u, d) for u, d in
                         (("TB", 1024 ** 4), ("GB", 1024 ** 3), ("MB", 1024 ** 2),
                          ("KB", 1024), ("B", 1))
                         if mx >= d or d == 1)
        vals = [r[1] / div for r in rows]
        ax.bar([r[0] for r in rows], vals, color=[r[2] for r in rows])
        for i, v in enumerate(vals):
            ax.text(i, v, ("%.1f" if v >= 10 else "%.2f") % v,
                    ha="center", va="bottom", fontsize=9)
        ax.set_ylabel(unit); ax.set_ylim(0, max(vals) * 1.25)
    else:
        ax.text(.5, .5, "no storage data", ha="center", transform=ax.transAxes)
    ax.set_title("Storage"); ax.tick_params(axis="x", labelrotation=20, labelsize=8)

    # query totals + completion
    ax = axes[2]
    names, totals, cols, notes = [], [], [], []
    for e in ENGINES:
        q = read_queries(results, sf, e)
        if not q:
            continue
        fin = [v for v in q.values() if isinstance(v, float)]
        dnf = sum(1 for v in q.values() if v in ("DNF", "ERR"))
        names.append(LABEL[e]); totals.append(sum(fin)); cols.append(COLOR[e])
        notes.append("%d/22 done%s" % (len(fin), (", %d DNF" % dnf) if dnf else ""))
    if names:
        ax.bar(names, totals, color=cols)
        for i, (v, note) in enumerate(zip(totals, notes)):
            ax.text(i, v, "%s\n%s" % (human_secs(v), note),
                    ha="center", va="bottom", fontsize=8)
        ax.set_ylabel("sum of finished queries (s)")
        ax.set_ylim(0, max(totals) * 1.35 if max(totals) else 1)
    else:
        ax.text(.5, .5, "no query data", ha="center", transform=ax.transAxes)
    ax.set_title("Query time (finished only)"); ax.tick_params(axis="x", labelrotation=20, labelsize=8)

    for a in axes:
        a.grid(axis="y", ls=":", alpha=0.4); a.set_axisbelow(True)
    fig.tight_layout(rect=[0, 0, 1, 0.94])
    p = os.path.join(outdir, "chart-summary.png")
    fig.savefig(p, dpi=150, bbox_inches="tight"); plt.close(fig)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--sf", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    made = []
    for fn in (lambda: chart_query_times(a.results, a.sf, a.out),
               lambda: chart_load_time(a.results, a.out),
               lambda: chart_storage(a.results, a.out),
               lambda: chart_summary(a.results, a.sf, a.out)):
        try:
            p = fn()
            if p:
                made.append(p)
        except Exception as exc:                      # never let one chart kill the rest
            print("  WARN: chart failed: %s" % exc)

    if made:
        for p in made:
            print("  wrote %s" % p)
    else:
        print("  no charts produced - no results found in %s" % a.results)


if __name__ == "__main__":
    main()
