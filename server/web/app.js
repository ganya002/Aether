(() => {
  "use strict";

  const TOKEN_KEY = "aether-cloud-token";
  const FONT_KEY = "aether-cloud-font-size";
  const KEYS_KEY = "aether-cloud-keybar";
  const BACKOFF = [400, 1000, 2000, 4000, 5000];
  const PING_EVERY = 20000;
  const PONG_WAIT = 8000;
  const QUEUE_LIMIT = 4096;
  const BUFFER_LIMIT = 2 * 1024 * 1024;
  const LONG_RUN = 60000;
  const LONG_PRESS = 520;
  const FONT_MIN = 9;
  const FONT_MAX = 28;
  const TRIMMED_NOTE = "\x1b[2m[Earlier output was trimmed]\x1b[0m\r\n";
  const URL_PATTERN = /https?:\/\/[^\s"'<>`\u0000-\u001f]+/g;
  const KEYS = {
    esc: "\x1b",
    tab: "\t",
    "|": "|",
    "~": "~",
    "/": "/",
    "-": "-",
    left: "\x1b[D",
    right: "\x1b[C",
    up: "\x1b[A",
    down: "\x1b[B",
    home: "\x1b[H",
    end: "\x1b[F",
    pgup: "\x1b[5~",
    pgdn: "\x1b[6~",
  };
  const RAW_KEYS = {
    "ctrl-c": "\x03",
    "ctrl-d": "\x04",
    "ctrl-z": "\x1a",
    "ctrl-r": "\x12",
  };
  const STATE_WORDS = {
    idle: "Idle",
    working: "Working",
    blocked: "Needs you",
    done: "Done",
    error: "Error",
    exited: "Exited",
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
  const altKey = document.getElementById("alt-key");
  const selectKey = document.getElementById("select-key");
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
  const notifyButton = document.getElementById("notify");
  const keysToggle = document.getElementById("keys-toggle");
  const signOutButton = document.getElementById("sign-out");
  const pairKeep = document.getElementById("pair-keep");
  const offline = document.getElementById("offline");
  const offlineText = document.getElementById("offline-text");
  const retryButton = document.getElementById("retry");
  const ended = document.getElementById("ended");
  const endedText = document.getElementById("ended-text");
  const restartButton = document.getElementById("restart");
  const removeButton = document.getElementById("remove");
  const selectSheet = document.getElementById("select-sheet");
  const selectText = document.getElementById("select-text");
  const selectCopy = document.getElementById("select-copy");
  const selectDone = document.getElementById("select-done");
  const announcer = document.getElementById("announce");

  const narrowQuery = window.matchMedia("(max-width: 720px)");
  const coarseQuery = window.matchMedia("(pointer: coarse), (hover: none)");
  const lightQuery = window.matchMedia("(prefers-color-scheme: light)");

  const sessions = new Map();
  const buffers = new Map();
  const locallyClosed = new Set();
  const closing = new Set();
  const forgotten = new Set();
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
  let fontOverride = 0;
  let fitQueued = false;
  let ctrlSticky = false;
  let altSticky = false;
  let selecting = false;
  let sinkSent = false;
  let composing = false;
  let pingTimer = 0;
  let pongTimer = 0;
  let queuedBytes = 0;
  let queueFull = false;
  const pendingCreates = [];
  const queuedInput = [];

  function readFont() {
    const stored = Number(localStorage.getItem(FONT_KEY));
    if (Number.isFinite(stored) && stored >= FONT_MIN && stored <= FONT_MAX) return Math.round(stored);
    return 0;
  }

  function fontSize() {
    return readFont() || (narrowQuery.matches ? 13 : 14);
  }

  function setFontSize(size, keep) {
    const next = Math.max(FONT_MIN, Math.min(FONT_MAX, Math.round(size)));
    if (keep !== false) localStorage.setItem(FONT_KEY, String(next));
    else fontOverride = next;
    queueFit();
    return next;
  }

  function currentFont() {
    return fontOverride || fontSize();
  }

  function touchInput() {
    return narrowQuery.matches || coarseQuery.matches;
  }

  function termTheme() {
    if (lightQuery.matches) {
      return {
        background: "rgba(255,255,255,0.3)",
        foreground: "#162024",
        cursor: "#162024",
        cursorAccent: "#f4f7f8",
        selectionBackground: "rgba(22,32,36,0.18)",
        selectionInactiveBackground: "rgba(22,32,36,0.12)",
        black: "#162024",
        red: "#c0362c",
        green: "#2c7d3a",
        yellow: "#8f6500",
        blue: "#1f5fbf",
        magenta: "#9b3aa3",
        cyan: "#14727e",
        white: "#7d878b",
        brightBlack: "#59656a",
        brightRed: "#d6453b",
        brightGreen: "#36964a",
        brightYellow: "#a87a00",
        brightBlue: "#2d74e0",
        brightMagenta: "#b24dbb",
        brightCyan: "#1a8a99",
        brightWhite: "#a6afb3",
      };
    }
    return {
      background: "rgba(0,0,0,0.28)",
      foreground: "#f2f7f8",
      cursor: "#f2f7f8",
      cursorAccent: "#141b1e",
      selectionBackground: "rgba(242,247,248,0.22)",
      selectionInactiveBackground: "rgba(242,247,248,0.22)",
    };
  }

  function termOptions() {
    return {
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
      fontSize: currentFont(),
      cursorBlink: false,
      scrollback: 10000,
      allowTransparency: true,
      convertEol: false,
      theme: termTheme(),
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

  function announce(text) {
    announcer.textContent = "";
    requestAnimationFrame(() => {
      announcer.textContent = text;
    });
  }

  function showGate(message) {
    gate.hidden = false;
    desk.hidden = true;
    setNote(message || "");
    document.title = "Aether";
  }

  function showDesk() {
    gate.hidden = true;
    desk.hidden = false;
    paintNotify();
    queueFit();
  }

  function cssEscape(value) {
    if (window.CSS && typeof CSS.escape === "function") return CSS.escape(value);
    return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  function libraryReady() {
    const lib = window.AetherXterm;
    return !!(lib && typeof lib.Terminal === "function" && typeof lib.FitAddon === "function");
  }

  // Links: the bundle has no web-links addon, so URLs are found here. Wrapped
  // rows are joined first so a long URL that spills onto the next row works.
  function trimURL(text) {
    let url = text.replace(/[.,;:!?'"]+$/, "");
    const pairs = { ")": "(", "]": "[", "}": "{" };
    for (;;) {
      const last = url[url.length - 1];
      if (!pairs[last]) break;
      const open = url.split(pairs[last]).length - 1;
      const close = url.split(last).length - 1;
      if (close <= open) break;
      url = url.slice(0, -1).replace(/[.,;:!?'"]+$/, "");
    }
    return url;
  }

  function openURL(url) {
    if (!/^https?:\/\//i.test(url)) return;
    const win = window.open(url, "_blank", "noopener,noreferrer");
    if (win) win.opener = null;
  }

  function linkProvider(term) {
    return {
      provideLinks(y, callback) {
        const buffer = term.buffer.active;
        let start = y - 1;
        while (start > 0) {
          const line = buffer.getLine(start);
          if (!line || !line.isWrapped) break;
          start -= 1;
        }
        let text = "";
        const cells = [];
        let row = start;
        const cell = buffer.getNullCell ? buffer.getNullCell() : undefined;
        for (;;) {
          const line = buffer.getLine(row);
          if (!line || (row !== start && !line.isWrapped)) break;
          for (let x = 0; x < line.length; x += 1) {
            const c = line.getCell(x, cell);
            if (!c || c.getWidth() === 0) continue;
            const chars = c.getChars() || " ";
            for (let i = 0; i < chars.length; i += 1) {
              text += chars[i];
              cells.push({ x: x + 1, y: row + 1, w: c.getWidth() });
            }
          }
          row += 1;
          if (row - start > 64) break;
        }
        const links = [];
        URL_PATTERN.lastIndex = 0;
        let match;
        while ((match = URL_PATTERN.exec(text))) {
          const url = trimURL(match[0]);
          if (url.length < 10) continue;
          const first = cells[match.index];
          const last = cells[match.index + url.length - 1];
          if (!first || !last || last.y < y || first.y > y) continue;
          links.push({
            text: url,
            range: { start: { x: first.x, y: first.y }, end: { x: last.x + last.w - 1, y: last.y } },
            decorations: { underline: true, pointerCursor: true },
            activate(event, linkText) {
              openURL(linkText);
            },
          });
        }
        callback(links.length ? links : undefined);
      },
    };
  }

  function openTerm(host) {
    const term = new window.AetherXterm.Terminal(termOptions());
    const fit = new window.AetherXterm.FitAddon();
    term.loadAddon(fit);
    term.open(host);
    if (typeof term.registerLinkProvider === "function") term.registerLinkProvider(linkProvider(term));
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
    stage.insertBefore(host, ended);
    const opened = openTerm(host);
    const term = opened.term;
    term.onData((data) => {
      if (visibleId !== id) return;
      sendInput(id, ctrlSticky || altSticky ? takeMods(data) : data);
    });
    session = {
      id,
      title: title || "Terminal",
      cwd: "",
      state: "idle",
      known: false,
      workingSince: 0,
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
    const session = sessions.get(id);
    if (session && session.exited) return;
    const bytes = new TextEncoder().encode(text);
    if (ready && send({ type: "input", id, data: bytesToBase64(bytes) })) return;
    // Hold keystrokes while the link is down and send them once it is back.
    if (queuedBytes + bytes.length > QUEUE_LIMIT) {
      queueFull = true;
      paintOffline();
      return;
    }
    queuedBytes += bytes.length;
    queuedInput.push({ id, bytes });
    paintOffline();
  }

  function flushInput() {
    const items = queuedInput.splice(0);
    queuedBytes = 0;
    queueFull = false;
    for (const item of items) {
      const session = sessions.get(item.id);
      if (!session || session.exited) continue;
      send({ type: "input", id: item.id, data: bytesToBase64(item.bytes) });
    }
  }

  function paintOffline() {
    const down = !desk.hidden && !ready && !!localStorage.getItem(TOKEN_KEY);
    offline.hidden = !down;
    if (!down) return;
    let text = attempt === 0 ? "Connecting…" : "Reconnecting…";
    if (queueFull) text += " Typing is paused until the connection is back.";
    else if (queuedBytes) text += " What you type will be sent when it's back.";
    offlineText.textContent = text;
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
    if (selecting && visibleId !== String(id)) leaveSelect();
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

  function openSession(id) {
    const session = sessions.get(id);
    if (!session) return;
    if (session.attached || session.exited) show(id);
    else attach(id, true);
  }

  function createSession(replace) {
    if (!ready) {
      setNote("Reconnecting");
      return;
    }
    const size = fittedSize();
    const cols = Math.max(80, size.cols | 0 || 80);
    const rows = Math.max(24, size.rows | 0 || 24);
    pendingCreates.push({ cols, rows, replace: replace || "" });
    send({ type: "create", cols, rows, cwd: "", command: "" });
  }

  // removeLocal forgets a terminal that has already ended on the server.
  function removeLocal(id, pickNext) {
    const session = sessions.get(id);
    if (!session) return;
    try { session.term.dispose(); } catch (err) { /* already gone */ }
    session.host.remove();
    sessions.delete(id);
    buffers.delete(id);
    locallyClosed.delete(id);
    closing.delete(id);
    forgotten.add(id);
    order = order.filter((item) => item !== id);
    if (visibleId !== id) {
      renderRail();
      return;
    }
    visibleId = null;
    if (selecting) leaveSelect();
    if (pickNext === false) return;
    const next = order.find((item) => {
      const other = sessions.get(item);
      return other && !other.exited;
    }) || order[0];
    if (next) openSession(next);
    else renderRail();
  }

  function focusSurface() {
    if (desk.hidden || selecting) return;
    const session = visibleId && sessions.get(visibleId);
    if (!session || session.exited) return;
    if (touchInput()) {
      keysink.focus({ preventScroll: true });
      return;
    }
    session.term.focus();
  }

  function stateOf(session) {
    return session.exited ? "exited" : (STATE_WORDS[session.state] ? session.state : "idle");
  }

  function renderRail() {
    const seen = new Set();
    let previous = null;
    let index = 0;
    for (const id of order) {
      const session = sessions.get(id);
      if (!session) continue;
      index += 1;
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
        const dot = document.createElement("span");
        dot.className = "dot";
        dot.setAttribute("aria-hidden", "true");
        const text = document.createElement("span");
        text.className = "row-text";
        const title = document.createElement("span");
        title.className = "row-title";
        const state = document.createElement("span");
        state.className = "row-state";
        text.append(title, state);
        open.append(dot, text);
        const close = document.createElement("button");
        close.type = "button";
        close.className = "row-close";
        close.textContent = "×";
        open.addEventListener("click", () => openSession(id));
        close.addEventListener("click", (event) => {
          event.stopPropagation();
          closeSession(id);
        });
        row.append(open, close);
        sessionsEl.appendChild(row);
      }
      const word = stateOf(session);
      const name = session.title || "Terminal";
      row.dataset.state = word;
      row.querySelector(".row-title").textContent = name;
      row.querySelector(".row-state").textContent = STATE_WORDS[word];
      const open = row.querySelector(".row-open");
      const hint = session.msg || session.cwd || "";
      open.title = (hint ? hint + " · " : "") + (index <= 9 ? "Alt+" + index : "");
      if (id === visibleId) open.setAttribute("aria-current", "true");
      else open.removeAttribute("aria-current");
      row.querySelector(".row-close").setAttribute("aria-label", (session.exited ? "Remove " : "Close ") + name);
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
    paintTitle();
    paintStage();
  }

  function closeSession(id) {
    const current = sessions.get(id);
    if (!current) return;
    if (current.exited) {
      removeLocal(id);
      return;
    }
    const busy = current.state === "working" || current.state === "blocked";
    if (busy && !window.confirm("“" + (current.title || "Terminal") + "” is still working. Close it anyway?")) return;
    closing.add(id);
    send({ type: "close", id });
  }

  function paintTitle() {
    let blocked = 0;
    for (const session of sessions.values()) {
      if (!session.exited && session.state === "blocked") blocked += 1;
    }
    const title = blocked ? "● Needs you · Aether" : "Aether";
    if (document.title !== title) document.title = title;
  }

  function paintStage() {
    const session = visibleId && sessions.get(visibleId);
    if (session && session.exited) {
      endedText.textContent = "“" + (session.title || "Terminal") + "” has exited.";
      restartButton.textContent = "Start again";
      removeButton.hidden = false;
      ended.hidden = false;
      return;
    }
    if (!session && booted && ready && !pendingCreates.length) {
      endedText.textContent = "No terminals are open.";
      restartButton.textContent = "New terminal";
      removeButton.hidden = true;
      ended.hidden = false;
      return;
    }
    ended.hidden = true;
  }

  // setState records a state change and tells the person about the ones that
  // need them: a screen-reader announcement always, a notification when the
  // page is in the background.
  function setState(session, state, msg) {
    if (typeof msg === "string") session.msg = msg;
    if (typeof state !== "string" || !state) return;
    const before = session.state;
    session.state = state;
    if (!session.known) {
      session.known = true;
      if (state === "working") session.workingSince = Date.now();
      return;
    }
    if (before === state) return;
    const ranFor = session.workingSince ? Date.now() - session.workingSince : 0;
    session.workingSince = state === "working" ? Date.now() : 0;
    const name = session.title || "Terminal";
    const exiting = state === "done" && session.msg === "exited";
    if (state === "blocked" || state === "error" || (state === "done" && !exiting)) {
      announce(name + ": " + STATE_WORDS[state] + (session.msg ? ". " + session.msg : ""));
    }
    if (state === "blocked" || state === "error" || (state === "done" && !exiting && ranFor >= LONG_RUN)) {
      notify(session, state);
    }
  }

  function notifyAllowed() {
    return "Notification" in window && window.isSecureContext && Notification.permission === "granted";
  }

  function notify(session, state) {
    if (!notifyAllowed() || document.visibilityState === "visible") return;
    const name = session.title || "Terminal";
    const heads = { blocked: name + " needs you", error: name + " hit an error", done: name + " is done" };
    try {
      const note = new Notification(heads[state] || name, {
        body: session.msg || "",
        tag: "aether-" + session.id,
        icon: "icon-192.png",
      });
      note.onclick = () => {
        window.focus();
        if (sessions.has(session.id)) openSession(session.id);
        note.close();
      };
    } catch (err) {
      /* Some browsers only allow notifications from a service worker. */
    }
  }

  function paintNotify() {
    const can = "Notification" in window && window.isSecureContext;
    notifyButton.hidden = !can || Notification.permission !== "default";
  }

  function syncSessions(items) {
    const listed = [];
    const seen = new Set();
    for (const item of items) {
      if (!item || item.id == null) continue;
      const id = String(item.id);
      if (forgotten.has(id)) continue;
      seen.add(id);
      listed.push(id);
      const session = ensureSession(id, item.title);
      session.title = item.title || session.title || "Terminal";
      session.cwd = item.cwd || "";
      if (locallyClosed.has(id)) {
        session.exited = true;
        session.attached = false;
        session.state = "exited";
      } else {
        session.exited = false;
        setState(session, item.state || "idle", typeof item.msg === "string" ? item.msg : "");
      }
    }
    // The server lists terminals in no particular order, so the rail keeps
    // the order it already has and adds new ones at the end.
    const next = [];
    for (const id of order) {
      const session = sessions.get(id);
      if (!session) continue;
      next.push(id);
      if (seen.has(id)) continue;
      session.exited = true;
      session.attached = false;
      session.state = "exited";
    }
    for (const id of listed) {
      if (!next.includes(id)) next.push(id);
    }
    order = next;
  }

  function onSessions(items) {
    const list = Array.isArray(items) ? items : [];
    syncSessions(list);
    if (!booted) {
      booted = true;
      if (!visibleId) {
        const first = list.find((item) => item && item.id != null && !forgotten.has(String(item.id)));
        if (first) attach(first.id, true);
        else createSession();
      }
    } else if (!visibleId && list.length) {
      const live = list.find((item) => item && item.id != null && !locallyClosed.has(String(item.id)) && !forgotten.has(String(item.id)));
      if (live) attach(live.id, true);
    }
    renderRail();
  }

  function onCreated(msg) {
    const id = String(msg.id);
    const session = ensureSession(id, msg.title);
    session.attached = true;
    session.exited = false;
    session.known = true;
    locallyClosed.delete(id);
    session.title = msg.title || session.title || "Terminal";
    session.state = session.state || "idle";
    const pending = pendingCreates.shift();
    if (pending) {
      session.sentCols = pending.cols;
      session.sentRows = pending.rows;
    }
    const replace = pending && pending.replace;
    if (replace && sessions.has(replace) && order.includes(replace)) {
      order.splice(order.indexOf(replace), 0, id);
      removeLocal(replace, false);
    } else {
      remember(id);
    }
    const queued = buffers.get(id);
    buffers.delete(id);
    show(id);
    if (queued) {
      if (queued.trimmed) session.term.write(TRIMMED_NOTE);
      for (const chunk of queued.chunks) session.term.write(chunk);
    }
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
    setState(session, msg.state, msg.msg);
    remember(id);
    if (!visibleId || visibleId === id) show(id);
    else renderRail();
  }

  // bufferOutput holds output for a terminal this page hasn't heard of yet,
  // keeping the newest BUFFER_LIMIT bytes.
  function bufferOutput(id, bytes) {
    let entry = buffers.get(id);
    if (!entry) {
      entry = { chunks: [], bytes: 0, trimmed: false };
      buffers.set(id, entry);
    }
    if (bytes.length > BUFFER_LIMIT) {
      bytes = bytes.subarray(bytes.length - BUFFER_LIMIT);
      entry.trimmed = true;
    }
    entry.chunks.push(bytes);
    entry.bytes += bytes.length;
    while (entry.bytes > BUFFER_LIMIT && entry.chunks.length > 1) {
      entry.bytes -= entry.chunks.shift().length;
      entry.trimmed = true;
    }
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
      if (!forgotten.has(id)) bufferOutput(id, bytes);
      return;
    }
    session.term.write(bytes);
  }

  function onStatus(msg) {
    const session = sessions.get(String(msg.id));
    if (!session || session.exited) return;
    setState(session, msg.state, msg.msg);
    renderRail();
  }

  function onClosed(id) {
    const session = sessions.get(String(id));
    if (!session) return;
    if (closing.has(session.id)) {
      removeLocal(session.id);
      return;
    }
    const wasLive = !session.exited;
    session.exited = true;
    session.attached = false;
    session.state = "exited";
    locallyClosed.add(session.id);
    if (wasLive) announce((session.title || "Terminal") + " has exited");
    if (session.id === visibleId) {
      if (selecting) leaveSelect();
      if (document.activeElement === keysink) keysink.blur();
    }
    renderRail();
  }

  function onHello() {
    ready = true;
    attempt = 0;
    setLink("");
    setNote("");
    paintOffline();
    send({ type: "list" });
    if (visibleId) {
      const session = sessions.get(visibleId);
      if (session && !session.exited) {
        session.attached = false;
        attach(visibleId, true);
      }
    }
    flushInput();
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
    if (msg.type === "pong") {
      clearTimeout(pongTimer);
      pongTimer = 0;
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
    closing.clear();
    forgotten.clear();
    order = [];
    visibleId = null;
    booted = false;
    ready = false;
    attempt = 0;
    pendingCreates.length = 0;
    queuedInput.length = 0;
    queuedBytes = 0;
    queueFull = false;
    clearMods();
    if (selecting) leaveSelect();
    if (probe) {
      try { probe.term.dispose(); } catch (err) { /* already gone */ }
      probe.host.remove();
      probe = null;
    }
    sessionsEl.replaceChildren();
    pairPanel.hidden = true;
    ended.hidden = true;
  }

  function signOut(message) {
    generation += 1;
    clearTimeout(reconnectTimer);
    stopHeartbeat();
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
    paintOffline();
  }

  function stopHeartbeat() {
    clearInterval(pingTimer);
    clearTimeout(pongTimer);
    pingTimer = 0;
    pongTimer = 0;
  }

  // ping asks the server for a pong; a socket that stays quiet is treated as
  // dead even if the browser still thinks it is open, which is what happens
  // after sleep or a network change.
  function ping() {
    if (!ready || pongTimer) return;
    if (!send({ type: "ping" })) return;
    const ws = socket;
    pongTimer = setTimeout(() => {
      pongTimer = 0;
      if (ws && socket === ws) drop(ws);
    }, PONG_WAIT);
  }

  // heartbeat also refreshes the list, which is the only way to hear about
  // terminals this page isn't attached to.
  function heartbeat() {
    ping();
    if (ready) send({ type: "list" });
  }

  function drop(ws) {
    if (socket !== ws) return;
    ws.onopen = null;
    ws.onmessage = null;
    ws.onerror = null;
    ws.onclose = null;
    try { ws.close(); } catch (err) { /* already closed */ }
    lost(ws, generation);
  }

  function lost(ws, gen) {
    if (gen !== generation) return;
    if (socket === ws) socket = null;
    stopHeartbeat();
    ready = false;
    pendingCreates.length = 0;
    for (const session of sessions.values()) session.attached = false;
    const delay = BACKOFF[Math.min(attempt, BACKOFF.length - 1)];
    attempt += 1;
    setLink("Reconnecting");
    paintOffline();
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => {
      if (gen !== generation) return;
      connect();
    }, delay);
  }

  // reconnectNow skips the backoff when the page comes back into view or the
  // network returns, and checks that an open socket is really alive.
  function reconnectNow() {
    if (!localStorage.getItem(TOKEN_KEY) || desk.hidden) return;
    if (socket && socket.readyState === WebSocket.OPEN && ready) {
      ping();
      return;
    }
    if (socket && socket.readyState === WebSocket.CONNECTING) return;
    clearTimeout(reconnectTimer);
    connect();
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
    paintOffline();
    const helloTimer = setTimeout(() => {
      if (gen !== generation || ready) return;
      drop(ws);
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
      if (msg && msg.type === "helloOk") {
        clearTimeout(helloTimer);
        stopHeartbeat();
        pingTimer = setInterval(heartbeat, PING_EVERY);
      }
      handleMessage(msg);
    };
    ws.onerror = () => {
      try { ws.close(); } catch (err) { /* already closed */ }
    };
    ws.onclose = () => {
      clearTimeout(helloTimer);
      lost(ws, gen);
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
    const size = currentFont();
    if (size === appliedFont) return false;
    appliedFont = size;
    for (const session of sessions.values()) session.term.options.fontSize = size;
    if (probe) probe.term.options.fontSize = size;
    selectText.style.fontSize = size + "px";
    return true;
  }

  function applyTheme() {
    const theme = termTheme();
    for (const session of sessions.values()) session.term.options.theme = theme;
    if (probe) probe.term.options.theme = theme;
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
    if (ch === " " || ch === "2") return "\x00";
    if (ch === "?" || ch === "8") return "\x7f";
    if (ch === "/") return "\x1f";
    const code = ch.toUpperCase().charCodeAt(0);
    if (code >= 64 && code <= 95) return String.fromCharCode(code - 64);
    return "";
  }

  // withMods applies the sticky Ctrl and Alt keys the way xterm encodes them:
  // a control byte or ESC prefix for characters, a modifier parameter for
  // cursor and paging keys.
  function withMods(seq, ctrl, alt) {
    if (!ctrl && !alt) return seq;
    const param = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    let match = /^\x1b\[([A-DHF])$/.exec(seq);
    if (match) return "\x1b[1;" + param + match[1];
    match = /^\x1b\[(\d+)~$/.exec(seq);
    if (match) return "\x1b[" + match[1] + ";" + param + "~";
    const chars = Array.from(seq);
    let head = chars[0] || "";
    if (ctrl) head = controlByte(head) || head;
    if (alt) head = "\x1b" + head;
    return head + chars.slice(1).join("");
  }

  function paintMods() {
    ctrlKey.setAttribute("aria-pressed", ctrlSticky ? "true" : "false");
    altKey.setAttribute("aria-pressed", altSticky ? "true" : "false");
  }

  function clearMods() {
    if (!ctrlSticky && !altSticky) return;
    ctrlSticky = false;
    altSticky = false;
    paintMods();
  }

  function takeMods(text) {
    if (!ctrlSticky && !altSticky) return text;
    const out = withMods(text, ctrlSticky, altSticky);
    clearMods();
    return out;
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
    if (event.ctrlKey && !event.metaKey && !event.altKey && event.key.length === 1) {
      const byte = controlByte(event.key);
      if (byte) {
        event.preventDefault();
        clearMods();
        emitSink(byte);
      }
      return;
    }
    if ((ctrlSticky || altSticky) && event.key.length === 1 && !event.altKey && !event.metaKey) {
      event.preventDefault();
      emitSink(takeMods(event.key));
      return;
    }
    const special = {
      Escape: "\x1b",
      Tab: "\t",
      ArrowUp: "\x1b[A",
      ArrowDown: "\x1b[B",
      ArrowRight: "\x1b[C",
      ArrowLeft: "\x1b[D",
      Home: "\x1b[H",
      End: "\x1b[F",
      PageUp: "\x1b[5~",
      PageDown: "\x1b[6~",
      Delete: "\x1b[3~",
    };
    if (Object.prototype.hasOwnProperty.call(special, event.key)) {
      event.preventDefault();
      emitSink(takeMods(special[event.key]));
      return;
    }
    if (event.key === "Backspace") {
      event.preventDefault();
      emitSink(takeMods("\x7f"));
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      clearMods();
      emitSink("\r");
    }
  }

  function onSinkBefore(event) {
    if (composing || event.isComposing) return;
    if (sinkSent) {
      event.preventDefault();
      return;
    }
    const type = event.inputType;
    if ((type === "insertText" || type === "insertReplacementText") && event.data) {
      event.preventDefault();
      emitSink(takeMods(event.data));
      return;
    }
    if (type === "insertFromPaste" && event.data) {
      event.preventDefault();
      clearMods();
      pasteText(event.data);
      keysink.value = "";
      return;
    }
    if (type === "deleteContentBackward") {
      event.preventDefault();
      emitSink(takeMods("\x7f"));
      return;
    }
    if (type === "insertLineBreak" || type === "insertParagraph") {
      event.preventDefault();
      clearMods();
      emitSink("\r");
    }
  }

  // pasteText goes through xterm so bracketed paste is honoured.
  function pasteText(text) {
    const session = visibleId && sessions.get(visibleId);
    if (!session || session.exited || !text) return;
    session.term.paste(text);
  }

  async function pasteFromClipboard() {
    clearMods();
    if (!navigator.clipboard || typeof navigator.clipboard.readText !== "function") {
      setNote("This browser doesn't let pages read the clipboard. Use your keyboard's paste instead.");
      return;
    }
    try {
      const text = await navigator.clipboard.readText();
      if (text) pasteText(text);
      else setNote("The clipboard is empty.");
    } catch (err) {
      setNote("Paste wasn't allowed. Use your keyboard's paste instead.");
    }
    focusSurface();
  }

  // Selecting: xterm can't select text with touch, so the visible terminal's
  // text is copied into a plain, natively selectable sheet with live links.
  function bufferText(term) {
    const buffer = term.buffer.active;
    const parts = [];
    for (let y = 0; y < buffer.length; y += 1) {
      const line = buffer.getLine(y);
      if (!line) continue;
      const next = buffer.getLine(y + 1);
      parts.push(line.translateToString(!(next && next.isWrapped)));
      if (!(next && next.isWrapped)) parts.push("\n");
    }
    return parts.join("").replace(/\n+$/, "\n");
  }

  function fillSheet(text) {
    const out = document.createDocumentFragment();
    let at = 0;
    URL_PATTERN.lastIndex = 0;
    let match;
    while ((match = URL_PATTERN.exec(text))) {
      const url = trimURL(match[0]);
      if (url.length < 10) continue;
      if (match.index > at) out.appendChild(document.createTextNode(text.slice(at, match.index)));
      const link = document.createElement("a");
      link.href = url;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = url;
      out.appendChild(link);
      at = match.index + url.length;
      URL_PATTERN.lastIndex = at;
    }
    if (at < text.length) out.appendChild(document.createTextNode(text.slice(at)));
    selectText.replaceChildren(out);
  }

  function enterSelect() {
    const session = visibleId && sessions.get(visibleId);
    if (!session || selecting) return;
    selecting = true;
    if (document.activeElement === keysink) keysink.blur();
    session.term.blur();
    const buffer = session.term.buffer.active;
    fillSheet(bufferText(session.term));
    selectText.style.fontSize = currentFont() + "px";
    selectSheet.hidden = false;
    selectKey.setAttribute("aria-pressed", "true");
    const reach = Math.max(1, buffer.baseY);
    const share = buffer.viewportY / reach;
    selectText.scrollTop = share * Math.max(0, selectText.scrollHeight - selectText.clientHeight);
    selectText.focus({ preventScroll: true });
  }

  function leaveSelect() {
    if (!selecting) return;
    selecting = false;
    selectSheet.hidden = true;
    selectText.replaceChildren();
    selectKey.setAttribute("aria-pressed", "false");
    const selection = window.getSelection && window.getSelection();
    if (selection) selection.removeAllRanges();
  }

  function stripPair() {
    const url = new URL(location.href);
    if (!url.searchParams.has("pair")) return;
    url.searchParams.delete("pair");
    history.replaceState(null, "", url.pathname + url.search + url.hash);
  }

  // formatCode tidies a typed or pasted code into ABCD-EFGH, and accepts a
  // whole pairing link too.
  function formatCode(value) {
    let raw = String(value || "");
    const fromLink = /[?&]pair=([^&#\s]+)/.exec(raw);
    if (fromLink) {
      try { raw = decodeURIComponent(fromLink[1]); } catch (err) { raw = fromLink[1]; }
    }
    const clean = raw.toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (clean.length > 8) return raw.trim().toUpperCase();
    return clean.length > 4 ? clean.slice(0, 4) + "-" + clean.slice(4) : clean;
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
    if (localStorage.getItem(TOKEN_KEY) && !window.confirm("This will replace the account on this device. Its terminals can only be reached again with a code from another device that is still signed in.")) {
      return Promise.resolve();
    }
    return runAction(claimForm.querySelector("button[type=submit]"), async () => {
      setNote("Checking the code");
      const data = await postJSON("/claim", { code });
      leaveCurrent();
      storeToken(data);
      stripPair();
      pairKeep.hidden = true;
      enrollForm.hidden = false;
      codeInput.value = "";
      setNote("");
      connect();
    });
  }

  // leaveCurrent drops the live connection before another account moves in.
  function leaveCurrent() {
    if (!socket && !sessions.size) return;
    generation += 1;
    clearTimeout(reconnectTimer);
    stopHeartbeat();
    const ws = socket;
    socket = null;
    if (ws) {
      ws.onopen = null;
      ws.onclose = null;
      ws.onmessage = null;
      ws.onerror = null;
      try { ws.close(); } catch (err) { /* already closed */ }
    }
    wipe();
  }

  // offerPair fills in a code from a ?pair= link but waits for a click, so a
  // link alone can never sign this device in or swap out its account.
  function offerPair(code) {
    codeInput.value = formatCode(code);
    const signedIn = !!localStorage.getItem(TOKEN_KEY);
    pairKeep.hidden = !signedIn;
    enrollForm.hidden = signedIn;
    showGate(signedIn
      ? "A link wants to sign this device in to another account. Using it will replace the account on this device."
      : "Press Use a code to sign in with this link.");
    claimForm.querySelector("button[type=submit]").focus();
  }

  function keybarWanted() {
    return localStorage.getItem(KEYS_KEY) === "on";
  }

  function paintKeysToggle() {
    const on = keybarWanted();
    desk.classList.toggle("keys-on", on);
    keysToggle.setAttribute("aria-pressed", on ? "true" : "false");
    keysToggle.textContent = on ? "Hide keys" : "Show keys";
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
    const code = formatCode(codeInput.value);
    if (!code) {
      setNote("Enter a code");
      codeInput.focus();
      return;
    }
    claim(code);
  });

  codeInput.addEventListener("input", (event) => {
    if (event.isComposing) return;
    const atEnd = codeInput.selectionStart === codeInput.value.length;
    const next = formatCode(codeInput.value);
    if (atEnd && next !== codeInput.value) codeInput.value = next;
  });

  newButton.addEventListener("click", () => createSession());

  restartButton.addEventListener("click", () => {
    const session = visibleId && sessions.get(visibleId);
    createSession(session && session.exited ? session.id : "");
  });

  removeButton.addEventListener("click", () => {
    if (visibleId) removeLocal(visibleId);
  });

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

  notifyButton.addEventListener("click", async () => {
    if (!("Notification" in window)) return;
    try {
      const answer = await Notification.requestPermission();
      if (answer === "granted") setNote("You'll get a notification when a terminal needs you.");
      else if (answer === "denied") setNote("Notifications are blocked. You can allow them in your browser's site settings.");
    } catch (err) {
      setNote("This browser can't show notifications here.");
    }
    paintNotify();
  });

  keysToggle.addEventListener("click", () => {
    localStorage.setItem(KEYS_KEY, keybarWanted() ? "off" : "on");
    paintKeysToggle();
    queueFit();
  });

  signOutButton.addEventListener("click", () => {
    if (!window.confirm("Sign out on this device? Your terminals keep running, but you'll need a code from another signed-in device to get back to them.")) return;
    signOut("");
  });

  pairKeep.addEventListener("click", () => {
    stripPair();
    pairKeep.hidden = true;
    enrollForm.hidden = false;
    codeInput.value = "";
    setNote("");
    connect();
  });

  retryButton.addEventListener("click", () => {
    if (socket && !ready) drop(socket);
    attempt = 0;
    clearTimeout(reconnectTimer);
    connect();
    focusSurface();
  });

  selectDone.addEventListener("click", () => {
    leaveSelect();
    focusSurface();
  });

  selectCopy.addEventListener("click", async () => {
    const text = selectText.textContent || "";
    try {
      await navigator.clipboard.writeText(text);
      selectCopy.textContent = "Copied";
      setTimeout(() => {
        selectCopy.textContent = "Copy all";
      }, 1600);
    } catch (err) {
      const range = document.createRange();
      range.selectNodeContents(selectText);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
  });

  selectSheet.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      leaveSelect();
      focusSurface();
    }
  });

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") reconnectNow();
  });
  window.addEventListener("online", reconnectNow);
  window.addEventListener("pageshow", (event) => {
    if (event.persisted) reconnectNow();
  });

  // Alt+1…9 picks a terminal and Alt+T opens one. event.code is used because
  // Option on a Mac turns the key into a different character.
  document.addEventListener("keydown", (event) => {
    if (desk.hidden || !event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    const code = event.code || "";
    const digit = /^Digit([1-9])$/.exec(code);
    if (digit) {
      const id = order[Number(digit[1]) - 1];
      if (!id) return;
      event.preventDefault();
      event.stopPropagation();
      openSession(id);
      return;
    }
    if (code === "KeyT") {
      event.preventDefault();
      event.stopPropagation();
      createSession();
    }
  }, true);

  keybar.addEventListener("pointerdown", (event) => {
    if (event.target.closest("button")) event.preventDefault();
  });

  keybar.addEventListener("click", (event) => {
    const button = event.target.closest("button");
    if (!button) return;
    const name = button.dataset.key;
    if (name === "ctrl") {
      ctrlSticky = !ctrlSticky;
      paintMods();
      focusSurface();
      return;
    }
    if (name === "alt") {
      altSticky = !altSticky;
      paintMods();
      focusSurface();
      return;
    }
    if (name === "paste") {
      pasteFromClipboard();
      return;
    }
    if (name === "select") {
      if (selecting) {
        leaveSelect();
        focusSurface();
      } else {
        enterSelect();
      }
      return;
    }
    if (name === "font-down" || name === "font-up") {
      const size = setFontSize(currentFont() + (name === "font-up" ? 1 : -1));
      announce("Text size " + size);
      focusSurface();
      return;
    }
    if (Object.prototype.hasOwnProperty.call(RAW_KEYS, name)) {
      clearMods();
      sendInput(visibleId, RAW_KEYS[name]);
      focusSurface();
      return;
    }
    if (!Object.prototype.hasOwnProperty.call(KEYS, name)) return;
    sendInput(visibleId, takeMods(KEYS[name]));
    focusSurface();
  });

  keysink.addEventListener("keydown", onSinkKey);
  keysink.addEventListener("beforeinput", onSinkBefore);
  keysink.addEventListener("input", () => {
    if (sinkSent) {
      keysink.value = "";
      return;
    }
    if (keysink.value) emitSink(takeMods(keysink.value));
  });
  keysink.addEventListener("compositionstart", () => {
    composing = true;
  });
  keysink.addEventListener("compositionend", (event) => {
    composing = false;
    if (event.data) sendInput(visibleId, event.data);
    keysink.value = "";
    sinkSent = true;
    queueMicrotask(() => {
      sinkSent = false;
    });
  });
  keysink.addEventListener("focus", stopScroll);

  // Touch on the terminal: a tap brings up the keyboard, a drag scrolls, a
  // long press opens the select sheet and a pinch changes the text size.
  const touch = { timer: 0, x: 0, y: 0, moved: false, pressed: false, pinch: 0, pinchFont: 0 };

  function inTerminal(node) {
    return !!(node && node.closest && node.closest(".term-host"));
  }

  function pinchDistance(list) {
    const a = list[0];
    const b = list[1];
    return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
  }

  stage.addEventListener("pointerdown", (event) => {
    if (event.pointerType !== "touch" && inTerminal(event.target)) focusSurface();
  });

  stage.addEventListener("touchstart", (event) => {
    clearTimeout(touch.timer);
    if (event.touches.length === 2) {
      touch.pinch = pinchDistance(event.touches);
      touch.pinchFont = currentFont();
      touch.moved = true;
      return;
    }
    if (event.touches.length !== 1 || !inTerminal(event.target)) return;
    const point = event.touches[0];
    touch.x = point.clientX;
    touch.y = point.clientY;
    touch.moved = false;
    touch.pressed = false;
    touch.pinch = 0;
    touch.timer = setTimeout(() => {
      if (touch.moved) return;
      touch.pressed = true;
      if (navigator.vibrate) navigator.vibrate(10);
      enterSelect();
    }, LONG_PRESS);
  }, { passive: true });

  stage.addEventListener("touchmove", (event) => {
    if (touch.pinch && event.touches.length === 2) {
      event.preventDefault();
      const scale = pinchDistance(event.touches) / touch.pinch;
      const size = Math.max(FONT_MIN, Math.min(FONT_MAX, Math.round(touch.pinchFont * scale)));
      if (size !== currentFont()) setFontSize(size, false);
      return;
    }
    if (event.touches.length !== 1) return;
    const point = event.touches[0];
    if (Math.abs(point.clientX - touch.x) > 10 || Math.abs(point.clientY - touch.y) > 10) {
      touch.moved = true;
      clearTimeout(touch.timer);
    }
  }, { passive: false });

  function endTouch(event) {
    clearTimeout(touch.timer);
    // Lifting after a long press must not click whatever the sheet put there.
    if (touch.pressed && event.cancelable) event.preventDefault();
    // The keyboard only opens when focus moves inside the touch itself.
    if (event.type === "touchend" && event.touches.length === 0 && !touch.moved && !touch.pressed && !touch.pinch && inTerminal(event.target)) {
      focusSurface();
    }
    if (touch.pinch && event.touches.length < 2) {
      if (fontOverride) {
        const size = fontOverride;
        fontOverride = 0;
        setFontSize(size);
      }
      // Keep pinch set until the last finger lifts so pointerup doesn't
      // treat it as a tap.
      if (event.touches.length === 0) setTimeout(() => { touch.pinch = 0; }, 0);
    }
  }

  stage.addEventListener("touchend", endTouch);
  stage.addEventListener("touchcancel", endTouch);
  stage.addEventListener("gesturestart", (event) => event.preventDefault());
  stage.addEventListener("contextmenu", (event) => {
    if (touchInput() && inTerminal(event.target)) event.preventDefault();
  });

  stage.addEventListener("focusin", (event) => {
    if (!touchInput()) return;
    const target = event.target;
    if (target && target.classList && target.classList.contains("xterm-helper-textarea")) {
      if (selecting) target.blur();
      else keysink.focus({ preventScroll: true });
    }
  });

  document.addEventListener("touchmove", (event) => {
    const node = event.target;
    if (node && node.closest && node.closest(".sessions, .rail, .xterm-viewport, .keybar, .select-text, .gate, input, textarea")) return;
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
  lightQuery.addEventListener("change", applyTheme);
  new ResizeObserver(() => queueFit()).observe(stage);

  if (!libraryReady()) {
    setNote("The terminal did not load.");
  }

  paintKeysToggle();
  paintNotify();
  layoutChrome();
  const pair = new URLSearchParams(location.search).get("pair");
  if (pair && pair.trim()) offerPair(pair.trim());
  else if (localStorage.getItem(TOKEN_KEY)) connect();
  else showGate("");
})();
