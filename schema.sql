\set ON_ERROR_STOP on
\encoding UTF8

DROP SCHEMA IF EXISTS ecommerce CASCADE;
CREATE SCHEMA ecommerce;
SET search_path TO ecommerce;

-- ============================================================================
-- Таблицы
-- ============================================================================

CREATE TABLE ecommerce.customers (
    customer_id text,
    customer_unique_id text,
    customer_zip_code_prefix integer,
    customer_city text,
    customer_state char(2)
);

CREATE TABLE ecommerce.sellers (
    seller_id text,
    seller_zip_code_prefix integer,
    seller_city text,
    seller_state char(2)
);

CREATE TABLE ecommerce.product_categories (
    product_category_name text,
    product_category_name_english text
);

CREATE TABLE ecommerce.products (
    product_id text,
    product_category_name text,
    product_name_length integer,
    product_description_length integer,
    product_photos_qty integer,
    product_weight_g integer,
    product_length_cm integer,
    product_height_cm integer,
    product_width_cm integer
);

CREATE TABLE ecommerce.orders (
    order_id text,
    customer_id text,
    order_status text,
    order_purchase_timestamp timestamp,
    order_approved_at timestamp,
    order_delivered_carrier_date timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp
);

CREATE TABLE ecommerce.order_items (
    order_id text,
    order_item_id integer,
    product_id text,
    seller_id text,
    shipping_limit_date timestamp,
    price numeric(12, 2),
    freight_value numeric(12, 2)
);

CREATE TABLE ecommerce.order_payments (
    order_id text,
    payment_sequential integer,
    payment_type text,
    payment_installments integer,
    payment_value numeric(12, 2)
);

CREATE TABLE ecommerce.order_reviews (
    review_id text,
    order_id text,
    review_score integer,
    review_comment_title text,
    review_comment_message text,
    review_creation_date timestamp,
    review_answer_timestamp timestamp
);

CREATE TABLE ecommerce.geolocation (
    geolocation_id bigserial,
    geolocation_zip_code_prefix integer,
    geolocation_lat numeric(10, 7),
    geolocation_lng numeric(10, 7),
    geolocation_city text,
    geolocation_state char(2)
);

-- ============================================================================
-- Импорт CSV
-- ============================================================================

\copy ecommerce.customers FROM 'data/olist_customers_dataset.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.sellers FROM 'data/olist_sellers_dataset.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.product_categories FROM 'data/product_category_name_translation.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.products FROM 'data/olist_products_dataset.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.orders FROM 'data/olist_orders_dataset.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.order_items FROM 'data/olist_order_items_dataset.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.order_payments FROM 'data/olist_order_payments_dataset.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.order_reviews FROM 'data/olist_order_reviews_dataset.csv' WITH (FORMAT csv, HEADER true);
\copy ecommerce.geolocation (geolocation_zip_code_prefix, geolocation_lat, geolocation_lng, geolocation_city, geolocation_state) FROM 'data/olist_geolocation_dataset.csv' WITH (FORMAT csv, HEADER true);

-- ============================================================================
-- Нормализация перед внешними ключами
-- ============================================================================

INSERT INTO ecommerce.product_categories (product_category_name, product_category_name_english)
SELECT 'unknown', 'unknown'
WHERE NOT EXISTS (
    SELECT 1
    FROM ecommerce.product_categories
    WHERE product_category_name = 'unknown'
);

UPDATE ecommerce.products
SET product_category_name = 'unknown'
WHERE product_category_name IS NULL OR btrim(product_category_name) = '';

INSERT INTO ecommerce.product_categories (product_category_name, product_category_name_english)
SELECT DISTINCT
    p.product_category_name,
    p.product_category_name
FROM ecommerce.products AS p
LEFT JOIN ecommerce.product_categories AS pc
    ON pc.product_category_name = p.product_category_name
WHERE pc.product_category_name IS NULL;

-- ============================================================================
-- Ключи и ограничения
-- ============================================================================

ALTER TABLE ecommerce.customers
    ADD CONSTRAINT pk_customers PRIMARY KEY (customer_id);

ALTER TABLE ecommerce.sellers
    ADD CONSTRAINT pk_sellers PRIMARY KEY (seller_id);

ALTER TABLE ecommerce.product_categories
    ADD CONSTRAINT pk_product_categories PRIMARY KEY (product_category_name);

ALTER TABLE ecommerce.products
    ADD CONSTRAINT pk_products PRIMARY KEY (product_id);

ALTER TABLE ecommerce.orders
    ADD CONSTRAINT pk_orders PRIMARY KEY (order_id);

