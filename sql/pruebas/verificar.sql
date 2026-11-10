-- Verificación automática (solo lee, no cambia nada). Cada fila debe decir OK.
-- Los scripts/verificar.* fallan si aparece alguna fila con FALLA.
USE manufactura;

SELECT 'stock materia = suma de lotes = suma de bodegas' AS prueba,
       IF(COUNT(*) = 0, 'OK', 'FALLA') AS resultado
  FROM materia_prima mp
 WHERE mp.stock_actual <> (SELECT COALESCE(SUM(cantidad_disponible), 0) FROM lote WHERE id_materia_prima = mp.id_materia_prima)
    OR mp.stock_actual <> (SELECT COALESCE(SUM(cantidad), 0) FROM stock_bodega WHERE id_materia_prima = mp.id_materia_prima)
UNION ALL
SELECT 'stock materia = suma del kardex', IF(COUNT(*) = 0, 'OK', 'FALLA')
  FROM materia_prima mp
 WHERE mp.stock_actual <> (SELECT COALESCE(SUM(CASE WHEN tipo = 'ENTRADA' THEN cantidad ELSE -cantidad END), 0)
                             FROM movimiento_inventario WHERE id_materia_prima = mp.id_materia_prima)
UNION ALL
SELECT 'saldo del kardex nunca negativo (orden de fecha)', IF(COUNT(*) = 0, 'OK', 'FALLA')
  FROM (SELECT SUM(CASE WHEN tipo = 'ENTRADA' THEN cantidad ELSE -cantidad END)
                 OVER (PARTITION BY id_materia_prima ORDER BY fecha, id_movimiento) AS saldo
          FROM movimiento_inventario) z
 WHERE saldo < 0
UNION ALL
SELECT 'cada salida consumió exactamente lo que salió de lotes', IF(COUNT(*) = 0, 'OK', 'FALLA')
  FROM movimiento_inventario m
  LEFT JOIN (SELECT id_movimiento, SUM(cantidad) c FROM consumo_lote GROUP BY id_movimiento) x
         ON x.id_movimiento = m.id_movimiento
 WHERE m.tipo = 'SALIDA' AND COALESCE(x.c, 0) <> m.cantidad
UNION ALL
SELECT 'producto terminado = producido - despachado', IF(COUNT(*) = 0, 'OK', 'FALLA')
  FROM producto pr
 WHERE pr.stock_actual <>
       COALESCE((SELECT SUM(cantidad) FROM orden_produccion WHERE id_producto = pr.id_producto AND estado = 'COMPLETADA'), 0)
     - COALESCE((SELECT SUM(cantidad) FROM despacho WHERE id_producto = pr.id_producto), 0)
UNION ALL
SELECT 'compras con costo registrado', IF(COUNT(*) = 0, 'OK', 'FALLA')
  FROM movimiento_inventario WHERE tipo = 'ENTRADA' AND costo_unitario IS NULL
UNION ALL
SELECT 'cada oferta de proveedor tiene exactamente 1 precio vigente', IF(COUNT(*) = 0, 'OK', 'FALLA')
  FROM proveedor_materia_prima pmp
 WHERE (SELECT COUNT(*) FROM historial_precio h
         WHERE h.id_proveedor = pmp.id_proveedor AND h.id_materia_prima = pmp.id_materia_prima
           AND h.vigente_hasta IS NULL) <> 1
UNION ALL
SELECT 'despachos y pedidos despachados cuadran en unidades', IF(
       (SELECT COALESCE(SUM(cantidad), 0) FROM despacho) =
       (SELECT COALESCE(SUM(d.cantidad), 0) FROM pedido_venta_detalle d
          JOIN pedido_venta p ON p.id_pedido = d.id_pedido WHERE p.estado = 'DESPACHADO'), 'OK', 'FALLA')
UNION ALL
SELECT 'catálogo mínimo cargado (>=14 proveedores, >=18 materias, >=9 productos)', IF(
       (SELECT COUNT(*) FROM proveedor) >= 14 AND (SELECT COUNT(*) FROM materia_prima) >= 18
       AND (SELECT COUNT(*) FROM producto) >= 9, 'OK', 'FALLA')
UNION ALL
SELECT 'modulo de la aplicacion instalado (usuarios, bitacora, procedimientos)', IF(
       EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'modulo_aplicacion')
       AND (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = DATABASE() AND routine_name LIKE 'sp\\_%') >= 70
       AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name IN ('usuario', 'bitacora') HAVING COUNT(*) = 2), 'OK', 'FALLA');
