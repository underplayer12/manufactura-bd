"""
Aplicacion web v2 - Industria manufacturera (control de produccion e inventarios).

Como esta armada (de arriba abajo):
  1. Configuracion, seguridad de sesion y cabeceras.
  2. Registro de solicitudes (bitacora): cada accion queda guardada en la base.
  3. Control de acceso: usuario + clave, y tres roles (ADMIN, OPERARIO, CONSULTA).
  4. Rutas /api/...: cada una valida los datos y llama a UN procedimiento de la base.
  5. La pagina (static/index.html + app.js + app.css).

Cambios frente a la v1: ver MANUAL (y CLAUDE.md). Resumen: login, roles, bitacora,
modulos de inventario/clientes/proveedores/ventas/reportes, y conexion con un usuario
de MySQL que solo puede ejecutar procedimientos (antes usaba root).
"""
import csv
import io
import json
import os
import re
import secrets
import time
from datetime import timedelta
from decimal import Decimal, InvalidOperation
from functools import wraps

from flask import Flask, Response, g, jsonify, request, send_from_directory, session
from werkzeug.security import check_password_hash, generate_password_hash

import bd
from bd import ErrorNegocio, filas, llamar, una

# ---------------------------------------------------------------------------
# 1. Configuracion
# ---------------------------------------------------------------------------
app = Flask(__name__, static_folder="static", static_url_path="/static")
app.secret_key = os.environ.get("SECRET_KEY") or secrets.token_hex(32)   # sin SECRET_KEY fija, las sesiones se cierran al reiniciar
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,          # el JavaScript de la pagina no puede leer la cookie
    SESSION_COOKIE_SAMESITE="Lax",         # el navegador no la manda desde otros sitios (frena CSRF)
    SESSION_COOKIE_SECURE=os.environ.get("COOKIE_SEGURA", "0") == "1",   # poner 1 si se usa HTTPS
    PERMANENT_SESSION_LIFETIME=timedelta(hours=int(os.environ.get("SESION_HORAS", "8"))),
    MAX_CONTENT_LENGTH=64 * 1024,
    JSON_AS_ASCII=False,
)

ADMIN_USUARIO = "admin"
ADMIN_CLAVE_INICIAL = os.environ.get("ADMIN_CLAVE_INICIAL", "Admin2026!")
RANGO = {"CONSULTA": 1, "OPERARIO": 2, "ADMIN": 3}
CAMPOS_SECRETOS = {"clave", "clave_actual", "clave_nueva", "clave_temporal"}

# Intentos fallidos de login: (usuario, ip) -> [contador, bloqueado_hasta]
INTENTOS = {}
MAX_INTENTOS, BLOQUEO_SEG = 5, 300