ALTER TABLE ecommerce.order_items
    ADD CONSTRAINT pk_order_items PRIMARY KEY (order_id, order_item_id);

ALTER TABLE ecommerce.order_payments
    ADD CONSTRAINT pk_order_payments PRIMARY KEY (order_id, payment_sequential);

-- review_id в датасете может повторяться, поэтому ключ составной.
ALTER TABLE ecommerce.order_reviews
    ADD CONSTRAINT pk_order_reviews PRIMARY KEY (review_id, order_id);

ALTER TABLE ecommerce.geolocation
    ADD CONSTRAINT pk_geolocation PRIMARY KEY (geolocation_id);

ALTER TABLE ecommerce.products
    ADD CONSTRAINT fk_products_category
    FOREIGN KEY (product_category_name)
    REFERENCES ecommerce.product_categories (product_category_name);

ALTER TABLE ecommerce.orders
    ADD CONSTRAINT fk_orders_customer
    FOREIGN KEY (customer_id)
    REFERENCES ecommerce.customers (customer_id);

ALTER TABLE ecommerce.order_items
    ADD CONSTRAINT fk_order_items_order
    FOREIGN KEY (order_id)
    REFERENCES ecommerce.orders (order_id);

ALTER TABLE ecommerce.order_items
    ADD CONSTRAINT fk_order_items_product
    FOREIGN KEY (product_id)
    REFERENCES ecommerce.products (product_id);

ALTER TABLE ecommerce.order_items
    ADD CONSTRAINT fk_order_items_seller
    FOREIGN KEY (seller_id)
    REFERENCES ecommerce.sellers (seller_id);

ALTER TABLE ecommerce.order_payments
    ADD CONSTRAINT fk_order_payments_order
    FOREIGN KEY (order_id)
    REFERENCES ecommerce.orders (order_id);

ALTER TABLE ecommerce.order_reviews
    ADD CONSTRAINT fk_order_reviews_order
    FOREIGN KEY (order_id)
    REFERENCES ecommerce.orders (order_id);

ALTER TABLE ecommerce.customers
    ADD CONSTRAINT chk_customers_state CHECK (customer_state ~ '^[A-Z]{2}$');

ALTER TABLE ecommerce.sellers
    ADD CONSTRAINT chk_sellers_state CHECK (seller_state ~ '^[A-Z]{2}$');

ALTER TABLE ecommerce.orders
    ADD CONSTRAINT chk_orders_status
    CHECK (order_status IN ('created', 'approved', 'invoiced', 'processing', 'shipped', 'delivered', 'canceled', 'unavailable'));

ALTER TABLE ecommerce.order_items
    ADD CONSTRAINT chk_order_items_values
    CHECK (order_item_id >= 1 AND price >= 0 AND freight_value >= 0);

ALTER TABLE ecommerce.order_payments
    ADD CONSTRAINT chk_order_payments_values
    CHECK (payment_sequential >= 1 AND payment_installments >= 0 AND payment_value >= 0);

ALTER TABLE ecommerce.order_payments
    ADD CONSTRAINT chk_order_payments_type
    CHECK (payment_type IN ('boleto', 'credit_card', 'debit_card', 'voucher', 'not_defined'));

ALTER TABLE ecommerce.order_reviews
    ADD CONSTRAINT chk_order_reviews_score CHECK (review_score BETWEEN 1 AND 5);

-- В исходных данных есть несколько странных дат. Ограничение оставлено как
-- правило для новых строк, но существующие CSV-строки не валидируются.
ALTER TABLE ecommerce.orders
    ADD CONSTRAINT chk_orders_basic_dates
    CHECK (
        order_purchase_timestamp IS NOT NULL
        AND (order_delivered_customer_date IS NULL OR order_delivered_customer_date >= order_purchase_timestamp)
        AND (order_estimated_delivery_date IS NULL OR order_estimated_delivery_date::date >= order_purchase_timestamp::date)
    )
    NOT VALID;

-- ============================================================================
-- Индексы
-- ============================================================================

CREATE INDEX idx_orders_purchase_date ON ecommerce.orders (order_purchase_timestamp);
CREATE INDEX idx_orders_status ON ecommerce.orders (order_status);
CREATE INDEX idx_customers_unique_id ON ecommerce.customers (customer_unique_id);
CREATE INDEX idx_customers_state ON ecommerce.customers (customer_state);
CREATE INDEX idx_sellers_state ON ecommerce.sellers (seller_state);
CREATE INDEX idx_products_category ON ecommerce.products (product_category_name);
CREATE INDEX idx_order_items_product ON ecommerce.order_items (product_id);
CREATE INDEX idx_order_items_seller ON ecommerce.order_items (seller_id);
CREATE INDEX idx_payments_type ON ecommerce.order_payments (payment_type);
CREATE INDEX idx_reviews_score ON ecommerce.order_reviews (review_score);

