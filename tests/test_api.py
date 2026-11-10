"""
Pruebas de la aplicacion v2 contra la base de datos REAL (no usa mocks).

Como correrlas (con la base levantada y los scripts 01..06 cargados):
    DB_HOST=127.0.0.1 DB_PORT=3307 python tests/test_api.py          (Linux / Mac)
    $env:DB_HOST="127.0.0.1"; $env:DB_PORT="3307"; python tests\\test_api.py   (PowerShell)

Crean sus propios datos con un sufijo unico, asi que se pueden repetir sin chocar.
Dejan huella en la bitacora (justamente lo que se quiere demostrar).
"""
import os
import sys
import time
import unittest
import uuid

_aqui = os.path.dirname(os.path.abspath(__file__))
for _ruta in (os.path.join(_aqui, "..", "app"), os.path.join(_aqui, "..")):   # carpeta del repo o dentro del contenedor (/app)
    if os.path.exists(os.path.join(_ruta, "app.py")):
        sys.path.insert(0, _ruta)
os.environ.setdefault("SECRET_KEY", "clave-de-pruebas")
import app as m  # noqa: E402
import bd  # noqa: E402

SUF = uuid.uuid4().hex[:6]
CLAVE_ADMIN = os.environ.get("ADMIN_CLAVE_INICIAL", "Admin2026!")
NUEVA = "Segura2026x"


class Sesion:
    """Un 'navegador': guarda la cookie de sesion entre solicitudes."""

    def __init__(self):
        self.c = m.app.test_client()

    def pedir(self, metodo, ruta, datos=None, cabecera=True):
        h = {"X-Requested-With": "fetch"} if cabecera else {}
        r = self.c.open("/api/" + ruta, method=metodo, json=datos, headers=h)
        return r.status_code, (r.get_json(silent=True) if r.is_json else r.get_data(as_text=True))

    def get(self, ruta): return self.pedir("GET", ruta)
    def post(self, ruta, datos=None): return self.pedir("POST", ruta, datos or {})
    def put(self, ruta, datos): return self.pedir("PUT", ruta, datos)
    def delete(self, ruta): return self.pedir("DELETE", ruta)


def entrar(usuario, clave):
    s = Sesion()
    est, d = s.post("login", {"usuario": usuario, "clave": clave})
    assert est == 200, (usuario, est, d)
    return s


def admin():
    """Sesion de admin lista para trabajar (maneja el cambio de clave obligatorio de la 1a vez)."""
    s = Sesion()
    for clave in (NUEVA, CLAVE_ADMIN):
        est, d = s.post("login", {"usuario": "admin", "clave": clave})
        if est == 200:
            if d["debe_cambiar_clave"]:
                est, d = s.post("cambiar-clave", {"clave_actual": clave, "clave_nueva": NUEVA})
                assert est == 200, d
            return s
    raise AssertionError("No se pudo entrar como admin")


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.adm = admin()

    def bitacora(self, **filtros):
        q = "&".join("%s=%s" % kv for kv in filtros.items())
        est, d = self.adm.get("bitacora?" + q)
        self.assertEqual(est, 200)
        return d


