-- ============================================================
-- 03_EDA.SQL
-- Análisis Exploratorio de Datos (EDA) y Consultas de Negocio
-- Foco: RENTABILIDAD (¿dónde gana y dónde pierde dinero el negocio?)
-- ============================================================

USE superstore_db;


-- ============================================================
-- BLOQUE 1: CALIDAD DE DATOS
-- ============================================================

-- ------------------------------------------------------------
-- 1.1 Detección de valores nulos en columnas críticas de fact_sales
-- Resultado obtenido: 0 nulos en todas las columnas
-- ------------------------------------------------------------
SELECT
    SUM(CASE WHEN customer_id IS NULL THEN 1 ELSE 0 END) AS nulos_customer,
    SUM(CASE WHEN product_id IS NULL THEN 1 ELSE 0 END)  AS nulos_product,
    SUM(CASE WHEN location_id IS NULL THEN 1 ELSE 0 END) AS nulos_location,
    SUM(CASE WHEN date_id IS NULL THEN 1 ELSE 0 END)     AS nulos_date,
    SUM(CASE WHEN sales IS NULL THEN 1 ELSE 0 END)       AS nulos_sales,
    SUM(CASE WHEN profit IS NULL THEN 1 ELSE 0 END)      AS nulos_profit
FROM fact_sales;

-- postal_code SÍ puede tener nulos (permitido en el schema, ciudades sin CP registrado)
SELECT COUNT(*) AS nulos_postal_code
FROM dim_location
WHERE postal_code IS NULL;


-- ------------------------------------------------------------
-- 1.2 Detección de duplicados lógicos con RANK() OVER (PARTITION BY...)
-- Resultado obtenido: 8 casos de mismo (order_id, product_id, customer_id)
-- con row_id distinto. Tras inspección, corresponden a líneas de pedido
-- separadas del mismo producto dentro de la misma orden (comportamiento
-- de compra real, NO son errores de carga). No se eliminan.
-- ------------------------------------------------------------
SELECT *
FROM (
    SELECT
        row_id, order_id, product_id, customer_id, sales,
        RANK() OVER (
            PARTITION BY order_id, product_id, customer_id
            ORDER BY row_id
        ) AS rnk
    FROM fact_sales
) ranked
WHERE rnk > 1;


-- ------------------------------------------------------------
-- 1.3 Validación de fechas (tipos y rango esperado)
-- Resultado obtenido: 2014-01-03 a 2017-12-30 (consistente con el dataset)
-- ------------------------------------------------------------
SELECT MIN(full_date) AS fecha_minima, MAX(full_date) AS fecha_maxima
FROM dim_calendar;

SELECT *
FROM dim_calendar
WHERE YEAR(full_date) NOT BETWEEN 2014 AND 2017;
-- Resultado esperado: 0 filas (ninguna fecha fuera de rango)


-- ------------------------------------------------------------
-- 1.4 Outliers / valores extremos en profit
-- Resultado: se identificaron transacciones con pérdidas extremas
-- (hasta -$6,599) asociadas a descuentos del 70-80%. NO son errores
-- de datos, sino información de negocio válida: ventas con descuentos
-- agresivos que generaron pérdida neta. Se documentan y se analizan
-- como parte del EDA de rentabilidad (Bloque 3), no se corrigen.
-- ------------------------------------------------------------
SELECT row_id, order_id, customer_id, product_id, location_id, date_id,
       sales, quantity, discount, profit
FROM fact_sales
WHERE profit < -1000
ORDER BY profit ASC;


-- ------------------------------------------------------------
-- 1.5 UPDATE de validación: estandarización de formato en 'region'
-- Verificamos que no haya inconsistencias de mayúsculas/minúsculas.
-- Resultado: 0 filas afectadas -> el dataset ya tenía 'region'
-- correctamente formateado, no se detectaron inconsistencias.
-- ------------------------------------------------------------
UPDATE dim_location
SET region = UPPER(region)
WHERE BINARY region <> BINARY UPPER(region);

SELECT DISTINCT region FROM dim_location;

