#!/usr/bin/env bash
# Corre sql/pruebas/verificar.sql (solo lee). Sale con código 1 si alguna prueba dice FALLA.
source "$(dirname "$0")/lib.sh"
esperar_db
salida="$(ejecutar_sql sql/pruebas/verificar.sql)"
echo "$salida"
if echo "$salida" | grep -q "FALLA"; then
  echo "RESULTADO: HAY PRUEBAS QUE FALLAN"; exit 1
fi
echo "RESULTADO: TODO OK"