class T1_Acceso(Base):
    def test_salud_publica(self):
        self.assertEqual(Sesion().get("salud")[0], 200)

    def test_sin_sesion_no_hay_datos(self):
        for ruta in ("dashboard", "ordenes", "clientes", "usuarios", "bitacora"):
            est, d = Sesion().get(ruta)
            self.assertEqual(est, 401, ruta)
            self.assertTrue(d.get("login"))

    def test_login_incorrecto_queda_en_bitacora(self):
        s = Sesion()
        est, _ = s.post("login", {"usuario": "admin", "clave": "mala-" + SUF})
        self.assertEqual(est, 401)
        est, d = s.post("login", {"usuario": "no.existe." + SUF, "clave": "x"})
        self.assertEqual(est, 401)
        self.assertEqual(d["error"], "Usuario o clave incorrectos.")            # no delata si el usuario existe
        b = self.bitacora(modulo="Acceso", resultado="ERROR")
        self.assertTrue(any(f["usuario"] == "no.existe." + SUF for f in b["filas"]))

    def test_politica_de_clave(self):
        nombre = "pol" + SUF
        self.adm.post("usuarios", {"usuario": nombre, "nombre": "Politica", "rol": "CONSULTA", "clave_temporal": "Temporal1x"})
        s = entrar(nombre, "Temporal1x")
        est, d = s.post("cambiar-clave", {"clave_actual": "Temporal1x", "clave_nueva": "corta1"})
        self.assertEqual(est, 400)
        est, d = s.post("cambiar-clave", {"clave_actual": "Temporal1x", "clave_nueva": "soloLetrasLargas"})
        self.assertEqual(est, 400)
        est, d = s.post("cambiar-clave", {"clave_actual": "equivocada1", "clave_nueva": "Nueva2026ok"})
        self.assertEqual(est, 400)
        # mientras no cambie la clave, no puede usar nada mas
        self.assertEqual(s.get("dashboard")[0], 403)
        self.assertEqual(s.post("cambiar-clave", {"clave_actual": "Temporal1x", "clave_nueva": "Nueva2026ok"})[0], 200)
        self.assertEqual(s.get("dashboard")[0], 200)

    def test_clave_nunca_en_bitacora(self):
        nombre = "sec" + SUF
        self.adm.post("usuarios", {"usuario": nombre, "nombre": "Secreto", "rol": "CONSULTA", "clave_temporal": "ClaveSecreta9"})
        b = self.bitacora(modulo="Usuarios")
        texto = str(b)
        self.assertNotIn("ClaveSecreta9", texto)
        self.assertIn("***", texto)

    def test_hash_en_base_no_es_la_clave(self):
        filas = bd.filas("sp_usuario_listar")
        self.assertTrue(filas)
        self.assertNotIn("clave_hash", filas[0])                                  # ni siquiera se lista
        h = bd.una("sp_usuario_login", "admin")["clave_hash"]
        self.assertNotIn(NUEVA, h)
        self.assertNotIn(CLAVE_ADMIN, h)

    def test_csrf_exige_cabecera(self):
        est, d = Sesion().pedir("POST", "logout", {}, cabecera=False)
        self.assertEqual(est, 401)                                                # sin sesion
        est, d = self.adm.pedir("POST", "ordenes", {"id_producto": 1, "cantidad": 1}, cabecera=False)
        self.assertEqual(est, 400)


class T2_Roles(Base):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        for u, rol in (("op" + SUF, "OPERARIO"), ("co" + SUF, "CONSULTA")):
            cls.adm.post("usuarios", {"usuario": u, "nombre": "Prueba " + rol, "rol": rol, "clave_temporal": "Temporal1x"})
            s = entrar(u, "Temporal1x")
            s.post("cambiar-clave", {"clave_actual": "Temporal1x", "clave_nueva": "Definitiva1x"})
        cls.op, cls.co = entrar("op" + SUF, "Definitiva1x"), entrar("co" + SUF, "Definitiva1x")

    def test_consulta_solo_mira(self):
        self.assertEqual(self.co.get("ordenes")[0], 200)
        self.assertEqual(self.co.get("reportes/ventas")[0], 200)
        est, d = self.co.post("ordenes", {"id_producto": 1, "cantidad": 1})
        self.assertEqual(est, 403)
        self.assertIn("CONSULTA", d["error"])
        self.assertEqual(self.co.get("usuarios")[0], 403)
        self.assertEqual(self.co.get("bitacora")[0], 403)
        self.assertEqual(self.co.get("bitacora/mia")[0], 200)

    def test_operario_opera_pero_no_administra(self):
        self.assertEqual(self.op.post("productos", {"codigo": "X" + SUF, "nombre": "x", "precio_venta": 1})[0], 403)
        self.assertEqual(self.op.post("bodegas", {"codigo": "B" + SUF, "nombre": "x"})[0], 403)
        self.assertEqual(self.op.get("usuarios")[0], 403)
        self.assertEqual(self.op.post("clientes", {"nit": "8" + SUF, "nombre": "Cliente " + SUF, "ciudad": "Cali"})[0], 201)

    def test_denegados_quedan_en_bitacora(self):
        self.co.post("ordenes", {"id_producto": 1, "cantidad": 1})
        b = self.bitacora(usuario="co" + SUF, resultado="ERROR")
        self.assertTrue(any(f["accion"] == "ACCESO DENEGADO" and f["http_estado"] == 403 for f in b["filas"]))

    def test_desactivar_expulsa_al_instante(self):
        nombre = "baja" + SUF
        self.adm.post("usuarios", {"usuario": nombre, "nombre": "Baja", "rol": "CONSULTA", "clave_temporal": "Temporal1x"})
        s = entrar(nombre, "Temporal1x")
        s.post("cambiar-clave", {"clave_actual": "Temporal1x", "clave_nueva": "Definitiva1x"})
        self.assertEqual(s.get("ordenes")[0], 200)
        uid = next(u["id_usuario"] for u in self.adm.get("usuarios")[1]["filas"] if u["usuario"] == nombre)
        self.assertEqual(self.adm.put("usuarios/%d" % uid, {"nombre": "Baja", "rol": "CONSULTA", "activo": False})[0], 200)
        self.assertEqual(s.get("ordenes")[0], 401)
        self.assertEqual(Sesion().post("login", {"usuario": nombre, "clave": "Definitiva1x"})[0], 401)

    def test_siempre_queda_un_admin(self):
        activos = [u for u in self.adm.get("usuarios")[1]["filas"] if u["rol"] == "ADMIN" and u["activo"]]
        if len(activos) == 1:
            est, d = self.adm.put("usuarios/%d" % activos[0]["id_usuario"], {"nombre": "Administrador", "rol": "CONSULTA", "activo": True})
            self.assertEqual(est, 400)
            self.assertIn("administrador", d["error"])

    def test_bloqueo_por_intentos(self):
        nombre = "lock" + SUF
        self.adm.post("usuarios", {"usuario": nombre, "nombre": "Bloqueo", "rol": "CONSULTA", "clave_temporal": "Temporal1x"})
        s = Sesion()
        estados = [s.post("login", {"usuario": nombre, "clave": "mal"})[0] for _ in range(m.MAX_INTENTOS)]
        self.assertEqual(estados, [401] * m.MAX_INTENTOS)
        self.assertEqual(s.post("login", {"usuario": nombre, "clave": "Temporal1x"})[0], 429)   # ni con la clave buena


