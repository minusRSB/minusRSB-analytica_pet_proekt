SET search_path TO ecommerce;

-- ============================================================================
-- 1. Проверки качества данных
-- ============================================================================

-- Пропуски в важных колонках.
SELECT 'orders.order_approved_at' AS check_name, COUNT(*) AS missing_rows
FROM ecommerce.orders
WHERE order_approved_at IS NULL
UNION ALL
SELECT 'orders.order_delivered_customer_date', COUNT(*)
FROM ecommerce.orders
WHERE order_delivered_customer_date IS NULL
UNION ALL
SELECT 'reviews.review_comment_message', COUNT(*)
FROM ecommerce.order_reviews
WHERE review_comment_message IS NULL OR btrim(review_comment_message) = ''
UNION ALL
SELECT 'products.product_category_name', COUNT(*)
FROM ecommerce.products
WHERE product_category_name IS NULL OR product_category_name = 'unknown';

-- Дубли по основным бизнес-ключам.
WITH duplicate_checks AS (
    SELECT 'customers.customer_id' AS check_name, customer_id AS key_value, COUNT(*) AS rows_count
    FROM ecommerce.customers
    GROUP BY customer_id
    HAVING COUNT(*) > 1

    UNION ALL

    SELECT 'orders.order_id', order_id, COUNT(*)
    FROM ecommerce.orders
    GROUP BY order_id
    HAVING COUNT(*) > 1

    UNION ALL

    SELECT 'products.product_id', product_id, COUNT(*)
    FROM ecommerce.products
    GROUP BY product_id
    HAVING COUNT(*) > 1
)
SELECT check_name, COUNT(*) AS duplicated_keys
FROM duplicate_checks
GROUP BY check_name;

-- Невалидные цены и платежи.
SELECT 'order_items.price' AS check_name, COUNT(*) AS invalid_rows
FROM ecommerce.order_items
WHERE price < 0
UNION ALL
SELECT 'order_items.freight_value', COUNT(*)
FROM ecommerce.order_items
WHERE freight_value < 0
UNION ALL
SELECT 'order_payments.payment_value', COUNT(*)
FROM ecommerce.order_payments
WHERE payment_value < 0;

-- Странные даты в жизненном цикле заказа.
SELECT
    COUNT(*) FILTER (WHERE order_approved_at < order_purchase_timestamp) AS approved_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_carrier_date < order_purchase_timestamp) AS carrier_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_customer_date < order_purchase_timestamp) AS delivered_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_customer_date > order_estimated_delivery_date) AS delayed_orders
FROM ecommerce.orders;

-- Orphan-записи после загрузки.
SELECT 'orders_without_customer' AS check_name, COUNT(*) AS orphan_rows
FROM ecommerce.orders AS o
LEFT JOIN ecommerce.customers AS c
    ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'items_without_order', COUNT(*)
FROM ecommerce.order_items AS oi
LEFT JOIN ecommerce.orders AS o
    ON o.order_id = oi.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'payments_without_order', COUNT(*)
FROM ecommerce.order_payments AS p
LEFT JOIN ecommerce.orders AS o
    ON o.order_id = p.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'reviews_without_order', COUNT(*)
FROM ecommerce.order_reviews AS r
LEFT JOIN ecommerce.orders AS o
    ON o.order_id = r.order_id
WHERE o.order_id IS NULL;

-- Категории товаров без нормального английского названия.
SELECT
    p.product_category_name,
    COUNT(*) AS products_count
FROM ecommerce.products AS p
LEFT JOIN ecommerce.product_categories AS pc
    ON pc.product_category_name = p.product_category_name
WHERE pc.product_category_name_english IS NULL
   OR pc.product_category_name_english = p.product_category_name
GROUP BY p.product_category_name
ORDER BY products_count DESC;

-- ============================================================================
-- 2. KPI
-- ============================================================================

