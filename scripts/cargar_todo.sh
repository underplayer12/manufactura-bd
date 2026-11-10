#!/usr/bin/env bash
# Reconstruye la base "manufactura" DESDE CERO con los 6 scripts obligatorios, en orden.
# ATENCIÓN: 01_manufactura_completa.sql hace DROP DATABASE manufactura (borra los datos actuales).
#   Uso:  ./scripts/cargar_todo.sh            (con Docker)
#         MYSQL_CMD="mysql -uroot -proot ..." ./scripts/cargar_todo.sh   (sin Docker)
# Con --con-endurecimiento también carga sql/90_endurecimiento_opcional.sql al final.
source "$(dirname "$0")/lib.sh"

ARCHIVOS=(
  sql/01_manufactura_completa.sql
  sql/02_funciones_crud.sql
  sql/03_mejoras_estructura.sql
  sql/04_datos_historicos.sql
  sql/05_mejoras_diseno.sql
  sql/06_modulo_aplicacion.sql
)
if [ "${1:-}" = "--con-endurecimiento" ]; then ARCHIVOS+=(sql/90_endurecimiento_opcional.sql); fi

esperar_db
for f in "${ARCHIVOS[@]}"; do
  echo ">> Cargando $f"
  ejecutar_sql "$f"
done
echo ">> Base cargada. Verificando..."
exec "$(dirname "$0")/verificar.sh"