-- ============================================================================
-- Базовые аналитические представления
-- ============================================================================

CREATE OR REPLACE VIEW ecommerce.v_order_items_enriched AS
SELECT
    oi.order_id,
    oi.order_item_id,
    o.order_status,
    o.order_purchase_timestamp,
    date_trunc('month', o.order_purchase_timestamp)::date AS order_month,
    c.customer_unique_id,
    c.customer_state,
    c.customer_city,
    oi.product_id,
    COALESCE(pc.product_category_name_english, p.product_category_name, 'unknown') AS category_name,
    oi.seller_id,
    s.seller_state,
    s.seller_city,
    oi.price,
    oi.freight_value,
    CASE
        WHEN o.order_status IN ('canceled', 'unavailable') THEN false
        ELSE true
    END AS is_commercial_order
FROM ecommerce.order_items AS oi
JOIN ecommerce.orders AS o
    ON o.order_id = oi.order_id
JOIN ecommerce.customers AS c
    ON c.customer_id = o.customer_id
JOIN ecommerce.products AS p
    ON p.product_id = oi.product_id
LEFT JOIN ecommerce.product_categories AS pc
    ON pc.product_category_name = p.product_category_name
JOIN ecommerce.sellers AS s
    ON s.seller_id = oi.seller_id;

CREATE OR REPLACE VIEW ecommerce.v_order_summary AS
WITH item_summary AS (
    SELECT
        order_id,
        COUNT(*) AS items_count,
        COUNT(DISTINCT product_id) AS distinct_products,
        SUM(price) AS revenue,
        SUM(freight_value) AS freight_value
    FROM ecommerce.order_items
    GROUP BY order_id
),
payment_summary AS (
    SELECT
        order_id,
        SUM(payment_value) AS payment_value,
        MAX(payment_installments) AS max_installments
    FROM ecommerce.order_payments
    GROUP BY order_id
),
review_summary AS (
    SELECT
        order_id,
        AVG(review_score)::numeric(4, 2) AS avg_review_score,
        MIN(review_score) AS min_review_score
    FROM ecommerce.order_reviews
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.order_status,
    o.order_purchase_timestamp,
    date_trunc('month', o.order_purchase_timestamp)::date AS order_month,
    c.customer_unique_id,
    c.customer_state,
    COALESCE(i.items_count, 0) AS items_count,
    COALESCE(i.distinct_products, 0) AS distinct_products,
    COALESCE(i.revenue, 0) AS revenue,
    COALESCE(i.freight_value, 0) AS freight_value,
    COALESCE(p.payment_value, 0) AS payment_value,
    p.max_installments,
    r.avg_review_score,
    r.min_review_score,
    EXTRACT(day FROM o.order_delivered_customer_date - o.order_purchase_timestamp)::numeric AS delivery_days,
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN NULL
        ELSE o.order_delivered_customer_date > o.order_estimated_delivery_date
    END AS is_delayed,
    CASE
        WHEN o.order_status IN ('canceled', 'unavailable') THEN false
        ELSE true
    END AS is_commercial_order
FROM ecommerce.orders AS o
JOIN ecommerce.customers AS c
    ON c.customer_id = o.customer_id
LEFT JOIN item_summary AS i
    ON i.order_id = o.order_id
LEFT JOIN payment_summary AS p
    ON p.order_id = o.order_id
LEFT JOIN review_summary AS r
    ON r.order_id = o.order_id;

CREATE OR REPLACE VIEW ecommerce.v_monthly_sales AS
SELECT
    order_month,
    COUNT(DISTINCT order_id) AS orders,
    COUNT(DISTINCT customer_unique_id) AS customers,
    SUM(revenue) AS revenue,
    AVG(revenue)::numeric(12, 2) AS average_order_value,
    AVG(items_count)::numeric(12, 2) AS average_basket_size
FROM ecommerce.v_order_summary
WHERE is_commercial_order
GROUP BY order_month;

CREATE OR REPLACE VIEW ecommerce.v_customer_metrics AS
SELECT
    customer_unique_id,
    MIN(order_purchase_timestamp) AS first_order_at,
    MAX(order_purchase_timestamp) AS last_order_at,
    COUNT(DISTINCT order_id) AS order_count,
    SUM(revenue) AS customer_lifetime_value,
    AVG(revenue)::numeric(12, 2) AS average_order_value,
    AVG(items_count)::numeric(12, 2) AS average_basket_size
FROM ecommerce.v_order_summary
WHERE is_commercial_order
GROUP BY customer_unique_id;
