-- =====================================================================
-- MEJORAS DE DISEÑO: bodegas, lotes, historial de precios, clientes y ventas
-- Orden de carga:
--   1) manufactura_completa.sql   2) funciones_crud.sql
--   3) mejoras_estructura.sql     4) datos_historicos.sql
--   5) mejoras_diseno.sql  (este archivo)
--   6) endurecimiento_opcional.sql (siempre al final, si lo vas a usar)
--
-- REGLA: solo AGREGA. No se borra ni se renombra nada. Las columnas nuevas
-- son opcionales (NULL) y los triggers nuevos las llenan solos, así que
-- sp_registrar_compra, sp_completar_orden y la interfaz siguen funcionando igual.
-- Se puede ejecutar más de una vez sin duplicar nada.
-- =====================================================================

SET NAMES utf8mb4;
USE manufactura;

DELIMITER $$

-- Ayudantes temporales: "haz el cambio SOLO si todavía no existe" ----------
DROP PROCEDURE IF EXISTS sp_mig_requisito$$
CREATE PROCEDURE sp_mig_requisito()
BEGIN
  IF NOT EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'mejoras_estructura') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Primero ejecuta mejoras_estructura.sql';
  END IF;
  IF EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'endurecimiento_kardex') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'El endurecimiento ya esta activo y bloquea los rellenos: ejecuta este archivo ANTES';
  END IF;
  -- @ya_migrado = 1 -> los rellenos históricos ya se hicieron, no se repiten
  SET @ya_migrado = EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'mejoras_diseno');
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

DROP PROCEDURE IF EXISTS sp_mig_fk$$
CREATE PROCEDURE sp_mig_fk(IN p_tabla VARCHAR(64), IN p_nombre VARCHAR(64), IN p_definicion VARCHAR(300))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints
                  WHERE table_schema = DATABASE() AND table_name = p_tabla
                    AND constraint_name = p_nombre AND constraint_type = 'FOREIGN KEY') THEN
    SET @sql = CONCAT('ALTER TABLE ', p_tabla, ' ADD CONSTRAINT ', p_nombre, ' FOREIGN KEY ', p_definicion);
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

DELIMITER ;

CALL sp_mig_requisito();

-- =====================================================================
-- PARTE 1. BODEGAS: dónde está físicamente cada materia prima
-- =====================================================================
CREATE TABLE IF NOT EXISTS bodega (
  id_bodega INT AUTO_INCREMENT PRIMARY KEY,
  codigo    VARCHAR(20)  NOT NULL UNIQUE,
  nombre    VARCHAR(100) NOT NULL,
  ubicacion VARCHAR(100),
  activa    BOOLEAN NOT NULL DEFAULT TRUE
) ENGINE=InnoDB;

INSERT IGNORE INTO bodega (codigo, nombre, ubicacion) VALUES
 ('BOD-01', 'Bodega general de insumos',               'Bloque A - primer piso'),
 ('BOD-02', 'Patio de metales (láminas y tubería)',    'Bloque B - patio cubierto'),
 ('BOD-03', 'Bodega de tapicería y empaques',          'Bloque A - segundo piso');

-- Cada materia prima tiene una bodega "de casa" (opcional; si falta se usa BOD-01)
CALL sp_mig_columna('materia_prima', 'id_bodega_predeterminada', 'INT NULL');
CALL sp_mig_fk('materia_prima', 'fk_mp_bodega', '(id_bodega_predeterminada) REFERENCES bodega(id_bodega) ON DELETE RESTRICT ON UPDATE CASCADE');

UPDATE materia_prima SET id_bodega_predeterminada = (SELECT id_bodega FROM bodega WHERE codigo = 'BOD-02')
 WHERE codigo IN ('MP-001', 'MP-002', 'MP-013') AND id_bodega_predeterminada IS NULL;
UPDATE materia_prima SET id_bodega_predeterminada = (SELECT id_bodega FROM bodega WHERE codigo = 'BOD-03')
 WHERE codigo IN ('MP-006', 'MP-007', 'MP-010', 'MP-016') AND id_bodega_predeterminada IS NULL;
UPDATE materia_prima SET id_bodega_predeterminada = (SELECT id_bodega FROM bodega WHERE codigo = 'BOD-01')
 WHERE id_bodega_predeterminada IS NULL;

-- Cuánto hay de cada materia en cada bodega (lo mantiene un trigger, ver parte 6)
CREATE TABLE IF NOT EXISTS stock_bodega (
  id_bodega        INT NOT NULL,
  id_materia_prima INT NOT NULL,
  cantidad         DECIMAL(12,3) NOT NULL DEFAULT 0,
  PRIMARY KEY (id_bodega, id_materia_prima),
  CONSTRAINT fk_sb_bodega FOREIGN KEY (id_bodega)
    REFERENCES bodega(id_bodega) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_sb_materia FOREIGN KEY (id_materia_prima)
    REFERENCES materia_prima(id_materia_prima) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_sb_cantidad CHECK (cantidad >= 0)
) ENGINE=InnoDB;

