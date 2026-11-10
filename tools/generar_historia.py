#!/usr/bin/env python3
"""Genera datos_historicos.sql: catálogo ampliado + 12 meses de operación.

Simula la fábrica semana a semana (compras -> órdenes -> consumo -> despachos)
y escribe llamadas a procedimientos auxiliares. La simulación mantiene el
mismo saldo que calculará MySQL, así que el script nunca deja stock negativo.
Todo es determinista (semilla fija): siempre produce el mismo archivo.
"""
import math
import random
import sys
from datetime import datetime, timedelta
from decimal import Decimal as D

rnd = random.Random(2026)
SALIDA = sys.argv[1]

# ---------------------------------------------------------------- catálogo
PROV_NUEVOS = [
    ("901236478-2", "Cauchos y Plásticos Industriales S.A.S.", "6043115520", "ventas@cauchosyplasticos.com.co"),
    ("860512394-8", "Cerraduras y Chapas de Colombia Ltda.", "6013489027", "pedidos@cerradurasycolombia.com.co"),
    ("890412765-3", "Vidrios Templados del Eje S.A.", "6063352218", "comercial@vidriosdeleje.com.co"),
    ("901377820-9", "Aluminios Extruidos de Antioquia S.A.S.", "6044128836", "cotizaciones@aluminiosantioquia.com.co"),
    ("811027345-6", "Fibras y Textiles de Medellín S.A.", "6042661940", "ventas@fibrasytextiles.com.co"),
    ("900845119-1", "Logística y Empaques del Norte S.A.S.", "6053471258", "servicio@empaquesdelnorte.com.co"),
]
NIT = {  # proveedores existentes por posición original + nuevos
    1: "900412378-5", 2: "830215664-1", 3: "890305127-9", 4: "901128450-3",
    5: "860045982-7", 6: "900776231-2", 7: "901554093-6", 8: "890902117-4",
    9: "901236478-2", 10: "860512394-8", 11: "890412765-3", 12: "901377820-9",
    13: "811027345-6", 14: "900845119-1",
}

# codigo, nombre, unidad, stock_minimo
MP_NUEVAS = [
    ("MP-011", "Cerradura de seguridad para archivador", "UND", 25),
    ("MP-012", "Vidrio templado 6 mm para cubierta", "UND", 10),
    ("MP-013", "Perfil de aluminio 40 x 20 mm", "M", 60),
    ("MP-014", "Tapa plástica para tubo cuadrado", "UND", 200),
    ("MP-015", "Pegante de contacto industrial (galón)", "GAL", 4),
    ("MP-016", "Rollo de cinta de embalaje 48 mm", "UND", 10),
    ("MP-017", "Base giratoria cromada cinco puntas", "UND", 20),
    ("MP-018", "Pistón neumático clase 3", "UND", 20),
]
PR_NUEVOS = [  # codigo, nombre, precio, semana de lanzamiento (0 = 4 ago 2025)
    ("PR-006", "Silla de visitante fija", 165000, 30),
    ("PR-007", "Mesa auxiliar con cubierta de vidrio", 340000, 30),
    ("PR-008", "Gabinete bajo con puertas", 455000, 35),
    ("PR-009", "Silla gerencial ejecutiva", 790000, 39),
]

# proveedor (n.º), materia, país, precio actual COP, días de entrega
PMP_NUEVOS = [
    (9, "MP-014", "Colombia", 350.00, 2), (9, "MP-008", "Colombia", 3100.00, 3),
    (10, "MP-011", "Colombia", 12500.00, 4), (7, "MP-011", "China", 8200.00, 38),
    (11, "MP-012", "Colombia", 96000.00, 6),
    (12, "MP-013", "Colombia", 15800.00, 5),
    (13, "MP-007", "Colombia", 16900.00, 3), (13, "MP-006", "Colombia", 44500.00, 4),
    (13, "MP-015", "Colombia", 148000.00, 3),
    (14, "MP-010", "Colombia", 4150.00, 4), (14, "MP-016", "Colombia", 6900.00, 2),
    (7, "MP-017", "China", 31000.00, 40), (5, "MP-017", "Colombia", 42000.00, 3),
    (7, "MP-018", "China", 11800.00, 40), (5, "MP-018", "Colombia", 16500.00, 3),
    (7, "MP-014", "China", 210.00, 38), (7, "MP-016", "China", 4200.00, 40),
    (12, "MP-002", "Colombia", 8300.00, 5),
]

