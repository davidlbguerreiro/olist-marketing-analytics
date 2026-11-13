-- =====================================================================
-- Customers and satisfaction: analytical queries (SQLite)
-- Base: v_orders_delivered (delivered orders). Revenue = item GMV (excluding
-- freight) unless stated. Customer = customer_unique_id.
-- =====================================================================

-- name: q1_monthly_overview
-- Question: how do orders, new customers and average order value evolve? (Jan 2017 - Aug 2018)
WITH first_month AS (
    SELECT customer_unique_id, MIN(purchase_month) AS first_month
    FROM v_orders_delivered GROUP BY customer_unique_id
),
m AS (
    SELECT o.purchase_month,
           COUNT(*)                                   AS orders,
           COUNT(DISTINCT o.customer_unique_id)       AS customers,
           COUNT(DISTINCT CASE WHEN f.first_month = o.purchase_month
                               THEN o.customer_unique_id END) AS new_customers,
           SUM(o.items_value)                         AS gmv
    FROM v_orders_delivered o
    JOIN first_month f USING (customer_unique_id)
    WHERE o.purchase_month BETWEEN '2017-01' AND '2018-08'
    GROUP BY o.purchase_month
)
SELECT purchase_month, orders, customers,
       ROUND(100.0 * new_customers / customers, 1)                      AS pct_new,
       ROUND(gmv)                                                       AS gmv,
       ROUND(gmv / orders, 1)                                           AS aov,
       ROUND(100.0 * (gmv - LAG(gmv) OVER (ORDER BY purchase_month))
                   / LAG(gmv) OVER (ORDER BY purchase_month), 1)        AS gmv_mom_pct,
       ROUND(AVG(gmv) OVER (ORDER BY purchase_month
                            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))  AS gmv_3m_avg
FROM m ORDER BY purchase_month;

-- name: q2_delay_vs_review
-- Question: what does a late delivery cost in satisfaction?
WITH b AS (
    SELECT review_score, delay_days,
           CASE WHEN delay_days < -7  THEN 'a) >7 days early'
                WHEN delay_days <= 0  THEN 'b) 0-7 days early (on time)'
                WHEN delay_days <= 3  THEN 'c) 1-3 days late'
                WHEN delay_days <= 7  THEN 'd) 4-7 days late'
                WHEN delay_days <= 14 THEN 'e) 8-14 days late'
                ELSE                       'f) >14 days late' END AS bucket
    FROM v_orders_delivered
    WHERE review_score IS NOT NULL
)
SELECT bucket,
       COUNT(*)                                                    AS orders,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_orders,
       ROUND(AVG(review_score), 2)                                 AS avg_score,
       ROUND(100.0 * AVG(review_score <= 2), 1)                    AS pct_1_2_stars,
       ROUND(100.0 * AVG(review_score = 5), 1)                     AS pct_5_stars
FROM b GROUP BY bucket ORDER BY bucket;

-- name: q3_state_performance
-- Question: how do states differ in volume, logistics and satisfaction?
WITH s AS (
    SELECT customer_state,
           COUNT(*)                          AS orders,
           SUM(items_value)                  AS gmv,
           SUM(freight_value)                AS freight,
           AVG(delivery_days)                AS delivery_days,
           AVG(is_late)                      AS late_rate,
           AVG(review_score)                 AS avg_score
    FROM v_orders_delivered GROUP BY customer_state
)
SELECT customer_state, orders,
       ROUND(100.0 * gmv / SUM(gmv) OVER (), 1)                         AS pct_gmv,
       ROUND(100.0 * SUM(gmv) OVER (ORDER BY gmv DESC ROWS UNBOUNDED PRECEDING)
                   / SUM(gmv) OVER (), 1)                               AS cum_pct_gmv,
       ROUND(gmv / orders, 1)                                           AS aov,
       ROUND(100.0 * freight / gmv, 1)                                  AS freight_pct_of_price,
       ROUND(delivery_days, 1)                                          AS avg_delivery_days,
       ROUND(100.0 * late_rate, 1)                                      AS late_pct,
       ROUND(avg_score, 2)                                              AS avg_score
FROM s ORDER BY gmv DESC;