-- Historial de traslados entre bodegas (mover stock no cambia el total)
CREATE TABLE IF NOT EXISTS traslado_bodega (
  id_traslado      INT AUTO_INCREMENT PRIMARY KEY,
  id_materia_prima INT NOT NULL,
  id_origen        INT NOT NULL,
  id_destino       INT NOT NULL,
  cantidad         DECIMAL(12,3) NOT NULL,
  fecha            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_tr_materia  FOREIGN KEY (id_materia_prima) REFERENCES materia_prima(id_materia_prima),
  CONSTRAINT fk_tr_origen   FOREIGN KEY (id_origen)  REFERENCES bodega(id_bodega),
  CONSTRAINT fk_tr_destino  FOREIGN KEY (id_destino) REFERENCES bodega(id_bodega),
  CONSTRAINT ck_tr_cantidad CHECK (cantidad > 0),
  CONSTRAINT ck_tr_distintas CHECK (id_origen <> id_destino)
) ENGINE=InnoDB;

-- =====================================================================
-- PARTE 2. LOTES: de qué compra salió cada kilo, y a qué producto fue a parar
-- =====================================================================
-- Cada ENTRADA del kardex crea un lote. Cada SALIDA consume lotes en orden
-- FIFO (primero en entrar, primero en salir). Así se puede responder:
-- "este lote de tela defectuosa, ¿en qué órdenes de producción se usó?"
CREATE TABLE IF NOT EXISTS lote (
  id_lote             INT AUTO_INCREMENT PRIMARY KEY,
  codigo_lote         VARCHAR(30) NULL UNIQUE,
  id_materia_prima    INT NOT NULL,
  id_proveedor        INT NULL,
  lote_proveedor      VARCHAR(40) NULL,      -- número de lote que trae el empaque del proveedor
  fecha_ingreso       DATETIME NOT NULL,
  fecha_vencimiento   DATE NULL,
  cantidad_inicial    DECIMAL(12,3) NOT NULL,
  cantidad_disponible DECIMAL(12,3) NOT NULL,
  -- 1 mientras quede saldo; sirve para que el índice FIFO ignore los lotes agotados
  abierto TINYINT(1) GENERATED ALWAYS AS (cantidad_disponible > 0) STORED,
  CONSTRAINT fk_lote_materia FOREIGN KEY (id_materia_prima)
    REFERENCES materia_prima(id_materia_prima) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_lote_proveedor FOREIGN KEY (id_proveedor)
    REFERENCES proveedor(id_proveedor) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_lote_inicial    CHECK (cantidad_inicial > 0),
  CONSTRAINT ck_lote_disponible CHECK (cantidad_disponible >= 0 AND cantidad_disponible <= cantidad_inicial),
  INDEX idx_lote_fifo (id_materia_prima, abierto, fecha_ingreso, id_lote)
) ENGINE=InnoDB;

-- Qué parte de cada SALIDA salió de cuál lote (trazabilidad)
CREATE TABLE IF NOT EXISTS consumo_lote (
  id_movimiento INT NOT NULL,
  id_lote       INT NOT NULL,
  cantidad      DECIMAL(12,3) NOT NULL,
  PRIMARY KEY (id_movimiento, id_lote),
  CONSTRAINT fk_cl_movimiento FOREIGN KEY (id_movimiento)
    REFERENCES movimiento_inventario(id_movimiento) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_cl_lote FOREIGN KEY (id_lote)
    REFERENCES lote(id_lote) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_cl_cantidad CHECK (cantidad > 0),
  INDEX idx_cl_lote (id_lote)
) ENGINE=InnoDB;

-- El kardex apunta a su bodega y a su lote (ambos opcionales: los llena un trigger)
CALL sp_mig_columna('movimiento_inventario', 'id_bodega', 'INT NULL');
CALL sp_mig_columna('movimiento_inventario', 'id_lote',   'INT NULL');
CALL sp_mig_fk('movimiento_inventario', 'fk_mov_bodega', '(id_bodega) REFERENCES bodega(id_bodega) ON DELETE RESTRICT ON UPDATE CASCADE');
CALL sp_mig_fk('movimiento_inventario', 'fk_mov_lote',   '(id_lote) REFERENCES lote(id_lote) ON DELETE RESTRICT ON UPDATE CASCADE');

-- =====================================================================
-- PARTE 3. HISTORIAL DE PRECIOS DE PROVEEDOR
-- =====================================================================
-- proveedor_materia_prima guarda solo el precio de HOY. Esta tabla guarda cada
-- precio con las fechas en que estuvo vigente (hasta NULL = precio actual).
CREATE TABLE IF NOT EXISTS historial_precio (
  id_historial     INT AUTO_INCREMENT PRIMARY KEY,
  id_proveedor     INT NOT NULL,
  id_materia_prima INT NOT NULL,
  precio_unitario  DECIMAL(12,2) NOT NULL,
  vigente_desde    DATETIME NOT NULL,
  vigente_hasta    DATETIME NULL,
  CONSTRAINT fk_hp_oferta FOREIGN KEY (id_proveedor, id_materia_prima)
    REFERENCES proveedor_materia_prima(id_proveedor, id_materia_prima)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_hp_precio  CHECK (precio_unitario > 0),
  CONSTRAINT ck_hp_vigencia CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde),
  INDEX idx_hp_oferta (id_proveedor, id_materia_prima, vigente_desde)
) ENGINE=InnoDB;