@app.after_request
def cabeceras(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "same-origin"
    resp.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'")
    if request.path.startswith("/api/"):
        resp.headers["Cache-Control"] = "no-store"
    return resp


# ---------------------------------------------------------------------------
# 2. Bitacora (registro de solicitudes)
# ---------------------------------------------------------------------------
def ip_cliente():
    return (request.headers.get("X-Forwarded-For") or request.remote_addr or "")[:45].split(",")[0].strip()


def parametros_seguros():
    """Los datos enviados por el usuario, sin claves."""
    cuerpo = request.get_json(silent=True)
    if not isinstance(cuerpo, dict):
        return None
    limpio = {k: ("***" if k in CAMPOS_SECRETOS else v) for k, v in cuerpo.items()}
    return json.dumps(limpio, ensure_ascii=False)[:4000]


def registrar(estado, mensaje_error=None, usuario=None):
    """Guarda UNA fila en la bitacora. Si falla, no tumba la solicitud (solo avisa en consola)."""
    u = usuario or getattr(g, "usuario", None) or {}
    try:
        llamar(
            "sp_bitacora_registrar",
            u.get("id_usuario"), (u.get("usuario") or getattr(g, "usuario_intentado", None) or "(anonimo)")[:30],
            u.get("rol"), getattr(g, "accion", None) or request.method, getattr(g, "modulo", None) or "General",
            getattr(g, "ref", None), (mensaje_error or getattr(g, "detalle", None) or "")[:500] or None,
            "OK" if estado < 400 else "ERROR", request.method, request.path[:200], estado,
            parametros_seguros(), ip_cliente())
    except Exception as e:  # noqa: BLE001 - la bitacora nunca debe romper la operacion
        app.logger.error("No se pudo escribir en la bitacora: %s", e)


# ---------------------------------------------------------------------------
# 3. Acceso: decorador de rutas con rol minimo
# ---------------------------------------------------------------------------
def usuario_actual():
    """Lee la sesion y confirma en la base que el usuario sigue activo (si lo desactivan, cae al instante)."""
    id_usuario = session.get("id_usuario")
    if not id_usuario:
        return None
    u = una("sp_usuario_obtener", id_usuario)
    if not u or not u["activo"]:
        session.clear()
        return None
    return u


def ruta(path, metodos=("GET",), rol="CONSULTA", modulo=None, accion=None, libre=False, auditar=None):
    """
    Registra una ruta /api/<path>.
      rol     : rol minimo que puede usarla
      modulo/accion : como se escribe en la bitacora
      libre   : True = no exige sesion (login, salud)
      auditar : por defecto se audita todo lo que NO es GET
    """
    def decorador(funcion):
        @wraps(funcion)
        def envoltura(**kwargs):
            g.modulo, g.accion, g.ref, g.detalle = modulo, accion, None, None
            auditado = (request.method != "GET") if auditar is None else auditar
            try:
                if not libre:
                    u = usuario_actual()
                    if not u:
                        raise ErrorNegocio("Inicia sesión para continuar.", 401, {"login": True})
                    g.usuario = u
                    if u["debe_cambiar_clave"] and funcion.__name__ not in ("api_yo", "api_logout", "api_cambiar_clave"):
                        raise ErrorNegocio("Debes cambiar tu clave antes de continuar.", 403, {"cambiar_clave": True})
                    if RANGO[u["rol"]] < RANGO[rol]:
                        g.accion = "ACCESO DENEGADO"
                        raise ErrorNegocio("Tu rol (%s) no tiene permiso para esto." % u["rol"], 403)
                    if request.method != "GET" and request.headers.get("X-Requested-With") != "fetch":
                        raise ErrorNegocio("Solicitud no válida.", 400)          # defensa CSRF extra
                resultado = funcion(**kwargs)
                datos, estado = resultado if isinstance(resultado, tuple) else (resultado, 200)
                if auditado:
                    registrar(estado)
                return jsonify(datos), estado
            except ErrorNegocio as e:
                if auditado or e.estado == 403:
                    registrar(e.estado, e.mensaje)
                return jsonify({"error": e.mensaje, **e.extra}), e.estado
        app.add_url_rule("/api/" + path, funcion.__name__, envoltura, methods=list(metodos))
        return envoltura
    return decorador


# --- validacion de datos de entrada -----------------------------------------
def cuerpo():
    datos = request.get_json(silent=True)
    if not isinstance(datos, dict):
        raise ErrorNegocio("Falta el cuerpo de la solicitud (JSON).")
    return datos


def texto(d, campo, obligatorio=True, maximo=100, etiqueta=None):
    v = d.get(campo)
    if v is None or (isinstance(v, str) and not v.strip()):
        if obligatorio:
            raise ErrorNegocio("Falta: %s." % (etiqueta or campo))
        return None
    v = str(v).strip()
    if len(v) > maximo:
        raise ErrorNegocio("%s es demasiado largo (máximo %d caracteres)." % (etiqueta or campo, maximo))
    return v


def entero(d, campo, obligatorio=True, minimo=None, etiqueta=None):
    v = d.get(campo)
    if v in (None, ""):
        if obligatorio:
            raise ErrorNegocio("Falta: %s." % (etiqueta or campo))
        return None
    try:
        if isinstance(v, bool) or (isinstance(v, float) and v != int(v)):
            raise ValueError
        v = int(v)
    except (TypeError, ValueError):
        raise ErrorNegocio("%s debe ser un número entero." % (etiqueta or campo))
    if minimo is not None and v < minimo:
        raise ErrorNegocio("%s debe ser al menos %d." % (etiqueta or campo, minimo))
    return v


def decimal(d, campo, obligatorio=True, minimo=None, etiqueta=None):
    v = d.get(campo)
    if v in (None, ""):
        if obligatorio:
            raise ErrorNegocio("Falta: %s." % (etiqueta or campo))
        return None
    try:
        n = Decimal(str(v).replace(",", "."))
        if not n.is_finite():
            raise InvalidOperation
    except (InvalidOperation, ValueError):
        raise ErrorNegocio("%s debe ser un número." % (etiqueta or campo))
    if minimo is not None and n < minimo:
        raise ErrorNegocio("%s no puede ser menor que %s." % (etiqueta or campo, minimo))
    return n


def booleano(d, campo):
    v = d.get(campo)
    if not isinstance(v, bool):
        raise ErrorNegocio("Falta: %s (verdadero o falso)." % campo)
    return v


def fecha(d, campo):
    v = d.get(campo)
    if v in (None, ""):
        return None
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(v)):
        raise ErrorNegocio("%s debe tener formato AAAA-MM-DD." % campo)
    return str(v)


def verdadero(nombre):
    return request.args.get(nombre, "0") in ("1", "true", "si")


