-- =====================================================================
-- MEJORAS DE ESTRUCTURA PARA CRECER (escalabilidad e integridad)
-- Ejecutar DESPUÉS de manufactura_completa.sql y funciones_crud.sql
--
-- REGLA DE ESTE ARCHIVO: solo AGREGA. No hay DROP de tablas ni de datos,
-- no se cambia ningún nombre, columna ni procedimiento que ya exista.
-- Se puede ejecutar más de una vez sin daño (cada cambio revisa
-- primero si ya está hecho).
-- =====================================================================

SET NAMES utf8mb4;
USE manufactura;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 0. Ayudantes temporales: "crea el índice / la restricción SOLO si no existe"
--    (se borran al final del archivo)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_mig_indice$$
CREATE PROCEDURE sp_mig_indice(IN p_tabla VARCHAR(64), IN p_indice VARCHAR(64), IN p_columnas VARCHAR(200))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.statistics
                  WHERE table_schema = DATABASE()
                    AND table_name = p_tabla AND index_name = p_indice) THEN
    SET @sql = CONCAT('CREATE INDEX ', p_indice, ' ON ', p_tabla, ' (', p_columnas, ')');
    PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_mig_check$$
CREATE PROCEDURE sp_mig_check(IN p_tabla VARCHAR(64), IN p_nombre VARCHAR(64), IN p_expresion VARCHAR(500))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints
                  WHERE table_schema = DATABASE() AND table_name = p_tabla
                    AND constraint_name = p_nombre AND constraint_type = 'CHECK') THEN
    SET @sql = CONCAT('ALTER TABLE ', p_tabla, ' ADD CONSTRAINT ', p_nombre, ' CHECK (', p_expresion, ')');
    PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_mig_columna$$
CREATE PROCEDURE sp_mig_columna(IN p_tabla VARCHAR(64), IN p_columna VARCHAR(64), IN p_definicion VARCHAR(200))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = DATABASE()
                    AND table_name = p_tabla AND column_name = p_columna) THEN
    SET @sql = CONCAT('ALTER TABLE ', p_tabla, ' ADD COLUMN ', p_columna, ' ', p_definicion);
    PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;
  END IF;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 1. ÍNDICES: que las consultas no se vuelvan lentas cuando haya miles de filas
--    Sin índice, MySQL lee TODA la tabla para filtrar. Con índice salta directo.
-- ---------------------------------------------------------------------
-- Filtro de la interfaz (Pendientes / Completadas / Canceladas) + orden por fecha
CALL sp_mig_indice('orden_produccion', 'idx_op_estado_fecha', 'estado, fecha_creacion');
-- Reportes por fecha (producción y compras por mes)
CALL sp_mig_indice('movimiento_inventario', 'idx_mov_fecha', 'fecha');
-- Sumas de entradas/salidas por materia y tipo (consultas 7.5 y 7.6)
CALL sp_mig_indice('movimiento_inventario', 'idx_mov_materia_tipo', 'id_materia_prima, tipo');

-- ---------------------------------------------------------------------
-- 2. INTEGRIDAD: una orden PENDIENTE no tiene fecha de cierre;
--    una COMPLETADA o CANCELADA siempre la tiene y nunca es anterior a la creación.
--    (todos los datos actuales ya cumplen esta regla)
-- ---------------------------------------------------------------------
CALL sp_mig_check('orden_produccion', 'ck_op_cierre_coherente',
  "(estado = 'PENDIENTE' AND fecha_cierre IS NULL) OR (estado <> 'PENDIENTE' AND fecha_cierre IS NOT NULL AND fecha_cierre >= fecha_creacion)");

-- ---------------------------------------------------------------------
-- 3. COSTO REAL DE CADA COMPRA
--    Hoy el kardex guarda cuánto entró, pero no a qué precio. Si el proveedor
--    cambia su precio mañana, se perdería cuánto costó la compra de hoy.
--    La columna es opcional (NULL), así que los INSERT que ya existen siguen igual.
-- ---------------------------------------------------------------------
CALL sp_mig_columna('movimiento_inventario', 'costo_unitario', 'DECIMAL(12,2) NULL AFTER cantidad');
CALL sp_mig_check('movimiento_inventario', 'ck_mov_costo', 'costo_unitario IS NULL OR costo_unitario > 0');

