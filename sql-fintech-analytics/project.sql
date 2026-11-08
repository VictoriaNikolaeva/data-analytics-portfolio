\set ON_ERROR_STOP on
\echo 'Транзакционный и продуктовый анализ: запуск SQL-сценария'

-- ==============================================================================
-- 1. СОЗДАНИЕ СХЕМ И ТАБЛИЦ
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS marts;
CREATE SCHEMA IF NOT EXISTS synthetic;

CREATE TABLE IF NOT EXISTS raw.paysim_transactions (
    raw_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    step INTEGER,
    type TEXT,
    amount NUMERIC(20, 2),
    name_orig TEXT,
    old_balance_orig NUMERIC(20, 2),
    new_balance_orig NUMERIC(20, 2),
    name_dest TEXT,
    old_balance_dest NUMERIC(20, 2),
    new_balance_dest NUMERIC(20, 2),
    is_fraud SMALLINT,
    is_flagged_fraud SMALLINT
);

CREATE TABLE IF NOT EXISTS staging.paysim_transactions (
    transaction_id BIGINT PRIMARY KEY,
    step INTEGER NOT NULL,
    transaction_type TEXT NOT NULL,
    amount NUMERIC(20, 2) NOT NULL,
    origin_account_id TEXT NOT NULL,
    old_balance_orig NUMERIC(20, 2),
    new_balance_orig NUMERIC(20, 2),
    destination_account_id TEXT NOT NULL,
    old_balance_dest NUMERIC(20, 2),
    new_balance_dest NUMERIC(20, 2),
    is_fraud SMALLINT NOT NULL,
    is_flagged_fraud SMALLINT NOT NULL,
    simulation_hour INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS marts.dim_account (
    account_id TEXT PRIMARY KEY,
    account_kind TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS marts.dim_transaction_type (
    transaction_type TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS marts.fact_transaction (
    transaction_id BIGINT PRIMARY KEY,
    step INTEGER NOT NULL,
    simulation_hour INTEGER NOT NULL,
    transaction_type TEXT NOT NULL REFERENCES marts.dim_transaction_type(transaction_type),
    amount NUMERIC(20, 2) NOT NULL,
    origin_account_id TEXT NOT NULL REFERENCES marts.dim_account(account_id),
    destination_account_id TEXT NOT NULL REFERENCES marts.dim_account(account_id),
    old_balance_orig NUMERIC(20, 2),
    new_balance_orig NUMERIC(20, 2),
    old_balance_dest NUMERIC(20, 2),
    new_balance_dest NUMERIC(20, 2),
    is_fraud SMALLINT NOT NULL,
    is_flagged_fraud SMALLINT NOT NULL
);

CREATE TABLE IF NOT EXISTS synthetic.users (
    user_id TEXT PRIMARY KEY,
    signup_date DATE NOT NULL,
    acquisition_channel TEXT NOT NULL,
    device_type TEXT NOT NULL,
    region_group TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS synthetic.experiment_assignments (
    user_id TEXT PRIMARY KEY REFERENCES synthetic.users(user_id),
    experiment_name TEXT NOT NULL,
    variant TEXT NOT NULL CHECK (variant IN ('control', 'treatment')),
    assigned_date DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS synthetic.user_journey (
    user_id TEXT PRIMARY KEY REFERENCES synthetic.users(user_id),
    onboarding_completed BOOLEAN NOT NULL,
    card_ordered BOOLEAN NOT NULL,
    card_activated BOOLEAN NOT NULL,
    first_transfer_completed BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS synthetic.app_events (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES synthetic.users(user_id),
    event_name TEXT NOT NULL,
    event_date DATE NOT NULL
);

-- ==============================================================================
-- 2. ЗАГРУЗКА ИСХОДНОГО CSV В RAW
-- ==============================================================================

TRUNCATE TABLE raw.paysim_transactions RESTART IDENTITY;
\copy raw.paysim_transactions (step, type, amount, name_orig, old_balance_orig, new_balance_orig, name_dest, old_balance_dest, new_balance_dest, is_fraud, is_flagged_fraud) FROM 'data/raw/PS_20174392719_1491204439457_log.csv' WITH (FORMAT csv, HEADER true);

-- ==============================================================================
-- 3. ПЕРЕНОС В STAGING И ПОСТРОЕНИЕ MARTS
-- ==============================================================================

TRUNCATE TABLE marts.fact_transaction;
TRUNCATE TABLE marts.dim_account;
TRUNCATE TABLE marts.dim_transaction_type;
TRUNCATE TABLE staging.paysim_transactions;

INSERT INTO staging.paysim_transactions (
    transaction_id, step, transaction_type, amount,
    origin_account_id, old_balance_orig, new_balance_orig,
    destination_account_id, old_balance_dest, new_balance_dest,
    is_fraud, is_flagged_fraud, simulation_hour
)
SELECT
    raw_id,
    step,
    UPPER(TRIM(type)),
    amount,
    TRIM(name_orig),
    old_balance_orig,
    new_balance_orig,
    TRIM(name_dest),
    old_balance_dest,
    new_balance_dest,
    is_fraud,
    is_flagged_fraud,
    step - 1
FROM raw.paysim_transactions;

INSERT INTO marts.dim_transaction_type (transaction_type)
SELECT DISTINCT transaction_type
FROM staging.paysim_transactions
ON CONFLICT DO NOTHING;

INSERT INTO marts.dim_account (account_id, account_kind)
SELECT account_id,
       CASE WHEN LEFT(account_id, 1) = 'C' THEN 'customer_account'
            WHEN LEFT(account_id, 1) = 'M' THEN 'merchant_or_other'
            ELSE 'unknown_prefix' END
FROM (
    SELECT origin_account_id AS account_id FROM staging.paysim_transactions
    UNION
    SELECT destination_account_id AS account_id FROM staging.paysim_transactions
) accounts
ON CONFLICT DO NOTHING;

INSERT INTO marts.fact_transaction (
    transaction_id, step, simulation_hour, transaction_type, amount,
    origin_account_id, destination_account_id,
    old_balance_orig, new_balance_orig, old_balance_dest, new_balance_dest,
    is_fraud, is_flagged_fraud
)
SELECT transaction_id, step, simulation_hour, transaction_type, amount,
       origin_account_id, destination_account_id,
       old_balance_orig, new_balance_orig, old_balance_dest, new_balance_dest,
       is_fraud, is_flagged_fraud
FROM staging.paysim_transactions;

-- ==============================================================================
-- 4. СИНТЕТИЧЕСКИЙ СЛОЙ ЦИФРОВОГО ПРОДУКТА
-- ==============================================================================

TRUNCATE TABLE synthetic.app_events RESTART IDENTITY;
TRUNCATE TABLE synthetic.user_journey;
TRUNCATE TABLE synthetic.experiment_assignments;
TRUNCATE TABLE synthetic.users CASCADE;

SELECT setseed(0.42);

INSERT INTO synthetic.users (user_id, signup_date, acquisition_channel, device_type, region_group)
SELECT
    'SYN_' || LPAD(user_no::TEXT, 6, '0'),
    DATE '2025-01-01' + (FLOOR(random() * 30)::INTEGER),
    (ARRAY['organic', 'paid_search', 'social', 'referral'])[1 + FLOOR(random() * 4)::INTEGER],
    (ARRAY['ios', 'android', 'web'])[1 + FLOOR(random() * 3)::INTEGER],
    (ARRAY['central', 'northwest', 'south', 'other'])[1 + FLOOR(random() * 4)::INTEGER]
FROM generate_series(1, 10000) AS user_no;

INSERT INTO synthetic.experiment_assignments (user_id, experiment_name, variant, assigned_date)
SELECT user_id,
       'simplified_first_transfer',
       CASE WHEN random() < 0.5 THEN 'control' ELSE 'treatment' END,
       signup_date
FROM synthetic.users;

INSERT INTO synthetic.user_journey (
    user_id, onboarding_completed, card_ordered, card_activated, first_transfer_completed
)
SELECT
    u.user_id,
    onboarding_completed,
    card_ordered,
    card_activated,
    first_transfer_completed
FROM synthetic.users u
JOIN synthetic.experiment_assignments a USING (user_id)
CROSS JOIN LATERAL (
    SELECT random() < 0.78 AND u.user_id IS NOT NULL AS onboarding_completed
) s1
CROSS JOIN LATERAL (
    SELECT s1.onboarding_completed AND random() < 0.72 AS card_ordered
) s2
CROSS JOIN LATERAL (
    SELECT s2.card_ordered AND random() < 0.82 AS card_activated
) s3
CROSS JOIN LATERAL (
    SELECT s3.card_activated AND random() <
        CASE WHEN a.variant = 'treatment' THEN 0.30 ELSE 0.25 END
        AS first_transfer_completed
) s4;

INSERT INTO synthetic.app_events (user_id, event_name, event_date)
SELECT u.user_id, 'app_open', u.signup_date + d.day_offset
FROM synthetic.users u
CROSS JOIN generate_series(0, 30) AS d(day_offset)
WHERE d.day_offset = 0
   OR random() < GREATEST(0.04, 0.52 - d.day_offset * 0.014);

INSERT INTO synthetic.app_events (user_id, event_name, event_date)
SELECT u.user_id, 'onboarding_completed', u.signup_date + 1
FROM synthetic.users u
JOIN synthetic.user_journey j USING (user_id)
WHERE j.onboarding_completed;

INSERT INTO synthetic.app_events (user_id, event_name, event_date)
SELECT u.user_id, 'card_ordered', u.signup_date + 2
FROM synthetic.users u
JOIN synthetic.user_journey j USING (user_id)
WHERE j.card_ordered;

INSERT INTO synthetic.app_events (user_id, event_name, event_date)
SELECT u.user_id, 'card_activated', u.signup_date + 4
FROM synthetic.users u
JOIN synthetic.user_journey j USING (user_id)
WHERE j.card_activated;

INSERT INTO synthetic.app_events (user_id, event_name, event_date)
SELECT u.user_id, 'first_transfer_completed', u.signup_date + 6
FROM synthetic.users u
JOIN synthetic.user_journey j USING (user_id)
WHERE j.first_transfer_completed;

-- Обновляем статистику после генерации данных: планировщик использует её
-- для оценки селективности фильтров и выбора порядка соединений.
ANALYZE synthetic.users;
ANALYZE synthetic.experiment_assignments;
ANALYZE synthetic.user_journey;
ANALYZE synthetic.app_events;

-- ==============================================================================
-- 5. ПРОВЕРКИ КАЧЕСТВА ДАННЫХ
-- ==============================================================================

\echo '1. Row counts'
SELECT 'raw' AS layer, COUNT(*) AS row_count FROM raw.paysim_transactions
UNION ALL
SELECT 'staging', COUNT(*) FROM staging.paysim_transactions
UNION ALL
SELECT 'fact', COUNT(*) FROM marts.fact_transaction;

\echo '2. Null checks in raw'
SELECT
    COUNT(*) FILTER (WHERE step IS NULL) AS null_step,
    COUNT(*) FILTER (WHERE type IS NULL) AS null_type,
    COUNT(*) FILTER (WHERE amount IS NULL) AS null_amount,
    COUNT(*) FILTER (WHERE name_orig IS NULL) AS null_origin,
    COUNT(*) FILTER (WHERE name_dest IS NULL) AS null_destination,
    COUNT(*) FILTER (WHERE is_fraud IS NULL) AS null_fraud_flag
FROM raw.paysim_transactions;

\echo '3. Domain checks'
SELECT
    COUNT(*) FILTER (WHERE step < 1 OR step > 744) AS invalid_step,
    COUNT(*) FILTER (WHERE amount < 0) AS negative_amount,
    COUNT(*) FILTER (WHERE is_fraud NOT IN (0, 1)) AS invalid_fraud_flag,
    COUNT(*) FILTER (WHERE is_flagged_fraud NOT IN (0, 1)) AS invalid_system_flag
FROM raw.paysim_transactions;

\echo '4. Transaction types'
SELECT type, COUNT(*) AS transactions
FROM raw.paysim_transactions
GROUP BY type
ORDER BY transactions DESC;

\echo '5. Duplicate source rows (all business columns)'
SELECT COUNT(*) AS duplicate_groups
FROM (
    SELECT step, type, amount, name_orig, old_balance_orig, new_balance_orig,
           name_dest, old_balance_dest, new_balance_dest, is_fraud, is_flagged_fraud
    FROM raw.paysim_transactions
    GROUP BY step, type, amount, name_orig, old_balance_orig, new_balance_orig,
             name_dest, old_balance_dest, new_balance_dest, is_fraud, is_flagged_fraud
    HAVING COUNT(*) > 1
) duplicates;

\echo '6. Balance reconciliation diagnostics (not a fraud rule)'
SELECT transaction_type,
       COUNT(*) AS transactions,
       COUNT(*) FILTER (
           WHERE ABS((old_balance_orig - new_balance_orig) - amount) > 0.01
       ) AS origin_balance_differences
FROM marts.fact_transaction
GROUP BY transaction_type
ORDER BY transaction_type;

\echo '7. Fraud distribution'
SELECT is_fraud, COUNT(*) AS transactions,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 4) AS share_pct
FROM marts.fact_transaction
GROUP BY is_fraud
ORDER BY is_fraud;

-- ==============================================================================
-- 6. ИНДЕКСЫ И СТАТИСТИКА
-- ==============================================================================

-- Индексы ускоряют временные срезы, анализ типов операций, историю отправителей и выборку fraud-строк.
CREATE INDEX IF NOT EXISTS idx_fact_step ON marts.fact_transaction(step);
CREATE INDEX IF NOT EXISTS idx_fact_type_step ON marts.fact_transaction(transaction_type, step);
CREATE INDEX IF NOT EXISTS idx_fact_origin_step ON marts.fact_transaction(origin_account_id, step);
CREATE INDEX IF NOT EXISTS idx_fact_fraud ON marts.fact_transaction(is_fraud) WHERE is_fraud = 1;

-- Индексы ускоряют анализ активности пользователя и динамики отдельных типов событий.
CREATE INDEX IF NOT EXISTS idx_events_user_date ON synthetic.app_events(user_id, event_date);
CREATE INDEX IF NOT EXISTS idx_events_name_date ON synthetic.app_events(event_name, event_date);

-- Обновляем статистику таблиц для выбора оптимальных планов выполнения запросов.
ANALYZE marts.fact_transaction;
ANALYZE synthetic.app_events;

-- ==============================================================================
-- АНАЛИТИКА: 01_transaction_overview
-- ==============================================================================

-- 1. Общая характеристика транзакционного набора.
SELECT
    COUNT(*) AS transaction_count,
    COUNT(DISTINCT origin_account_id) AS unique_senders,
    COUNT(DISTINCT destination_account_id) AS unique_recipients,
    MIN(step) AS first_step,
    MAX(step) AS last_step,
    ROUND(AVG(amount), 2) AS average_transaction_amount,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount::DOUBLE PRECISION)::NUMERIC, 2) AS median_amount,
    ROUND(SUM(amount), 2) AS total_transaction_volume
FROM marts.fact_transaction;

-- 2. Структура операций.
SELECT transaction_type,
       COUNT(*) AS transaction_count,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS transaction_share_pct,
       ROUND(SUM(amount), 2) AS transaction_volume,
       ROUND(AVG(amount), 2) AS average_amount
FROM marts.fact_transaction
GROUP BY transaction_type
ORDER BY transaction_count DESC;

-- 3. Крупнейшие операции.
SELECT transaction_id, step, transaction_type, amount,
       origin_account_id, destination_account_id, is_fraud
FROM marts.fact_transaction
ORDER BY amount DESC
LIMIT 20;

-- ==============================================================================
-- АНАЛИТИКА: 02_customer_activity
-- ==============================================================================

WITH customer_activity AS (
    SELECT origin_account_id AS account_id,
           COUNT(*) AS transaction_count,
           SUM(amount) AS total_sent_amount,
           AVG(amount) AS average_amount,
           MIN(step) AS first_active_step,
           MAX(step) AS last_active_step,
           COUNT(DISTINCT transaction_type) AS used_transaction_types
    FROM marts.fact_transaction
    GROUP BY origin_account_id
)
SELECT COUNT(*) AS active_senders,
       ROUND(AVG(transaction_count), 2) AS avg_transactions_per_sender,
       ROUND(AVG(total_sent_amount), 2) AS avg_sent_volume_per_sender,
       ROUND(AVG(used_transaction_types), 2) AS avg_used_transaction_types
FROM customer_activity;

SELECT origin_account_id AS account_id,
       COUNT(*) AS transaction_count,
       ROUND(SUM(amount), 2) AS total_sent_amount,
       MAX(step) AS last_active_step
FROM marts.fact_transaction
GROUP BY origin_account_id
ORDER BY transaction_count DESC
LIMIT 20;

WITH account_volume AS (
    SELECT origin_account_id, SUM(amount) AS sent_volume
    FROM marts.fact_transaction
    GROUP BY origin_account_id
), ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY sent_volume DESC) AS rn
    FROM account_volume
)
SELECT ROUND(100.0 * SUM(sent_volume) FILTER (WHERE rn <= 10)
             / NULLIF(SUM(sent_volume), 0), 2) AS top_10_volume_share_pct
FROM ranked;

-- ==============================================================================
-- АНАЛИТИКА: 03_time_analysis
-- ==============================================================================

SELECT step,
       COUNT(*) AS transaction_count,
       ROUND(SUM(amount), 2) AS transaction_volume,
       ROUND(AVG(amount), 2) AS average_amount
FROM marts.fact_transaction
GROUP BY step
ORDER BY step;

SELECT step, transaction_type, COUNT(*) AS transaction_count
FROM marts.fact_transaction
GROUP BY step, transaction_type
ORDER BY step, transaction_type;

WITH hourly AS (
    SELECT step, COUNT(*) AS transaction_count
    FROM marts.fact_transaction
    GROUP BY step
)
SELECT step,
       transaction_count,
       LAG(transaction_count) OVER (ORDER BY step) AS previous_step_count,
       transaction_count - LAG(transaction_count) OVER (ORDER BY step) AS change_vs_previous_step
FROM hourly
ORDER BY step;

-- ==============================================================================
-- АНАЛИТИКА: 04_fraud_analysis
-- ==============================================================================

SELECT transaction_type,
       COUNT(*) AS total_transactions,
       COUNT(*) FILTER (WHERE is_fraud = 1) AS fraud_transactions,
       ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud = 1)
             / NULLIF(COUNT(*), 0), 4) AS fraud_rate_pct