-- Основные KPI проекта.
WITH base AS (
    SELECT *
    FROM ecommerce.v_order_summary
    WHERE is_commercial_order
)
SELECT
    SUM(revenue) AS revenue,
    COUNT(DISTINCT order_id) AS orders,
    ROUND(SUM(revenue) / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS average_order_value,
    COUNT(DISTINCT customer_unique_id) AS customers,
    COUNT(DISTINCT customer_unique_id) FILTER (WHERE customer_unique_id IN (
        SELECT customer_unique_id
        FROM base
        GROUP BY customer_unique_id
        HAVING COUNT(DISTINCT order_id) > 1
    )) AS repeat_customers,
    ROUND(
        COUNT(DISTINCT customer_unique_id) FILTER (WHERE customer_unique_id IN (
            SELECT customer_unique_id
            FROM base
            GROUP BY customer_unique_id
            HAVING COUNT(DISTINCT order_id) > 1
        ))::numeric / NULLIF(COUNT(DISTINCT customer_unique_id), 0),
        4
    ) AS customer_retention_rate,
    ROUND(AVG(delivery_days) FILTER (WHERE delivery_days IS NOT NULL), 2) AS average_delivery_time_days,
    ROUND(AVG(avg_review_score), 2) AS average_review_score
FROM base;

-- ============================================================================
-- 3. Продажи
-- ============================================================================

-- Месячная выручка, заказы, средний чек и динамика MoM.
WITH RECURSIVE bounds AS (
    SELECT
        MIN(order_month) AS min_month,
        MAX(order_month) AS max_month
    FROM ecommerce.v_monthly_sales
),
month_spine AS (
    SELECT min_month AS order_month
    FROM bounds

    UNION ALL

    SELECT (order_month + INTERVAL '1 month')::date
    FROM month_spine, bounds
    WHERE order_month < bounds.max_month
),
monthly AS (
    SELECT
        ms.order_month,
        COALESCE(v.orders, 0) AS orders,
        COALESCE(v.revenue, 0) AS revenue,
        COALESCE(v.average_order_value, 0) AS average_order_value
    FROM month_spine AS ms
    LEFT JOIN ecommerce.v_monthly_sales AS v
        ON v.order_month = ms.order_month
)
SELECT
    order_month,
    orders,
    revenue,
    average_order_value,
    LAG(revenue) OVER (ORDER BY order_month) AS previous_month_revenue,
    LEAD(revenue) OVER (ORDER BY order_month) AS next_month_revenue,
    revenue - LAG(revenue) OVER (ORDER BY order_month) AS revenue_mom_change,
    CASE
        WHEN revenue > LAG(revenue) OVER (ORDER BY order_month) THEN 'growth'
        WHEN revenue < LAG(revenue) OVER (ORDER BY order_month) THEN 'decline'
        WHEN LAG(revenue) OVER (ORDER BY order_month) IS NULL THEN 'first_month'
        ELSE 'flat'
    END AS revenue_trend
FROM monthly
ORDER BY order_month;

-- Выручка по категориям.
SELECT
    category_name,
    COUNT(DISTINCT order_id) AS orders,
    COUNT(*) AS units_sold,
    SUM(price) AS revenue,
    AVG(price)::numeric(12, 2) AS average_product_price,
    RANK() OVER (ORDER BY SUM(price) DESC) AS revenue_rank
FROM ecommerce.v_order_items_enriched
WHERE is_commercial_order
GROUP BY category_name
ORDER BY revenue DESC;

-- Выручка по штатам.
SELECT
    customer_state,
    COUNT(DISTINCT order_id) AS orders,
    COUNT(DISTINCT customer_unique_id) AS customers,
    SUM(price) AS revenue,
    ROUND(SUM(price) / NULLIF(COUNT(DISTINCT order_id), 0), 2) AS average_order_value,
    DENSE_RANK() OVER (ORDER BY SUM(price) DESC) AS state_rank
FROM ecommerce.v_order_items_enriched
WHERE is_commercial_order
GROUP BY customer_state
ORDER BY revenue DESC;

-- Топ продавцов.
SELECT
    seller_id,
    seller_state,
    seller_city,
    COUNT(DISTINCT order_id) AS orders,
    COUNT(*) AS units_sold,
    SUM(price) AS revenue,
    RANK() OVER (ORDER BY SUM(price) DESC) AS seller_rank
FROM ecommerce.v_order_items_enriched
WHERE is_commercial_order
GROUP BY seller_id, seller_state, seller_city
ORDER BY revenue DESC
LIMIT 20;

-- ============================================================================
-- 4. Клиенты
-- ============================================================================

-- Повторные клиенты и CLV.
SELECT
    COUNT(*) AS customers,
    COUNT(*) FILTER (WHERE order_count > 1) AS repeat_customers,
    ROUND(COUNT(*) FILTER (WHERE order_count > 1)::numeric / NULLIF(COUNT(*), 0), 4) AS repeat_customer_rate,
    AVG(customer_lifetime_value)::numeric(12, 2) AS average_clv,
    MAX(customer_lifetime_value) AS max_clv
FROM ecommerce.v_customer_metrics;

-- Топ клиентов по lifetime value.
SELECT
    customer_unique_id,
    order_count,
    customer_lifetime_value,
    average_order_value,
    average_basket_size,
    RANK() OVER (ORDER BY customer_lifetime_value DESC) AS clv_rank
FROM ecommerce.v_customer_metrics
ORDER BY customer_lifetime_value DESC
LIMIT 20;

-- Cohort analysis по месяцу первой покупки.
WITH customer_orders AS (
    SELECT
        customer_unique_id,
        order_id,
        order_month,
        MIN(order_month) OVER (PARTITION BY customer_unique_id) AS cohort_month
    FROM ecommerce.v_order_summary
    WHERE is_commercial_order
),
cohort_activity AS (
    SELECT
        cohort_month,
        order_month,
        (
            DATE_PART('year', AGE(order_month, cohort_month)) * 12
            + DATE_PART('month', AGE(order_month, cohort_month))
        )::integer AS month_number,
        COUNT(DISTINCT customer_unique_id) AS active_customers
    FROM customer_orders
    GROUP BY cohort_month, order_month
),
cohort_size AS (
    SELECT
        cohort_month,
        active_customers AS cohort_customers
    FROM cohort_activity
    WHERE month_number = 0
)
SELECT
    ca.cohort_month,
    ca.month_number,
    cs.cohort_customers,
    ca.active_customers,
    ROUND(ca.active_customers::numeric / NULLIF(cs.cohort_customers, 0), 4) AS retention_rate
FROM cohort_activity AS ca
JOIN cohort_size AS cs
    ON cs.cohort_month = ca.cohort_month
ORDER BY ca.cohort_month, ca.month_number;

-- Средний размер корзины.
SELECT
    order_month,
    AVG(items_count)::numeric(12, 2) AS average_basket_size,
    AVG(distinct_products)::numeric(12, 2) AS average_distinct_products
FROM ecommerce.v_order_summary
WHERE is_commercial_order
GROUP BY order_month
ORDER BY order_month;

-- ============================================================================
-- 5. Товары
-- ============================================================================

-- Best selling и worst selling products.
WITH product_sales AS (
    SELECT
        product_id,
        category_name,
        COUNT(*) AS units_sold,
        COUNT(DISTINCT order_id) AS orders,
        SUM(price) AS revenue,
        AVG(price)::numeric(12, 2) AS average_price
    FROM ecommerce.v_order_items_enriched
    WHERE is_commercial_order
    GROUP BY product_id, category_name
),
ranked AS (
    SELECT
        *,
        RANK() OVER (ORDER BY units_sold DESC, revenue DESC) AS best_rank,
        RANK() OVER (ORDER BY units_sold ASC, revenue ASC) AS worst_rank
    FROM product_sales
)
SELECT 'best_selling' AS segment, best_rank AS rank, product_id, category_name, units_sold, orders, revenue, average_price
FROM ranked
WHERE best_rank <= 10
UNION ALL
SELECT 'worst_selling' AS segment, worst_rank AS rank, product_id, category_name, units_sold, orders, revenue, average_price
FROM ranked
WHERE worst_rank <= 10
ORDER BY segment, rank;

-- Категории с лучшим margin proxy: товарная выручка минус доставка.
SELECT
    category_name,
    SUM(price) AS revenue,
    SUM(freight_value) AS freight_value,
    SUM(price - freight_value) AS margin_proxy,
    ROUND(SUM(price - freight_value) / NULLIF(SUM(price), 0), 4) AS margin_proxy_rate
FROM ecommerce.v_order_items_enriched
WHERE is_commercial_order
GROUP BY category_name
ORDER BY margin_proxy DESC;

-- ============================================================================
-- 6. Доставка и отзывы
-- ============================================================================

-- Среднее время доставки и просрочки по штатам.
SELECT
    customer_state,
    COUNT(*) FILTER (WHERE delivery_days IS NOT NULL) AS delivered_orders,
    AVG(delivery_days)::numeric(12, 2) AS average_delivery_days,
    COUNT(*) FILTER (WHERE is_delayed) AS delayed_orders,
    ROUND(COUNT(*) FILTER (WHERE is_delayed)::numeric / NULLIF(COUNT(*) FILTER (WHERE delivery_days IS NOT NULL), 0), 4) AS delayed_rate
FROM ecommerce.v_order_summary
WHERE is_commercial_order
GROUP BY customer_state
ORDER BY delayed_rate DESC NULLS LAST;

-- Связь времени доставки и review score.
SELECT
    CASE
        WHEN delivery_days <= 3 THEN '00-03 days'
        WHEN delivery_days <= 7 THEN '04-07 days'
        WHEN delivery_days <= 14 THEN '08-14 days'
        WHEN delivery_days <= 30 THEN '15-30 days'
        ELSE '31+ days'
    END AS delivery_bucket,
    COUNT(*) AS reviewed_orders,
    AVG(avg_review_score)::numeric(12, 2) AS average_review_score,
    COUNT(*) FILTER (WHERE avg_review_score <= 2) AS negative_reviews
FROM ecommerce.v_order_summary
WHERE delivery_days IS NOT NULL
  AND avg_review_score IS NOT NULL
GROUP BY delivery_bucket
ORDER BY delivery_bucket;

-- Review score by category.
SELECT
    i.category_name,
    COUNT(DISTINCT i.order_id) AS reviewed_orders,
    AVG(r.review_score)::numeric(12, 2) AS average_review_score,
    COUNT(*) FILTER (WHERE r.review_score <= 2) AS negative_reviews
FROM ecommerce.v_order_items_enriched AS i
JOIN ecommerce.order_reviews AS r
    ON r.order_id = i.order_id
WHERE i.is_commercial_order
GROUP BY i.category_name
ORDER BY average_review_score ASC;

-- Простая диагностика негативных отзывов.
SELECT
    CASE
        WHEN is_delayed THEN 'delayed_delivery'
        WHEN delivery_days > 14 THEN 'long_delivery'
        WHEN revenue >= 500 THEN 'high_value_order'
        WHEN items_count >= 3 THEN 'large_basket'
        ELSE 'other'
    END AS possible_reason,
    COUNT(*) AS negative_orders,
    AVG(avg_review_score)::numeric(12, 2) AS average_review_score
FROM ecommerce.v_order_summary
WHERE avg_review_score <= 2
GROUP BY possible_reason
ORDER BY negative_orders DESC;

-- ============================================================================
-- 7. Платежи
-- ============================================================================

-- Распределение способов оплаты.
SELECT
    payment_type,
    COUNT(*) AS payment_rows,
    COUNT(DISTINCT order_id) AS orders,
    SUM(payment_value) AS payment_value,
    ROUND(SUM(payment_value) / NULLIF(SUM(SUM(payment_value)) OVER (), 0), 4) AS payment_value_share,
    RANK() OVER (ORDER BY SUM(payment_value) DESC) AS payment_rank
FROM ecommerce.order_payments
GROUP BY payment_type
ORDER BY payment_value DESC;

-- Анализ рассрочек.
SELECT
    payment_installments,
    COUNT(*) AS payment_rows,
    COUNT(DISTINCT order_id) AS orders,
    SUM(payment_value) AS payment_value,
    AVG(payment_value)::numeric(12, 2) AS average_payment_value
FROM ecommerce.order_payments
GROUP BY payment_installments
ORDER BY payment_installments;
