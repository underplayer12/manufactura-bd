/* nucleo.js - piezas reutilizables de la pagina: DOM, llamadas a la API, ventanas, formularios y tablas.
   IMPORTANTE (seguridad): todo texto que viene de la base se inserta con textContent (nunca innerHTML),
   asi un nombre como "<script>..." se muestra como texto y no se ejecuta. */
"use strict";

const N = (() => {
  const estado = { yo: null };

  /* ---------- DOM ---------- */
  function h(etiqueta, props, ...hijos) {
    const el = document.createElement(etiqueta);
    for (const [k, v] of Object.entries(props || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") el.className = v;
      else if (k === "texto") el.textContent = v;
      else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
      else if (k === "value") el.value = v;
      else if (v === true) el.setAttribute(k, "");
      else el.setAttribute(k, v);
    }
    const poner = (x) => {
      if (x === null || x === undefined || x === false) return;
      if (Array.isArray(x)) x.forEach(poner);
      else el.append(x instanceof Node ? x : document.createTextNode(String(x)));
    };
    hijos.forEach(poner);
    return el;
  }
  const $ = (s, r = document) => r.querySelector(s);

  /* ---------- Formatos ---------- */
  const nf = new Intl.NumberFormat("es-CO", { maximumFractionDigits: 3 });
  const mf = new Intl.NumberFormat("es-CO", { style: "currency", currency: "COP", maximumFractionDigits: 0 });
  const fmt = {
    num: (v) => (v === null || v === undefined ? "—" : nf.format(v)),
    dinero: (v) => (v === null || v === undefined ? "—" : mf.format(v)),
    fecha: (v) => {
      if (!v) return "—";
      const m = /^(\d{4})-(\d{2})-(\d{2})(?: (\d{2}:\d{2}))?/.exec(v);
      return m ? `${m[3]}/${m[2]}/${m[1]}${m[4] ? " " + m[4] : ""}` : v;
    },
    si: (v) => (v ? "Sí" : "No"),
  };
  const COLORES = {
    PENDIENTE: "ambar", COMPLETADA: "verde", CANCELADA: "gris", ABIERTO: "ambar", DESPACHADO: "verde", CANCELADO: "gris",
    OK: "verde", ERROR: "rojo", REABASTECER: "rojo", ADMIN: "azul", OPERARIO: "ambar", CONSULTA: "gris",
    ENTRADA: "verde", SALIDA: "rojo", AJUSTE: "azul", TRASLADO: "azul",
  };
  const insignia = (texto, color) => h("span", { class: "insignia i-" + (color || COLORES[texto] || "gris"), texto });

  const RANGO = { CONSULTA: 1, OPERARIO: 2, ADMIN: 3 };
  const puede = (rol) => !!estado.yo && RANGO[estado.yo.rol] >= RANGO[rol];

  /* ---------- Llamadas a la API ---------- */
  class ErrorApi extends Error {
    constructor(mensaje, estadoHttp, datos) { super(mensaje); this.estado = estadoHttp; this.datos = datos || {}; }
  }
  let alCaerSesion = () => {};
  const alPerderSesion = (f) => { alCaerSesion = f; };

  async function api(metodo, ruta, cuerpo) {
    let resp;
    try {
      resp = await fetch("/api/" + ruta, {
        method: metodo,
        headers: { "Content-Type": "application/json", "X-Requested-With": "fetch" },
        body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
        credentials: "same-origin",
      });
    } catch (e) {
      throw new ErrorApi("No hay conexión con el servidor. Revisa que la aplicación esté encendida.", 0);
    }
    let datos = {};
    try { datos = await resp.json(); } catch (e) { /* respuesta sin JSON */ }
    if (!resp.ok) {
      if (resp.status === 401 && datos.login && ruta !== "login") alCaerSesion();
      throw new ErrorApi(datos.error || "Error inesperado (" + resp.status + ")", resp.status, datos);
    }
    return datos;
  }
  const GET = (r) => api("GET", r);
  const POST = (r, c) => api("POST", r, c === undefined ? {} : c);
  const PUT = (r, c) => api("PUT", r, c);
  const DEL = (r) => api("DELETE", r);

  /* ---------- Avisos flotantes ---------- */
  function aviso(texto, mal) {
    const a = h("div", { class: "aviso-flotante" + (mal ? " mal" : ""), role: mal ? "alert" : "status", texto });
    $("#avisos").append(a);
    setTimeout(() => a.remove(), mal ? 7000 : 3800);
  }
  /* Ejecuta una accion y avisa el resultado. Devuelve true si salio bien. */
  async function hacer(accion, textoOk) {
    try {
      const r = await accion();
      if (textoOk) aviso(textoOk);
      return r === undefined ? true : r;
    } catch (e) {
      aviso(e.message, true);
      return false;
    }
  }

  /* ---------- Ventanas ---------- */
  const dlg = () => $("#modal");
  function cerrarModal() { const d = dlg(); if (d.open) d.close(); d.replaceChildren(); d.onclose = null; }
  function modal({ titulo, cuerpo, botones = [], ancho = false, alCerrar }) {
    const d = dlg();
    d.replaceChildren();
    d.className = ancho ? "ancho" : "";
    const pie = botones.length ? h("div", { class: "d-pie" }, botones.map((b) =>
      h("button", { class: "btn " + (b.cls || ""), type: "button", onclick: b.onclick, id: b.id }, b.t))) : null;
    d.append(
      h("div", { class: "d-cab" }, h("h2", { texto: titulo }),
        h("button", { class: "cerrar", type: "button", "aria-label": "Cerrar", onclick: cerrarModal }, "×")),
      h("div", { class: "d-cuerpo" }, cuerpo), pie);
    d.onclose = () => { d.replaceChildren(); if (alCerrar) alCerrar(); };
    if (!d.open) d.showModal();
    return d;
  }

  function confirmar(titulo, texto, botonTexto = "Confirmar", peligro = false) {
    return new Promise((resolver) => {
      let respondido = false;
      const fin = (v) => { respondido = true; cerrarModal(); resolver(v); };
      modal({
        titulo, cuerpo: h("p", { texto }),
        botones: [{ t: "Cancelar", onclick: () => fin(false) }, { t: botonTexto, cls: peligro ? "peligro" : "primario", onclick: () => fin(true) }],
        alCerrar: () => { if (!respondido) resolver(false); },
      });
    });
  }

  /* Formulario generico en ventana. campos: [{n, et, tipo, req, opciones, ayuda, paso, min, maxlen, deshab, mitad, num, valor}] */
  function formulario({ titulo, campos, valores = {}, enviar, boton = "Guardar", nota }) {
    const err = h("div", { class: "error-form oculto", role: "alert" });
    const entradas = {};
    const crear = (c) => {
      const id = "f-" + c.n;
      const v = c.n in valores ? valores[c.n] : c.valor;
      let el;
      if (c.tipo === "select") {
        el = h("select", { id, name: c.n, required: c.req, disabled: c.deshab },
          c.vacio !== undefined ? h("option", { value: "" }, c.vacio) : null,
          (c.opciones || []).map((o) => h("option", { value: String(o.v) }, o.t)));
        if (v !== undefined && v !== null) el.value = String(v);
      } else if (c.tipo === "check") {
        el = h("input", { id, name: c.n, type: "checkbox", disabled: c.deshab });
        el.checked = !!v;
        entradas[c.n] = { el, c };
        return h("div", { class: "campo" }, h("label", { class: "casilla", for: id }, el, c.et), c.ayuda ? h("div", { class: "ayuda", texto: c.ayuda }) : null);
      } else if (c.tipo === "textarea") {
        el = h("textarea", { id, name: c.n, rows: 3, maxlength: c.maxlen, required: c.req, disabled: c.deshab });
        el.value = v ?? "";
      } else {
        el = h("input", {
          id, name: c.n, type: c.tipo || "text", required: c.req, disabled: c.deshab, maxlength: c.maxlen,
          step: c.tipo === "number" ? c.paso || "any" : null, min: c.min, autocomplete: c.tipo === "password" ? "new-password" : "off",
        });
        el.value = v ?? "";
      }
      entradas[c.n] = { el, c };
      return h("div", { class: "campo" }, h("label", { for: id }, c.et, c.req ? " *" : ""), el, c.ayuda ? h("div", { class: "ayuda", texto: c.ayuda }) : null);
    };
    const filas = [];
    for (let i = 0; i < campos.length; i++) {
      if (campos[i].mitad && campos[i + 1] && campos[i + 1].mitad) { filas.push(h("div", { class: "dos" }, crear(campos[i]), crear(campos[i + 1]))); i++; }
      else filas.push(crear(campos[i]));
    }
    const form = h("form", { novalidate: false }, nota ? h("div", { class: "aviso", texto: nota }) : null, err, filas);
    const guardar = async () => {
      if (!form.reportValidity()) return;
      const datos = {};
      for (const [n, { el, c }] of Object.entries(entradas)) {
        if (c.deshab && !c.enviarDeshab) continue;
        if (c.tipo === "check") datos[n] = el.checked;
        else if (el.value.trim() === "") { if (!c.req) datos[n] = null; else datos[n] = ""; }
        else if (c.tipo === "number" || c.num) datos[n] = Number(el.value.replace(",", "."));
        else datos[n] = c.tipo === "password" ? el.value : el.value.trim();
      }
      const b = $("#f-guardar");
      b.disabled = true;
      err.classList.add("oculto");
      try { await enviar(datos); cerrarModal(); }
      catch (e) { err.textContent = e.message; err.classList.remove("oculto"); b.disabled = false; }
    };
    form.addEventListener("submit", (ev) => { ev.preventDefault(); guardar(); });
    modal({ titulo, cuerpo: form, botones: [{ t: "Cancelar", onclick: cerrarModal }, { t: boton, cls: "primario", id: "f-guardar", onclick: guardar }] });
    const primero = form.querySelector("input:not([disabled]), select:not([disabled]), textarea:not([disabled])");
    if (primero) primero.focus();
  }

  /* ---------- Tabla ---------- */
  /* cols: [{t, k, num, f(fila)->texto|nodo}] ; opciones: {vacio, claseFila(fila)} */
  function tabla(cols, filas, opciones = {}) {
    if (!filas || !filas.length) return h("div", { class: "vacio", texto: opciones.vacio || "No hay registros para mostrar." });
    return h("div", { class: "tabla-caja" }, h("table", null,
      h("thead", null, h("tr", null, cols.map((c) => h("th", { class: c.num ? "num" : c.acc ? "acc" : "" }, c.t)))),
      h("tbody", null, filas.map((fila) => h("tr", { class: opciones.claseFila ? opciones.claseFila(fila) : "" },
        cols.map((c) => {
          const v = c.f ? c.f(fila) : fila[c.k];
          return h("td", { class: c.num ? "num" : c.acc ? "acc" : "" }, v === null || v === undefined || v === "" ? (c.acc ? "" : "—") : v);
        }))))));
  }
  const boton = (texto, onclick, cls = "") => h("button", { class: "btn chico " + cls, type: "button", onclick }, texto);

  function pestanas(items, activa, alCambiar) {
    return h("div", { class: "pestanas", role: "tablist" }, items.map((it) =>
      h("button", { type: "button", role: "tab", "aria-selected": String(it.id === activa), onclick: () => alCambiar(it.id) }, it.t)));
  }

  return { h, $, fmt, insignia, puede, estado, api, GET, POST, PUT, DEL, alPerderSesion, aviso, hacer, modal, cerrarModal,
    confirmar, formulario, tabla, boton, pestanas, ErrorApi };
})();
