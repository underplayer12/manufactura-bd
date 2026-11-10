-- =====================================================================
-- 06. BASE PARA LA APLICACIÓN WEB v2
--     Acceso por usuario y rol, bitácora de solicitudes, y todos los
--     procedimientos que necesitan los módulos de la página.
--
-- Orden de carga: después de 05_mejoras_diseno.sql y ANTES de 90_endurecimiento.
-- REGLA: solo AGREGA. No borra tablas ni datos. Las columnas nuevas llevan
-- valor por defecto, así que todo lo que ya existía sigue igual. Se puede
-- ejecutar más de una vez.
--
-- IDEA CENTRAL: la página (Python) NUNCA escribe SQL suelto; solo llama
-- procedimientos ("CALL sp_..."). Por eso al final se crea un usuario de la
-- base (app_manufactura) que SOLO puede ejecutar procedimientos, no leer ni
-- borrar tablas directamente. Así, aunque alguien encontrara un error en la
-- página, no tendría acceso total a la base como pasaba con "root".
-- =====================================================================

SET NAMES utf8mb4;
USE manufactura;

DELIMITER $$

-- Ayudantes temporales (se borran al final) ------------------------------
DROP PROCEDURE IF EXISTS sp_mig_requisito$$
CREATE PROCEDURE sp_mig_requisito()
BEGIN
  IF NOT EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'mejoras_diseno') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Primero ejecuta 05_mejoras_diseno.sql';
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_mig_columna$$
CREATE PROCEDURE sp_mig_columna(IN p_tabla VARCHAR(64), IN p_columna VARCHAR(64), IN p_definicion VARCHAR(300))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = DATABASE() AND table_name = p_tabla AND column_name = p_columna) THEN
    SET @sql = CONCAT('ALTER TABLE ', p_tabla, ' ADD COLUMN ', p_columna, ' ', p_definicion);
    PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;
  END IF;
END$$

DELIMITER ;

CALL sp_mig_requisito();

-- =====================================================================
-- PARTE 1. TABLAS NUEVAS
-- =====================================================================

-- Quién puede entrar a la página y con qué rol.
--   ADMIN     = todo (catálogos, usuarios, historial)
--   OPERARIO  = opera el día a día (órdenes, compras, traslados, ventas, clientes)
--   CONSULTA  = solo mira
-- La clave NUNCA se guarda: solo su "hash" (una huella que no se puede revertir).
CREATE TABLE IF NOT EXISTS usuario (
  id_usuario          INT AUTO_INCREMENT PRIMARY KEY,
  usuario             VARCHAR(30)  NOT NULL UNIQUE,
  nombre              VARCHAR(100) NOT NULL,
  rol                 ENUM('ADMIN','OPERARIO','CONSULTA') NOT NULL DEFAULT 'CONSULTA',
  clave_hash          VARCHAR(255) NOT NULL,
  activo              BOOLEAN  NOT NULL DEFAULT TRUE,
  debe_cambiar_clave  BOOLEAN  NOT NULL DEFAULT TRUE,
  creado              DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ultimo_acceso       DATETIME NULL,
  CONSTRAINT ck_usuario_formato CHECK (CHAR_LENGTH(usuario) >= 3)
) ENGINE=InnoDB;

-- Registro de cada solicitud que hace la gente desde la página:
-- quién, cuándo, qué pidió (con sus datos), y si salió bien o falló.
CREATE TABLE IF NOT EXISTS bitacora (
  id_bitacora  BIGINT AUTO_INCREMENT PRIMARY KEY,
  fecha        DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  id_usuario   INT NULL,                 -- NULL si alguien intentó entrar con un usuario que no existe
  usuario      VARCHAR(30) NOT NULL,
  rol          VARCHAR(20) NULL,
  accion       VARCHAR(40) NOT NULL,     -- CREAR, EDITAR, COMPLETAR, LOGIN...
  modulo       VARCHAR(40) NOT NULL,     -- Órdenes, Inventario, Clientes...
  referencia   VARCHAR(60) NULL,         -- por ejemplo OP-12
  detalle      VARCHAR(500) NULL,        -- frase legible, o el motivo del error
  resultado    ENUM('OK','ERROR') NOT NULL,
  http_metodo  VARCHAR(8) NULL,
  ruta         VARCHAR(200) NULL,
  http_estado  SMALLINT NULL,
  parametros   JSON NULL,                -- los datos enviados (sin claves)
  ip           VARCHAR(45) NULL,
  CONSTRAINT fk_bit_usuario FOREIGN KEY (id_usuario)
    REFERENCES usuario(id_usuario) ON DELETE RESTRICT ON UPDATE CASCADE,
  INDEX idx_bit_fecha (fecha),
  INDEX idx_bit_usuario_fecha (usuario, fecha),
  INDEX idx_bit_modulo_fecha (modulo, fecha),
  INDEX idx_bit_resultado_fecha (resultado, fecha)
) ENGINE=InnoDB;

-- Productos y materias primas ya no se borran: se DESACTIVAN (conservan su historial)
CALL sp_mig_columna('producto',      'activo', 'BOOLEAN NOT NULL DEFAULT TRUE');
CALL sp_mig_columna('materia_prima', 'activo', 'BOOLEAN NOT NULL DEFAULT TRUE');

-- =====================================================================
-- PARTE 2. PROCEDIMIENTOS
-- =====================================================================
DELIMITER $$

-- ---------- 2.1 Usuarios ----------
DROP PROCEDURE IF EXISTS sp_usuario_contar$$
CREATE PROCEDURE sp_usuario_contar()
BEGIN
  SELECT COUNT(*) AS total FROM usuario;
