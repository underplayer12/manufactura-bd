# ACTUALIZA una base que ya tienes (con 01..05 cargados) a la versión 2 de la página, SIN borrar datos.
# Solo ejecuta sql/06_modulo_aplicacion.sql, que únicamente agrega (usuarios, bitácora y procedimientos). Se puede repetir.
. "$PSScriptRoot\lib.ps1"
Esperar-Db
Write-Host ">> Instalando el modulo de la aplicacion (sql/06_modulo_aplicacion.sql)"
Ejecutar-Sql "sql/06_modulo_aplicacion.sql"
& "$PSScriptRoot\verificar.ps1"
