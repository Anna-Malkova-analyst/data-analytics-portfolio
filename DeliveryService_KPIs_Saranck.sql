-----------------------------------------------------------------------
-- Проект: Ключевые бизнес-метрики сервиса доставки еды "Всё.из.кафе" 
-- Город: Саранск, период: май — июнь 2021
-- Цель: Анализ клиентской базы через расчет ключевых метрик, построение дашборда и аналитической записки.
-----------------------------------------------------------------------

-------------------------------------------------------------------------
-- Задача 1: Расчёт DAU (Daily Active Users)
-- Определяем ежедневное количество активных пользователей (размещавших заказ) за май и июнь.
-------------------------------------------------------------------------
SELECT log_date, 
       COUNT(DISTINCT user_id) AS DAU
FROM analytics_events AS ae
LEFT JOIN cities AS c ON c.city_id = ae.city_id
WHERE ae.event = 'order' 
  AND c.city_name = 'Саранск' 
  AND log_date BETWEEN '2021-05-01' AND '2021-06-30'
GROUP BY log_date
ORDER BY log_date ASC
LIMIT 10;

-------------------------------------------------------------------------
-- Задача 2: Расчёт Conversion Rate (CR)
-- Определяем конверсию зарегистрированных пользователей в активных клиентов за каждый день.
-------------------------------------------------------------------------
SELECT ae.log_date, 
       ROUND(
           COUNT(DISTINCT ae.user_id) FILTER (WHERE ae.event = 'order')::numeric 
           / COUNT(DISTINCT ae.user_id), 2
       ) AS CR
FROM analytics_events AS ae
LEFT JOIN cities AS c ON ae.city_id = c.city_id
WHERE c.city_name = 'Саранск'
  AND ae.log_date BETWEEN '2021-05-01' AND '2021-06-30'
GROUP BY ae.log_date
ORDER BY ae.log_date ASC
LIMIT 10;

-------------------------------------------------------------------------
-- Задача 3: Расчёт среднего чека
-- Рассчитываем средний доход с заказа (комиссию) по месяцам для активных клиентов.
-------------------------------------------------------------------------
WITH orders AS (
    SELECT *,
           revenue * commission AS commission_revenue
    FROM analytics_events
    JOIN cities ON analytics_events.city_id = cities.city_id
    WHERE revenue IS NOT NULL
      AND log_date BETWEEN '2021-05-01' AND '2021-06-30'
      AND city_name = 'Саранск'
)
SELECT DATE_TRUNC('month', log_date)::date AS "Месяц",
       COUNT(DISTINCT order_id) AS "Количество заказов",
       ROUND(SUM(commission_revenue)::numeric, 2) AS "Сумма комиссии",
       ROUND(SUM(commission_revenue)::numeric / COUNT(DISTINCT order_id), 2) AS "Средний чек"
FROM orders
GROUP BY "Месяц"
ORDER BY "Месяц" ASC;

-------------------------------------------------------------------------
-- Задача 4: Расчёт LTV ресторанов
-- Определяем три ресторана с наибольшим LTV (суммарная комиссия за май-июнь).
-------------------------------------------------------------------------
WITH orders AS (
    SELECT analytics_events.rest_id,
           analytics_events.city_id,
           revenue * commission AS commission_revenue
    FROM analytics_events
    JOIN cities ON analytics_events.city_id = cities.city_id
    WHERE revenue IS NOT NULL
      AND log_date BETWEEN '2021-05-01' AND '2021-06-30'
      AND city_name = 'Саранск'
)
SELECT o.rest_id,
       p.chain AS "Название сети",
       p.type AS "Тип кухни",
       ROUND(SUM(o.commission_revenue)::numeric, 2) AS LTV
FROM orders o
JOIN partners p ON o.rest_id = p.rest_id AND o.city_id = p.city_id
GROUP BY o.rest_id, p.chain, p.type
ORDER BY LTV DESC
LIMIT 3;

-------------------------------------------------------------------------
-- Задача 5: LTV — самые популярные блюда двух топ-ресторанов
-- Определяем пять блюд с максимальным LTV из двух ресторанов с наибольшим LTV.
-------------------------------------------------------------------------
WITH orders AS (
    SELECT analytics_events.rest_id,
           analytics_events.city_id,
           analytics_events.object_id,
           revenue * commission AS commission_revenue
    FROM analytics_events
    JOIN cities ON analytics_events.city_id = cities.city_id
    WHERE revenue IS NOT NULL
      AND log_date BETWEEN '2021-05-01' AND '2021-06-30'
      AND city_name = 'Саранск'
), 
top_ltv_restaurants AS (
    SELECT orders.rest_id,
           chain,
           type,
           ROUND(SUM(commission_revenue)::numeric, 2) AS LTV
    FROM orders
    JOIN partners ON orders.rest_id = partners.rest_id AND orders.city_id = partners.city_id
    GROUP BY 1, 2, 3
    ORDER BY LTV DESC
    LIMIT 2
)
SELECT tr.chain AS "Название сети",
       d.name AS "Название блюда",
       d.spicy,
       d.fish,
       d.meat,
       ROUND(SUM(o.commission_revenue)::numeric, 2) AS LTV