-- ------------------------------------------------------------
-- 1.6 TRANSACCIÓN: corrección controlada de ship_mode en Tables
-- El equipo de logística reportó una posible inconsistencia en el
-- método de envío de la sub-categoría "Tables" (la de mayores
-- pérdidas, ver Bloque 3). Antes de aplicar el cambio de forma
-- definitiva, lo envolvemos en una transacción para poder revisar
-- el resultado con un SELECT y decidir si confirmar (COMMIT) o
-- deshacer (ROLLBACK) sin dejar la base de datos en un estado
-- intermedio.
-- ------------------------------------------------------------
START TRANSACTION;

UPDATE fact_sales f
INNER JOIN dim_products p ON f.product_id = p.product_id
SET f.ship_mode = 'Standard Class'
WHERE p.sub_category = 'Tables'
  AND f.ship_mode = 'Same Day';

-- Verificación antes de confirmar el cambio
SELECT f.row_id, p.sub_category, f.ship_mode
FROM fact_sales f
INNER JOIN dim_products p ON f.product_id = p.product_id
WHERE p.sub_category = 'Tables'
  AND f.ship_mode = 'Standard Class';

-- El UPDATE sí modificó 21 filas correctamente, pero tras revisar
-- el resultado se decide NO confirmar el cambio: se trataba de una
-- prueba para validar que la corrección era técnicamente viable,
-- no de un error real en los datos. Se revierte con ROLLBACK para
-- dejar la base de datos exactamente como estaba.
ROLLBACK;

-- Verificación post-rollback: los datos deben quedar como estaban
SELECT f.row_id, p.sub_category, f.ship_mode
FROM fact_sales f
INNER JOIN dim_products p ON f.product_id = p.product_id
WHERE p.sub_category = 'Tables'
  AND f.ship_mode = 'Same Day';

-- ============================================================
-- BLOQUE 2: EDA DESCRIPTIVO
-- ============================================================

-- ------------------------------------------------------------
-- 2.1 Visión general del negocio: totales generales
-- Insight: tamaño del negocio en ventas, ganancia y volumen
-- ------------------------------------------------------------
SELECT
    COUNT(*) AS total_transacciones,
    SUM(sales) AS ventas_totales,
    SUM(profit) AS ganancia_total,
    ROUND(AVG(sales), 2) AS ticket_promedio,
    ROUND(AVG(profit), 2) AS ganancia_promedio_por_venta
FROM fact_sales;


-- ------------------------------------------------------------
-- 2.2 Rentabilidad por categoría (INNER JOIN)
-- INSIGHT #1: Furniture genera casi el mismo volumen de ventas que
-- Technology y Office Supplies, pero su margen de ganancia es ~7x menor.
-- ------------------------------------------------------------
SELECT
    p.category,
    COUNT(*) AS num_ventas,
    SUM(f.sales) AS ventas_totales,
    SUM(f.profit) AS ganancia_total,
    ROUND(SUM(f.profit) / SUM(f.sales) * 100, 2) AS margen_pct
FROM fact_sales f
INNER JOIN dim_products p ON f.product_id = p.product_id
GROUP BY p.category
ORDER BY ventas_totales DESC;



-- ============================================================
-- BLOQUE 3: CONSULTAS ANALÍTICAS DE NEGOCIO (RENTABILIDAD)
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 Rentabilidad por sub-categoría (drill-down)
-- INSIGHT #3 (el más fuerte): Furniture - Tables es responsable del 96%
-- de las pérdidas de la categoría Furniture (-$17,726 de -$18,451 totales).
-- Es la única sub-categoría con margen negativo de doble dígito (-8.56%).
-- Technology - Copiers logra el mejor margen del negocio (+37.20%).
-- ------------------------------------------------------------
SELECT
    p.category,
    p.sub_category,
    COUNT(*) AS num_ventas,
    SUM(f.sales) AS ventas_totales,
    SUM(f.profit) AS ganancia_total,
    ROUND(SUM(f.profit) / SUM(f.sales) * 100, 2) AS margen_pct
FROM fact_sales f
INNER JOIN dim_products p ON f.product_id = p.product_id
GROUP BY p.category, p.sub_category
ORDER BY ganancia_total ASC;


-- ------------------------------------------------------------
-- 3.2 Rentabilidad por región (INNER JOIN)
-- INSIGHT #2: West es la región más rentable (14.94% de margen),
-- mientras que Central, aunque vende más que South, tiene el margen
-- más bajo de todas las regiones (7.92%).
-- ------------------------------------------------------------
SELECT
    l.region,
    COUNT(*) AS num_ventas,
    SUM(f.sales) AS ventas_totales,
    SUM(f.profit) AS ganancia_total,
    ROUND(SUM(f.profit) / SUM(f.sales) * 100, 2) AS margen_pct