-- =====================================================================
-- PARTE 4. CLIENTES Y VENTAS
-- =====================================================================
CREATE TABLE IF NOT EXISTS cliente (
  id_cliente INT AUTO_INCREMENT PRIMARY KEY,
  nit        VARCHAR(20)  NOT NULL UNIQUE,
  nombre     VARCHAR(100) NOT NULL,
  telefono   VARCHAR(20),
  email      VARCHAR(100),
  ciudad     VARCHAR(60),
  activo     BOOLEAN NOT NULL DEFAULT TRUE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS pedido_venta (
  id_pedido    INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente   INT NOT NULL,
  fecha        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  estado       ENUM('ABIERTO','DESPACHADO','CANCELADO') NOT NULL DEFAULT 'ABIERTO',
  fecha_cierre DATETIME NULL,
  observacion  VARCHAR(200),
  CONSTRAINT fk_pv_cliente FOREIGN KEY (id_cliente)
    REFERENCES cliente(id_cliente) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_pv_cierre CHECK (
    (estado = 'ABIERTO' AND fecha_cierre IS NULL)
    OR (estado <> 'ABIERTO' AND fecha_cierre IS NOT NULL AND fecha_cierre >= fecha)),
  INDEX idx_pv_estado_fecha (estado, fecha),
  INDEX idx_pv_cliente_fecha (id_cliente, fecha)
) ENGINE=InnoDB;

-- Líneas del pedido: el precio se congela al momento de agregar el producto
CREATE TABLE IF NOT EXISTS pedido_venta_detalle (
  id_pedido       INT NOT NULL,
  id_producto     INT NOT NULL,
  cantidad        INT NOT NULL,
  precio_unitario DECIMAL(12,2) NOT NULL,
  PRIMARY KEY (id_pedido, id_producto),
  CONSTRAINT fk_pvd_pedido FOREIGN KEY (id_pedido)
    REFERENCES pedido_venta(id_pedido) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_pvd_producto FOREIGN KEY (id_producto)
    REFERENCES producto(id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_pvd_cantidad CHECK (cantidad > 0),
  CONSTRAINT ck_pvd_precio   CHECK (precio_unitario > 0)
) ENGINE=InnoDB;

-- El despacho (creado en mejoras_estructura) ahora sabe a qué cliente y pedido pertenece
CALL sp_mig_columna('despacho', 'id_cliente', 'INT NULL');
CALL sp_mig_columna('despacho', 'id_pedido',  'INT NULL');
CALL sp_mig_fk('despacho', 'fk_desp_cliente', '(id_cliente) REFERENCES cliente(id_cliente) ON DELETE RESTRICT ON UPDATE CASCADE');
CALL sp_mig_fk('despacho', 'fk_desp_pedido',  '(id_pedido) REFERENCES pedido_venta(id_pedido) ON DELETE RESTRICT ON UPDATE CASCADE');

-- =====================================================================
-- PARTE 5. PROCEDIMIENTO DE CONSUMO FIFO (lo usan el trigger y el relleno)
-- =====================================================================
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_consumir_lotes$$
CREATE PROCEDURE sp_consumir_lotes(IN p_id_movimiento INT, IN p_id_materia INT, IN p_cantidad DECIMAL(12,3))
BEGIN
  DECLARE v_resto DECIMAL(12,3);
  DECLARE v_lote  INT;
  DECLARE v_disp  DECIMAL(12,3);
  DECLARE v_toma  DECIMAL(12,3);

  SET v_resto = p_cantidad;

  WHILE v_resto > 0 DO
    -- El lote abierto más antiguo de esa materia (FIFO)
    SET v_lote = (SELECT id_lote FROM lote
                   WHERE id_materia_prima = p_id_materia AND abierto = 1
                   ORDER BY fecha_ingreso, id_lote LIMIT 1);

    IF v_lote IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No hay lotes con saldo suficiente para esta salida';
    END IF;

    SET v_disp = (SELECT cantidad_disponible FROM lote WHERE id_lote = v_lote);
    SET v_toma = LEAST(v_disp, v_resto);

    UPDATE lote SET cantidad_disponible = cantidad_disponible - v_toma WHERE id_lote = v_lote;
    INSERT INTO consumo_lote (id_movimiento, id_lote, cantidad) VALUES (p_id_movimiento, v_lote, v_toma);

    SET v_resto = v_resto - v_toma;
  END WHILE;
END$$

-- Relleno ÚNICO del pasado: reconstruye lotes, consumos y stock por bodega a partir del kardex
-- (en orden de fecha). Solo corre si esta migración no se había aplicado antes.
DROP PROCEDURE IF EXISTS sp_mig_rellenar_pasado$$
CREATE PROCEDURE sp_mig_rellenar_pasado()
BEGIN
  DECLARE hecho   INT DEFAULT 0;
  DECLARE v_id    INT;
  DECLARE v_mp    INT;
  DECLARE v_tipo  VARCHAR(10);
  DECLARE v_cant  DECIMAL(12,3);
  DECLARE v_fecha DATETIME;
  DECLARE v_prov  INT;
  DECLARE v_lote  INT;
  DECLARE c CURSOR FOR
    SELECT id_movimiento, id_materia_prima, tipo, cantidad, fecha, id_proveedor
      FROM movimiento_inventario ORDER BY fecha, id_movimiento;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET hecho = 1;

  IF @ya_migrado = 0 THEN
    -- Limpieza por si una ejecución anterior se cortó a la mitad
    DELETE FROM consumo_lote;
    DELETE FROM stock_bodega;
    UPDATE movimiento_inventario SET id_lote = NULL;
    DELETE FROM lote;

    -- 1) Cada movimiento antiguo pertenece a la bodega "de casa" de su materia
    UPDATE movimiento_inventario m
      JOIN materia_prima mp ON mp.id_materia_prima = m.id_materia_prima
       SET m.id_bodega = mp.id_bodega_predeterminada
     WHERE m.id_bodega IS NULL;

    -- 2) Se repasa el kardex en orden: ENTRADA crea lote, SALIDA consume FIFO
    OPEN c;
    repaso: LOOP
      FETCH c INTO v_id, v_mp, v_tipo, v_cant, v_fecha, v_prov;
      IF hecho = 1 THEN LEAVE repaso; END IF;

      IF v_tipo = 'ENTRADA' THEN
        INSERT INTO lote (id_materia_prima, id_proveedor, fecha_ingreso, cantidad_inicial, cantidad_disponible)
        VALUES (v_mp, v_prov, v_fecha, v_cant, v_cant);
        SET v_lote = LAST_INSERT_ID();
        UPDATE lote SET codigo_lote = CONCAT('L-', LPAD(v_lote, 6, '0')) WHERE id_lote = v_lote;
        UPDATE movimiento_inventario SET id_lote = v_lote WHERE id_movimiento = v_id;
      ELSE
        CALL sp_consumir_lotes(v_id, v_mp, v_cant);
      END IF;
    END LOOP;
    CLOSE c;

    -- 3) Stock por bodega = suma del kardex por bodega
    INSERT INTO stock_bodega (id_bodega, id_materia_prima, cantidad)
    SELECT id_bodega, id_materia_prima,
           SUM(CASE WHEN tipo = 'ENTRADA' THEN cantidad ELSE -cantidad END)
      FROM movimiento_inventario
     GROUP BY id_bodega, id_materia_prima;
  END IF;