-- name: q4_category_performance
-- Question: which categories sell the most and with what satisfaction? (min. 300 items; item level)
WITH i AS (
    SELECT e.category, e.price, d.review_score, d.is_late
    FROM v_order_items_enriched e
    JOIN v_orders_delivered d USING (order_id)
)
SELECT category,
       COUNT(*)                                       AS items,
       ROUND(SUM(price))                              AS revenue,
       ROUND(100.0 * SUM(price) / SUM(SUM(price)) OVER (), 1) AS pct_revenue,
       ROUND(AVG(price), 1)                           AS avg_price,
       ROUND(AVG(review_score), 2)                    AS avg_score,
       ROUND(100.0 * AVG(is_late), 1)                 AS late_pct,
       RANK() OVER (ORDER BY AVG(review_score) ASC)   AS worst_score_rank
FROM i
GROUP BY category
HAVING COUNT(*) >= 300
ORDER BY revenue DESC;

-- name: q5_repeat_vs_one_time
-- Question: how much are repeat customers worth?
WITH c AS (
    SELECT customer_unique_id, COUNT(*) AS orders, SUM(items_value) AS spend,
           AVG(review_score) AS avg_score
    FROM v_orders_delivered GROUP BY customer_unique_id
)
SELECT CASE WHEN orders = 1 THEN '1 order' ELSE '2+ orders' END AS segment,
       COUNT(*)                                            AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct_customers,
       ROUND(SUM(spend))                                   AS gmv,
       ROUND(100.0 * SUM(spend) / SUM(SUM(spend)) OVER (), 1) AS pct_gmv,
       ROUND(AVG(spend), 1)                                AS avg_spend,
       ROUND(AVG(avg_score), 2)                            AS avg_score
FROM c GROUP BY segment;

-- name: q6_customer_value_deciles
-- Question: is revenue concentrated in the best customers? (deciles by total spend)
WITH c AS (
    SELECT customer_unique_id, SUM(items_value) AS spend
    FROM v_orders_delivered GROUP BY customer_unique_id
),
d AS (SELECT spend, NTILE(10) OVER (ORDER BY spend DESC) AS decile FROM c)
SELECT decile,
       COUNT(*)                                                    AS customers,
       ROUND(MIN(spend), 1)                                        AS min_spend,
       ROUND(SUM(spend))                                           AS gmv,
       ROUND(100.0 * SUM(spend) / SUM(SUM(spend)) OVER (), 1)      AS pct_gmv,
       ROUND(100.0 * SUM(SUM(spend)) OVER (ORDER BY decile)
                   / SUM(SUM(spend)) OVER (), 1)                   AS cum_pct_gmv
FROM d GROUP BY decile ORDER BY decile;

-- name: q7_first_experience_vs_repeat
-- Question: does a bad first experience reduce repeat purchase within 180 days?
-- Only first purchases from Jan 2017 to Feb 2018 (>= 180 days of observation).
WITH o AS (
    SELECT customer_unique_id, order_purchase_timestamp AS ts, review_score, is_late,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id
                              ORDER BY order_purchase_timestamp) AS rn
    FROM v_orders_delivered
),
f AS (SELECT * FROM o WHERE rn = 1 AND ts >= '2017-01-01' AND ts < '2018-03-01'),
s AS (SELECT customer_unique_id, ts FROM o WHERE rn = 2)
SELECT CASE WHEN f.review_score IS NULL THEN 'no review'
            WHEN f.review_score <= 2    THEN '1-2 stars'
            WHEN f.review_score = 3     THEN '3 stars'
            ELSE                             '4-5 stars' END        AS first_review,
       CASE WHEN f.is_late = 1 THEN 'late' ELSE 'on time' END     AS first_delivery,
       COUNT(*)                                                         AS first_orders,
       SUM(CASE WHEN s.ts IS NOT NULL
                 AND julianday(s.ts) - julianday(f.ts) <= 180 THEN 1 ELSE 0 END) AS repeated_180d,
       ROUND(100.0 * SUM(CASE WHEN s.ts IS NOT NULL
                 AND julianday(s.ts) - julianday(f.ts) <= 180 THEN 1 ELSE 0 END) / COUNT(*), 2) AS repeat_pct
FROM f LEFT JOIN s USING (customer_unique_id)
GROUP BY first_review, first_delivery
ORDER BY first_review, first_delivery;
