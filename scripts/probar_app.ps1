# Corre las 22 pruebas de la aplicacion (login, roles, bitacora, flujo completo...) DENTRO del contenedor de la app.
# Dejan datos de prueba en la base: al terminar, .\scripts\cargar_todo.ps1 la deja limpia otra vez.
. "$PSScriptRoot\lib.ps1"
docker compose up -d --build
docker compose exec -T app python tests/test_api.py
