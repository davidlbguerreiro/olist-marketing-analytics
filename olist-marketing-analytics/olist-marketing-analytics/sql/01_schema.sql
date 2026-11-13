-- =====================================================================
-- Olist Marketing & E-Commerce Analytics: relational schema (SQLite)
-- Dates are stored as ISO-8601 TEXT ('YYYY-MM-DD HH:MM:SS'), SQLite's native
-- format, compatible with date(), strftime() and julianday().
-- =====================================================================
PRAGMA foreign_keys = ON;

-- ---------- Marketplace -----------------------------------------------
CREATE TABLE customers (
    customer_id              TEXT PRIMARY KEY,   -- changes with every order
    customer_unique_id       TEXT NOT NULL,      -- identifies the person
    customer_zip_code_prefix INTEGER,
    customer_city            TEXT,
    customer_state           TEXT
);

CREATE TABLE sellers (
    seller_id              TEXT PRIMARY KEY,
    seller_zip_code_prefix INTEGER,
    seller_city            TEXT,
    seller_state           TEXT
);

CREATE TABLE category_translation (
    product_category_name         TEXT PRIMARY KEY,
    product_category_name_english TEXT NOT NULL
);

CREATE TABLE products (
    product_id                 TEXT PRIMARY KEY,
    product_category_name      TEXT,
    product_name_length        INTEGER,          -- original: product_name_lenght
    product_description_length INTEGER,          -- original: product_description_lenght
    product_photos_qty         INTEGER,
    product_weight_g           REAL,
    product_length_cm          REAL,
    product_height_cm          REAL,
    product_width_cm           REAL
);

CREATE TABLE orders (
    order_id                      TEXT PRIMARY KEY,
    customer_id                   TEXT NOT NULL REFERENCES customers(customer_id),
    order_status                  TEXT NOT NULL,
    order_purchase_timestamp      TEXT NOT NULL,
    order_approved_at             TEXT,
    order_delivered_carrier_date  TEXT,
    order_delivered_customer_date TEXT,
    order_estimated_delivery_date TEXT
);

CREATE TABLE order_items (
    order_id            TEXT    NOT NULL REFERENCES orders(order_id),
    order_item_id       INTEGER NOT NULL,
    product_id          TEXT    NOT NULL REFERENCES products(product_id),
    seller_id           TEXT    NOT NULL REFERENCES sellers(seller_id),
    shipping_limit_date TEXT,
    price               REAL    NOT NULL,
    freight_value       REAL    NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE order_payments (
    order_id             TEXT    NOT NULL REFERENCES orders(order_id),
    payment_sequential   INTEGER NOT NULL,
    payment_type         TEXT,
    payment_installments INTEGER,
    payment_value        REAL,
    PRIMARY KEY (order_id, payment_sequential)
);

-- review_id is NOT unique in the source data (some reviews repeat across
-- orders), so the primary key is composite.
CREATE TABLE order_reviews (
    review_id               TEXT NOT NULL,
    order_id                TEXT NOT NULL REFERENCES orders(order_id),
    review_score            INTEGER NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TEXT,
    review_answer_timestamp TEXT,
    PRIMARY KEY (review_id, order_id)
);

-- Aggregated by zip-code prefix (the source has ~1 M rows, 26 % of them
-- duplicates, with many points per prefix).
CREATE TABLE geolocation (
    zip_code_prefix INTEGER PRIMARY KEY,
    lat             REAL,
    lng             REAL,
    city            TEXT,
    state           TEXT,
    n_points        INTEGER
);

-- ---------- Marketing funnel (Marketing Funnel by Olist) ---------------
CREATE TABLE marketing_qualified_leads (
    mql_id             TEXT PRIMARY KEY,
    first_contact_date TEXT NOT NULL,
    landing_page_id    TEXT,
    origin             TEXT                      -- NULL and 'unknown' merged into 'unknown'
);

CREATE TABLE closed_deals (
    mql_id                        TEXT PRIMARY KEY REFERENCES marketing_qualified_leads(mql_id),
    seller_id                     TEXT NOT NULL,   -- links to sellers, but only 380 of 842 have sales
    sdr_id                        TEXT,
    sr_id                         TEXT,
    won_date                      TEXT NOT NULL,
    business_segment              TEXT,
    lead_type                     TEXT,
    lead_behaviour_profile        TEXT,
    has_company                   INTEGER,         -- 0/1
    has_gtin                      INTEGER,         -- 0/1
    average_stock                 TEXT,
    business_type                 TEXT,
    declared_product_catalog_size REAL,
    declared_monthly_revenue      REAL
);

-- ---------- Indexes supporting the analytical queries -------------------
CREATE INDEX idx_customers_unique   ON customers(customer_unique_id);
CREATE INDEX idx_orders_customer    ON orders(customer_id);
CREATE INDEX idx_orders_purchase    ON orders(order_purchase_timestamp);
CREATE INDEX idx_items_product      ON order_items(product_id);
CREATE INDEX idx_items_seller       ON order_items(seller_id);
CREATE INDEX idx_reviews_order      ON order_reviews(order_id);
CREATE INDEX idx_deals_seller       ON closed_deals(seller_id);
CREATE INDEX idx_mql_origin         ON marketing_qualified_leads(origin);