def clave_valida(clave):
    if not isinstance(clave, str) or len(clave) < 8:
        raise ErrorNegocio("La clave debe tener al menos 8 caracteres.")
    if not (re.search(r"[A-Za-z]", clave) and re.search(r"\d", clave)):
        raise ErrorNegocio("La clave debe mezclar letras y números.")
    if len(clave) > 72:
        raise ErrorNegocio("La clave es demasiado larga (máximo 72).")
    return clave


# ---------------------------------------------------------------------------
# 4a. Sesion
# ---------------------------------------------------------------------------
def asegurar_admin():
    """La primera vez que arranca, crea el usuario 'admin' (debe cambiar la clave al entrar)."""
    try:
        if una("sp_usuario_contar")["total"] == 0:
            llamar("sp_usuario_crear", ADMIN_USUARIO, "Administrador", "ADMIN", generate_password_hash(ADMIN_CLAVE_INICIAL))
            app.logger.warning("Se creo el usuario '%s' con la clave inicial. Cambiala al entrar.", ADMIN_USUARIO)
    except ErrorNegocio as e:
        app.logger.error("No se pudo preparar el usuario admin: %s", e.mensaje)


@app.route("/")
def inicio():
    return send_from_directory(app.static_folder, "index.html")


@ruta("salud", libre=True)
def api_salud():
    una("sp_usuario_contar")          # si la base no responde, esto lanza el error
    return {"ok": True}


@ruta("login", ("POST",), libre=True, modulo="Acceso", accion="LOGIN")
def api_login():
    d = cuerpo()
    nombre = (texto(d, "usuario", maximo=30) or "").lower()
    clave = d.get("clave") if isinstance(d.get("clave"), str) else ""
    g.usuario_intentado = nombre
    llave = (nombre, ip_cliente())
    contador, hasta = INTENTOS.get(llave, [0, 0])
    if hasta > time.time():
        g.detalle = "Acceso bloqueado temporalmente por demasiados intentos"
        raise ErrorNegocio("Demasiados intentos. Espera unos minutos e inténtalo de nuevo.", 429)
    u = una("sp_usuario_login", nombre)
    if not u:
        asegurar_admin()                       # por si la base estaba caida cuando arranco la aplicacion
        u = una("sp_usuario_login", nombre)
    # check_password_hash tambien se ejecuta si el usuario no existe, para no delatar cuales existen
    ok = check_password_hash(u["clave_hash"] if u else generate_password_hash("x"), clave) and u and u["activo"]
    if not ok:
        contador += 1
        INTENTOS[llave] = [contador, time.time() + BLOQUEO_SEG if contador >= MAX_INTENTOS else 0]
        g.detalle = "Usuario o clave incorrectos" + (" (usuario inexistente)" if not u else " (usuario inactivo)" if not u["activo"] else "")
        raise ErrorNegocio("Usuario o clave incorrectos.", 401)
    INTENTOS.pop(llave, None)
    session.clear()
    session.permanent = True
    session["id_usuario"] = u["id_usuario"]
    llamar("sp_usuario_registrar_acceso", u["id_usuario"])
    g.usuario = u
    g.detalle = "Inicio de sesión"
    return {"usuario": u["usuario"], "nombre": u["nombre"], "rol": u["rol"], "debe_cambiar_clave": bool(u["debe_cambiar_clave"])}


@ruta("logout", ("POST",), modulo="Acceso", accion="LOGOUT")
def api_logout():
    g.detalle = "Cierre de sesión"
    session.clear()
    return {"ok": True}


@ruta("yo")
def api_yo():
    u = g.usuario
    return {"usuario": u["usuario"], "nombre": u["nombre"], "rol": u["rol"], "debe_cambiar_clave": bool(u["debe_cambiar_clave"])}


@ruta("cambiar-clave", ("POST",), modulo="Acceso", accion="CAMBIAR CLAVE")
def api_cambiar_clave():
    d = cuerpo()
    actual, nueva = d.get("clave_actual"), clave_valida(d.get("clave_nueva"))
    registro = una("sp_usuario_login", g.usuario["usuario"])
    if not isinstance(actual, str) or not check_password_hash(registro["clave_hash"], actual):
        raise ErrorNegocio("La clave actual no es correcta.", 400)
    if actual == nueva:
        raise ErrorNegocio("La clave nueva debe ser distinta de la actual.")
    llamar("sp_usuario_cambiar_clave", g.usuario["id_usuario"], generate_password_hash(nueva), False)
    g.detalle = "El usuario cambió su propia clave"
    return {"ok": True}


# ---------------------------------------------------------------------------
# 4b. Inicio y reportes
# ---------------------------------------------------------------------------
@ruta("dashboard")
def api_dashboard():
    return {"resumen": una("sp_dashboard"), "reponer": filas("sp_reponer_sugerencias")}


REPORTES = {
    "produccion": "sp_reporte_produccion",
    "compras": "sp_reporte_compras",
    "ventas": "sp_reporte_ventas",
    "clientes": "sp_reporte_clientes",
    "inventario": "sp_reporte_inventario",
    "reponer": "sp_reponer_sugerencias",
}


