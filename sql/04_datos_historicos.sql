-- =====================================================================
-- DATOS HISTÓRICOS: catálogo ampliado + 12 meses de operación
-- (4 de agosto de 2025 a 2 de agosto de 2026)
-- Ejecutar DESPUÉS de mejoras_estructura.sql
--
-- QUÉ AGREGA
--   * 6 proveedores, 8 materias primas y 4 productos nuevos (con recetas)
--   * compras, órdenes de producción, consumos y despachos de todo un año
--
-- QUÉ NO TOCA (por diseño)
--   * Nada de lo anterior se borra ni se modifica: ni proveedores, ni recetas
--     de los productos 1 a 5, ni sus 11 órdenes, ni los precios.
--   * El historial nuevo es anterior al 4 de agosto de 2026 (donde empezaban tus
--     datos) y queda en neto cero para las 10 materias y 5 productos originales:
--     el stock de hoy es EXACTAMENTE el mismo de antes (la OP-9 sigue fallando por falta
--     de MDF y la OP-10 sigue alcanzando).
--   * Todo se hace con los mismos mecanismos reales (trigger de kardex y
--     sp_completar_orden): el stock lo calcula la base, no se escribe a mano.
--   * Se puede ejecutar UNA vez; si se repite, no hace nada (lo detecta solo).
--
-- NOTA: nombres de empresas, NIT y clientes son ficticios. Precios en COP.
-- =====================================================================

SET NAMES utf8mb4;
USE manufactura;

DELIMITER $$

-- Ayudantes temporales (se borran al final) ------------------------------
DROP PROCEDURE IF EXISTS sp_mig_requisito$$
CREATE PROCEDURE sp_mig_requisito()
BEGIN
  IF NOT EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'mejoras_estructura') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Primero ejecuta mejoras_estructura.sql';
  END IF;
  -- @mig_omitir = 1 hace que los ayudantes no hagan nada (script ya aplicado)
  SET @mig_omitir = EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'datos_historicos');
END$$

DROP PROCEDURE IF EXISTS sp_mig_compra$$
CREATE PROCEDURE sp_mig_compra(IN p_mp VARCHAR(20), IN p_nit VARCHAR(20), IN p_cant DECIMAL(12,3),
                               IN p_costo DECIMAL(12,2), IN p_fecha DATETIME, IN p_obs VARCHAR(200))
BEGIN
  DECLARE v_mp INT;
  DECLARE v_prov INT;
  IF @mig_omitir = 0 THEN
    -- Los ids se buscan ANTES del INSERT: el trigger del kardex actualiza materia_prima
    -- y MySQL no permite que el mismo INSERT también lea esa tabla.
    SELECT id_materia_prima INTO v_mp FROM materia_prima WHERE codigo = p_mp;
    SELECT id_proveedor INTO v_prov FROM proveedor WHERE nit = p_nit;
    INSERT INTO movimiento_inventario
           (id_materia_prima, tipo, cantidad, costo_unitario, fecha, id_proveedor, observacion)
    VALUES (v_mp, 'ENTRADA', p_cant, p_costo, p_fecha, v_prov, p_obs);
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_mig_salida$$
CREATE PROCEDURE sp_mig_salida(IN p_mp VARCHAR(20), IN p_cant DECIMAL(12,3),
                               IN p_fecha DATETIME, IN p_obs VARCHAR(200))
BEGIN
  DECLARE v_mp INT;
  IF @mig_omitir = 0 THEN
    SELECT id_materia_prima INTO v_mp FROM materia_prima WHERE codigo = p_mp;
    INSERT INTO movimiento_inventario (id_materia_prima, tipo, cantidad, fecha, observacion)
    VALUES (v_mp, 'SALIDA', p_cant, p_fecha, p_obs);
  END IF;
END$$

-- Crea la orden. Si es COMPLETADA la procesa con el procedimiento real
-- (sp_completar_orden) y luego acomoda las fechas al pasado, igual que en el script original.
DROP PROCEDURE IF EXISTS sp_mig_orden$$
CREATE PROCEDURE sp_mig_orden(IN p_prod VARCHAR(20), IN p_cant INT, IN p_creada DATETIME,
                              IN p_horas INT, IN p_estado VARCHAR(20))
BEGIN
  DECLARE v_id INT;
  IF @mig_omitir = 0 THEN
    IF p_estado = 'CANCELADA' THEN
      INSERT INTO orden_produccion (id_producto, cantidad, estado, fecha_creacion, fecha_cierre)
      SELECT id_producto, p_cant, 'CANCELADA', p_creada, DATE_ADD(p_creada, INTERVAL 20 HOUR)
        FROM producto WHERE codigo = p_prod;
    ELSE
      INSERT INTO orden_produccion (id_producto, cantidad, fecha_creacion)
      SELECT id_producto, p_cant, p_creada FROM producto WHERE codigo = p_prod;
      SET v_id = LAST_INSERT_ID();
      CALL sp_completar_orden(v_id);
      UPDATE orden_produccion SET fecha_cierre = DATE_ADD(fecha_creacion, INTERVAL p_horas HOUR)
       WHERE id_orden = v_id;
      UPDATE movimiento_inventario m JOIN orden_produccion o ON o.id_orden = m.id_orden
         SET m.fecha = o.fecha_cierre
       WHERE m.id_orden = v_id;
    END IF;
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_mig_despacho$$
CREATE PROCEDURE sp_mig_despacho(IN p_prod VARCHAR(20), IN p_cant INT,
                                 IN p_fecha DATETIME, IN p_cliente VARCHAR(100))
BEGIN
  DECLARE v_prod INT;
  IF @mig_omitir = 0 THEN
    SELECT id_producto INTO v_prod FROM producto WHERE codigo = p_prod;
    INSERT INTO despacho (id_producto, cantidad, fecha, cliente, observacion)
    VALUES (v_prod, p_cant, p_fecha, p_cliente, 'Entrega a cliente');
  END IF;
END$$

DELIMITER ;

CALL sp_mig_requisito();

-- ---------------------------------------------------------------------
-- 1. CATÁLOGO NUEVO (INSERT IGNORE: si ya existe, lo respeta)
-- ---------------------------------------------------------------------

INSERT IGNORE INTO proveedor (nit, nombre, telefono, email) VALUES
 ('901236478-2', 'Cauchos y Plásticos Industriales S.A.S.', '6043115520', 'ventas@cauchosyplasticos.com.co'),
 ('860512394-8', 'Cerraduras y Chapas de Colombia Ltda.', '6013489027', 'pedidos@cerradurasycolombia.com.co'),
 ('890412765-3', 'Vidrios Templados del Eje S.A.', '6063352218', 'comercial@vidriosdeleje.com.co'),
 ('901377820-9', 'Aluminios Extruidos de Antioquia S.A.S.', '6044128836', 'cotizaciones@aluminiosantioquia.com.co'),
 ('811027345-6', 'Fibras y Textiles de Medellín S.A.', '6042661940', 'ventas@fibrasytextiles.com.co'),
 ('900845119-1', 'Logística y Empaques del Norte S.A.S.', '6053471258', 'servicio@empaquesdelnorte.com.co');

INSERT IGNORE INTO materia_prima (codigo, nombre, unidad_medida, stock_minimo) VALUES
 ('MP-011', 'Cerradura de seguridad para archivador', 'UND', 25),
 ('MP-012', 'Vidrio templado 6 mm para cubierta', 'UND', 10),
 ('MP-013', 'Perfil de aluminio 40 x 20 mm', 'M', 60),
 ('MP-014', 'Tapa plástica para tubo cuadrado', 'UND', 200),
 ('MP-015', 'Pegante de contacto industrial (galón)', 'GAL', 4),
 ('MP-016', 'Rollo de cinta de embalaje 48 mm', 'UND', 10),
 ('MP-017', 'Base giratoria cromada cinco puntas', 'UND', 20),
 ('MP-018', 'Pistón neumático clase 3', 'UND', 20);

INSERT IGNORE INTO producto (codigo, nombre, precio_venta) VALUES
 ('PR-006', 'Silla de visitante fija', 165000.00),
 ('PR-007', 'Mesa auxiliar con cubierta de vidrio', 340000.00),
 ('PR-008', 'Gabinete bajo con puertas', 455000.00),
 ('PR-009', 'Silla gerencial ejecutiva', 790000.00);

-- Qué vende cada proveedor (se enlaza por NIT y por código, no por número de id)
INSERT IGNORE INTO proveedor_materia_prima (id_proveedor, id_materia_prima, pais_origen, precio_unitario, tiempo_entrega_dias)
SELECT p.id_proveedor, m.id_materia_prima, v.pais, v.precio, v.dias FROM (
  SELECT '901236478-2' AS nit, 'MP-014' AS cod, 'Colombia' AS pais, 350.00 AS precio, 2 AS dias
 UNION ALL
  SELECT '901236478-2' AS nit, 'MP-008' AS cod, 'Colombia' AS pais, 3100.00 AS precio, 3 AS dias
 UNION ALL
  SELECT '860512394-8' AS nit, 'MP-011' AS cod, 'Colombia' AS pais, 12500.00 AS precio, 4 AS dias
 UNION ALL
  SELECT '901554093-6' AS nit, 'MP-011' AS cod, 'China' AS pais, 8200.00 AS precio, 38 AS dias
 UNION ALL
  SELECT '890412765-3' AS nit, 'MP-012' AS cod, 'Colombia' AS pais, 96000.00 AS precio, 6 AS dias
 UNION ALL
  SELECT '901377820-9' AS nit, 'MP-013' AS cod, 'Colombia' AS pais, 15800.00 AS precio, 5 AS dias
 UNION ALL
  SELECT '811027345-6' AS nit, 'MP-007' AS cod, 'Colombia' AS pais, 16900.00 AS precio, 3 AS dias
 UNION ALL
  SELECT '811027345-6' AS nit, 'MP-006' AS cod, 'Colombia' AS pais, 44500.00 AS precio, 4 AS dias
 UNION ALL
  SELECT '811027345-6' AS nit, 'MP-015' AS cod, 'Colombia' AS pais, 148000.00 AS precio, 3 AS dias
 UNION ALL
  SELECT '900845119-1' AS nit, 'MP-010' AS cod, 'Colombia' AS pais, 4150.00 AS precio, 4 AS dias
 UNION ALL
  SELECT '900845119-1' AS nit, 'MP-016' AS cod, 'Colombia' AS pais, 6900.00 AS precio, 2 AS dias
 UNION ALL
  SELECT '901554093-6' AS nit, 'MP-017' AS cod, 'China' AS pais, 31000.00 AS precio, 40 AS dias
 UNION ALL
  SELECT '860045982-7' AS nit, 'MP-017' AS cod, 'Colombia' AS pais, 42000.00 AS precio, 3 AS dias
 UNION ALL
  SELECT '901554093-6' AS nit, 'MP-018' AS cod, 'China' AS pais, 11800.00 AS precio, 40 AS dias
 UNION ALL
  SELECT '860045982-7' AS nit, 'MP-018' AS cod, 'Colombia' AS pais, 16500.00 AS precio, 3 AS dias
 UNION ALL
  SELECT '901554093-6' AS nit, 'MP-014' AS cod, 'China' AS pais, 210.00 AS precio, 38 AS dias
 UNION ALL
  SELECT '901554093-6' AS nit, 'MP-016' AS cod, 'China' AS pais, 4200.00 AS precio, 40 AS dias
 UNION ALL
  SELECT '901377820-9' AS nit, 'MP-002' AS cod, 'Colombia' AS pais, 8300.00 AS precio, 5 AS dias
) v JOIN proveedor p ON p.nit = v.nit JOIN materia_prima m ON m.codigo = v.cod;