END$$

DELIMITER ;

CALL sp_mig_rellenar_pasado();

-- Historial de precios del pasado, reconstruido con lo que realmente se pagó cada mes
INSERT INTO historial_precio (id_proveedor, id_materia_prima, precio_unitario, vigente_desde)
SELECT m.id_proveedor, m.id_materia_prima, ROUND(AVG(m.costo_unitario), 2),
       STR_TO_DATE(CONCAT(DATE_FORMAT(MIN(m.fecha), '%Y-%m'), '-01'), '%Y-%m-%d')
  FROM movimiento_inventario m
 WHERE @ya_migrado = 0 AND m.tipo = 'ENTRADA' AND m.id_proveedor IS NOT NULL AND m.costo_unitario IS NOT NULL
 GROUP BY m.id_proveedor, m.id_materia_prima, DATE_FORMAT(m.fecha, '%Y-%m');

-- Cada precio vigente termina un segundo antes de que empiece el siguiente
UPDATE historial_precio h
  JOIN (SELECT id_historial,
               LEAD(vigente_desde) OVER (PARTITION BY id_proveedor, id_materia_prima
                                         ORDER BY vigente_desde) AS siguiente
          FROM historial_precio) x ON x.id_historial = h.id_historial
   SET h.vigente_hasta = DATE_SUB(x.siguiente, INTERVAL 1 SECOND)
 WHERE @ya_migrado = 0 AND x.siguiente IS NOT NULL;

-- Si el último precio de la historia no es el del catálogo de hoy, se cierra y se abre el actual
UPDATE historial_precio h
  JOIN proveedor_materia_prima pmp
    ON pmp.id_proveedor = h.id_proveedor AND pmp.id_materia_prima = h.id_materia_prima
   SET h.vigente_hasta = GREATEST(h.vigente_desde, '2026-07-31 23:59:59')
 WHERE @ya_migrado = 0 AND h.vigente_hasta IS NULL AND h.precio_unitario <> pmp.precio_unitario;

-- Toda oferta sin precio vigente abierto (sin historia, o recién cerrada) recibe el precio actual
INSERT INTO historial_precio (id_proveedor, id_materia_prima, precio_unitario, vigente_desde)
SELECT pmp.id_proveedor, pmp.id_materia_prima, pmp.precio_unitario,
       COALESCE((SELECT DATE_ADD(MAX(h2.vigente_hasta), INTERVAL 1 SECOND)
                   FROM historial_precio h2
                  WHERE h2.id_proveedor = pmp.id_proveedor
                    AND h2.id_materia_prima = pmp.id_materia_prima), '2026-08-01 00:00:00')
  FROM proveedor_materia_prima pmp
 WHERE @ya_migrado = 0
   AND NOT EXISTS (SELECT 1 FROM historial_precio h
                    WHERE h.id_proveedor = pmp.id_proveedor
                      AND h.id_materia_prima = pmp.id_materia_prima
                      AND h.vigente_hasta IS NULL);

-- Clientes: los nombres que antes eran texto libre en los despachos pasan a ser clientes reales
INSERT IGNORE INTO cliente (nit, nombre, ciudad)
SELECT CONCAT('9', LPAD(10000 + (SELECT COUNT(*) FROM cliente) + ROW_NUMBER() OVER (ORDER BY n.cliente), 8, '0'), '-',
              MOD(ROW_NUMBER() OVER (ORDER BY n.cliente), 9) + 1),
       n.cliente,
       ELT(1 + MOD(ROW_NUMBER() OVER (ORDER BY n.cliente), 4), 'Bogotá', 'Medellín', 'Cali', 'Bucaramanga')
  FROM (SELECT DISTINCT cliente FROM despacho
         WHERE cliente NOT IN (SELECT nombre FROM cliente)) n;

