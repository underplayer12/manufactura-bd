# Versión 1 de la interfaz (referencia)

`app_v1.py` es la página original: un solo archivo, solo el CRUD de órdenes de producción (con la lista de
inventario al lado), conectada a MySQL como `root`, **sin acceso por usuario y sin registro de solicitudes**.
`test_app_v1.py` son sus pruebas con base simulada. No se usan en la versión actual; se conservan para
comparar (el manual explica qué cambió) y para demostrar la vulnerabilidad "la aplicación entra como root".

Para correrla (solo con la base cargada): `python docs/version_1/app_v1.py` con `DB_HOST=127.0.0.1 DB_PORT=3307`.