# Recetas nuevas (los productos 1 a 5 NO se tocan)
REC_NUEVAS = {
    "PR-006": {"MP-002": "3.8000", "MP-004": "0.1500", "MP-005": "10.0000", "MP-006": "0.1500",
               "MP-007": "0.9000", "MP-014": "4.0000", "MP-016": "0.0500", "MP-010": "1.0000"},
    "PR-007": {"MP-013": "5.2000", "MP-012": "1.0000", "MP-005": "12.0000", "MP-014": "4.0000",
               "MP-008": "4.0000", "MP-016": "0.0500", "MP-010": "1.0000"},
    "PR-008": {"MP-001": "18.0000", "MP-011": "1.0000", "MP-004": "0.9000", "MP-005": "36.0000",
               "MP-015": "0.0200", "MP-009": "4.0000", "MP-016": "0.0500", "MP-010": "1.0000"},
    "PR-009": {"MP-017": "1.0000", "MP-018": "1.0000", "MP-006": "0.4000", "MP-007": "1.6000",
               "MP-002": "3.0000", "MP-005": "14.0000", "MP-015": "0.0300", "MP-016": "0.0500",
               "MP-010": "1.0000"},
}
# Recetas ya existentes (solo lectura aquí: se necesitan para simular el consumo)
REC_VIEJAS = {
    "PR-001": {"MP-001": "2.5", "MP-002": "4.5", "MP-004": "0.3", "MP-005": "16", "MP-006": "0.25",
               "MP-007": "1.2", "MP-008": "5", "MP-010": "1"},
    "PR-002": {"MP-003": "2", "MP-002": "9", "MP-004": "0.4", "MP-005": "30", "MP-010": "2"},
    "PR-003": {"MP-001": "28", "MP-009": "8", "MP-004": "1.2", "MP-005": "40", "MP-010": "1"},
    "PR-004": {"MP-001": "14", "MP-004": "0.8", "MP-005": "48", "MP-010": "1"},
    "PR-005": {"MP-003": "3", "MP-002": "14", "MP-004": "0.6", "MP-005": "24", "MP-010": "2"},
}
RECETA = {p: {m: D(c) for m, c in r.items()} for p, r in {**REC_VIEJAS, **REC_NUEVAS}.items()}

# Proveedores por materia: (n.º proveedor, precio actual, país, días)
OFERTA = {
    "MP-001": [(1, 4850, 3), (2, 5100, 2), (7, 4050, 40)],
    "MP-002": [(1, 7800, 3), (2, 8150, 2), (12, 8300, 5)],
    "MP-003": [(3, 78000, 4), (7, 71500, 30)],
    "MP-004": [(4, 21500, 5), (7, 18900, 38)],
    "MP-005": [(5, 38, 2), (7, 24, 40)],
    "MP-006": [(6, 46000, 4), (13, 44500, 4)],
    "MP-007": [(6, 17800, 4), (13, 16900, 3), (7, 13900, 45)],
    "MP-008": [(9, 3100, 3), (5, 3400, 3), (7, 2100, 38)],
    "MP-009": [(5, 14500, 3), (7, 9800, 38)],
    "MP-010": [(8, 4300, 5), (14, 4150, 4)],
    "MP-011": [(10, 12500, 4), (7, 8200, 38)],
    "MP-012": [(11, 96000, 6)],
    "MP-013": [(12, 15800, 5)],
    "MP-014": [(9, 350, 2), (7, 210, 38)],
    "MP-015": [(13, 148000, 3)],
    "MP-016": [(14, 6900, 2), (7, 4200, 40)],
    "MP-017": [(5, 42000, 3), (7, 31000, 40)],
    "MP-018": [(5, 16500, 3), (7, 11800, 40)],
}
LOTE = {"MP-001": 25, "MP-002": 20, "MP-003": 10, "MP-004": 5, "MP-005": 500, "MP-006": 10,
        "MP-007": 10, "MP-008": 100, "MP-009": 50, "MP-010": 50, "MP-011": 10, "MP-012": 5,
        "MP-013": 20, "MP-014": 100, "MP-015": 1, "MP-016": 10, "MP-017": 10, "MP-018": 10}
