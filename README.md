# Superstore Sales - Análisis de Rentabilidad (SQL)

## 1. Objetivo
Diseñar, implementar y analizar una base de datos relacional con un modelo
dimensional (esquema en estrella) sobre las ventas de un Superstore de
retail en USA durante el período 2014-2017, para responder una pregunta de
negocio central: **¿dónde gana y dónde pierde dinero la empresa?**

## 2. Dataset
- **Fuente:** [Kaggle - Sample Superstore](https://www.kaggle.com/datasets)
- **Filas:** 9,994 transacciones | **Período:** 2014-01-03 a 2017-12-30
- **Motor SQL:** MySQL 8.0
- **Archivo de carga:** `Sample - Superstore.csv` (vía `LOAD DATA LOCAL INFILE` a `stg_superstore`)

## 2.1 Modelo de datos

Esquema en estrella con 1 tabla de hechos y 4 tablas de dimensiones:

| Tabla | Tipo | Granularidad | PK |
|---|---|---|---|
| `fact_sales` | Hechos | 1 fila por línea de producto dentro de un pedido | `row_id` |
| `dim_customers` | Dimensión | 1 fila por cliente único | `customer_id` |
| `dim_products` | Dimensión | 1 fila por producto único | `product_id` |
| `dim_location` | Dimensión | 1 fila por combinación única ciudad/estado/CP | `location_id` (surrogate) |
| `dim_calendar` | Dimensión | 1 fila por fecha única presente en las ventas | `date_id` (surrogate) |

### Decisiones de diseño
- **`row_id` como PK de `fact_sales`**: un mismo `Order ID` puede tener varias líneas de producto, por lo que `Order ID` no es único por fila; `row_id` sí lo es.
- **`location_id` y `date_id` como surrogate keys**: el CSV original no trae un identificador único de ubicación ni de fecha, así que se generan con `AUTO_INCREMENT`.
- **Constraints de negocio** (`CHECK`): `quantity > 0`, `sales >= 0`, `discount BETWEEN 0 AND 1` — evitan cargar datos que violen reglas básicas del negocio.
- **Índice en `fact_sales(date_id)`**: las consultas de negocio filtran y agrupan por fecha con frecuencia (tendencias, estacionalidad), por lo que este índice acelera esos JOINs y WHERE.

## 3. Preguntas de negocio
1. ¿Qué categoría genera más ventas y cuál tiene mejor margen de ganancia?
2. ¿Qué región es la más y la menos rentable?
3. ¿Qué sub-categoría concentra las pérdidas dentro de Furniture?
4. ¿Cómo afecta el nivel de descuento a la rentabilidad de las ventas?

## 4. Calidad de datos

El dataset presentaba puntos a validar antes del análisis:

| Problema | Solución |
|---|---|
| Nulos en columnas críticas de `fact_sales` | Validado con `IS NULL` — 0 valores nulos encontrados |
| Posibles duplicados por `(order_id, product_id, customer_id)` | Detectados con `RANK() OVER (PARTITION BY...)` — 8 casos, corresponden a líneas de pedido separadas del mismo producto en la misma orden; comportamiento de compra válido, no se eliminan |
| Fechas en formato texto en staging | Convertidas con `CAST` / `STR_TO_DATE`; rango validado entre 2014-01-03 y 2017-12-30 |
| Outliers de `profit` | Transacciones con pérdidas extremas (hasta -$6,599) asociadas a descuentos del 70-80%; no son errores de carga, sino información de negocio real, analizada en el EDA en lugar de corregida |

**Corrección controlada con transacción:** se evaluó reasignar el
`ship_mode` de 21 pedidos de la sub-categoría Tables (la de mayores
pérdidas) marcados como envío `Same Day`, para simular el efecto de un
cambio logístico. El `UPDATE` se envolvió en una transacción
(`START TRANSACTION`) para poder revisar el resultado con un `SELECT`
antes de confirmar. Tras la verificación se decidió no aplicar el cambio
en producción y se ejecutó `ROLLBACK` — demostrando el propósito real de
una transacción: probar un cambio de forma segura y poder deshacerlo por
completo si no se confirma como definitivo, sin dejar la base de datos en
un estado intermedio.

## 5. Arquitectura

```
stg_superstore (staging, carga cruda del CSV)
        ↓
dim_customers / dim_products / dim_location / dim_calendar / fact_sales (modelo dimensional limpio)
        ↓
vw_rentabilidad_categoria_region / vw_impacto_descuento (vistas de negocio)
        ↓
Consultas analíticas (03_eda.sql)
```

## 6. Hallazgos principales

**1. Furniture es la categoría con peor margen, a pesar de vender casi igual que las demás**
Genera un volumen de ventas similar a Technology y Office Supplies, pero su
margen de ganancia es aproximadamente 7 veces menor (2.5% vs ~17%). Esto
sugiere que la política de descuentos de Furniture necesita revisarse de
forma específica, en vez de aplicarle el mismo criterio que al resto de
categorías.

**2. La región Central es la menos rentable, pese a no ser la que menos vende**
West lidera en margen (14.94%), mientras que Central, aunque vende más que
South, tiene el margen más bajo de todas las regiones (7.92%). Vale la pena
auditar qué está haciendo Central distinto a West en términos de descuentos
y mix de producto, para entender de dónde viene esa diferencia.

**3. La sub-categoría "Tables" concentra el 96% de las pérdidas de Furniture**
Con un margen de -8.56%, es la única sub-categoría con pérdida de doble
dígito porcentual, y explica casi por completo el bajo margen de toda la
categoría Furniture. En el extremo opuesto, Technology - Copiers logra el
mejor margen del negocio (+37.20%). Dos caminos posibles aquí: renegociar
costes de aprovisionamiento de Tables, o directamente limitar el descuento
máximo permitido en esa sub-categoría.

**Causa raíz identificada:** a partir de un descuento superior al 20%, la
ganancia promedio por venta se vuelve negativa. Las ventas sin descuento
generan en conjunto +$320,988, mientras que las ventas con descuento mayor
al 20% generan -$135,376 combinadas. Los descuentos agresivos no están
funcionando como estrategia comercial — están generando pérdidas netas, y
un tope del 20% (con excepciones justificadas caso por caso) parece el
punto de partida más razonable para frenar esto.

## 7. Cómo ejecutar

```sql
-- 1. Crear la base de datos y las tablas
SOURCE 01_schema.sql;

-- 2. Ajustar la ruta del CSV en 02_data.sql (LOAD DATA LOCAL INFILE)
--    a la ubicación local de "Sample - Superstore.csv", y ejecutar:
SOURCE 02_data.sql;

-- 3. Ejecutar el análisis completo
SOURCE 03_eda.sql;
```

> **Nota:** `LOAD DATA LOCAL INFILE` requiere `local_infile=1` habilitado
> tanto en el servidor MySQL como en el cliente (en MySQL Workbench:
> *Edit Connection → Advanced → Others → `OPT_LOCAL_INFILE=1`*).

## 8. Estructura del repositorio

El proyecto está dividido en capas bien diferenciadas, siguiendo el flujo
staging → modelo dimensional → vistas → análisis:

```
superstore-sql-rentabilidad-o-Analisis-SQL-Superstore-2014-2017/
├── README.md
├── model.png            # Diagrama ER del esquema en estrella
└── sql/
    ├── 01_schema.sql    # Creación de tablas, PKs, FKs, constraints, índice
    ├── 02_data.sql      # Carga del CSV a staging y transformación al modelo dimensional
    └── 03_eda.sql       # Calidad de datos, EDA, consultas de negocio, vistas y función
```

## 9. Técnicas SQL aplicadas

`INSERT` · `UPDATE` · `DELETE` · `CAST` / `STR_TO_DATE` · funciones de fecha
(`YEAR`, `MONTH`, `QUARTER`, `DAYNAME`) · `SUM` / `COUNT` / `AVG` ·
subqueries · `INNER JOIN` y `LEFT JOIN` · `CASE` · CTEs encadenadas (`WITH`) ·
funciones ventana (`RANK() OVER PARTITION BY`) · transacciones
(`START TRANSACTION` / `COMMIT` / `ROLLBACK`) · índice · 2 `VIEW` · 1 `FUNCTION`

## 10. Tecnologías utilizadas
- **Base de datos:** MySQL 8.0
- **Gestor de base de datos:** MySQL Workbench
- **Control de versiones:** Git y GitHub

## Autor
José Alejandro Espinosa — Master en Data Science, Evolve España