-- Recetas de los productos nuevos
INSERT IGNORE INTO receta (id_producto, id_materia_prima, cantidad_por_unidad)
SELECT pr.id_producto, m.id_materia_prima, v.cant FROM (
  SELECT 'PR-006' AS prod, 'MP-002' AS cod, 3.8000 AS cant
 UNION ALL
  SELECT 'PR-006' AS prod, 'MP-004' AS cod, 0.1500 AS cant
 UNION ALL
  SELECT 'PR-006' AS prod, 'MP-005' AS cod, 10.0000 AS cant
 UNION ALL
  SELECT 'PR-006' AS prod, 'MP-006' AS cod, 0.1500 AS cant
 UNION ALL
  SELECT 'PR-006' AS prod, 'MP-007' AS cod, 0.9000 AS cant
 UNION ALL
  SELECT 'PR-006' AS prod, 'MP-014' AS cod, 4.0000 AS cant
 UNION ALL
  SELECT 'PR-006' AS prod, 'MP-016' AS cod, 0.0500 AS cant
 UNION ALL
  SELECT 'PR-006' AS prod, 'MP-010' AS cod, 1.0000 AS cant
 UNION ALL
  SELECT 'PR-007' AS prod, 'MP-013' AS cod, 5.2000 AS cant
 UNION ALL
  SELECT 'PR-007' AS prod, 'MP-012' AS cod, 1.0000 AS cant
 UNION ALL
  SELECT 'PR-007' AS prod, 'MP-005' AS cod, 12.0000 AS cant
 UNION ALL
  SELECT 'PR-007' AS prod, 'MP-014' AS cod, 4.0000 AS cant
 UNION ALL
  SELECT 'PR-007' AS prod, 'MP-008' AS cod, 4.0000 AS cant
 UNION ALL
  SELECT 'PR-007' AS prod, 'MP-016' AS cod, 0.0500 AS cant
 UNION ALL
  SELECT 'PR-007' AS prod, 'MP-010' AS cod, 1.0000 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-001' AS cod, 18.0000 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-011' AS cod, 1.0000 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-004' AS cod, 0.9000 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-005' AS cod, 36.0000 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-015' AS cod, 0.0200 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-009' AS cod, 4.0000 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-016' AS cod, 0.0500 AS cant
 UNION ALL
  SELECT 'PR-008' AS prod, 'MP-010' AS cod, 1.0000 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-017' AS cod, 1.0000 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-018' AS cod, 1.0000 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-006' AS cod, 0.4000 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-007' AS cod, 1.6000 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-002' AS cod, 3.0000 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-005' AS cod, 14.0000 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-015' AS cod, 0.0300 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-016' AS cod, 0.0500 AS cant
 UNION ALL
  SELECT 'PR-009' AS prod, 'MP-010' AS cod, 1.0000 AS cant
) v JOIN producto pr ON pr.codigo = v.prod JOIN materia_prima m ON m.codigo = v.cod;

