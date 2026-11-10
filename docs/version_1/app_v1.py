"""
Interfaz sencilla para gestionar ordenes de produccion (CRUD) de la base `manufactura`.

Como esta armado (de arriba abajo):
  1. Conexion a MySQL (PyMySQL).
  2. Dos procedimientos nuevos (editar y eliminar orden) que la app crea sola al iniciar.
  3. Rutas /api/...: cada una llama a un procedimiento de la base y devuelve JSON.
  4. La pagina (HTML + CSS + JavaScript) que ve el usuario.

Cada operacion del CRUD se mapea a un procedimiento de la base:
  Crear     -> sp_crear_orden
  Leer      -> sp_get_ordenes, sp_get_inventario
  Actualizar-> sp_actualizar_orden (editar cantidad), sp_completar_orden, sp_cancelar_orden
  Eliminar  -> sp_eliminar_orden
"""
import os
from datetime import date, datetime
from decimal import Decimal

import pymysql
from flask import Flask, Response, jsonify, request

# ---------------------------------------------------------------------------
# 1. Conexion a la base de datos
# ---------------------------------------------------------------------------
# Dentro de Docker, "host.docker.internal" es tu computador; el puerto 3307 es el
# que publicamos para el contenedor mysql-manufactura.
DB = dict(
    host=os.environ.get("DB_HOST", "host.docker.internal"),
    port=int(os.environ.get("DB_PORT", "3307")),
    user=os.environ.get("DB_USER", "root"),
    password=os.environ.get("DB_PASSWORD", "root"),
    database="manufactura",
    charset="utf8mb4",
    autocommit=True,
    cursorclass=pymysql.cursors.DictCursor,
)

app = Flask(__name__)


def conectar():
    return pymysql.connect(**DB)


def limpiar(valor):
    """Convierte tipos de MySQL (Decimal, fechas) a algo que JSON entienda."""
    if isinstance(valor, Decimal):
        return int(valor) if valor == valor.to_integral_value() else float(valor)
    if isinstance(valor, (datetime, date)):
        return valor.strftime("%Y-%m-%d %H:%M")
    return valor


def filas(cursor):
    return [{k: limpiar(v) for k, v in fila.items()} for fila in cursor.fetchall()]


# ---------------------------------------------------------------------------
# 2. Procedimientos que agrega esta interfaz
# ---------------------------------------------------------------------------
PROCEDIMIENTOS = [
    (
        "sp_actualizar_orden",
        """
        CREATE PROCEDURE sp_actualizar_orden(IN p_id_orden INT, IN p_cantidad INT)
        BEGIN
          IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad debe ser mayor que cero';
          END IF;
          IF NOT EXISTS (SELECT 1 FROM orden_produccion
                          WHERE id_orden = p_id_orden AND estado = 'PENDIENTE') THEN
            SIGNAL SQLSTATE '45000'
              SET MESSAGE_TEXT = 'Solo se puede editar una orden que exista y este pendiente';
          END IF;
          UPDATE orden_produccion SET cantidad = p_cantidad WHERE id_orden = p_id_orden;
        END
        """,
    ),
    (
        "sp_eliminar_orden",
        """
        CREATE PROCEDURE sp_eliminar_orden(IN p_id_orden INT)
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM orden_produccion
                          WHERE id_orden = p_id_orden
                            AND estado IN ('PENDIENTE', 'CANCELADA')) THEN
            SIGNAL SQLSTATE '45000'
              SET MESSAGE_TEXT = 'Solo se pueden eliminar ordenes pendientes o canceladas';
          END IF;
          DELETE FROM orden_produccion WHERE id_orden = p_id_orden;
        END
        """,
    ),
]

LISTO = False  # se vuelve True cuando los procedimientos ya existen


def preparar(cursor):
    for nombre, sql in PROCEDIMIENTOS:
        cursor.execute("DROP PROCEDURE IF EXISTS " + nombre)
        cursor.execute(sql)


def ejecutar(sql, params=(), devolver=False):
    """Abre una conexion, ejecuta una instruccion y la cierra."""
    global LISTO
    conexion = conectar()
    try:
        with conexion.cursor() as cursor:
            if not LISTO:
                preparar(cursor)
                LISTO = True
            cursor.execute(sql, params)
            return filas(cursor) if devolver else None
    finally:
        conexion.close()


# ---------------------------------------------------------------------------
# 3. Rutas de la API
# ---------------------------------------------------------------------------
CODIGOS_CONEXION = {1045, 1049, 2002, 2003, 2006, 2013}

