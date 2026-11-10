# Proyecto: base de datos de manufactura (control de producción e inventarios)

Proyecto universitario de **Administración de Bases de Datos / SQL** (Ingeniería de Sistemas, 6.º semestre,
Universidad ECCI). Grupo Forero–Ramos–Peña J. Fábrica ficticia de muebles de oficina.
Motor: **MySQL 8.0** en Docker. Interfaz web **v2**: Flask + PyMySQL con login, roles y bitácora (la v1 queda en `docs/version_1/`). Idioma de todo: **español**.

## Cómo trabajar con la persona que usa este repo
- Está **aprendiendo bases de datos**: cada vez que crees o cambies algo de SQL, **explica qué hace y por qué**
  (qué es el trigger, por qué una transacción, etc.). No entregues cambios mudos.
- Prefiere guía y explicación a recibir todo resuelto; a veces hay poco tiempo: sé directo, pero explica lo esencial.
- Antes de decir "listo", **ejecuta `scripts/verificar.*`** y reporta el resultado real.

## Los 3 requisitos del proyecto (todo cambio debe seguir cumpliéndolos)
1. **Registrar** productos, materias primas, proveedores y órdenes de producción.
2. **Consultar** el inventario disponible (`vista_inventario`, `sp_get_inventario`, `fn_max_producible`, bodegas, lotes).
3. **Actualizar automáticamente** el inventario con las operaciones de producción (`sp_completar_orden` + triggers).
Pruebas listas para capturas: `sql/pruebas/pruebas_requisitos.sql` (`scripts/probar_requisitos.*`).

