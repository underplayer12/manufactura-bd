-- =====================================================================
-- PRUEBAS DE LOS 3 REQUISITOS DEL PROYECTO (para capturas del informe)
-- Ejecutar DESPUÉS de mejoras_diseno.sql. Cada bloque muestra un título
-- y el resultado; toma una captura por requisito.
--
--  R1. Registrar productos, materias primas, proveedores y órdenes de producción
--  R2. Consultar el inventario disponible
--  R3. Actualizar el inventario automáticamente con las operaciones de producción
-- =====================================================================
SET NAMES utf8mb4;
USE manufactura;

-- ---------------------------------------------------------------------
-- R1. REGISTRAR  (todo dentro de una transacción que se deshace al final,
--     para no ensuciar tus datos; quita el ROLLBACK si quieres conservarlos)
-- ---------------------------------------------------------------------
SELECT 'R1. REGISTRAR: conteo ANTES' AS prueba,
       (SELECT COUNT(*) FROM proveedor) proveedores, (SELECT COUNT(*) FROM materia_prima) materias,
       (SELECT COUNT(*) FROM producto) productos, (SELECT COUNT(*) FROM orden_produccion) ordenes;

START TRANSACTION;
CALL sp_registrar_proveedor('900999999-1', 'Proveedor de Prueba S.A.S.', '3000000000', 'prueba@correo.co');
INSERT INTO materia_prima (codigo, nombre, unidad_medida, stock_minimo) VALUES ('MP-999', 'Materia de prueba', 'KG', 10);
INSERT INTO producto (codigo, nombre, precio_venta) VALUES ('PR-999', 'Producto de prueba', 100000);
CALL sp_crear_orden(1, 5);

SELECT 'R1. REGISTRAR: conteo DESPUÉS (cada cifra subió en 1)' AS prueba,
       (SELECT COUNT(*) FROM proveedor) proveedores, (SELECT COUNT(*) FROM materia_prima) materias,
       (SELECT COUNT(*) FROM producto) productos, (SELECT COUNT(*) FROM orden_produccion) ordenes;
ROLLBACK;

-- ---------------------------------------------------------------------
-- R2. CONSULTAR INVENTARIO DISPONIBLE
-- ---------------------------------------------------------------------
SELECT 'R2.1 Inventario de materia prima y alerta de reabastecimiento' AS prueba;
CALL sp_get_inventario();

SELECT 'R2.2 Dónde está guardada cada materia (por bodega)' AS prueba;
SELECT bodega_codigo, codigo, materia_prima, cantidad FROM vista_inventario_por_bodega
 WHERE codigo IN ('MP-001', 'MP-003', 'MP-007') ORDER BY codigo, bodega_codigo;

SELECT 'R2.3 Producto terminado disponible y cuántas unidades más se pueden fabricar HOY' AS prueba;
SELECT codigo, nombre, stock_actual AS en_bodega, fn_max_producible(id_producto) AS se_pueden_fabricar_mas
  FROM producto ORDER BY codigo;

-- ---------------------------------------------------------------------
-- R3. ACTUALIZACIÓN AUTOMÁTICA (esta prueba SÍ cambia datos: crea y completa una orden de 2 sillas)
-- ---------------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS antes_mp;
CREATE TEMPORARY TABLE antes_mp AS SELECT id_materia_prima, stock_actual FROM materia_prima;
SET @sillas_antes = (SELECT stock_actual FROM producto WHERE codigo = 'PR-001');

CALL sp_crear_orden(1, 2);
SET @orden = (SELECT MAX(id_orden) FROM orden_produccion);
CALL sp_completar_orden(@orden);          -- UNA sola llamada; el resto lo hace la base sola

SELECT 'R3.1 La orden quedó COMPLETADA' AS prueba;
SELECT id_orden, estado, fecha_creacion, fecha_cierre FROM orden_produccion WHERE id_orden = @orden;

SELECT 'R3.2 Materia prima descontada sola = receta x 2 (la columna diferencia debe ser 0)' AS prueba;
SELECT mp.codigo, a.stock_actual AS antes, mp.stock_actual AS despues,
       a.stock_actual - mp.stock_actual AS descontado,
       r.cantidad_por_unidad * 2 AS esperado_por_receta,
       (a.stock_actual - mp.stock_actual) - r.cantidad_por_unidad * 2 AS diferencia
  FROM receta r
  JOIN materia_prima mp ON mp.id_materia_prima = r.id_materia_prima
  JOIN antes_mp a       ON a.id_materia_prima = r.id_materia_prima
 WHERE r.id_producto = 1 ORDER BY mp.codigo;

SELECT 'R3.3 Producto terminado sumado solo (+2)' AS prueba;
SELECT @sillas_antes AS sillas_antes, stock_actual AS sillas_despues FROM producto WHERE codigo = 'PR-001';

SELECT 'R3.4 Trazabilidad automática: de qué lotes salió cada insumo de esa orden' AS prueba;
SELECT materia, codigo_lote, proveedor, cantidad_consumida
  FROM vista_trazabilidad_lote WHERE id_orden = @orden ORDER BY materia, codigo_lote;

SELECT 'R3.5 Conciliación final: stock = lotes = bodegas (todas las diferencias en 0)' AS prueba;
SELECT mp.codigo, mp.stock_actual,
       mp.stock_actual - (SELECT COALESCE(SUM(cantidad_disponible), 0) FROM lote WHERE id_materia_prima = mp.id_materia_prima) AS dif_lotes,
       mp.stock_actual - (SELECT COALESCE(SUM(cantidad), 0) FROM stock_bodega WHERE id_materia_prima = mp.id_materia_prima) AS dif_bodegas
  FROM materia_prima mp ORDER BY mp.codigo;
