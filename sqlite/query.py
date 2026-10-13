#!/usr/bin/env python3
"""Run an analysis query from sqlite/queries/ against the jobs database.

Usage:
  python3 sqlite/query.py latest
  python3 sqlite/query.py search --param q='data strategy'
  python3 sqlite/query.py closing_soon --param days=7
  python3 sqlite/query.py agency_history --param agency='Monetary Authority of Singapore'
  python3 sqlite/query.py watchlist --param status=applied
  python3 sqlite/query.py lifecycle --param natural_key='hrp|17643792|005056a3-53e2-1fd1-adac-d57ca848f40b'
  python3 sqlite/query.py content_history --param natural_key='hrp|17643792|005056a3-53e2-1fd1-adac-d57ca848f40b'
  python3 sqlite/query.py field_trends
  python3 sqlite/query.py platform_summary
  python3 sqlite/query.py stats --tsv

Any :param placeholder used in the .sql file can be bound with --param name=value.
"""
from __future__ import annotations

import argparse
import os
import re
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
QUERIES_DIR = HERE / "queries"
DEFAULT_DB = HERE / "jobs.db"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("query", help="query name (file in sqlite/queries/ without .sql)")
    ap.add_argument("--db", type=Path, default=DEFAULT_DB, help="sqlite database path")
    ap.add_argument("--param", action="append", default=[], metavar="name=value",
                    help="bind a named query parameter; repeatable")
    ap.add_argument("--limit", type=int, default=None, help="cap result rows")
    ap.add_argument("--tsv", action="store_true", help="raw tab-separated output (no alignment)")
    args = ap.parse_args()

    qpath = QUERIES_DIR / f"{args.query}.sql"
    if not qpath.exists():
        print(f"No such query: {args.query} (looked in {qpath})", file=sys.stderr)
        return 2
    sql = qpath.read_text()

    params: dict[str, str | int] = {}
    for kv in args.param:
        k, _, v = kv.partition("=")
        if not k:
            print(f"Bad --param '{kv}' (expected name=value)", file=sys.stderr)
            return 2
        params[k] = int(v) if v.lstrip("-").isdigit() else v
    # any placeholder not supplied gets bound to empty string (makes optional filters work)
    for m in re.findall(r":(\w+)", sql):
        params.setdefault(m, "")
    if "q" in re.findall(r":(\w+)", sql) and not params.get("q"):
        print("This query needs --param q='<some text>'", file=sys.stderr)
        return 2

    if args.limit is not None:
        sql = sql.rstrip().rstrip(';')  # drop trailing ';' so wrapping stays valid
        sql = f"SELECT * FROM (\n{sql}\n) AS _limited LIMIT {int(args.limit)}"

    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(sql, params).fetchall()
    except sqlite3.Error as e:
        print(f"Query failed: {e}", file=sys.stderr)
        print("Missing a --param? Query declares:", [m for m in re.findall(r":\w+", sql)], file=sys.stderr)
        return 1

    if not rows:
        print("(no rows)")
        return 0

    cols = rows[0].keys()
    if args.tsv:
        print("\t".join(cols))
        for r in rows:
            print("\t".join("" if v is None else str(v) for v in r))
        return 0

    # aligned table output
    width = len(cols)
    def cell(v):
        s = "" if v is None else str(v)
        return s
    widths = []
    for i in range(width):
        w = max([len(cell(r[i])) for r in rows[:500]] + [len(cols[i])])
        widths.append(w)

    def fmt(v, w):
        s = "" if v is None else str(v)
        if len(s) > 120:
            s = s[:117].rstrip() + "..."
        return s.ljust(w)[:w]

    print("  ".join(fmt(c, w) for c, w in zip(cols, widths)))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(fmt(r[i], w) for i, w in enumerate(widths)))
    print(f"\n{len(rows)} rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())