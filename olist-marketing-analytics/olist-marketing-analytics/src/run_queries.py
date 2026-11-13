"""Runs the named queries of a .sql file and prints the results.

Usage: python src/run_queries.py sql/queries/03_funnel.sql [query_name ...]
"""
import re
import sqlite3
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent


def parse(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"^-- name:\s*(\S+)\s*$", text, flags=re.M)
    return {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}


def main() -> None:
    queries = parse(Path(sys.argv[1]))
    wanted = sys.argv[2:] or list(queries)
    con = sqlite3.connect(ROOT / "data" / "olist.db")
    pd.set_option("display.width", 200, "display.max_columns", 30)
    for name in wanted:
        df = pd.read_sql_query(queries[name], con)
        print(f"\n=== {name} ({len(df)} rows)")
        print(df.to_string(index=False))


if __name__ == "__main__":
    main()
