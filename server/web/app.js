(() => {
  "use strict";

  const TOKEN_KEY = "aether-cloud-token";
  const BACKOFF = [400, 1000, 2000, 4000, 5000];
  const KEYS = {
    esc: "\x1b",
    tab: "\t",
    "/": "/",
    "-": "-",
    left: "\x1b[D",
    right: "\x1b[C",
    up: "\x1b[A",
    down: "\x1b[B",
  };

  const frame = document.getElementById("frame");
  const gate = document.getElementById("gate");
  const desk = document.getElementById("desk");
  const gateNote = document.getElementById("gate-note");
  const deskNote = document.getElementById("desk-note");
  const linkEl = document.getElementById("link");
  const sessionsEl = document.getElementById("sessions");
  const stage = document.getElementById("stage");
  const keysink = document.getElementById("keysink");
  const keybar = document.getElementById("keybar");
  const ctrlKey = document.getElementById("ctrl-key");
  const pairPanel = document.getElementById("pair-panel");
  const pairCode = document.getElementById("pair-code");
  const pairExpires = document.getElementById("pair-expires");
  const pairURL = document.getElementById("pair-url");
  const pairCopy = document.getElementById("pair-copy");
  const enrollForm = document.getElementById("enroll-form");
  const claimForm = document.getElementById("claim-form");
  const codeInput = document.getElementById("code");
  const newButton = document.getElementById("new-terminal");
  const pairButton = document.getElementById("pair");
  const signOutButton = document.getElementById("sign-out");

  const narrowQuery = window.matchMedia("(max-width: 720px)");
  const coarseQuery = window.matchMedia("(pointer: coarse), (hover: none)");

  const sessions = new Map();
  const buffers = new Map();
  const locallyClosed = new Set();
  let order = [];
  let visibleId = null;
  let probe = null;
  let socket = null;
  let generation = 0;
  let attempt = 0;
  let ready = false;
  let booted = false;
  let reconnectTimer = 0;
  let appliedFont = 0;
  let fitQueued = false;
  let ctrlSticky = false;
  let sinkSent = false;
  const pendingCreates = [];

  function fontSize() {
    return narrowQuery.matches ? 13 : 14;
  }

  function touchInput() {
    return narrowQuery.matches || coarseQuery.matches;
  }

  function termOptions() {
    return {
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: fontSize(),
      cursorBlink: false,
      scrollback: 10000,
      allowTransparency: true,
      convertEol: false,
      theme: {
        background: "rgba(0,0,0,0.28)",
        foreground: "#f2f7f8",
        cursor: "#f2f7f8",
        cursorAccent: "#141b1e",
        selectionBackground: "rgba(242,247,248,0.22)",
        selectionInactiveBackground: "rgba(242,247,248,0.22)",
      },
    };
  }

  function tuneTextarea(el) {
    if (!el) return;
    el.setAttribute("autocomplete", "off");
    el.setAttribute("autocorrect", "off");
    el.setAttribute("autocapitalize", "off");
    el.setAttribute("spellcheck", "false");
    el.style.fontSize = "16px";
  }

  function bytesToBase64(bytes) {
    let binary = "";
    const size = 0x8000;
    for (let i = 0; i < bytes.length; i += size) {
      binary += String.fromCharCode(...bytes.subarray(i, i + size));
    }
    return btoa(binary);
  }

  function base64ToBytes(data) {
    const binary = atob(String(data).replace(/\s/g, ""));
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i) & 255;
    return out;
  }

  function socketURL() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    return proto + "//" + location.host + "/ws";
  }

  function setNote(text) {
    const line = text ? String(text).replace(/\s+/g, " ").trim() : "";
    gateNote.textContent = line;
    deskNote.textContent = line;
    gateNote.title = line;
    deskNote.title = line;
  }

  function setLink(text) {
    linkEl.textContent = text || "";
  }

  function showGate(message) {
    gate.hidden = false;
    desk.hidden = true;
    setNote(message || "");
  }

  function showDesk() {
    gate.hidden = true;
    desk.hidden = false;
    queueFit();
  }

  function cssEscape(value) {
    if (window.CSS && typeof CSS.escape === "function") return CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  function libraryReady() {
    return window.AetherXterm && typeof AetherXterm.Terminal === "function" && typeof AetherXterm.FitAddon === "function";
  }

  function openTerm(host) {
    const term = new AetherXterm.Terminal(termOptions());
    const fit = new AetherXterm.FitAddon();
    term.loadAddon(fit);
    term.open(host);
    tuneTextarea(term.textarea);
    return { term, fit };
  }

  function ensureProbe() {
    if (probe) return probe;
    const host = document.createElement("div");
    host.className = "term-host is-probe";
    host.setAttribute("aria-hidden", "true");
    stage.appendChild(host);
    const opened = openTerm(host);
    if (opened.term.textarea) opened.term.textarea.tabIndex = -1;
    probe = { host, term: opened.term, fit: opened.fit };
    return probe;
  }

  function ensureSession(id, title) {
    id = String(id);
    let session = sessions.get(id);
    if (session) {
      if (title) session.title = title;
      return session;
    }
    const host = document.createElement("div");
    host.className = "term-host";
    stage.appendChild(host);
    const opened = openTerm(host);
    const term = opened.term;
    term.onData((data) => {
      if (visibleId !== id) return;
      sendInput(id, data);
    });
    session = {
      id,
      title: title || "Terminal",
      cwd: "",
      state: "idle",
      msg: "",
      term,
      fit: opened.fit,
      host,
      attached: false,
      exited: false,
      sentCols: 0,
      sentRows: 0,
    };
    sessions.set(id, session);
    return session;
  }

  function remember(id) {
    if (!order.includes(id)) order.push(id);
  }

  function fitNow(entry) {
    try {
      entry.fit.fit();
    } catch (err) {
      /* The host has no size yet. */
    }
    return {
      cols: entry.term.cols || 80,
      rows: entry.term.rows || 24,
    };
  }

  function fittedSize() {
    const session = visibleId && sessions.get(visibleId);
    if (session && session.host.classList.contains("is-on")) return fitNow(session);
    const measuring = ensureProbe();
    measuring.host.classList.add("is-on");
    return fitNow(measuring);
  }

  function send(msg) {
    if (!socket || socket.readyState !== WebSocket.OPEN) return false;
    socket.send(JSON.stringify(msg));
    return true;
  }

  function sendInput(id, text) {
    if (!id || text == null || text === "") return;
    const bytes = new TextEncoder().encode(text);
    send({ type: "input", id, data: bytesToBase64(bytes) });
  }

  function sendResize(session, size) {
    const cols = size.cols | 0;
    const rows = size.rows | 0;
    if (cols < 2 || rows < 2) return;
    if (!ready || !session.attached) return;
    if (session.sentCols === cols && session.sentRows === rows) return;
    session.sentCols = cols;
    session.sentRows = rows;
    send({ type: "resize", id: session.id, cols, rows });
  }

  function show(id) {
    visibleId = String(id);
    if (probe) probe.host.classList.remove("is-on");
    for (const [sid, session] of sessions) {
      session.host.classList.toggle("is-on", sid === visibleId);
    }
    const session = sessions.get(visibleId);
    if (session) sendResize(session, fitNow(session));
    renderRail();
    focusSurface();
  }

  function attach(id, reveal) {
    const session = sessions.get(String(id));
    if (!session) return;
    if (session.exited) {
      if (reveal !== false) show(session.id);
      return;
    }
    if (reveal !== false) show(session.id);
    if (session.attached) return;
    const measured = visibleId === session.id ? fitNow(session) : { cols: session.term.cols || 80, rows: session.term.rows || 24 };
    const cols = measured.cols >= 2 ? measured.cols : 80;
    const rows = measured.rows >= 2 ? measured.rows : 24;
    session.sentCols = cols;
    session.sentRows = rows;
    send({ type: "attach", id: session.id, cols, rows });
  }

  function createSession() {
    if (!ready) {
      setNote("Reconnecting");
      return;
    }
    const size = fittedSize();
    const cols = Math.max(80, size.cols | 0 || 80);
    const rows = Math.max(24, size.rows | 0 || 24);
    pendingCreates.push({ cols, rows });
    send({ type: "create", cols, rows, cwd: "", command: "" });
  }

  function focusSurface() {
    if (desk.hidden) return;
    if (touchInput()) {
      keysink.focus({ preventScroll: true });
      return;
    }
    const session = visibleId && sessions.get(visibleId);
    if (session) session.term.focus();
  }

  function renderRail() {
    const seen = new Set();
    let previous = null;
    for (const id of order) {
      const session = sessions.get(id);
      if (!session) continue;
      seen.add(id);
      let row = sessionsEl.querySelector('[data-id="' + cssEscape(id) + '"]');
      if (!row) {
        row = document.createElement("div");
        row.className = "row";
        row.dataset.id = id;
        row.setAttribute("role", "listitem");
        const open = document.createElement("button");
        open.type = "button";
        open.className = "row-open";
        const title = document.createElement("span");
        title.className = "row-title";
        const state = document.createElement("span");
        state.className = "row-state";
        open.append(title, state);
        const close = document.createElement("button");
        close.type = "button";
        close.className = "row-close";
        close.textContent = "×";
        open.addEventListener("click", () => {
          const current = sessions.get(id);
          if (!current) return;
          if (current.attached || current.exited) show(id);
          else attach(id, true);
        });
        close.addEventListener("click", (event) => {
          event.stopPropagation();
          send({ type: "close", id });
        });
        row.append(open, close);
        sessionsEl.appendChild(row);
      }
      const stateWord = session.exited ? "exited" : (session.state || "idle");
      const titleEl = row.querySelector(".row-title");
      const stateEl = row.querySelector(".row-state");
      titleEl.textContent = session.title || "Terminal";
      stateEl.textContent = stateWord;
      stateEl.dataset.state = stateWord;
      row.querySelector(".row-open").title = session.msg || session.cwd || "";
      row.querySelector(".row-close").setAttribute("aria-label", "Close " + (session.title || "terminal"));
      row.classList.toggle("is-current", id === visibleId);
      if (previous) {
        if (row.previousElementSibling !== previous) previous.after(row);
      } else if (sessionsEl.firstElementChild !== row) {
        sessionsEl.prepend(row);
      }
      previous = row;
    }
    for (const row of [...sessionsEl.querySelectorAll(".row")]) {
      if (!seen.has(row.dataset.id)) row.remove();
    }
  }

  function syncSessions(items) {
    const listed = [];
    const seen = new Set();
    for (const item of items) {
      if (!item || item.id == null) continue;
      const id = String(item.id);
      seen.add(id);
      listed.push(id);
      const session = ensureSession(id, item.title);
      session.title = item.title || session.title || "Terminal";
      session.cwd = item.cwd || "";
      session.msg = typeof item.msg === "string" ? item.msg : "";
      if (locallyClosed.has(id)) {
        session.exited = true;
        session.attached = false;
        session.state = "exited";
      } else {
        session.exited = false;
        session.state = item.state || "idle";
      }
    }
    for (const id of order) {
      if (seen.has(id)) continue;
      const session = sessions.get(id);
      if (!session) continue;
      session.exited = true;
      session.attached = false;
      session.state = "exited";
      listed.push(id);
    }
    order = listed;
  }

  function onSessions(items) {
    const list = Array.isArray(items) ? items : [];
    syncSessions(list);
    if (!booted) {
      booted = true;
      if (!visibleId) {
        if (list.length && list[0] && list[0].id != null) attach(list[0].id, true);
        else createSession();
      }
    }
    renderRail();
  }

  function onCreated(msg) {
    const id = String(msg.id);
    const session = ensureSession(id, msg.title);
    session.attached = true;
    session.exited = false;
    locallyClosed.delete(id);
    session.title = msg.title || session.title || "Terminal";
    session.state = session.state || "idle";
    const pending = pendingCreates.shift();
    if (pending) {
      session.sentCols = pending.cols;
      session.sentRows = pending.rows;
    }
    remember(id);
    const queued = buffers.get(id) || [];
    buffers.delete(id);
    show(id);
    for (const chunk of queued) session.term.write(chunk);
  }

  function onAttached(msg) {
    const id = String(msg.id);
    buffers.delete(id);
    const session = ensureSession(id, msg.title);
    session.term.reset();
    session.attached = true;
    session.exited = false;
    locallyClosed.delete(id);
    if (msg.title) session.title = msg.title;
    if (typeof msg.state === "string" && msg.state) session.state = msg.state;
    if (typeof msg.msg === "string") session.msg = msg.msg;
    remember(id);
    show(id);
  }

  function onOutput(msg) {
    const id = String(msg.id);
    let bytes;
    try {
      bytes = base64ToBytes(msg.data || "");
    } catch (err) {
      setNote("Could not read terminal output");
      return;
    }
    const session = sessions.get(id);
    if (!session) {
      const queued = buffers.get(id) || [];
      queued.push(bytes);
      if (queued.length > 200) queued.shift();
      buffers.set(id, queued);
      return;
    }
    session.term.write(bytes);
  }

  function onStatus(msg) {
    const session = sessions.get(String(msg.id));
    if (!session || session.exited) return;
    if (typeof msg.state === "string" && msg.state) session.state = msg.state;
    if (typeof msg.msg === "string") session.msg = msg.msg;
    renderRail();
  }

  function onClosed(id) {
    const session = sessions.get(String(id));
    if (!session) return;
    session.exited = true;
    session.attached = false;
    session.state = "exited";
    locallyClosed.add(session.id);
    renderRail();
  }

  function onHello() {
    ready = true;
    attempt = 0;
    setLink("");
    setNote("");
    send({ type: "list" });
    if (!visibleId) return;
    const session = sessions.get(visibleId);
    if (!session || session.exited) return;
    session.attached = false;
    attach(visibleId, true);
  }

  function handleMessage(msg) {
    if (!msg || typeof msg !== "object") return;
    if (msg.type === "error") {
      const message = String(msg.message || "Something went wrong");
      if (/unauthorized/i.test(message)) {
        signOut(message);
        return;
      }
      setNote(message);
      return;
    }
    if (msg.type === "helloOk") {
      onHello();
      return;
    }
    if (!ready) return;
    if (msg.type === "sessions") onSessions(msg.items);
    else if (msg.type === "created" && msg.id != null) onCreated(msg);
    else if (msg.type === "attached" && msg.id != null) onAttached(msg);
    else if (msg.type === "output" && msg.id != null) onOutput(msg);
    else if (msg.type === "status" && msg.id != null) onStatus(msg);
    else if (msg.type === "resync" && msg.id != null) {
      const session = sessions.get(String(msg.id));
      if (!session || session.exited) return;
      session.attached = false;
      attach(session.id, session.id === visibleId);
    } else if (msg.type === "closed" && msg.id != null) onClosed(msg.id);
  }

  function wipe() {
    for (const session of sessions.values()) {
      try { session.term.dispose(); } catch (err) { /* already gone */ }
      session.host.remove();
    }
    sessions.clear();
    buffers.clear();
    locallyClosed.clear();
    order = [];
    visibleId = null;
    booted = false;
    ready = false;
    attempt = 0;
    pendingCreates.length = 0;
    ctrlSticky = false;
    paintCtrl();
    if (probe) {
      try { probe.term.dispose(); } catch (err) { /* already gone */ }
      probe.host.remove();
      probe = null;
    }
    sessionsEl.replaceChildren();
    pairPanel.hidden = true;
  }

  function signOut(message) {
    generation += 1;
    clearTimeout(reconnectTimer);
    localStorage.removeItem(TOKEN_KEY);
    const ws = socket;
    socket = null;
    if (ws) {
      ws.onclose = null;
      ws.onmessage = null;
      ws.onerror = null;
      try { ws.close(); } catch (err) { /* already closed */ }
    }
    wipe();
    showGate(message || "");
  }

  function connect() {
    if (!localStorage.getItem(TOKEN_KEY)) {
      showGate("");
      return;
    }
    if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
    clearTimeout(reconnectTimer);
    const gen = ++generation;
    const ws = new WebSocket(socketURL());
    socket = ws;
    ready = false;
    setLink(attempt === 0 ? "Connecting" : "Reconnecting");
    showDesk();
    const helloTimer = setTimeout(() => {
      if (gen !== generation || ready) return;
      try { ws.close(); } catch (err) { /* already closed */ }
    }, 8000);
    ws.onopen = () => {
      if (gen !== generation) return;
      const token = localStorage.getItem(TOKEN_KEY);
      if (!token) {
        try { ws.close(); } catch (err) { /* already closed */ }
        return;
      }
      ws.send(JSON.stringify({ type: "hello", token, client: "web" }));
    };
    ws.onmessage = (event) => {
      if (gen !== generation) return;
      if (typeof event.data !== "string") return;
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch (err) {
        return;
      }
      if (msg && msg.type === "helloOk") clearTimeout(helloTimer);
      handleMessage(msg);
    };
    ws.onerror = () => {
      try { ws.close(); } catch (err) { /* already closed */ }
    };
    ws.onclose = () => {
      clearTimeout(helloTimer);
      if (gen !== generation) return;
      if (socket === ws) socket = null;
      ready = false;
      for (const session of sessions.values()) session.attached = false;
      const delay = BACKOFF[Math.min(attempt, BACKOFF.length - 1)];
      attempt += 1;
      setLink("Reconnecting");
      reconnectTimer = setTimeout(() => {
        if (gen !== generation) return;
        connect();
      }, delay);
    };
  }

  function layoutChrome() {
    const vv = window.visualViewport;
    if (!vv) return;
    const overlap = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
    frame.classList.toggle("keyboard-open", overlap > 80);
    const top = vv.offsetTop + "px";
    const left = vv.offsetLeft + "px";
    const width = vv.width + "px";
    const height = vv.height + "px";
    if (frame.style.top !== top) frame.style.top = top;
    if (frame.style.left !== left) frame.style.left = left;
    if (frame.style.width !== width) frame.style.width = width;
    if (frame.style.height !== height) frame.style.height = height;
  }

  function applyFont() {
    const size = fontSize();
    if (size === appliedFont) return false;
    appliedFont = size;
    for (const session of sessions.values()) session.term.options.fontSize = size;
    if (probe) probe.term.options.fontSize = size;
    return true;
  }

  function fitVisible() {
    if (desk.hidden) return;
    const session = visibleId && sessions.get(visibleId);
    if (!session || !session.host.classList.contains("is-on")) return;
    sendResize(session, fitNow(session));
  }

  function queueFit() {
    if (fitQueued) return;
    fitQueued = true;
    requestAnimationFrame(() => {
      fitQueued = false;
      layoutChrome();
      const changed = applyFont();
      fitVisible();
      if (changed) requestAnimationFrame(fitVisible);
    });
  }

  function stopScroll() {
    if (window.scrollX || window.scrollY) window.scrollTo(0, 0);
  }

  function controlByte(ch) {
    if (!ch || ch.length !== 1) return "";
    const code = ch.toLowerCase().charCodeAt(0);
    if (code >= 97 && code <= 122) return String.fromCharCode(code - 96);
    return "";
  }

  function paintCtrl() {
    ctrlKey.setAttribute("aria-pressed", ctrlSticky ? "true" : "false");
  }

  function clearCtrl() {
    if (!ctrlSticky) return;
    ctrlSticky = false;
    paintCtrl();
  }

  function takeCtrl(text) {
    if (!ctrlSticky) return text;
    clearCtrl();
    if (text.length === 1) {
      const byte = controlByte(text);
      if (byte) return byte;
    }
    return text;
  }

  function emitSink(text) {
    sinkSent = true;
    sendInput(visibleId, text);
    keysink.value = "";
    queueMicrotask(() => {
      sinkSent = false;
    });
  }

  function onSinkKey(event) {
    if (event.isComposing || event.keyCode === 229) return;
    if (event.key === "Control" || event.key === "Shift" || event.key === "Alt" || event.key === "Meta") return;
    if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key.length === 1) {
      const byte = controlByte(event.key);
      if (byte) {
        event.preventDefault();
        clearCtrl();
        emitSink(byte);
      }
      return;
    }
    if (ctrlSticky && event.key.length === 1 && !event.altKey) {
      const byte = controlByte(event.key);
      if (byte) {
        event.preventDefault();
        clearCtrl();
        emitSink(byte);
        return;
      }
    }
    const special = {
      Escape: "\x1b",
      Tab: "\t",
      ArrowUp: "\x1b[A",
      ArrowDown: "\x1b[B",
      ArrowRight: "\x1b[C",
      ArrowLeft: "\x1b[D",
    };
    if (Object.prototype.hasOwnProperty.call(special, event.key)) {
      event.preventDefault();
      emitSink(takeCtrl(special[event.key]));
      return;
    }
    if (event.key === "Backspace") {
      event.preventDefault();
      clearCtrl();
      emitSink("\x7f");
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      clearCtrl();
      emitSink("\r");
    }
  }

  function onSinkBefore(event) {
    if (event.isComposing) return;
    if (sinkSent) {
      event.preventDefault();
      return;
    }
    const type = event.inputType;
    if ((type === "insertText" || type === "insertFromPaste" || type === "insertReplacementText") && event.data) {
      event.preventDefault();
      emitSink(takeCtrl(event.data));
      return;
    }
    if (type === "deleteContentBackward") {
      event.preventDefault();
      clearCtrl();
      emitSink("\x7f");
      return;
    }
    if (type === "insertLineBreak" || type === "insertParagraph") {
      event.preventDefault();
      clearCtrl();
      emitSink("\r");
    }
  }

  function stripPair() {
    const url = new URL(location.href);
    if (!url.searchParams.has("pair")) return;
    url.searchParams.delete("pair");
    history.replaceState(null, "", url.pathname + url.search + url.hash);
  }

  async function postJSON(path, body, token) {
    const headers = {};
    const init = { method: "POST", headers };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    if (token) headers.Authorization = "Bearer " + token;
    let res;
    try {
      res = await fetch(path, init);
    } catch (err) {
      throw new Error("Could not reach the server");
    }
    const text = await res.text();
    let data = null;
    if (text) {
      try { data = JSON.parse(text); } catch (err) { data = null; }
    }
    if (!res.ok) {
      let message = "";
      if (data && typeof data === "object") message = data.message || data.error || "";
      else if (typeof data === "string") message = data;
      if (!message && text && !text.trim().startsWith("<")) message = text.trim();
      if (!message) message = "Request failed (" + res.status + ")";
      throw new Error(String(message).replace(/\s+/g, " ").trim());
    }
    return data || {};
  }

  function storeToken(data) {
    if (!data || typeof data.token !== "string" || !data.token) {
      throw new Error("The server did not return a token");
    }
    localStorage.setItem(TOKEN_KEY, data.token);
  }

  async function runAction(button, fn) {
    if (button) button.disabled = true;
    try {
      await fn();
    } catch (err) {
      const message = err && err.message ? err.message : "Something went wrong";
      if (/unauthorized/i.test(message) && localStorage.getItem(TOKEN_KEY)) signOut(message);
      else setNote(message);
    } finally {
      if (button) button.disabled = false;
    }
  }

  function formatExpiry(value) {
    if (value == null || value === "") return "";
    let date = null;
    if (typeof value === "number" || (typeof value === "string" && /^\d+$/.test(value))) {
      const n = Number(value);
      date = new Date(n > 1e12 ? n : n * 1000);
    } else {
      date = new Date(value);
    }
    if (!date || Number.isNaN(date.getTime()) || date.getTime() < Date.now() - 60000) return "";
    return "Expires " + date.toLocaleString(undefined, {
      hour: "numeric",
      minute: "2-digit",
      month: "short",
      day: "numeric",
    });
  }

  function claim(code) {
    return runAction(claimForm.querySelector("button"), async () => {
      setNote("Checking the code");
      const data = await postJSON("/claim", { code });
      storeToken(data);
      stripPair();
      setNote("");
      connect();
    }).then(() => {
      stripPair();
    });
  }

  enrollForm.addEventListener("submit", (event) => {
    event.preventDefault();
    runAction(enrollForm.querySelector("button"), async () => {
      const data = await postJSON("/enroll", {});
      storeToken(data);
      setNote("");
      connect();
    });
  });

  claimForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const code = codeInput.value.trim();
    if (!code) {
      setNote("Enter a code");
      return;
    }
    claim(code);
  });

  newButton.addEventListener("click", () => createSession());

  pairButton.addEventListener("click", () => {
    runAction(pairButton, async () => {
      const token = localStorage.getItem(TOKEN_KEY);
      if (!token) {
        signOut("");
        return;
      }
      const data = await postJSON("/pair", undefined, token);
      if (!data.code) throw new Error("The server did not return a code");
      pairCode.textContent = String(data.code);
      pairURL.value = data.url ? String(data.url) : "";
      pairExpires.textContent = formatExpiry(data.expires);
      pairPanel.hidden = false;
      setNote("");
      queueFit();
    });
  });

  pairCopy.addEventListener("click", async () => {
    pairURL.focus();
    pairURL.select();
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(pairURL.value);
        pairCopy.textContent = "Copied";
        setTimeout(() => {
          pairCopy.textContent = "Copy link";
        }, 1600);
      }
    } catch (err) {
      pairCopy.textContent = "Copy link";
    }
  });

  signOutButton.addEventListener("click", () => signOut(""));

  keybar.addEventListener("pointerdown", (event) => {
    if (event.target.closest("button")) event.preventDefault();
  });

  keybar.addEventListener("click", (event) => {
    const button = event.target.closest("button");
    if (!button) return;
    const name = button.dataset.key;
    if (name === "ctrl") {
      ctrlSticky = !ctrlSticky;
      paintCtrl();
      focusSurface();
      return;
    }
    if (name === "ctrl-c") {
      clearCtrl();
      sendInput(visibleId, "\x03");
      focusSurface();
      return;
    }
    if (!Object.prototype.hasOwnProperty.call(KEYS, name)) return;
    sendInput(visibleId, takeCtrl(KEYS[name]));
    focusSurface();
  });

  keysink.addEventListener("keydown", onSinkKey);
  keysink.addEventListener("beforeinput", onSinkBefore);
  keysink.addEventListener("input", () => {
    if (sinkSent) {
      keysink.value = "";
      return;
    }
    if (keysink.value) emitSink(takeCtrl(keysink.value));
  });
  keysink.addEventListener("compositionend", (event) => {
    if (event.data) sendInput(visibleId, event.data);
    keysink.value = "";
  });
  keysink.addEventListener("focus", stopScroll);

  stage.addEventListener("pointerdown", () => focusSurface());
  stage.addEventListener("focusin", (event) => {
    if (!touchInput()) return;
    const target = event.target;
    if (target && target.classList && target.classList.contains("xterm-helper-textarea")) {
      keysink.focus({ preventScroll: true });
    }
  });

  document.addEventListener("touchmove", (event) => {
    const node = event.target;
    if (node && node.closest && node.closest(".sessions, .rail, .xterm-viewport, .keybar, input, textarea")) return;
    event.preventDefault();
  }, { passive: false });

  window.addEventListener("resize", queueFit);
  window.addEventListener("scroll", stopScroll, { passive: true });
  if (window.visualViewport) {
    visualViewport.addEventListener("resize", queueFit);
    visualViewport.addEventListener("scroll", () => {
      stopScroll();
      queueFit();
    });
  }
  narrowQuery.addEventListener("change", () => {
    queueFit();
    focusSurface();
  });
  coarseQuery.addEventListener("change", () => focusSurface());
  new ResizeObserver(() => queueFit()).observe(stage);

  if (!libraryReady()) {
    setNote("The terminal did not load.");
  }

  layoutChrome();
  const pair = new URLSearchParams(location.search).get("pair");
  if (pair && pair.trim()) claim(pair.trim());
  else if (localStorage.getItem(TOKEN_KEY)) connect();
  else showGate("");
})();