class T3_FlujoCompleto(Base):
    """Camino completo del negocio, como lo haria la empresa."""

    def test_flujo(self):
        a = self.adm
        # --- catalogos (ADMIN)
        est, bod = a.post("bodegas", {"codigo": "T" + SUF.upper(), "nombre": "Bodega prueba " + SUF, "ubicacion": "Patio"})
        self.assertEqual(est, 201, bod)
        est, mp = a.post("materias", {"codigo": "M" + SUF, "nombre": "Tela prueba " + SUF, "unidad_medida": "m", "stock_minimo": 10, "id_bodega": bod["id_bodega"]})
        self.assertEqual(est, 201, mp)
        est, pv = a.post("proveedores", {"nit": "9" + SUF, "nombre": "Proveedor prueba " + SUF, "telefono": "300"})
        self.assertEqual(est, 201, pv)
        self.assertEqual(a.put("proveedores/%d/ofertas/%d" % (pv["id_proveedor"], mp["id_materia_prima"]),
                               {"pais_origen": "Colombia", "precio_unitario": 5000, "tiempo_entrega_dias": 3})[0], 200)
        est, pr = a.post("productos", {"codigo": "P" + SUF, "nombre": "Cojin prueba " + SUF, "precio_venta": 80000})
        self.assertEqual(est, 201, pr)
        self.assertEqual(a.put("productos/%d/receta/%d" % (pr["id_producto"], mp["id_materia_prima"]), {"cantidad_por_unidad": 2})[0], 200)
        est, rec = a.get("productos/%d/receta" % pr["id_producto"])
        self.assertEqual(rec["filas"][0]["cantidad_por_unidad"], 2)

        # codigo duplicado -> mensaje amable
        est, d = a.post("productos", {"codigo": "P" + SUF, "nombre": "Otro", "precio_venta": 1})
        self.assertEqual(est, 409)
        self.assertIn("Ya existe", d["error"])

        # --- sin materia prima no se puede completar, y no se descuenta nada
        est, o = a.post("ordenes", {"id_producto": pr["id_producto"], "cantidad": 10})
        self.assertEqual(est, 201, o)
        est, d = a.post("ordenes/%d/completar" % o["id_orden"])
        self.assertEqual(est, 400)
        self.assertEqual(self._producto(pr["id_producto"])["stock_actual"], 0)

        # --- compra con lote (suma stock; trigger lo reparte en la bodega)
        est, c = a.post("compras", {"id_materia_prima": mp["id_materia_prima"], "id_proveedor": pv["id_proveedor"], "cantidad": 100,
                                    "id_bodega": bod["id_bodega"], "lote_proveedor": "LP-" + SUF})
        self.assertEqual(est, 201, c)
        self.assertEqual(self._materia(mp["id_materia_prima"])["stock_actual"], 100)
        # proveedor que no vende esa materia
        est, d = a.post("compras", {"id_materia_prima": 1, "id_proveedor": pv["id_proveedor"], "cantidad": 5})
        self.assertEqual(est, 400)

        # --- editar y completar la orden: 10 x 2 = 20 de materia
        self.assertEqual(a.put("ordenes/%d" % o["id_orden"], {"cantidad": 12})[0], 200)
        self.assertEqual(a.post("ordenes/%d/completar" % o["id_orden"])[0], 200)
        self.assertEqual(self._materia(mp["id_materia_prima"])["stock_actual"], 76)       # 100 - 12*2
        self.assertEqual(self._producto(pr["id_producto"])["stock_actual"], 12)
        # una orden completada no se edita ni se borra
        self.assertEqual(a.put("ordenes/%d" % o["id_orden"], {"cantidad": 1})[0], 400)
        self.assertEqual(a.delete("ordenes/%d" % o["id_orden"])[0], 400)

        # --- traslado entre bodegas
        est, bod2 = a.post("bodegas", {"codigo": "U" + SUF.upper(), "nombre": "Bodega 2 " + SUF})
        est, d = a.post("traslados", {"id_materia_prima": mp["id_materia_prima"], "id_origen": bod["id_bodega"], "id_destino": bod2["id_bodega"], "cantidad": 26})
        self.assertEqual(est, 201, d)
        est, ub = a.get("materias/%d/bodegas" % mp["id_materia_prima"])
        self.assertEqual({f["bodega_codigo"]: f["cantidad"] for f in ub["filas"]}, {"T" + SUF.upper(): 50, "U" + SUF.upper(): 26})
        est, d = a.post("traslados", {"id_materia_prima": mp["id_materia_prima"], "id_origen": bod["id_bodega"], "id_destino": bod2["id_bodega"], "cantidad": 9999})
        self.assertEqual(est, 400)

        # --- cliente, pedido y despacho
        est, cl = a.post("clientes", {"nit": "7" + SUF, "nombre": "Cliente flujo " + SUF, "ciudad": "Bogota"})
        self.assertEqual(est, 201, cl)
        est, pe = a.post("pedidos", {"id_cliente": cl["id_cliente"]})
        self.assertEqual(est, 201, pe)
        self.assertEqual(a.post("pedidos/%d/lineas" % pe["id_pedido"], {"id_producto": pr["id_producto"], "cantidad": 20})[0], 201)
        est, d = a.post("pedidos/%d/despachar" % pe["id_pedido"])                     # solo hay 12
        self.assertEqual(est, 400)
        self.assertEqual(self._producto(pr["id_producto"])["stock_actual"], 12)
        self.assertEqual(a.post("pedidos/%d/lineas" % pe["id_pedido"], {"id_producto": pr["id_producto"], "cantidad": -8})[0], 400)
        self.assertEqual(a.delete("pedidos/%d/lineas/%d" % (pe["id_pedido"], pr["id_producto"]))[0], 200)
        self.assertEqual(a.post("pedidos/%d/lineas" % pe["id_pedido"], {"id_producto": pr["id_producto"], "cantidad": 12})[0], 201)
        self.assertEqual(a.post("pedidos/%d/despachar" % pe["id_pedido"])[0], 200)
        self.assertEqual(self._producto(pr["id_producto"])["stock_actual"], 0)
        est, lin = a.get("pedidos/%d" % pe["id_pedido"])
        self.assertEqual(lin["filas"][0]["subtotal"], 960000)
        est, ped_cli = a.get("clientes/%d/pedidos" % cl["id_cliente"])
        self.assertEqual(ped_cli["filas"][0]["estado"], "DESPACHADO")

        # --- desactivar en vez de borrar
        self.assertEqual(a.post("productos/%d/estado" % pr["id_producto"], {"activo": False})[0], 200)
        est, d = a.post("ordenes", {"id_producto": pr["id_producto"], "cantidad": 1})
        self.assertEqual(est, 400)
        self.assertEqual(a.post("materias/%d/estado" % mp["id_materia_prima"], {"activo": False})[0], 400)   # aun tiene existencias

        # --- todo quedo en la bitacora
        b = self.bitacora(modulo="Ventas")
        acciones = {f["accion"] for f in b["filas"]}
        self.assertTrue({"CREAR PEDIDO", "AGREGAR LINEA", "DESPACHAR"} <= acciones, acciones)
        despacho = next(f for f in b["filas"] if f["accion"] == "DESPACHAR" and f["resultado"] == "OK")
        self.assertEqual(despacho["usuario"], "admin")
        self.assertEqual(despacho["referencia"], "PED-%d" % pe["id_pedido"])
        fallo = next(f for f in b["filas"] if f["accion"] == "DESPACHAR" and f["resultado"] == "ERROR")
        self.assertTrue(fallo["detalle"])

        # --- la base sigue cuadrada
        self._verificar_integridad()

    def _producto(self, id_producto):
        return next(p for p in self.adm.get("productos?inactivos=1")[1]["filas"] if p["id_producto"] == id_producto)

    def _materia(self, id_materia):
        return next(x for x in self.adm.get("materias?inactivas=1")[1]["filas"] if x["id_materia_prima"] == id_materia)

    def _verificar_integridad(self):
        """stock = suma de lotes = suma de bodegas, en TODAS las materias."""
        inv = {x["id_materia_prima"]: x["stock_actual"] for x in self.adm.get("materias?inactivas=1")[1]["filas"]}
        por_bodega = {}
        for f in self.adm.get("inventario/bodegas")[1]["filas"]:
            por_bodega[f["id_materia_prima"]] = por_bodega.get(f["id_materia_prima"], 0) + f["cantidad"]
        for id_m, stock in inv.items():
            self.assertAlmostEqual(stock, por_bodega.get(id_m, 0), places=3, msg="materia %s" % id_m)