UPDATE despacho d JOIN cliente c ON c.nombre = d.cliente
   SET d.id_cliente = c.id_cliente
 WHERE d.id_cliente IS NULL;

-- Cada despacho histórico se convierte en un pedido de venta ya despachado.
-- El precio se reconstruye con el de lista de hoy menos ~0,5 % por cada mes hacia atrás.
INSERT INTO pedido_venta (id_pedido, id_cliente, fecha, estado, fecha_cierre, observacion)
SELECT d.id_despacho, d.id_cliente, d.fecha, 'DESPACHADO', d.fecha, 'Generado desde el despacho histórico'
  FROM despacho d
 WHERE @ya_migrado = 0 AND d.id_pedido IS NULL AND d.id_cliente IS NOT NULL;

INSERT INTO pedido_venta_detalle (id_pedido, id_producto, cantidad, precio_unitario)
SELECT d.id_despacho, d.id_producto, d.cantidad,
       ROUND(pr.precio_venta * (1 - 0.005 * GREATEST(0, DATEDIFF('2026-08-01', d.fecha) / 30)) / 1000) * 1000
  FROM despacho d JOIN producto pr ON pr.id_producto = d.id_producto
 WHERE @ya_migrado = 0 AND d.id_pedido IS NULL AND d.id_cliente IS NOT NULL;

UPDATE despacho SET id_pedido = id_despacho
 WHERE @ya_migrado = 0 AND id_pedido IS NULL AND id_cliente IS NOT NULL;

-- =====================================================================
-- PARTE 6. TRIGGERS: lo nuevo se mantiene solo
-- =====================================================================
DELIMITER $$

-- ANTES de guardar un movimiento: asigna bodega y, si es una compra, crea su lote.
-- Va DESPUÉS de trg_movimiento_costo (el que pone el precio), sin tocarlo.
DROP TRIGGER IF EXISTS trg_mov_bodega_lote$$
CREATE TRIGGER trg_mov_bodega_lote
BEFORE INSERT ON movimiento_inventario
FOR EACH ROW FOLLOWS trg_movimiento_costo
BEGIN
  DECLARE v_lote INT;

  IF NEW.id_bodega IS NULL THEN
    SET NEW.id_bodega = COALESCE(
      (SELECT id_bodega_predeterminada FROM materia_prima WHERE id_materia_prima = NEW.id_materia_prima),
      (SELECT id_bodega FROM bodega WHERE codigo = 'BOD-01'));
  END IF;

  IF NEW.tipo = 'ENTRADA' AND NEW.id_lote IS NULL THEN
    INSERT INTO lote (id_materia_prima, id_proveedor, fecha_ingreso, cantidad_inicial, cantidad_disponible)
    VALUES (NEW.id_materia_prima, NEW.id_proveedor, NEW.fecha, NEW.cantidad, NEW.cantidad);
    SET v_lote = LAST_INSERT_ID();
    UPDATE lote SET codigo_lote = CONCAT('L-', LPAD(v_lote, 6, '0')) WHERE id_lote = v_lote;
    SET NEW.id_lote = v_lote;
  END IF;
END$$

-- DESPUÉS de guardar: actualiza el stock de la bodega y consume lotes en las salidas.
-- Va DESPUÉS de trg_movimiento_actualiza_stock (el que actualiza el total), sin tocarlo.
DROP TRIGGER IF EXISTS trg_mov_distribuye$$
CREATE TRIGGER trg_mov_distribuye
AFTER INSERT ON movimiento_inventario
FOR EACH ROW FOLLOWS trg_movimiento_actualiza_stock
BEGIN
  IF NEW.tipo = 'ENTRADA' THEN
    INSERT INTO stock_bodega (id_bodega, id_materia_prima, cantidad)
    VALUES (NEW.id_bodega, NEW.id_materia_prima, NEW.cantidad)
    ON DUPLICATE KEY UPDATE cantidad = cantidad + NEW.cantidad;
  ELSE
    UPDATE stock_bodega SET cantidad = cantidad - NEW.cantidad
     WHERE id_bodega = NEW.id_bodega AND id_materia_prima = NEW.id_materia_prima;
    IF ROW_COUNT() = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No hay existencias de esa materia prima en la bodega';
    END IF;
    CALL sp_consumir_lotes(NEW.id_movimiento, NEW.id_materia_prima, NEW.cantidad);
  END IF;
END$$

-- Si el despacho trae solo el nombre del cliente, se enlaza al cliente registrado
DROP TRIGGER IF EXISTS trg_despacho_cliente$$
CREATE TRIGGER trg_despacho_cliente
BEFORE INSERT ON despacho
FOR EACH ROW
BEGIN
  IF NEW.id_cliente IS NULL THEN
    SET NEW.id_cliente = (SELECT id_cliente FROM cliente WHERE nombre = NEW.cliente LIMIT 1);
  END IF;
END$$

-- Historial de precios: cada alta o cambio de precio del proveedor queda registrado solo
DROP TRIGGER IF EXISTS trg_pmp_historial_alta$$
CREATE TRIGGER trg_pmp_historial_alta
AFTER INSERT ON proveedor_materia_prima
FOR EACH ROW
BEGIN
  INSERT INTO historial_precio (id_proveedor, id_materia_prima, precio_unitario, vigente_desde)
  VALUES (NEW.id_proveedor, NEW.id_materia_prima, NEW.precio_unitario, NOW());
