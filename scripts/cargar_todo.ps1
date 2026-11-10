# Reconstruye la base "manufactura" DESDE CERO. 01_manufactura_completa.sql hace DROP DATABASE.
#   .\scripts\cargar_todo.ps1                     -> los 6 scripts obligatorios
#   .\scripts\cargar_todo.ps1 -ConEndurecimiento  -> y además sql/90_endurecimiento_opcional.sql
param([switch]$ConEndurecimiento)
. "$PSScriptRoot\lib.ps1"

$archivos = @(
  "sql/01_manufactura_completa.sql", "sql/02_funciones_crud.sql", "sql/03_mejoras_estructura.sql",
  "sql/04_datos_historicos.sql", "sql/05_mejoras_diseno.sql",
  "sql/06_modulo_aplicacion.sql")
if ($ConEndurecimiento) { $archivos += "sql/90_endurecimiento_opcional.sql" }

Esperar-Db
foreach ($f in $archivos) { Write-Host ">> Cargando $f"; Ejecutar-Sql $f }
Write-Host ">> Base cargada. Verificando..."
& "$PSScriptRoot\verificar.ps1"
