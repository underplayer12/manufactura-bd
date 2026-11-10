/* app.js - arranque: login, menu segun el rol, cambio de clave obligatorio y navegacion. */
"use strict";

(() => {
  const { h, $, GET, POST, estado, aviso, formulario, puede } = N;
  let vistaActual = "inicio";

  const mostrar = (cual) => {
    $("#pantalla-login").classList.toggle("oculto", cual !== "login");
    $("#app").classList.toggle("oculto", cual !== "app");
  };

  function pintarMenu() {
    const items = V.MENU.filter((m) => m.sep || puede(m.rol));
    $("#menu").replaceChildren(...items.map((m) => (m.sep
      ? h("div", { class: "sep", texto: m.sep })
      : h("button", { type: "button", "aria-current": m.id === vistaActual ? "page" : null, onclick: () => ir(m.id) }, m.t))));
  }
  function ir(id) {
    vistaActual = id;
    pintarMenu();
    const def = V.MENU.find((m) => m.id === id);
    $("#barra-titulo").textContent = def ? def.t : "";
    history.replaceState(null, "", "#" + id);
    V[id]($("#contenido"));
    window.scrollTo(0, 0);
  }

  function pedirCambioClave(obligatorio) {
    formulario({
      titulo: obligatorio ? "Debes cambiar tu clave" : "Cambiar mi clave", boton: "Cambiar clave",
      nota: obligatorio ? "Tu clave actual es temporal. Elige una propia para continuar." : "Mínimo 8 caracteres, con letras y números.",
      campos: [{ n: "clave_actual", et: "Clave actual", tipo: "password", req: true }, { n: "clave_nueva", et: "Clave nueva", tipo: "password", req: true, ayuda: "Mínimo 8 caracteres, con letras y números." }],
      enviar: async (d) => {
        await POST("cambiar-clave", d);
        aviso("Clave cambiada");
        estado.yo.debe_cambiar_clave = false;
        if (obligatorio) entrarApp();
      },
    });
    if (obligatorio) {
      // sin clave propia no se puede seguir: el boton "x" y Esc no deben dejar pasar
      const d = $("#modal"); d.addEventListener("cancel", (e) => e.preventDefault(), { once: true });
      const x = d.querySelector(".cerrar"); if (x) x.classList.add("oculto");
      const cancelar = [...d.querySelectorAll(".d-pie .btn")].find((b) => b.textContent === "Cancelar");
      if (cancelar) cancelar.addEventListener("click", salir, { once: true });
    }
  }

  function entrarApp() {
    mostrar("app");
    $("#yo-texto").textContent = `${estado.yo.nombre} · ${estado.yo.rol}`;
    const pedida = location.hash.slice(1);
    vistaActual = V.MENU.some((m) => m.id === pedida && (!m.rol || puede(m.rol))) ? pedida : "inicio";
    ir(vistaActual);
    if (estado.yo.debe_cambiar_clave) pedirCambioClave(true);
  }

  function mostrarLogin(mensaje) {
    estado.yo = null;
    history.replaceState(null, "", location.pathname);   // el proximo usuario empieza en Inicio
    N.cerrarModal();
    mostrar("login");
    $("#l-clave").value = "";
    const e = $("#login-error");
    e.textContent = mensaje || "";
    e.classList.toggle("oculto", !mensaje);
    $("#l-usuario").focus();
  }
  async function salir() {
    try { await POST("logout"); } catch (e) { /* si ya no habia sesion, igual salimos */ }
    mostrarLogin();
  }

  $("#form-login").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const boton = ev.submitter; boton.disabled = true;
    try {
      estado.yo = await POST("login", { usuario: $("#l-usuario").value.trim(), clave: $("#l-clave").value });
      $("#login-error").classList.add("oculto");
      entrarApp();
    } catch (e) {
      $("#login-error").textContent = e.message;
      $("#login-error").classList.remove("oculto");
      $("#l-clave").value = ""; $("#l-clave").focus();
    } finally { boton.disabled = false; }
  });
  $("#btn-salir").addEventListener("click", salir);
  $("#btn-clave").addEventListener("click", () => pedirCambioClave(false));
  N.alPerderSesion(() => mostrarLogin("Tu sesión terminó. Ingresa de nuevo."));

  // Al abrir la pagina: ¿ya hay sesion?
  (async () => {
    try { estado.yo = await GET("yo"); entrarApp(); }
    catch (e) {
      mostrarLogin();
    }
  })();
})();
