-- =====================================================================
-- Acquisition funnel: analytical queries (SQLite)
-- All use v_funnel_cohort (leads contacted Jan-May 2018), see 02_views.sql.
-- Revenue is GMV (item price of delivered orders), not Olist's commission.
-- =====================================================================

-- name: q1_channel_conversion
-- Question: which channels bring leads that close, and how fast?
WITH leads AS (
    SELECT origin, is_won, days_to_close FROM v_funnel_cohort
),
agg AS (
    SELECT origin, COUNT(*) AS leads, SUM(is_won) AS won
    FROM leads GROUP BY origin
),
won AS (
    SELECT origin, days_to_close,
           ROW_NUMBER() OVER (PARTITION BY origin ORDER BY days_to_close) AS rn,
           COUNT(*)     OVER (PARTITION BY origin)                        AS cnt
    FROM leads WHERE is_won = 1
),
med AS (   -- median (SQLite has no MEDIAN)
    SELECT origin, AVG(days_to_close) AS median_days_to_close
    FROM won WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
    GROUP BY origin
)
SELECT a.origin,
       a.leads,
       ROUND(100.0 * a.leads / SUM(a.leads) OVER (), 1) AS pct_of_leads,
       a.won,
       ROUND(100.0 * a.won   / SUM(a.won)   OVER (), 1) AS pct_of_won,
       ROUND(100.0 * a.won / a.leads, 1)                AS conv_pct,
       m.median_days_to_close,
       CASE WHEN a.won < 20 THEN 'small sample (<20 deals)' ELSE '' END AS warning
FROM agg a LEFT JOIN med m USING (origin)
ORDER BY a.leads DESC;

-- name: q2_value_per_lead
-- Question: how much value does each lead generate, by channel? (conversion + activation + revenue)
SELECT origin,
       COUNT(*)                                                       AS leads,
       SUM(is_won)                                                    AS won,
       SUM(seller_has_sales)                                          AS won_with_sales,
       ROUND(100.0 * SUM(seller_has_sales) / NULLIF(SUM(is_won), 0), 1) AS activation_pct,
       ROUND(SUM(seller_revenue))                                     AS revenue,
       ROUND(SUM(seller_revenue) / COUNT(*), 1)                       AS revenue_per_lead,
       ROUND(SUM(seller_revenue) / NULLIF(SUM(is_won), 0))            AS revenue_per_won
FROM v_funnel_cohort
GROUP BY origin
ORDER BY revenue_per_lead DESC;

-- name: q3_segment_revenue
-- Question: which business segments generate the revenue? (Pareto with window functions)
WITH seg AS (
    SELECT COALESCE(business_segment, 'unknown') AS segment,
           COUNT(*)              AS deals,
           SUM(seller_has_sales) AS with_sales,
           SUM(seller_revenue)   AS revenue
    FROM v_funnel_cohort
    WHERE is_won = 1
    GROUP BY 1
)
SELECT segment, deals, with_sales,
       ROUND(revenue)                                    AS revenue,
       ROUND(revenue / deals)                            AS revenue_per_deal,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 1)  AS pct_revenue,
       ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC
                                        ROWS UNBOUNDED PRECEDING)
                   / SUM(revenue) OVER (), 1)            AS cum_pct_revenue
FROM seg
ORDER BY revenue DESC;

-- name: q4_monthly_channel_trend
-- Question: how do mix, conversion and ranking of the main channels evolve month by month?
WITH m AS (
    SELECT contact_month, origin, COUNT(*) AS leads, SUM(is_won) AS won
    FROM v_funnel_cohort GROUP BY 1, 2
),
main AS (   -- only channels with relevant volume in the cohort
    SELECT origin FROM v_funnel_cohort GROUP BY origin HAVING COUNT(*) >= 300
)
SELECT contact_month, origin, leads, won,
       ROUND(100.0 * won / leads, 1)                                         AS conv_pct,
       ROUND(100.0 * leads / SUM(leads) OVER (PARTITION BY contact_month), 1) AS pct_of_month_leads,
       RANK() OVER (PARTITION BY contact_month ORDER BY 1.0 * won / leads DESC) AS conv_rank,
       SUM(won) OVER (PARTITION BY origin ORDER BY contact_month
                      ROWS UNBOUNDED PRECEDING)                               AS cum_won
FROM m
WHERE origin IN (SELECT origin FROM main)
ORDER BY contact_month, leads DESC;

-- name: q5_landing_pages
-- Question: which landing pages convert above/below average? (min. 30 leads)
WITH lp AS (
    SELECT landing_page_id, COUNT(*) AS leads, SUM(is_won) AS won,
           SUM(seller_revenue) AS revenue
    FROM v_funnel_cohort
    GROUP BY landing_page_id
    HAVING COUNT(*) >= 30
),
tot AS (SELECT 100.0 * SUM(is_won) / COUNT(*) AS avg_conv FROM v_funnel_cohort)
SELECT substr(landing_page_id, 1, 8)                       AS landing_page,
       leads, won,
       ROUND(100.0 * won / leads, 1)                        AS conv_pct,
       ROUND(100.0 * won / leads - avg_conv, 1)             AS vs_avg_pp,
       ROUND(revenue)                                       AS seller_revenue,
       RANK()  OVER (ORDER BY 1.0 * won / leads DESC)       AS conv_rank,
       NTILE(4) OVER (ORDER BY 1.0 * won / leads DESC)      AS quartile
FROM lp, tot
ORDER BY conv_rank;

-- name: q6_time_to_first_sale
-- Question: how long does a recruited seller take to make a first sale?
WITH d AS (
    SELECT origin,
           julianday(first_sale_date) - julianday(won_date) AS days,
           ROW_NUMBER() OVER (PARTITION BY origin
                              ORDER BY julianday(first_sale_date) - julianday(won_date)) AS rn,
           COUNT(*) OVER (PARTITION BY origin) AS cnt
    FROM v_funnel_cohort
    WHERE seller_has_sales = 1
)
SELECT origin,
       cnt                          AS activated_sellers,
       ROUND(AVG(days), 1)          AS median_days_won_to_first_sale
FROM d
WHERE rn IN ((cnt + 1) / 2, (cnt + 2) / 2)
GROUP BY origin, cnt
ORDER BY cnt DESC;

-- name: q7_revenue_concentration
-- Question: is the revenue of recruited sellers concentrated in a few? (Pareto by seller)
WITH s AS (
    SELECT origin, business_segment, seller_revenue AS revenue
    FROM v_funnel_cohort WHERE seller_revenue > 0
),
r AS (
    SELECT origin, business_segment, revenue,
           ROW_NUMBER() OVER (ORDER BY revenue DESC)                              AS seller_rank,
           SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)     AS cum_rev,
           SUM(revenue) OVER ()                                                   AS total,
           COUNT(*)     OVER ()                                                   AS n
    FROM s
)
SELECT seller_rank, origin, business_segment,
       ROUND(revenue)                      AS revenue,
       ROUND(100.0 * revenue / total, 1)   AS pct_of_total,
       ROUND(100.0 * cum_rev / total, 1)   AS cum_pct,
       CASE WHEN seller_rank IN (n / 10, n / 5, n / 2)
            THEN 'milestone: top ' || ROUND(100.0 * seller_rank / n) || '% of sellers' ELSE '' END AS milestone
FROM r
WHERE seller_rank <= 10 OR seller_rank IN (n / 10, n / 5, n / 2)
ORDER BY seller_rank;
