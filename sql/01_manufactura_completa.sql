-- =====================================================================
-- BASE DE DATOS: manufactura (Control de producción e inventarios)
-- Caso: fábrica de muebles de oficina (metalmecánica + tapicería)
-- Motor: MySQL 8.0.16 o superior (necesario para que funcionen los CHECK)
-- Grupo: Forero - Ramos - Peña J.
-- NOTA: nombres de empresas y NIT son ficticios. Precios en pesos (COP).
-- =====================================================================

SET NAMES utf8mb4;
DROP DATABASE IF EXISTS manufactura;
CREATE DATABASE manufactura CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE manufactura;

-- ---------------------------------------------------------------------
-- 1. TABLAS BASE
-- ---------------------------------------------------------------------

CREATE TABLE proveedor (
  id_proveedor INT AUTO_INCREMENT PRIMARY KEY,
  nit          VARCHAR(20)  NOT NULL UNIQUE,
  nombre       VARCHAR(100) NOT NULL,
  telefono     VARCHAR(20),
  email        VARCHAR(100),
  activo       BOOLEAN NOT NULL DEFAULT TRUE
) ENGINE=InnoDB;

CREATE TABLE materia_prima (
  id_materia_prima INT AUTO_INCREMENT PRIMARY KEY,
  codigo           VARCHAR(20)   NOT NULL UNIQUE,
  nombre           VARCHAR(100)  NOT NULL,
  unidad_medida    VARCHAR(10)   NOT NULL,
  stock_actual     DECIMAL(12,3) NOT NULL DEFAULT 0,
  stock_minimo     DECIMAL(12,3) NOT NULL DEFAULT 0,
  CONSTRAINT ck_mp_stock_no_negativo CHECK (stock_actual >= 0),
  CONSTRAINT ck_mp_stock_minimo      CHECK (stock_minimo >= 0)
) ENGINE=InnoDB;