## Comandos (desde la raíz del repo)
| Qué | Windows (PowerShell) | Linux/macOS/Git Bash |
|---|---|---|
| Levantar solo MySQL | `docker compose up -d --wait db` | igual |
| Reconstruir todo desde cero + verificar | `.\scripts\cargar_todo.ps1` | `./scripts/cargar_todo.sh` |
| Solo verificar (no cambia datos) | `.\scripts\verificar.ps1` | `./scripts/verificar.sh` |
| Pruebas de los 3 requisitos | `.\scripts\probar_requisitos.ps1` | `./scripts/probar_requisitos.sh` |
| Interfaz web (http://localhost:5000) | `docker compose up -d --build` | igual |
| Actualizar una base que ya tienes a la v2 (sin borrar datos) | `.\scripts\instalar_modulo_app.ps1` | `./scripts/instalar_modulo_app.sh` |
| Pruebas de la app v2 (22, contra MySQL real, dentro del contenedor) | `.\scripts\probar_app.ps1` | `./scripts/probar_app.sh` |
| Pruebas de la app desde el host (sin Docker para la app) | `$env:DB_HOST="127.0.0.1"; $env:DB_PORT="3307"; python tests\test_api.py` | `DB_HOST=127.0.0.1 DB_PORT=3307 python tests/test_api.py` |
| Consola SQL | `docker compose exec db mysql -uroot -proot manufactura` | igual |

Sin Docker: define `MYSQL_CMD="mysql -uroot -proot -h127.0.0.1 -P3307 --default-character-set=utf8mb4"` y usa los `.sh`.
MySQL expone el puerto **3307** del computador (contenedor `mysql-manufactura`, usuario `root`, clave `root`).
Si ya existe un contenedor viejo con ese nombre: `docker rm -f mysql-manufactura` antes de `docker compose up`.

## Orden de los scripts SQL (carpeta `sql/`)
| Archivo | Qué hace | Notas |
|---|---|---|
| `01_manufactura_completa.sql` | Esquema base (7 tablas), trigger de stock, `sp_completar_orden`, vista, datos iniciales | **Empieza con `DROP DATABASE manufactura`** |
| `02_funciones_crud.sql` | 11 procedimientos GET/crear/cancelar + `fn_max_producible` | |
| `03_mejoras_estructura.sql` | Índices, CHECK de fechas, `costo_unitario`, tabla `despacho`, kardex paginado, vistas de reporte | Solo agrega; idempotente |
| `04_datos_historicos.sql` | +6 proveedores, +8 materias, +4 productos y 12 meses de operación | **Generado** por `tools/generar_historia.py` (no editar a mano) |
| `05_mejoras_diseno.sql` | Bodegas, lotes FIFO + trazabilidad, historial de precios, clientes y pedidos de venta | Solo agrega; idempotente; exige 03 y que NO esté el 90 |
| `06_modulo_aplicacion.sql` | Para la página v2: tablas `usuario` y `bitacora`, columna `activo` en producto/materia, ~50 procedimientos (CRUD, reportes, usuarios), usuario MySQL `app_manufactura` (solo EXECUTE) | Solo agrega; idempotente; exige 05 |
| `90_endurecimiento_opcional.sql` | Kardex, despachos y bitácora inmutables (triggers) | **Siempre al final**; cierra una vulnerabilidad que el informe debe demostrar antes |

Regenerar el histórico: `python tools/generar_historia.py sql/04_datos_historicos.sql` (determinista, semilla fija).

## Reglas para modificar la base (importante)
- **No rompas lo anterior.** Cambios nuevos = **archivo nuevo** numerado (`06_...sql`) que solo AGREGA
  (`CREATE TABLE IF NOT EXISTS`, columnas `NULL`, triggers con `FOLLOWS`/`PRECEDES`, `INSERT IGNORE`).
  No edites `01` ni `02` salvo un bug real. Cada migración debe ser **idempotente** y registrarse en `migracion_log`.
- Nunca pongas `DROP TABLE`/`DROP DATABASE` en una migración. (`DROP PROCEDURE/TRIGGER IF EXISTS` para recrear sí.)
- Después de cualquier cambio: `cargar_todo` desde cero **y** `verificar`; confirma además que **OP-9 falla** y **OP-10 funciona**
  (ver abajo) y que `tests/test_api.py` sigue pasando.
- Ejecuta scripts con DELIMITER vía cliente `mysql` (`source`), **no** con DBeaver (daba errores de conexión y de ejecución parcial).

## Arquitectura en 30 segundos
- **Fuente de verdad del stock = kardex** (`movimiento_inventario`). `materia_prima.stock_actual`, `stock_bodega` y `lote` los mantienen **triggers** (híbrido).
- Trigger `trg_movimiento_costo` (BEFORE, pone precio) → `trg_mov_bodega_lote` (BEFORE, bodega y lote)
  → `trg_movimiento_actualiza_stock` (AFTER, total) → `trg_mov_distribuye` (AFTER, bodega + consumo FIFO con `sp_consumir_lotes`).
- `sp_completar_orden(id)`: transacción única (SALIDA por receta + suma producto + cierra orden); con `EXIT HANDLER` → `ROLLBACK` + `RESIGNAL`.
  Si falta materia, el `CHECK ck_mp_stock_no_negativo` falla (error 3819) y no queda nada a medias.
- Ventas: `cliente`, `pedido_venta`, `pedido_venta_detalle`; `sp_despachar_pedido` es todo-o-nada y mueve `despacho` (que baja el stock de producto por trigger).
- Precios: `proveedor_materia_prima` guarda el precio de hoy; `historial_precio` lo vigente por fechas (lo llenan triggers).
- **Interfaz v2** (`app/`): `app.py` (rutas + login + bitácora), `bd.py` (conexión, errores), `static/` (nucleo.js, vistas.js, app.js, app.css; JS sin frameworks).
  Solo llama procedimientos (`CALL sp_...`) con el usuario MySQL `app_manufactura`, que **solo puede ejecutar procedimientos** (ya no usa `root`).
  `sp_actualizar_orden`/`sp_eliminar_orden` ahora viven en `06` (antes la app los creaba al arrancar).
- Acceso: tres roles — ADMIN (todo), OPERARIO (órdenes, compras, traslados, ventas, clientes), CONSULTA (solo lectura). Clave con hash (werkzeug),
  primer ingreso obliga a cambiarla, bloqueo 5 min tras 5 intentos fallidos, cookie HttpOnly+SameSite, cabecera `X-Requested-With` obligatoria en escrituras (anti-CSRF).
  El usuario `admin` lo crea la app sola la primera vez (clave `ADMIN_CLAVE_INICIAL`, por defecto `Admin2026!`).
- Bitácora (`bitacora`): cada solicitud que NO es lectura, más logins, accesos denegados y descargas de reportes; guarda usuario, rol, acción, módulo, referencia, detalle, resultado, ruta, estado HTTP, parámetros (sin claves) e IP.
- Productos y materias primas **se desactivan, no se borran** (`activo`).
- Regla al agregar una ruta: validar entrada con los ayudantes de `app.py` (`texto/entero/decimal`), llamar UN procedimiento, fijar `g.ref`/`g.detalle` para la bitácora, y añadir su prueba en `tests/test_api.py`.

## Pruebas de aceptación que deben seguir cumpliéndose
- **OP-9** (20 escritorios) **debe fallar**: necesita 40 MDF y hay 32 → error 3819, nada cambia. **OP-10** (10 mesas) **debe funcionar**.
  (Solo son válidas en una base recién cargada: una vez se completa una orden o se compra MDF, el estado cambia.)
- Stock original tras `01`+`02`: lámina 191, MDF 32 (ambos en REABASTECER); `03`–`05` no deben alterar el stock de las 10 materias originales ni de los 5 productos originales.
- `scripts/verificar.*` → 10 filas `OK` (la 10.ª comprueba que el módulo de la aplicación está instalado).
- `tests/test_api.py` → 22 pruebas OK (dejan datos de prueba: `cargar_todo` deja la base limpia otra vez).

## Trampas conocidas (no repetir)
- **Error 1442** si un `INSERT … SELECT FROM materia_prima/producto` dispara un trigger que actualiza esa misma tabla → buscar ids en variables antes del `INSERT … VALUES`.
- `ROW_COUNT()` vale 0 si un `UPDATE` no cambia valores → no usarlo para detectar "no existe"; usar `NOT EXISTS`.
- Un `SELECT … INTO` sin filas dispara `NOT FOUND` y desordena un bucle con cursor → usar `SET v = (SELECT … LIMIT 1)`.
- Un trigger no puede alterar la tabla que está insertando; se pueden crear varios triggers por evento con `FOLLOWS`.
- Si aparece "Public Key Retrieval is not allowed": `ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';` (el compose ya lo evita).
- CHECK solo se aplica desde MySQL 8.0.16.

## Pendiente del proyecto (segundo corte = 50 % de la nota)
El profesor pidió: **darle un punto de vista crítico a la pregunta**, un **informe con pruebas y diagnóstico técnico**,
**3 vulnerabilidades** y **3 ventajas** de la base de datos.
- [ ] Capturas de pruebas: OP-9 fallando, OP-10 funcionando, `pruebas_requisitos`, conciliaciones.
- [ ] 3 vulnerabilidades con evidencia antes/después: (1) `UPDATE materia_prima SET stock_actual=…` directo rompe la conciliación con el kardex;
      (2) modificar/borrar movimientos del kardex (cerrada por `90_endurecimiento_opcional.sql`; en `05` el `DELETE` de salidas ya choca con FK);
      (3) `root` con todos los permisos: **la v1 de la app entraba como `root`** (ver `docs/version_1/app_v1.py`); la v2 ya usa `app_manufactura` (solo EXECUTE). Para la evidencia "antes/después": antes = conexión como root puede `DROP`/`DELETE`; después = `app_manufactura` recibe error 1142 (`tests/test_api.py::test_bd_con_minimo_privilegio`).
- [ ] 3 ventajas (p. ej. atomicidad de `sp_completar_orden`, integridad con CHECK/FK, trazabilidad por lote y kardex auditable).
- [ ] Informe final. Documentación ya existente: documento "Claude Docs" del proyecto (enlace en la conversación original).
- [x] Hecho en v2: pantalla de ventas, login/roles, bitácora, usuario de BD de mínimo privilegio, manual de usuario.
- [ ] Ideas opcionales: servidor de producción (gunicorn + HTTPS), paginación de órdenes, prueba de carga (`sql/pruebas/prueba_carga.sql`, usa la copia `manufactura_carga`).

Datos: nombres de empresas, NIT y clientes son **ficticios**. Precios en COP.