-- Rellena las compras antiguas con el precio del catálogo (solo donde está vacío)
UPDATE movimiento_inventario m
  JOIN proveedor_materia_prima pmp
    ON pmp.id_proveedor = m.id_proveedor AND pmp.id_materia_prima = m.id_materia_prima
   SET m.costo_unitario = pmp.precio_unitario
 WHERE m.tipo = 'ENTRADA' AND m.costo_unitario IS NULL;

DELIMITER $$

-- Desde ahora, cada compra nueva guarda sola el precio vigente del proveedor.
-- Es un trigger BEFORE: llena el dato ANTES de guardar la fila, sin tocar
-- sp_registrar_compra ni ningún otro procedimiento.
DROP TRIGGER IF EXISTS trg_movimiento_costo$$
CREATE TRIGGER trg_movimiento_costo
BEFORE INSERT ON movimiento_inventario
FOR EACH ROW
BEGIN
  IF NEW.tipo = 'ENTRADA' AND NEW.costo_unitario IS NULL AND NEW.id_proveedor IS NOT NULL THEN
    SET NEW.costo_unitario = (SELECT precio_unitario
                                FROM proveedor_materia_prima
                               WHERE id_proveedor = NEW.id_proveedor
                                 AND id_materia_prima = NEW.id_materia_prima);
  END IF;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 4. DESPACHOS (salida de producto terminado)
