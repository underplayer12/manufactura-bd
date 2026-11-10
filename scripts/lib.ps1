# Funciones comunes para PowerShell (Windows). Usa Docker Compose (servicio "db").
$ErrorActionPreference = "Continue"   # no tratar los avisos de stderr de mysql como error
$Raiz = Split-Path -Parent $PSScriptRoot
Set-Location $Raiz

function Esperar-Db { docker compose up -d --wait db; if ($LASTEXITCODE -ne 0) { throw "No se pudo levantar la base de datos" } }

# Ejecuta un .sql ya montado en el contenedor (ruta relativa, ej. sql/01_manufactura_completa.sql)
function Ejecutar-Sql($archivo) {
  docker compose exec -T -e MYSQL_PWD=root db mysql -uroot --default-character-set=utf8mb4 -e "source /$archivo"
  if ($LASTEXITCODE -ne 0) { throw "Fallo al ejecutar $archivo" }
}

function Consultar-Sql($sentencia) {
  docker compose exec -T -e MYSQL_PWD=root db mysql -uroot --default-character-set=utf8mb4 -N -e $sentencia
}