FROM marts.fact_transaction
GROUP BY transaction_type
ORDER BY fraud_rate_pct DESC;

SELECT is_flagged_fraud, COUNT(*) AS transaction_count
FROM marts.fact_transaction
GROUP BY is_flagged_fraud
ORDER BY is_flagged_fraud;

SELECT is_fraud,
       COUNT(*) AS transaction_count,
       ROUND(AVG(amount), 2) AS average_amount,
       ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount::DOUBLE PRECISION)::NUMERIC, 2) AS median_amount,
       ROUND(MAX(amount), 2) AS max_amount
FROM marts.fact_transaction
GROUP BY is_fraud
ORDER BY is_fraud;

-- ==============================================================================
-- АНАЛИТИКА: 05_rfm_segmentation
-- Чем позже последняя активность, тем выше recency_score.
-- ==============================================================================

WITH customer_metrics AS (
    SELECT origin_account_id AS account_id,
           MAX(step) AS last_active_step,
           COUNT(*) AS frequency,
           SUM(amount) AS monetary
    FROM marts.fact_transaction
    GROUP BY origin_account_id
), scored AS (
    SELECT *,
           NTILE(4) OVER (ORDER BY last_active_step DESC, account_id) AS recency_score,
           NTILE(4) OVER (ORDER BY frequency) AS frequency_score,
           NTILE(4) OVER (ORDER BY monetary) AS monetary_score
    FROM customer_metrics
), segmented AS (
    SELECT *,
           CASE
             WHEN recency_score >= 3 AND frequency_score >= 3 AND monetary_score >= 3 THEN 'high_value_active'
             WHEN recency_score >= 3 AND frequency_score >= 3 THEN 'active_frequent'
             WHEN recency_score >= 3 AND frequency_score <= 2 THEN 'recent_low_frequency'
             WHEN recency_score <= 2 AND frequency_score >= 3 THEN 'previously_active'
             ELSE 'low_activity'
           END AS customer_segment
    FROM scored
)
SELECT customer_segment,
       COUNT(*) AS customers,
       ROUND(AVG(frequency), 2) AS avg_transactions,
       ROUND(AVG(monetary), 2) AS avg_sent_volume
