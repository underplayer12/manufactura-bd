-- =====================================================================
-- FUNCIONES Y PROCEDIMIENTOS (GET / CREAR / ACTUALIZAR / DESACTIVAR)
-- Ejecutar DESPUÉS de manufactura_completa.sql
-- =====================================================================

SET NAMES utf8mb4;
USE manufactura;

DELIMITER $$

-- ---------------------------------------------------------------------
-- A. GET (lectura): solo consultan, no modifican nada
-- ---------------------------------------------------------------------

-- Inventario completo con su estado (OK / REABASTECER)
CREATE PROCEDURE sp_get_inventario()
BEGIN
  SELECT * FROM vista_inventario ORDER BY estado DESC, nombre;
END$$

-- Datos de UNA materia prima
CREATE PROCEDURE sp_get_materia(IN p_id_materia INT)
BEGIN
  SELECT * FROM materia_prima WHERE id_materia_prima = p_id_materia;
END$$

-- Qué proveedores venden una materia prima, de más barato a más caro
CREATE PROCEDURE sp_get_proveedores_materia(IN p_id_materia INT)
BEGIN
  SELECT p.id_proveedor, p.nombre AS proveedor, pmp.pais_origen,
         pmp.precio_unitario, pmp.tiempo_entrega_dias
    FROM proveedor_materia_prima pmp
    JOIN proveedor p ON p.id_proveedor = pmp.id_proveedor
   WHERE pmp.id_materia_prima = p_id_materia
     AND p.activo = TRUE
   ORDER BY pmp.precio_unitario;
END$$

-- Receta de un producto (qué materias consume una unidad)
CREATE PROCEDURE sp_get_receta(IN p_id_producto INT)
BEGIN
  SELECT mp.codigo, mp.nombre AS materia_prima, mp.unidad_medida,
         r.cantidad_por_unidad, mp.stock_actual
    FROM receta r
    JOIN materia_prima mp ON mp.id_materia_prima = r.id_materia_prima
   WHERE r.id_producto = p_id_producto
   ORDER BY mp.codigo;
END$$

-- Órdenes de producción. Si pasas NULL muestra todas;
-- si pasas 'PENDIENTE', 'COMPLETADA' o 'CANCELADA' filtra por estado.
CREATE PROCEDURE sp_get_ordenes(IN p_estado VARCHAR(20))
BEGIN
  SELECT o.id_orden, pr.nombre AS producto, o.cantidad, o.estado,
         o.fecha_creacion, o.fecha_cierre
    FROM orden_produccion o
    JOIN producto pr ON pr.id_producto = o.id_producto
   WHERE p_estado IS NULL OR o.estado = p_estado
   ORDER BY o.id_orden;
END$$

-- Kardex de una materia prima con saldo acumulado
CREATE PROCEDURE sp_get_kardex(IN p_id_materia INT)
BEGIN
  SELECT m.id_movimiento, m.fecha, m.tipo, m.cantidad,
         pv.nombre AS proveedor, m.id_orden, m.observacion,
         SUM(CASE WHEN m.tipo = 'ENTRADA' THEN m.cantidad ELSE -m.cantidad END)
           OVER (ORDER BY m.fecha, m.id_movimiento) AS saldo
    FROM movimiento_inventario m
    LEFT JOIN proveedor pv ON pv.id_proveedor = m.id_proveedor
   WHERE m.id_materia_prima = p_id_materia
   ORDER BY m.fecha, m.id_movimiento;
END$$

-- FUNCIÓN: cuántas unidades de un producto se pueden fabricar con el stock actual.
-- Divide el stock de cada materia entre lo que pide la receta y toma el menor.
CREATE FUNCTION fn_max_producible(p_id_producto INT)
RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_max INT;

  SELECT MIN(FLOOR(mp.stock_actual / r.cantidad_por_unidad))
    INTO v_max
    FROM receta r
    JOIN materia_prima mp ON mp.id_materia_prima = r.id_materia_prima
   WHERE r.id_producto = p_id_producto;

  RETURN COALESCE(v_max, 0);
END$$

-- ---------------------------------------------------------------------
-- B. CREAR (insertar con validaciones)
-- ---------------------------------------------------------------------