MINIMO = {c: m for c, _, _, m in MP_NUEVAS}
NUEVAS = set(MINIMO)
NOMBRE_MP = {"MP-001": "lámina", "MP-002": "tubo", "MP-003": "MDF", "MP-004": "pintura",
             "MP-005": "tornillería", "MP-006": "espuma", "MP-007": "tela", "MP-008": "rodachines",
             "MP-009": "rieles", "MP-010": "cajas", "MP-011": "cerraduras", "MP-012": "vidrio",
             "MP-013": "perfil aluminio", "MP-014": "tapas", "MP-015": "pegante", "MP-016": "cinta",
             "MP-017": "bases giratorias", "MP-018": "pistones"}

# producto -> (min, max, paso, peso de aparición)
RANGO = {"PR-001": (30, 60, 5, 5), "PR-002": (10, 25, 5, 3), "PR-003": (6, 14, 2, 3),
         "PR-004": (15, 30, 5, 3), "PR-005": (4, 9, 1, 2), "PR-006": (20, 50, 5, 3),
         "PR-007": (8, 20, 4, 2), "PR-008": (8, 16, 4, 2), "PR-009": (10, 25, 5, 2)}
LANZAMIENTO = {c: s for c, _, _, s in PR_NUEVOS}
CLIENTES = ["Oficinas Modernas S.A.S.", "Colegio San Ignacio", "Clínica del Norte S.A.",
            "Constructora Altos del Valle", "Distribuidora de Muebles Capital",
            "Universidad Regional (compras)", "Coworking Nodo 21", "Alcaldía Municipal (dotación)",
            "Banco Andino sucursal Centro", "Hotel Plaza Real", "Cooperativa Agrofuturo",
            "Notaría 14 del Círculo"]

INICIO = datetime(2025, 8, 4)      # lunes
SEMANAS = 52                       # hasta el 27 de julio de 2026
FIN_PERIODO = datetime(2026, 8, 2, 20, 0)


def sql(s):
    return "'" + s.replace("'", "''") + "'"


def f(dt):
    return sql(dt.strftime("%Y-%m-%d %H:%M:%S"))


def num(x):
    x = D(x)
    return format(x.normalize(), "f") if x != x.to_integral() else str(int(x))


def costo(precio, fecha):
    """Precio de entonces: el catálogo actual menos ~0,5 % por cada mes hacia atrás."""
    meses = max(0, (datetime(2026, 8, 1) - fecha).days / 30.0)
    v = precio * (1 - 0.005 * meses)
    paso = 50 if precio >= 1000 else 1
    return max(paso, int(round(v / paso)) * paso)


# ---------------------------------------------------------------- simulación
saldo = {c: D(0) for c in OFERTA}          # saldo virtual del periodo
sal_prod = {c: 0 for c in RECETA}
lineas = []
n_oc = 0
n_op = 0
n_compra = n_orden = n_desp = n_salida = 0
ultimo_completado_nuevo = {}