FROM fact_sales f
INNER JOIN dim_location l ON f.location_id = l.location_id
GROUP BY l.region
ORDER BY ganancia_total DESC;


-- ------------------------------------------------------------
-- 3.3 Top 5 productos más rentables vs Top 5 que más pierden
-- Usa CTE encadenada + Window Function (RANK)
-- Insight: identifica productos puntuales a potenciar o descontinuar
-- ------------------------------------------------------------
WITH profit_por_producto AS (
    SELECT
        p.product_id,
        p.product_name,
        p.category,
        SUM(f.profit) AS ganancia_total,
        SUM(f.sales) AS ventas_totales
    FROM fact_sales f
    INNER JOIN dim_products p ON f.product_id = p.product_id
    GROUP BY p.product_id, p.product_name, p.category
),
ranking AS (
    SELECT
        *,
        RANK() OVER (ORDER BY ganancia_total DESC) AS rank_mejores,
        RANK() OVER (ORDER BY ganancia_total ASC)  AS rank_peores
    FROM profit_por_producto
)
SELECT * FROM ranking WHERE rank_mejores <= 5
UNION ALL
SELECT * FROM ranking WHERE rank_peores <= 5;


-- ------------------------------------------------------------
-- 3.4 Impacto del descuento en la rentabilidad (CASE + agregación)
-- INSIGHT CLAVE: a partir de 21% de descuento, la ganancia promedio
-- por venta se vuelve NEGATIVA. Ventas sin descuento generan +$320,988
-- en total; ventas con descuento >20% generan -$135,376 combinadas.
-- ------------------------------------------------------------
SELECT
    CASE
        WHEN discount = 0 THEN 'Sin descuento'
        WHEN discount > 0 AND discount <= 0.20 THEN 'Descuento bajo (1-20%)'
        WHEN discount > 0.20 AND discount <= 0.50 THEN 'Descuento medio (21-50%)'
        ELSE 'Descuento alto (>50%)'
    END AS rango_descuento,
    COUNT(*) AS num_ventas,
    SUM(sales) AS ventas_totales,
    SUM(profit) AS ganancia_total,
    ROUND(AVG(profit), 2) AS ganancia_promedio
FROM fact_sales
GROUP BY rango_descuento
ORDER BY ganancia_total DESC;


-- ------------------------------------------------------------
-- 3.5 LEFT JOIN: clientes que nunca compraron Technology
-- Insight: identifica oportunidad de venta cruzada para el equipo comercial.
-- Usamos LEFT JOIN (en vez de INNER) para conservar TODOS los clientes,
-- incluso los que no tienen ninguna compra en esa categoría.
-- ------------------------------------------------------------
SELECT
    c.customer_id,
    c.customer_name,
    c.segment,
    COALESCE(SUM(f.sales), 0) AS ventas_en_tecnologia
FROM dim_customers c
LEFT JOIN fact_sales f
    ON c.customer_id = f.customer_id
   AND f.product_id IN (SELECT product_id FROM dim_products WHERE category = 'Technology')
GROUP BY c.customer_id, c.customer_name, c.segment
HAVING ventas_en_tecnologia = 0;


-- ------------------------------------------------------------
-- 3.6 Subquery: productos con ganancia por debajo del promedio general
-- Insight: aunque Technology es la categoría más rentable en general,
-- productos puntuales como las impresoras 3D Cubify CubeX generan
-- pérdidas individuales de hasta -$8,880, sugiriendo revisión o
-- descontinuación de esos productos específicos.
-- ------------------------------------------------------------
SELECT
    p.product_name,
    p.category,
    SUM(f.profit) AS ganancia_total
FROM fact_sales f
INNER JOIN dim_products p ON f.product_id = p.product_id
GROUP BY p.product_name, p.category
HAVING SUM(f.profit) < (
    SELECT AVG(profit) FROM fact_sales
)
ORDER BY ganancia_total ASC
LIMIT 10;