FROM segmented
GROUP BY customer_segment
ORDER BY customers DESC;

WITH customer_metrics AS (
    SELECT origin_account_id AS account_id,
           MAX(step) AS last_active_step,
           COUNT(*) AS frequency,
           SUM(amount) AS monetary
    FROM marts.fact_transaction
    GROUP BY origin_account_id
)
SELECT account_id,
       (SELECT MAX(step) FROM marts.fact_transaction) - last_active_step AS recency_steps,
       frequency,
       ROUND(monetary, 2) AS monetary_volume,
       NTILE(4) OVER (ORDER BY last_active_step DESC, account_id) AS recency_score,
       NTILE(4) OVER (ORDER BY frequency) AS frequency_score,
       NTILE(4) OVER (ORDER BY monetary) AS monetary_score
FROM customer_metrics;

-- ==============================================================================
-- АНАЛИТИКА: 06_product_funnel
-- ==============================================================================

WITH funnel AS (
    SELECT
        COUNT(*) AS registered_users,
        COUNT(*) FILTER (WHERE onboarding_completed) AS onboarding_users,
        COUNT(*) FILTER (WHERE card_ordered) AS card_ordered_users,
        COUNT(*) FILTER (WHERE card_activated) AS card_activated_users,
        COUNT(*) FILTER (WHERE first_transfer_completed) AS first_transfer_users
    FROM synthetic.user_journey
)
SELECT 'registration' AS funnel_stage, registered_users AS users, 100.0 AS conversion_from_registration_pct FROM funnel
UNION ALL
SELECT 'onboarding_completed', onboarding_users, ROUND(100.0 * onboarding_users / NULLIF(registered_users, 0), 2) FROM funnel
UNION ALL
SELECT 'card_ordered', card_ordered_users, ROUND(100.0 * card_ordered_users / NULLIF(registered_users, 0), 2) FROM funnel
UNION ALL
SELECT 'card_activated', card_activated_users, ROUND(100.0 * card_activated_users / NULLIF(registered_users, 0), 2) FROM funnel
UNION ALL
SELECT 'first_transfer_completed', first_transfer_users, ROUND(100.0 * first_transfer_users / NULLIF(registered_users, 0), 2) FROM funnel;