class T4_Entradas(Base):
    def test_datos_invalidos(self):
        a = self.adm
        for cuerpo in ({"id_producto": 1, "cantidad": -5}, {"id_producto": 1, "cantidad": 0}, {"id_producto": 1, "cantidad": "abc"},
                       {"id_producto": 1, "cantidad": 2.5}, {"cantidad": 3}, {"id_producto": "uno", "cantidad": 3}):
            self.assertEqual(a.post("ordenes", cuerpo)[0], 400, cuerpo)
        self.assertEqual(a.pedir("POST", "ordenes", None)[0], 400)
        self.assertEqual(Sesion().post("login", {"usuario": "x", "clave": 1})[0], 401)

    def test_inyeccion_sql_es_texto_inofensivo(self):
        est, d = self.adm.post("clientes", {"nit": "1" + SUF, "nombre": "Robert'); DROP TABLE cliente;-- " + SUF, "ciudad": "x"})
        self.assertEqual(est, 201)
        est, d = self.adm.get("clientes")
        self.assertTrue(any("DROP TABLE" in c["nombre"] for c in d["filas"]))      # se guardo como texto, la tabla sigue viva
        est, d = Sesion().post("login", {"usuario": "admin' OR '1'='1", "clave": "' OR '1'='1"})
        self.assertEqual(est, 401)

    def test_ruta_inexistente_y_metodo(self):
        self.assertEqual(self.adm.get("no-existe")[0], 404)
        self.assertEqual(self.adm.pedir("PATCH", "ordenes", {})[0], 405)

    def test_bd_con_minimo_privilegio(self):
        """La conexion de la pagina no puede leer ni borrar tablas directamente."""
        con = bd.conectar()
        try:
            with con.cursor() as cur:
                for sql in ("SELECT * FROM usuario", "DELETE FROM bitacora", "DROP TABLE cliente"):
                    with self.assertRaises(Exception):
                        cur.execute(sql)
        finally:
            con.close()