CREATE PROCEDURE sp_registrar_proveedor(
  IN p_nit VARCHAR(20), IN p_nombre VARCHAR(100),
  IN p_telefono VARCHAR(20), IN p_email VARCHAR(100))
BEGIN
  INSERT INTO proveedor (nit, nombre, telefono, email)
  VALUES (p_nit, p_nombre, p_telefono, p_email);

  SELECT LAST_INSERT_ID() AS id_proveedor_creado;
END$$

-- Registra una compra: valida que ese proveedor realmente venda esa materia.
-- El trigger sube el stock automáticamente.
CREATE PROCEDURE sp_registrar_compra(
  IN p_id_materia INT, IN p_id_proveedor INT,
  IN p_cantidad DECIMAL(12,3), IN p_observacion VARCHAR(200))
BEGIN
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad debe ser mayor que cero';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM proveedor_materia_prima
                  WHERE id_proveedor = p_id_proveedor
                    AND id_materia_prima = p_id_materia) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ese proveedor no vende esa materia prima';
  END IF;

  INSERT INTO movimiento_inventario
         (id_materia_prima, tipo, cantidad, id_proveedor, observacion)
  VALUES (p_id_materia, 'ENTRADA', p_cantidad, p_id_proveedor, p_observacion);

  SELECT codigo, nombre, stock_actual
    FROM materia_prima
   WHERE id_materia_prima = p_id_materia;
END$$

-- Crea una orden en estado PENDIENTE (se completa luego con sp_completar_orden)
CREATE PROCEDURE sp_crear_orden(IN p_id_producto INT, IN p_cantidad INT)
BEGIN
  INSERT INTO orden_produccion (id_producto, cantidad)
  VALUES (p_id_producto, p_cantidad);

  SELECT LAST_INSERT_ID() AS id_orden_creada,
         fn_max_producible(p_id_producto) AS maximo_producible_hoy;
END$$

-- ---------------------------------------------------------------------
-- C. ACTUALIZAR / DESACTIVAR
-- ---------------------------------------------------------------------

-- Cancela una orden, pero solo si sigue PENDIENTE
CREATE PROCEDURE sp_cancelar_orden(IN p_id_orden INT)
BEGIN
  UPDATE orden_produccion
     SET estado = 'CANCELADA', fecha_cierre = NOW()
   WHERE id_orden = p_id_orden AND estado = 'PENDIENTE';

  IF ROW_COUNT() = 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'La orden no existe o ya no esta PENDIENTE';
  END IF;
END$$

-- "Borrado lógico": el proveedor no se elimina (tiene historial), solo se desactiva
CREATE PROCEDURE sp_desactivar_proveedor(IN p_id_proveedor INT)
BEGIN
  UPDATE proveedor SET activo = FALSE WHERE id_proveedor = p_id_proveedor;

  IF ROW_COUNT() = 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'El proveedor no existe o ya estaba inactivo';
  END IF;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- D. PRUEBAS (ejecutar una a la vez)
-- ---------------------------------------------------------------------
-- CALL sp_get_inventario();
-- CALL sp_get_proveedores_materia(1);        -- proveedores de la lámina
-- CALL sp_get_receta(1);                     -- receta de la silla
-- CALL sp_get_ordenes('PENDIENTE');
-- CALL sp_get_kardex(3);                     -- kardex del MDF con saldo
-- SELECT fn_max_producible(1) AS sillas;     -- 55 (la tela es el límite)
-- SELECT fn_max_producible(2) AS escritorios;-- 16 (el MDF es el límite)
-- SELECT fn_max_producible(5) AS mesas;      -- 10
--
-- CALL sp_registrar_compra(3, 3, 60, 'Reposición MDF');   -- sube el MDF a 92
-- CALL sp_registrar_compra(3, 1, 60, 'Prueba');           -- FALLA: proveedor 1 no vende MDF
-- CALL sp_crear_orden(2, 5);                 -- crea una orden nueva
-- CALL sp_cancelar_orden(9);                 -- cancela la OP-9 pendiente
-- CALL sp_cancelar_orden(1);                 -- FALLA: ya está COMPLETADA