WITH counts AS (
    SELECT
        COUNT(*) AS registrations,
        COUNT(*) FILTER (WHERE onboarding_completed) AS onboarding,
        COUNT(*) FILTER (WHERE card_ordered) AS card_ordered,
        COUNT(*) FILTER (WHERE card_activated) AS card_activated,
        COUNT(*) FILTER (WHERE first_transfer_completed) AS first_transfer
    FROM synthetic.user_journey
)
SELECT 'registration_to_onboarding' AS conversion_step,
       ROUND(100.0 * onboarding / NULLIF(registrations, 0), 2) AS conversion_pct FROM counts
UNION ALL
SELECT 'onboarding_to_card_order', ROUND(100.0 * card_ordered / NULLIF(onboarding, 0), 2) FROM counts
UNION ALL
SELECT 'card_order_to_activation', ROUND(100.0 * card_activated / NULLIF(card_ordered, 0), 2) FROM counts
UNION ALL
SELECT 'activation_to_first_transfer', ROUND(100.0 * first_transfer / NULLIF(card_activated, 0), 2) FROM counts;

-- ==============================================================================
-- АНАЛИТИКА: 07_cohort_retention
-- ==============================================================================

WITH user_cohorts AS (
    SELECT user_id,
           DATE_TRUNC('week', signup_date)::DATE AS cohort_week
    FROM synthetic.users
), activity AS (
    SELECT DISTINCT user_id,
           DATE_TRUNC('week', event_date)::DATE AS activity_week
    FROM synthetic.app_events
    WHERE event_name = 'app_open'
), cohort_activity AS (
    SELECT c.cohort_week,
           ((a.activity_week - c.cohort_week) / 7)::INTEGER AS week_number,
           COUNT(DISTINCT c.user_id) AS active_users
    FROM user_cohorts c
    JOIN activity a USING (user_id)
    WHERE a.activity_week >= c.cohort_week
    GROUP BY c.cohort_week, week_number
), cohort_sizes AS (
    SELECT cohort_week, COUNT(*) AS cohort_users
    FROM user_cohorts
    GROUP BY cohort_week
)
SELECT ca.cohort_week,
       ca.week_number,
       cs.cohort_users,
       ca.active_users,
       ROUND(100.0 * ca.active_users / NULLIF(cs.cohort_users, 0), 2) AS retention_pct
