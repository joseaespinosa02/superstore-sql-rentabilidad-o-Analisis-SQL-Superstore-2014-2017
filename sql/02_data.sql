-- ============================================================
-- 02_DATA.SQL
-- Carga de datos: desde el CSV original hacia staging, y desde
-- staging hacia el modelo dimensional (dim_* y fact_sales)
-- ============================================================

USE superstore_db;

-- ------------------------------------------------------------
-- 0) HABILITAR CARGA LOCAL DE ARCHIVOS (una sola vez por sesión)
-- Necesario para poder usar LOAD DATA LOCAL INFILE
-- ------------------------------------------------------------
SET GLOBAL local_infile = 1;


-- ------------------------------------------------------------
-- 1) CARGA INICIAL: CSV -> tabla staging (stg_superstore)
-- Usamos LOAD DATA en vez del Import Wizard gráfico porque el
-- dataset tiene campos de texto con comas dentro de comillas
-- (ej. nombres de producto largos), y LOAD DATA respeta
-- correctamente el ENCLOSED BY '"' para no cortar esas filas.
--
-- NOTA: ajustar la ruta del archivo según corresponda en tu entorno.
-- ------------------------------------------------------------
LOAD DATA LOCAL INFILE 'C:/Users/josea/Downloads/Data Science/Proyecto_Superstore/data/raw/Sample - Superstore.csv'
INTO TABLE stg_superstore
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\r\n'
IGNORE 1 ROWS;

-- Verificación: debe dar 9994 filas (igual al CSV original sin el header)
SELECT COUNT(*) AS total_filas_staging FROM stg_superstore;


-- ------------------------------------------------------------
-- 2) DIM_CUSTOMERS
-- GROUP BY + MAX() por seguridad: si un mismo customer_id tuviera
-- ligeras inconsistencias de nombre/segmento en el CSV, esto evita
-- errores de PK duplicada al insertar.
-- ------------------------------------------------------------
INSERT INTO dim_customers (customer_id, customer_name, segment)
SELECT customer_id, MAX(customer_name), MAX(segment)
FROM stg_superstore
GROUP BY customer_id;


-- ------------------------------------------------------------
-- 3) DIM_PRODUCTS
-- Mismo criterio: GROUP BY product_id para evitar duplicados de PK.
-- ------------------------------------------------------------
INSERT INTO dim_products (product_id, product_name, category, sub_category)
SELECT product_id, MAX(product_name), MAX(category), MAX(sub_category)
FROM stg_superstore
GROUP BY product_id;


-- ------------------------------------------------------------
-- 4) DIM_LOCATION
-- SELECT DISTINCT sobre la combinación ciudad/estado/región/país/CP.
-- location_id se genera automáticamente (AUTO_INCREMENT).
-- ------------------------------------------------------------
INSERT INTO dim_location (city, state, region, country, postal_code)
SELECT DISTINCT city, state, region, country, postal_code
FROM stg_superstore;


-- ------------------------------------------------------------
-- 5) DIM_CALENDAR
-- Convertimos order_date (texto 'M/D/YYYY') a tipo DATE con
-- STR_TO_DATE (CAST de tipos), y extraemos year/month/quarter/
-- day_of_week usando funciones de fecha nativas de MySQL.
-- ------------------------------------------------------------
INSERT INTO dim_calendar (full_date, year, month, month_name, quarter, day_of_week)
SELECT DISTINCT
    STR_TO_DATE(order_date, '%m/%d/%Y')                AS full_date,
    YEAR(STR_TO_DATE(order_date, '%m/%d/%Y'))          AS year,
    MONTH(STR_TO_DATE(order_date, '%m/%d/%Y'))         AS month,
    MONTHNAME(STR_TO_DATE(order_date, '%m/%d/%Y'))     AS month_name,
    QUARTER(STR_TO_DATE(order_date, '%m/%d/%Y'))       AS quarter,
    DAYNAME(STR_TO_DATE(order_date, '%m/%d/%Y'))       AS day_of_week
FROM stg_superstore;


-- ------------------------------------------------------------
-- 6) FACT_SALES
-- JOINs con dim_location y dim_calendar para obtener los IDs
-- generados (surrogate keys). Usamos <=> (NULL-safe equal) en
-- postal_code porque algunas filas tienen CP nulo, y '=' normal
-- no compara NULL con NULL como verdadero.
-- ------------------------------------------------------------
INSERT INTO fact_sales (
    row_id, order_id, customer_id, product_id, location_id, date_id,
    ship_date, ship_mode, sales, quantity, discount, profit
)
SELECT
    s.row_id,
    s.order_id,
    s.customer_id,
    s.product_id,
    dl.location_id,
    dc.date_id,
    STR_TO_DATE(s.ship_date, '%m/%d/%Y'),
    s.ship_mode,
    s.sales,
    s.quantity,
    s.discount,
    s.profit
FROM stg_superstore s
INNER JOIN dim_location dl
    ON dl.city = s.city
   AND dl.state = s.state
   AND dl.postal_code <=> s.postal_code
INNER JOIN dim_calendar dc
    ON dc.full_date = STR_TO_DATE(s.order_date, '%m/%d/%Y');


-- ------------------------------------------------------------
-- 7) VERIFICACIÓN FINAL DE CARGA
-- ------------------------------------------------------------
SELECT 'dim_customers' AS tabla, COUNT(*) AS filas FROM dim_customers
UNION ALL SELECT 'dim_products', COUNT(*) FROM dim_products
UNION ALL SELECT 'dim_location', COUNT(*) FROM dim_location
UNION ALL SELECT 'dim_calendar', COUNT(*) FROM dim_calendar
UNION ALL SELECT 'fact_sales', COUNT(*) FROM fact_sales;
-- Resultado esperado: 793 / 1862 / 632 / 1237 / 9994


-- ------------------------------------------------------------
-- 8) LIMPIEZA DE LA CAPA STAGING
-- stg_superstore ya cumplió su función (los datos fueron
-- transformados exitosamente al modelo dimensional). Se eliminan
-- sus registros para liberar espacio y evitar confusión con
-- datos crudos sin normalizar.
-- ------------------------------------------------------------
DELETE FROM stg_superstore;

SELECT COUNT(*) AS filas_restantes_staging FROM stg_superstore;
-- Resultado esperado: 0
