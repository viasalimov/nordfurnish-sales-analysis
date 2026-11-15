-- =====================================================================
-- NordFurnish: data cleaning and analysis (BigQuery)
-- Dataset: da-nfactorial.student_alikha_salimov
--
-- How to run: execute the whole file as one script, or run one block at
-- a time. Run in this order, because later views depend on earlier ones.
--   0. Data quality check
--   1. Staging layer (cleaned views)
--   2. Analysis tasks 1 to 5
--   3. Unified table for Power BI and Python
-- =====================================================================


-- =====================================================================
-- 0. DATA QUALITY CHECK
-- Compare total rows with unique keys in each raw table.
-- =====================================================================
SELECT 'customers' AS tbl, COUNT(*) AS rows_total, COUNT(DISTINCT `Customer ID`) AS uniq_key
FROM `da-nfactorial.student_alikha_salimov.final_customers`
UNION ALL
SELECT 'orders', COUNT(*), COUNT(DISTINCT `Order ID`)
FROM `da-nfactorial.student_alikha_salimov.final_orders`
UNION ALL
SELECT 'sales', COUNT(*), COUNT(DISTINCT CONCAT(`Order ID`, '|', `Product ID`))
FROM `da-nfactorial.student_alikha_salimov.final_sales`;


-- =====================================================================
-- 1. STAGING LAYER
-- Raw tables stay untouched. Cleaned versions live as separate views.
-- =====================================================================

-- 1a. Customers: 1,754 rows but only 707 unique customers, because each
-- customer has 2 to 4 addresses. Keep one address per customer, chosen
-- by a deterministic hash. MIN(postal_code) would bias the region split,
-- because US ZIP codes are geographic.
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.final_customers_clean` AS
SELECT customer_id, customer_name, segment, country,
       city, state, postal_code, region
FROM (
  SELECT
    `Customer ID`   AS customer_id,
    `Customer Name` AS customer_name,
    `Segment`       AS segment,
    `Country`       AS country,
    `City`          AS city,
    `State`         AS state,
    `Postal Code`   AS postal_code,
    `Region`        AS region,
    ROW_NUMBER() OVER (
      PARTITION BY `Customer ID`
      ORDER BY FARM_FINGERPRINT(CONCAT(`Customer ID`, `City`, CAST(`Postal Code` AS STRING)))
    ) AS rn
  FROM `da-nfactorial.student_alikha_salimov.final_customers`
)
WHERE rn = 1;

-- 1b. Orders: rename columns and remove exact duplicate rows
-- (2,121 rows for 1,764 unique orders).
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.final_orders_clean` AS
SELECT DISTINCT
  `Order ID`    AS order_id,
  `Order Date`  AS order_date,
  `Ship Date`   AS ship_date,
  `Ship Mode`   AS ship_mode,
  `Customer ID` AS customer_id
FROM `da-nfactorial.student_alikha_salimov.final_orders`;

-- 1c. Sales: rename columns and remove the one fully duplicated row
-- (2,120 rows remain).
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.final_sales_clean` AS
SELECT DISTINCT
  `Order ID`   AS order_id,
  `Product ID` AS product_id,
  `Sales`      AS sales,
  `Quantity`   AS quantity,
  `Discount`   AS discount,
  `Profit`     AS profit
FROM `da-nfactorial.student_alikha_salimov.final_sales`;

-- 1d. Products: 8 product_id values each point to two different products.
-- Joining them to sales inflated revenue by about 3% (row fan-out).
-- Keep one row per product_id (first by product name: deterministic,
-- but the choice between the two products is arbitrary).
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.final_products_clean` AS
SELECT product_id, category, sub_category, product_name
FROM (
  SELECT
    product_id, category, sub_category, product_name,
    ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY product_name) AS rn
  FROM `da-nfactorial.student_alikha_salimov.final_products`
)
WHERE rn = 1;


-- =====================================================================
-- 2. ANALYSIS TASKS
-- =====================================================================

-- Task 1: Top 5 products by revenue.
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.task1_top_products` AS
SELECT
  p.product_id,
  p.product_name,
  SUM(s.sales) AS total_revenue
FROM `da-nfactorial.student_alikha_salimov.final_sales_clean` s
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_products_clean` p
  ON s.product_id = p.product_id
GROUP BY p.product_id, p.product_name
ORDER BY SUM(s.sales) DESC
LIMIT 5;