END$$

DROP TRIGGER IF EXISTS trg_pmp_historial_cambio$$
CREATE TRIGGER trg_pmp_historial_cambio
AFTER UPDATE ON proveedor_materia_prima
FOR EACH ROW
BEGIN
  IF NEW.precio_unitario <> OLD.precio_unitario THEN
    UPDATE historial_precio SET vigente_hasta = GREATEST(vigente_desde, NOW())
     WHERE id_proveedor = NEW.id_proveedor AND id_materia_prima = NEW.id_materia_prima
       AND vigente_hasta IS NULL;
    INSERT INTO historial_precio (id_proveedor, id_materia_prima, precio_unitario, vigente_desde)
    VALUES (NEW.id_proveedor, NEW.id_materia_prima, NEW.precio_unitario, NOW());
  END IF;
END$$

DELIMITER ;

-- =====================================================================
-- PARTE 7. PROCEDIMIENTOS (lectura y operaciones)
-- =====================================================================
DELIMITER $$

-- ---------- Bodegas y lotes ----------
DROP PROCEDURE IF EXISTS sp_get_inventario_bodegas$$
CREATE PROCEDURE sp_get_inventario_bodegas()
BEGIN
  SELECT * FROM vista_inventario_por_bodega ORDER BY bodega, codigo;
END$$

DROP PROCEDURE IF EXISTS sp_get_lotes$$
CREATE PROCEDURE sp_get_lotes(IN p_id_materia INT)
BEGIN
  SELECT l.id_lote, l.codigo_lote, l.fecha_ingreso, pv.nombre AS proveedor,
         l.lote_proveedor, l.fecha_vencimiento, l.cantidad_inicial, l.cantidad_disponible
    FROM lote l LEFT JOIN proveedor pv ON pv.id_proveedor = l.id_proveedor
   WHERE l.id_materia_prima = p_id_materia AND l.abierto = 1
   ORDER BY l.fecha_ingreso, l.id_lote;      -- el primero de la lista es el que se gasta primero
END$$

-- Trazabilidad hacia adelante: ¿en qué órdenes y productos se usó este lote?
DROP PROCEDURE IF EXISTS sp_get_trazabilidad_lote$$
CREATE PROCEDURE sp_get_trazabilidad_lote(IN p_id_lote INT)
BEGIN
  SELECT * FROM vista_trazabilidad_lote WHERE id_lote = p_id_lote ORDER BY fecha_consumo;
END$$

-- Compra con datos de lote del proveedor y bodega de destino
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
  IF NOT EXISTS (SELECT 1 FROM proveedor_materia_prima
                  WHERE id_proveedor = p_id_proveedor AND id_materia_prima = p_id_materia) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ese proveedor no vende esa materia prima';
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

-- Mover stock entre bodegas: el total de la materia NO cambia
DROP PROCEDURE IF EXISTS sp_trasladar_stock$$
CREATE PROCEDURE sp_trasladar_stock(
  IN p_id_materia INT, IN p_id_origen INT, IN p_id_destino INT, IN p_cantidad DECIMAL(12,3))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad debe ser mayor que cero';
  END IF;
  IF p_id_origen = p_id_destino THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bodega de origen y destino son la misma';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM bodega WHERE id_bodega = p_id_destino AND activa) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bodega de destino no existe o esta inactiva';
  END IF;

  START TRANSACTION;
  IF COALESCE((SELECT cantidad FROM stock_bodega
                WHERE id_bodega = p_id_origen AND id_materia_prima = p_id_materia FOR UPDATE), 0) < p_cantidad THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No hay suficiente stock en la bodega de origen';
  END IF;

  UPDATE stock_bodega SET cantidad = cantidad - p_cantidad
   WHERE id_bodega = p_id_origen AND id_materia_prima = p_id_materia;
  INSERT INTO stock_bodega (id_bodega, id_materia_prima, cantidad)
  VALUES (p_id_destino, p_id_materia, p_cantidad)
  ON DUPLICATE KEY UPDATE cantidad = cantidad + p_cantidad;
  INSERT INTO traslado_bodega (id_materia_prima, id_origen, id_destino, cantidad)
  VALUES (p_id_materia, p_id_origen, p_id_destino, p_cantidad);
  COMMIT;

  SELECT * FROM vista_inventario_por_bodega WHERE id_materia_prima = p_id_materia ORDER BY bodega;
END$$

-- ---------- Precios ----------
DROP PROCEDURE IF EXISTS sp_cambiar_precio_proveedor$$
CREATE PROCEDURE sp_cambiar_precio_proveedor(
  IN p_id_proveedor INT, IN p_id_materia INT, IN p_precio DECIMAL(12,2))
BEGIN
  IF p_precio IS NULL OR p_precio <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio debe ser mayor que cero';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM proveedor_materia_prima
                  WHERE id_proveedor = p_id_proveedor AND id_materia_prima = p_id_materia) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ese proveedor no vende esa materia prima';
  END IF;

  UPDATE proveedor_materia_prima SET precio_unitario = p_precio
   WHERE id_proveedor = p_id_proveedor AND id_materia_prima = p_id_materia;   -- el trigger guarda el historial

  CALL sp_get_historial_precios(p_id_proveedor, p_id_materia);