for sem in range(SEMANAS):
    lunes = INICIO + timedelta(weeks=sem)
    cuarto_final = sem >= SEMANAS - 5
    # --- órdenes de la semana
    n = 3 + (1 if sem % 3 == 0 else 0) + rnd.choice([0, 0, 1])
    activos = [c for c in RANGO if LANZAMIENTO.get(c, 0) <= sem]
    pesos = [RANGO[c][3] for c in activos]
    ordenes = []
    for k in range(n):
        prod = rnd.choices(activos, pesos)[0]
        lo, hi, paso, _ = RANGO[prod]
        cant = rnd.randrange(lo, hi + 1, paso)
        creada = lunes + timedelta(days=rnd.randint(0, 2), hours=rnd.randint(8, 15),
                                   minutes=rnd.choice([0, 10, 20, 30, 40, 50]))
        horas = rnd.randint(48, 90)
        n_op += 1
        estado = "CANCELADA" if n_op % 11 == 0 else "COMPLETADA"
        ordenes.append((creada, prod, cant, horas, estado))
    ordenes.sort()

    # --- necesidad de materia prima de las órdenes que sí se fabrican
    necesidad = {}
    for creada, prod, cant, horas, estado in ordenes:
        if estado == "COMPLETADA":
            for mp, c in RECETA[prod].items():
                necesidad[mp] = necesidad.get(mp, D(0)) + c * cant

    # --- compras del lunes (recepción 06:30-07:50, antes de las órdenes)
    for i, mp in enumerate(sorted(necesidad)):
        falta = necesidad[mp] - saldo[mp]
        oferta = OFERTA[mp]
        locales = [o for o in oferta if o[2] < 30]
        importados = [o for o in oferta if o[2] >= 30]
        compra_import = (importados and lunes.day <= 7 and not cuarto_final and necesidad[mp] > 0
                         and (mp in NUEVAS or sem % 2 == 0) and necesidad[mp] >= 2 * LOTE[mp] * 0.1)
        if compra_import:
            objetivo = 3 * necesidad[mp] - saldo[mp]
            prov = importados[0]
            obs = "Importación"
        elif falta > 0:
            objetivo = falta
            prov = (locales or importados)[(sem + i) % len(locales or importados)]
            obs = "Compra"
        else:
            continue
        if objetivo <= 0:
            continue
        cant = int(math.ceil(objetivo / LOTE[mp])) * LOTE[mp]
        fecha = lunes + timedelta(hours=6, minutes=30 + 4 * i)
        n_oc += 1
        precio = costo(prov[1], fecha)
        lineas.append(f"CALL sp_mig_compra({sql(mp)}, {sql(NIT[prov[0]])}, {cant}, {precio}, "
                      f"{f(fecha)}, {sql(f'{obs} OC-2026-H{n_oc:03d} {NOMBRE_MP[mp]}')});")
        saldo[mp] += cant
        n_compra += 1

    # --- órdenes y despachos
    for creada, prod, cant, horas, estado in ordenes:
        lineas.append(f"CALL sp_mig_orden({sql(prod)}, {cant}, {f(creada)}, {horas}, {sql(estado)});")
        n_orden += 1
        if estado == "COMPLETADA":
            for mp, c in RECETA[prod].items():
                saldo[mp] -= c * cant
                assert saldo[mp] >= 0, (sem, mp)
            cierre = creada + timedelta(hours=horas)
            sal_prod[prod] += cant
            ultimo_completado_nuevo[prod] = (cierre, cant)
            lineas.append(("DESP", prod, cant, cierre))