-- ---------------------------------------------------------------------
-- 2. HISTORIAL: 424 compras, 193 órdenes, 209 despachos, 9 ajustes de cierre
-- ---------------------------------------------------------------------
CALL sp_mig_compra('MP-001', '901554093-6', 3025, 3800, '2025-08-04 06:30:00', 'Importación OC-2026-H001 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 100, 7650, '2025-08-04 06:34:00', 'Compra OC-2026-H002 tubo');
CALL sp_mig_compra('MP-003', '901554093-6', 60, 67200, '2025-08-04 06:38:00', 'Importación OC-2026-H003 MDF');
CALL sp_mig_compra('MP-004', '901554093-6', 180, 17750, '2025-08-04 06:42:00', 'Importación OC-2026-H004 pintura');
CALL sp_mig_compra('MP-005', '901554093-6', 10500, 23, '2025-08-04 06:46:00', 'Importación OC-2026-H005 tornillería');
CALL sp_mig_compra('MP-009', '901554093-6', 150, 9200, '2025-08-04 06:50:00', 'Importación OC-2026-H006 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4050, '2025-08-04 06:54:00', 'Compra OC-2026-H007 cajas');
CALL sp_mig_orden('PR-002', 10, '2025-08-04 14:40:00', 83, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2025-08-09 03:40:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-003', 6, '2025-08-05 09:30:00', 48, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 6, '2025-08-08 11:30:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-004', 30, '2025-08-06 13:10:00', 73, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 30, '2025-08-10 16:10:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-004', 30, '2025-08-06 15:10:00', 48, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 30, '2025-08-09 17:10:00', 'Constructora Altos del Valle');
CALL sp_mig_compra('MP-002', '901377820-9', 540, 7800, '2025-08-11 06:34:00', 'Compra OC-2026-H008 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 30, 73400, '2025-08-11 06:38:00', 'Compra OC-2026-H009 MDF');
CALL sp_mig_compra('MP-006', '900776231-2', 20, 43300, '2025-08-11 06:50:00', 'Compra OC-2026-H010 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 60, 15900, '2025-08-11 06:54:00', 'Compra OC-2026-H011 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 300, 2900, '2025-08-11 06:58:00', 'Compra OC-2026-H012 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 3900, '2025-08-11 07:02:00', 'Compra OC-2026-H013 cajas');
CALL sp_mig_orden('PR-002', 20, '2025-08-12 09:50:00', 69, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 20, '2025-08-16 08:50:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-001', 50, '2025-08-12 12:30:00', 57, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 50, '2025-08-15 23:30:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-005', 9, '2025-08-13 12:00:00', 71, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 9, '2025-08-17 13:00:00', 'Hotel Plaza Real');
CALL sp_mig_compra('MP-002', '900412378-5', 80, 7350, '2025-08-18 06:34:00', 'Compra OC-2026-H014 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 73500, '2025-08-18 06:38:00', 'Compra OC-2026-H015 MDF');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 13650, '2025-08-18 06:50:00', 'Compra OC-2026-H016 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4050, '2025-08-18 06:54:00', 'Compra OC-2026-H017 cajas');
CALL sp_mig_orden('PR-003', 14, '2025-08-19 14:40:00', 64, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2025-08-23 08:40:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-002', 10, '2025-08-19 15:00:00', 75, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2025-08-23 20:00:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-004', 30, '2025-08-20 08:40:00', 62, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2025-08-24 00:40:00', 'Constructora Altos del Valle');
CALL sp_mig_despacho('PR-004', 15, '2025-08-25 00:40:00', 'Clínica del Norte S.A.');
CALL sp_mig_compra('MP-002', '830215664-1', 140, 7700, '2025-08-25 06:34:00', 'Compra OC-2026-H018 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 30, 73600, '2025-08-25 06:38:00', 'Compra OC-2026-H019 MDF');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 13700, '2025-08-25 06:50:00', 'Compra OC-2026-H020 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 3900, '2025-08-25 06:54:00', 'Compra OC-2026-H021 cajas');
CALL sp_mig_orden('PR-002', 15, '2025-08-25 15:50:00', 78, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 15, '2025-08-29 23:50:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-004', 15, '2025-08-27 14:30:00', 57, 'CANCELADA');
CALL sp_mig_orden('PR-004', 25, '2025-08-27 14:50:00', 67, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2025-08-31 11:50:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-003', 14, '2025-08-27 15:30:00', 75, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2025-08-31 20:30:00', 'Banco Andino sucursal Centro');
CALL sp_mig_compra('MP-001', '901554093-6', 300, 3850, '2025-09-01 06:30:00', 'Importación OC-2026-H022 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 480, 7850, '2025-09-01 06:34:00', 'Compra OC-2026-H023 tubo');
CALL sp_mig_compra('MP-003', '901554093-6', 60, 67550, '2025-09-01 06:38:00', 'Importación OC-2026-H024 MDF');
CALL sp_mig_compra('MP-004', '901554093-6', 85, 17850, '2025-09-01 06:42:00', 'Importación OC-2026-H025 pintura');
CALL sp_mig_compra('MP-005', '901554093-6', 4000, 23, '2025-09-01 06:46:00', 'Importación OC-2026-H026 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 20, 42050, '2025-09-01 06:50:00', 'Compra OC-2026-H027 espuma');
CALL sp_mig_compra('MP-007', '901554093-6', 310, 13150, '2025-09-01 06:54:00', 'Importación OC-2026-H028 tela');
CALL sp_mig_compra('MP-008', '901554093-6', 1300, 2000, '2025-09-01 06:58:00', 'Importación OC-2026-H029 rodachines');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4050, '2025-09-01 07:02:00', 'Compra OC-2026-H030 cajas');
CALL sp_mig_orden('PR-001', 40, '2025-09-01 08:10:00', 89, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 40, '2025-09-06 03:10:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-001', 45, '2025-09-02 15:30:00', 83, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 45, '2025-09-07 04:30:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-005', 7, '2025-09-03 15:20:00', 60, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 7, '2025-09-07 05:20:00', 'Colegio San Ignacio');
CALL sp_mig_compra('MP-001', '830215664-1', 75, 4800, '2025-09-08 06:30:00', 'Compra OC-2026-H031 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 480, 7400, '2025-09-08 06:34:00', 'Compra OC-2026-H032 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 10, 73750, '2025-09-08 06:38:00', 'Compra OC-2026-H033 MDF');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 43500, '2025-09-08 06:50:00', 'Compra OC-2026-H034 espuma');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 3900, '2025-09-08 07:02:00', 'Compra OC-2026-H035 cajas');
CALL sp_mig_orden('PR-001', 60, '2025-09-09 10:30:00', 48, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 30, '2025-09-12 12:30:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_despacho('PR-001', 30, '2025-09-13 12:30:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-004', 25, '2025-09-09 10:30:00', 78, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2025-09-13 18:30:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-005', 6, '2025-09-09 15:00:00', 76, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 6, '2025-09-13 21:00:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-005', 9, '2025-09-09 15:20:00', 54, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 9, '2025-09-12 23:20:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_compra('MP-001', '900412378-5', 475, 4600, '2025-09-15 06:30:00', 'Compra OC-2026-H036 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 320, 7700, '2025-09-15 06:34:00', 'Compra OC-2026-H037 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 73850, '2025-09-15 06:38:00', 'Compra OC-2026-H038 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 20350, '2025-09-15 06:42:00', 'Compra OC-2026-H039 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1000, 36, '2025-09-15 06:46:00', 'Compra OC-2026-H040 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 20, 42150, '2025-09-15 06:50:00', 'Compra OC-2026-H041 espuma');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 13750, '2025-09-15 07:02:00', 'Compra OC-2026-H042 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 3950, '2025-09-15 07:06:00', 'Compra OC-2026-H043 cajas');
CALL sp_mig_orden('PR-001', 50, '2025-09-15 12:50:00', 88, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 25, '2025-09-20 06:50:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_despacho('PR-001', 25, '2025-09-21 06:50:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-002', 10, '2025-09-16 15:50:00', 56, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2025-09-20 01:50:00', 'Notaría 14 del Círculo');
CALL sp_mig_orden('PR-001', 50, '2025-09-17 09:40:00', 60, 'CANCELADA');
CALL sp_mig_orden('PR-003', 12, '2025-09-17 10:40:00', 80, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 12, '2025-09-21 20:40:00', 'Colegio San Ignacio');
CALL sp_mig_compra('MP-001', '830215664-1', 475, 4850, '2025-09-22 06:30:00', 'Compra OC-2026-H044 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 340, 7850, '2025-09-22 06:34:00', 'Compra OC-2026-H045 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 73950, '2025-09-22 06:38:00', 'Compra OC-2026-H046 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 35, 20400, '2025-09-22 06:42:00', 'Compra OC-2026-H047 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 36, '2025-09-22 06:46:00', 'Compra OC-2026-H048 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 43600, '2025-09-22 06:50:00', 'Compra OC-2026-H049 espuma');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 13750, '2025-09-22 07:02:00', 'Compra OC-2026-H050 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4100, '2025-09-22 07:06:00', 'Compra OC-2026-H051 cajas');
CALL sp_mig_orden('PR-005', 7, '2025-09-22 08:20:00', 89, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 7, '2025-09-27 03:20:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-001', 55, '2025-09-22 10:40:00', 67, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 55, '2025-09-26 07:40:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-003', 12, '2025-09-22 11:30:00', 48, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 12, '2025-09-25 13:30:00', 'Cooperativa Agrofuturo');
CALL sp_mig_compra('MP-001', '900412378-5', 275, 4600, '2025-09-29 06:30:00', 'Compra OC-2026-H052 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 140, 7400, '2025-09-29 06:34:00', 'Compra OC-2026-H053 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 30, 74050, '2025-09-29 06:38:00', 'Compra OC-2026-H054 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 20, 20400, '2025-09-29 06:42:00', 'Compra OC-2026-H055 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 36, '2025-09-29 06:46:00', 'Compra OC-2026-H056 tornillería');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 3950, '2025-09-29 06:50:00', 'Compra OC-2026-H057 cajas');
CALL sp_mig_orden('PR-005', 4, '2025-09-29 15:20:00', 67, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 4, '2025-10-03 12:20:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-002', 10, '2025-09-30 15:40:00', 87, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2025-10-05 08:40:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-004', 20, '2025-10-01 11:30:00', 87, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 20, '2025-10-06 04:30:00', 'Banco Andino sucursal Centro');
CALL sp_mig_compra('MP-001', '830215664-1', 125, 4850, '2025-10-06 06:30:00', 'Compra OC-2026-H058 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 420, 7750, '2025-10-06 06:34:00', 'Compra OC-2026-H059 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 40, 74150, '2025-10-06 06:38:00', 'Compra OC-2026-H060 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 20450, '2025-10-06 06:42:00', 'Compra OC-2026-H061 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1000, 36, '2025-10-06 06:46:00', 'Compra OC-2026-H062 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 43700, '2025-10-06 06:50:00', 'Compra OC-2026-H063 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 50, 16050, '2025-10-06 06:54:00', 'Compra OC-2026-H064 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 200, 2950, '2025-10-06 06:58:00', 'Compra OC-2026-H065 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 3950, '2025-10-06 07:02:00', 'Compra OC-2026-H066 cajas');
CALL sp_mig_orden('PR-001', 55, '2025-10-06 08:50:00', 82, 'CANCELADA');
CALL sp_mig_orden('PR-001', 50, '2025-10-06 10:10:00', 90, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 25, '2025-10-11 06:10:00', 'Colegio San Ignacio');
CALL sp_mig_despacho('PR-001', 25, '2025-10-12 06:10:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-005', 4, '2025-10-07 11:30:00', 49, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 4, '2025-10-10 14:30:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-002', 15, '2025-10-08 09:40:00', 73, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 15, '2025-10-12 12:40:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_compra('MP-001', '900412378-5', 100, 4600, '2025-10-13 06:30:00', 'Compra OC-2026-H067 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 500, 7900, '2025-10-13 06:34:00', 'Compra OC-2026-H068 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 70, 74200, '2025-10-13 06:38:00', 'Compra OC-2026-H069 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 20450, '2025-10-13 06:42:00', 'Compra OC-2026-H070 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 36, '2025-10-13 06:46:00', 'Compra OC-2026-H071 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 42350, '2025-10-13 06:50:00', 'Compra OC-2026-H072 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 50, 16950, '2025-10-13 06:54:00', 'Compra OC-2026-H073 tela');
CALL sp_mig_compra('MP-008', '860045982-7', 200, 3250, '2025-10-13 06:58:00', 'Compra OC-2026-H074 rodachines');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4100, '2025-10-13 07:02:00', 'Compra OC-2026-H075 cajas');
CALL sp_mig_orden('PR-001', 40, '2025-10-13 12:30:00', 79, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 40, '2025-10-17 21:30:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-005', 7, '2025-10-14 15:10:00', 68, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 7, '2025-10-18 13:10:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-002', 25, '2025-10-15 14:00:00', 72, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 25, '2025-10-19 16:00:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_compra('MP-001', '830215664-1', 750, 4850, '2025-10-20 06:30:00', 'Compra OC-2026-H076 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 220, 7450, '2025-10-20 06:34:00', 'Compra OC-2026-H077 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 74300, '2025-10-20 06:38:00', 'Compra OC-2026-H078 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 45, 20500, '2025-10-20 06:42:00', 'Compra OC-2026-H079 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 36, '2025-10-20 06:46:00', 'Compra OC-2026-H080 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 43800, '2025-10-20 06:50:00', 'Compra OC-2026-H081 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 40, 16100, '2025-10-20 06:54:00', 'Compra OC-2026-H082 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 100, 2950, '2025-10-20 06:58:00', 'Compra OC-2026-H083 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 13800, '2025-10-20 07:02:00', 'Compra OC-2026-H084 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4100, '2025-10-20 07:06:00', 'Compra OC-2026-H085 cajas');
CALL sp_mig_orden('PR-004', 20, '2025-10-20 13:10:00', 70, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 20, '2025-10-24 13:10:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-001', 30, '2025-10-21 13:30:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 30, '2025-10-26 01:30:00', 'Notaría 14 del Círculo');
CALL sp_mig_orden('PR-003', 14, '2025-10-22 11:00:00', 87, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2025-10-27 04:00:00', 'Constructora Altos del Valle');
CALL sp_mig_orden('PR-002', 10, '2025-10-22 12:00:00', 61, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2025-10-26 03:00:00', 'Universidad Regional (compras)');
CALL sp_mig_compra('MP-001', '900412378-5', 675, 4650, '2025-10-27 06:30:00', 'Compra OC-2026-H086 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 340, 7750, '2025-10-27 06:34:00', 'Compra OC-2026-H087 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 74400, '2025-10-27 06:38:00', 'Compra OC-2026-H088 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 50, 20500, '2025-10-27 06:42:00', 'Compra OC-2026-H089 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 36, '2025-10-27 06:46:00', 'Compra OC-2026-H090 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 42450, '2025-10-27 06:50:00', 'Compra OC-2026-H091 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 70, 17000, '2025-10-27 06:54:00', 'Compra OC-2026-H092 tela');
CALL sp_mig_compra('MP-008', '860045982-7', 300, 3250, '2025-10-27 06:58:00', 'Compra OC-2026-H093 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 13850, '2025-10-27 07:02:00', 'Compra OC-2026-H094 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 3950, '2025-10-27 07:06:00', 'Compra OC-2026-H095 cajas');
CALL sp_mig_orden('PR-005', 5, '2025-10-27 08:20:00', 59, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 5, '2025-10-30 21:20:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-003', 14, '2025-10-27 09:20:00', 54, 'CANCELADA');
CALL sp_mig_orden('PR-004', 25, '2025-10-28 10:20:00', 64, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2025-11-01 04:20:00', 'Cooperativa Agrofuturo');
CALL sp_mig_orden('PR-001', 60, '2025-10-29 11:40:00', 66, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 30, '2025-11-02 07:40:00', 'Hotel Plaza Real');
CALL sp_mig_despacho('PR-001', 30, '2025-11-03 07:40:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-003', 6, '2025-10-29 13:20:00', 85, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 6, '2025-11-03 04:20:00', 'Universidad Regional (compras)');
CALL sp_mig_compra('MP-001', '830215664-1', 500, 4850, '2025-11-03 06:30:00', 'Compra OC-2026-H096 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 420, 7950, '2025-11-03 06:34:00', 'Compra OC-2026-H097 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 40, 20550, '2025-11-03 06:38:00', 'Compra OC-2026-H098 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 36, '2025-11-03 06:42:00', 'Compra OC-2026-H099 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 30, 42500, '2025-11-03 06:46:00', 'Compra OC-2026-H100 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 110, 17000, '2025-11-03 06:50:00', 'Compra OC-2026-H101 tela');
CALL sp_mig_compra('MP-008', '860045982-7', 500, 3250, '2025-11-03 06:54:00', 'Compra OC-2026-H102 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 13850, '2025-11-03 06:58:00', 'Compra OC-2026-H103 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 3950, '2025-11-03 07:02:00', 'Compra OC-2026-H104 cajas');
CALL sp_mig_orden('PR-001', 30, '2025-11-04 09:00:00', 83, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 30, '2025-11-08 22:00:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-001', 60, '2025-11-04 14:00:00', 51, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 60, '2025-11-07 19:00:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-003', 10, '2025-11-04 15:40:00', 88, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2025-11-09 09:40:00', 'Constructora Altos del Valle');
CALL sp_mig_compra('MP-001', '900412378-5', 1300, 4650, '2025-11-10 06:30:00', 'Compra OC-2026-H105 lámina');
CALL sp_mig_compra('MP-004', '901128450-3', 70, 20550, '2025-11-10 06:34:00', 'Compra OC-2026-H106 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 3500, 36, '2025-11-10 06:38:00', 'Compra OC-2026-H107 tornillería');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 13850, '2025-11-10 06:42:00', 'Compra OC-2026-H108 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4100, '2025-11-10 06:46:00', 'Compra OC-2026-H109 cajas');
CALL sp_mig_orden('PR-004', 30, '2025-11-10 12:50:00', 69, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 30, '2025-11-14 11:50:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-004', 25, '2025-11-11 12:20:00', 51, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2025-11-14 17:20:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-004', 15, '2025-11-11 13:40:00', 61, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2025-11-15 04:40:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-003', 12, '2025-11-12 09:50:00', 71, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 12, '2025-11-16 10:50:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_compra('MP-001', '830215664-1', 325, 4900, '2025-11-17 06:30:00', 'Compra OC-2026-H110 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 280, 7800, '2025-11-17 06:34:00', 'Compra OC-2026-H111 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 74650, '2025-11-17 06:38:00', 'Compra OC-2026-H112 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 20600, '2025-11-17 06:42:00', 'Compra OC-2026-H113 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 36, '2025-11-17 06:46:00', 'Compra OC-2026-H114 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 44050, '2025-11-17 06:50:00', 'Compra OC-2026-H115 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 50, 16200, '2025-11-17 06:54:00', 'Compra OC-2026-H116 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 200, 2950, '2025-11-17 06:58:00', 'Compra OC-2026-H117 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 3950, '2025-11-17 07:02:00', 'Compra OC-2026-H118 cajas');
CALL sp_mig_orden('PR-004', 15, '2025-11-17 09:00:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2025-11-20 13:00:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-005', 8, '2025-11-18 11:40:00', 51, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 8, '2025-11-21 16:40:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-004', 15, '2025-11-18 14:20:00', 85, 'CANCELADA');
CALL sp_mig_orden('PR-001', 40, '2025-11-19 12:00:00', 75, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 40, '2025-11-23 17:00:00', 'Banco Andino sucursal Centro');
CALL sp_mig_compra('MP-001', '900412378-5', 800, 4650, '2025-11-24 06:30:00', 'Compra OC-2026-H119 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 440, 7950, '2025-11-24 06:34:00', 'Compra OC-2026-H120 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 55, 20600, '2025-11-24 06:38:00', 'Compra OC-2026-H121 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 36, '2025-11-24 06:42:00', 'Compra OC-2026-H122 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 20, 44100, '2025-11-24 06:46:00', 'Compra OC-2026-H123 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 110, 16200, '2025-11-24 06:50:00', 'Compra OC-2026-H124 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 500, 2950, '2025-11-24 06:54:00', 'Compra OC-2026-H125 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 200, 13900, '2025-11-24 06:58:00', 'Compra OC-2026-H126 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4100, '2025-11-24 07:02:00', 'Compra OC-2026-H127 cajas');
CALL sp_mig_orden('PR-003', 8, '2025-11-24 08:50:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 8, '2025-11-28 20:50:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-003', 12, '2025-11-25 10:10:00', 49, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 12, '2025-11-28 13:10:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-001', 45, '2025-11-25 14:10:00', 74, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 45, '2025-11-29 18:10:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-001', 50, '2025-11-25 14:20:00', 68, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 25, '2025-11-29 12:20:00', 'Notaría 14 del Círculo');
CALL sp_mig_despacho('PR-001', 25, '2025-11-30 12:20:00', 'Hotel Plaza Real');
CALL sp_mig_compra('MP-001', '830215664-1', 725, 4900, '2025-12-01 06:30:00', 'Compra OC-2026-H128 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 100, 7500, '2025-12-01 06:34:00', 'Compra OC-2026-H129 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 30, 74850, '2025-12-01 06:38:00', 'Compra OC-2026-H130 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 40, 20650, '2025-12-01 06:42:00', 'Compra OC-2026-H131 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 36, '2025-12-01 06:46:00', 'Compra OC-2026-H132 tornillería');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 13900, '2025-12-01 06:50:00', 'Compra OC-2026-H133 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4000, '2025-12-01 06:54:00', 'Compra OC-2026-H134 cajas');
CALL sp_mig_orden('PR-004', 25, '2025-12-01 08:50:00', 63, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2025-12-05 01:50:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-005', 8, '2025-12-01 10:40:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 8, '2025-12-04 14:40:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-003', 14, '2025-12-02 13:50:00', 81, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2025-12-07 00:50:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_compra('MP-001', '900412378-5', 350, 4650, '2025-12-08 06:30:00', 'Compra OC-2026-H135 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 360, 7850, '2025-12-08 06:34:00', 'Compra OC-2026-H136 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 70, 74950, '2025-12-08 06:38:00', 'Compra OC-2026-H137 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 35, 20650, '2025-12-08 06:42:00', 'Compra OC-2026-H138 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 37, '2025-12-08 06:46:00', 'Compra OC-2026-H139 tornillería');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4000, '2025-12-08 06:50:00', 'Compra OC-2026-H140 cajas');
CALL sp_mig_orden('PR-004', 25, '2025-12-08 12:20:00', 60, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2025-12-12 02:20:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-001', 35, '2025-12-10 10:50:00', 73, 'CANCELADA');
CALL sp_mig_orden('PR-005', 9, '2025-12-10 12:10:00', 58, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 9, '2025-12-14 00:10:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-002', 25, '2025-12-10 15:40:00', 78, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 25, '2025-12-14 23:40:00', 'Constructora Altos del Valle');
CALL sp_mig_compra('MP-001', '830215664-1', 725, 4900, '2025-12-15 06:30:00', 'Compra OC-2026-H141 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 480, 8000, '2025-12-15 06:34:00', 'Compra OC-2026-H142 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 50, 75050, '2025-12-15 06:38:00', 'Compra OC-2026-H143 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 60, 20700, '2025-12-15 06:42:00', 'Compra OC-2026-H144 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 4000, 37, '2025-12-15 06:46:00', 'Compra OC-2026-H145 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 20, 44250, '2025-12-15 06:50:00', 'Compra OC-2026-H146 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 70, 16250, '2025-12-15 06:54:00', 'Compra OC-2026-H147 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 300, 3000, '2025-12-15 06:58:00', 'Compra OC-2026-H148 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 150, 4000, '2025-12-15 07:02:00', 'Compra OC-2026-H149 cajas');
CALL sp_mig_orden('PR-004', 20, '2025-12-15 12:20:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 10, '2025-12-20 00:20:00', 'Constructora Altos del Valle');
CALL sp_mig_despacho('PR-004', 10, '2025-12-21 00:20:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-002', 25, '2025-12-15 13:40:00', 74, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 25, '2025-12-19 17:40:00', 'Notaría 14 del Círculo');
CALL sp_mig_orden('PR-004', 20, '2025-12-17 09:00:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 10, '2025-12-21 21:00:00', 'Cooperativa Agrofuturo');
CALL sp_mig_despacho('PR-004', 10, '2025-12-22 21:00:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-001', 60, '2025-12-17 12:40:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 60, '2025-12-20 16:40:00', 'Coworking Nodo 21');
CALL sp_mig_compra('MP-001', '900412378-5', 625, 4650, '2025-12-22 06:30:00', 'Compra OC-2026-H150 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 140, 7500, '2025-12-22 06:34:00', 'Compra OC-2026-H151 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 30, 75150, '2025-12-22 06:38:00', 'Compra OC-2026-H152 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 45, 20700, '2025-12-22 06:42:00', 'Compra OC-2026-H153 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 37, '2025-12-22 06:46:00', 'Compra OC-2026-H154 tornillería');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4000, '2025-12-22 06:50:00', 'Compra OC-2026-H155 cajas');
CALL sp_mig_orden('PR-004', 20, '2025-12-22 12:20:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 20, '2025-12-27 00:20:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-002', 15, '2025-12-24 09:00:00', 57, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 15, '2025-12-27 20:00:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-004', 25, '2025-12-24 12:20:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2025-12-27 16:20:00', 'Cooperativa Agrofuturo');
CALL sp_mig_compra('MP-001', '830215664-1', 100, 4900, '2025-12-29 06:30:00', 'Compra OC-2026-H156 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 520, 7850, '2025-12-29 06:34:00', 'Compra OC-2026-H157 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 80, 75200, '2025-12-29 06:38:00', 'Compra OC-2026-H158 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 20750, '2025-12-29 06:42:00', 'Compra OC-2026-H159 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 37, '2025-12-29 06:46:00', 'Compra OC-2026-H160 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 44350, '2025-12-29 06:50:00', 'Compra OC-2026-H161 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 50, 16300, '2025-12-29 06:54:00', 'Compra OC-2026-H162 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 200, 3000, '2025-12-29 06:58:00', 'Compra OC-2026-H163 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4000, '2025-12-29 07:02:00', 'Compra OC-2026-H164 cajas');
CALL sp_mig_orden('PR-002', 25, '2025-12-29 08:40:00', 89, 'CANCELADA');
CALL sp_mig_orden('PR-002', 25, '2025-12-30 10:50:00', 81, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2026-01-03 21:50:00', 'Universidad Regional (compras)');
CALL sp_mig_despacho('PR-002', 15, '2026-01-04 21:50:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-005', 8, '2025-12-31 08:20:00', 52, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 8, '2026-01-03 14:20:00', 'Cooperativa Agrofuturo');
CALL sp_mig_orden('PR-001', 40, '2025-12-31 10:10:00', 49, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 40, '2026-01-03 13:10:00', 'Universidad Regional (compras)');
CALL sp_mig_compra('MP-001', '901554093-6', 875, 3900, '2026-01-05 06:30:00', 'Importación OC-2026-H165 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 320, 8000, '2026-01-05 06:34:00', 'Compra OC-2026-H166 tubo');
CALL sp_mig_compra('MP-003', '901554093-6', 60, 69050, '2026-01-05 06:38:00', 'Importación OC-2026-H167 MDF');
CALL sp_mig_compra('MP-004', '901554093-6', 80, 18250, '2026-01-05 06:42:00', 'Importación OC-2026-H168 pintura');
CALL sp_mig_compra('MP-005', '901554093-6', 3500, 23, '2026-01-05 06:46:00', 'Importación OC-2026-H169 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 42950, '2026-01-05 06:50:00', 'Compra OC-2026-H170 espuma');
CALL sp_mig_compra('MP-007', '901554093-6', 180, 13400, '2026-01-05 06:54:00', 'Importación OC-2026-H171 tela');
CALL sp_mig_compra('MP-008', '901554093-6', 700, 2050, '2026-01-05 06:58:00', 'Importación OC-2026-H172 rodachines');
CALL sp_mig_compra('MP-009', '901554093-6', 150, 9450, '2026-01-05 07:02:00', 'Importación OC-2026-H173 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4000, '2026-01-05 07:06:00', 'Compra OC-2026-H174 cajas');
CALL sp_mig_orden('PR-005', 7, '2026-01-05 09:30:00', 64, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 7, '2026-01-09 03:30:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-001', 50, '2026-01-05 11:10:00', 54, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 25, '2026-01-08 19:10:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_despacho('PR-001', 25, '2026-01-09 19:10:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-003', 6, '2026-01-06 15:30:00', 55, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 6, '2026-01-10 00:30:00', 'Coworking Nodo 21');
CALL sp_mig_compra('MP-001', '830215664-1', 400, 4950, '2026-01-12 06:30:00', 'Compra OC-2026-H175 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 280, 7550, '2026-01-12 06:34:00', 'Compra OC-2026-H176 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 5, 20800, '2026-01-12 06:38:00', 'Compra OC-2026-H177 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 500, 37, '2026-01-12 06:42:00', 'Compra OC-2026-H178 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 43000, '2026-01-12 06:46:00', 'Compra OC-2026-H179 espuma');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 14000, '2026-01-12 06:58:00', 'Compra OC-2026-H180 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4000, '2026-01-12 07:02:00', 'Compra OC-2026-H181 cajas');
CALL sp_mig_orden('PR-004', 20, '2026-01-12 13:30:00', 80, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 20, '2026-01-16 23:30:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-001', 60, '2026-01-12 15:20:00', 64, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 60, '2026-01-16 09:20:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-003', 10, '2026-01-14 15:30:00', 68, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2026-01-18 13:30:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-003', 10, '2026-01-14 15:40:00', 70, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2026-01-18 15:40:00', 'Coworking Nodo 21');
CALL sp_mig_compra('MP-001', '900412378-5', 650, 4700, '2026-01-19 06:30:00', 'Compra OC-2026-H182 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 220, 7900, '2026-01-19 06:34:00', 'Compra OC-2026-H183 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 10, 75500, '2026-01-19 06:38:00', 'Compra OC-2026-H184 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 45, 20800, '2026-01-19 06:42:00', 'Compra OC-2026-H185 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 37, '2026-01-19 06:46:00', 'Compra OC-2026-H186 tornillería');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 14050, '2026-01-19 06:50:00', 'Compra OC-2026-H187 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4150, '2026-01-19 06:54:00', 'Compra OC-2026-H188 cajas');
CALL sp_mig_orden('PR-004', 30, '2026-01-19 10:30:00', 84, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 30, '2026-01-24 00:30:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-001', 45, '2026-01-19 13:20:00', 74, 'CANCELADA');
CALL sp_mig_orden('PR-002', 25, '2026-01-20 10:40:00', 88, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2026-01-25 04:40:00', 'Notaría 14 del Círculo');
CALL sp_mig_despacho('PR-002', 15, '2026-01-26 04:40:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-003', 8, '2026-01-20 12:20:00', 55, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 8, '2026-01-23 21:20:00', 'Banco Andino sucursal Centro');
CALL sp_mig_compra('MP-001', '830215664-1', 700, 4950, '2026-01-26 06:30:00', 'Compra OC-2026-H189 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 160, 8050, '2026-01-26 06:34:00', 'Compra OC-2026-H190 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 35, 20850, '2026-01-26 06:38:00', 'Compra OC-2026-H191 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 37, '2026-01-26 06:42:00', 'Compra OC-2026-H192 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 43100, '2026-01-26 06:46:00', 'Compra OC-2026-H193 espuma');
CALL sp_mig_compra('MP-009', '860045982-7', 200, 14050, '2026-01-26 06:58:00', 'Compra OC-2026-H194 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4000, '2026-01-26 07:02:00', 'Compra OC-2026-H195 cajas');
CALL sp_mig_orden('PR-003', 10, '2026-01-26 15:50:00', 88, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2026-01-31 09:50:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-003', 12, '2026-01-27 08:40:00', 69, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 12, '2026-01-31 07:40:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-001', 35, '2026-01-28 09:20:00', 66, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 15, '2026-02-01 05:20:00', 'Universidad Regional (compras)');
CALL sp_mig_despacho('PR-001', 20, '2026-02-02 05:20:00', 'Coworking Nodo 21');
CALL sp_mig_compra('MP-001', '901554093-6', 3025, 3950, '2026-02-02 06:30:00', 'Importación OC-2026-H196 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 200, 7550, '2026-02-02 06:34:00', 'Compra OC-2026-H197 tubo');
CALL sp_mig_compra('MP-004', '901554093-6', 170, 18350, '2026-02-02 06:38:00', 'Importación OC-2026-H198 pintura');
CALL sp_mig_compra('MP-005', '901554093-6', 7500, 23, '2026-02-02 06:42:00', 'Importación OC-2026-H199 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 44650, '2026-02-02 06:46:00', 'Compra OC-2026-H200 espuma');
CALL sp_mig_compra('MP-007', '901554093-6', 160, 13500, '2026-02-02 06:50:00', 'Importación OC-2026-H201 tela');
CALL sp_mig_compra('MP-008', '901554093-6', 700, 2050, '2026-02-02 06:54:00', 'Importación OC-2026-H202 rodachines');
CALL sp_mig_compra('MP-009', '901554093-6', 500, 9500, '2026-02-02 06:58:00', 'Importación OC-2026-H203 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4150, '2026-02-02 07:02:00', 'Compra OC-2026-H204 cajas');
CALL sp_mig_orden('PR-003', 10, '2026-02-02 13:40:00', 89, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2026-02-07 08:40:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-003', 12, '2026-02-03 13:00:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 12, '2026-02-06 17:00:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-004', 20, '2026-02-03 13:50:00', 69, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 10, '2026-02-07 12:50:00', 'Notaría 14 del Círculo');
CALL sp_mig_despacho('PR-004', 10, '2026-02-08 12:50:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-001', 45, '2026-02-04 10:00:00', 65, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 20, '2026-02-08 05:00:00', 'Constructora Altos del Valle');
CALL sp_mig_despacho('PR-001', 25, '2026-02-09 05:00:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_compra('MP-002', '830215664-1', 60, 7900, '2026-02-09 06:34:00', 'Compra OC-2026-H205 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 10, 75750, '2026-02-09 06:38:00', 'Compra OC-2026-H206 MDF');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4050, '2026-02-09 06:54:00', 'Compra OC-2026-H207 cajas');
CALL sp_mig_orden('PR-004', 15, '2026-02-09 10:20:00', 62, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2026-02-13 02:20:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-003', 10, '2026-02-10 08:10:00', 77, 'CANCELADA');
CALL sp_mig_orden('PR-005', 5, '2026-02-11 10:50:00', 67, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 5, '2026-02-15 07:50:00', 'Constructora Altos del Valle');
CALL sp_mig_orden('PR-003', 14, '2026-02-11 13:00:00', 83, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2026-02-16 02:00:00', 'Clínica del Norte S.A.');
CALL sp_mig_compra('MP-002', '901377820-9', 300, 8050, '2026-02-16 06:34:00', 'Compra OC-2026-H208 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 75850, '2026-02-16 06:38:00', 'Compra OC-2026-H209 MDF');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 43300, '2026-02-16 06:50:00', 'Compra OC-2026-H210 espuma');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4050, '2026-02-16 07:06:00', 'Compra OC-2026-H211 cajas');
CALL sp_mig_orden('PR-001', 45, '2026-02-16 10:40:00', 80, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 20, '2026-02-20 20:40:00', 'Universidad Regional (compras)');
CALL sp_mig_despacho('PR-001', 25, '2026-02-21 20:40:00', 'Hotel Plaza Real');
CALL sp_mig_orden('PR-003', 14, '2026-02-18 10:00:00', 49, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2026-02-21 13:00:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-005', 7, '2026-02-18 13:20:00', 70, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 7, '2026-02-22 13:20:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_compra('MP-001', '830215664-1', 25, 4950, '2026-02-23 06:30:00', 'Compra OC-2026-H212 lámina');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 14100, '2026-02-23 06:42:00', 'Compra OC-2026-H213 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4050, '2026-02-23 06:46:00', 'Compra OC-2026-H214 cajas');
CALL sp_mig_orden('PR-004', 30, '2026-02-23 13:20:00', 80, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2026-02-27 23:20:00', 'Hotel Plaza Real');
CALL sp_mig_despacho('PR-004', 15, '2026-02-28 23:20:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-003', 8, '2026-02-23 15:20:00', 64, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 8, '2026-02-27 09:20:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-003', 10, '2026-02-24 13:20:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2026-02-27 17:20:00', 'Cooperativa Agrofuturo');
CALL sp_mig_compra('MP-001', '901554093-6', 2100, 3950, '2026-03-02 06:30:00', 'Importación OC-2026-H215 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 340, 7950, '2026-03-02 06:34:00', 'Compra OC-2026-H216 tubo');
CALL sp_mig_compra('MP-003', '901554093-6', 80, 69700, '2026-03-02 06:38:00', 'Importación OC-2026-H217 MDF');
CALL sp_mig_compra('MP-004', '901554093-6', 145, 18400, '2026-03-02 06:42:00', 'Importación OC-2026-H218 pintura');
CALL sp_mig_compra('MP-005', '901554093-6', 7500, 23, '2026-03-02 06:46:00', 'Importación OC-2026-H219 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 20, 43400, '2026-03-02 06:50:00', 'Compra OC-2026-H220 espuma');
CALL sp_mig_compra('MP-007', '901554093-6', 120, 13550, '2026-03-02 06:54:00', 'Importación OC-2026-H221 tela');
CALL sp_mig_compra('MP-008', '901554093-6', 500, 2050, '2026-03-02 06:58:00', 'Importación OC-2026-H222 rodachines');
CALL sp_mig_compra('MP-009', '901554093-6', 200, 9550, '2026-03-02 07:02:00', 'Importación OC-2026-H223 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4050, '2026-03-02 07:06:00', 'Compra OC-2026-H224 cajas');
CALL sp_mig_orden('PR-004', 25, '2026-03-02 09:40:00', 59, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 25, '2026-03-05 22:40:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-003', 8, '2026-03-04 08:30:00', 52, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 8, '2026-03-07 14:30:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-005', 9, '2026-03-04 12:30:00', 87, 'CANCELADA');
CALL sp_mig_orden('PR-001', 50, '2026-03-04 13:30:00', 68, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 25, '2026-03-08 11:30:00', 'Coworking Nodo 21');
CALL sp_mig_despacho('PR-001', 25, '2026-03-09 11:30:00', 'Constructora Altos del Valle');
CALL sp_mig_orden('PR-005', 8, '2026-03-04 14:50:00', 54, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 8, '2026-03-07 22:50:00', 'Colegio San Ignacio');
CALL sp_mig_compra('MP-002', '901377820-9', 260, 8100, '2026-03-09 06:34:00', 'Compra OC-2026-H225 tubo');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 43450, '2026-03-09 06:46:00', 'Compra OC-2026-H226 espuma');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4050, '2026-03-09 07:02:00', 'Compra OC-2026-H227 cajas');
CALL sp_mig_compra('MP-012', '890412765-3', 10, 93700, '2026-03-09 07:06:00', 'Compra OC-2026-H228 vidrio');
CALL sp_mig_compra('MP-013', '901377820-9', 60, 15400, '2026-03-09 07:10:00', 'Compra OC-2026-H229 perfil aluminio');
CALL sp_mig_compra('MP-014', '901236478-2', 100, 342, '2026-03-09 07:14:00', 'Compra OC-2026-H230 tapas');
CALL sp_mig_compra('MP-016', '900845119-1', 10, 6750, '2026-03-09 07:18:00', 'Compra OC-2026-H231 cinta');
CALL sp_mig_orden('PR-004', 20, '2026-03-09 10:50:00', 57, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 20, '2026-03-12 21:50:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-003', 14, '2026-03-09 11:20:00', 79, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2026-03-13 20:20:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-007', 8, '2026-03-10 11:10:00', 75, 'COMPLETADA');
CALL sp_mig_despacho('PR-007', 8, '2026-03-14 16:10:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-001', 55, '2026-03-10 13:50:00', 73, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 55, '2026-03-14 16:50:00', 'Notaría 14 del Círculo');
CALL sp_mig_compra('MP-002', '901377820-9', 440, 8100, '2026-03-16 06:30:00', 'Compra OC-2026-H232 tubo');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 44950, '2026-03-16 06:46:00', 'Compra OC-2026-H233 espuma');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4200, '2026-03-16 06:54:00', 'Compra OC-2026-H234 cajas');
CALL sp_mig_compra('MP-014', '901236478-2', 200, 342, '2026-03-16 06:58:00', 'Compra OC-2026-H235 tapas');
CALL sp_mig_orden('PR-002', 20, '2026-03-16 10:20:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 20, '2026-03-20 22:20:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-005', 5, '2026-03-17 10:10:00', 51, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 5, '2026-03-20 15:10:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-006', 50, '2026-03-18 08:50:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-006', 50, '2026-03-21 12:50:00', 'Banco Andino sucursal Centro');
CALL sp_mig_compra('MP-002', '830215664-1', 540, 7950, '2026-03-23 06:34:00', 'Compra OC-2026-H236 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 40, 76300, '2026-03-23 06:38:00', 'Compra OC-2026-H237 MDF');
CALL sp_mig_compra('MP-005', '860045982-7', 500, 37, '2026-03-23 06:46:00', 'Compra OC-2026-H238 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 20, 45000, '2026-03-23 06:50:00', 'Compra OC-2026-H239 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 90, 16550, '2026-03-23 06:54:00', 'Compra OC-2026-H240 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 200, 3050, '2026-03-23 06:58:00', 'Compra OC-2026-H241 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 150, 4050, '2026-03-23 07:02:00', 'Compra OC-2026-H242 cajas');
CALL sp_mig_orden('PR-001', 40, '2026-03-23 08:30:00', 48, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 40, '2026-03-26 10:30:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-002', 20, '2026-03-25 09:30:00', 74, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 20, '2026-03-29 13:30:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-001', 40, '2026-03-25 12:20:00', 49, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 40, '2026-03-28 15:20:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-005', 7, '2026-03-25 15:40:00', 49, 'CANCELADA');
CALL sp_mig_compra('MP-002', '901377820-9', 220, 8150, '2026-03-30 06:34:00', 'Compra OC-2026-H243 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 50, 76400, '2026-03-30 06:38:00', 'Compra OC-2026-H244 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 20, 21050, '2026-03-30 06:42:00', 'Compra OC-2026-H245 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 37, '2026-03-30 06:46:00', 'Compra OC-2026-H246 tornillería');
CALL sp_mig_compra('MP-008', '860045982-7', 100, 3350, '2026-03-30 06:50:00', 'Compra OC-2026-H247 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4050, '2026-03-30 06:58:00', 'Compra OC-2026-H248 cajas');
CALL sp_mig_compra('MP-012', '890412765-3', 20, 94050, '2026-03-30 07:02:00', 'Compra OC-2026-H249 vidrio');
CALL sp_mig_compra('MP-013', '901377820-9', 100, 15500, '2026-03-30 07:06:00', 'Compra OC-2026-H250 perfil aluminio');
CALL sp_mig_compra('MP-014', '901236478-2', 100, 343, '2026-03-30 07:10:00', 'Compra OC-2026-H251 tapas');
CALL sp_mig_orden('PR-002', 25, '2026-03-30 13:10:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2026-04-04 01:10:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_despacho('PR-002', 15, '2026-04-05 01:10:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-003', 6, '2026-03-31 14:10:00', 58, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 6, '2026-04-04 02:10:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-007', 20, '2026-04-01 14:30:00', 71, 'COMPLETADA');
CALL sp_mig_despacho('PR-007', 10, '2026-04-05 15:30:00', 'Cooperativa Agrofuturo');
CALL sp_mig_despacho('PR-007', 10, '2026-04-06 15:30:00', 'Banco Andino sucursal Centro');
CALL sp_mig_compra('MP-001', '830215664-1', 650, 5000, '2026-04-06 06:30:00', 'Compra OC-2026-H252 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 380, 7650, '2026-04-06 06:34:00', 'Compra OC-2026-H253 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 60, 21100, '2026-04-06 06:38:00', 'Compra OC-2026-H254 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 37, '2026-04-06 06:42:00', 'Compra OC-2026-H255 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 20, 43650, '2026-04-06 06:46:00', 'Compra OC-2026-H256 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 100, 17450, '2026-04-06 06:50:00', 'Compra OC-2026-H257 tela');
CALL sp_mig_compra('MP-008', '860045982-7', 400, 3350, '2026-04-06 06:54:00', 'Compra OC-2026-H258 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 14200, '2026-04-06 06:58:00', 'Compra OC-2026-H259 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4050, '2026-04-06 07:02:00', 'Compra OC-2026-H260 cajas');
CALL sp_mig_orden('PR-001', 45, '2026-04-06 14:00:00', 83, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 20, '2026-04-11 03:00:00', 'Coworking Nodo 21');
CALL sp_mig_despacho('PR-001', 25, '2026-04-12 03:00:00', 'Notaría 14 del Círculo');
CALL sp_mig_orden('PR-003', 14, '2026-04-08 10:00:00', 59, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2026-04-11 23:00:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-004', 20, '2026-04-08 11:00:00', 53, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 10, '2026-04-11 18:00:00', 'Hotel Plaza Real');
CALL sp_mig_despacho('PR-004', 10, '2026-04-12 18:00:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-001', 40, '2026-04-08 15:40:00', 86, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 40, '2026-04-13 07:40:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_compra('MP-001', '900412378-5', 850, 4750, '2026-04-13 06:30:00', 'Compra OC-2026-H261 lámina');
CALL sp_mig_compra('MP-004', '901128450-3', 40, 21100, '2026-04-13 06:34:00', 'Compra OC-2026-H262 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 37, '2026-04-13 06:38:00', 'Compra OC-2026-H263 tornillería');
CALL sp_mig_compra('MP-009', '860045982-7', 150, 14250, '2026-04-13 06:42:00', 'Compra OC-2026-H264 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 50, 4200, '2026-04-13 06:46:00', 'Compra OC-2026-H265 cajas');
CALL sp_mig_compra('MP-011', '860512394-8', 20, 12250, '2026-04-13 06:50:00', 'Compra OC-2026-H266 cerraduras');
CALL sp_mig_compra('MP-015', '811027345-6', 1, 145300, '2026-04-13 06:54:00', 'Compra OC-2026-H267 pegante');
CALL sp_mig_orden('PR-004', 20, '2026-04-13 10:40:00', 62, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 20, '2026-04-17 02:40:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-008', 12, '2026-04-14 08:50:00', 90, 'COMPLETADA');
CALL sp_mig_despacho('PR-008', 12, '2026-04-19 04:50:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-005', 9, '2026-04-14 12:50:00', 71, 'CANCELADA');
CALL sp_mig_orden('PR-003', 12, '2026-04-15 15:20:00', 70, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 12, '2026-04-19 15:20:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_compra('MP-001', '830215664-1', 600, 5000, '2026-04-20 06:30:00', 'Compra OC-2026-H268 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 280, 8150, '2026-04-20 06:34:00', 'Compra OC-2026-H269 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 60, 76650, '2026-04-20 06:38:00', 'Compra OC-2026-H270 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 40, 21150, '2026-04-20 06:42:00', 'Compra OC-2026-H271 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 37, '2026-04-20 06:46:00', 'Compra OC-2026-H272 tornillería');
CALL sp_mig_compra('MP-009', '860045982-7', 150, 14250, '2026-04-20 06:50:00', 'Compra OC-2026-H273 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4100, '2026-04-20 06:54:00', 'Compra OC-2026-H274 cajas');
CALL sp_mig_orden('PR-002', 10, '2026-04-21 12:00:00', 53, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2026-04-24 19:00:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-003', 14, '2026-04-21 15:40:00', 49, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2026-04-24 18:40:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-002', 20, '2026-04-22 09:30:00', 77, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 20, '2026-04-26 16:30:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-004', 15, '2026-04-22 15:40:00', 54, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2026-04-25 23:40:00', 'Notaría 14 del Círculo');
CALL sp_mig_compra('MP-001', '900412378-5', 150, 4750, '2026-04-27 06:30:00', 'Compra OC-2026-H275 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 420, 7700, '2026-04-27 06:34:00', 'Compra OC-2026-H276 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 21150, '2026-04-27 06:38:00', 'Compra OC-2026-H277 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 37, '2026-04-27 06:42:00', 'Compra OC-2026-H278 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 20, 45250, '2026-04-27 06:46:00', 'Compra OC-2026-H279 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 110, 16650, '2026-04-27 06:50:00', 'Compra OC-2026-H280 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 400, 3050, '2026-04-27 06:54:00', 'Compra OC-2026-H281 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4100, '2026-04-27 06:58:00', 'Compra OC-2026-H282 cajas');
CALL sp_mig_compra('MP-012', '890412765-3', 10, 94500, '2026-04-27 07:02:00', 'Compra OC-2026-H283 vidrio');
CALL sp_mig_compra('MP-013', '901377820-9', 60, 15550, '2026-04-27 07:06:00', 'Compra OC-2026-H284 perfil aluminio');
CALL sp_mig_compra('MP-014', '901236478-2', 200, 344, '2026-04-27 07:10:00', 'Compra OC-2026-H285 tapas');
CALL sp_mig_orden('PR-007', 12, '2026-04-27 09:30:00', 53, 'COMPLETADA');
CALL sp_mig_despacho('PR-007', 12, '2026-04-30 16:30:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-006', 40, '2026-04-27 13:50:00', 57, 'COMPLETADA');
CALL sp_mig_despacho('PR-006', 40, '2026-05-01 00:50:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-001', 60, '2026-04-28 08:00:00', 52, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 30, '2026-05-01 14:00:00', 'Clínica del Norte S.A.');
CALL sp_mig_despacho('PR-001', 30, '2026-05-02 14:00:00', 'Notaría 14 del Círculo');
CALL sp_mig_compra('MP-001', '830215664-1', 800, 5050, '2026-05-04 06:30:00', 'Compra OC-2026-H286 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 120, 8050, '2026-05-04 06:34:00', 'Compra OC-2026-H287 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 30, 76850, '2026-05-04 06:38:00', 'Compra OC-2026-H288 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 45, 21200, '2026-05-04 06:42:00', 'Compra OC-2026-H289 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 37, '2026-05-04 06:46:00', 'Compra OC-2026-H290 tornillería');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 14300, '2026-05-04 06:50:00', 'Compra OC-2026-H291 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4100, '2026-05-04 06:54:00', 'Compra OC-2026-H292 cajas');
CALL sp_mig_orden('PR-004', 30, '2026-05-05 08:30:00', 61, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2026-05-08 23:30:00', 'Colegio San Ignacio');
CALL sp_mig_despacho('PR-004', 15, '2026-05-09 23:30:00', 'Constructora Altos del Valle');
CALL sp_mig_orden('PR-002', 15, '2026-05-05 11:00:00', 85, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 15, '2026-05-10 02:00:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-003', 14, '2026-05-05 14:00:00', 79, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 14, '2026-05-09 23:00:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-009', 15, '2026-05-05 15:50:00', 63, 'CANCELADA');
CALL sp_mig_compra('MP-001', '900412378-5', 350, 4800, '2026-05-11 06:30:00', 'Compra OC-2026-H293 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 380, 8200, '2026-05-11 06:34:00', 'Compra OC-2026-H294 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 30, 21200, '2026-05-11 06:38:00', 'Compra OC-2026-H295 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 37, '2026-05-11 06:42:00', 'Compra OC-2026-H296 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 20, 45400, '2026-05-11 06:46:00', 'Compra OC-2026-H297 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 100, 16650, '2026-05-11 06:50:00', 'Compra OC-2026-H298 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 200, 3050, '2026-05-11 06:54:00', 'Compra OC-2026-H299 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 14300, '2026-05-11 06:58:00', 'Compra OC-2026-H300 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4250, '2026-05-11 07:02:00', 'Compra OC-2026-H301 cajas');
CALL sp_mig_compra('MP-011', '860512394-8', 10, 12350, '2026-05-11 07:06:00', 'Compra OC-2026-H302 cerraduras');
CALL sp_mig_compra('MP-014', '901236478-2', 100, 345, '2026-05-11 07:10:00', 'Compra OC-2026-H303 tapas');
CALL sp_mig_orden('PR-006', 40, '2026-05-12 10:20:00', 63, 'COMPLETADA');
CALL sp_mig_despacho('PR-006', 20, '2026-05-16 03:20:00', 'Coworking Nodo 21');
CALL sp_mig_despacho('PR-006', 20, '2026-05-17 03:20:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-008', 12, '2026-05-12 14:50:00', 85, 'COMPLETADA');
CALL sp_mig_despacho('PR-008', 12, '2026-05-17 05:50:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-001', 50, '2026-05-13 10:40:00', 55, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 25, '2026-05-16 19:40:00', 'Cooperativa Agrofuturo');
CALL sp_mig_despacho('PR-001', 25, '2026-05-17 19:40:00', 'Colegio San Ignacio');
CALL sp_mig_compra('MP-001', '830215664-1', 575, 5050, '2026-05-18 06:30:00', 'Compra OC-2026-H304 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 100, 7700, '2026-05-18 06:34:00', 'Compra OC-2026-H305 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 77050, '2026-05-18 06:38:00', 'Compra OC-2026-H306 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 35, 21250, '2026-05-18 06:42:00', 'Compra OC-2026-H307 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 38, '2026-05-18 06:46:00', 'Compra OC-2026-H308 tornillería');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 14300, '2026-05-18 06:50:00', 'Compra OC-2026-H309 rieles');
CALL sp_mig_compra('MP-010', '900845119-1', 50, 4100, '2026-05-18 06:54:00', 'Compra OC-2026-H310 cajas');
CALL sp_mig_compra('MP-011', '860512394-8', 10, 12350, '2026-05-18 06:58:00', 'Compra OC-2026-H311 cerraduras');
CALL sp_mig_compra('MP-016', '900845119-1', 10, 6800, '2026-05-18 07:06:00', 'Compra OC-2026-H312 cinta');
CALL sp_mig_orden('PR-004', 15, '2026-05-18 14:30:00', 48, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2026-05-21 16:30:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-008', 8, '2026-05-19 10:00:00', 61, 'COMPLETADA');
CALL sp_mig_despacho('PR-008', 8, '2026-05-23 01:00:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-002', 10, '2026-05-19 10:40:00', 65, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2026-05-23 05:40:00', 'Constructora Altos del Valle');
CALL sp_mig_orden('PR-003', 8, '2026-05-20 09:40:00', 58, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 8, '2026-05-23 21:40:00', 'Constructora Altos del Valle');
CALL sp_mig_compra('MP-001', '900412378-5', 125, 4800, '2026-05-25 06:30:00', 'Compra OC-2026-H313 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 500, 8050, '2026-05-25 06:34:00', 'Compra OC-2026-H314 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 77150, '2026-05-25 06:38:00', 'Compra OC-2026-H315 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 21250, '2026-05-25 06:42:00', 'Compra OC-2026-H316 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 38, '2026-05-25 06:46:00', 'Compra OC-2026-H317 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 20, 44000, '2026-05-25 06:50:00', 'Compra OC-2026-H318 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 110, 17600, '2026-05-25 06:54:00', 'Compra OC-2026-H319 tela');
CALL sp_mig_compra('MP-008', '860045982-7', 300, 3350, '2026-05-25 06:58:00', 'Compra OC-2026-H320 rodachines');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4250, '2026-05-25 07:02:00', 'Compra OC-2026-H321 cajas');
CALL sp_mig_compra('MP-014', '901236478-2', 100, 346, '2026-05-25 07:06:00', 'Compra OC-2026-H322 tapas');
CALL sp_mig_compra('MP-015', '811027345-6', 1, 146350, '2026-05-25 07:10:00', 'Compra OC-2026-H323 pegante');
CALL sp_mig_compra('MP-017', '860045982-7', 20, 41550, '2026-05-25 07:18:00', 'Compra OC-2026-H324 bases giratorias');
CALL sp_mig_compra('MP-018', '860045982-7', 20, 16300, '2026-05-25 07:22:00', 'Compra OC-2026-H325 pistones');
CALL sp_mig_orden('PR-001', 55, '2026-05-25 12:10:00', 48, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 25, '2026-05-28 14:10:00', 'Colegio San Ignacio');
CALL sp_mig_despacho('PR-001', 30, '2026-05-29 14:10:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-002', 10, '2026-05-26 12:00:00', 82, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2026-05-31 00:00:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-008', 16, '2026-05-27 09:30:00', 83, 'CANCELADA');
CALL sp_mig_orden('PR-009', 15, '2026-05-27 15:00:00', 66, 'COMPLETADA');
CALL sp_mig_despacho('PR-009', 15, '2026-05-31 11:00:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-006', 30, '2026-05-27 15:40:00', 88, 'COMPLETADA');
CALL sp_mig_despacho('PR-006', 15, '2026-06-01 09:40:00', 'Banco Andino sucursal Centro');
CALL sp_mig_despacho('PR-006', 15, '2026-06-02 09:40:00', 'Colegio San Ignacio');
CALL sp_mig_compra('MP-001', '830215664-1', 400, 5050, '2026-06-01 06:30:00', 'Compra OC-2026-H326 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 420, 8200, '2026-06-01 06:34:00', 'Compra OC-2026-H327 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 50, 77200, '2026-06-01 06:38:00', 'Compra OC-2026-H328 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 40, 21300, '2026-06-01 06:42:00', 'Compra OC-2026-H329 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 38, '2026-06-01 06:46:00', 'Compra OC-2026-H330 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 10, 45550, '2026-06-01 06:50:00', 'Compra OC-2026-H331 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 60, 16750, '2026-06-01 06:54:00', 'Compra OC-2026-H332 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 200, 3050, '2026-06-01 06:58:00', 'Compra OC-2026-H333 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 150, 4100, '2026-06-01 07:02:00', 'Compra OC-2026-H334 cajas');
CALL sp_mig_orden('PR-004', 20, '2026-06-02 08:40:00', 70, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 20, '2026-06-06 08:40:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_orden('PR-002', 25, '2026-06-02 09:10:00', 50, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 25, '2026-06-05 13:10:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-001', 45, '2026-06-03 09:30:00', 87, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 20, '2026-06-08 02:30:00', 'Constructora Altos del Valle');
CALL sp_mig_despacho('PR-001', 25, '2026-06-09 02:30:00', 'Banco Andino sucursal Centro');
CALL sp_mig_compra('MP-001', '900412378-5', 475, 4800, '2026-06-08 06:30:00', 'Compra OC-2026-H335 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 420, 7750, '2026-06-08 06:34:00', 'Compra OC-2026-H336 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 40, 21300, '2026-06-08 06:38:00', 'Compra OC-2026-H337 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2000, 38, '2026-06-08 06:42:00', 'Compra OC-2026-H338 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 30, 45600, '2026-06-08 06:46:00', 'Compra OC-2026-H339 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 110, 16750, '2026-06-08 06:50:00', 'Compra OC-2026-H340 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 500, 3050, '2026-06-08 06:54:00', 'Compra OC-2026-H341 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 14350, '2026-06-08 06:58:00', 'Compra OC-2026-H342 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4250, '2026-06-08 07:02:00', 'Compra OC-2026-H343 cajas');
CALL sp_mig_orden('PR-001', 60, '2026-06-08 11:30:00', 57, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 30, '2026-06-11 22:30:00', 'Colegio San Ignacio');
CALL sp_mig_despacho('PR-001', 30, '2026-06-12 22:30:00', 'Coworking Nodo 21');
CALL sp_mig_orden('PR-003', 8, '2026-06-09 09:00:00', 70, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 8, '2026-06-13 09:00:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-001', 35, '2026-06-10 11:40:00', 69, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 35, '2026-06-14 10:40:00', 'Alcaldía Municipal (dotación)');
CALL sp_mig_compra('MP-001', '830215664-1', 100, 5050, '2026-06-15 06:30:00', 'Compra OC-2026-H344 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 340, 8100, '2026-06-15 06:34:00', 'Compra OC-2026-H345 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 15, 21350, '2026-06-15 06:38:00', 'Compra OC-2026-H346 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1000, 38, '2026-06-15 06:42:00', 'Compra OC-2026-H347 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 20, 44150, '2026-06-15 06:46:00', 'Compra OC-2026-H348 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 100, 17650, '2026-06-15 06:50:00', 'Compra OC-2026-H349 tela');
CALL sp_mig_compra('MP-008', '860045982-7', 200, 3350, '2026-06-15 06:54:00', 'Compra OC-2026-H350 rodachines');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4250, '2026-06-15 06:58:00', 'Compra OC-2026-H351 cajas');
CALL sp_mig_compra('MP-012', '890412765-3', 10, 95250, '2026-06-15 07:02:00', 'Compra OC-2026-H352 vidrio');
CALL sp_mig_compra('MP-013', '901377820-9', 40, 15700, '2026-06-15 07:06:00', 'Compra OC-2026-H353 perfil aluminio');
CALL sp_mig_compra('MP-014', '901236478-2', 200, 347, '2026-06-15 07:10:00', 'Compra OC-2026-H354 tapas');
CALL sp_mig_compra('MP-017', '860045982-7', 10, 41700, '2026-06-15 07:22:00', 'Compra OC-2026-H355 bases giratorias');
CALL sp_mig_compra('MP-018', '860045982-7', 10, 16350, '2026-06-15 07:26:00', 'Compra OC-2026-H356 pistones');
CALL sp_mig_orden('PR-001', 40, '2026-06-15 09:30:00', 63, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 20, '2026-06-19 02:30:00', 'Constructora Altos del Valle');
CALL sp_mig_despacho('PR-001', 20, '2026-06-20 02:30:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-009', 15, '2026-06-16 08:00:00', 69, 'COMPLETADA');
CALL sp_mig_despacho('PR-009', 15, '2026-06-20 07:00:00', 'Universidad Regional (compras)');
CALL sp_mig_orden('PR-007', 12, '2026-06-16 09:10:00', 48, 'CANCELADA');
CALL sp_mig_orden('PR-006', 30, '2026-06-17 13:00:00', 85, 'COMPLETADA');
CALL sp_mig_despacho('PR-006', 30, '2026-06-22 04:00:00', 'Cooperativa Agrofuturo');
CALL sp_mig_orden('PR-007', 8, '2026-06-17 15:50:00', 74, 'COMPLETADA');
CALL sp_mig_despacho('PR-007', 8, '2026-06-21 19:50:00', 'Hotel Plaza Real');
CALL sp_mig_compra('MP-001', '900412378-5', 500, 4800, '2026-06-22 06:30:00', 'Compra OC-2026-H357 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 460, 8250, '2026-06-22 06:34:00', 'Compra OC-2026-H358 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 45, 21350, '2026-06-22 06:38:00', 'Compra OC-2026-H359 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 3000, 38, '2026-06-22 06:42:00', 'Compra OC-2026-H360 tornillería');
CALL sp_mig_compra('MP-006', '900776231-2', 30, 45700, '2026-06-22 06:46:00', 'Compra OC-2026-H361 espuma');
CALL sp_mig_compra('MP-007', '811027345-6', 130, 16800, '2026-06-22 06:50:00', 'Compra OC-2026-H362 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 500, 3100, '2026-06-22 06:54:00', 'Compra OC-2026-H363 rodachines');
CALL sp_mig_compra('MP-010', '900845119-1', 100, 4100, '2026-06-22 06:58:00', 'Compra OC-2026-H364 cajas');
CALL sp_mig_compra('MP-017', '860045982-7', 10, 41750, '2026-06-22 07:10:00', 'Compra OC-2026-H365 bases giratorias');
CALL sp_mig_compra('MP-018', '860045982-7', 10, 16400, '2026-06-22 07:14:00', 'Compra OC-2026-H366 pistones');
CALL sp_mig_orden('PR-009', 10, '2026-06-23 12:10:00', 72, 'COMPLETADA');
CALL sp_mig_despacho('PR-009', 10, '2026-06-27 14:10:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-001', 45, '2026-06-24 09:10:00', 90, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 45, '2026-06-29 05:10:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-001', 50, '2026-06-24 12:10:00', 74, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 50, '2026-06-28 16:10:00', 'Banco Andino sucursal Centro');
CALL sp_mig_orden('PR-004', 20, '2026-06-24 15:00:00', 52, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 10, '2026-06-27 21:00:00', 'Banco Andino sucursal Centro');
CALL sp_mig_despacho('PR-004', 10, '2026-06-28 21:00:00', 'Universidad Regional (compras)');
CALL sp_mig_compra('MP-001', '830215664-1', 275, 5050, '2026-06-29 06:30:00', 'Compra OC-2026-H367 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 100, 7750, '2026-06-29 06:34:00', 'Compra OC-2026-H368 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 20, 77600, '2026-06-29 06:38:00', 'Compra OC-2026-H369 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 15, 21400, '2026-06-29 06:42:00', 'Compra OC-2026-H370 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 500, 38, '2026-06-29 06:46:00', 'Compra OC-2026-H371 tornillería');
CALL sp_mig_compra('MP-008', '901236478-2', 100, 3100, '2026-06-29 06:50:00', 'Compra OC-2026-H372 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 14400, '2026-06-29 06:54:00', 'Compra OC-2026-H373 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 50, 4300, '2026-06-29 06:58:00', 'Compra OC-2026-H374 cajas');
CALL sp_mig_compra('MP-012', '890412765-3', 20, 95500, '2026-06-29 07:02:00', 'Compra OC-2026-H375 vidrio');
CALL sp_mig_compra('MP-013', '901377820-9', 100, 15700, '2026-06-29 07:06:00', 'Compra OC-2026-H376 perfil aluminio');
CALL sp_mig_compra('MP-014', '901236478-2', 100, 348, '2026-06-29 07:10:00', 'Compra OC-2026-H377 tapas');
CALL sp_mig_orden('PR-007', 20, '2026-06-29 14:20:00', 76, 'COMPLETADA');
-- (PR-007: esta última producción queda en bodega, sin despachar)
CALL sp_mig_orden('PR-003', 10, '2026-06-30 10:00:00', 87, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2026-07-05 03:00:00', 'Constructora Altos del Valle');
CALL sp_mig_orden('PR-007', 16, '2026-06-30 15:50:00', 87, 'CANCELADA');
CALL sp_mig_orden('PR-005', 7, '2026-07-01 09:00:00', 62, 'COMPLETADA');
CALL sp_mig_despacho('PR-005', 7, '2026-07-05 01:00:00', 'Notaría 14 del Círculo');
CALL sp_mig_compra('MP-001', '900412378-5', 625, 4850, '2026-07-06 06:30:00', 'Compra OC-2026-H378 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 700, 8100, '2026-07-06 06:34:00', 'Compra OC-2026-H379 tubo');
CALL sp_mig_compra('MP-003', '890305127-9', 80, 77700, '2026-07-06 06:38:00', 'Compra OC-2026-H380 MDF');
CALL sp_mig_compra('MP-004', '901128450-3', 60, 21400, '2026-07-06 06:42:00', 'Compra OC-2026-H381 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 4000, 38, '2026-07-06 06:46:00', 'Compra OC-2026-H382 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 20, 44300, '2026-07-06 06:50:00', 'Compra OC-2026-H383 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 90, 17750, '2026-07-06 06:54:00', 'Compra OC-2026-H384 tela');
CALL sp_mig_compra('MP-008', '860045982-7', 300, 3400, '2026-07-06 06:58:00', 'Compra OC-2026-H385 rodachines');
CALL sp_mig_compra('MP-010', '890902117-4', 200, 4300, '2026-07-06 07:02:00', 'Compra OC-2026-H386 cajas');
CALL sp_mig_orden('PR-002', 20, '2026-07-06 09:10:00', 72, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 10, '2026-07-10 11:10:00', 'Cooperativa Agrofuturo');
CALL sp_mig_despacho('PR-002', 10, '2026-07-11 11:10:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-002', 20, '2026-07-06 11:20:00', 58, 'COMPLETADA');
CALL sp_mig_despacho('PR-002', 20, '2026-07-09 23:20:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-004', 30, '2026-07-08 12:20:00', 76, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2026-07-12 18:20:00', 'Coworking Nodo 21');
CALL sp_mig_despacho('PR-004', 15, '2026-07-13 18:20:00', 'Notaría 14 del Círculo');
CALL sp_mig_orden('PR-001', 35, '2026-07-08 12:50:00', 73, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 15, '2026-07-12 15:50:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_despacho('PR-001', 20, '2026-07-13 15:50:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-001', 40, '2026-07-08 14:10:00', 87, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 20, '2026-07-13 07:10:00', 'Cooperativa Agrofuturo');
CALL sp_mig_despacho('PR-001', 20, '2026-07-14 07:10:00', 'Coworking Nodo 21');
CALL sp_mig_compra('MP-001', '830215664-1', 275, 5100, '2026-07-13 06:30:00', 'Compra OC-2026-H387 lámina');
CALL sp_mig_compra('MP-002', '901377820-9', 240, 8300, '2026-07-13 06:34:00', 'Compra OC-2026-H388 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 25, 21450, '2026-07-13 06:38:00', 'Compra OC-2026-H389 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1000, 38, '2026-07-13 06:42:00', 'Compra OC-2026-H390 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 44350, '2026-07-13 06:46:00', 'Compra OC-2026-H391 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 60, 17750, '2026-07-13 06:50:00', 'Compra OC-2026-H392 tela');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 14450, '2026-07-13 06:54:00', 'Compra OC-2026-H393 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 50, 4300, '2026-07-13 06:58:00', 'Compra OC-2026-H394 cajas');
CALL sp_mig_compra('MP-014', '901236478-2', 200, 349, '2026-07-13 07:02:00', 'Compra OC-2026-H395 tapas');
CALL sp_mig_orden('PR-006', 40, '2026-07-14 08:40:00', 80, 'COMPLETADA');
CALL sp_mig_despacho('PR-006', 20, '2026-07-18 18:40:00', 'Universidad Regional (compras)');
CALL sp_mig_despacho('PR-006', 20, '2026-07-19 18:40:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-003', 10, '2026-07-14 11:50:00', 88, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 10, '2026-07-19 05:50:00', 'Distribuidora de Muebles Capital');
CALL sp_mig_orden('PR-006', 25, '2026-07-14 14:50:00', 79, 'COMPLETADA');
-- (PR-006: esta última producción queda en bodega, sin despachar)
CALL sp_mig_compra('MP-001', '900412378-5', 600, 4850, '2026-07-20 06:30:00', 'Compra OC-2026-H396 lámina');
CALL sp_mig_compra('MP-002', '900412378-5', 160, 7800, '2026-07-20 06:34:00', 'Compra OC-2026-H397 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 35, 21450, '2026-07-20 06:38:00', 'Compra OC-2026-H398 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 1500, 38, '2026-07-20 06:42:00', 'Compra OC-2026-H399 tornillería');
CALL sp_mig_compra('MP-007', '811027345-6', 40, 16850, '2026-07-20 06:50:00', 'Compra OC-2026-H400 tela');
CALL sp_mig_compra('MP-008', '901236478-2', 200, 3100, '2026-07-20 06:54:00', 'Compra OC-2026-H401 rodachines');
CALL sp_mig_compra('MP-009', '860045982-7', 100, 14450, '2026-07-20 06:58:00', 'Compra OC-2026-H402 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 50, 4300, '2026-07-20 07:02:00', 'Compra OC-2026-H403 cajas');
CALL sp_mig_compra('MP-011', '860512394-8', 20, 12500, '2026-07-20 07:06:00', 'Compra OC-2026-H404 cerraduras');
CALL sp_mig_compra('MP-015', '811027345-6', 1, 147750, '2026-07-20 07:10:00', 'Compra OC-2026-H405 pegante');
CALL sp_mig_compra('MP-016', '900845119-1', 10, 6900, '2026-07-20 07:14:00', 'Compra OC-2026-H406 cinta');
CALL sp_mig_orden('PR-008', 12, '2026-07-20 14:20:00', 49, 'COMPLETADA');
CALL sp_mig_despacho('PR-008', 12, '2026-07-23 17:20:00', 'Clínica del Norte S.A.');
CALL sp_mig_orden('PR-001', 35, '2026-07-20 15:40:00', 73, 'COMPLETADA');
CALL sp_mig_despacho('PR-001', 35, '2026-07-24 18:40:00', 'Notaría 14 del Círculo');
CALL sp_mig_orden('PR-008', 16, '2026-07-21 13:20:00', 72, 'COMPLETADA');
-- (PR-008: esta última producción queda en bodega, sin despachar)
CALL sp_mig_orden('PR-004', 15, '2026-07-21 14:30:00', 87, 'CANCELADA');
CALL sp_mig_compra('MP-001', '830215664-1', 725, 5100, '2026-07-27 06:30:00', 'Compra OC-2026-H407 lámina');
CALL sp_mig_compra('MP-002', '830215664-1', 40, 8150, '2026-07-27 06:34:00', 'Compra OC-2026-H408 tubo');
CALL sp_mig_compra('MP-004', '901128450-3', 40, 21500, '2026-07-27 06:38:00', 'Compra OC-2026-H409 pintura');
CALL sp_mig_compra('MP-005', '860045982-7', 2500, 38, '2026-07-27 06:42:00', 'Compra OC-2026-H410 tornillería');
CALL sp_mig_compra('MP-006', '811027345-6', 10, 44450, '2026-07-27 06:46:00', 'Compra OC-2026-H411 espuma');
CALL sp_mig_compra('MP-007', '900776231-2', 20, 17800, '2026-07-27 06:50:00', 'Compra OC-2026-H412 tela');
CALL sp_mig_compra('MP-009', '860045982-7', 50, 14500, '2026-07-27 06:54:00', 'Compra OC-2026-H413 rieles');
CALL sp_mig_compra('MP-010', '890902117-4', 100, 4300, '2026-07-27 06:58:00', 'Compra OC-2026-H414 cajas');
CALL sp_mig_compra('MP-017', '860045982-7', 20, 41950, '2026-07-27 07:10:00', 'Compra OC-2026-H415 bases giratorias');
CALL sp_mig_compra('MP-018', '860045982-7', 20, 16500, '2026-07-27 07:14:00', 'Compra OC-2026-H416 pistones');
CALL sp_mig_orden('PR-003', 6, '2026-07-27 09:20:00', 90, 'COMPLETADA');
CALL sp_mig_despacho('PR-003', 6, '2026-08-01 05:20:00', 'Oficinas Modernas S.A.S.');
CALL sp_mig_orden('PR-004', 15, '2026-07-27 11:30:00', 55, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 15, '2026-07-30 20:30:00', 'Colegio San Ignacio');
CALL sp_mig_orden('PR-009', 15, '2026-07-28 11:20:00', 49, 'COMPLETADA');
-- (PR-009: esta última producción queda en bodega, sin despachar)
CALL sp_mig_orden('PR-004', 25, '2026-07-29 09:30:00', 63, 'COMPLETADA');
CALL sp_mig_despacho('PR-004', 10, '2026-08-02 02:30:00', 'Coworking Nodo 21');
CALL sp_mig_despacho('PR-004', 15, '2026-08-03 02:30:00', 'Colegio San Ignacio');

-- Cierre del periodo: ajustes de inventario de las materias originales y reposición de las nuevas
CALL sp_mig_salida('MP-001', 19, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-002', 1, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-004', 3.35, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-005', 334, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-006', 4.75, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-007', 0.5, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-008', 28, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-009', 4, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_salida('MP-010', 45, '2026-08-02 20:00:00', 'Ajuste por inventario físico y mermas - cierre de julio 2026');
CALL sp_mig_compra('MP-011', '860512394-8', 70, 12500, '2026-07-31 09:00:00', 'Reposición OC-2026-H417 cerraduras');
CALL sp_mig_compra('MP-012', '890412765-3', 25, 96000, '2026-07-31 09:00:00', 'Reposición OC-2026-H418 vidrio');
CALL sp_mig_compra('MP-013', '901377820-9', 160, 15800, '2026-07-31 09:00:00', 'Reposición OC-2026-H419 perfil aluminio');
CALL sp_mig_compra('MP-014', '901236478-2', 500, 350, '2026-07-31 09:00:00', 'Reposición OC-2026-H420 tapas');
CALL sp_mig_compra('MP-015', '811027345-6', 10, 148000, '2026-07-31 09:00:00', 'Reposición OC-2026-H421 pegante');
CALL sp_mig_compra('MP-016', '900845119-1', 20, 6900, '2026-07-31 09:00:00', 'Reposición OC-2026-H422 cinta');
CALL sp_mig_compra('MP-017', '860045982-7', 50, 42000, '2026-07-31 09:00:00', 'Reposición OC-2026-H423 bases giratorias');
CALL sp_mig_compra('MP-018', '860045982-7', 50, 16500, '2026-07-31 09:00:00', 'Reposición OC-2026-H424 pistones');

-- ---------------------------------------------------------------------
-- 3. CIERRE: constancia y limpieza de ayudantes
-- ---------------------------------------------------------------------
INSERT IGNORE INTO migracion_log (nombre) VALUES ('datos_historicos');

DROP PROCEDURE IF EXISTS sp_mig_requisito;
DROP PROCEDURE IF EXISTS sp_mig_compra;
DROP PROCEDURE IF EXISTS sp_mig_salida;
DROP PROCEDURE IF EXISTS sp_mig_orden;
DROP PROCEDURE IF EXISTS sp_mig_despacho;
SET @mig_omitir = NULL;

-- ---------------------------------------------------------------------
-- 4. VERIFICACIONES (ejecutar una a la vez)
-- ---------------------------------------------------------------------
-- 4.1 Conciliación: stock guardado = suma del kardex (la columna 'diferencia' debe ser 0 en todas)
-- SELECT mp.codigo, mp.stock_actual,
--        COALESCE(SUM(CASE WHEN m.tipo='ENTRADA' THEN m.cantidad ELSE -m.cantidad END),0) AS stock_kardex,
--        mp.stock_actual - COALESCE(SUM(CASE WHEN m.tipo='ENTRADA' THEN m.cantidad ELSE -m.cantidad END),0) AS diferencia
--   FROM materia_prima mp LEFT JOIN movimiento_inventario m ON m.id_materia_prima = mp.id_materia_prima
--  GROUP BY mp.id_materia_prima, mp.codigo, mp.stock_actual;
--
-- 4.2 Producto terminado = producido - despachado
-- SELECT pr.codigo, pr.stock_actual,
--        COALESCE((SELECT SUM(cantidad) FROM orden_produccion WHERE id_producto=pr.id_producto AND estado='COMPLETADA'),0)
--      - COALESCE((SELECT SUM(cantidad) FROM despacho WHERE id_producto=pr.id_producto),0) AS esperado
--   FROM producto pr;
--
-- 4.3 Volumen por tabla
-- SELECT 'ordenes' t, COUNT(*) n FROM orden_produccion UNION ALL SELECT 'movimientos', COUNT(*) FROM movimiento_inventario
-- UNION ALL SELECT 'despachos', COUNT(*) FROM despacho UNION ALL SELECT 'proveedores', COUNT(*) FROM proveedor;
--
-- 4.4 Las pruebas de antes siguen igual: OP-9 debe FALLAR y OP-10 debe funcionar
-- CALL sp_completar_orden(9);   -- error: falta MDF (hay 32, necesita 40)
-- CALL sp_completar_orden(10);  -- funciona