MENSAJES = {
    3819: "No hay materia prima suficiente para completar esta orden. "
          "No se descontó nada. Mira la bodega a la derecha y registra una compra, "
          "o baja la cantidad con «Editar».",
    1451: "No se puede eliminar: hay datos que dependen de este registro.",
    1452: "El producto elegido no existe.",
    1305: "Falta un procedimiento en la base. Carga de nuevo los dos archivos .sql.",
}


def responder(accion, creado=False):
    """Ejecuta `accion` y traduce los errores de la base a mensajes claros."""
    try:
        datos = accion()
        return jsonify(ok=True, datos=datos), (201 if creado else 200)
    except pymysql.MySQLError as error:
        codigo = error.args[0] if error.args and isinstance(error.args[0], int) else 0
        if codigo in CODIGOS_CONEXION:
            return jsonify(
                ok=False,
                conexion=False,
                mensaje="No se pudo conectar con la base «manufactura». Revisa que el "
                        "contenedor mysql-manufactura esté encendido (docker ps) y que "
                        "hayas cargado manufactura_completa.sql.",
            ), 503
        if codigo == 1644:  # error lanzado por la propia base con SIGNAL
            return jsonify(ok=False, mensaje=error.args[1]), 400
        mensaje = MENSAJES.get(codigo, "La base de datos devolvió un error (código %s)." % codigo)
        return jsonify(ok=False, mensaje=mensaje), 400


@app.get("/api/productos")
def productos():
    return responder(lambda: ejecutar(
        "SELECT id_producto, codigo, nombre, stock_actual, "
        "fn_max_producible(id_producto) AS max_producible "
        "FROM producto ORDER BY nombre",
        devolver=True,
    ))


@app.get("/api/inventario")
def inventario():
    return responder(lambda: ejecutar("CALL sp_get_inventario()", devolver=True))


@app.get("/api/ordenes")
def ordenes():
    return responder(lambda: ejecutar("CALL sp_get_ordenes(%s)", (None,), devolver=True))


@app.post("/api/ordenes")
def crear_orden():
    datos = request.get_json(silent=True) or {}
    try:
        id_producto = int(datos.get("id_producto"))
        cantidad = int(datos.get("cantidad"))
    except (TypeError, ValueError):
        return jsonify(ok=False, mensaje="Elige un producto y escribe una cantidad válida."), 400
    return responder(
        lambda: ejecutar("CALL sp_crear_orden(%s, %s)", (id_producto, cantidad), devolver=True),
        creado=True,
    )


@app.put("/api/ordenes/<int:id_orden>")
def editar_orden(id_orden):
    datos = request.get_json(silent=True) or {}
    try:
        cantidad = int(datos.get("cantidad"))
    except (TypeError, ValueError):
        return jsonify(ok=False, mensaje="Escribe una cantidad válida."), 400
    return responder(lambda: ejecutar("CALL sp_actualizar_orden(%s, %s)", (id_orden, cantidad)))


@app.post("/api/ordenes/<int:id_orden>/completar")
def completar_orden(id_orden):
    return responder(lambda: ejecutar("CALL sp_completar_orden(%s)", (id_orden,)))


@app.post("/api/ordenes/<int:id_orden>/cancelar")
def cancelar_orden(id_orden):
    return responder(lambda: ejecutar("CALL sp_cancelar_orden(%s)", (id_orden,)))


@app.delete("/api/ordenes/<int:id_orden>")
def eliminar_orden(id_orden):
    return responder(lambda: ejecutar("CALL sp_eliminar_orden(%s)", (id_orden,)))


# ---------------------------------------------------------------------------
# 4. La pagina
# ---------------------------------------------------------------------------
PAGINA = r"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Órdenes de producción</title>
<style>
:root{
  --fondo:#EEF1F3; --panel:#FFFFFF; --tinta:#16202A; --acero:#55616B;
  --linea:#CBD3D9; --linea-suave:#E4E9ED;
  --amarillo:#F5B800; --amarillo-osc:#DCA400; --amarillo-claro:#FFF1C2; --amarillo-texto:#5C4300;
  --verde:#1E6B3A; --verde-claro:#E3F1E7; --rojo:#B3261E; --rojo-claro:#FBE9E7;
  --titulos:"Bahnschrift","DIN Alternate","Arial Narrow",system-ui,sans-serif;
  --cuerpo:"Segoe UI",system-ui,-apple-system,Roboto,sans-serif;
}
*{box-sizing:border-box}
[hidden]{display:none !important}
body{margin:0;background:var(--fondo);color:var(--tinta);font-family:var(--cuerpo);font-size:16px;line-height:1.5}
.contenedor{max-width:1120px;margin:0 auto;padding:0 20px}

