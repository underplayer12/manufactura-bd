-- =====================================================================
-- ENDURECIMIENTO DEL KARDEX (OPCIONAL - ejecutar al FINAL)
--
-- IMPORTANTE PARA EL INFORME: este archivo CIERRA una vulnerabilidad que tu
-- profesor te pide encontrar y demostrar (poder modificar o borrar un
-- movimiento del kardex). Ejecútalo SOLO después de haber hecho las pruebas
-- y tomado las capturas "antes". Luego repite la prueba y toma la captura
-- "después": ese par de capturas es la evidencia.
--
-- No cambia ningún dato ni ningún procedimiento. Solo agrega 6 triggers (4 del kardex/despachos y 2 de la bitácora).
-- Los flujos normales (comprar, completar órdenes, despachar) siguen igual,
-- porque solo hacen INSERT.
-- =====================================================================

SET NAMES utf8mb4;
USE manufactura;

DELIMITER $$

-- El kardex es un libro contable: se escribe, no se corrige. Un error se
-- corrige con un movimiento nuevo que lo compense, no editando el anterior.
DROP TRIGGER IF EXISTS trg_mov_no_update$$
CREATE TRIGGER trg_mov_no_update BEFORE UPDATE ON movimiento_inventario
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'El kardex no se modifica: registra un movimiento nuevo que corrija';
END$$

DROP TRIGGER IF EXISTS trg_mov_no_delete$$
CREATE TRIGGER trg_mov_no_delete BEFORE DELETE ON movimiento_inventario
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'El kardex no se borra: registra un movimiento nuevo que corrija';
END$$

-- Lo mismo para los despachos (también son historial)
DROP TRIGGER IF EXISTS trg_desp_no_update$$
CREATE TRIGGER trg_desp_no_update BEFORE UPDATE ON despacho
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Los despachos no se modifican';
END$$

DROP TRIGGER IF EXISTS trg_desp_no_delete$$
CREATE TRIGGER trg_desp_no_delete BEFORE DELETE ON despacho
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Los despachos no se borran';
END$$

-- La bitácora (registro de solicitudes de la página) también es historial: solo se agrega.
-- (Requiere 06_modulo_aplicacion.sql, que va antes que este archivo.)
DROP TRIGGER IF EXISTS trg_bit_no_update$$
CREATE TRIGGER trg_bit_no_update BEFORE UPDATE ON bitacora
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bitacora no se modifica';
END$$

DROP TRIGGER IF EXISTS trg_bit_no_delete$$
CREATE TRIGGER trg_bit_no_delete BEFORE DELETE ON bitacora
FOR EACH ROW
BEGIN
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La bitacora no se borra';
END$$

DELIMITER ;

INSERT IGNORE INTO migracion_log (nombre) VALUES ('endurecimiento_kardex');

-- PRUEBA (debe FALLAR con el mensaje de arriba):
-- UPDATE movimiento_inventario SET cantidad = 1 WHERE id_movimiento = 1;
-- DELETE FROM movimiento_inventario WHERE id_movimiento = 1;
--
-- PARA DESHACER:
-- DROP TRIGGER trg_mov_no_update; DROP TRIGGER trg_mov_no_delete;
-- DROP TRIGGER trg_desp_no_update; DROP TRIGGER trg_desp_no_delete;
-- DROP TRIGGER trg_bit_no_update; DROP TRIGGER trg_bit_no_delete;