-- Task 2: Margin and discount by region.
-- average_discount_all counts every sale; average_discount_given counts
-- only sales that had a discount.
-- Sort by the numeric margin, not by the text column margin_pct, which
-- would sort alphabetically.
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.task2_discount_by_region` AS
SELECT
  c.region,
  SUM(s.sales)  AS total_sales,
  SUM(s.profit) AS total_profit,
  CONCAT(ROUND(SUM(s.profit) / SUM(s.sales) * 100, 2), '%') AS margin_pct,
  ROUND(AVG(s.discount), 2) AS average_discount_all,
  ROUND(AVG(IF(s.discount > 0, s.discount, NULL)), 2) AS average_discount_given
FROM `da-nfactorial.student_alikha_salimov.final_sales_clean` s
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_orders_clean` o
  ON o.order_id = s.order_id
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_customers_clean` c
  ON c.customer_id = o.customer_id
GROUP BY c.region
ORDER BY SUM(s.profit) / SUM(s.sales) DESC;

-- Task 3: Top 10 customers by number of orders (RFM-style view).
-- Recency: days since the last order, measured against the latest order
-- date in the data. Frequency: orders_count and active_years.
-- Monetary: total_sales and total_profit.
-- A customer is 'lapsed' after 365 days without an order. This cutoff is
-- a business assumption: with about 2.5 orders per customer, the data is
-- too sparse to estimate it reliably from the gaps between orders.
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.task3_loyal_customers` AS
SELECT
  c.customer_id,
  c.customer_name,
  c.segment,
  c.region,
  COUNT(DISTINCT o.order_id) AS orders_count,
  COUNT(DISTINCT EXTRACT(YEAR FROM o.order_date)) AS active_years,
  MIN(o.order_date) AS first_order,
  MAX(o.order_date) AS last_order,
  DATE_DIFF(
    (SELECT MAX(order_date) FROM `da-nfactorial.student_alikha_salimov.final_orders_clean`),
    MAX(o.order_date), DAY) AS days_since_last_order,
  ROUND(SUM(s.sales), 2)  AS total_sales,
  ROUND(SUM(s.profit), 2) AS total_profit,
  CASE
    WHEN DATE_DIFF(
           (SELECT MAX(order_date) FROM `da-nfactorial.student_alikha_salimov.final_orders_clean`),
           MAX(o.order_date), DAY) <= 365
    THEN 'active' ELSE 'lapsed'
  END AS status
FROM `da-nfactorial.student_alikha_salimov.final_sales_clean` s
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_orders_clean` o
  ON o.order_id = s.order_id
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_customers_clean` c
  ON c.customer_id = o.customer_id
GROUP BY c.customer_id, c.customer_name, c.segment, c.region
ORDER BY orders_count DESC, active_years DESC
LIMIT 10;

-- Task 4: Profit by sub-category.
-- Uses margin instead of absolute profit, and shows the share of
-- loss-making sales rows in each sub-category.
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.task4_profit_by_subcategory` AS
SELECT
  p.sub_category,
  ROUND(SUM(s.sales), 2)  AS total_sales,
  ROUND(SUM(s.profit), 2) AS total_profit,
  CONCAT(ROUND(SUM(s.profit) / SUM(s.sales) * 100, 2), '%') AS margin_pct,
  ROUND(AVG(s.discount), 3) AS avg_discount,
  SUM(s.quantity) AS total_qty,
  COUNT(*) AS sales_rows,
  CONCAT(ROUND(COUNTIF(s.profit < 0) / COUNT(*) * 100, 1), '%') AS loss_share
FROM `da-nfactorial.student_alikha_salimov.final_sales_clean` s
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_products_clean` p
  ON s.product_id = p.product_id
GROUP BY p.sub_category
ORDER BY total_profit DESC;

-- Task 5: Share of discounted sales, and profit with versus without
-- a discount.
CREATE OR REPLACE VIEW `da-nfactorial.student_alikha_salimov.task5_discount_share` AS
SELECT
  ROUND(SUM(s.sales), 2) AS total_sales,
  ROUND(SUM(IF(s.discount > 0, s.sales, NULL)), 2) AS sales_w_discount,
  ROUND(SUM(IF(s.discount > 0, s.sales, NULL)) / SUM(s.sales) * 100, 2) AS discounted_sales_pct,
  ROUND(AVG(IF(s.discount > 0, s.sales, NULL)), 2) AS avg_discounted_sales,
  ROUND(AVG(IF(s.discount = 0, s.sales, NULL)), 2) AS avg_full_sales,
  ROUND(COUNTIF(s.discount > 0) / COUNT(*) * 100, 2) AS discounted_rows_pct,
  ROUND(SUM(IF(s.discount > 0, s.profit, 0)), 2) AS profit_discounted,
  ROUND(SUM(IF(s.discount = 0, s.profit, 0)), 2) AS profit_full_price
FROM `da-nfactorial.student_alikha_salimov.final_sales_clean` s;


-- =====================================================================
-- 3. UNIFIED TABLE (Task 6)
-- All four cleaned tables joined into one analysis-ready table.
-- Used by Power BI and Python. Adds order year, month, delivery days and
-- a discount flag.
-- =====================================================================
CREATE OR REPLACE TABLE `da-nfactorial.student_alikha_salimov.orders_full` AS
SELECT
  s.order_id,
  o.order_date,
  o.ship_date,
  o.ship_mode,
  c.customer_id,
  c.customer_name,
  c.segment,
  c.city,
  c.state,
  c.region,
  p.product_id,
  p.category,
  p.sub_category,
  p.product_name,
  s.sales,
  s.quantity,
  s.discount,
  s.profit,
  EXTRACT(YEAR  FROM o.order_date) AS order_year,
  EXTRACT(MONTH FROM o.order_date) AS order_month,
  DATE_DIFF(o.ship_date, o.order_date, DAY) AS delivery_days,
  s.discount > 0 AS is_discounted
FROM `da-nfactorial.student_alikha_salimov.final_sales_clean` s
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_orders_clean` o
  ON o.order_id = s.order_id
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_customers_clean` c
  ON c.customer_id = o.customer_id
LEFT JOIN `da-nfactorial.student_alikha_salimov.final_products_clean` p
  ON p.product_id = s.product_id;

-- Export: download the result of this query as CSV (orders_full.csv).
SELECT * FROM `da-nfactorial.student_alikha_salimov.orders_full`;
