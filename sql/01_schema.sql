-- ============================================================
-- 01_SCHEMA.SQL
-- Proyecto: Análisis de Rentabilidad - Superstore Sales
-- Modelo dimensional: 1 tabla de Hechos + 4 tablas de Dimensiones
-- Motor: MySQL 8.0
-- ============================================================

CREATE DATABASE IF NOT EXISTS superstore_db;
USE superstore_db;


-- ============================================================
-- TABLA STAGING (carga inicial cruda del CSV, sin normalizar)
-- Granularidad: igual al CSV original, 1 fila por línea de pedido
-- ============================================================
DROP TABLE IF EXISTS stg_superstore;

CREATE TABLE stg_superstore (
    row_id        INT,
    order_id      VARCHAR(20),
    order_date    VARCHAR(20),   -- texto en origen, se convierte con CAST/STR_TO_DATE en 02_data.sql
    ship_date     VARCHAR(20),
    ship_mode     VARCHAR(50),
    customer_id   VARCHAR(20),
    customer_name VARCHAR(100),
    segment       VARCHAR(50),
    country       VARCHAR(50),
    city          VARCHAR(100),
    state         VARCHAR(50),
    postal_code   VARCHAR(20),
    region        VARCHAR(50),
    product_id    VARCHAR(20),
    category      VARCHAR(50),
    sub_category  VARCHAR(50),
    product_name  VARCHAR(255),
    sales         DECIMAL(10,4),
    quantity      INT,
    discount      DECIMAL(5,2),
    profit        DECIMAL(10,4)
);


-- Eliminamos primero la tabla de hechos (depende de las dimensiones via FK)
DROP TABLE IF EXISTS fact_sales;
DROP TABLE IF EXISTS dim_customers;
DROP TABLE IF EXISTS dim_products;
DROP TABLE IF EXISTS dim_location;
DROP TABLE IF EXISTS dim_calendar;


-- ============================================================
-- DIM_CUSTOMERS
-- Granularidad: 1 fila por cliente único
-- PK: customer_id ya viene único en el CSV original, lo reutilizamos
-- ============================================================
CREATE TABLE dim_customers (
    customer_id   VARCHAR(20) NOT NULL,
    customer_name VARCHAR(100) NOT NULL,
    segment       VARCHAR(50) NOT NULL,
    CONSTRAINT pk_dim_customers PRIMARY KEY (customer_id)
);


-- ============================================================
-- DIM_PRODUCTS
-- Granularidad: 1 fila por producto único
-- PK: product_id ya viene único en el CSV original
-- ============================================================
CREATE TABLE dim_products (
    product_id   VARCHAR(20) NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    category     VARCHAR(50) NOT NULL,
    sub_category VARCHAR(50) NOT NULL,
    CONSTRAINT pk_dim_products PRIMARY KEY (product_id)
);


-- ============================================================
-- DIM_LOCATION
-- Granularidad: 1 fila por combinación única de ciudad/estado/CP
-- PK: location_id es un ID propio (surrogate key), porque el CSV
--      no trae un identificador único de ubicación
-- UNIQUE: evita duplicar la misma combinación ciudad/estado/CP
-- DEFAULT: country casi siempre es 'United States' en este dataset
-- ============================================================
CREATE TABLE dim_location (
    location_id INT NOT NULL AUTO_INCREMENT,
    city        VARCHAR(100) NOT NULL,
    state       VARCHAR(50) NOT NULL,
    region      VARCHAR(50) NOT NULL,
    country     VARCHAR(50) NOT NULL DEFAULT 'United States',
    postal_code VARCHAR(10),
    CONSTRAINT pk_dim_location PRIMARY KEY (location_id),
    CONSTRAINT uq_location UNIQUE (city, state, postal_code)
);


-- ============================================================
-- DIM_CALENDAR
-- Granularidad: 1 fila por fecha única presente en las ventas
-- PK: date_id propio (surrogate), full_date es UNIQUE
-- CHECK: month entre 1-12 y quarter entre 1-4 (validación de rango)
-- ============================================================
CREATE TABLE dim_calendar (
    date_id     INT NOT NULL AUTO_INCREMENT,
    full_date   DATE NOT NULL,
    year        INT NOT NULL,
    month       INT NOT NULL,
    month_name  VARCHAR(20) NOT NULL,
    quarter     INT NOT NULL,
    day_of_week VARCHAR(20) NOT NULL,
    CONSTRAINT pk_dim_calendar PRIMARY KEY (date_id),
    CONSTRAINT uq_full_date UNIQUE (full_date),
    CONSTRAINT chk_month CHECK (month BETWEEN 1 AND 12),
    CONSTRAINT chk_quarter CHECK (quarter BETWEEN 1 AND 4)
);


-- ============================================================
-- FACT_SALES (Tabla de Hechos)
-- Granularidad: 1 fila por línea de producto dentro de un pedido
--               (igual que el CSV original: row_id = 1 línea de venta)
-- PK: row_id reutilizado del CSV (ya es único por línea)
-- FK: customer_id, product_id, location_id, date_id -> dimensiones
-- CHECK: quantity > 0, sales >= 0, discount entre 0 y 1
--        (reglas de negocio: no se venden cantidades negativas,
--         un descuento no puede ser mayor al 100%)
-- DEFAULT: discount = 0 (la mayoría de ventas no tienen descuento)
-- ============================================================
CREATE TABLE fact_sales (
    row_id      INT NOT NULL,
    order_id    VARCHAR(20) NOT NULL,
    customer_id VARCHAR(20) NOT NULL,
    product_id  VARCHAR(20) NOT NULL,
    location_id INT NOT NULL,
    date_id     INT NOT NULL,
    ship_date   DATE,
    ship_mode   VARCHAR(50) NOT NULL,
    sales       DECIMAL(10,4) NOT NULL,
    quantity    INT NOT NULL,
    discount    DECIMAL(5,2) NOT NULL DEFAULT 0,
    profit      DECIMAL(10,4) NOT NULL,
    CONSTRAINT pk_fact_sales PRIMARY KEY (row_id),
    CONSTRAINT fk_fact_customer FOREIGN KEY (customer_id) REFERENCES dim_customers(customer_id),
    CONSTRAINT fk_fact_product  FOREIGN KEY (product_id)  REFERENCES dim_products(product_id),
    CONSTRAINT fk_fact_location FOREIGN KEY (location_id) REFERENCES dim_location(location_id),
    CONSTRAINT fk_fact_date     FOREIGN KEY (date_id)     REFERENCES dim_calendar(date_id),
    CONSTRAINT chk_quantity CHECK (quantity > 0),
    CONSTRAINT chk_sales CHECK (sales >= 0),
    CONSTRAINT chk_discount CHECK (discount BETWEEN 0 AND 1)
);


-- ============================================================
-- ÍNDICE
-- Justificación: las consultas de negocio frecuentemente filtran
-- y agrupan por fecha (tendencias mensuales, anuales, etc.)
-- Este índice acelera esos JOINs y WHERE sobre date_id
-- ============================================================
CREATE INDEX idx_fact_sales_date ON fact_sales(date_id);