--    Hoy el producto terminado solo sube (cuando se completa una orden) y nunca
--    baja: con meses de operación el stock crecería sin límite. Esta tabla
--    registra lo que se entrega a los clientes y descuenta solo.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS despacho (
  id_despacho INT AUTO_INCREMENT PRIMARY KEY,
  id_producto INT          NOT NULL,
  cantidad    INT          NOT NULL,
  fecha       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  cliente     VARCHAR(100) NOT NULL,
  observacion VARCHAR(200),
  CONSTRAINT fk_desp_producto FOREIGN KEY (id_producto)
    REFERENCES producto(id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_desp_cantidad CHECK (cantidad > 0),
  INDEX idx_desp_producto_fecha (id_producto, fecha),
  INDEX idx_desp_fecha (fecha)
) ENGINE=InnoDB;

DELIMITER $$

DROP TRIGGER IF EXISTS trg_despacho_actualiza_stock$$
CREATE TRIGGER trg_despacho_actualiza_stock
AFTER INSERT ON despacho
FOR EACH ROW
BEGIN
  -- Si no hay suficiente producto, el CHECK de producto.stock_actual falla y todo se cancela
  UPDATE producto SET stock_actual = stock_actual - NEW.cantidad
   WHERE id_producto = NEW.id_producto;
END$$

-- Registra un despacho con un mensaje claro si no alcanza el producto
DROP PROCEDURE IF EXISTS sp_registrar_despacho$$
CREATE PROCEDURE sp_registrar_despacho(
  IN p_id_producto INT, IN p_cantidad INT, IN p_cliente VARCHAR(100), IN p_observacion VARCHAR(200))
BEGIN
  DECLARE v_stock INT;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad debe ser mayor que cero';
  END IF;

  SELECT stock_actual INTO v_stock FROM producto WHERE id_producto = p_id_producto FOR UPDATE;

  IF v_stock IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  END IF;
  IF v_stock < p_cantidad THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No hay suficiente producto terminado para despachar';
  END IF;

  INSERT INTO despacho (id_producto, cantidad, cliente, observacion)
  VALUES (p_id_producto, p_cantidad, p_cliente, p_observacion);

  SELECT codigo, nombre, stock_actual FROM producto WHERE id_producto = p_id_producto;
END$$

-- ---------------------------------------------------------------------
-- 5. LECTURA PAGINADA DEL KARDEX
--    sp_get_kardex devuelve TODAS las filas de la materia. Con años de historia
--    serían miles. Esta versión devuelve de a páginas, lo más nuevo primero.
--    (sp_get_kardex sigue existiendo igual, no se tocó)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_get_kardex_paginado$$
CREATE PROCEDURE sp_get_kardex_paginado(
  IN p_id_materia INT, IN p_limite INT, IN p_desplazamiento INT)
BEGIN
  SELECT * FROM (
    SELECT m.id_movimiento, m.fecha, m.tipo, m.cantidad, m.costo_unitario,
           pv.nombre AS proveedor, m.id_orden, m.observacion,
           SUM(CASE WHEN m.tipo = 'ENTRADA' THEN m.cantidad ELSE -m.cantidad END)
             OVER (ORDER BY m.fecha, m.id_movimiento) AS saldo
      FROM movimiento_inventario m
      LEFT JOIN proveedor pv ON pv.id_proveedor = m.id_proveedor
     WHERE m.id_materia_prima = p_id_materia
  ) k
  ORDER BY k.fecha DESC, k.id_movimiento DESC
  LIMIT p_limite OFFSET p_desplazamiento;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 5b. ÓRDENES: lo más reciente primero
--     Con cientos de órdenes, la nueva quedaba al final de la lista. Mismo
--     procedimiento, mismas columnas y mismo filtro; solo cambia el ORDER BY.
-- ---------------------------------------------------------------------
DELIMITER $$
DROP PROCEDURE IF EXISTS sp_get_ordenes$$
CREATE PROCEDURE sp_get_ordenes(IN p_estado VARCHAR(20))
BEGIN
  SELECT o.id_orden, pr.nombre AS producto, o.cantidad, o.estado,
         o.fecha_creacion, o.fecha_cierre
    FROM orden_produccion o
    JOIN producto pr ON pr.id_producto = o.id_producto
   WHERE p_estado IS NULL OR o.estado = p_estado
   ORDER BY o.fecha_creacion DESC, o.id_orden DESC;
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- 6. VISTAS DE REPORTE (solo leen; no afectan nada de lo anterior)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vista_produccion_mensual AS
SELECT DATE_FORMAT(o.fecha_cierre, '%Y-%m') AS mes,
       pr.codigo, pr.nombre AS producto,
       COUNT(*)        AS ordenes_completadas,
       SUM(o.cantidad) AS unidades_producidas
  FROM orden_produccion o
  JOIN producto pr ON pr.id_producto = o.id_producto
 WHERE o.estado = 'COMPLETADA'
 GROUP BY DATE_FORMAT(o.fecha_cierre, '%Y-%m'), pr.codigo, pr.nombre;

CREATE OR REPLACE VIEW vista_compras_proveedor AS
SELECT p.nombre AS proveedor,
       mp.codigo, mp.nombre AS materia_prima,
       COUNT(*)                          AS num_compras,
       SUM(m.cantidad)                   AS cantidad_comprada,
       SUM(m.cantidad * m.costo_unitario) AS gasto_total
  FROM movimiento_inventario m
  JOIN proveedor p     ON p.id_proveedor = m.id_proveedor
  JOIN materia_prima mp ON mp.id_materia_prima = m.id_materia_prima
 WHERE m.tipo = 'ENTRADA'
 GROUP BY p.nombre, mp.codigo, mp.nombre;

-- ---------------------------------------------------------------------
-- 7. BITÁCORA DE MIGRACIONES: deja constancia de qué scripts ya se corrieron
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS migracion_log (
  nombre VARCHAR(60) PRIMARY KEY,
  fecha  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT IGNORE INTO migracion_log (nombre) VALUES ('mejoras_estructura');

-- Se borran los ayudantes temporales
DROP PROCEDURE IF EXISTS sp_mig_indice;
DROP PROCEDURE IF EXISTS sp_mig_check;
DROP PROCEDURE IF EXISTS sp_mig_columna;

-- ---------------------------------------------------------------------
-- 8. VERIFICACIÓN RÁPIDA (debe mostrar los índices nuevos y 0 compras sin costo)
-- ---------------------------------------------------------------------
-- SHOW INDEX FROM orden_produccion;
-- SELECT COUNT(*) AS compras_sin_costo FROM movimiento_inventario WHERE tipo='ENTRADA' AND costo_unitario IS NULL;
-- SELECT * FROM vista_compras_proveedor ORDER BY gasto_total DESC;