END$$

DROP PROCEDURE IF EXISTS sp_usuario_login$$
CREATE PROCEDURE sp_usuario_login(IN p_usuario VARCHAR(30))
BEGIN
  SELECT id_usuario, usuario, nombre, rol, clave_hash, activo, debe_cambiar_clave
    FROM usuario WHERE usuario = p_usuario;
END$$

DROP PROCEDURE IF EXISTS sp_usuario_obtener$$
CREATE PROCEDURE sp_usuario_obtener(IN p_id INT)
BEGIN
  SELECT id_usuario, usuario, nombre, rol, activo, debe_cambiar_clave
    FROM usuario WHERE id_usuario = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_usuario_registrar_acceso$$
CREATE PROCEDURE sp_usuario_registrar_acceso(IN p_id INT)
BEGIN
  UPDATE usuario SET ultimo_acceso = NOW() WHERE id_usuario = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_usuario_listar$$
CREATE PROCEDURE sp_usuario_listar()
BEGIN
  SELECT id_usuario, usuario, nombre, rol, activo, debe_cambiar_clave, creado, ultimo_acceso
    FROM usuario ORDER BY activo DESC, rol, usuario;
END$$

DROP PROCEDURE IF EXISTS sp_usuario_crear$$
CREATE PROCEDURE sp_usuario_crear(IN p_usuario VARCHAR(30), IN p_nombre VARCHAR(100),
                                  IN p_rol VARCHAR(20), IN p_hash VARCHAR(255))
BEGIN
  IF p_usuario IS NULL OR p_usuario NOT REGEXP '^[a-z0-9._-]{3,30}$' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'El usuario debe tener de 3 a 30 caracteres: letras minusculas, numeros, punto, guion o guion bajo';
  END IF;
  IF p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre es obligatorio';
  END IF;
  IF p_rol NOT IN ('ADMIN', 'OPERARIO', 'CONSULTA') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El rol debe ser ADMIN, OPERARIO o CONSULTA';
  END IF;
  INSERT INTO usuario (usuario, nombre, rol, clave_hash, debe_cambiar_clave)
  VALUES (p_usuario, TRIM(p_nombre), p_rol, p_hash, TRUE);
  SELECT LAST_INSERT_ID() AS id_usuario_creado;
END$$

