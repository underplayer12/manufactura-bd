#!/usr/bin/env bash
# Corre las 22 pruebas de la aplicación (login, roles, bitácora, flujo completo...) DENTRO del contenedor de la app.
# Dejan datos de prueba en la base: al terminar, ./scripts/cargar_todo.sh la deja limpia otra vez.
cd "$(dirname "$0")/.."
docker compose up -d --build --wait db app 2>/dev/null || docker compose up -d --build
docker compose exec -T app python tests/test_api.py
