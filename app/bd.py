"""
bd.py - Todo lo que tiene que ver con hablar con MySQL.

Idea clave: la pagina NUNCA arma SQL a mano. Solo llama procedimientos
almacenados ("CALL sp_..."). Asi las reglas del negocio viven en la base y la
pagina solo las usa. Ademas, el usuario de MySQL con el que se conecta
(app_manufactura) solo tiene permiso de EJECUTAR procedimientos.
"""
import os
from datetime import date, datetime
from decimal import Decimal

import pymysql

CONFIG = dict(
    host=os.environ.get("DB_HOST", "host.docker.internal"),
    port=int(os.environ.get("DB_PORT", "3307")),
    user=os.environ.get("DB_USER", "app_manufactura"),
    password=os.environ.get("DB_PASSWORD", "app_manufactura_2026"),
    database=os.environ.get("DB_NAME", "manufactura"),
    charset="utf8mb4",
    autocommit=True,
    connect_timeout=5,
    cursorclass=pymysql.cursors.DictCursor,
)

# Errores de MySQL que significan "no hay conexion" (no es culpa del usuario)
CODIGOS_CONEXION = {1045, 1049, 2002, 2003, 2006, 2013}

# Traduccion de errores tecnicos a frases que entiende quien usa la pagina
MENSAJES = {
    3819: "Esa operación dejaría una existencia negativa o un valor inválido. No se cambió nada.",
    1451: "No se puede borrar: hay otros registros que dependen de este.",
    1452: "Uno de los datos elegidos no existe (producto, cliente, proveedor…).",
    1062: "Ya existe un registro con ese código, NIT o nombre.",
    1406: "Un texto es demasiado largo para ese campo.",
    1264: "Un número está fuera del rango permitido.",
    1305: "La base de datos no tiene instalado el módulo de la aplicación. Ejecuta sql/06_modulo_aplicacion.sql.",
}


class ErrorNegocio(Exception):
    """Error que se le puede mostrar tal cual al usuario (codigo HTTP incluido)."""

    def __init__(self, mensaje, estado=400, extra=None):
        super().__init__(mensaje)
        self.mensaje, self.estado, self.extra = mensaje, estado, extra or {}


def limpiar(valor):
    """Convierte tipos de MySQL (Decimal, fechas) a algo que JSON entienda."""
    if isinstance(valor, Decimal):
        return int(valor) if valor == valor.to_integral_value() else float(valor)
    if isinstance(valor, datetime):
        return valor.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(valor, date):
        return valor.strftime("%Y-%m-%d")
    return valor


def conectar():
    return pymysql.connect(**CONFIG)


def traducir(error):
    """pymysql.Error -> ErrorNegocio con un mensaje amable."""
    codigo = error.args[0] if error.args else 0
    if codigo in CODIGOS_CONEXION:
        return ErrorNegocio("No se pudo conectar con la base de datos.", 503, {"conexion": False})
    if codigo == 1644:                       # SIGNAL de nuestros procedimientos/triggers
        return ErrorNegocio(str(error.args[1]), 400)
    if codigo in MENSAJES:
        return ErrorNegocio(MENSAJES[codigo], 409 if codigo in (1451, 1062) else 400)
    return ErrorNegocio("La base de datos rechazó la operación (código %s)." % codigo, 400)


def llamar(nombre, *args):
    """
    Ejecuta CALL nombre(args) y devuelve TODAS las tablas de resultado
    como lista de listas de diccionarios. Una conexion por llamada (simple y segura).
    """
    try:
        conexion = conectar()
    except pymysql.Error as e:
        raise traducir(e)
    try:
        with conexion.cursor() as cursor:
            marcas = ", ".join(["%s"] * len(args))
            cursor.execute("CALL %s(%s)" % (nombre, marcas), args)
            resultados = []
            while True:
                if cursor.description:
                    resultados.append([{k: limpiar(v) for k, v in f.items()} for f in cursor.fetchall()])
                if not cursor.nextset():
                    break
            return resultados
    except pymysql.Error as e:
        raise traducir(e)
    finally:
        conexion.close()


def filas(nombre, *args):
    """Primera tabla de resultado (lo habitual)."""
    r = llamar(nombre, *args)
    return r[0] if r else []


def una(nombre, *args):
    """Primera fila de la primera tabla, o None."""
    f = filas(nombre, *args)
    return f[0] if f else None