# --- despachos: productos viejos salen completos; los nuevos dejan en bodega la última orden
final = []
for it in lineas:
    if isinstance(it, tuple):
        _, prod, cant, cierre = it
        if prod in LANZAMIENTO and ultimo_completado_nuevo[prod] == (cierre, cant):
            final.append(f"-- ({prod}: esta última producción queda en bodega, sin despachar)")
            continue
        partes = [cant]
        if cant >= 20 and rnd.random() < 0.4:      # a veces se reparte entre dos clientes
            a = (cant // 2 // 5) * 5 or cant // 2
            partes = [a, cant - a]
        for j, q in enumerate(partes):
            fecha = cierre + timedelta(days=1 + j, hours=2)
            final.append(f"CALL sp_mig_despacho({sql(prod)}, {q}, {f(fecha)}, {sql(rnd.choice(CLIENTES))});")
            n_desp += 1
    else:
        final.append(it)
lineas = final

# --- cierre del periodo
cierre_lineas = []
for mp in sorted(saldo):
    if mp in NUEVAS:
        # Que las materias nuevas terminen con un colchón sobre su mínimo
        meta = D(MINIMO[mp]) * D("2.5")
        if saldo[mp] < meta:
            cant = int(math.ceil((meta - saldo[mp]) / LOTE[mp])) * LOTE[mp]
            prov = [o for o in OFERTA[mp] if o[2] < 30][0]
            fecha = datetime(2026, 7, 31, 9, 0)
            n_oc += 1
            cierre_lineas.append(f"CALL sp_mig_compra({sql(mp)}, {sql(NIT[prov[0]])}, {cant}, "
                                 f"{costo(prov[1], fecha)}, {f(fecha)}, "
                                 f"{sql(f'Reposición OC-2026-H{n_oc:03d} {NOMBRE_MP[mp]}')});")
            saldo[mp] += cant
            n_compra += 1
    elif saldo[mp] > 0:
        cierre_lineas.append(f"CALL sp_mig_salida({sql(mp)}, {num(saldo[mp])}, {f(FIN_PERIODO)}, "
                             f"'Ajuste por inventario físico y mermas - cierre de julio 2026');")
        n_salida += 1
        saldo[mp] = D(0)

# ---------------------------------------------------------------- escritura
out = []
w = out.append
w("""-- =====================================================================
-- DATOS HISTÓRICOS: catálogo ampliado + 12 meses de operación
-- (4 de agosto de 2025 a 2 de agosto de 2026)
-- Ejecutar DESPUÉS de mejoras_estructura.sql
--
-- QUÉ AGREGA
--   * 6 proveedores, 8 materias primas y 4 productos nuevos (con recetas)
--   * compras, órdenes de producción, consumos y despachos de todo un año
--
-- QUÉ NO TOCA (por diseño)
--   * Nada de lo anterior se borra ni se modifica: ni proveedores, ni recetas
--     de los productos 1 a 5, ni sus 11 órdenes, ni los precios.
--   * El historial nuevo es anterior al 4 de agosto de 2026 (donde empezaban tus
--     datos) y queda en neto cero para las 10 materias y 5 productos originales:
--     el stock de hoy es EXACTAMENTE el mismo de antes (la OP-9 sigue fallando por falta
--     de MDF y la OP-10 sigue alcanzando).
--   * Todo se hace con los mismos mecanismos reales (trigger de kardex y
--     sp_completar_orden): el stock lo calcula la base, no se escribe a mano.
--   * Se puede ejecutar UNA vez; si se repite, no hace nada (lo detecta solo).
--
-- NOTA: nombres de empresas, NIT y clientes son ficticios. Precios en COP.
-- =====================================================================

SET NAMES utf8mb4;
USE manufactura;

DELIMITER $$

-- Ayudantes temporales (se borran al final) ------------------------------
DROP PROCEDURE IF EXISTS sp_mig_requisito$$
CREATE PROCEDURE sp_mig_requisito()
BEGIN
  IF NOT EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'mejoras_estructura') THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'Primero ejecuta mejoras_estructura.sql';
  END IF;
  -- @mig_omitir = 1 hace que los ayudantes no hagan nada (script ya aplicado)
  SET @mig_omitir = EXISTS (SELECT 1 FROM migracion_log WHERE nombre = 'datos_historicos');
END$$

DROP PROCEDURE IF EXISTS sp_mig_compra$$
CREATE PROCEDURE sp_mig_compra(IN p_mp VARCHAR(20), IN p_nit VARCHAR(20), IN p_cant DECIMAL(12,3),
                               IN p_costo DECIMAL(12,2), IN p_fecha DATETIME, IN p_obs VARCHAR(200))
BEGIN
  DECLARE v_mp INT;
  DECLARE v_prov INT;
  IF @mig_omitir = 0 THEN
    -- Los ids se buscan ANTES del INSERT: el trigger del kardex actualiza materia_prima
    -- y MySQL no permite que el mismo INSERT también lea esa tabla.
    SELECT id_materia_prima INTO v_mp FROM materia_prima WHERE codigo = p_mp;
    SELECT id_proveedor INTO v_prov FROM proveedor WHERE nit = p_nit;
    INSERT INTO movimiento_inventario
           (id_materia_prima, tipo, cantidad, costo_unitario, fecha, id_proveedor, observacion)
    VALUES (v_mp, 'ENTRADA', p_cant, p_costo, p_fecha, v_prov, p_obs);
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_mig_salida$$
CREATE PROCEDURE sp_mig_salida(IN p_mp VARCHAR(20), IN p_cant DECIMAL(12,3),
                               IN p_fecha DATETIME, IN p_obs VARCHAR(200))
BEGIN
  DECLARE v_mp INT;
  IF @mig_omitir = 0 THEN
    SELECT id_materia_prima INTO v_mp FROM materia_prima WHERE codigo = p_mp;
    INSERT INTO movimiento_inventario (id_materia_prima, tipo, cantidad, fecha, observacion)
    VALUES (v_mp, 'SALIDA', p_cant, p_fecha, p_obs);
  END IF;
END$$

-- Crea la orden. Si es COMPLETADA la procesa con el procedimiento real
-- (sp_completar_orden) y luego acomoda las fechas al pasado, igual que en el script original.
DROP PROCEDURE IF EXISTS sp_mig_orden$$
CREATE PROCEDURE sp_mig_orden(IN p_prod VARCHAR(20), IN p_cant INT, IN p_creada DATETIME,
                              IN p_horas INT, IN p_estado VARCHAR(20))
BEGIN
  DECLARE v_id INT;
  IF @mig_omitir = 0 THEN
    IF p_estado = 'CANCELADA' THEN
      INSERT INTO orden_produccion (id_producto, cantidad, estado, fecha_creacion, fecha_cierre)
      SELECT id_producto, p_cant, 'CANCELADA', p_creada, DATE_ADD(p_creada, INTERVAL 20 HOUR)
        FROM producto WHERE codigo = p_prod;
    ELSE
      INSERT INTO orden_produccion (id_producto, cantidad, fecha_creacion)
      SELECT id_producto, p_cant, p_creada FROM producto WHERE codigo = p_prod;
      SET v_id = LAST_INSERT_ID();
      CALL sp_completar_orden(v_id);
      UPDATE orden_produccion SET fecha_cierre = DATE_ADD(fecha_creacion, INTERVAL p_horas HOUR)
       WHERE id_orden = v_id;
      UPDATE movimiento_inventario m JOIN orden_produccion o ON o.id_orden = m.id_orden
         SET m.fecha = o.fecha_cierre
       WHERE m.id_orden = v_id;
    END IF;
  END IF;
END$$

DROP PROCEDURE IF EXISTS sp_mig_despacho$$
CREATE PROCEDURE sp_mig_despacho(IN p_prod VARCHAR(20), IN p_cant INT,
                                 IN p_fecha DATETIME, IN p_cliente VARCHAR(100))
BEGIN
  DECLARE v_prod INT;
  IF @mig_omitir = 0 THEN
    SELECT id_producto INTO v_prod FROM producto WHERE codigo = p_prod;
    INSERT INTO despacho (id_producto, cantidad, fecha, cliente, observacion)
    VALUES (v_prod, p_cant, p_fecha, p_cliente, 'Entrega a cliente');
  END IF;
END$$

DELIMITER ;

CALL sp_mig_requisito();

-- ---------------------------------------------------------------------
-- 1. CATÁLOGO NUEVO (INSERT IGNORE: si ya existe, lo respeta)
-- ---------------------------------------------------------------------
""")
w("INSERT IGNORE INTO proveedor (nit, nombre, telefono, email) VALUES")
w(",\n".join(f" ({sql(a)}, {sql(b)}, {sql(c)}, {sql(d)})" for a, b, c, d in PROV_NUEVOS) + ";\n")
w("INSERT IGNORE INTO materia_prima (codigo, nombre, unidad_medida, stock_minimo) VALUES")
w(",\n".join(f" ({sql(a)}, {sql(b)}, {sql(c)}, {d})" for a, b, c, d in MP_NUEVAS) + ";\n")
w("INSERT IGNORE INTO producto (codigo, nombre, precio_venta) VALUES")
w(",\n".join(f" ({sql(a)}, {sql(b)}, {c}.00)" for a, b, c, _ in PR_NUEVOS) + ";\n")
w("-- Qué vende cada proveedor (se enlaza por NIT y por código, no por número de id)")
w("INSERT IGNORE INTO proveedor_materia_prima (id_proveedor, id_materia_prima, pais_origen, precio_unitario, tiempo_entrega_dias)")
w("SELECT p.id_proveedor, m.id_materia_prima, v.pais, v.precio, v.dias FROM (")
w("\n UNION ALL\n".join(f"  SELECT {sql(NIT[pv])} AS nit, {sql(mp)} AS cod, {sql(pa)} AS pais, {pr:.2f} AS precio, {d} AS dias"
                       for pv, mp, pa, pr, d in PMP_NUEVOS))
w(") v JOIN proveedor p ON p.nit = v.nit JOIN materia_prima m ON m.codigo = v.cod;\n")
w("-- Recetas de los productos nuevos")
w("INSERT IGNORE INTO receta (id_producto, id_materia_prima, cantidad_por_unidad)")
w("SELECT pr.id_producto, m.id_materia_prima, v.cant FROM (")
w("\n UNION ALL\n".join(f"  SELECT {sql(pc)} AS prod, {sql(mp)} AS cod, {c} AS cant"
                       for pc, r in REC_NUEVAS.items() for mp, c in r.items()))
w(") v JOIN producto pr ON pr.codigo = v.prod JOIN materia_prima m ON m.codigo = v.cod;\n")
w("-- ---------------------------------------------------------------------")
w(f"-- 2. HISTORIAL: {n_compra} compras, {n_orden} órdenes, {n_desp} despachos, {n_salida} ajustes de cierre")
w("-- ---------------------------------------------------------------------")
out.extend(lineas)
w("")
w("-- Cierre del periodo: ajustes de inventario de las materias originales y reposición de las nuevas")
out.extend(cierre_lineas)
w("""
-- ---------------------------------------------------------------------
-- 3. CIERRE: constancia y limpieza de ayudantes
-- ---------------------------------------------------------------------
INSERT IGNORE INTO migracion_log (nombre) VALUES ('datos_historicos');

DROP PROCEDURE IF EXISTS sp_mig_requisito;
DROP PROCEDURE IF EXISTS sp_mig_compra;
DROP PROCEDURE IF EXISTS sp_mig_salida;
DROP PROCEDURE IF EXISTS sp_mig_orden;
DROP PROCEDURE IF EXISTS sp_mig_despacho;
SET @mig_omitir = NULL;

-- ---------------------------------------------------------------------
-- 4. VERIFICACIONES (ejecutar una a la vez)
-- ---------------------------------------------------------------------
-- 4.1 Conciliación: stock guardado = suma del kardex (la columna 'diferencia' debe ser 0 en todas)
-- SELECT mp.codigo, mp.stock_actual,
--        COALESCE(SUM(CASE WHEN m.tipo='ENTRADA' THEN m.cantidad ELSE -m.cantidad END),0) AS stock_kardex,
--        mp.stock_actual - COALESCE(SUM(CASE WHEN m.tipo='ENTRADA' THEN m.cantidad ELSE -m.cantidad END),0) AS diferencia
--   FROM materia_prima mp LEFT JOIN movimiento_inventario m ON m.id_materia_prima = mp.id_materia_prima
--  GROUP BY mp.id_materia_prima, mp.codigo, mp.stock_actual;
--
-- 4.2 Producto terminado = producido - despachado
-- SELECT pr.codigo, pr.stock_actual,
--        COALESCE((SELECT SUM(cantidad) FROM orden_produccion WHERE id_producto=pr.id_producto AND estado='COMPLETADA'),0)
--      - COALESCE((SELECT SUM(cantidad) FROM despacho WHERE id_producto=pr.id_producto),0) AS esperado
--   FROM producto pr;
--
-- 4.3 Volumen por tabla
-- SELECT 'ordenes' t, COUNT(*) n FROM orden_produccion UNION ALL SELECT 'movimientos', COUNT(*) FROM movimiento_inventario
-- UNION ALL SELECT 'despachos', COUNT(*) FROM despacho UNION ALL SELECT 'proveedores', COUNT(*) FROM proveedor;
--
-- 4.4 Las pruebas de antes siguen igual: OP-9 debe FALLAR y OP-10 debe funcionar
-- CALL sp_completar_orden(9);   -- error: falta MDF (hay 32, necesita 40)
-- CALL sp_completar_orden(10);  -- funciona
""")

open(SALIDA, "w", encoding="utf-8").write("\n".join(out))
print(f"compras={n_compra} ordenes={n_orden} despachos={n_desp} ajustes={n_salida}")