END$$

DROP PROCEDURE IF EXISTS sp_get_historial_precios$$
CREATE PROCEDURE sp_get_historial_precios(IN p_id_proveedor INT, IN p_id_materia INT)
BEGIN
  SELECT h.vigente_desde, h.vigente_hasta, h.precio_unitario,
         ROUND(100 * (h.precio_unitario / LAG(h.precio_unitario) OVER (ORDER BY h.vigente_desde) - 1), 2) AS variacion_pct
    FROM historial_precio h
   WHERE h.id_proveedor = p_id_proveedor AND h.id_materia_prima = p_id_materia
   ORDER BY h.vigente_desde;
END$$

-- ---------- Clientes y pedidos ----------
DROP PROCEDURE IF EXISTS sp_crear_cliente$$
CREATE PROCEDURE sp_crear_cliente(
  IN p_nit VARCHAR(20), IN p_nombre VARCHAR(100), IN p_telefono VARCHAR(20),
  IN p_email VARCHAR(100), IN p_ciudad VARCHAR(60))
BEGIN
  INSERT INTO cliente (nit, nombre, telefono, email, ciudad)
  VALUES (p_nit, p_nombre, p_telefono, p_email, p_ciudad);
  SELECT LAST_INSERT_ID() AS id_cliente_creado;
END$$

DROP PROCEDURE IF EXISTS sp_crear_pedido$$
CREATE PROCEDURE sp_crear_pedido(IN p_id_cliente INT, IN p_observacion VARCHAR(200))
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cliente WHERE id_cliente = p_id_cliente AND activo) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente no existe o esta inactivo';
  END IF;
  INSERT INTO pedido_venta (id_cliente, observacion) VALUES (p_id_cliente, p_observacion);
  SELECT LAST_INSERT_ID() AS id_pedido_creado;
END$$

-- Agrega un producto al pedido con el precio de lista de HOY (si ya estaba, suma la cantidad)
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
  SET v_precio = (SELECT precio_venta FROM producto WHERE id_producto = p_id_producto);
  IF v_precio IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  END IF;

  INSERT INTO pedido_venta_detalle (id_pedido, id_producto, cantidad, precio_unitario)
  VALUES (p_id_pedido, p_id_producto, p_cantidad, v_precio)
  ON DUPLICATE KEY UPDATE cantidad = cantidad + p_cantidad;

  CALL sp_get_pedido_detalle(p_id_pedido);
END$$

-- Despacha TODO el pedido en una sola transacción: o sale completo o no sale nada
DROP PROCEDURE IF EXISTS sp_despachar_pedido$$
CREATE PROCEDURE sp_despachar_pedido(IN p_id_pedido INT)
BEGIN
  DECLARE v_estado VARCHAR(20);
  DECLARE v_faltan TEXT;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  SELECT estado INTO v_estado FROM pedido_venta WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF v_estado IS NULL OR v_estado <> 'ABIERTO' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pedido no existe o ya no esta ABIERTO';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pedido_venta_detalle WHERE id_pedido = p_id_pedido) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pedido no tiene productos';
  END IF;

  -- Revisa todas las líneas antes de mover nada, y dice cuáles no alcanzan
  SELECT GROUP_CONCAT(CONCAT(pr.nombre, ' (hay ', pr.stock_actual, ', pide ', d.cantidad, ')') SEPARATOR '; ')
    INTO v_faltan
    FROM pedido_venta_detalle d JOIN producto pr ON pr.id_producto = d.id_producto
   WHERE d.id_pedido = p_id_pedido AND pr.stock_actual < d.cantidad;
  IF v_faltan IS NOT NULL THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'No hay suficiente producto terminado para despachar este pedido';
  END IF;

  INSERT INTO despacho (id_producto, cantidad, cliente, id_cliente, id_pedido, observacion)
  SELECT d.id_producto, d.cantidad, c.nombre, c.id_cliente, p.id_pedido,
         CONCAT('Pedido de venta PV-', p.id_pedido)
    FROM pedido_venta_detalle d
    JOIN pedido_venta p ON p.id_pedido = d.id_pedido
    JOIN cliente c      ON c.id_cliente = p.id_cliente
   WHERE d.id_pedido = p_id_pedido;

  UPDATE pedido_venta SET estado = 'DESPACHADO', fecha_cierre = NOW() WHERE id_pedido = p_id_pedido;
  COMMIT;

  CALL sp_get_pedido_detalle(p_id_pedido);
END$$

DROP PROCEDURE IF EXISTS sp_cancelar_pedido$$
CREATE PROCEDURE sp_cancelar_pedido(IN p_id_pedido INT)
BEGIN
  UPDATE pedido_venta SET estado = 'CANCELADO', fecha_cierre = NOW()
   WHERE id_pedido = p_id_pedido AND estado = 'ABIERTO';
  IF ROW_COUNT() = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pedido no existe o ya no esta ABIERTO';
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_get_pedidos$$
CREATE PROCEDURE sp_get_pedidos(IN p_estado VARCHAR(20))
BEGIN
  SELECT p.id_pedido, c.nombre AS cliente, p.fecha, p.estado, p.fecha_cierre,
         COUNT(d.id_producto) AS lineas, COALESCE(SUM(d.cantidad * d.precio_unitario), 0) AS total
    FROM pedido_venta p
    JOIN cliente c ON c.id_cliente = p.id_cliente
    LEFT JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
   WHERE p_estado IS NULL OR p.estado = p_estado
   GROUP BY p.id_pedido, c.nombre, p.fecha, p.estado, p.fecha_cierre
   ORDER BY p.fecha DESC, p.id_pedido DESC;