@ruta("reportes/<nombre>", auditar=False)
def api_reporte(nombre):
    if nombre not in REPORTES:
        raise ErrorNegocio("Ese reporte no existe.", 404)
    return {"filas": filas(REPORTES[nombre])}


# El CSV necesita su propia respuesta (no es JSON), por eso no usa el decorador
@app.route("/api/reportes/<nombre>/descargar")
def api_reporte_csv(nombre):
    u = usuario_actual()
    if not u:
        return jsonify({"error": "Inicia sesión para continuar.", "login": True}), 401
    if nombre not in REPORTES:
        return jsonify({"error": "Ese reporte no existe."}), 404
    g.usuario, g.modulo, g.accion, g.ref, g.detalle = u, "Reportes", "DESCARGAR CSV", nombre, "Descarga de reporte en CSV"
    datos = filas(REPORTES[nombre])
    salida = io.StringIO()
    if datos:
        w = csv.DictWriter(salida, fieldnames=list(datos[0].keys()), lineterminator="\r\n")
        w.writeheader()
        w.writerows(datos)
    registrar(200)
    resp = Response("﻿" + salida.getvalue(), mimetype="text/csv; charset=utf-8")
    resp.headers["Content-Disposition"] = "attachment; filename=reporte_%s.csv" % nombre
    return resp


# ---------------------------------------------------------------------------
# 4c. Ordenes de produccion  (el CRUD original de la v1)
# ---------------------------------------------------------------------------
@ruta("ordenes")
def api_ordenes():
    return {"filas": filas("sp_get_ordenes", request.args.get("estado") or None)}


@ruta("ordenes", ("POST",), "OPERARIO", "Órdenes", "CREAR")
def api_orden_crear():
    d = cuerpo()
    r = una("sp_orden_crear", entero(d, "id_producto", etiqueta="Producto"), entero(d, "cantidad", minimo=1, etiqueta="Cantidad"))
    g.ref = "OP-%s" % list(r.values())[0] if r else None
    g.detalle = "Orden creada: producto %s x %s" % (d.get("id_producto"), d.get("cantidad"))
    return {"id_orden": list(r.values())[0] if r else None}, 201


@ruta("ordenes/<int:id_orden>", ("PUT",), "OPERARIO", "Órdenes", "EDITAR")
def api_orden_editar(id_orden):
    llamar("sp_actualizar_orden", id_orden, entero(cuerpo(), "cantidad", minimo=1, etiqueta="Cantidad"))
    g.ref, g.detalle = "OP-%d" % id_orden, "Cantidad cambiada"
    return {"ok": True}


@ruta("ordenes/<int:id_orden>/completar", ("POST",), "OPERARIO", "Órdenes", "COMPLETAR")
def api_orden_completar(id_orden):
    llamar("sp_completar_orden", id_orden)
    g.ref, g.detalle = "OP-%d" % id_orden, "Orden completada: se descontaron materias primas y subió el stock del producto"
    return {"ok": True}


@ruta("ordenes/<int:id_orden>/cancelar", ("POST",), "OPERARIO", "Órdenes", "CANCELAR")
def api_orden_cancelar(id_orden):
    llamar("sp_cancelar_orden", id_orden)
    g.ref = "OP-%d" % id_orden
    return {"ok": True}


@ruta("ordenes/<int:id_orden>", ("DELETE",), "OPERARIO", "Órdenes", "ELIMINAR")
def api_orden_eliminar(id_orden):
    llamar("sp_eliminar_orden", id_orden)
    g.ref = "OP-%d" % id_orden
    return {"ok": True}


# ---------------------------------------------------------------------------
# 4d. Productos y recetas
# ---------------------------------------------------------------------------
@ruta("productos")
def api_productos():
    return {"filas": filas("sp_producto_listar", verdadero("inactivos"))}


@ruta("productos", ("POST",), "ADMIN", "Productos", "CREAR")
def api_producto_crear():
    d = cuerpo()
    codigo = texto(d, "codigo", maximo=20, etiqueta="Código")
    r = una("sp_producto_crear", codigo, texto(d, "nombre", etiqueta="Nombre"), decimal(d, "precio_venta", minimo=Decimal("0.01"), etiqueta="Precio de venta"))
    g.ref, g.detalle = codigo, "Producto creado: %s" % d.get("nombre")
    return {"id_producto": list(r.values())[0]}, 201


@ruta("productos/<int:id_producto>", ("PUT",), "ADMIN", "Productos", "EDITAR")
def api_producto_editar(id_producto):
    d = cuerpo()
    llamar("sp_producto_actualizar", id_producto, texto(d, "nombre", etiqueta="Nombre"), decimal(d, "precio_venta", minimo=Decimal("0.01"), etiqueta="Precio de venta"))
    g.ref = "PROD-%d" % id_producto
    return {"ok": True}


