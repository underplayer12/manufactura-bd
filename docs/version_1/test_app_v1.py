import json
import os
import tempfile
import re
import shutil
import subprocess
import sys
from datetime import datetime
from decimal import Decimal

import pymysql

import os as _os, sys as _sys
_sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '..', 'app'))
import app as m

MODO = {"error": None}
LLAMADAS = []


class Cursor:
    def __init__(self):
        self.filas = []

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def execute(self, sql, params=()):
        LLAMADAS.append((" ".join(sql.split()), params))
        if MODO["error"] and "DROP PROCEDURE" not in sql and "CREATE PROCEDURE" not in sql:
            raise pymysql.err.OperationalError(*MODO["error"])
        self.filas = []
        if "sp_get_ordenes" in sql:
            self.filas = [{"id_orden": 1, "producto": "Silla", "cantidad": 40, "estado": "COMPLETADA",
                           "fecha_creacion": datetime(2026, 9, 15, 8, 0), "fecha_cierre": datetime(2026, 9, 18, 16, 0)}]
        elif "sp_get_inventario" in sql:
            self.filas = [{"codigo": "MP-001", "nombre": "Lámina", "unidad_medida": "KG",
                           "stock_actual": Decimal("191.000"), "stock_minimo": Decimal("300.500"), "estado": "REABASTECER"}]
        elif "FROM producto" in sql:
            self.filas = [{"id_producto": 1, "codigo": "PR-001", "nombre": "Silla", "stock_actual": 70, "max_producible": 55}]
        elif "sp_crear_orden" in sql:
            self.filas = [{"id_orden_creada": 12, "maximo_producible_hoy": 55}]

    def fetchall(self):
        return self.filas


class Conexion:
    def cursor(self):
        return Cursor()

    def close(self):
        pass


m.conectar = lambda: Conexion()
cliente = m.app.test_client()


def ver(titulo, resp):
    print(titulo, resp.status_code, json.dumps(resp.get_json(), ensure_ascii=False))
    return resp


# --- Rutas de lectura
r = ver("GET ordenes   ", cliente.get("/api/ordenes"))
assert r.get_json()["datos"][0]["fecha_creacion"] == "2026-09-15 08:00"
r = ver("GET inventario", cliente.get("/api/inventario"))
assert r.get_json()["datos"][0]["stock_actual"] == 191 and r.get_json()["datos"][0]["stock_minimo"] == 300.5
r = ver("GET productos ", cliente.get("/api/productos"))
assert r.get_json()["datos"][0]["max_producible"] == 55

# --- Crear, editar, completar, cancelar, eliminar
r = ver("POST crear    ", cliente.post("/api/ordenes", json={"id_producto": 1, "cantidad": 5}))
assert r.status_code == 201 and r.get_json()["datos"][0]["id_orden_creada"] == 12
r = ver("POST invalido ", cliente.post("/api/ordenes", json={"id_producto": "", "cantidad": "x"}))
assert r.status_code == 400
ver("PUT editar    ", cliente.put("/api/ordenes/9", json={"cantidad": 8}))
ver("POST completar", cliente.post("/api/ordenes/9/completar"))
ver("POST cancelar ", cliente.post("/api/ordenes/9/cancelar"))
ver("DELETE        ", cliente.delete("/api/ordenes/9"))

# --- Errores traducidos
MODO["error"] = (3819, "Check constraint 'ck_mp_stock_no_negativo' is violated.")
r = ver("ERR stock     ", cliente.post("/api/ordenes/9/completar"))
assert r.status_code == 400 and "No hay materia prima suficiente" in r.get_json()["mensaje"]

MODO["error"] = (1644, "Solo se pueden eliminar ordenes pendientes o canceladas")
r = ver("ERR signal    ", cliente.delete("/api/ordenes/1"))
assert r.get_json()["mensaje"].startswith("Solo se pueden eliminar")

MODO["error"] = (2003, "Can't connect to MySQL server")
r = ver("ERR conexion  ", cliente.get("/api/ordenes"))
assert r.status_code == 503 and r.get_json()["conexion"] is False

# --- Llamadas SQL hechas
print("\nSQL ejecutado (sin DROP/CREATE):")
for sql, params in LLAMADAS:
    if sql.startswith("CALL") or sql.startswith("SELECT"):
        print("  ", sql[:90], params)

# --- Pagina y JavaScript
pagina = cliente.get("/")
assert pagina.status_code == 200 and "Órdenes de producción" in pagina.get_data(as_text=True)
codigo_js = re.search(r"<script>(.*)</script>", m.PAGINA, re.S).group(1)
RUTA_JS = os.path.join(tempfile.gettempdir(), "pagina_manufactura.js")
open(RUTA_JS, "w", encoding="utf-8").write(codigo_js)
if shutil.which("node"):
    r = subprocess.run(["node", "--check", RUTA_JS], capture_output=True, text=True)
    print("\nnode --check:", "OK" if r.returncode == 0 else r.stderr)
    assert r.returncode == 0
else:
    print("\nnode no disponible: JavaScript sin revisar")
print("\nTODO BIEN")
