-- =====================================================================
-- PRUEBA DE CARGA (OPCIONAL) - ¿aguanta la base 400 mil movimientos?
--
-- Trabaja en una COPIA llamada manufactura_carga. Tu base "manufactura"
-- no se toca. Ejecutar después de mejoras_estructura.sql.
-- Tarda ~20-40 segundos. Sirve como evidencia para el informe.
-- =====================================================================

SET NAMES utf8mb4;
DROP DATABASE IF EXISTS manufactura_carga;
CREATE DATABASE manufactura_carga CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE manufactura_carga;

-- Copia solo la estructura de las dos tablas grandes (con sus índices)
CREATE TABLE movimiento_inventario LIKE manufactura.movimiento_inventario;
CREATE TABLE orden_produccion      LIKE manufactura.orden_produccion;

SET SESSION cte_max_recursion_depth = 400000;
SET autocommit = 0;

-- 400.000 movimientos repartidos en 900 días
INSERT INTO movimiento_inventario (id_materia_prima, tipo, cantidad, costo_unitario, fecha, observacion)
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 400000)
SELECT 1 + MOD(i, 10), 'ENTRADA', 1 + MOD(i, 50), 1000,
       DATE_ADD('2024-01-01', INTERVAL MOD(i * 37, 900) DAY), 'carga de prueba'
  FROM n;

-- 200.000 órdenes (un tercio pendientes, sin fecha de cierre)
INSERT INTO orden_produccion (id_producto, cantidad, estado, fecha_creacion, fecha_cierre)
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 200000)
SELECT 1 + MOD(i, 5), 10, ELT(1 + MOD(i, 3), 'COMPLETADA', 'CANCELADA', 'PENDIENTE'),
       DATE_ADD('2024-01-01', INTERVAL MOD(i, 900) DAY),
       IF(MOD(i, 3) = 2, NULL, DATE_ADD('2024-01-01', INTERVAL MOD(i, 900) + 2 DAY))
  FROM n;
COMMIT;
ANALYZE TABLE movimiento_inventario, orden_produccion;

-- ---------------------------------------------------------------------
-- COMPARACIÓN: la columna "type" del EXPLAIN dice cómo busca MySQL.
--   ALL   = lee la tabla completa (malo con muchas filas)
--   ref / range = salta directo con un índice (bueno)
-- ---------------------------------------------------------------------
-- A) SIN los índices nuevos (se quitan en la copia)
DROP INDEX idx_op_estado_fecha  ON orden_produccion;
DROP INDEX idx_mov_fecha        ON movimiento_inventario;
DROP INDEX idx_mov_materia_tipo ON movimiento_inventario;

EXPLAIN SELECT id_orden FROM orden_produccion
         WHERE estado = 'PENDIENTE' ORDER BY fecha_creacion DESC LIMIT 20;
EXPLAIN SELECT COUNT(*) FROM movimiento_inventario
         WHERE fecha >= '2025-03-01' AND fecha < '2025-04-01';

-- B) CON los índices nuevos
CREATE INDEX idx_op_estado_fecha  ON orden_produccion (estado, fecha_creacion);
CREATE INDEX idx_mov_fecha        ON movimiento_inventario (fecha);
CREATE INDEX idx_mov_materia_tipo ON movimiento_inventario (id_materia_prima, tipo);
ANALYZE TABLE movimiento_inventario, orden_produccion;

EXPLAIN SELECT id_orden FROM orden_produccion
         WHERE estado = 'PENDIENTE' ORDER BY fecha_creacion DESC LIMIT 20;
EXPLAIN SELECT COUNT(*) FROM movimiento_inventario
         WHERE fecha >= '2025-03-01' AND fecha < '2025-04-01';

-- Al terminar, para no ocupar espacio:
-- DROP DATABASE manufactura_carga;
