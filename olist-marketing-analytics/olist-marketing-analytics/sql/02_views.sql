-- =====================================================================
-- Analytical views. Business rules are centralised here so that every
-- query and the notebook share the same definitions.
-- =====================================================================

DROP VIEW IF EXISTS v_order_items_enriched;
DROP VIEW IF EXISTS v_orders_delivered;
DROP VIEW IF EXISTS v_funnel;
DROP VIEW IF EXISTS v_funnel_cohort;

-- One row per order item, with the English category and the seller's geography.
CREATE VIEW v_order_items_enriched AS
SELECT
    oi.order_id,
    oi.order_item_id,
    oi.product_id,
    oi.seller_id,
    oi.price,
    oi.freight_value,
    COALESCE(ct.product_category_name_english, p.product_category_name, 'unknown')
        AS category,
    s.seller_state,
    s.seller_city
FROM order_items oi
JOIN products p              ON p.product_id = oi.product_id
LEFT JOIN category_translation ct ON ct.product_category_name = p.product_category_name
JOIN sellers s               ON s.seller_id = oi.seller_id;

-- One row per DELIVERED order (with a recorded delivery date).
-- Items, payments and reviews are aggregated BEFORE the join so rows are not
-- duplicated (an order can have several items, payments and reviews).
CREATE VIEW v_orders_delivered AS
WITH items AS (
    SELECT order_id,
           COUNT(*)           AS n_items,
           SUM(price)         AS items_value,
           SUM(freight_value) AS freight_value
    FROM order_items
    GROUP BY order_id
),
pay AS (
    SELECT order_id,
           SUM(payment_value)        AS payment_value,
           MAX(payment_installments) AS max_installments,
           -- payment type with the highest value in the order
           (SELECT p2.payment_type FROM order_payments p2
             WHERE p2.order_id = op.order_id
             ORDER BY p2.payment_value DESC LIMIT 1) AS main_payment_type
    FROM order_payments op
    GROUP BY order_id
),
rev AS (
    -- most recent review per order
    SELECT order_id, review_score
    FROM (
        SELECT order_id, review_score,
               ROW_NUMBER() OVER (PARTITION BY order_id
                                  ORDER BY review_answer_timestamp DESC) AS rn
        FROM order_reviews
    )
    WHERE rn = 1
)
SELECT
    o.order_id,
    c.customer_unique_id,
    c.customer_state,
    c.customer_city,
    o.order_purchase_timestamp,
    strftime('%Y-%m', o.order_purchase_timestamp)                      AS purchase_month,
    i.n_items,
    i.items_value,
    i.freight_value,
    pay.payment_value,
    pay.max_installments,
    pay.main_payment_type,
    rev.review_score,
    julianday(o.order_delivered_customer_date)
      - julianday(o.order_purchase_timestamp)                          AS delivery_days,
    julianday(o.order_delivered_customer_date)
      - julianday(o.order_estimated_delivery_date)                     AS delay_days,
    CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
         THEN 1 ELSE 0 END                                             AS is_late
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN items i     ON i.order_id    = o.order_id
LEFT JOIN pay    ON pay.order_id  = o.order_id
LEFT JOIN rev    ON rev.order_id  = o.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL;

-- One row per lead (MQL), with the closed deal and the seller's sales on the
-- marketplace (delivered orders only). seller_id is NULL for leads that did
-- not close.
CREATE VIEW v_funnel AS
WITH seller_sales AS (
    SELECT oi.seller_id,
           COUNT(DISTINCT oi.order_id) AS orders,
           SUM(oi.price)               AS revenue,
           MIN(o.order_purchase_timestamp) AS first_sale_date
    FROM order_items oi
    JOIN orders o ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY oi.seller_id
)
SELECT
    m.mql_id,
    m.first_contact_date,
    strftime('%Y-%m', m.first_contact_date) AS contact_month,
    m.landing_page_id,
    m.origin,
    CASE WHEN d.mql_id IS NOT NULL THEN 1 ELSE 0 END AS is_won,
    d.won_date,
    CAST(julianday(d.won_date) - julianday(m.first_contact_date) AS INTEGER)
                                             AS days_to_close,
    d.seller_id,
    d.business_segment,
    d.lead_type,
    d.business_type,
    d.declared_monthly_revenue,
    COALESCE(ss.orders, 0)                   AS seller_orders,
    COALESCE(ss.revenue, 0)                  AS seller_revenue,
    ss.first_sale_date,
    CASE WHEN ss.seller_id IS NOT NULL THEN 1 ELSE 0 END AS seller_has_sales
FROM marketing_qualified_leads m
LEFT JOIN closed_deals d  ON d.mql_id    = m.mql_id
LEFT JOIN seller_sales ss ON ss.seller_id = d.seller_id;

-- Comparable funnel cohort: leads contacted between 2018-01-01 and 2018-05-31.
-- Why: closed_deals only contains deals closed from 2017-12-05 onwards, so 2017
-- leads look artificially bad (2-5 % conversion vs 12-15 % in 2018). Leads from
-- Jan-May 2018 had >= 5 months until the end of the data (max won_date
-- 2018-11-14), enough for the vast majority to close (median 15 days,
-- p90 ~126 days).
CREATE VIEW v_funnel_cohort AS
SELECT * FROM v_funnel
WHERE first_contact_date >= '2018-01-01';