class T5_Reportes(Base):
    def test_reportes_con_datos(self):
        for nombre in ("produccion", "compras", "ventas", "clientes", "inventario", "reponer"):
            est, d = self.adm.get("reportes/" + nombre)
            self.assertEqual(est, 200, nombre)
            self.assertTrue(len(d["filas"]) > 0, nombre)
        self.assertEqual(self.adm.get("reportes/otro")[0], 404)

    def test_dashboard(self):
        est, d = self.adm.get("dashboard")
        self.assertEqual(est, 200)
        self.assertGreater(d["resumen"]["ventas_total"], 0)

    def test_csv_y_bitacora(self):
        r = self.adm.c.get("/api/reportes/ventas/descargar")
        self.assertEqual(r.status_code, 200)
        self.assertIn("text/csv", r.content_type)
        self.assertIn("total_vendido", r.get_data(as_text=True))
        b = self.bitacora(modulo="Reportes")
        self.assertTrue(any(f["accion"] == "DESCARGAR CSV" for f in b["filas"]))

    def test_filtros_bitacora(self):
        est, d = self.adm.get("bitacora?desde=2026-01-01&hasta=2099-12-31&resultado=OK&pagina=1")
        self.assertEqual(est, 200)
        self.assertTrue(all(f["resultado"] == "OK" for f in d["filas"]))
        self.assertGreater(d["total"], 0)
        self.assertEqual(self.adm.get("bitacora?desde=ayer")[0], 400)
        self.assertEqual(self.adm.get("bitacora?resultado=TAL")[0], 400)


if __name__ == "__main__":
    unittest.main(verbosity=2)
