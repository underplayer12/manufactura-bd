#!/usr/bin/env bash
# Funciones comunes. Dos modos:
#   - Docker (por defecto): usa el servicio "db" de docker-compose.yml
#   - Local: si defines MYSQL_CMD, por ejemplo
#       MYSQL_CMD="mysql -uroot -proot -h127.0.0.1 -P3307 --default-character-set=utf8mb4"
#     se usa ese cliente mysql directamente (útil si no hay Docker).
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

# Ejecuta un archivo .sql (ruta relativa a la raíz del proyecto, ej. sql/01_...sql)
ejecutar_sql() {
  local archivo="$1"
  if [ -n "${MYSQL_CMD:-}" ]; then
    $MYSQL_CMD < "$archivo"
  else
    docker compose exec -T -e MYSQL_PWD=root db mysql -uroot --default-character-set=utf8mb4 \
      -e "source /$archivo"
  fi
}

# Ejecuta una sentencia suelta y devuelve el texto sin cabeceras
consultar() {
  if [ -n "${MYSQL_CMD:-}" ]; then
    $MYSQL_CMD -N -e "$1"
  else
    docker compose exec -T -e MYSQL_PWD=root db mysql -uroot --default-character-set=utf8mb4 -N -e "$1"
  fi
}

esperar_db() {
  if [ -z "${MYSQL_CMD:-}" ]; then
    docker compose up -d --wait db
  fi
}