/* Cabecera */
.cabecera{background:var(--tinta);color:#fff;border-bottom:4px solid var(--amarillo);padding:22px 0}
.cabecera h1{margin:0;font-family:var(--titulos);font-weight:600;font-size:1.8rem;letter-spacing:.01em}
.cabecera p{margin:4px 0 0;color:#C9D2D9}
main{padding-top:20px;padding-bottom:56px}

/* Botones */
.btn{font:inherit;font-weight:600;color:var(--tinta);background:#fff;border:1.5px solid var(--tinta);border-radius:4px;
  padding:8px 16px;min-height:42px;cursor:pointer}
.btn:hover{background:var(--linea-suave)}
.btn.primario{background:var(--amarillo);border-color:var(--tinta)}
.btn.primario:hover{background:var(--amarillo-osc)}
.btn.peligro{background:var(--rojo);border-color:var(--rojo);color:#fff}
.btn.peligro:hover{background:#8f1d17}
.btn.peq{min-height:34px;padding:4px 12px;font-size:.92rem}
.btn:disabled{opacity:.55;cursor:wait}
:focus-visible{outline:3px solid var(--tinta);outline-offset:2px}

/* Aviso de conexion y guia */
.alerta{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap;
  background:var(--rojo-claro);border:1.5px solid var(--rojo);color:#6b1510;border-radius:4px;padding:12px 16px;margin-bottom:20px}
.guia{background:var(--amarillo-claro);border:1.5px solid var(--amarillo);border-radius:4px;padding:12px 16px;margin-bottom:20px}
.guia summary{cursor:pointer;font-weight:600}
.guia ol{margin:10px 0 2px;padding-left:22px}
.guia li{margin:4px 0}

/* Estructura */
.rejilla{display:grid;gap:20px;grid-template-columns:minmax(0,1fr);align-items:start}
@media(min-width:960px){.rejilla{grid-template-columns:minmax(0,1fr) 340px}}
.panel{background:var(--panel);border:1px solid var(--linea);border-radius:6px;padding:20px}
.barra{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
h2{margin:0;font-family:var(--titulos);font-weight:600;font-size:1.3rem}
h3{margin:22px 0 0;font-family:var(--titulos);font-weight:600;font-size:1.02rem}
.nota{color:var(--acero);font-size:.9rem;margin:4px 0 0}

/* Filtros */
.filtros{display:flex;gap:8px;flex-wrap:wrap;margin:16px 0 8px}
.filtro{font:inherit;color:var(--tinta);background:#fff;border:1.5px solid var(--linea);border-radius:4px;padding:6px 14px;cursor:pointer}
.filtro:hover{border-color:var(--tinta)}
.filtro[aria-pressed="true"]{background:var(--tinta);border-color:var(--tinta);color:#fff;font-weight:600}

/* Tabla de ordenes */
table{width:100%;border-collapse:collapse}
th{font-size:.85rem;font-weight:600;color:var(--acero);text-align:left;padding:8px 10px;border-bottom:1.5px solid var(--tinta)}
td{padding:12px 10px;border-bottom:1px solid var(--linea-suave);vertical-align:middle}
.der{text-align:right}
.acciones{white-space:nowrap;text-align:right}
.op{display:inline-block;font-family:var(--titulos);font-weight:700;font-size:1.05rem;border:1.5px solid var(--tinta);border-radius:4px;padding:1px 8px}
.estado{display:inline-block;font-size:.88rem;font-weight:600;border:1px solid;border-radius:4px;padding:1px 9px}
.estado.pendiente{background:var(--amarillo-claro);border-color:var(--amarillo);color:var(--amarillo-texto)}
.estado.completada{background:var(--verde-claro);border-color:#9CC9A9;color:var(--verde)}
.estado.cancelada{background:var(--linea-suave);border-color:var(--linea);color:var(--acero)}
.vacio{margin:20px 0 4px;color:var(--acero)}
.nueva td,.cambio{animation:resaltar 3s ease-out}
@keyframes resaltar{from{background:var(--amarillo-claro)}to{background:transparent}}
@media(prefers-reduced-motion:reduce){.nueva td,.cambio{animation:none}}

/* Menu "Mas" */
details.mas{display:inline-block;position:relative;margin-left:4px}
details.mas>summary{list-style:none;display:inline-block}
details.mas>summary::-webkit-details-marker{display:none}
.menu{position:absolute;right:0;top:100%;margin-top:4px;z-index:5;min-width:180px;background:#fff;border:1.5px solid var(--tinta);
  border-radius:4px;padding:4px;box-shadow:0 8px 20px rgba(22,32,42,.18);text-align:left}
.menu button{display:block;width:100%;text-align:left;font:inherit;background:none;border:0;border-radius:3px;padding:9px 12px;cursor:pointer}
.menu button:hover{background:var(--linea-suave)}
.menu .rojo{color:var(--rojo);font-weight:600}

/* Bodega */
.lista{list-style:none;margin:8px 0 0;padding:0}
.lista li{display:flex;justify-content:space-between;gap:10px;padding:9px 6px;border-bottom:1px solid var(--linea-suave)}
.lista .nombre{display:block}
.lista .minimo{display:block;color:var(--acero);font-size:.82rem}
.cifra{text-align:right;white-space:nowrap;font-family:var(--titulos);font-size:1.02rem}
.cifra .reponer{display:block;font-family:var(--cuerpo);font-size:.8rem;font-weight:600;color:var(--amarillo-texto);
  background:var(--amarillo-claro);border:1px solid var(--amarillo);border-radius:4px;padding:0 6px;margin-top:2px}

/* Ventanas (dialog) */
dialog{border:0;border-radius:6px;padding:24px;width:calc(100% - 32px);max-width:460px;color:var(--tinta);box-shadow:0 20px 50px rgba(22,32,42,.35)}
dialog::backdrop{background:rgba(22,32,42,.55)}
dialog h3{margin:0 0 6px;font-size:1.25rem}
dialog p{margin:8px 0 0}
label{display:block;font-weight:600;margin:16px 0 6px}
select,input[type=number]{width:100%;font:inherit;min-height:44px;padding:8px 12px;background:#fff;border:1.5px solid var(--tinta);border-radius:4px}
.ayuda{margin:12px 0 0;color:var(--acero);font-size:.93rem;min-height:1.4em}
.ayuda.aviso{color:var(--amarillo-texto);background:var(--amarillo-claro);border:1px solid var(--amarillo);border-radius:4px;padding:8px 10px}
.error-form{margin:12px 0 0;color:var(--rojo);font-weight:600}
.pie{display:flex;justify-content:flex-end;gap:10px;margin-top:22px}

/* Avisos emergentes */
#avisos{position:fixed;left:50%;bottom:20px;transform:translateX(-50%);z-index:50;display:grid;gap:8px;width:min(560px,calc(100% - 32px))}
.aviso-flotante{padding:12px 16px;border-radius:4px;color:#fff;background:var(--tinta);box-shadow:0 8px 20px rgba(22,32,42,.3)}
.aviso-flotante.ok{background:var(--verde)}
.aviso-flotante.error{background:var(--rojo)}
.solo-lectores{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}

/* Pantallas pequenas: cada fila se vuelve una ficha */
@media(max-width:700px){
  thead{display:none}
  table,tbody,tr,td{display:block;width:100%}
  tr{border:1.5px solid var(--linea);border-radius:6px;padding:10px 12px;margin-bottom:12px}
  td{border:0;padding:4px 0}
  td[data-etiqueta]::before{content:attr(data-etiqueta) ": ";color:var(--acero);font-size:.85rem}
  .der,.acciones{text-align:left}
  td.acciones{padding-top:10px}
}
</style>
</head>
<body>
<header class="cabecera">
  <div class="contenedor">
    <h1>Órdenes de producción</h1>
    <p>Crea, completa, edita o elimina órdenes. La bodega se actualiza sola.</p>
  </div>
</header>

<main class="contenedor">
  <div id="banner" class="alerta" role="alert" hidden>
    <span id="bannerTexto"></span>
    <button class="btn peq" id="btnReintentar" type="button">Reintentar</button>
  </div>

  <details class="guia" id="guia" open>
    <summary>¿Primera vez? Así se usa, en 3 pasos</summary>
    <ol>
      <li><strong>Crea</strong> una orden con el botón «Nueva orden».</li>
      <li><strong>Complétala</strong> cuando quieras fabricar: se gasta la materia prima necesaria.</li>
      <li><strong>Mira la bodega</strong> a la derecha: lo que cambió se resalta unos segundos.</li>
    </ol>
  </details>

  <div class="rejilla">
    <section class="panel" aria-labelledby="tOrdenes">
      <div class="barra">
        <h2 id="tOrdenes">Órdenes</h2>
        <button class="btn primario" id="btnNueva" type="button">Nueva orden</button>
      </div>

      <div class="filtros" role="group" aria-label="Filtrar órdenes por estado">
        <button class="filtro" type="button" data-filtro="" aria-pressed="true">Todas <span id="nTodas"></span></button>
        <button class="filtro" type="button" data-filtro="PENDIENTE" aria-pressed="false">Pendientes <span id="nPendiente"></span></button>
        <button class="filtro" type="button" data-filtro="COMPLETADA" aria-pressed="false">Completadas <span id="nCompletada"></span></button>
        <button class="filtro" type="button" data-filtro="CANCELADA" aria-pressed="false">Canceladas <span id="nCancelada"></span></button>
      </div>

      <table>
        <caption class="solo-lectores">Lista de órdenes de producción</caption>
        <thead>
          <tr><th>Orden</th><th>Producto</th><th class="der">Cantidad</th><th>Estado</th><th>Creada</th><th class="der">Acciones</th></tr>
        </thead>
        <tbody id="cuerpo"></tbody>
      </table>
      <p id="vacio" class="vacio" hidden>Todavía no hay órdenes en esta vista. Crea la primera con «Nueva orden».</p>
    </section>

    <aside class="panel" aria-labelledby="tBodega">
      <h2 id="tBodega">Bodega</h2>
      <p class="nota">Se actualiza sola cuando completas una orden.</p>
      <h3>Materia prima</h3>
      <ul class="lista" id="listaMP"></ul>
      <h3>Producto terminado</h3>
      <ul class="lista" id="listaPR"></ul>
    </aside>
  </div>
</main>

<dialog id="dlgOrden" aria-labelledby="oTitulo">
  <form id="frmOrden" novalidate>
    <h3 id="oTitulo">Nueva orden</h3>
    <label for="fProducto">Producto</label>
    <select id="fProducto" required></select>
    <label for="fCantidad">Cantidad a fabricar</label>
    <input id="fCantidad" type="number" min="1" step="1" inputmode="numeric" value="1" required>
    <p id="fAyuda" class="ayuda"></p>
    <p id="fError" class="error-form" role="alert" hidden></p>
    <div class="pie">
      <button type="button" class="btn" id="oVolver">Volver</button>
      <button type="submit" class="btn primario" id="oGuardar">Crear orden</button>
    </div>
  </form>
</dialog>

<dialog id="dlgConfirmar" aria-labelledby="cTitulo">
  <form method="dialog">
    <h3 id="cTitulo"></h3>
    <p id="cTexto"></p>
    <div class="pie">
      <button value="volver" class="btn" formnovalidate>Volver</button>
      <button value="ok" class="btn primario" id="cOk">Aceptar</button>
    </div>
  </form>
</dialog>

<div id="avisos" role="status" aria-live="polite"></div>

<script>
// ---------------------------------------------------------------------------
// Estado de la pagina: aqui se guardan los datos que llegan de la base.
// ---------------------------------------------------------------------------
const estado = { ordenes: [], productos: [], inventario: [], filtro: '', previo: null, cambios: new Set(), nueva: null, edicion: null };

const $ = (selector) => document.querySelector(selector);
const esc = (t) => String(t ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const formatoNum = new Intl.NumberFormat('es-CO', { maximumFractionDigits: 3 });
const fecha = (f) => {
  if (!f) return '—';
  const [dia, hora] = f.split(' ');
  const [a, m, d] = dia.split('-');
  return d + '/' + m + '/' + a + ' ' + hora;
};

// ---------------------------------------------------------------------------
// Hablar con el servidor (las rutas /api/... de app.py)
// ---------------------------------------------------------------------------
async function api(url, opciones = {}) {
  let respuesta;
  try {
    respuesta = await fetch(url, { headers: { 'Content-Type': 'application/json' }, ...opciones });
  } catch (e) {
    throw { mensaje: 'No se pudo hablar con la aplicación. Revisa que la ventana de PowerShell con el comando de Docker siga abierta.', conexion: true };
  }
  let cuerpo = {};
  try { cuerpo = await respuesta.json(); } catch (e) { /* sin cuerpo */ }
  if (!respuesta.ok || !cuerpo.ok) {
    throw { mensaje: cuerpo.mensaje || 'Algo salió mal. Inténtalo de nuevo.', conexion: cuerpo.conexion === false };
  }
  return cuerpo.datos;
}

// ---------------------------------------------------------------------------
// Cargar y dibujar
// ---------------------------------------------------------------------------
async function cargarTodo() {
  try {
    const [ordenes, productos, inventario] = await Promise.all([
      api('/api/ordenes'), api('/api/productos'), api('/api/inventario'),
    ]);
    marcarCambios(inventario, productos);
    estado.ordenes = ordenes;
    estado.productos = productos;
    estado.inventario = inventario;
    $('#banner').hidden = true;
    pintar();
  } catch (e) {
    mostrarBanner(e.mensaje);
  }
}

// Compara con la carga anterior para resaltar lo que cambio en la bodega.
function marcarCambios(inventario, productos) {
  const ahora = { mp: {}, pr: {} };
  inventario.forEach((m) => { ahora.mp[m.codigo] = m.stock_actual; });
  productos.forEach((p) => { ahora.pr[p.codigo] = p.stock_actual; });
  estado.cambios = new Set();
  if (estado.previo) {
    Object.keys(ahora.mp).forEach((c) => { if (ahora.mp[c] !== estado.previo.mp[c]) estado.cambios.add('mp:' + c); });
    Object.keys(ahora.pr).forEach((c) => { if (ahora.pr[c] !== estado.previo.pr[c]) estado.cambios.add('pr:' + c); });
  }
  estado.previo = ahora;
}

function pintar() {
  pintarFiltros();
  pintarOrdenes();
  pintarBodega();
}

function pintarFiltros() {
  const cuenta = (e) => estado.ordenes.filter((o) => o.estado === e).length;
  $('#nTodas').textContent = '(' + estado.ordenes.length + ')';
  $('#nPendiente').textContent = '(' + cuenta('PENDIENTE') + ')';
  $('#nCompletada').textContent = '(' + cuenta('COMPLETADA') + ')';
  $('#nCancelada').textContent = '(' + cuenta('CANCELADA') + ')';
}

const NOMBRE_ESTADO = { PENDIENTE: 'Pendiente', COMPLETADA: 'Completada', CANCELADA: 'Cancelada' };
const AYUDA_ESTADO = {
  PENDIENTE: 'Todavía no se fabrica ni se gasta materia prima.',
  COMPLETADA: 'Ya se fabricó y se descontó la materia prima.',
  CANCELADA: 'Se anuló antes de fabricarla.',
};

function accionesDe(o) {
  const id = o.id_orden;
  if (o.estado === 'PENDIENTE') {
    return '<button class="btn primario peq" type="button" data-accion="completar" data-id="' + id + '">Completar</button> '
      + '<button class="btn peq" type="button" data-accion="editar" data-id="' + id + '">Editar</button>'
      + '<details class="mas"><summary class="btn peq" aria-label="Más acciones de la orden OP-' + id + '">Más</summary>'
      + '<div class="menu"><button type="button" data-accion="cancelar" data-id="' + id + '">Cancelar orden</button>'
      + '<button type="button" class="rojo" data-accion="eliminar" data-id="' + id + '">Eliminar orden</button></div></details>';
  }
  if (o.estado === 'CANCELADA') {
    return '<button class="btn peq" type="button" data-accion="eliminar" data-id="' + id + '">Eliminar</button>';
  }
  return '<span class="nota">Cerrada el ' + esc(fecha(o.fecha_cierre)) + '</span>';
}

function pintarOrdenes() {
  const lista = estado.ordenes
    .filter((o) => !estado.filtro || o.estado === estado.filtro)
    .sort((a, b) => b.id_orden - a.id_orden);
  $('#vacio').hidden = lista.length > 0;
  $('#cuerpo').innerHTML = lista.map((o) =>
    '<tr class="' + (o.id_orden === estado.nueva ? 'nueva' : '') + '">'
    + '<td data-etiqueta="Orden"><span class="op">OP-' + o.id_orden + '</span></td>'
    + '<td data-etiqueta="Producto">' + esc(o.producto) + '</td>'
    + '<td data-etiqueta="Cantidad" class="der">' + formatoNum.format(o.cantidad) + '</td>'
    + '<td data-etiqueta="Estado"><span class="estado ' + o.estado.toLowerCase() + '" title="' + AYUDA_ESTADO[o.estado] + '">' + NOMBRE_ESTADO[o.estado] + '</span></td>'
    + '<td data-etiqueta="Creada">' + esc(fecha(o.fecha_creacion)) + '</td>'
    + '<td class="acciones">' + accionesDe(o) + '</td>'
    + '</tr>'
  ).join('');
  estado.nueva = null;
}

function pintarBodega() {
  $('#listaMP').innerHTML = estado.inventario.map((m) =>
    '<li class="' + (estado.cambios.has('mp:' + m.codigo) ? 'cambio' : '') + '">'
    + '<div><span class="nombre">' + esc(m.nombre) + '</span><span class="minimo">mínimo ' + formatoNum.format(m.stock_minimo) + ' ' + esc(m.unidad_medida) + '</span></div>'
    + '<div class="cifra">' + formatoNum.format(m.stock_actual) + ' ' + esc(m.unidad_medida)
    + (m.estado === 'REABASTECER' ? '<span class="reponer">Hay que reponer</span>' : '') + '</div></li>'
  ).join('');
  $('#listaPR').innerHTML = estado.productos.map((p) =>
    '<li class="' + (estado.cambios.has('pr:' + p.codigo) ? 'cambio' : '') + '">'
    + '<span class="nombre">' + esc(p.nombre) + '</span>'
    + '<div class="cifra">' + formatoNum.format(p.stock_actual) + ' und</div></li>'
  ).join('');
  estado.cambios = new Set();
}

// ---------------------------------------------------------------------------
// Avisos y confirmaciones
// ---------------------------------------------------------------------------
function mostrarBanner(texto) {
  $('#bannerTexto').textContent = texto;
  $('#banner').hidden = false;
}

function aviso(texto, tipo) {
  const el = document.createElement('div');
  el.className = 'aviso-flotante ' + tipo;
  if (tipo === 'error') el.setAttribute('role', 'alert');
  el.textContent = texto;
  $('#avisos').appendChild(el);
  setTimeout(() => el.remove(), tipo === 'error' ? 9000 : 5000);
}

function confirmar(titulo, texto, textoBoton, esPeligro) {
  return new Promise((resolver) => {
    const d = $('#dlgConfirmar');
    $('#cTitulo').textContent = titulo;
    $('#cTexto').textContent = texto;
    const ok = $('#cOk');
    ok.textContent = textoBoton;
    ok.className = 'btn ' + (esPeligro ? 'peligro' : 'primario');
    d.returnValue = '';
    d.addEventListener('close', () => resolver(d.returnValue === 'ok'), { once: true });
    d.showModal();
  });
}

// Ejecuta una accion, avisa el resultado y vuelve a cargar los datos.
async function ejecutar(peticion, mensajeOk) {
  try {
    await peticion();
    aviso(mensajeOk, 'ok');
  } catch (e) {
    aviso(e.mensaje, 'error');
    if (e.conexion) mostrarBanner(e.mensaje);
  }
  await cargarTodo();
}

// ---------------------------------------------------------------------------
// Acciones de cada orden
// ---------------------------------------------------------------------------
async function completar(o) {
  const si = await confirmar(
    '¿Completar la orden OP-' + o.id_orden + '?',
    'Se fabricarán ' + o.cantidad + ' unidades de «' + o.producto + '» y se descontará de la bodega la materia prima necesaria. Esto no se puede deshacer.',
    'Completar orden', false);
  if (!si) return;
  await ejecutar(() => api('/api/ordenes/' + o.id_orden + '/completar', { method: 'POST' }),
    'Orden OP-' + o.id_orden + ' completada. La bodega ya se actualizó.');
}

async function cancelar(o) {
  const si = await confirmar(
    '¿Cancelar la orden OP-' + o.id_orden + '?',
    'Pasará a «Cancelada». No gasta materia prima y ya no se podrá completar.',
    'Cancelar orden', true);
  if (!si) return;
  await ejecutar(() => api('/api/ordenes/' + o.id_orden + '/cancelar', { method: 'POST' }),
    'Orden OP-' + o.id_orden + ' cancelada.');
}

async function eliminar(o) {
  const si = await confirmar(
    '¿Eliminar la orden OP-' + o.id_orden + '?',
    'Se borra del sistema y no se puede recuperar.',
    'Eliminar orden', true);
  if (!si) return;
  await ejecutar(() => api('/api/ordenes/' + o.id_orden, { method: 'DELETE' }),
    'Orden OP-' + o.id_orden + ' eliminada.');
}

// ---------------------------------------------------------------------------
// Ventana para crear o editar
// ---------------------------------------------------------------------------
function productoElegido() {
  const id = parseInt($('#fProducto').value, 10);
  return estado.productos.find((p) => p.id_producto === id);
}

function actualizarAyuda() {
  const p = productoElegido();
  const cantidad = parseInt($('#fCantidad').value, 10);
  const ayuda = $('#fAyuda');
  ayuda.className = 'ayuda';
  if (!p) { ayuda.textContent = 'Elige un producto para ver cuántas unidades se pueden fabricar hoy.'; return; }
  if (Number.isInteger(cantidad) && cantidad > p.max_producible) {
    ayuda.className = 'ayuda aviso';
    ayuda.textContent = 'Pides ' + cantidad + ', pero con la bodega de hoy solo alcanza para ' + p.max_producible
      + '. Puedes crear la orden igual; no se podrá completar hasta que haya más materia prima.';
    return;
  }
  ayuda.textContent = 'Con la bodega de hoy se pueden fabricar hasta ' + p.max_producible + ' unidades de este producto.';
}

function errorForm(texto) {
  const el = $('#fError');
  el.textContent = texto;
  el.hidden = false;
}

function abrirOrden(orden) {
  estado.edicion = orden || null;
  const select = $('#fProducto');
  select.innerHTML = '<option value="" disabled selected>Elige un producto…</option>'
    + estado.productos.map((p) => '<option value="' + p.id_producto + '">' + esc(p.nombre) + '</option>').join('');
  $('#oTitulo').textContent = orden ? 'Editar orden OP-' + orden.id_orden : 'Nueva orden';
  $('#oGuardar').textContent = orden ? 'Guardar cambios' : 'Crear orden';
  if (orden) {
    const p = estado.productos.find((x) => x.nombre === orden.producto);
    if (p) select.value = p.id_producto;
  }
  select.disabled = !!orden;
  $('#fCantidad').value = orden ? orden.cantidad : 1;
  $('#fError').hidden = true;
  actualizarAyuda();
  $('#dlgOrden').showModal();
  (orden ? $('#fCantidad') : select).focus();
}

$('#frmOrden').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const cantidad = parseInt($('#fCantidad').value, 10);
  const idProducto = parseInt($('#fProducto').value, 10);
  if (!estado.edicion && !idProducto) return errorForm('Elige el producto que quieres fabricar.');
  if (!Number.isInteger(cantidad) || cantidad < 1) return errorForm('Escribe una cantidad de 1 o más.');
  const boton = $('#oGuardar');
  boton.disabled = true;
  try {
    if (estado.edicion) {
      const id = estado.edicion.id_orden;
      await api('/api/ordenes/' + id, { method: 'PUT', body: JSON.stringify({ cantidad }) });
      aviso('Orden OP-' + id + ' actualizada.', 'ok');
    } else {
      const r = await api('/api/ordenes', { method: 'POST', body: JSON.stringify({ id_producto: idProducto, cantidad }) });
      estado.nueva = r[0].id_orden_creada;
      aviso('Orden OP-' + estado.nueva + ' creada. Queda pendiente: complétala cuando quieras fabricar.', 'ok');
    }
    $('#dlgOrden').close();
    await cargarTodo();
  } catch (e) {
    errorForm(e.mensaje);
  } finally {
    boton.disabled = false;
  }
});

$('#fProducto').addEventListener('change', actualizarAyuda);
$('#fCantidad').addEventListener('input', actualizarAyuda);
$('#oVolver').addEventListener('click', () => $('#dlgOrden').close());

// ---------------------------------------------------------------------------
// Eventos de la pagina
// ---------------------------------------------------------------------------
$('#btnNueva').addEventListener('click', () => abrirOrden(null));
$('#btnReintentar').addEventListener('click', cargarTodo);

document.querySelectorAll('.filtro').forEach((boton) => {
  boton.addEventListener('click', () => {
    estado.filtro = boton.dataset.filtro;
    document.querySelectorAll('.filtro').forEach((b) => b.setAttribute('aria-pressed', String(b === boton)));
    pintarOrdenes();
  });
});

// Un solo escuchador para todos los botones de la tabla.
$('#cuerpo').addEventListener('click', (ev) => {
  const boton = ev.target.closest('button[data-accion]');
  if (!boton) return;
  const menu = boton.closest('details');
  if (menu) menu.removeAttribute('open');
  const orden = estado.ordenes.find((o) => o.id_orden === Number(boton.dataset.id));
  if (!orden) return;
  const acciones = { completar, cancelar, eliminar, editar: abrirOrden };
  acciones[boton.dataset.accion](orden);
});

// Cierra el menu "Mas" al hacer clic fuera.
document.addEventListener('click', (ev) => {
  document.querySelectorAll('details.mas[open]').forEach((d) => { if (!d.contains(ev.target)) d.removeAttribute('open'); });
});

// Recuerda si la guia ya se cerro.
try { if (localStorage.getItem('guiaCerrada') === '1') $('#guia').removeAttribute('open'); } catch (e) { /* sin almacenamiento */ }
$('#guia').addEventListener('toggle', () => {
  try { localStorage.setItem('guiaCerrada', $('#guia').open ? '0' : '1'); } catch (e) { /* sin almacenamiento */ }
});

cargarTodo();
</script>
</body>
</html>
"""


@app.get("/")
def inicio():
    return Response(PAGINA, mimetype="text/html")


if __name__ == "__main__":
    print("Listo. Abre http://localhost:5000 en tu navegador.", flush=True)
    app.run(host="0.0.0.0", port=5000)
