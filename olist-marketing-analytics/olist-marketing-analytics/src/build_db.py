"""Builds the olist.db SQLite database from the Kaggle CSV files.

Usage:
    python src/build_db.py --raw /path/to/csvs --db data/olist.db

Expects, in --raw (or its subfolders), the 9 CSVs of the "Brazilian E-Commerce
Public Dataset by Olist" and the 2 CSVs of the "Marketing Funnel by Olist".
The raw data is NOT included in the repository (see README / licences).
"""
import argparse
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent

# Translations missing from the original file (2 categories without a match)
EXTRA_TRANSLATIONS = {
    "pc_gamer": "pc_gamer",
    "portateis_cozinha_e_preparadores_de_alimentos": "portable_kitchen_food_preparers",
}

FILES = {
    "customers": "olist_customers_dataset.csv",
    "geolocation": "olist_geolocation_dataset.csv",
    "order_items": "olist_order_items_dataset.csv",
    "order_payments": "olist_order_payments_dataset.csv",
    "order_reviews": "olist_order_reviews_dataset.csv",
    "orders": "olist_orders_dataset.csv",
    "products": "olist_products_dataset.csv",
    "sellers": "olist_sellers_dataset.csv",
    "category_translation": "product_category_name_translation.csv",
    "marketing_qualified_leads": "olist_marketing_qualified_leads_dataset.csv",
    "closed_deals": "olist_closed_deals_dataset.csv",
}


def find_csv(raw: Path, name: str) -> Path:
    hits = sorted(raw.rglob(name))
    if not hits:
        raise FileNotFoundError(f"Could not find {name} in {raw}")
    return hits[0]


def load(raw: Path, key: str) -> pd.DataFrame:
    return pd.read_csv(find_csv(raw, FILES[key]))


def clean_geolocation(df: pd.DataFrame) -> pd.DataFrame:
    """One record per zip-code prefix: mean coordinates and most frequent city."""
    df = df.rename(columns={
        "geolocation_zip_code_prefix": "zip_code_prefix",
        "geolocation_lat": "lat", "geolocation_lng": "lng",
        "geolocation_city": "city", "geolocation_state": "state",
    })
    coords = df.groupby("zip_code_prefix").agg(
        lat=("lat", "mean"), lng=("lng", "mean"), n_points=("lat", "size"))
    mode = (df.groupby(["zip_code_prefix", "city", "state"]).size()
              .reset_index(name="n")
              .sort_values(["zip_code_prefix", "n"], ascending=[True, False])
              .drop_duplicates("zip_code_prefix")
              .set_index("zip_code_prefix")[["city", "state"]])
    return coords.join(mode).reset_index()


def clean_products(df: pd.DataFrame) -> pd.DataFrame:
    df = df.rename(columns={
        "product_name_lenght": "product_name_length",
        "product_description_lenght": "product_description_length",
    })
    for c in ("product_name_length", "product_description_length", "product_photos_qty"):
        df[c] = df[c].astype("Int64")
    return df


def clean_leads(df: pd.DataFrame) -> pd.DataFrame:
    # 'unknown' (text) and NaN mean the same: origin not recorded.
    df["origin"] = df["origin"].fillna("unknown")
    return df


def clean_deals(df: pd.DataFrame) -> pd.DataFrame:
    for c in ("has_company", "has_gtin"):
        df[c] = df[c].map({"true": 1, "false": 0, True: 1, False: 0}).astype("Int64")
    return df


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True, type=Path, help="folder with the CSV files")
    ap.add_argument("--db", default=ROOT / "data" / "olist.db", type=Path)
    args = ap.parse_args()

    args.db.parent.mkdir(parents=True, exist_ok=True)
    if args.db.exists():
        args.db.unlink()

    con = sqlite3.connect(args.db)
    con.executescript((ROOT / "sql" / "01_schema.sql").read_text(encoding="utf-8"))

    data = {k: load(args.raw, k) for k in FILES}
    data["geolocation"] = clean_geolocation(data["geolocation"])
    data["products"] = clean_products(data["products"])
    data["marketing_qualified_leads"] = clean_leads(data["marketing_qualified_leads"])
    data["closed_deals"] = clean_deals(data["closed_deals"])
    extra = pd.DataFrame(list(EXTRA_TRANSLATIONS.items()),
                         columns=["product_category_name", "product_category_name_english"])
    data["category_translation"] = pd.concat(
        [data["category_translation"], extra], ignore_index=True)

    # Load order respects foreign keys (parents before children)
    order = ["customers", "sellers", "category_translation", "products", "orders",
             "order_items", "order_payments", "order_reviews", "geolocation",
             "marketing_qualified_leads", "closed_deals"]
    for table in order:
        df = data[table]
        df.to_sql(table, con, if_exists="append", index=False)
        print(f"{table:<28}{len(df):>10,} rows")

    con.executescript((ROOT / "sql" / "02_views.sql").read_text(encoding="utf-8"))
    violations = con.execute("PRAGMA foreign_key_check").fetchall()
    print("\nForeign-key violations:", len(violations))
    con.commit()
    con.close()
    print(f"Database created at {args.db}")


if __name__ == "__main__":
    main()