@ruta("productos/<int:id_producto>/estado", ("POST",), "ADMIN", "Productos", "CAMBIAR ESTADO")
def api_producto_estado(id_producto):
    activo = booleano(cuerpo(), "activo")
    llamar("sp_producto_estado", id_producto, activo)
    g.ref, g.detalle = "PROD-%d" % id_producto, "Activado" if activo else "Desactivado"
    return {"ok": True}


@ruta("productos/<int:id_producto>/receta")
def api_receta(id_producto):
    return {"filas": filas("sp_receta_listar", id_producto)}


@ruta("productos/<int:id_producto>/receta/<int:id_materia>", ("PUT",), "ADMIN", "Recetas", "GUARDAR LINEA")
def api_receta_guardar(id_producto, id_materia):
    llamar("sp_receta_guardar", id_producto, id_materia, decimal(cuerpo(), "cantidad_por_unidad", minimo=Decimal("0.0001"), etiqueta="Cantidad por unidad"))
    g.ref, g.detalle = "PROD-%d" % id_producto, "Materia %d en la receta" % id_materia
    return {"ok": True}


@ruta("productos/<int:id_producto>/receta/<int:id_materia>", ("DELETE",), "ADMIN", "Recetas", "QUITAR LINEA")
def api_receta_quitar(id_producto, id_materia):
    llamar("sp_receta_quitar", id_producto, id_materia)
    g.ref, g.detalle = "PROD-%d" % id_producto, "Materia %d fuera de la receta" % id_materia
    return {"ok": True}


# ---------------------------------------------------------------------------
# 4e. Materias primas e inventario
# ---------------------------------------------------------------------------
@ruta("materias")
def api_materias():
    return {"filas": filas("sp_materia_listar", verdadero("inactivas"))}


@ruta("materias", ("POST",), "ADMIN", "Materias primas", "CREAR")
def api_materia_crear():
    d = cuerpo()
    codigo = texto(d, "codigo", maximo=20, etiqueta="Código")
    r = una("sp_materia_crear", codigo, texto(d, "nombre", etiqueta="Nombre"), texto(d, "unidad_medida", maximo=10, etiqueta="Unidad"),
            decimal(d, "stock_minimo", minimo=Decimal(0), etiqueta="Stock minimo"), entero(d, "id_bodega", obligatorio=False))
    g.ref, g.detalle = codigo, "Materia prima creada: %s" % d.get("nombre")
    return {"id_materia_prima": list(r.values())[0]}, 201


@ruta("materias/<int:id_materia>", ("PUT",), "ADMIN", "Materias primas", "EDITAR")
def api_materia_editar(id_materia):
    d = cuerpo()
    llamar("sp_materia_actualizar", id_materia, texto(d, "nombre", etiqueta="Nombre"), texto(d, "unidad_medida", maximo=10, etiqueta="Unidad"),
           decimal(d, "stock_minimo", minimo=Decimal(0), etiqueta="Stock minimo"), entero(d, "id_bodega", obligatorio=False))
    g.ref = "MP-ID %d" % id_materia
    return {"ok": True}


@ruta("materias/<int:id_materia>/estado", ("POST",), "ADMIN", "Materias primas", "CAMBIAR ESTADO")
def api_materia_estado(id_materia):
    activo = booleano(cuerpo(), "activo")
    llamar("sp_materia_estado", id_materia, activo)
    g.ref, g.detalle = "MP-ID %d" % id_materia, "Activada" if activo else "Desactivada"
    return {"ok": True}


@ruta("materias/<int:id_materia>/kardex")
def api_kardex(id_materia):
    pagina = int(request.args["pagina"]) if request.args.get("pagina", "").isdigit() and int(request.args["pagina"]) > 0 else 1
    tam = 25
    datos = filas("sp_get_kardex_paginado", id_materia, tam + 1, (pagina - 1) * tam)
    return {"filas": datos[:tam], "hay_mas": len(datos) > tam, "pagina": pagina}


@ruta("materias/<int:id_materia>/lotes")
def api_lotes(id_materia):
    return {"filas": filas("sp_get_lotes", id_materia)}


@ruta("materias/<int:id_materia>/bodegas")
def api_materia_bodegas(id_materia):
    return {"filas": filas("sp_materia_bodegas", id_materia)}


@ruta("materias/<int:id_materia>/proveedores")
def api_materia_proveedores(id_materia):
    return {"filas": filas("sp_get_proveedores_materia", id_materia)}


@ruta("lotes/<int:id_lote>/trazabilidad")
def api_trazabilidad(id_lote):
    return {"filas": filas("sp_get_trazabilidad_lote", id_lote)}