-- Nunca puede quedar el sistema sin un administrador activo
DROP PROCEDURE IF EXISTS sp_usuario_actualizar$$
CREATE PROCEDURE sp_usuario_actualizar(IN p_id INT, IN p_nombre VARCHAR(100),
                                       IN p_rol VARCHAR(20), IN p_activo BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario no existe';
  END IF;
  IF p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre es obligatorio';
  END IF;
  IF p_rol NOT IN ('ADMIN', 'OPERARIO', 'CONSULTA') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El rol debe ser ADMIN, OPERARIO o CONSULTA';
  END IF;
  IF NOT (p_rol = 'ADMIN' AND p_activo)
     AND NOT EXISTS (SELECT 1 FROM usuario WHERE rol = 'ADMIN' AND activo AND id_usuario <> p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Debe quedar al menos un administrador activo';
  END IF;
  UPDATE usuario SET nombre = TRIM(p_nombre), rol = p_rol, activo = p_activo WHERE id_usuario = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_usuario_cambiar_clave$$
CREATE PROCEDURE sp_usuario_cambiar_clave(IN p_id INT, IN p_hash VARCHAR(255), IN p_debe_cambiar BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario no existe';
  END IF;
  UPDATE usuario SET clave_hash = p_hash, debe_cambiar_clave = p_debe_cambiar WHERE id_usuario = p_id;
END$$

-- ---------- 2.2 Bitácora ----------
DROP PROCEDURE IF EXISTS sp_bitacora_registrar$$
CREATE PROCEDURE sp_bitacora_registrar(
  IN p_id_usuario INT, IN p_usuario VARCHAR(30), IN p_rol VARCHAR(20),
  IN p_accion VARCHAR(40), IN p_modulo VARCHAR(40), IN p_referencia VARCHAR(60),
  IN p_detalle VARCHAR(500), IN p_resultado VARCHAR(5), IN p_http_metodo VARCHAR(8),
  IN p_ruta VARCHAR(200), IN p_http_estado SMALLINT, IN p_parametros JSON, IN p_ip VARCHAR(45))
BEGIN
  INSERT INTO bitacora (id_usuario, usuario, rol, accion, modulo, referencia, detalle, resultado,
                        http_metodo, ruta, http_estado, parametros, ip)
  VALUES (p_id_usuario, p_usuario, p_rol, p_accion, p_modulo, p_referencia, p_detalle, p_resultado,
          p_http_metodo, p_ruta, p_http_estado, p_parametros, p_ip);
END$$

-- Lista paginada con filtros; la columna "total" trae cuántas filas hay en total
DROP PROCEDURE IF EXISTS sp_bitacora_listar$$
CREATE PROCEDURE sp_bitacora_listar(
  IN p_usuario VARCHAR(30), IN p_modulo VARCHAR(40), IN p_resultado VARCHAR(5),
  IN p_desde DATE, IN p_hasta DATE, IN p_limite INT, IN p_desplazamiento INT)
BEGIN
  SELECT b.id_bitacora, b.fecha, b.usuario, b.rol, b.accion, b.modulo, b.referencia, b.detalle,
         b.resultado, b.http_metodo, b.ruta, b.http_estado, b.parametros, b.ip,
         COUNT(*) OVER () AS total
    FROM bitacora b
   WHERE (p_usuario   IS NULL OR b.usuario   = p_usuario)
     AND (p_modulo    IS NULL OR b.modulo    = p_modulo)
     AND (p_resultado IS NULL OR b.resultado = p_resultado)
     AND (p_desde     IS NULL OR b.fecha >= p_desde)
     AND (p_hasta     IS NULL OR b.fecha <  DATE_ADD(p_hasta, INTERVAL 1 DAY))
   ORDER BY b.fecha DESC, b.id_bitacora DESC
   LIMIT p_limite OFFSET p_desplazamiento;
END$$

-- ---------- 2.3 Órdenes de producción (antes las creaba la propia página al arrancar) ----------
DROP PROCEDURE IF EXISTS sp_orden_crear$$
CREATE PROCEDURE sp_orden_crear(IN p_id_producto INT, IN p_cantidad INT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM producto WHERE id_producto = p_id_producto AND activo) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe o esta inactivo';
  END IF;
  CALL sp_crear_orden(p_id_producto, p_cantidad);
END$$

DROP PROCEDURE IF EXISTS sp_actualizar_orden$$
CREATE PROCEDURE sp_actualizar_orden(IN p_id_orden INT, IN p_cantidad INT)
BEGIN
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad debe ser mayor que cero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM orden_produccion
                  WHERE id_orden = p_id_orden AND estado = 'PENDIENTE') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Solo se puede editar una orden que exista y este pendiente';
  END IF;
  UPDATE orden_produccion SET cantidad = p_cantidad WHERE id_orden = p_id_orden;
END$$

DROP PROCEDURE IF EXISTS sp_eliminar_orden$$
CREATE PROCEDURE sp_eliminar_orden(IN p_id_orden INT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM orden_produccion
                  WHERE id_orden = p_id_orden AND estado IN ('PENDIENTE', 'CANCELADA')) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Solo se pueden eliminar ordenes pendientes o canceladas';
  END IF;
  DELETE FROM orden_produccion WHERE id_orden = p_id_orden;
END$$

-- ---------- 2.4 Productos y recetas ----------
DROP PROCEDURE IF EXISTS sp_producto_listar$$
CREATE PROCEDURE sp_producto_listar(IN p_incluir_inactivos BOOLEAN)
BEGIN
  SELECT pr.id_producto, pr.codigo, pr.nombre, pr.precio_venta, pr.stock_actual,
         fn_max_producible(pr.id_producto) AS max_producible, pr.activo,
         (SELECT COUNT(*) FROM receta r WHERE r.id_producto = pr.id_producto) AS lineas_receta
    FROM producto pr
   WHERE p_incluir_inactivos OR pr.activo
   ORDER BY pr.activo DESC, pr.nombre;
END$$

DROP PROCEDURE IF EXISTS sp_producto_crear$$
CREATE PROCEDURE sp_producto_crear(IN p_codigo VARCHAR(20), IN p_nombre VARCHAR(100), IN p_precio DECIMAL(12,2))
BEGIN
  IF p_codigo IS NULL OR CHAR_LENGTH(TRIM(p_codigo)) = 0 OR p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El codigo y el nombre son obligatorios';
  END IF;
  IF p_precio IS NULL OR p_precio <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio de venta debe ser mayor que cero';
  END IF;
  INSERT INTO producto (codigo, nombre, precio_venta) VALUES (TRIM(p_codigo), TRIM(p_nombre), p_precio);
  SELECT LAST_INSERT_ID() AS id_producto_creado;
END$$

DROP PROCEDURE IF EXISTS sp_producto_actualizar$$
CREATE PROCEDURE sp_producto_actualizar(IN p_id INT, IN p_nombre VARCHAR(100), IN p_precio DECIMAL(12,2))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM producto WHERE id_producto = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  END IF;
  IF p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre es obligatorio';
  END IF;
  IF p_precio IS NULL OR p_precio <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio de venta debe ser mayor que cero';
  END IF;
  UPDATE producto SET nombre = TRIM(p_nombre), precio_venta = p_precio WHERE id_producto = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_producto_estado$$
CREATE PROCEDURE sp_producto_estado(IN p_id INT, IN p_activo BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM producto WHERE id_producto = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  END IF;
  IF NOT p_activo AND EXISTS (SELECT 1 FROM orden_produccion WHERE id_producto = p_id AND estado = 'PENDIENTE') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'No se puede desactivar: tiene ordenes de produccion pendientes';
  END IF;
  UPDATE producto SET activo = p_activo WHERE id_producto = p_id;
END$$

-- Receta con los ids que necesita la página para editarla
DROP PROCEDURE IF EXISTS sp_receta_listar$$
CREATE PROCEDURE sp_receta_listar(IN p_id_producto INT)
BEGIN
  SELECT mp.id_materia_prima, mp.codigo, mp.nombre AS materia_prima, mp.unidad_medida,
         r.cantidad_por_unidad, mp.stock_actual
    FROM receta r JOIN materia_prima mp ON mp.id_materia_prima = r.id_materia_prima
   WHERE r.id_producto = p_id_producto
   ORDER BY mp.codigo;
END$$

DROP PROCEDURE IF EXISTS sp_receta_guardar$$
CREATE PROCEDURE sp_receta_guardar(IN p_id_producto INT, IN p_id_materia INT, IN p_cantidad DECIMAL(12,4))
BEGIN
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad por unidad debe ser mayor que cero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM producto WHERE id_producto = p_id_producto) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM materia_prima WHERE id_materia_prima = p_id_materia AND activo) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La materia prima no existe o esta inactiva';
  END IF;
  INSERT INTO receta (id_producto, id_materia_prima, cantidad_por_unidad)
  VALUES (p_id_producto, p_id_materia, p_cantidad)
  ON DUPLICATE KEY UPDATE cantidad_por_unidad = p_cantidad;
END$$

DROP PROCEDURE IF EXISTS sp_receta_quitar$$
CREATE PROCEDURE sp_receta_quitar(IN p_id_producto INT, IN p_id_materia INT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM receta WHERE id_producto = p_id_producto AND id_materia_prima = p_id_materia) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Esa materia prima no esta en la receta';
  END IF;
  DELETE FROM receta WHERE id_producto = p_id_producto AND id_materia_prima = p_id_materia;
END$$

-- ---------- 2.5 Materias primas e inventario ----------
DROP PROCEDURE IF EXISTS sp_materia_listar$$
CREATE PROCEDURE sp_materia_listar(IN p_incluir_inactivas BOOLEAN)
BEGIN
  SELECT mp.id_materia_prima, mp.codigo, mp.nombre, mp.unidad_medida, mp.stock_actual, mp.stock_minimo,
         CASE WHEN mp.stock_actual <= mp.stock_minimo THEN 'REABASTECER' ELSE 'OK' END AS estado,
         mp.id_bodega_predeterminada, b.nombre AS bodega, mp.activo,
         (SELECT COUNT(*) FROM lote l WHERE l.id_materia_prima = mp.id_materia_prima AND l.abierto = 1) AS lotes_abiertos,
         (SELECT COUNT(*) FROM proveedor_materia_prima x WHERE x.id_materia_prima = mp.id_materia_prima) AS proveedores
    FROM materia_prima mp
    LEFT JOIN bodega b ON b.id_bodega = mp.id_bodega_predeterminada
   WHERE p_incluir_inactivas OR mp.activo
   ORDER BY mp.activo DESC, mp.codigo;
END$$

DROP PROCEDURE IF EXISTS sp_materia_crear$$
CREATE PROCEDURE sp_materia_crear(IN p_codigo VARCHAR(20), IN p_nombre VARCHAR(100), IN p_unidad VARCHAR(10),
                                  IN p_minimo DECIMAL(12,3), IN p_id_bodega INT)
BEGIN
  IF p_codigo IS NULL OR CHAR_LENGTH(TRIM(p_codigo)) = 0 OR p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0
     OR p_unidad IS NULL OR CHAR_LENGTH(TRIM(p_unidad)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El codigo, el nombre y la unidad de medida son obligatorios';
  END IF;
  IF p_minimo IS NULL OR p_minimo < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock minimo no puede ser negativo';
  END IF;
  IF p_id_bodega IS NOT NULL AND NOT EXISTS (SELECT 1 FROM bodega WHERE id_bodega = p_id_bodega AND activa) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bodega no existe o esta inactiva';
  END IF;
  INSERT INTO materia_prima (codigo, nombre, unidad_medida, stock_minimo, id_bodega_predeterminada)
  VALUES (TRIM(p_codigo), TRIM(p_nombre), UPPER(TRIM(p_unidad)), p_minimo, p_id_bodega);
  SELECT LAST_INSERT_ID() AS id_materia_creada;
END$$

-- La unidad de medida solo se puede cambiar mientras la materia no tenga movimientos
DROP PROCEDURE IF EXISTS sp_materia_actualizar$$
CREATE PROCEDURE sp_materia_actualizar(IN p_id INT, IN p_nombre VARCHAR(100), IN p_unidad VARCHAR(10),
                                       IN p_minimo DECIMAL(12,3), IN p_id_bodega INT)
BEGIN
  DECLARE v_unidad VARCHAR(10);
  SET v_unidad = (SELECT unidad_medida FROM materia_prima WHERE id_materia_prima = p_id);
  IF v_unidad IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La materia prima no existe';
  END IF;
  IF p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 OR p_unidad IS NULL OR CHAR_LENGTH(TRIM(p_unidad)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre y la unidad de medida son obligatorios';
  END IF;
  IF p_minimo IS NULL OR p_minimo < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock minimo no puede ser negativo';
  END IF;
  IF p_id_bodega IS NOT NULL AND NOT EXISTS (SELECT 1 FROM bodega WHERE id_bodega = p_id_bodega AND activa) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bodega no existe o esta inactiva';
  END IF;
  IF UPPER(TRIM(p_unidad)) <> v_unidad
     AND EXISTS (SELECT 1 FROM movimiento_inventario WHERE id_materia_prima = p_id) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'No se puede cambiar la unidad de medida: la materia prima ya tiene movimientos';
  END IF;
  UPDATE materia_prima
     SET nombre = TRIM(p_nombre), unidad_medida = UPPER(TRIM(p_unidad)),
         stock_minimo = p_minimo, id_bodega_predeterminada = p_id_bodega
   WHERE id_materia_prima = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_materia_estado$$
CREATE PROCEDURE sp_materia_estado(IN p_id INT, IN p_activo BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM materia_prima WHERE id_materia_prima = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La materia prima no existe';
  END IF;
  IF NOT p_activo AND (SELECT stock_actual FROM materia_prima WHERE id_materia_prima = p_id) > 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'No se puede desactivar una materia prima que todavia tiene existencias';
  END IF;
  UPDATE materia_prima SET activo = p_activo WHERE id_materia_prima = p_id;
END$$

-- Dónde está guardada una materia prima (por bodega)
DROP PROCEDURE IF EXISTS sp_materia_bodegas$$
CREATE PROCEDURE sp_materia_bodegas(IN p_id INT)
BEGIN
  SELECT b.id_bodega, b.codigo AS bodega_codigo, b.nombre AS bodega, sb.cantidad
    FROM stock_bodega sb JOIN bodega b ON b.id_bodega = sb.id_bodega
   WHERE sb.id_materia_prima = p_id AND sb.cantidad > 0
   ORDER BY b.codigo;
END$$

-- Compra con lote y bodega (mismo procedimiento de 05, ahora rechaza materias inactivas)
DROP PROCEDURE IF EXISTS sp_registrar_compra_lote$$
CREATE PROCEDURE sp_registrar_compra_lote(
  IN p_id_materia INT, IN p_id_proveedor INT, IN p_cantidad DECIMAL(12,3),
  IN p_id_bodega INT, IN p_lote_proveedor VARCHAR(40), IN p_vencimiento DATE, IN p_observacion VARCHAR(200))
BEGIN
  DECLARE v_mov  INT;
  DECLARE v_lote INT;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad debe ser mayor que cero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM materia_prima WHERE id_materia_prima = p_id_materia AND activo) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La materia prima no existe o esta inactiva';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM proveedor_materia_prima pmp JOIN proveedor p ON p.id_proveedor = pmp.id_proveedor
                  WHERE pmp.id_proveedor = p_id_proveedor AND pmp.id_materia_prima = p_id_materia AND p.activo) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ese proveedor no vende esa materia prima o esta inactivo';
  END IF;
  IF p_id_bodega IS NOT NULL AND NOT EXISTS (SELECT 1 FROM bodega WHERE id_bodega = p_id_bodega AND activa) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bodega no existe o esta inactiva';
  END IF;

  INSERT INTO movimiento_inventario (id_materia_prima, tipo, cantidad, id_proveedor, id_bodega, observacion)
  VALUES (p_id_materia, 'ENTRADA', p_cantidad, p_id_proveedor, p_id_bodega, p_observacion);
  SET v_mov = LAST_INSERT_ID();

  SET v_lote = (SELECT id_lote FROM movimiento_inventario WHERE id_movimiento = v_mov);
  UPDATE lote SET lote_proveedor = p_lote_proveedor, fecha_vencimiento = p_vencimiento
   WHERE id_lote = v_lote;

  SELECT l.id_lote, l.codigo_lote, mp.codigo, mp.nombre, mp.stock_actual
    FROM lote l JOIN materia_prima mp ON mp.id_materia_prima = l.id_materia_prima
   WHERE l.id_lote = v_lote;
END$$

DROP PROCEDURE IF EXISTS sp_compras_listar$$
CREATE PROCEDURE sp_compras_listar(IN p_limite INT)
BEGIN
  SELECT m.id_movimiento, m.fecha, mp.codigo, mp.nombre AS materia, pv.nombre AS proveedor,
         m.cantidad, mp.unidad_medida, m.costo_unitario, m.cantidad * m.costo_unitario AS total,
         l.codigo_lote, b.codigo AS bodega, m.observacion
    FROM movimiento_inventario m
    JOIN materia_prima mp ON mp.id_materia_prima = m.id_materia_prima
    LEFT JOIN proveedor pv ON pv.id_proveedor = m.id_proveedor
    LEFT JOIN lote l ON l.id_lote = m.id_lote
    LEFT JOIN bodega b ON b.id_bodega = m.id_bodega
   WHERE m.tipo = 'ENTRADA'
   ORDER BY m.fecha DESC, m.id_movimiento DESC
   LIMIT p_limite;
END$$

-- ---------- 2.6 Bodegas ----------
DROP PROCEDURE IF EXISTS sp_bodega_listar$$
CREATE PROCEDURE sp_bodega_listar()
BEGIN
  SELECT b.id_bodega, b.codigo, b.nombre, b.ubicacion, b.activa,
         (SELECT COUNT(*) FROM stock_bodega sb WHERE sb.id_bodega = b.id_bodega AND sb.cantidad > 0) AS materias
    FROM bodega b ORDER BY b.activa DESC, b.codigo;
END$$

DROP PROCEDURE IF EXISTS sp_bodega_crear$$
CREATE PROCEDURE sp_bodega_crear(IN p_codigo VARCHAR(20), IN p_nombre VARCHAR(100), IN p_ubicacion VARCHAR(100))
BEGIN
  IF p_codigo IS NULL OR CHAR_LENGTH(TRIM(p_codigo)) = 0 OR p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El codigo y el nombre son obligatorios';
  END IF;
  INSERT INTO bodega (codigo, nombre, ubicacion) VALUES (UPPER(TRIM(p_codigo)), TRIM(p_nombre), p_ubicacion);
  SELECT LAST_INSERT_ID() AS id_bodega_creada;
END$$

DROP PROCEDURE IF EXISTS sp_bodega_actualizar$$
CREATE PROCEDURE sp_bodega_actualizar(IN p_id INT, IN p_nombre VARCHAR(100), IN p_ubicacion VARCHAR(100), IN p_activa BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM bodega WHERE id_bodega = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bodega no existe';
  END IF;
  IF p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre es obligatorio';
  END IF;
  IF NOT p_activa AND EXISTS (SELECT 1 FROM stock_bodega WHERE id_bodega = p_id AND cantidad > 0) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se puede desactivar una bodega que todavia tiene existencias';
  END IF;
  UPDATE bodega SET nombre = TRIM(p_nombre), ubicacion = p_ubicacion, activa = p_activa WHERE id_bodega = p_id;
END$$

-- ---------- 2.7 Proveedores y precios ----------
DROP PROCEDURE IF EXISTS sp_proveedor_listar$$
CREATE PROCEDURE sp_proveedor_listar(IN p_incluir_inactivos BOOLEAN)
BEGIN
  SELECT p.id_proveedor, p.nit, p.nombre, p.telefono, p.email, p.activo,
         (SELECT COUNT(*) FROM proveedor_materia_prima x WHERE x.id_proveedor = p.id_proveedor) AS materias
    FROM proveedor p
   WHERE p_incluir_inactivos OR p.activo
   ORDER BY p.activo DESC, p.nombre;
END$$

DROP PROCEDURE IF EXISTS sp_proveedor_actualizar$$
CREATE PROCEDURE sp_proveedor_actualizar(IN p_id INT, IN p_nombre VARCHAR(100), IN p_telefono VARCHAR(20), IN p_email VARCHAR(100))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM proveedor WHERE id_proveedor = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El proveedor no existe';
  END IF;
  IF p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre es obligatorio';
  END IF;
  UPDATE proveedor SET nombre = TRIM(p_nombre), telefono = p_telefono, email = p_email WHERE id_proveedor = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_proveedor_estado$$
CREATE PROCEDURE sp_proveedor_estado(IN p_id INT, IN p_activo BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM proveedor WHERE id_proveedor = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El proveedor no existe';
  END IF;
  UPDATE proveedor SET activo = p_activo WHERE id_proveedor = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_oferta_listar$$
CREATE PROCEDURE sp_oferta_listar(IN p_id_proveedor INT)
BEGIN
  SELECT mp.id_materia_prima, mp.codigo, mp.nombre AS materia_prima, mp.unidad_medida,
         pmp.pais_origen, pmp.precio_unitario, pmp.tiempo_entrega_dias
    FROM proveedor_materia_prima pmp JOIN materia_prima mp ON mp.id_materia_prima = pmp.id_materia_prima
   WHERE pmp.id_proveedor = p_id_proveedor
   ORDER BY mp.codigo;
END$$

-- Alta o cambio de lo que vende un proveedor. Si cambia el precio, un trigger (de 05)
-- guarda solo el historial de precios.
DROP PROCEDURE IF EXISTS sp_oferta_guardar$$
CREATE PROCEDURE sp_oferta_guardar(IN p_id_proveedor INT, IN p_id_materia INT, IN p_pais VARCHAR(60),
                                   IN p_precio DECIMAL(12,2), IN p_dias INT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM proveedor WHERE id_proveedor = p_id_proveedor) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El proveedor no existe';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM materia_prima WHERE id_materia_prima = p_id_materia AND activo) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La materia prima no existe o esta inactiva';
  END IF;
  IF p_pais IS NULL OR CHAR_LENGTH(TRIM(p_pais)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pais de origen es obligatorio';
  END IF;
  IF p_precio IS NULL OR p_precio <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio debe ser mayor que cero';
  END IF;
  IF p_dias IS NULL OR p_dias < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Los dias de entrega no pueden ser negativos';
  END IF;

  IF EXISTS (SELECT 1 FROM proveedor_materia_prima WHERE id_proveedor = p_id_proveedor AND id_materia_prima = p_id_materia) THEN
    UPDATE proveedor_materia_prima
       SET pais_origen = TRIM(p_pais), precio_unitario = p_precio, tiempo_entrega_dias = p_dias
     WHERE id_proveedor = p_id_proveedor AND id_materia_prima = p_id_materia;
  ELSE
    INSERT INTO proveedor_materia_prima (id_proveedor, id_materia_prima, pais_origen, precio_unitario, tiempo_entrega_dias)
    VALUES (p_id_proveedor, p_id_materia, TRIM(p_pais), p_precio, p_dias);
  END IF;
END$$

-- ---------- 2.8 Clientes ----------
DROP PROCEDURE IF EXISTS sp_cliente_listar$$
CREATE PROCEDURE sp_cliente_listar(IN p_incluir_inactivos BOOLEAN)
BEGIN
  SELECT c.id_cliente, c.nit, c.nombre, c.telefono, c.email, c.ciudad, c.activo,
         COUNT(DISTINCT p.id_pedido) AS pedidos,
         COALESCE(SUM(CASE WHEN p.estado = 'DESPACHADO' THEN d.cantidad * d.precio_unitario END), 0) AS total_comprado
    FROM cliente c
    LEFT JOIN pedido_venta p ON p.id_cliente = c.id_cliente
    LEFT JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
   WHERE p_incluir_inactivos OR c.activo
   GROUP BY c.id_cliente, c.nit, c.nombre, c.telefono, c.email, c.ciudad, c.activo
   ORDER BY c.activo DESC, c.nombre;
END$$

DROP PROCEDURE IF EXISTS sp_cliente_actualizar$$
CREATE PROCEDURE sp_cliente_actualizar(IN p_id INT, IN p_nombre VARCHAR(100), IN p_telefono VARCHAR(20),
                                       IN p_email VARCHAR(100), IN p_ciudad VARCHAR(60))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cliente WHERE id_cliente = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente no existe';
  END IF;
  IF p_nombre IS NULL OR CHAR_LENGTH(TRIM(p_nombre)) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nombre es obligatorio';
  END IF;
  UPDATE cliente SET nombre = TRIM(p_nombre), telefono = p_telefono, email = p_email, ciudad = p_ciudad
   WHERE id_cliente = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_cliente_estado$$
CREATE PROCEDURE sp_cliente_estado(IN p_id INT, IN p_activo BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cliente WHERE id_cliente = p_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente no existe';
  END IF;
  IF NOT p_activo AND EXISTS (SELECT 1 FROM pedido_venta WHERE id_cliente = p_id AND estado = 'ABIERTO') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se puede desactivar: el cliente tiene pedidos abiertos';
  END IF;
  UPDATE cliente SET activo = p_activo WHERE id_cliente = p_id;
END$$

DROP PROCEDURE IF EXISTS sp_pedidos_cliente$$
CREATE PROCEDURE sp_pedidos_cliente(IN p_id_cliente INT)
BEGIN
  SELECT p.id_pedido, p.fecha, p.estado, p.fecha_cierre,
         COUNT(d.id_producto) AS lineas, COALESCE(SUM(d.cantidad * d.precio_unitario), 0) AS total
    FROM pedido_venta p LEFT JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
   WHERE p.id_cliente = p_id_cliente
   GROUP BY p.id_pedido, p.fecha, p.estado, p.fecha_cierre
   ORDER BY p.fecha DESC, p.id_pedido DESC;
END$$

-- ---------- 2.9 Ventas ----------
-- Mismo procedimiento de 05, ahora rechaza productos inactivos
DROP PROCEDURE IF EXISTS sp_agregar_linea_pedido$$
CREATE PROCEDURE sp_agregar_linea_pedido(IN p_id_pedido INT, IN p_id_producto INT, IN p_cantidad INT)
BEGIN
  DECLARE v_precio DECIMAL(12,2);

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad debe ser mayor que cero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pedido_venta WHERE id_pedido = p_id_pedido AND estado = 'ABIERTO') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pedido no existe o ya no esta ABIERTO';
  END IF;
  SET v_precio = (SELECT precio_venta FROM producto WHERE id_producto = p_id_producto AND activo);
  IF v_precio IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe o esta inactivo';
  END IF;

  INSERT INTO pedido_venta_detalle (id_pedido, id_producto, cantidad, precio_unitario)
  VALUES (p_id_pedido, p_id_producto, p_cantidad, v_precio)
  ON DUPLICATE KEY UPDATE cantidad = cantidad + p_cantidad;

  CALL sp_get_pedido_detalle(p_id_pedido);
END$$

DROP PROCEDURE IF EXISTS sp_quitar_linea_pedido$$
CREATE PROCEDURE sp_quitar_linea_pedido(IN p_id_pedido INT, IN p_id_producto INT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pedido_venta WHERE id_pedido = p_id_pedido AND estado = 'ABIERTO') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pedido no existe o ya no esta ABIERTO';
  END IF;
  DELETE FROM pedido_venta_detalle WHERE id_pedido = p_id_pedido AND id_producto = p_id_producto;
  IF ROW_COUNT() = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ese producto no esta en el pedido';
  END IF;
END$$

-- Líneas de un pedido con lo que necesita la página (ids, stock disponible, cliente)
DROP PROCEDURE IF EXISTS sp_pedido_lineas$$
CREATE PROCEDURE sp_pedido_lineas(IN p_id_pedido INT)
BEGIN
  SELECT p.id_pedido, p.estado, c.nombre AS cliente, pr.id_producto, pr.codigo, pr.nombre AS producto,
         d.cantidad, d.precio_unitario, d.cantidad * d.precio_unitario AS subtotal,
         pr.stock_actual AS disponible
    FROM pedido_venta p
    JOIN cliente c ON c.id_cliente = p.id_cliente
    LEFT JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
    LEFT JOIN producto pr ON pr.id_producto = d.id_producto
   WHERE p.id_pedido = p_id_pedido
   ORDER BY pr.codigo;
END$$

-- ---------- 2.10 Inicio y reportes ----------
DROP PROCEDURE IF EXISTS sp_dashboard$$
CREATE PROCEDURE sp_dashboard()
BEGIN
  SELECT
    (SELECT COUNT(*) FROM orden_produccion WHERE estado = 'PENDIENTE')  AS ordenes_pendientes,
    (SELECT COUNT(*) FROM orden_produccion WHERE estado = 'COMPLETADA') AS ordenes_completadas,
    (SELECT COUNT(*) FROM materia_prima WHERE activo AND stock_actual <= stock_minimo) AS materias_reponer,
    (SELECT COUNT(*) FROM pedido_venta WHERE estado = 'ABIERTO') AS pedidos_abiertos,
    (SELECT COALESCE(SUM(d.cantidad * d.precio_unitario), 0)
       FROM pedido_venta p JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
      WHERE p.estado = 'DESPACHADO') AS ventas_total,
    (SELECT COUNT(*) FROM producto WHERE activo)   AS productos_activos,
    (SELECT COUNT(*) FROM cliente WHERE activo)    AS clientes_activos,
    (SELECT COUNT(*) FROM proveedor WHERE activo)  AS proveedores_activos;
END$$

-- Materias bajo el mínimo y el proveedor activo MÁS BARATO de cada una
DROP PROCEDURE IF EXISTS sp_reponer_sugerencias$$
CREATE PROCEDURE sp_reponer_sugerencias()
BEGIN
  SELECT x.id_materia_prima, x.codigo, x.nombre, x.unidad_medida, x.stock_actual, x.stock_minimo,
         x.id_proveedor, x.proveedor, x.precio_unitario, x.tiempo_entrega_dias, x.pais_origen
    FROM (
      SELECT mp.id_materia_prima, mp.codigo, mp.nombre, mp.unidad_medida, mp.stock_actual, mp.stock_minimo,
             o.id_proveedor, o.proveedor, o.precio_unitario, o.tiempo_entrega_dias, o.pais_origen,
             ROW_NUMBER() OVER (PARTITION BY mp.id_materia_prima ORDER BY o.precio_unitario) AS rn
        FROM materia_prima mp
        LEFT JOIN (SELECT pmp.id_materia_prima, pmp.id_proveedor, pv.nombre AS proveedor,
                          pmp.precio_unitario, pmp.tiempo_entrega_dias, pmp.pais_origen
                     FROM proveedor_materia_prima pmp
                     JOIN proveedor pv ON pv.id_proveedor = pmp.id_proveedor AND pv.activo) o
               ON o.id_materia_prima = mp.id_materia_prima
       WHERE mp.activo AND mp.stock_actual <= mp.stock_minimo
    ) x
   WHERE x.rn = 1
   ORDER BY x.stock_actual / NULLIF(x.stock_minimo, 0), x.nombre;
END$$

DROP PROCEDURE IF EXISTS sp_reporte_produccion$$
CREATE PROCEDURE sp_reporte_produccion()
BEGIN
  SELECT mes, producto, ordenes_completadas AS ordenes, unidades_producidas AS unidades
    FROM vista_produccion_mensual
   ORDER BY mes DESC, unidades_producidas DESC;
END$$

DROP PROCEDURE IF EXISTS sp_reporte_compras$$
CREATE PROCEDURE sp_reporte_compras()
BEGIN
  SELECT proveedor, codigo, materia_prima, num_compras AS compras, cantidad_comprada AS cantidad, gasto_total AS gasto
    FROM vista_compras_proveedor
   ORDER BY gasto_total DESC;
END$$

DROP PROCEDURE IF EXISTS sp_reporte_ventas$$
CREATE PROCEDURE sp_reporte_ventas()
BEGIN
  SELECT DATE_FORMAT(p.fecha_cierre, '%Y-%m') AS mes,
         COUNT(DISTINCT p.id_pedido) AS pedidos,
         SUM(d.cantidad) AS unidades,
         SUM(d.cantidad * d.precio_unitario) AS total_vendido
    FROM pedido_venta p JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
   WHERE p.estado = 'DESPACHADO'
   GROUP BY DATE_FORMAT(p.fecha_cierre, '%Y-%m')
   ORDER BY mes DESC;
END$$

DROP PROCEDURE IF EXISTS sp_reporte_clientes$$
CREATE PROCEDURE sp_reporte_clientes()
BEGIN
  SELECT c.nombre AS cliente, c.ciudad,
         COUNT(DISTINCT p.id_pedido) AS pedidos,
         SUM(d.cantidad) AS unidades,
         SUM(d.cantidad * d.precio_unitario) AS total_comprado
    FROM cliente c
    JOIN pedido_venta p ON p.id_cliente = c.id_cliente AND p.estado = 'DESPACHADO'
    JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
   GROUP BY c.id_cliente, c.nombre, c.ciudad
   ORDER BY total_comprado DESC;
END$$

-- Valor del inventario: lo que queda de cada lote x lo que costó ese lote
DROP PROCEDURE IF EXISTS sp_reporte_inventario$$
CREATE PROCEDURE sp_reporte_inventario()
BEGIN
  SELECT mp.codigo, mp.nombre AS materia_prima, mp.unidad_medida, mp.stock_actual,
         ROUND(SUM(l.cantidad_disponible * m.costo_unitario) / NULLIF(SUM(l.cantidad_disponible), 0), 2) AS costo_promedio,
         ROUND(COALESCE(SUM(l.cantidad_disponible * m.costo_unitario), 0), 2) AS valor_total
    FROM materia_prima mp
    LEFT JOIN lote l ON l.id_materia_prima = mp.id_materia_prima AND l.abierto = 1
    LEFT JOIN movimiento_inventario m ON m.id_lote = l.id_lote AND m.tipo = 'ENTRADA'
   WHERE mp.activo
   GROUP BY mp.id_materia_prima, mp.codigo, mp.nombre, mp.unidad_medida, mp.stock_actual
   ORDER BY valor_total DESC;
END$$

DELIMITER ;

-- =====================================================================
-- PARTE 3. USUARIO DE LA BASE DE MÍNIMO PRIVILEGIO PARA LA PÁGINA
--   Solo puede EJECUTAR procedimientos y funciones. No puede leer tablas,
--   ni borrar, ni crear, ni cambiar permisos. (Cambia esta clave si la
--   base va a estar en un servidor real.)
-- =====================================================================
CREATE USER IF NOT EXISTS 'app_manufactura'@'%' IDENTIFIED WITH mysql_native_password BY 'app_manufactura_2026';
GRANT EXECUTE ON manufactura.* TO 'app_manufactura'@'%';

-- =====================================================================
-- PARTE 4. CIERRE
-- =====================================================================
INSERT IGNORE INTO migracion_log (nombre) VALUES ('modulo_aplicacion');

DROP PROCEDURE IF EXISTS sp_mig_requisito;
DROP PROCEDURE IF EXISTS sp_mig_columna;

-- Verificación rápida:
-- SELECT routine_name FROM information_schema.routines WHERE routine_schema = 'manufactura' ORDER BY 1;
-- SHOW GRANTS FOR 'app_manufactura'@'%';