FROM orders o
JOIN top_ltv_restaurants tr ON o.rest_id = tr.rest_id
JOIN dishes d ON o.object_id = d.object_id AND tr.rest_id = d.rest_id
GROUP BY 1, 2, 3, 4, 5
ORDER BY LTV DESC
LIMIT 5;

-------------------------------------------------------------------------
-- Задача 6: Расчёт Retention Rate
-- Вычисляем процент пользователей, возвращающихся в приложение в течение первой недели после регистрации.
-------------------------------------------------------------------------
WITH new_users AS (
    SELECT DISTINCT first_date,
           user_id
    FROM analytics_events
    JOIN cities ON analytics_events.city_id = cities.city_id
    WHERE first_date BETWEEN '2021-05-01' AND '2021-06-24'
      AND city_name = 'Саранск'
),
active_users AS (
    SELECT DISTINCT log_date,
           user_id
    FROM analytics_events
    JOIN cities ON analytics_events.city_id = cities.city_id
    WHERE log_date BETWEEN '2021-05-01' AND '2021-06-30'
      AND city_name = 'Саранск'
),
daily_retention AS (
    SELECT n.user_id,
           first_date,
           log_date::date - first_date::date AS day_since_install
    FROM new_users n
    JOIN active_users a ON n.user_id = a.user_id AND log_date >= first_date
)
SELECT day_since_install,
       COUNT(DISTINCT user_id) AS retained_users,
       ROUND(
           1.0 * COUNT(DISTINCT user_id) / 
           (MAX(COUNT(DISTINCT user_id)) OVER (ORDER BY day_since_install))::numeric, 2
       ) AS retention_rate
FROM daily_retention
WHERE day_since_install < 8
GROUP BY day_since_install
ORDER BY day_since_install ASC;

-------------------------------------------------------------------------
-- Задача 7: Сравнение Retention Rate по месяцам
-- Анализируем возврат пользователей по когортам, разделённым по месяцу первого визита.
-- Рассчитываем Retention Rate для первых 7 дней жизни пользователей.
-------------------------------------------------------------------------
WITH new_users AS (
    -- Определяем новых пользователей по дате первого посещения продукта
    SELECT DISTINCT first_date,
                    user_id
    FROM analytics_events
    JOIN cities ON analytics_events.city_id = cities.city_id
    WHERE first_date BETWEEN '2021-05-01' AND '2021-06-24'
      AND city_name = 'Саранск'
),
active_users AS (
    -- Определяем активных пользователей по дате события
    SELECT DISTINCT log_date,
                    user_id
    FROM analytics_events
    JOIN cities ON analytics_events.city_id = cities.city_id
    WHERE log_date BETWEEN '2021-05-01' AND '2021-06-30'
      AND city_name = 'Саранск'
),
daily_retention AS (
    -- Считаем дни жизни пользователя и их возвраты
    SELECT n.user_id,
           n.first_date,
           a.log_date::date - n.first_date::date AS day_since_install
    FROM new_users n
    JOIN active_users a ON n.user_id = a.user_id AND a.log_date >= n.first_date
),
cohorts AS (
    -- Размер когорты: количество новых пользователей в каждом месяце
    SELECT DATE_TRUNC('month', first_date)::date AS cohort_month,
           COUNT(DISTINCT user_id) AS cohort_size
    FROM new_users
    GROUP BY 1
)
-- Финальный расчёт Retention Rate по когортам
SELECT DATE_TRUNC('month', d.first_date)::date AS "Месяц",
       d.day_since_install,
       COUNT(DISTINCT d.user_id) AS retained_users,
       ROUND(COUNT(DISTINCT d.user_id)::numeric / c.cohort_size, 2) AS retention_rate
FROM daily_retention d
JOIN cohorts c ON DATE_TRUNC('month', d.first_date) = c.cohort_month
WHERE d.day_since_install BETWEEN 0 AND 7
GROUP BY "Месяц", d.day_since_install, c.cohort_size
ORDER BY "Месяц", d.day_since_install;
