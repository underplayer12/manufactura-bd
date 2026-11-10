# Manufactura — control de producción e inventarios (MySQL)

Base de datos MySQL 8.0 + página web (Flask) con acceso por usuario, roles e historial de solicitudes para una fábrica ficticia de muebles de oficina.
Proyecto de Administración de Bases de Datos / SQL.

## Arranque rápido (necesitas Docker Desktop)

**Windows (PowerShell), dentro de esta carpeta:**
```powershell
.\scripts\cargar_todo.ps1        # levanta MySQL, carga los 6 scripts y verifica (10 pruebas en OK)
docker compose up -d --build     # la página web en http://localhost:5000
```
**Linux / macOS / Git Bash:**
```bash
./scripts/cargar_todo.sh
docker compose up -d --build
```

> **Primer ingreso a la página:** usuario `admin`, clave `Admin2026!` → te obliga a cambiarla. Luego crea los usuarios en el módulo *Usuarios*.
> **Si ya tenías la base cargada (versión anterior)** y no quieres borrarla: `.\scripts\instalar_modulo_app.ps1` solo agrega lo nuevo (script 06).

> Si ya tienes un contenedor viejo `mysql-manufactura`: `docker rm -f mysql-manufactura` y repite.
> `cargar_todo` borra y reconstruye la base `manufactura` (lleva `DROP DATABASE` al inicio).

## Qué hay en cada carpeta
| Carpeta | Contenido |
|---|---|
| `sql/` | Scripts numerados que se ejecutan en orden (ver `CLAUDE.md`). `sql/pruebas/` trae `verificar.sql`, `pruebas_requisitos.sql` y `prueba_carga.sql` |
| `app/` | Página web v2 (Flask + PyMySQL; `static/` trae el HTML/JS/CSS) |
| `docs/version_1/` | La interfaz anterior (solo órdenes, sin acceso) como referencia |
| `scripts/` | `cargar_todo`, `instalar_modulo_app`, `verificar`, `probar_requisitos`, `probar_app` (versión `.ps1` y `.sh`) |
| `tools/` | `generar_historia.py`: genera `04_datos_historicos.sql` |
| `tests/` | `test_api.py`: 22 pruebas de la página contra la base real (acceso, roles, bitácora, flujo completo) |

## Conectarte con un cliente SQL
Host `127.0.0.1`, puerto **3307**, usuario `root`, clave `root`, base `manufactura`.
Consola: `docker compose exec db mysql -uroot -proot manufactura`.
La página NO usa `root`: se conecta como `app_manufactura` (solo puede ejecutar procedimientos).

## Trabajar con Claude Code
Abre esta carpeta con Claude Code: leerá `CLAUDE.md` solo (contexto, comandos, reglas y pendientes).
Ejemplos de pedidos:
- *"Carga la base desde cero, verifica y explícame qué hizo cada script."*
- *"Agrega una migración 06 que ... sin romper lo anterior, y demuéstralo con verificar."*
- *"Prepara las capturas de pruebas para el informe."*

Datos ficticios (empresas, NIT, clientes). Precios en COP.