CREATE TABLE producto (
  id_producto  INT AUTO_INCREMENT PRIMARY KEY,
  codigo       VARCHAR(20)   NOT NULL UNIQUE,
  nombre       VARCHAR(100)  NOT NULL,
  precio_venta DECIMAL(12,2) NOT NULL,
  stock_actual INT           NOT NULL DEFAULT 0,
  CONSTRAINT ck_prod_precio CHECK (precio_venta > 0),
  CONSTRAINT ck_prod_stock  CHECK (stock_actual >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. TABLAS INTERMEDIAS (relaciones muchos a muchos)
-- ---------------------------------------------------------------------

-- Qué proveedor vende qué materia prima, desde qué país y a qué precio
CREATE TABLE proveedor_materia_prima (
  id_proveedor        INT NOT NULL,
  id_materia_prima    INT NOT NULL,
  pais_origen         VARCHAR(60)   NOT NULL,
  precio_unitario     DECIMAL(12,2) NOT NULL,
  tiempo_entrega_dias INT           NOT NULL DEFAULT 1,
  PRIMARY KEY (id_proveedor, id_materia_prima),
  CONSTRAINT fk_pmp_proveedor FOREIGN KEY (id_proveedor)
    REFERENCES proveedor(id_proveedor) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_pmp_materia FOREIGN KEY (id_materia_prima)
    REFERENCES materia_prima(id_materia_prima) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_pmp_precio  CHECK (precio_unitario > 0),
  CONSTRAINT ck_pmp_entrega CHECK (tiempo_entrega_dias >= 0)
) ENGINE=InnoDB;

-- Receta (BOM): cuánta materia prima consume UNA unidad de cada producto
CREATE TABLE receta (
  id_producto         INT NOT NULL,
  id_materia_prima    INT NOT NULL,
  cantidad_por_unidad DECIMAL(12,4) NOT NULL,
  PRIMARY KEY (id_producto, id_materia_prima),
  CONSTRAINT fk_rec_producto FOREIGN KEY (id_producto)
    REFERENCES producto(id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_rec_materia FOREIGN KEY (id_materia_prima)
    REFERENCES materia_prima(id_materia_prima) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_rec_cantidad CHECK (cantidad_por_unidad > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. OPERACIÓN: órdenes de producción y movimientos (kardex)
-- ---------------------------------------------------------------------

CREATE TABLE orden_produccion (
  id_orden       INT AUTO_INCREMENT PRIMARY KEY,
  id_producto    INT NOT NULL,
  cantidad       INT NOT NULL,
  estado         ENUM('PENDIENTE','COMPLETADA','CANCELADA') NOT NULL DEFAULT 'PENDIENTE',
  fecha_creacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_cierre   DATETIME NULL,
  CONSTRAINT fk_op_producto FOREIGN KEY (id_producto)
    REFERENCES producto(id_producto) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_op_cantidad CHECK (cantidad > 0)
) ENGINE=InnoDB;

-- Cada entrada o salida de materia prima queda registrada aquí
CREATE TABLE movimiento_inventario (
  id_movimiento    INT AUTO_INCREMENT PRIMARY KEY,
  id_materia_prima INT NOT NULL,
  tipo             ENUM('ENTRADA','SALIDA') NOT NULL,
  cantidad         DECIMAL(12,3) NOT NULL,
  fecha            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  id_proveedor     INT NULL,   -- se llena en las compras (ENTRADA)
  id_orden         INT NULL,   -- se llena en los consumos (SALIDA)
  observacion      VARCHAR(200),
  CONSTRAINT fk_mov_materia FOREIGN KEY (id_materia_prima)
    REFERENCES materia_prima(id_materia_prima) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_mov_proveedor FOREIGN KEY (id_proveedor)
    REFERENCES proveedor(id_proveedor) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_mov_orden FOREIGN KEY (id_orden)
    REFERENCES orden_produccion(id_orden) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT ck_mov_cantidad CHECK (cantidad > 0)
) ENGINE=InnoDB;

CREATE INDEX idx_mov_materia_fecha ON movimiento_inventario (id_materia_prima, fecha);

-- ---------------------------------------------------------------------
-- 4. AUTOMATIZACIÓN
-- ---------------------------------------------------------------------

DELIMITER $$

-- TRIGGER: cada vez que se inserta un movimiento, el stock se ajusta solo.
-- Si una SALIDA deja el stock negativo, el CHECK falla y TODO se cancela.
CREATE TRIGGER trg_movimiento_actualiza_stock
AFTER INSERT ON movimiento_inventario
FOR EACH ROW
BEGIN
  IF NEW.tipo = 'ENTRADA' THEN
    UPDATE materia_prima
       SET stock_actual = stock_actual + NEW.cantidad
     WHERE id_materia_prima = NEW.id_materia_prima;
  ELSE
    UPDATE materia_prima
       SET stock_actual = stock_actual - NEW.cantidad
     WHERE id_materia_prima = NEW.id_materia_prima;
  END IF;
END$$

-- PROCEDIMIENTO: completa una orden de producción como UNA sola transacción.
-- O se hace todo (consumir materias, sumar producto, cerrar orden) o no se hace nada.
CREATE PROCEDURE sp_completar_orden (IN p_id_orden INT)
BEGIN
  DECLARE v_estado   VARCHAR(20);
  DECLARE v_producto INT;
  DECLARE v_cantidad INT;

  -- Si ocurre cualquier error: deshacer todo y mostrar el error original
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  START TRANSACTION;

  -- FOR UPDATE bloquea la orden para que nadie más la procese a la vez
  SELECT estado, id_producto, cantidad
    INTO v_estado, v_producto, v_cantidad
    FROM orden_produccion
   WHERE id_orden = p_id_orden
     FOR UPDATE;

  IF v_estado IS NULL OR v_estado <> 'PENDIENTE' THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'La orden no existe o no esta PENDIENTE';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM receta WHERE id_producto = v_producto) THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'El producto no tiene receta definida';
  END IF;

  -- Una SALIDA por cada materia prima de la receta (el trigger descuenta el stock)
  INSERT INTO movimiento_inventario
         (id_materia_prima, tipo, cantidad, id_orden, observacion)
  SELECT r.id_materia_prima, 'SALIDA', r.cantidad_por_unidad * v_cantidad,
         p_id_orden, CONCAT('Consumo orden de produccion OP-', p_id_orden)
    FROM receta r
   WHERE r.id_producto = v_producto;

  -- Entra el producto terminado
  UPDATE producto
     SET stock_actual = stock_actual + v_cantidad
   WHERE id_producto = v_producto;

  -- Se cierra la orden
  UPDATE orden_produccion
     SET estado = 'COMPLETADA', fecha_cierre = NOW()
   WHERE id_orden = p_id_orden;

  COMMIT;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 5. VISTA: inventario disponible
-- ---------------------------------------------------------------------

CREATE VIEW vista_inventario AS
SELECT mp.codigo,
       mp.nombre,
       mp.unidad_medida,
       mp.stock_actual,
       mp.stock_minimo,
       CASE WHEN mp.stock_actual <= mp.stock_minimo THEN 'REABASTECER' ELSE 'OK' END AS estado
  FROM materia_prima mp;

-- ---------------------------------------------------------------------
-- 6. DATOS REALISTAS
-- ---------------------------------------------------------------------

-- 6.1 Proveedores (8)
INSERT INTO proveedor (nit, nombre, telefono, email) VALUES
 ('900412378-5', 'Aceros y Laminados del Caribe S.A.S.',        '6053854120', 'ventas@acerosdelcaribe.com.co'),
 ('830215664-1', 'Distribuidora Metálica Andina Ltda.',         '6017423365', 'pedidos@metalicaandina.com.co'),
 ('890305127-9', 'Maderas y Tableros de Santander S.A.',        '6076351890', 'comercial@tablerosdesantander.com.co'),
 ('901128450-3', 'Pinturas Electrostáticas del Valle S.A.S.',   '6023318472', 'servicioalcliente@pinturasdelvalle.com.co'),
 ('860045982-7', 'Tornillos y Herrajes Industriales Ltda.',     '6012674033', 'ventas@tornillosyherrajes.com.co'),
 ('900776231-2', 'Espumas y Tapicerías de Bogotá S.A.S.',       '3114820957', 'compras@espumasytapicerias.com.co'),
 ('901554093-6', 'Importadora de Componentes Asia-Pacífico S.A.S.', '3208871460', 'importaciones@asiapacifico.com.co'),
 ('890902117-4', 'Empaques Corrugados de Colombia S.A.',        '6044437781', 'ventas@empaquescorrugados.com.co');

-- 6.2 Materias primas (10). El stock arranca en 0: lo llenan las compras (kardex)
INSERT INTO materia_prima (codigo, nombre, unidad_medida, stock_minimo) VALUES
 ('MP-001', 'Lámina cold rolled calibre 20',        'KG',  300),
 ('MP-002', 'Tubo cuadrado 1" calibre 18',          'M',   200),
 ('MP-003', 'Tablero MDF 15 mm (1,22 x 2,44 m)',    'UND',  40),
 ('MP-004', 'Pintura electrostática en polvo gris', 'KG',   25),
 ('MP-005', 'Tornillo autoperforante 1/2"',         'UND', 2000),
 ('MP-006', 'Lámina de espuma poliuretano 5 cm',    'UND',  30),
 ('MP-007', 'Tela tapicería antifluido',            'M',    60),
 ('MP-008', 'Rodachín de nylon 50 mm',              'UND', 100),
 ('MP-009', 'Riel telescópico para gaveta 45 cm',   'UND', 100),
 ('MP-010', 'Caja de cartón corrugado para empaque','UND',  80);

-- 6.3 Productos terminados (5)
INSERT INTO producto (codigo, nombre, precio_venta) VALUES
 ('PR-001', 'Silla operativa ergonómica',      289000.00),
 ('PR-002', 'Escritorio ejecutivo en L',       640000.00),
 ('PR-003', 'Archivador metálico 4 gavetas',   520000.00),
 ('PR-004', 'Estantería metálica 5 niveles',   215000.00),
 ('PR-005', 'Mesa de reuniones 8 puestos',     980000.00);

-- 6.4 Qué vende cada proveedor (materia, país de origen, precio COP, días de entrega)
INSERT INTO proveedor_materia_prima VALUES
 (1, 1, 'Colombia',  4850.00,  3),
 (2, 1, 'Colombia',  5100.00,  2),
 (7, 1, 'China',     4050.00, 40),
 (1, 2, 'Colombia',  7800.00,  3),
 (2, 2, 'Colombia',  8150.00,  2),
 (3, 3, 'Colombia', 78000.00,  4),
 (7, 3, 'Brasil',   71500.00, 30),
 (4, 4, 'Colombia', 21500.00,  5),
 (7, 4, 'Turquía',  18900.00, 38),
 (5, 5, 'Colombia',    38.00,  2),
 (7, 5, 'China',       24.00, 40),
 (6, 6, 'Colombia', 46000.00,  4),
 (6, 7, 'Colombia', 17800.00,  4),
 (7, 7, 'India',    13900.00, 45),
 (7, 8, 'China',     2100.00, 38),
 (5, 8, 'Colombia',  3400.00,  3),
 (7, 9, 'China',     9800.00, 38),
 (5, 9, 'Colombia', 14500.00,  3),
 (8,10, 'Colombia',  4300.00,  5);

-- 6.5 Recetas: materia prima que consume UNA unidad de cada producto
INSERT INTO receta VALUES
 -- Silla operativa ergonómica
 (1, 1,  2.5000), (1, 2,  4.5000), (1, 4, 0.3000), (1, 5, 16.0000),
 (1, 6,  0.2500), (1, 7,  1.2000), (1, 8, 5.0000), (1,10,  1.0000),
 -- Escritorio ejecutivo en L
 (2, 3,  2.0000), (2, 2,  9.0000), (2, 4, 0.4000), (2, 5, 30.0000), (2,10, 2.0000),
 -- Archivador metálico 4 gavetas
 (3, 1, 28.0000), (3, 9,  8.0000), (3, 4, 1.2000), (3, 5, 40.0000), (3,10, 1.0000),
 -- Estantería metálica 5 niveles
 (4, 1, 14.0000), (4, 4,  0.8000), (4, 5, 48.0000), (4,10, 1.0000),
 -- Mesa de reuniones 8 puestos
 (5, 3,  3.0000), (5, 2, 14.0000), (5, 4, 0.6000), (5, 5, 24.0000), (5,10, 2.0000);

-- 6.6 Compras (ENTRADAS) entre agosto y mediados de septiembre.
--     El trigger sube el stock solo con cada insert.
INSERT INTO movimiento_inventario
  (id_materia_prima, tipo, cantidad, fecha, id_proveedor, observacion) VALUES
 (1,  'ENTRADA',  800, '2026-08-04 09:30:00', 1, 'Compra OC-2026-001 lámina'),
 (2,  'ENTRADA',  600, '2026-08-04 10:15:00', 2, 'Compra OC-2026-002 tubo'),
 (3,  'ENTRADA',   80, '2026-08-05 08:45:00', 3, 'Compra OC-2026-003 MDF'),
 (4,  'ENTRADA',  100, '2026-08-06 11:00:00', 4, 'Compra OC-2026-004 pintura'),
 (5,  'ENTRADA', 3000, '2026-08-06 14:20:00', 5, 'Compra OC-2026-005 tornillería'),
 (6,  'ENTRADA',   60, '2026-08-07 09:10:00', 6, 'Compra OC-2026-006 espuma'),
 (7,  'ENTRADA',  150, '2026-08-07 09:40:00', 6, 'Compra OC-2026-007 tela'),
 (10, 'ENTRADA',  300, '2026-08-08 15:05:00', 8, 'Compra OC-2026-008 cajas'),
 (8,  'ENTRADA', 1000, '2026-08-10 10:30:00', 7, 'Importación OC-2026-009 rodachines'),
 (9,  'ENTRADA',  400, '2026-08-10 10:45:00', 7, 'Importación OC-2026-010 rieles'),
 (10, 'ENTRADA',  200, '2026-09-12 08:50:00', 8, 'Reposición OC-2026-014 cajas'),
 (1,  'ENTRADA',  700, '2026-09-08 09:00:00', 1, 'Reposición OC-2026-011 lámina'),
 (2,  'ENTRADA',  400, '2026-09-08 09:20:00', 1, 'Reposición OC-2026-012 tubo'),
 (5,  'ENTRADA', 4000, '2026-09-09 13:15:00', 5, 'Reposición OC-2026-013 tornillería'),
 (4,  'ENTRADA',   60, '2026-09-10 10:40:00', 4, 'Reposición OC-2026-015 pintura');

-- 6.7 Órdenes de producción (8 se completan, 2 quedan pendientes y 1 cancelada)
INSERT INTO orden_produccion (id_producto, cantidad, fecha_creacion) VALUES
 (1, 40, '2026-09-15 08:00:00'),   -- OP-1  40 sillas
 (2, 15, '2026-09-16 08:00:00'),   -- OP-2  15 escritorios
 (3, 10, '2026-09-18 08:00:00'),   -- OP-3  10 archivadores
 (4, 25, '2026-09-21 08:00:00'),   -- OP-4  25 estanterías
 (5,  6, '2026-09-24 08:00:00'),   -- OP-5   6 mesas
 (1, 30, '2026-09-28 08:00:00'),   -- OP-6  30 sillas
 (3,  8, '2026-10-01 08:00:00'),   -- OP-7   8 archivadores
 (4, 20, '2026-10-02 08:00:00'),   -- OP-8  20 estanterías
 (2, 20, '2026-10-06 08:00:00'),   -- OP-9  20 escritorios (PENDIENTE)
 (5, 10, '2026-10-08 08:00:00');   -- OP-10 10 mesas (PENDIENTE)

INSERT INTO orden_produccion (id_producto, cantidad, estado, fecha_creacion, fecha_cierre) VALUES
 (1, 50, 'CANCELADA', '2026-09-25 08:00:00', '2026-09-26 10:30:00');  -- OP-11 cancelada

-- Se completan las órdenes 1 a 8 con el procedimiento (consumen materia prima solas)
CALL sp_completar_orden(1);
CALL sp_completar_orden(2);
CALL sp_completar_orden(3);
CALL sp_completar_orden(4);
CALL sp_completar_orden(5);
CALL sp_completar_orden(6);
CALL sp_completar_orden(7);
CALL sp_completar_orden(8);

-- El procedimiento sella la fecha con NOW(). Se ajusta para que el historial sea coherente:
-- cada orden se cierra 3 días y 8 horas después de crearse, y sus salidas llevan esa fecha.
SET SQL_SAFE_UPDATES = 0;

UPDATE orden_produccion
   SET fecha_cierre = DATE_ADD(fecha_creacion, INTERVAL 80 HOUR)
 WHERE estado = 'COMPLETADA';

UPDATE movimiento_inventario m
  JOIN orden_produccion o ON o.id_orden = m.id_orden
   SET m.fecha = o.fecha_cierre
 WHERE m.id_orden IS NOT NULL;

SET SQL_SAFE_UPDATES = 1;

-- ---------------------------------------------------------------------
-- 7. CONSULTAS DE DEMOSTRACIÓN Y PRUEBAS
-- ---------------------------------------------------------------------

-- 7.1 Inventario disponible (2 materias deben salir en REABASTECER: lámina y MDF)
SELECT * FROM vista_inventario;

-- 7.2 Producto terminado disponible
SELECT codigo, nombre, precio_venta, stock_actual FROM producto;

-- 7.3 Órdenes por estado (COUNT y SUM)
SELECT estado, COUNT(*) AS num_ordenes, SUM(cantidad) AS unidades
  FROM orden_produccion
 GROUP BY estado;

-- 7.4 JOIN complejo: materias primas con todos sus proveedores
SELECT mp.nombre AS materia_prima,
       p.nombre  AS proveedor,
       pmp.pais_origen,
       pmp.precio_unitario,
       pmp.tiempo_entrega_dias
  FROM materia_prima mp
  JOIN proveedor_materia_prima pmp ON pmp.id_materia_prima = mp.id_materia_prima
  JOIN proveedor p                 ON p.id_proveedor = pmp.id_proveedor
 ORDER BY mp.nombre, pmp.precio_unitario;

-- 7.5 SUM y COUNT: entradas, salidas y movimientos por materia prima
SELECT mp.nombre,
       COUNT(m.id_movimiento) AS num_movimientos,
       SUM(CASE WHEN m.tipo = 'ENTRADA' THEN m.cantidad ELSE 0 END) AS total_entradas,
       SUM(CASE WHEN m.tipo = 'SALIDA'  THEN m.cantidad ELSE 0 END) AS total_salidas
  FROM materia_prima mp
  LEFT JOIN movimiento_inventario m ON m.id_materia_prima = mp.id_materia_prima
 GROUP BY mp.id_materia_prima, mp.nombre;

-- 7.6 Conciliación: el stock guardado debe coincidir con la suma de movimientos
SELECT mp.nombre,
       mp.stock_actual AS stock_guardado,
       COALESCE(SUM(CASE WHEN m.tipo='ENTRADA' THEN m.cantidad ELSE -m.cantidad END),0) AS stock_calculado
  FROM materia_prima mp
  LEFT JOIN movimiento_inventario m ON m.id_materia_prima = mp.id_materia_prima
 GROUP BY mp.id_materia_prima, mp.nombre, mp.stock_actual;

-- 7.7 Materias a reabastecer y el proveedor más barato de cada una
SELECT mp.nombre, mp.stock_actual, mp.stock_minimo,
       p.nombre AS proveedor_mas_barato, pmp.pais_origen,
       pmp.precio_unitario, pmp.tiempo_entrega_dias
  FROM materia_prima mp
  JOIN proveedor_materia_prima pmp ON pmp.id_materia_prima = mp.id_materia_prima
  JOIN proveedor p                 ON p.id_proveedor = pmp.id_proveedor
 WHERE mp.stock_actual <= mp.stock_minimo
   AND pmp.precio_unitario = (SELECT MIN(x.precio_unitario)
                                FROM proveedor_materia_prima x
                               WHERE x.id_materia_prima = mp.id_materia_prima);

-- ---------------------------------------------------------------------
-- 8. PRUEBAS DE LAS ÓRDENES PENDIENTES (ejecutar una a la vez)
-- ---------------------------------------------------------------------
-- OP-10 (10 mesas) SÍ alcanza el stock de MDF:
-- CALL sp_completar_orden(10);
--
-- OP-9 (20 escritorios) necesita 40 tableros MDF y solo hay 32: debe FALLAR
-- y no cambiar nada (prueba de la transacción). Ejecútala ANTES que la OP-10:
-- CALL sp_completar_orden(9);
-- SELECT * FROM vista_inventario;   -- el MDF sigue en 32
