# Corre sql/pruebas/verificar.sql (solo lee). Termina con código 1 si alguna prueba dice FALLA.
. "$PSScriptRoot\lib.ps1"
Esperar-Db
$salida = Ejecutar-Sql "sql/pruebas/verificar.sql"
$salida | ForEach-Object { Write-Host $_ }
if (($salida | Out-String) -match "FALLA") { Write-Host "RESULTADO: HAY PRUEBAS QUE FALLAN"; exit 1 }
Write-Host "RESULTADO: TODO OK"