FROM cohort_activity ca
JOIN cohort_sizes cs USING (cohort_week)
ORDER BY ca.cohort_week, ca.week_number;

WITH cohort_users AS (
    SELECT user_id, signup_date FROM synthetic.users
), user_activity AS (
    SELECT DISTINCT user_id, event_date
    FROM synthetic.app_events
    WHERE event_name = 'app_open'
)
SELECT
    COUNT(*) AS registered_users,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM user_activity a
        WHERE a.user_id = u.user_id AND a.event_date = u.signup_date + 1
    )) AS d1_active_users,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM user_activity a
        WHERE a.user_id = u.user_id AND a.event_date = u.signup_date + 7
    )) AS d7_active_users,
    COUNT(*) FILTER (WHERE EXISTS (
        SELECT 1 FROM user_activity a
        WHERE a.user_id = u.user_id AND a.event_date = u.signup_date + 30
    )) AS d30_active_users
FROM cohort_users u;

-- ==============================================================================
-- АНАЛИТИКА: 08_ab_test
-- ==============================================================================

WITH experiment_results AS (
    SELECT a.variant,
           COUNT(*) AS users,
           COUNT(*) FILTER (WHERE j.first_transfer_completed) AS converted_users,
           AVG(j.first_transfer_completed::INTEGER::NUMERIC) AS conversion_rate
    FROM synthetic.experiment_assignments a
    JOIN synthetic.user_journey j USING (user_id)
    WHERE a.experiment_name = 'simplified_first_transfer'
    GROUP BY a.variant
), pivoted AS (
    SELECT
        MAX(users) FILTER (WHERE variant = 'control') AS n_control,
        MAX(users) FILTER (WHERE variant = 'treatment') AS n_treatment,
        MAX(converted_users) FILTER (WHERE variant = 'control') AS x_control,
        MAX(converted_users) FILTER (WHERE variant = 'treatment') AS x_treatment,
        MAX(conversion_rate) FILTER (WHERE variant = 'control') AS p_control,
        MAX(conversion_rate) FILTER (WHERE variant = 'treatment') AS p_treatment
    FROM experiment_results
)
SELECT n_control,
       n_treatment,
       x_control,
       x_treatment,
       ROUND(100 * p_control, 2) AS control_conversion_pct,
       ROUND(100 * p_treatment, 2) AS treatment_conversion_pct,
       ROUND(100 * (p_treatment - p_control), 2) AS absolute_lift_percentage_points,
       ROUND(100 * (p_treatment - p_control) / NULLIF(p_control, 0), 2) AS relative_lift_pct,
       ROUND(SQRT(
           (p_control * (1 - p_control) / NULLIF(n_control, 0)) +
           (p_treatment * (1 - p_treatment) / NULLIF(n_treatment, 0))
       )::NUMERIC, 6) AS standard_error_unpooled
FROM pivoted;

SELECT variant, COUNT(*) AS assigned_users,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS assignment_share_pct
FROM synthetic.experiment_assignments
WHERE experiment_name = 'simplified_first_transfer'
GROUP BY variant;

-- ==============================================================================
-- АНАЛИТИКА: 09_performance
-- ==============================================================================

-- Тест 1: план поиска операций конкретного отправителя.
-- Кандидат на использование - idx_fact_origin_step; фактический выбор делает планировщик.
EXPLAIN (ANALYZE, BUFFERS)
SELECT origin_account_id, COUNT(*) AS transaction_count, SUM(amount) AS total_amount
FROM marts.fact_transaction
WHERE origin_account_id = 'C1001'
GROUP BY origin_account_id;

-- Тест 2: план выборки по диапазону времени.
-- Кандидат - idx_fact_step; проверяем Scan type, actual time и buffers.
EXPLAIN (ANALYZE, BUFFERS)
SELECT transaction_type, COUNT(*)
FROM marts.fact_transaction
WHERE step BETWEEN 100 AND 200
GROUP BY transaction_type;

\echo 'Выполнение project.sql завершено.'