@ruta("inventario/bodegas")
def api_inventario_bodegas():
    return {"filas": filas("sp_get_inventario_bodegas")}


@ruta("compras")
def api_compras():
    return {"filas": filas("sp_compras_listar", 100)}


@ruta("compras", ("POST",), "OPERARIO", "Inventario", "REGISTRAR COMPRA")
def api_compra_crear():
    d = cuerpo()
    r = una("sp_registrar_compra_lote", entero(d, "id_materia_prima", etiqueta="Materia prima"), entero(d, "id_proveedor", etiqueta="Proveedor"),
            decimal(d, "cantidad", minimo=Decimal("0.001"), etiqueta="Cantidad"), entero(d, "id_bodega", obligatorio=False),
            texto(d, "lote_proveedor", obligatorio=False, maximo=40), fecha(d, "fecha_vencimiento"), texto(d, "observacion", obligatorio=False, maximo=200))
    g.ref = r["codigo_lote"] if r else None
    g.detalle = "Compra de %s x %s" % (r["codigo"] if r else d.get("id_materia_prima"), d.get("cantidad"))
    return {"compra": r}, 201


@ruta("traslados", ("POST",), "OPERARIO", "Inventario", "TRASLADAR")
def api_traslado():
    d = cuerpo()
    llamar("sp_trasladar_stock", entero(d, "id_materia_prima", etiqueta="Materia prima"), entero(d, "id_origen", etiqueta="Bodega origen"),
           entero(d, "id_destino", etiqueta="Bodega destino"), decimal(d, "cantidad", minimo=Decimal("0.001"), etiqueta="Cantidad"))
    g.detalle = "Traslado de %s unidades entre bodegas (materia %s)" % (d.get("cantidad"), d.get("id_materia_prima"))
    return {"ok": True}, 201


# ---------------------------------------------------------------------------
# 4f. Bodegas
# ---------------------------------------------------------------------------
@ruta("bodegas")
def api_bodegas():
    return {"filas": filas("sp_bodega_listar")}


@ruta("bodegas", ("POST",), "ADMIN", "Bodegas", "CREAR")
def api_bodega_crear():
    d = cuerpo()
    codigo = texto(d, "codigo", maximo=20, etiqueta="Código")
    r = una("sp_bodega_crear", codigo, texto(d, "nombre", etiqueta="Nombre"), texto(d, "ubicacion", obligatorio=False))
    g.ref = codigo
    return {"id_bodega": list(r.values())[0]}, 201


@ruta("bodegas/<int:id_bodega>", ("PUT",), "ADMIN", "Bodegas", "EDITAR")
def api_bodega_editar(id_bodega):
    d = cuerpo()
    llamar("sp_bodega_actualizar", id_bodega, texto(d, "nombre", etiqueta="Nombre"), texto(d, "ubicacion", obligatorio=False), booleano(d, "activa"))
    g.ref = "BOD-ID %d" % id_bodega
    return {"ok": True}


# ---------------------------------------------------------------------------
# 4g. Proveedores y precios
# ---------------------------------------------------------------------------
@ruta("proveedores")
def api_proveedores():
    return {"filas": filas("sp_proveedor_listar", verdadero("inactivos"))}


@ruta("proveedores", ("POST",), "ADMIN", "Proveedores", "CREAR")
def api_proveedor_crear():
    d = cuerpo()
    nit = texto(d, "nit", maximo=20, etiqueta="NIT")
    r = una("sp_registrar_proveedor", nit, texto(d, "nombre", etiqueta="Nombre"), texto(d, "telefono", obligatorio=False, maximo=20), texto(d, "email", obligatorio=False))
    g.ref, g.detalle = nit, "Proveedor creado: %s" % d.get("nombre")
    return {"id_proveedor": list(r.values())[0] if r else None}, 201


@ruta("proveedores/<int:id_proveedor>", ("PUT",), "ADMIN", "Proveedores", "EDITAR")
def api_proveedor_editar(id_proveedor):
    d = cuerpo()
    llamar("sp_proveedor_actualizar", id_proveedor, texto(d, "nombre", etiqueta="Nombre"), texto(d, "telefono", obligatorio=False, maximo=20), texto(d, "email", obligatorio=False))
    g.ref = "PROV-%d" % id_proveedor
    return {"ok": True}


@ruta("proveedores/<int:id_proveedor>/estado", ("POST",), "ADMIN", "Proveedores", "CAMBIAR ESTADO")
def api_proveedor_estado(id_proveedor):
    activo = booleano(cuerpo(), "activo")
    llamar("sp_proveedor_estado", id_proveedor, activo)
    g.ref, g.detalle = "PROV-%d" % id_proveedor, "Activado" if activo else "Desactivado"
    return {"ok": True}


@ruta("proveedores/<int:id_proveedor>/ofertas")
def api_ofertas(id_proveedor):
    return {"filas": filas("sp_oferta_listar", id_proveedor)}


