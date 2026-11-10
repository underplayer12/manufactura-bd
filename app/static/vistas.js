/* vistas.js - una funcion por modulo de la pagina. Cada una pinta dentro de #contenido y se vuelve a pintar
   sola despues de cada cambio (asi lo que ves siempre es lo que hay en la base). */
"use strict";

const V = (() => {
  const { h, fmt, insignia, puede, GET, POST, PUT, DEL, hacer, aviso, modal, cerrarModal, confirmar, formulario, tabla, boton, pestanas } = N;
  const opc = (filas, v, t) => filas.map((f) => ({ v: f[v], t: typeof t === "function" ? t(f) : f[t] }));
  const cabecera = (titulo, sub, ...acciones) =>
    h("div", { class: "cabecera" }, h("div", null, h("h1", { texto: titulo }), sub ? h("p", { texto: sub }) : null), h("div", { class: "acciones-cab" }, acciones));
  const cargando = (cont) => cont.replaceChildren(h("div", { class: "vacio", texto: "Cargando…" }));
  const falla = (cont, e) => cont.replaceChildren(h("div", { class: "aviso rojo", role: "alert", texto: e.message }));
  const toggleInactivos = (marcado, alCambiar, etiqueta = "Mostrar inactivos") =>
    h("label", { class: "casilla" }, h("input", { type: "checkbox", checked: marcado, onchange: (e) => alCambiar(e.target.checked) }), etiqueta);

  /* ================= INICIO ================= */
  async function inicio(cont) {
    cargando(cont);
    let d;
    try { d = await GET("dashboard"); } catch (e) { return falla(cont, e); }
    const r = d.resumen;
    const dato = (n, t, cls = "") => h("div", { class: "dato " + cls }, h("div", { class: "n", texto: n }), h("div", { class: "t", texto: t }));
    cont.replaceChildren(
      cabecera("Inicio", "Resumen de la operación en este momento"),
      h("div", { class: "rejilla" },
        dato(fmt.num(r.ordenes_pendientes), "Órdenes de producción pendientes", r.ordenes_pendientes ? "info" : ""),
        dato(fmt.num(r.materias_reponer), "Materias primas por reponer", r.materias_reponer ? "alerta" : "ok"),
        dato(fmt.num(r.pedidos_abiertos), "Pedidos de venta abiertos", r.pedidos_abiertos ? "info" : ""),
        dato(fmt.dinero(r.ventas_total), "Ventas despachadas (total)", "ok"),
        dato(fmt.num(r.ordenes_completadas), "Órdenes completadas"),
        dato(fmt.num(r.productos_activos), "Productos activos"),
        dato(fmt.num(r.clientes_activos), "Clientes activos"),
        dato(fmt.num(r.proveedores_activos), "Proveedores activos")),
      h("div", { class: "panel" }, h("h2", { texto: "Qué conviene reponer" }),
        h("p", { class: "pie-nota", texto: "Materias primas en o por debajo de su mínimo, con el proveedor activo más barato para cada una." }),
        tabla([
          { t: "Código", k: "codigo" }, { t: "Materia prima", k: "nombre" },
          { t: "Existencia", num: true, f: (f) => `${fmt.num(f.stock_actual)} ${f.unidad_medida}` },
          { t: "Mínimo", num: true, f: (f) => fmt.num(f.stock_minimo) },
          { t: "Proveedor sugerido", f: (f) => f.proveedor ? `${f.proveedor} (${f.pais_origen})` : insignia("Sin proveedor", "rojo") },
          { t: "Precio", num: true, f: (f) => (f.precio_unitario ? fmt.dinero(f.precio_unitario) : null) },
          { t: "Entrega", num: true, f: (f) => (f.tiempo_entrega_dias != null ? f.tiempo_entrega_dias + " d" : null) },
          { t: "", acc: true, f: (f) => (puede("OPERARIO") && f.id_proveedor ? boton("Registrar compra", () => formCompra(() => inicio(cont), f), "primario") : null) },
        ], d.reponer, { vacio: "Todo el inventario está por encima de su mínimo. 👍" })));
  }

  /* ================= ÓRDENES ================= */
  let filtroOrden = "";
  async function ordenes(cont) {
    cargando(cont);
    let filas;
    try { filas = (await GET("ordenes" + (filtroOrden ? "?estado=" + filtroOrden : ""))).filas; } catch (e) { return falla(cont, e); }
    const refrescar = () => ordenes(cont);
    const chips = h("div", { class: "chips" }, [["", "Todas"], ["PENDIENTE", "Pendientes"], ["COMPLETADA", "Completadas"], ["CANCELADA", "Canceladas"]].map(([v, t]) =>
      h("button", { type: "button", "aria-pressed": String(filtroOrden === v), onclick: () => { filtroOrden = v; refrescar(); } }, t)));
    cont.replaceChildren(
      cabecera("Órdenes de producción", "Al completar una orden se descuentan las materias primas (por lotes, el más antiguo primero) y sube el stock del producto.",
        puede("OPERARIO") ? h("button", { class: "btn primario", type: "button", onclick: () => formOrden(refrescar) }, "+ Nueva orden") : null),
      h("div", { class: "panel" }, h("div", { class: "filtros" }, chips),
        tabla([
          { t: "Orden", f: (f) => "OP-" + f.id_orden }, { t: "Producto", k: "producto" },
          { t: "Cantidad", num: true, f: (f) => fmt.num(f.cantidad) }, { t: "Estado", f: (f) => insignia(f.estado) },
          { t: "Creada", f: (f) => fmt.fecha(f.fecha_creacion) }, { t: "Cerrada", f: (f) => fmt.fecha(f.fecha_cierre) },
          { t: "", acc: true, f: (f) => (!puede("OPERARIO") || f.estado !== "PENDIENTE" ? (puede("OPERARIO") && f.estado === "CANCELADA" ? boton("Eliminar", () => eliminarOrden(f, refrescar), "peligro") : null) : [
            boton("Editar", () => editarOrden(f, refrescar)),
            boton("Completar", () => completarOrden(f, refrescar), "primario"),
            boton("Cancelar", () => cancelarOrden(f, refrescar)),
            boton("Eliminar", () => eliminarOrden(f, refrescar), "peligro")]) },
        ], filas, { vacio: "No hay órdenes con ese filtro." })));
  }
  async function formOrden(refrescar) {
    let prods;
    try { prods = (await GET("productos")).filas; } catch (e) { return aviso(e.message, true); }
    formulario({
      titulo: "Nueva orden de producción", boton: "Crear orden",
      campos: [
        { n: "id_producto", et: "Producto", tipo: "select", req: true, num: true, opciones: opc(prods, "id_producto", (p) => `${p.codigo} · ${p.nombre} (se pueden fabricar ${fmt.num(p.max_producible)} con lo que hay)`) },
        { n: "cantidad", et: "Cantidad a fabricar", tipo: "number", req: true, min: 1, paso: 1 }],
      enviar: async (d) => { const r = await POST("ordenes", d); aviso("Orden OP-" + r.id_orden + " creada"); refrescar(); },
    });
  }
  function editarOrden(o, refrescar) {
    formulario({ titulo: "Editar OP-" + o.id_orden, nota: "Solo se puede cambiar la cantidad de una orden pendiente.",
      campos: [{ n: "cantidad", et: o.producto + " — cantidad", tipo: "number", req: true, min: 1, paso: 1 }], valores: { cantidad: o.cantidad },
      enviar: async (d) => { await PUT("ordenes/" + o.id_orden, d); aviso("Orden actualizada"); refrescar(); } });
  }
  async function completarOrden(o, refrescar) {
    if (!(await confirmar("Completar OP-" + o.id_orden, `Se fabricarán ${fmt.num(o.cantidad)} × ${o.producto}. Se descontará la materia prima del inventario. ¿Continuar?`, "Completar"))) return;
    if (await hacer(() => POST("ordenes/" + o.id_orden + "/completar"), "Orden completada: inventario actualizado")) refrescar();
  }
  async function cancelarOrden(o, refrescar) {
    if (!(await confirmar("Cancelar OP-" + o.id_orden, "La orden pasará a CANCELADA. No se descuenta nada del inventario.", "Cancelar orden", true))) return;
    if (await hacer(() => POST("ordenes/" + o.id_orden + "/cancelar"), "Orden cancelada")) refrescar();
  }
  async function eliminarOrden(o, refrescar) {
    if (!(await confirmar("Eliminar OP-" + o.id_orden, "Se borra la orden definitivamente (queda constancia en el historial). ¿Seguro?", "Eliminar", true))) return;
    if (await hacer(() => DEL("ordenes/" + o.id_orden), "Orden eliminada")) refrescar();
  }

  /* ================= INVENTARIO ================= */
  let pestanaInv = "existencias", verInactivasMP = false;
  async function inventario(cont) {
    const refrescar = () => inventario(cont);
    const cambiar = (id) => { pestanaInv = id; refrescar(); };
    cargando(cont);
    let cuerpo, acciones = [];
    try {
      if (pestanaInv === "existencias") {
        const filas = (await GET("materias" + (verInactivasMP ? "?inactivas=1" : ""))).filas;
        if (puede("ADMIN")) acciones.push(h("button", { class: "btn", type: "button", onclick: () => formMateria(refrescar) }, "+ Nueva materia prima"));
        if (puede("OPERARIO")) acciones.push(h("button", { class: "btn", type: "button", onclick: () => formTraslado(refrescar) }, "Trasladar entre bodegas"),
          h("button", { class: "btn primario", type: "button", onclick: () => formCompra(refrescar) }, "+ Registrar compra"));
        cuerpo = h("div", { class: "panel" }, h("div", { class: "filtros" }, puede("ADMIN") ? toggleInactivos(verInactivasMP, (v) => { verInactivasMP = v; refrescar(); }, "Mostrar inactivas") : null),
          tabla([
            { t: "Código", k: "codigo" }, { t: "Materia prima", k: "nombre" },
            { t: "Existencia", num: true, f: (f) => `${fmt.num(f.stock_actual)} ${f.unidad_medida}` }, { t: "Mínimo", num: true, f: (f) => fmt.num(f.stock_minimo) },
            { t: "Estado", f: (f) => (f.activo ? insignia(f.estado) : insignia("Inactiva")) }, { t: "Bodega habitual", k: "bodega" },
            { t: "", acc: true, f: (f) => [boton("Detalle", () => detalleMateria(f)),
              puede("ADMIN") ? boton("Editar", () => formMateria(refrescar, f)) : null,
              puede("ADMIN") ? boton(f.activo ? "Desactivar" : "Activar", () => estadoMateria(f, refrescar), f.activo ? "peligro" : "") : null] },
          ], filas, { claseFila: (f) => (f.activo ? "" : "inactivo") }));
      } else if (pestanaInv === "bodegas-stock") {
        const filas = (await GET("inventario/bodegas")).filas;
        cuerpo = h("div", { class: "panel" }, h("h2", { texto: "Existencias por bodega" }), tabla([
          { t: "Bodega", f: (f) => `${f.bodega_codigo} · ${f.bodega}` }, { t: "Código", k: "codigo" }, { t: "Materia prima", k: "materia_prima" },
          { t: "Cantidad", num: true, f: (f) => `${fmt.num(f.cantidad)} ${f.unidad_medida}` }], filas));
      } else if (pestanaInv === "compras") {
        const filas = (await GET("compras")).filas;
        if (puede("OPERARIO")) acciones.push(h("button", { class: "btn primario", type: "button", onclick: () => formCompra(refrescar) }, "+ Registrar compra"));
        cuerpo = h("div", { class: "panel" }, h("h2", { texto: "Últimas compras" }), tabla([
          { t: "Fecha", f: (f) => fmt.fecha(f.fecha) }, { t: "Lote", k: "codigo_lote" }, { t: "Materia prima", f: (f) => `${f.codigo} · ${f.materia}` }, { t: "Proveedor", k: "proveedor" },
          { t: "Cantidad", num: true, f: (f) => `${fmt.num(f.cantidad)} ${f.unidad_medida}` }, { t: "Costo unit.", num: true, f: (f) => fmt.dinero(f.costo_unitario) },
          { t: "Total", num: true, f: (f) => fmt.dinero(f.total) }, { t: "Bodega", k: "bodega" }], filas));
      } else {
        const filas = (await GET("bodegas")).filas;
        if (puede("ADMIN")) acciones.push(h("button", { class: "btn primario", type: "button", onclick: () => formBodega(refrescar) }, "+ Nueva bodega"));
        cuerpo = h("div", { class: "panel" }, tabla([
          { t: "Código", k: "codigo" }, { t: "Nombre", k: "nombre" }, { t: "Ubicación", k: "ubicacion" }, { t: "Materias guardadas", num: true, k: "materias" },
          { t: "Estado", f: (f) => insignia(f.activa ? "Activa" : "Inactiva", f.activa ? "verde" : "gris") },
          { t: "", acc: true, f: (f) => (puede("ADMIN") ? boton("Editar", () => formBodega(refrescar, f)) : null) }], filas, { claseFila: (f) => (f.activa ? "" : "inactivo") }));
      }
    } catch (e) { return falla(cont, e); }
    cont.replaceChildren(cabecera("Inventario", "Existencias, compras con lote, traslados entre bodegas y trazabilidad.", ...acciones),
      pestanas([{ id: "existencias", t: "Existencias" }, { id: "bodegas-stock", t: "Por bodega" }, { id: "compras", t: "Compras" }, { id: "bodegas", t: "Bodegas" }], pestanaInv, cambiar), cuerpo);
  }

  async function estadoMateria(m, refrescar) {
    const nuevo = !m.activo;
    if (!(await confirmar((nuevo ? "Activar " : "Desactivar ") + m.nombre, nuevo ? "Volverá a poder usarse en recetas y compras." : "Ya no aparecerá en compras ni recetas, pero se conserva su historial.", nuevo ? "Activar" : "Desactivar", !nuevo))) return;
    if (await hacer(() => POST("materias/" + m.id_materia_prima + "/estado", { activo: nuevo }), nuevo ? "Materia activada" : "Materia desactivada")) refrescar();
  }
  async function formMateria(refrescar, m) {
    let bodegas;
    try { bodegas = (await GET("bodegas")).filas.filter((b) => b.activa || (m && b.id_bodega === m.id_bodega_predeterminada)); } catch (e) { return aviso(e.message, true); }
    formulario({
      titulo: m ? "Editar " + m.codigo : "Nueva materia prima", valores: m ? { ...m, id_bodega: m.id_bodega_predeterminada } : {},
      campos: [
        { n: "codigo", et: "Código", req: true, maxlen: 20, deshab: !!m, mitad: true }, { n: "unidad_medida", et: "Unidad de medida", req: true, maxlen: 10, mitad: true, ayuda: "KG, M, UND, L…" },
        { n: "nombre", et: "Nombre", req: true, maxlen: 100 },
        { n: "stock_minimo", et: "Stock mínimo (alerta de reposición)", tipo: "number", req: true, min: 0, mitad: true },
        { n: "id_bodega", et: "Bodega habitual", tipo: "select", num: true, vacio: "— sin bodega —", opciones: opc(bodegas, "id_bodega", "nombre"), mitad: true }],
      enviar: async (d) => { if (m) await PUT("materias/" + m.id_materia_prima, d); else await POST("materias", d); aviso(m ? "Materia actualizada" : "Materia creada"); refrescar(); },
    });
  }
  function formBodega(refrescar, b) {
    formulario({
      titulo: b ? "Editar bodega" : "Nueva bodega", valores: b ? { ...b } : { activa: true },
      campos: [{ n: "codigo", et: "Código", req: true, maxlen: 20, deshab: !!b, mitad: true }, { n: "nombre", et: "Nombre", req: true, maxlen: 100, mitad: true },
        { n: "ubicacion", et: "Ubicación", maxlen: 100 }, b ? { n: "activa", et: "Bodega activa", tipo: "check", ayuda: "No se puede desactivar si todavía guarda existencias." } : null].filter(Boolean),
      enviar: async (d) => { if (b) await PUT("bodegas/" + b.id_bodega, d); else await POST("bodegas", d); aviso(b ? "Bodega actualizada" : "Bodega creada"); refrescar(); },
    });
  }
  async function formCompra(refrescar, sugerida) {
    let mats, bods;
    try { [mats, bods] = await Promise.all([GET("materias"), GET("bodegas")]); } catch (e) { return aviso(e.message, true); }
    const idInicial = sugerida ? sugerida.id_materia_prima : mats.filas[0].id_materia_prima;
    formulario({
      titulo: "Registrar compra de materia prima", boton: "Registrar compra", valores: { id_materia_prima: idInicial },
      nota: "La compra crea un lote nuevo, suma la existencia y queda en el kardex con su costo (el precio vigente del proveedor).",
      campos: [
        { n: "id_materia_prima", et: "Materia prima", tipo: "select", req: true, num: true, opciones: opc(mats.filas, "id_materia_prima", (m) => `${m.codigo} · ${m.nombre} (hay ${fmt.num(m.stock_actual)} ${m.unidad_medida})`) },
        { n: "id_proveedor", et: "Proveedor", tipo: "select", req: true, num: true, opciones: [] },
        { n: "cantidad", et: "Cantidad", tipo: "number", req: true, min: 0.001, mitad: true },
        { n: "id_bodega", et: "Bodega de destino", tipo: "select", num: true, vacio: "La habitual de la materia", opciones: opc(bods.filas.filter((b) => b.activa), "id_bodega", "nombre"), mitad: true },
        { n: "lote_proveedor", et: "Lote del proveedor (opcional)", maxlen: 40, mitad: true }, { n: "fecha_vencimiento", et: "Vence (opcional)", tipo: "date", mitad: true },
        { n: "observacion", et: "Observación (opcional)", maxlen: 200 }],
      enviar: async (d) => { const r = await POST("compras", d); aviso(`Compra registrada: lote ${r.compra.codigo_lote}`); refrescar(); },
    });
    const selM = N.$("#f-id_materia_prima"), selP = N.$("#f-id_proveedor");
    const cargarProv = async () => {
      selP.replaceChildren();
      try {
        const provs = (await GET("materias/" + selM.value + "/proveedores")).filas;
        if (!provs.length) selP.append(h("option", { value: "" }, "Esta materia no tiene proveedores"));
        provs.forEach((p) => selP.append(h("option", { value: p.id_proveedor }, `${p.proveedor} · ${fmt.dinero(p.precio_unitario)} · ${p.tiempo_entrega_dias} d`)));
        if (sugerida && sugerida.id_proveedor && selM.value == sugerida.id_materia_prima) selP.value = String(sugerida.id_proveedor);
      } catch (e) { aviso(e.message, true); }
    };
    selM.addEventListener("change", cargarProv); cargarProv();
  }
  async function formTraslado(refrescar) {
    let mats, bods;
    try { [mats, bods] = await Promise.all([GET("materias"), GET("bodegas")]); } catch (e) { return aviso(e.message, true); }
    const ob = opc(bods.filas.filter((b) => b.activa), "id_bodega", (b) => `${b.codigo} · ${b.nombre}`);
    formulario({
      titulo: "Trasladar entre bodegas", boton: "Trasladar", nota: "Mueve existencias de una bodega a otra. La existencia total no cambia.",
      campos: [{ n: "id_materia_prima", et: "Materia prima", tipo: "select", req: true, num: true, opciones: opc(mats.filas, "id_materia_prima", (m) => `${m.codigo} · ${m.nombre}`) },
        { n: "id_origen", et: "Desde", tipo: "select", req: true, num: true, opciones: ob, mitad: true }, { n: "id_destino", et: "Hasta", tipo: "select", req: true, num: true, opciones: ob, mitad: true },
        { n: "cantidad", et: "Cantidad", tipo: "number", req: true, min: 0.001 }],
      enviar: async (d) => { await POST("traslados", d); aviso("Traslado registrado"); refrescar(); },
    });
  }
  function detalleMateria(m) {
    let pestana = "kardex", pagina = 1;
    const cuerpo = h("div"), traza = h("div");
    const pintar = async () => {
      cuerpo.replaceChildren(h("div", { class: "vacio", texto: "Cargando…" })); traza.replaceChildren();
      try {
        let nodo;
        if (pestana === "kardex") {
          const r = await GET(`materias/${m.id_materia_prima}/kardex?pagina=${pagina}`);
          nodo = h("div", null, tabla([{ t: "Fecha", f: (f) => fmt.fecha(f.fecha) }, { t: "Tipo", f: (f) => insignia(f.tipo) }, { t: "Cantidad", num: true, f: (f) => fmt.num(f.cantidad) },
            { t: "Costo unit.", num: true, f: (f) => fmt.dinero(f.costo_unitario) }, { t: "Saldo", num: true, f: (f) => fmt.num(f.saldo) }, { t: "Detalle", f: (f) => f.proveedor || f.observacion }], r.filas),
            h("div", { class: "paginacion" }, pagina > 1 ? boton("← Más recientes", () => { pagina--; pintar(); }) : null,
              h("span", { texto: "Página " + pagina }), r.hay_mas ? boton("Más antiguos →", () => { pagina++; pintar(); }) : null));
        } else if (pestana === "lotes") {
          const r = await GET(`materias/${m.id_materia_prima}/lotes`);
          nodo = tabla([{ t: "Lote", k: "codigo_lote" }, { t: "Ingreso", f: (f) => fmt.fecha(f.fecha_ingreso) }, { t: "Proveedor", k: "proveedor" }, { t: "Vence", f: (f) => fmt.fecha(f.fecha_vencimiento) },
            { t: "Inicial", num: true, f: (f) => fmt.num(f.cantidad_inicial) }, { t: "Disponible", num: true, f: (f) => fmt.num(f.cantidad_disponible) },
            { t: "", acc: true, f: (f) => boton("¿Dónde se usó?", () => trazabilidad(f)) }], r.filas, { vacio: "Sin lotes." });
        } else if (pestana === "bodegas") {
          const r = await GET(`materias/${m.id_materia_prima}/bodegas`);
          nodo = tabla([{ t: "Bodega", f: (f) => `${f.bodega_codigo} · ${f.bodega}` }, { t: "Cantidad", num: true, f: (f) => `${fmt.num(f.cantidad)} ${m.unidad_medida}` }], r.filas, { vacio: "No hay existencias en bodegas." });
        } else {
          const r = await GET(`materias/${m.id_materia_prima}/proveedores`);
          nodo = tabla([{ t: "Proveedor", k: "proveedor" }, { t: "País", k: "pais_origen" }, { t: "Precio", num: true, f: (f) => fmt.dinero(f.precio_unitario) }, { t: "Entrega", num: true, f: (f) => f.tiempo_entrega_dias + " d" }], r.filas, { vacio: "Ningún proveedor la ofrece." });
        }
        cuerpo.replaceChildren(nodo);
      } catch (e) { cuerpo.replaceChildren(h("div", { class: "aviso rojo", texto: e.message })); }
    };
    const trazabilidad = async (lote) => {
      try {
        const r = await GET(`lotes/${lote.id_lote}/trazabilidad`);
        traza.replaceChildren(h("div", { class: "panel", style: "margin-top:14px" }, h("h3", { texto: "Trazabilidad del lote " + lote.codigo_lote }),
          tabla([{ t: "Fecha", f: (f) => fmt.fecha(f.fecha_consumo) }, { t: "Orden", f: (f) => "OP-" + f.id_orden }, { t: "Producto fabricado", k: "producto_fabricado" }, { t: "Consumido", num: true, f: (f) => fmt.num(f.cantidad_consumida) }], r.filas, { vacio: "Este lote aún no se ha usado." })));
      } catch (e) { aviso(e.message, true); }
    };
    const marco = h("div"), repintarPestanas = () => { marco.replaceChildren(pestanas([{ id: "kardex", t: "Kardex" }, { id: "lotes", t: "Lotes" }, { id: "bodegas", t: "Por bodega" }, { id: "proveedores", t: "Proveedores" }], pestana, (id) => { pestana = id; pagina = 1; repintarPestanas(); pintar(); }), cuerpo, traza); };
    repintarPestanas();
    modal({ titulo: `${m.codigo} · ${m.nombre} — existencia ${fmt.num(m.stock_actual)} ${m.unidad_medida}`, cuerpo: marco, ancho: true, botones: [{ t: "Cerrar", onclick: cerrarModal }] });
    pintar();
  }

  /* ================= PRODUCTOS ================= */
  let verInactivosProd = false;
  async function productos(cont) {
    cargando(cont);
    let filas;
    try { filas = (await GET("productos" + (verInactivosProd ? "?inactivos=1" : ""))).filas; } catch (e) { return falla(cont, e); }
    const refrescar = () => productos(cont);
    cont.replaceChildren(
      cabecera("Productos y recetas", "Qué fabrica la empresa y con cuánta materia prima.", puede("ADMIN") ? h("button", { class: "btn primario", type: "button", onclick: () => formProducto(refrescar) }, "+ Nuevo producto") : null),
      h("div", { class: "panel" }, h("div", { class: "filtros" }, puede("ADMIN") ? toggleInactivos(verInactivosProd, (v) => { verInactivosProd = v; refrescar(); }) : null),
        tabla([{ t: "Código", k: "codigo" }, { t: "Producto", k: "nombre" }, { t: "Precio de venta", num: true, f: (f) => fmt.dinero(f.precio_venta) },
          { t: "En bodega (terminados)", num: true, f: (f) => fmt.num(f.stock_actual) }, { t: "Se pueden fabricar", num: true, f: (f) => fmt.num(f.max_producible) },
          { t: "Estado", f: (f) => insignia(f.activo ? "Activo" : "Inactivo", f.activo ? "verde" : "gris") },
          { t: "", acc: true, f: (f) => [boton("Receta", () => receta(f, refrescar)), puede("ADMIN") ? boton("Editar", () => formProducto(refrescar, f)) : null,
            puede("ADMIN") ? boton(f.activo ? "Desactivar" : "Activar", () => estadoProducto(f, refrescar), f.activo ? "peligro" : "") : null] }],
          filas, { claseFila: (f) => (f.activo ? "" : "inactivo") })));
  }
  function formProducto(refrescar, p) {
    formulario({
      titulo: p ? "Editar " + p.codigo : "Nuevo producto", valores: p ? { ...p } : {},
      campos: [{ n: "codigo", et: "Código", req: true, maxlen: 20, deshab: !!p, mitad: true }, { n: "precio_venta", et: "Precio de venta (COP)", tipo: "number", req: true, min: 1, mitad: true },
        { n: "nombre", et: "Nombre", req: true, maxlen: 100 }],
      nota: p ? null : "Después de crearlo, usa «Receta» para indicar qué materias primas lleva.",
      enviar: async (d) => { if (p) await PUT("productos/" + p.id_producto, d); else await POST("productos", d); aviso(p ? "Producto actualizado" : "Producto creado"); refrescar(); },
    });
  }
  async function estadoProducto(p, refrescar) {
    const nuevo = !p.activo;
    if (!(await confirmar((nuevo ? "Activar " : "Desactivar ") + p.nombre, nuevo ? "Volverá a estar disponible para órdenes y pedidos." : "No se podrán crear órdenes ni pedidos nuevos con él. Se conserva su historial.", nuevo ? "Activar" : "Desactivar", !nuevo))) return;
    if (await hacer(() => POST("productos/" + p.id_producto + "/estado", { activo: nuevo }), nuevo ? "Producto activado" : "Producto desactivado")) refrescar();
  }
  async function receta(p, refrescarLista) {
    const caja = h("div");
    const pintar = async () => {
      try {
        const [rec, mats] = await Promise.all([GET(`productos/${p.id_producto}/receta`), puede("ADMIN") ? GET("materias") : { filas: [] }]);
        caja.replaceChildren(
          tabla([{ t: "Código", k: "codigo" }, { t: "Materia prima", k: "materia_prima" }, { t: "Por unidad", num: true, f: (f) => `${fmt.num(f.cantidad_por_unidad)} ${f.unidad_medida}` }, { t: "Existencia", num: true, f: (f) => fmt.num(f.stock_actual) },
            { t: "", acc: true, f: (f) => (puede("ADMIN") ? [boton("Cambiar", () => formLinea(f)), boton("Quitar", () => quitar(f), "peligro")] : null) }], rec.filas, { vacio: "Este producto todavía no tiene receta." }),
          puede("ADMIN") ? h("div", { class: "panel", style: "margin-top:14px" }, h("h3", { texto: "Agregar materia prima a la receta" }), h("div", { class: "filtros", style: "margin-top:10px" },
            h("div", { class: "campo" }, h("label", { for: "r-mp" }, "Materia prima"), h("select", { id: "r-mp" }, opc(mats.filas, "id_materia_prima", (m) => `${m.codigo} · ${m.nombre} (${m.unidad_medida})`).map((o) => h("option", { value: o.v }, o.t)))),
            h("div", { class: "campo" }, h("label", { for: "r-cant" }, "Cantidad por unidad"), h("input", { id: "r-cant", type: "number", step: "any", min: "0.0001" })),
            h("button", { class: "btn primario", type: "button", onclick: async () => { const c = Number(N.$("#r-cant").value); if (!(c > 0)) return aviso("Escribe una cantidad mayor que cero", true); if (await hacer(() => PUT(`productos/${p.id_producto}/receta/${N.$("#r-mp").value}`, { cantidad_por_unidad: c }), "Receta actualizada")) { pintar(); refrescarLista(); } } }, "Agregar"))) : null);
      } catch (e) { caja.replaceChildren(h("div", { class: "aviso rojo", texto: e.message })); }
    };
    const formLinea = (f) => formulario({ titulo: "Cantidad de " + f.materia_prima, campos: [{ n: "cantidad_por_unidad", et: `Cantidad por unidad (${f.unidad_medida})`, tipo: "number", req: true, min: 0.0001 }], valores: { cantidad_por_unidad: f.cantidad_por_unidad },
      enviar: async (d) => { await PUT(`productos/${p.id_producto}/receta/${f.id_materia_prima}`, d); aviso("Receta actualizada"); receta(p, refrescarLista); refrescarLista(); } });
    const quitar = async (f) => { if (await hacer(() => DEL(`productos/${p.id_producto}/receta/${f.id_materia_prima}`), "Quitada de la receta")) { pintar(); refrescarLista(); } };
    modal({ titulo: `Receta de ${p.nombre}`, cuerpo: caja, ancho: true, botones: [{ t: "Cerrar", onclick: cerrarModal }] });
    pintar();
  }

  /* ================= CLIENTES ================= */
  let verInactivosCli = false;
  async function clientes(cont) {
    cargando(cont);
    let filas;
    try { filas = (await GET("clientes" + (verInactivosCli ? "?inactivos=1" : ""))).filas; } catch (e) { return falla(cont, e); }
    const refrescar = () => clientes(cont);
    cont.replaceChildren(
      cabecera("Clientes", "Quién compra, cuánto y desde cuándo. Los pedidos se arman en el módulo Ventas.", puede("OPERARIO") ? h("button", { class: "btn primario", type: "button", onclick: () => formCliente(refrescar) }, "+ Nuevo cliente") : null),
      h("div", { class: "panel" }, h("div", { class: "filtros" }, puede("ADMIN") ? toggleInactivos(verInactivosCli, (v) => { verInactivosCli = v; refrescar(); }) : null),
        tabla([{ t: "NIT", k: "nit" }, { t: "Cliente", k: "nombre" }, { t: "Ciudad", k: "ciudad" }, { t: "Teléfono", k: "telefono" }, { t: "Correo", k: "email" },
          { t: "Pedidos", num: true, f: (f) => fmt.num(f.pedidos) }, { t: "Total comprado", num: true, f: (f) => fmt.dinero(f.total_comprado) }, { t: "Estado", f: (f) => insignia(f.activo ? "Activo" : "Inactivo", f.activo ? "verde" : "gris") },
          { t: "", acc: true, f: (f) => [boton("Pedidos", () => pedidosDeCliente(f)), puede("OPERARIO") ? boton("Editar", () => formCliente(refrescar, f)) : null,
            puede("ADMIN") ? boton(f.activo ? "Desactivar" : "Activar", () => estadoCliente(f, refrescar), f.activo ? "peligro" : "") : null] }],
          filas, { claseFila: (f) => (f.activo ? "" : "inactivo") })));
  }
  function formCliente(refrescar, c) {
    formulario({
      titulo: c ? "Editar cliente" : "Nuevo cliente", valores: c ? { ...c } : {},
      campos: [{ n: "nit", et: "NIT", req: true, maxlen: 20, deshab: !!c, mitad: true }, { n: "ciudad", et: "Ciudad", maxlen: 60, mitad: true }, { n: "nombre", et: "Nombre o razón social", req: true, maxlen: 100 },
        { n: "telefono", et: "Teléfono", maxlen: 20, mitad: true }, { n: "email", et: "Correo", tipo: "email", maxlen: 100, mitad: true }],
      enviar: async (d) => { if (c) await PUT("clientes/" + c.id_cliente, d); else await POST("clientes", d); aviso(c ? "Cliente actualizado" : "Cliente creado"); refrescar(); },
    });
  }
  async function estadoCliente(c, refrescar) {
    const nuevo = !c.activo;
    if (!(await confirmar((nuevo ? "Activar " : "Desactivar ") + c.nombre, nuevo ? "Podrá recibir pedidos nuevos." : "No se le podrán crear pedidos nuevos. Su historial se conserva.", nuevo ? "Activar" : "Desactivar", !nuevo))) return;
    if (await hacer(() => POST("clientes/" + c.id_cliente + "/estado", { activo: nuevo }), nuevo ? "Cliente activado" : "Cliente desactivado")) refrescar();
  }
  async function pedidosDeCliente(c) {
    try {
      const r = await GET(`clientes/${c.id_cliente}/pedidos`);
      modal({ titulo: "Pedidos de " + c.nombre, ancho: true, botones: [{ t: "Cerrar", onclick: cerrarModal }], cuerpo: tabla([
        { t: "Pedido", f: (f) => "PED-" + f.id_pedido }, { t: "Fecha", f: (f) => fmt.fecha(f.fecha) }, { t: "Estado", f: (f) => insignia(f.estado) }, { t: "Líneas", num: true, k: "lineas" }, { t: "Total", num: true, f: (f) => fmt.dinero(f.total) },
        { t: "", acc: true, f: (f) => boton("Ver", () => detallePedido(f.id_pedido, () => pedidosDeCliente(c))) }], r.filas, { vacio: "Este cliente aún no tiene pedidos." }) });
    } catch (e) { aviso(e.message, true); }
  }

  /* ================= VENTAS ================= */
  let filtroPedido = "";
  async function ventas(cont) {
    cargando(cont);
    let filas;
    try { filas = (await GET("pedidos" + (filtroPedido ? "?estado=" + filtroPedido : ""))).filas; } catch (e) { return falla(cont, e); }
    const refrescar = () => ventas(cont);
    const chips = h("div", { class: "chips" }, [["", "Todos"], ["ABIERTO", "Abiertos"], ["DESPACHADO", "Despachados"], ["CANCELADO", "Cancelados"]].map(([v, t]) =>
      h("button", { type: "button", "aria-pressed": String(filtroPedido === v), onclick: () => { filtroPedido = v; refrescar(); } }, t)));
    cont.replaceChildren(
      cabecera("Ventas y despachos", "Un pedido se arma con productos terminados y, al despacharlo, descuenta el stock de producto.", puede("OPERARIO") ? h("button", { class: "btn primario", type: "button", onclick: () => formPedido(refrescar) }, "+ Nuevo pedido") : null),
      h("div", { class: "panel" }, h("div", { class: "filtros" }, chips),
        tabla([{ t: "Pedido", f: (f) => "PED-" + f.id_pedido }, { t: "Cliente", k: "cliente" }, { t: "Fecha", f: (f) => fmt.fecha(f.fecha) }, { t: "Estado", f: (f) => insignia(f.estado) },
          { t: "Líneas", num: true, k: "lineas" }, { t: "Total", num: true, f: (f) => fmt.dinero(f.total) }, { t: "", acc: true, f: (f) => boton("Abrir", () => detallePedido(f.id_pedido, refrescar)) }], filas, { vacio: "No hay pedidos con ese filtro." })));
  }
  async function formPedido(refrescar) {
    let cl;
    try { cl = (await GET("clientes")).filas; } catch (e) { return aviso(e.message, true); }
    formulario({ titulo: "Nuevo pedido de venta", boton: "Crear y agregar productos",
      campos: [{ n: "id_cliente", et: "Cliente", tipo: "select", req: true, num: true, opciones: opc(cl, "id_cliente", (c) => `${c.nombre} (${c.ciudad || "—"})`) }, { n: "observacion", et: "Observación (opcional)", maxlen: 200 }],
      enviar: async (d) => { const r = await POST("pedidos", d); aviso("Pedido PED-" + r.id_pedido + " creado"); refrescar(); setTimeout(() => detallePedido(r.id_pedido, refrescar), 50); } });
  }
  async function detallePedido(id, refrescar) {
    const caja = h("div"); let abierto = false;
    const pintar = async () => {
      try {
        const [r, prods] = await Promise.all([GET("pedidos/" + id), GET("productos")]);
        const fs = r.filas, cab = fs[0], lineas = fs.filter((f) => f.codigo), total = lineas.reduce((a, f) => a + f.subtotal, 0);
        abierto = cab.estado === "ABIERTO";
        const editable = abierto && puede("OPERARIO");
        caja.replaceChildren(
          h("p", null, h("b", { texto: cab.cliente }), "  ", insignia(cab.estado)),
          tabla([{ t: "Código", k: "codigo" }, { t: "Producto", k: "producto" }, { t: "Cantidad", num: true, f: (f) => fmt.num(f.cantidad) }, { t: "Precio", num: true, f: (f) => fmt.dinero(f.precio_unitario) },
            { t: "Subtotal", num: true, f: (f) => fmt.dinero(f.subtotal) }, { t: "Disponible", num: true, f: (f) => (abierto ? insignia(fmt.num(f.disponible), f.disponible >= f.cantidad ? "verde" : "rojo") : null) },
            { t: "", acc: true, f: (f) => (editable ? boton("Quitar", async () => { if (await hacer(() => DEL(`pedidos/${id}/lineas/${f.id_producto}`), "Línea quitada")) { pintar(); refrescar(); } }, "peligro") : null) }], lineas, { vacio: "El pedido no tiene productos todavía." }),
          h("p", { style: "text-align:right;font-size:1.15rem;margin:10px 0", }, "Total: ", h("b", { texto: fmt.dinero(total) })),
          editable ? h("div", { class: "panel" }, h("h3", { texto: "Agregar producto" }), h("div", { class: "filtros", style: "margin-top:10px" },
            h("div", { class: "campo" }, h("label", { for: "p-prod" }, "Producto"), h("select", { id: "p-prod" }, prods.filas.filter((p) => p.activo).map((p) => h("option", { value: p.id_producto }, `${p.codigo} · ${p.nombre} (hay ${fmt.num(p.stock_actual)})`)))),
            h("div", { class: "campo" }, h("label", { for: "p-cant" }, "Cantidad"), h("input", { id: "p-cant", type: "number", min: "1", step: "1" })),
            h("button", { class: "btn primario", type: "button", onclick: async () => { const c = Number(N.$("#p-cant").value); if (!(c >= 1)) return aviso("Escribe una cantidad válida", true); if (await hacer(() => POST(`pedidos/${id}/lineas`, { id_producto: Number(N.$("#p-prod").value), cantidad: c }), "Producto agregado")) { pintar(); refrescar(); } } }, "Agregar"))) : null);
        const pie = N.$("#modal .d-pie");
        if (pie) pie.replaceChildren(h("button", { class: "btn", type: "button", onclick: cerrarModal }, "Cerrar"),
          editable ? h("button", { class: "btn peligro", type: "button", onclick: async () => { if (await confirmar("Cancelar PED-" + id, "El pedido pasará a CANCELADO.", "Cancelar pedido", true)) { if (await hacer(() => POST(`pedidos/${id}/cancelar`), "Pedido cancelado")) { cerrarModal(); refrescar(); } } } }, "Cancelar pedido") : null,
          editable ? h("button", { class: "btn primario", type: "button", onclick: async () => { if (!lineas.length) return aviso("Agrega al menos un producto", true); if (await confirmar("Despachar PED-" + id, `Se descontarán del stock los productos del pedido (${fmt.dinero(total)}).`, "Despachar")) { if (await hacer(() => POST(`pedidos/${id}/despachar`), "Pedido despachado")) { cerrarModal(); refrescar(); } } } }, "Despachar") : null);
      } catch (e) { caja.replaceChildren(h("div", { class: "aviso rojo", texto: e.message })); }
    };
    modal({ titulo: "Pedido PED-" + id, cuerpo: caja, ancho: true, botones: [{ t: "Cerrar", onclick: cerrarModal }] });
    pintar();
  }

  /* ================= PROVEEDORES ================= */
  let verInactivosProv = false;
  async function proveedores(cont) {
    cargando(cont);
    let filas;
    try { filas = (await GET("proveedores" + (verInactivosProv ? "?inactivos=1" : ""))).filas; } catch (e) { return falla(cont, e); }
    const refrescar = () => proveedores(cont);
    cont.replaceChildren(
      cabecera("Proveedores", "Quién vende qué, a qué precio y con qué tiempo de entrega.", puede("ADMIN") ? h("button", { class: "btn primario", type: "button", onclick: () => formProveedor(refrescar) }, "+ Nuevo proveedor") : null),
      h("div", { class: "panel" }, h("div", { class: "filtros" }, puede("ADMIN") ? toggleInactivos(verInactivosProv, (v) => { verInactivosProv = v; refrescar(); }) : null),
        tabla([{ t: "NIT", k: "nit" }, { t: "Proveedor", k: "nombre" }, { t: "Teléfono", k: "telefono" }, { t: "Correo", k: "email" }, { t: "Materias que vende", num: true, k: "materias" }, { t: "Estado", f: (f) => insignia(f.activo ? "Activo" : "Inactivo", f.activo ? "verde" : "gris") },
          { t: "", acc: true, f: (f) => [boton("Precios", () => ofertas(f, refrescar)), puede("ADMIN") ? boton("Editar", () => formProveedor(refrescar, f)) : null,
            puede("ADMIN") ? boton(f.activo ? "Desactivar" : "Activar", () => estadoProveedor(f, refrescar), f.activo ? "peligro" : "") : null] }],
          filas, { claseFila: (f) => (f.activo ? "" : "inactivo") })));
  }
  function formProveedor(refrescar, p) {
    formulario({ titulo: p ? "Editar proveedor" : "Nuevo proveedor", valores: p ? { ...p } : {},
      campos: [{ n: "nit", et: "NIT", req: true, maxlen: 20, deshab: !!p, mitad: true }, { n: "telefono", et: "Teléfono", maxlen: 20, mitad: true }, { n: "nombre", et: "Nombre o razón social", req: true, maxlen: 100 }, { n: "email", et: "Correo", tipo: "email", maxlen: 100 }],
      enviar: async (d) => { if (p) await PUT("proveedores/" + p.id_proveedor, d); else await POST("proveedores", d); aviso(p ? "Proveedor actualizado" : "Proveedor creado"); refrescar(); } });
  }
  async function estadoProveedor(p, refrescar) {
    const nuevo = !p.activo;
    if (!(await confirmar((nuevo ? "Activar " : "Desactivar ") + p.nombre, nuevo ? "Volverá a poder usarse en compras." : "No se podrán registrar compras con él. Su historial se conserva.", nuevo ? "Activar" : "Desactivar", !nuevo))) return;
    if (await hacer(() => POST("proveedores/" + p.id_proveedor + "/estado", { activo: nuevo }), nuevo ? "Proveedor activado" : "Proveedor desactivado")) refrescar();
  }
  async function ofertas(p, refrescarLista) {
    const caja = h("div"), hist = h("div");
    const pintar = async () => {
      try {
        const [of, mats] = await Promise.all([GET(`proveedores/${p.id_proveedor}/ofertas`), puede("ADMIN") ? GET("materias") : { filas: [] }]);
        caja.replaceChildren(tabla([{ t: "Código", k: "codigo" }, { t: "Materia prima", k: "materia_prima" }, { t: "País", k: "pais_origen" }, { t: "Precio", num: true, f: (f) => fmt.dinero(f.precio_unitario) + " / " + f.unidad_medida },
          { t: "Entrega", num: true, f: (f) => f.tiempo_entrega_dias + " d" }, { t: "", acc: true, f: (f) => [boton("Historial", () => historial(f)), puede("ADMIN") ? boton("Cambiar", () => formOferta(f, mats.filas)) : null] }], of.filas, { vacio: "Este proveedor aún no tiene materias asignadas." }),
          puede("ADMIN") ? h("div", { style: "margin-top:12px" }, h("button", { class: "btn", type: "button", onclick: () => formOferta(null, mats.filas) }, "+ Agregar materia a este proveedor")) : null);
      } catch (e) { caja.replaceChildren(h("div", { class: "aviso rojo", texto: e.message })); }
    };
    const historial = async (f) => {
      try {
        const r = await GET(`proveedores/${p.id_proveedor}/historial/${f.id_materia_prima}`);
        hist.replaceChildren(h("div", { class: "panel", style: "margin-top:14px" }, h("h3", { texto: "Historial de precios · " + f.materia_prima }),
          tabla([{ t: "Desde", f: (x) => fmt.fecha(x.vigente_desde) }, { t: "Hasta", f: (x) => (x.vigente_hasta ? fmt.fecha(x.vigente_hasta) : insignia("Vigente", "verde")) }, { t: "Precio", num: true, f: (x) => fmt.dinero(x.precio_unitario) },
            { t: "Variación", num: true, f: (x) => (x.variacion_pct == null ? null : (x.variacion_pct > 0 ? "+" : "") + fmt.num(x.variacion_pct) + " %") }], r.filas)));
      } catch (e) { aviso(e.message, true); }
    };
    const formOferta = (f, mats) => formulario({
      titulo: f ? "Cambiar oferta · " + f.materia_prima : "Agregar materia a " + p.nombre, valores: f ? { ...f, id_materia_prima: f.id_materia_prima } : {},
      nota: "Si cambias el precio, el anterior queda guardado en el historial de precios.",
      campos: [{ n: "id_materia_prima", et: "Materia prima", tipo: "select", req: true, num: true, deshab: !!f, enviarDeshab: true, opciones: opc(mats, "id_materia_prima", (m) => `${m.codigo} · ${m.nombre}`) },
        { n: "pais_origen", et: "País de origen", req: true, maxlen: 60, mitad: true }, { n: "precio_unitario", et: "Precio unitario (COP)", tipo: "number", req: true, min: 1, mitad: true }, { n: "tiempo_entrega_dias", et: "Días de entrega", tipo: "number", req: true, min: 0, paso: 1 }],
      enviar: async (d) => { const id = d.id_materia_prima; delete d.id_materia_prima; await PUT(`proveedores/${p.id_proveedor}/ofertas/${id}`, d); aviso("Oferta guardada"); pintar(); refrescarLista(); setTimeout(() => ofertas(p, refrescarLista), 60); } });
    modal({ titulo: "Precios de " + p.nombre, cuerpo: h("div", null, caja, hist), ancho: true, botones: [{ t: "Cerrar", onclick: cerrarModal }] });
    pintar();
  }

  /* ================= REPORTES ================= */
  const REPS = [["ventas", "Ventas por mes"], ["clientes", "Ventas por cliente"], ["produccion", "Producción por mes"], ["compras", "Compras por proveedor"], ["inventario", "Valor del inventario"], ["reponer", "Qué reponer"]];
  let repActual = "ventas";
  const esDinero = (k) => /(total|gasto|precio|costo|valor|vendido|comprado)/.test(k);
  const etiqueta = (k) => k.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
  async function reportes(cont) {
    cargando(cont);
    let filas;
    try { filas = (await GET("reportes/" + repActual)).filas; } catch (e) { return falla(cont, e); }
    const cols = filas.length ? Object.keys(filas[0]).filter((k) => !k.startsWith("id_")).map((k) => ({
      t: etiqueta(k), num: typeof filas[0][k] === "number", f: (f) => (typeof f[k] === "number" ? (esDinero(k) ? fmt.dinero(f[k]) : fmt.num(f[k])) : f[k]) })) : [];
    cont.replaceChildren(
      cabecera("Reportes", "Consultas de la base (JOIN, SUM, COUNT, GROUP BY) listas para leer o llevar a Excel.", h("a", { class: "btn", href: `/api/reportes/${repActual}/descargar`, download: "" }, "Descargar CSV")),
      h("div", { class: "panel" }, h("div", { class: "filtros" }, h("div", { class: "chips" }, REPS.map(([id, t]) => h("button", { type: "button", "aria-pressed": String(id === repActual), onclick: () => { repActual = id; reportes(cont); } }, t)))),
        tabla(cols, filas, { vacio: "Este reporte no tiene datos." })));
  }

  /* ================= USUARIOS ================= */
  async function usuarios(cont) {
    cargando(cont);
    let filas;
    try { filas = (await GET("usuarios")).filas; } catch (e) { return falla(cont, e); }
    const refrescar = () => usuarios(cont);
    cont.replaceChildren(
      cabecera("Usuarios y permisos", "ADMIN: todo · OPERARIO: opera el día a día (órdenes, compras, ventas, clientes) · CONSULTA: solo mira.", h("button", { class: "btn primario", type: "button", onclick: () => formUsuario(refrescar) }, "+ Nuevo usuario")),
      h("div", { class: "panel" }, tabla([{ t: "Usuario", k: "usuario" }, { t: "Nombre", k: "nombre" }, { t: "Rol", f: (f) => insignia(f.rol) }, { t: "Estado", f: (f) => insignia(f.activo ? "Activo" : "Inactivo", f.activo ? "verde" : "gris") },
        { t: "Último acceso", f: (f) => fmt.fecha(f.ultimo_acceso) }, { t: "Clave", f: (f) => (f.debe_cambiar_clave ? insignia("Pendiente de cambio", "ambar") : insignia("Propia", "verde")) },
        { t: "", acc: true, f: (f) => [boton("Editar", () => formUsuario(refrescar, f)), boton("Restablecer clave", () => formClave(refrescar, f))] }], filas, { claseFila: (f) => (f.activo ? "" : "inactivo") })));
  }
  function formUsuario(refrescar, u) {
    const roles = [{ v: "CONSULTA", t: "CONSULTA — solo consulta" }, { v: "OPERARIO", t: "OPERARIO — opera el día a día" }, { v: "ADMIN", t: "ADMIN — todo" }];
    formulario({ titulo: u ? "Editar " + u.usuario : "Nuevo usuario", valores: u ? { ...u } : { rol: "CONSULTA", activo: true },
      nota: u ? null : "La clave temporal solo la conoce quien la crea: el usuario deberá cambiarla en su primer ingreso.",
      campos: [{ n: "usuario", et: "Usuario", req: true, maxlen: 30, deshab: !!u, mitad: true, ayuda: "Minúsculas, números, punto o guion." }, { n: "rol", et: "Rol", tipo: "select", req: true, opciones: roles, mitad: true },
        { n: "nombre", et: "Nombre completo", req: true, maxlen: 100 },
        u ? { n: "activo", et: "Usuario activo", tipo: "check", ayuda: "Si lo desactivas, su sesión se cierra al instante." } : { n: "clave_temporal", et: "Clave temporal", tipo: "password", req: true, ayuda: "Mínimo 8 caracteres, con letras y números." }].filter(Boolean),
      enviar: async (d) => { if (u) await PUT("usuarios/" + u.id_usuario, d); else await POST("usuarios", d); aviso(u ? "Usuario actualizado" : "Usuario creado"); refrescar(); } });
  }
  function formClave(refrescar, u) {
    formulario({ titulo: "Restablecer clave de " + u.usuario, boton: "Asignar clave temporal", nota: "El usuario deberá cambiarla al entrar.",
      campos: [{ n: "clave_temporal", et: "Clave temporal", tipo: "password", req: true, ayuda: "Mínimo 8 caracteres, con letras y números." }],
      enviar: async (d) => { await POST(`usuarios/${u.id_usuario}/clave`, d); aviso("Clave temporal asignada"); refrescar(); } });
  }

  /* ================= HISTORIAL (BITÁCORA) ================= */
  const filtrosH = { usuario: "", modulo: "", resultado: "", desde: "", hasta: "", pagina: 1 };
  async function historial(cont) {
    const admin = puede("ADMIN");
    cargando(cont);
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(filtrosH)) if (v && (admin || k !== "usuario")) q.set(k, v);
    let r;
    try { r = await GET((admin ? "bitacora?" : "bitacora/mia?") + q); } catch (e) { return falla(cont, e); }
    const campo = (id, et, ctrl) => h("div", { class: "campo" }, h("label", { for: id }, et), ctrl);
    const entrada = (k, tipo) => h("input", { id: "h-" + k, type: tipo, value: filtrosH[k] });
    const sel = h("select", { id: "h-resultado" }, [["", "Todos"], ["OK", "Correctos"], ["ERROR", "Con error"]].map(([v, t]) => h("option", { value: v }, t)));
    sel.value = filtrosH.resultado;
    const mods = h("select", { id: "h-modulo" }, ["", "Acceso", "Órdenes", "Inventario", "Productos", "Recetas", "Materias primas", "Bodegas", "Proveedores", "Clientes", "Ventas", "Usuarios", "Reportes"].map((m) => h("option", { value: m }, m || "Todos")));
    mods.value = filtrosH.modulo;
    const aplicar = () => { filtrosH.usuario = admin ? N.$("#h-usuario").value.trim() : ""; filtrosH.modulo = mods.value; filtrosH.resultado = sel.value; filtrosH.desde = N.$("#h-desde").value; filtrosH.hasta = N.$("#h-hasta").value; filtrosH.pagina = 1; historial(cont); };
    const paginas = Math.max(1, Math.ceil(r.total / r.tam));
    cont.replaceChildren(
      cabecera(admin ? "Historial de solicitudes" : "Mi actividad", admin ? "Cada acción hecha en la página: quién, cuándo, qué pidió y si salió bien o falló. No se puede editar desde la aplicación." : "Lo que has hecho en la página."),
      h("div", { class: "panel" }, h("div", { class: "filtros" }, admin ? campo("h-usuario", "Usuario", entrada("usuario", "text")) : null, campo("h-modulo", "Módulo", mods), campo("h-resultado", "Resultado", sel),
        campo("h-desde", "Desde", entrada("desde", "date")), campo("h-hasta", "Hasta", entrada("hasta", "date")), h("button", { class: "btn oscuro", type: "button", onclick: aplicar }, "Filtrar"),
        h("button", { class: "btn", type: "button", onclick: () => { Object.assign(filtrosH, { usuario: "", modulo: "", resultado: "", desde: "", hasta: "", pagina: 1 }); historial(cont); } }, "Limpiar")),
        tabla([{ t: "Fecha", f: (f) => fmt.fecha(f.fecha) }, admin ? { t: "Usuario", f: (f) => (f.rol ? `${f.usuario} (${f.rol})` : f.usuario) } : null, { t: "Acción", k: "accion" }, { t: "Módulo", k: "modulo" }, { t: "Ref.", k: "referencia" },
          { t: "Resultado", f: (f) => insignia(f.resultado) }, { t: "Detalle", f: (f) => h("span", null, f.detalle || "", f.parametros ? h("details", null, h("summary", { texto: "datos enviados" }), h("pre", { class: "json", texto: JSON.stringify(f.parametros, null, 2) })) : null) },
          admin ? { t: "IP", k: "ip" } : null].filter(Boolean), r.filas, { vacio: "No hay registros con esos filtros." }),
        h("div", { class: "paginacion" }, h("span", { texto: `${fmt.num(r.total)} registros · página ${r.pagina} de ${paginas}` }),
          boton("← Anterior", () => { filtrosH.pagina = Math.max(1, r.pagina - 1); historial(cont); }, r.pagina <= 1 ? "oculto" : ""), boton("Siguiente →", () => { filtrosH.pagina = r.pagina + 1; historial(cont); }, r.pagina >= paginas ? "oculto" : ""))));
  }

  return {
    inicio, ordenes, inventario, productos, clientes, ventas, proveedores, reportes, usuarios, historial,
    MENU: [
      { id: "inicio", t: "Inicio", rol: "CONSULTA" },
      { sep: "Operación" },
      { id: "ordenes", t: "Órdenes de producción", rol: "CONSULTA" }, { id: "inventario", t: "Inventario", rol: "CONSULTA" }, { id: "ventas", t: "Ventas y despachos", rol: "CONSULTA" },
      { sep: "Catálogos" },
      { id: "productos", t: "Productos y recetas", rol: "CONSULTA" }, { id: "clientes", t: "Clientes", rol: "CONSULTA" }, { id: "proveedores", t: "Proveedores", rol: "CONSULTA" },
      { sep: "Control" },
      { id: "reportes", t: "Reportes", rol: "CONSULTA" }, { id: "historial", t: "Historial", rol: "CONSULTA" }, { id: "usuarios", t: "Usuarios", rol: "ADMIN" },
    ],
  };
})();
