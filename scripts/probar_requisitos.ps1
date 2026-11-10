# Corre las pruebas de los 3 requisitos (R3 SÍ crea y completa una orden de 2 sillas).
. "$PSScriptRoot\lib.ps1"
Esperar-Db
Ejecutar-Sql "sql/pruebas/pruebas_requisitos.sql"