@ruta("proveedores/<int:id_proveedor>/ofertas/<int:id_materia>", ("PUT",), "ADMIN", "Proveedores", "GUARDAR OFERTA")
def api_oferta_guardar(id_proveedor, id_materia):
    d = cuerpo()
    llamar("sp_oferta_guardar", id_proveedor, id_materia, texto(d, "pais_origen", maximo=60, etiqueta="País de origen"),
           decimal(d, "precio_unitario", minimo=Decimal("0.01"), etiqueta="Precio"), entero(d, "tiempo_entrega_dias", minimo=0, etiqueta="Días de entrega"))
    g.ref, g.detalle = "PROV-%d" % id_proveedor, "Oferta de la materia %d (precio %s)" % (id_materia, d.get("precio_unitario"))
    return {"ok": True}


@ruta("proveedores/<int:id_proveedor>/historial/<int:id_materia>")
def api_historial_precios(id_proveedor, id_materia):
    return {"filas": filas("sp_get_historial_precios", id_proveedor, id_materia)}


# ---------------------------------------------------------------------------
# 4h. Clientes y pedidos de venta
# ---------------------------------------------------------------------------
@ruta("clientes")
def api_clientes():
    return {"filas": filas("sp_cliente_listar", verdadero("inactivos"))}


@ruta("clientes", ("POST",), "OPERARIO", "Clientes", "CREAR")
def api_cliente_crear():
    d = cuerpo()
    nit = texto(d, "nit", maximo=20, etiqueta="NIT")
    r = una("sp_crear_cliente", nit, texto(d, "nombre", etiqueta="Nombre"), texto(d, "telefono", obligatorio=False, maximo=20),
           texto(d, "email", obligatorio=False), texto(d, "ciudad", obligatorio=False, maximo=60))
    g.ref, g.detalle = nit, "Cliente creado: %s" % d.get("nombre")
    return {"id_cliente": list(r.values())[0] if r else None}, 201


@ruta("clientes/<int:id_cliente>", ("PUT",), "OPERARIO", "Clientes", "EDITAR")
def api_cliente_editar(id_cliente):
    d = cuerpo()
    llamar("sp_cliente_actualizar", id_cliente, texto(d, "nombre", etiqueta="Nombre"), texto(d, "telefono", obligatorio=False, maximo=20),
           texto(d, "email", obligatorio=False), texto(d, "ciudad", obligatorio=False, maximo=60))
    g.ref = "CLI-%d" % id_cliente
    return {"ok": True}


@ruta("clientes/<int:id_cliente>/estado", ("POST",), "ADMIN", "Clientes", "CAMBIAR ESTADO")
def api_cliente_estado(id_cliente):
    activo = booleano(cuerpo(), "activo")
    llamar("sp_cliente_estado", id_cliente, activo)
    g.ref, g.detalle = "CLI-%d" % id_cliente, "Activado" if activo else "Desactivado"
    return {"ok": True}


@ruta("clientes/<int:id_cliente>/pedidos")
def api_cliente_pedidos(id_cliente):
    return {"filas": filas("sp_pedidos_cliente", id_cliente)}


@ruta("pedidos")
def api_pedidos():
    return {"filas": filas("sp_get_pedidos", request.args.get("estado") or None)}


@ruta("pedidos", ("POST",), "OPERARIO", "Ventas", "CREAR PEDIDO")
def api_pedido_crear():
    d = cuerpo()
    r = una("sp_crear_pedido", entero(d, "id_cliente", etiqueta="Cliente"), texto(d, "observacion", obligatorio=False, maximo=200))
    nuevo = list(r.values())[0] if r else None
    g.ref = "PED-%s" % nuevo
    return {"id_pedido": nuevo}, 201


@ruta("pedidos/<int:id_pedido>")
def api_pedido(id_pedido):
    return {"filas": filas("sp_pedido_lineas", id_pedido)}


@ruta("pedidos/<int:id_pedido>/lineas", ("POST",), "OPERARIO", "Ventas", "AGREGAR LINEA")
def api_pedido_linea(id_pedido):
    d = cuerpo()
    llamar("sp_agregar_linea_pedido", id_pedido, entero(d, "id_producto", etiqueta="Producto"), entero(d, "cantidad", minimo=1, etiqueta="Cantidad"))
    g.ref, g.detalle = "PED-%d" % id_pedido, "Producto %s x %s" % (d.get("id_producto"), d.get("cantidad"))
    return {"ok": True}, 201


@ruta("pedidos/<int:id_pedido>/lineas/<int:id_producto>", ("DELETE",), "OPERARIO", "Ventas", "QUITAR LINEA")
def api_pedido_quitar(id_pedido, id_producto):
    llamar("sp_quitar_linea_pedido", id_pedido, id_producto)
    g.ref = "PED-%d" % id_pedido
    return {"ok": True}


