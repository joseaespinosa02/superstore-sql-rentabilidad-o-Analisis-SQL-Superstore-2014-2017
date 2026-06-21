# Análisis de Rentabilidad - Superstore Sales (SQL)

Proyecto del módulo de SQL del Master en Data Science (Evolve España). Diseño de un modelo de base de datos relacional y análisis exploratorio en SQL sobre el dataset público **Sample - Superstore** (Kaggle), enfocado en responder una pregunta de negocio central: **¿dónde gana y dónde pierde dinero la empresa?**

## Objetivo

Diseñar, implementar y analizar una base de datos relacional con un modelo dimensional (esquema en estrella), garantizando integridad de los datos y extrayendo insights de negocio mediante SQL avanzado.

## Dataset

- **Fuente**: [Sample - Superstore](https://www.kaggle.com/datasets) (Kaggle)
- **Periodo**: 2014-01-03 a 2017-12-30
- **Volumen**: 9,994 transacciones de venta
- **Motor SQL**: MySQL 8.0

## Modelo de datos

Esquema en estrella con 1 tabla de hechos y 4 tablas de dimensiones:

| Tabla | Tipo | Granularidad | PK |
|-------|------|--------------|-----|
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

## Arquitectura del proyecto

```
stg_superstore (staging, carga cruda del CSV)
        ↓
dim_customers / dim_products / dim_location / dim_calendar / fact_sales (modelo dimensional limpio)
        ↓
vw_rentabilidad_categoria_region / vw_impacto_descuento (vistas de negocio)
        ↓
Consultas analíticas (03_eda.sql)
```

## Estructura del repositorio

```
sql/
├── 01_schema.sql   # Creación de tablas, PKs, FKs, constraints, índice
├── 02_data.sql     # Carga del CSV a staging y transformación al modelo dimensional
├── 03_eda.sql      # Calidad de datos, EDA, consultas de negocio, vistas y función
└── README.md
```

## Cómo ejecutar el proyecto

1. Crear la base de datos y las tablas:
   ```sql
   SOURCE 01_schema.sql;
   ```
2. Ajustar la ruta del archivo CSV en `02_data.sql` (sentencia `LOAD DATA LOCAL INFILE`) a la ubicación local del archivo `Sample - Superstore.csv`, y ejecutar:
   ```sql
   SOURCE 02_data.sql;
   ```
3. Ejecutar el análisis completo:
   ```sql
   SOURCE 03_eda.sql;
   ```

> Nota: `LOAD DATA LOCAL INFILE` requiere `local_infile=1` habilitado tanto en el servidor MySQL como en el cliente (en MySQL Workbench: Edit Connection → Advanced → Others → `OPT_LOCAL_INFILE=1`).

## Calidad de datos

- **Nulos**: 0 valores nulos en las columnas críticas de `fact_sales`.
- **Duplicados**: se detectaron 8 casos de mismo `(order_id, product_id, customer_id)` con `row_id` distinto mediante `RANK() OVER (PARTITION BY...)`. Tras inspección, corresponden a líneas de pedido separadas del mismo producto dentro de la misma orden — comportamiento de compra válido, no se eliminan.
- **Fechas**: rango validado entre 2014-01-03 y 2017-12-30, consistente con el dataset.
- **Outliers de `profit`**: se identificaron transacciones con pérdidas extremas (hasta -$6,599) asociadas a descuentos del 70-80%. No son errores de carga, sino información de negocio real, analizada en el EDA en lugar de corregida.

## Insights de negocio

**1. Furniture es la categoría con peor margen, a pesar de vender casi igual que las demás.**
Genera un volumen de ventas similar a Technology y Office Supplies, pero su margen de ganancia es aproximadamente 7 veces menor (2.5% vs ~17%).

**2. La región Central es la menos rentable, pese a no ser la que menos vende.**
West lidera en margen (14.94%), mientras que Central, aunque vende más que South, tiene el margen más bajo de todas las regiones (7.92%).

**3. La sub-categoría "Tables" concentra el 96% de las pérdidas de Furniture.**
Con un margen de -8.56%, es la única sub-categoría con pérdida de doble dígito porcentual, y explica casi por completo el bajo margen de toda la categoría Furniture. En el extremo opuesto, Technology - Copiers logra el mejor margen del negocio (+37.20%).

**Causa raíz identificada**: a partir de un descuento superior al 20%, la ganancia promedio por venta se vuelve negativa. Las ventas sin descuento generan en conjunto +$320,988, mientras que las ventas con descuento mayor al 20% generan -$135,376 combinadas — los descuentos agresivos no están funcionando como estrategia comercial, están generando pérdidas netas.

## Técnicas SQL aplicadas

`INSERT` · `UPDATE` · `DELETE` · `CAST` / `STR_TO_DATE` · funciones de fecha (`YEAR`, `MONTH`, `QUARTER`, `DAYNAME`) · `SUM` / `COUNT` / `AVG` · subqueries · `INNER JOIN` y `LEFT JOIN` · `CASE` · CTEs encadenadas (`WITH`) · funciones ventana (`RANK() OVER PARTITION BY`) · transacciones (`START TRANSACTION` / `COMMIT` / `ROLLBACK`) · índice · 2 `VIEW` · 1 `FUNCTION`

## Autor

José Alejandro Espinosa — Master en Data Science, Evolve España