END$$

DROP PROCEDURE IF EXISTS sp_get_pedido_detalle$$
CREATE PROCEDURE sp_get_pedido_detalle(IN p_id_pedido INT)
BEGIN
  SELECT d.id_pedido, pr.codigo, pr.nombre AS producto, d.cantidad, d.precio_unitario,
         d.cantidad * d.precio_unitario AS subtotal, p.estado
    FROM pedido_venta_detalle d
    JOIN producto pr   ON pr.id_producto = d.id_producto
    JOIN pedido_venta p ON p.id_pedido = d.id_pedido
   WHERE d.id_pedido = p_id_pedido
   ORDER BY pr.codigo;
END$$

DELIMITER ;

-- =====================================================================
-- PARTE 8. VISTAS DE CONSULTA
-- =====================================================================
CREATE OR REPLACE VIEW vista_inventario_por_bodega AS
SELECT b.codigo AS bodega_codigo, b.nombre AS bodega, mp.id_materia_prima, mp.codigo, mp.nombre AS materia_prima,
       mp.unidad_medida, sb.cantidad
  FROM stock_bodega sb
  JOIN bodega b         ON b.id_bodega = sb.id_bodega
  JOIN materia_prima mp ON mp.id_materia_prima = sb.id_materia_prima;

CREATE OR REPLACE VIEW vista_trazabilidad_lote AS
SELECT l.id_lote, l.codigo_lote, mp.codigo AS materia, pv.nombre AS proveedor,
       m.fecha AS fecha_consumo, cl.cantidad AS cantidad_consumida,
       o.id_orden, pr.nombre AS producto_fabricado, o.cantidad AS unidades_orden
  FROM consumo_lote cl
  JOIN lote l                  ON l.id_lote = cl.id_lote
  JOIN materia_prima mp        ON mp.id_materia_prima = l.id_materia_prima
  LEFT JOIN proveedor pv       ON pv.id_proveedor = l.id_proveedor
  JOIN movimiento_inventario m ON m.id_movimiento = cl.id_movimiento
  LEFT JOIN orden_produccion o ON o.id_orden = m.id_orden
  LEFT JOIN producto pr        ON pr.id_producto = o.id_producto;

CREATE OR REPLACE VIEW vista_ventas_mensual AS
SELECT DATE_FORMAT(p.fecha_cierre, '%Y-%m') AS mes, c.nombre AS cliente,
       COUNT(DISTINCT p.id_pedido) AS pedidos, SUM(d.cantidad) AS unidades,
       SUM(d.cantidad * d.precio_unitario) AS total_vendido
  FROM pedido_venta p
  JOIN cliente c ON c.id_cliente = p.id_cliente
  JOIN pedido_venta_detalle d ON d.id_pedido = p.id_pedido
 WHERE p.estado = 'DESPACHADO'
 GROUP BY DATE_FORMAT(p.fecha_cierre, '%Y-%m'), c.nombre;

-- =====================================================================
-- PARTE 9. CIERRE
-- =====================================================================
INSERT IGNORE INTO migracion_log (nombre) VALUES ('mejoras_diseno');

DROP PROCEDURE IF EXISTS sp_mig_requisito;
DROP PROCEDURE IF EXISTS sp_mig_columna;
DROP PROCEDURE IF EXISTS sp_mig_fk;
DROP PROCEDURE IF EXISTS sp_mig_check;
DROP PROCEDURE IF EXISTS sp_mig_rellenar_pasado;
SET @ya_migrado = NULL;

-- =====================================================================
-- PARTE 10. VERIFICACIONES (ejecutar una a la vez)
-- =====================================================================
-- 10.1 Los tres totales deben coincidir: materia_prima = lotes = bodegas (columna 'dif_*' en 0)
-- SELECT mp.codigo, mp.stock_actual,
--        (SELECT COALESCE(SUM(cantidad_disponible),0) FROM lote WHERE id_materia_prima=mp.id_materia_prima) AS en_lotes,
--        (SELECT COALESCE(SUM(cantidad),0) FROM stock_bodega WHERE id_materia_prima=mp.id_materia_prima) AS en_bodegas
--   FROM materia_prima mp;
--
-- 10.2 Lotes abiertos de la lámina (el primero se gasta primero)
-- CALL sp_get_lotes(1);
--
-- 10.3 Trazabilidad: ¿en qué productos terminó el lote más viejo de la lámina?
-- CALL sp_get_trazabilidad_lote((SELECT MIN(id_lote) FROM lote WHERE id_materia_prima = 1));
--
-- 10.4 Historial de precios de la lámina del proveedor 1
-- CALL sp_get_historial_precios(1, 1);
--
-- 10.5 Ventas por mes
-- SELECT * FROM vista_ventas_mensual ORDER BY mes DESC, total_vendido DESC LIMIT 10;
--
-- 10.6 Flujo de venta completo
-- CALL sp_crear_pedido(1, 'Prueba');                  -- anota el id que devuelve
-- CALL sp_agregar_linea_pedido(<id>, 1, 5);
-- CALL sp_despachar_pedido(<id>);