@ruta("pedidos/<int:id_pedido>/despachar", ("POST",), "OPERARIO", "Ventas", "DESPACHAR")
def api_pedido_despachar(id_pedido):
    llamar("sp_despachar_pedido", id_pedido)
    g.ref, g.detalle = "PED-%d" % id_pedido, "Pedido despachado: se descontaron los productos terminados"
    return {"ok": True}


@ruta("pedidos/<int:id_pedido>/cancelar", ("POST",), "OPERARIO", "Ventas", "CANCELAR PEDIDO")
def api_pedido_cancelar(id_pedido):
    llamar("sp_cancelar_pedido", id_pedido)
    g.ref = "PED-%d" % id_pedido
    return {"ok": True}


# ---------------------------------------------------------------------------
# 4i. Usuarios y bitacora
# ---------------------------------------------------------------------------
@ruta("usuarios", rol="ADMIN")
def api_usuarios():
    return {"filas": filas("sp_usuario_listar")}


@ruta("usuarios", ("POST",), "ADMIN", "Usuarios", "CREAR")
def api_usuario_crear():
    d = cuerpo()
    nombre_usuario = (texto(d, "usuario", maximo=30, etiqueta="Usuario") or "").lower()
    una("sp_usuario_crear", nombre_usuario, texto(d, "nombre", etiqueta="Nombre"), texto(d, "rol", maximo=20, etiqueta="Rol"),
        generate_password_hash(clave_valida(d.get("clave_temporal"))))
    g.ref, g.detalle = nombre_usuario, "Usuario creado con rol %s (debe cambiar la clave al entrar)" % d.get("rol")
    return {"ok": True}, 201


@ruta("usuarios/<int:id_usuario>", ("PUT",), "ADMIN", "Usuarios", "EDITAR")
def api_usuario_editar(id_usuario):
    d = cuerpo()
    llamar("sp_usuario_actualizar", id_usuario, texto(d, "nombre", etiqueta="Nombre"), texto(d, "rol", maximo=20, etiqueta="Rol"), booleano(d, "activo"))
    g.ref, g.detalle = "USR-%d" % id_usuario, "Rol %s, %s" % (d.get("rol"), "activo" if d.get("activo") else "inactivo")
    return {"ok": True}


@ruta("usuarios/<int:id_usuario>/clave", ("POST",), "ADMIN", "Usuarios", "RESTABLECER CLAVE")
def api_usuario_clave(id_usuario):
    llamar("sp_usuario_cambiar_clave", id_usuario, generate_password_hash(clave_valida(cuerpo().get("clave_temporal"))), True)
    g.ref, g.detalle = "USR-%d" % id_usuario, "Clave temporal asignada (debe cambiarla al entrar)"
    return {"ok": True}


def _listar_bitacora(usuario=None):
    pagina = int(request.args["pagina"]) if request.args.get("pagina", "").isdigit() and int(request.args["pagina"]) > 0 else 1
    tam = 30
    desde, hasta = request.args.get("desde") or None, request.args.get("hasta") or None
    for v in (desde, hasta):
        if v and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
            raise ErrorNegocio("Las fechas deben tener formato AAAA-MM-DD.")
    resultado = request.args.get("resultado") or None
    if resultado not in (None, "OK", "ERROR"):
        raise ErrorNegocio("El resultado debe ser OK o ERROR.")
    datos = filas("sp_bitacora_listar", usuario or request.args.get("usuario") or None, request.args.get("modulo") or None,
                  resultado, desde, hasta, tam, (pagina - 1) * tam)
    total = datos[0]["total"] if datos else 0
    for f in datos:
        f.pop("total", None)
        if isinstance(f.get("parametros"), str):
            try:
                f["parametros"] = json.loads(f["parametros"])
            except ValueError:
                pass
    return {"filas": datos, "total": total, "pagina": pagina, "tam": tam}


@ruta("bitacora", rol="ADMIN", auditar=False)
def api_bitacora():
    return _listar_bitacora()


@ruta("bitacora/mia", auditar=False)
def api_bitacora_mia():
    return _listar_bitacora(g.usuario["usuario"])


@app.errorhandler(404)
def no_encontrada(_):
    if request.path.startswith("/api/"):
        return jsonify({"error": "Esa ruta no existe."}), 404
    return send_from_directory(app.static_folder, "index.html")


@app.errorhandler(405)
def metodo_no_permitido(_):
    return jsonify({"error": "Método no permitido."}), 405


@app.errorhandler(413)
def demasiado_grande(_):
    return jsonify({"error": "La solicitud es demasiado grande."}), 413


@app.errorhandler(500)
def error_interno(e):
    app.logger.exception(e)
    return jsonify({"error": "Ocurrió un error inesperado. Inténtalo de nuevo."}), 500


asegurar_admin()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
