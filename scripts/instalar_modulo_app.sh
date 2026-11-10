#!/usr/bin/env bash
# ACTUALIZA una base que ya tienes (con 01..05 cargados) a la versión 2 de la página, SIN borrar datos.
# Solo ejecuta sql/06_modulo_aplicacion.sql, que únicamente agrega (usuarios, bitácora y procedimientos). Se puede repetir.
source "$(dirname "$0")/lib.sh"
esperar_db
echo ">> Instalando el módulo de la aplicación (sql/06_modulo_aplicacion.sql)"
ejecutar_sql sql/06_modulo_aplicacion.sql
exec "$(dirname "$0")/verificar.sh"
