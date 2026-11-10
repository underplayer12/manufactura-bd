#!/usr/bin/env bash
# Corre las pruebas de los 3 requisitos (R3 SÍ crea y completa una orden de 2 sillas).
source "$(dirname "$0")/lib.sh"
esperar_db
ejecutar_sql sql/pruebas/pruebas_requisitos.sql