-- ------------------------------------------------------------
-- 3.7 Evolución temporal de ganancia por año y trimestre
-- Insight: identifica estacionalidad y tendencia de rentabilidad
-- ------------------------------------------------------------
SELECT
    dc.year,
    dc.quarter,
    SUM(f.sales) AS ventas_totales,
    SUM(f.profit) AS ganancia_total,
    ROUND(SUM(f.profit) / SUM(f.sales) * 100, 2) AS margen_pct
FROM fact_sales f
INNER JOIN dim_calendar dc ON f.date_id = dc.date_id
GROUP BY dc.year, dc.quarter
ORDER BY dc.year, dc.quarter;


-- ------------------------------------------------------------
-- 3.8 Clasificación de cada venta usando la FUNCTION fn_clasificar_margen
-- Resume cuántas ventas son Rentables / Neutras / Pérdida en todo el negocio
-- ------------------------------------------------------------
SELECT
    fn_clasificar_margen(sales, profit) AS clasificacion,
    COUNT(*) AS num_ventas,
    SUM(profit) AS ganancia_total
FROM fact_sales
GROUP BY clasificacion
ORDER BY ganancia_total DESC;



-- ============================================================
-- BLOQUE 4: VISTAS DE NEGOCIO (mínimo 2 requeridas)
-- ============================================================

-- ------------------------------------------------------------
-- VISTA 1: Rentabilidad por categoría y región
-- Vista de negocio reutilizable para dashboards/reportes
-- ------------------------------------------------------------
DROP VIEW IF EXISTS vw_rentabilidad_categoria_region;

CREATE VIEW vw_rentabilidad_categoria_region AS
SELECT
    p.category,
    l.region,
    COUNT(*) AS num_ventas,
    SUM(f.sales) AS ventas_totales,
    SUM(f.profit) AS ganancia_total,
    ROUND(SUM(f.profit) / SUM(f.sales) * 100, 2) AS margen_pct
FROM fact_sales f
INNER JOIN dim_products p ON f.product_id = p.product_id
INNER JOIN dim_location l ON f.location_id = l.location_id
GROUP BY p.category, l.region;

SELECT * FROM vw_rentabilidad_categoria_region ORDER BY margen_pct ASC;


-- ------------------------------------------------------------
-- VISTA 2: Impacto del descuento en rentabilidad
-- Reutiliza la lógica de CASE validada en 3.4
-- ------------------------------------------------------------
DROP VIEW IF EXISTS vw_impacto_descuento;

CREATE VIEW vw_impacto_descuento AS
SELECT
    CASE
        WHEN discount = 0 THEN 'Sin descuento'
        WHEN discount > 0 AND discount <= 0.20 THEN 'Descuento bajo (1-20%)'
        WHEN discount > 0.20 AND discount <= 0.50 THEN 'Descuento medio (21-50%)'
        ELSE 'Descuento alto (>50%)'
    END AS rango_descuento,
    COUNT(*) AS num_ventas,
    SUM(sales) AS ventas_totales,
    SUM(profit) AS ganancia_total,
    ROUND(AVG(profit), 2) AS ganancia_promedio
FROM fact_sales
GROUP BY rango_descuento;

SELECT * FROM vw_impacto_descuento;



-- ============================================================
-- BLOQUE 5: FUNCTION (mínimo 1 requerida)
-- ============================================================

-- ------------------------------------------------------------
-- FUNCTION: Clasificar el margen de una venta
-- Clasifica cualquier venta como Rentable / Neutro / Pérdida
-- según su margen (profit/sales). Útil para reportes y dashboards.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_clasificar_margen;

DELIMITER $$

CREATE FUNCTION fn_clasificar_margen(p_sales DECIMAL(10,4), p_profit DECIMAL(10,4))
RETURNS VARCHAR(20)
DETERMINISTIC
BEGIN
    DECLARE v_margen DECIMAL(10,4);

    IF p_sales = 0 THEN
        RETURN 'Sin ventas';
    END IF;

    SET v_margen = p_profit / p_sales;

    IF v_margen >= 0.10 THEN
        RETURN 'Rentable';
    ELSEIF v_margen >= 0 THEN
        RETURN 'Neutro';
    ELSE
        RETURN 'Pérdida';
    END IF;
END$$

DELIMITER ;

-- Prueba de la función
SELECT
    row_id,
    sales,
    profit,
    fn_clasificar_margen(sales, profit) AS clasificacion
FROM fact_sales
LIMIT 10;



