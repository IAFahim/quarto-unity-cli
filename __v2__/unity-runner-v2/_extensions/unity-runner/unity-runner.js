(function () {
  "use strict";

  var BRIDGE_URL = "ws://localhost:7890";
  var PROTOCOL_VERSION = 2;
  var RECONNECT_BASE_MS = 1500;
  var RECONNECT_CAP_MS = 10000;
  var CONNECT_TIMEOUT_MS = 4000;
  var PING_INTERVAL_MS = 20000;


  /* ═══ State ═══════════════════════════════════════════ */

  var ws = null;
  var connected = false;
  var reconnectDelay = RECONNECT_BASE_MS;
  var reconnectTimer = null;
  var connectTimer = null;
  var pingTimer = null;
  var pingSeq = 0;

  var blocks = {};
  var elapsedTimers = {};
  var nameToId = {};
  var setupCache = {};

  var queue = [];
  var queueActive = false;
  var queueCurrentId = null;


  /* ═══ Block State Machine ═════════════════════════════ */
  /*  idle → pending → running → done | failed            */
  /*  setup blocks: done → cached (on re-run, skip)       */

  function initBlockState(el) {
    var id = el.id;
    blocks[id] = {
      state: "idle",
      output: "",
      exitCode: null,
      elapsed: null,
      folded: false,
    };
  }

  function transitionBlock(id, nextState) {
    var b = blocks[id];
    if (!b) return;
    b.state = nextState;
    renderBlockState(id, nextState);
  }


  /* ═══ Name Registry ═══════════════════════════════════ */

  function loadRegistry() {
    var el = document.getElementById("ur-block-registry");
    if (!el) return;
    try { nameToId = JSON.parse(el.textContent); } catch (e) { nameToId = {}; }
  }

  function resolveId(nameOrId) {
    return nameToId[nameOrId] || nameOrId;
  }


  /* ═══ Dependency Resolution ═══════════════════════════ */

  function getDependencies(id) {
    var el = document.getElementById(id);
    if (!el) return [];
    var raw = el.dataset.depends;
    if (!raw) return [];
    return raw.split(",").map(function (s) { return resolveId(s.trim()); });
  }

  function resolveDag(targetId) {
    var ordered = [];
    var visited = {};
    var visiting = {};

    function visit(id) {
      if (visited[id]) return;
      if (visiting[id]) return;
      visiting[id] = true;
      var deps = getDependencies(id);
      for (var i = 0; i < deps.length; i++) visit(deps[i]);
      delete visiting[id];
      visited[id] = true;
      ordered.push(id);
    }

    visit(targetId);
    return ordered;
  }


  /* ═══ Connection ══════════════════════════════════════ */

  function openConnection() {
    if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
    setConnectionUi("connecting");

    try { ws = new WebSocket(BRIDGE_URL); } catch (e) {
      setConnectionUi("disconnected");
      scheduleReconnect();
      return;
    }

    connectTimer = setTimeout(function () {
      if (ws && ws.readyState === 0) ws.close();
    }, CONNECT_TIMEOUT_MS);

    ws.onopen = function () {
      clearTimeout(connectTimer);
      sendRaw({ type: "handshake", version: PROTOCOL_VERSION });
    };

    ws.onmessage = function (e) {
      var msg = JSON.parse(e.data);
      if (msg.type === "handshake") {
        connected = true;
        reconnectDelay = RECONNECT_BASE_MS;
        setConnectionUi("connected");
        startPing();
        return;
      }
      dispatch(msg);
    };

    ws.onclose = function () {
      clearTimeout(connectTimer);
      connected = false;
      stopPing();
      setConnectionUi("disconnected");
      drainQueueOnDisconnect();
      scheduleReconnect();
    };

    ws.onerror = function () {};
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(function () {
      reconnectTimer = null;
      openConnection();
    }, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 1.5, RECONNECT_CAP_MS);
  }

  function sendRaw(obj) {
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify(obj));
      return true;
    }
    return false;
  }

  function startPing() {
    stopPing();
    pingTimer = setInterval(function () {
      sendRaw({ type: "ping", seq: ++pingSeq });
    }, PING_INTERVAL_MS);
  }

  function stopPing() {
    if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
  }


  /* ═══ Message Dispatch ════════════════════════════════ */

  function dispatch(msg) {
    var id = msg.id;
    switch (msg.type) {
      case "stdout":
        appendOutput(id, msg.data, "stdout");
        break;
      case "stderr":
        appendOutput(id, msg.data, "stderr");
        break;
      case "exit":
        finalizeBlock(id, msg.code, msg.elapsed_ms || 0);
        break;
      case "error":
        appendOutput(id, msg.message + "\n", "stderr");
        finalizeBlock(id, 1, 0);
        break;
      case "pong":
        break;
    }
  }


  /* ═══ Block Execution ═════════════════════════════════ */

  function runSingleBlock(id) {
    var el = document.getElementById(id);
    if (!el) return;
    var b = blocks[id];
    if (!b) return;

    var intent = el.dataset.intent || "run";
    if (intent === "setup" && setupCache[id] !== undefined) {
      replayCache(id);
      return;
    }

    var codeEl = el.querySelector("pre code, code");
    if (!codeEl) return;

    clearOutput(id);
    transitionBlock(id, "running");
    startElapsed(id);

    var sent = sendRaw({
      type: "run",
      id: id,
      code: codeEl.textContent,
      kind: el.dataset.kind || "cli",
      usings: el.dataset.usings || "",
      timeout: parseInt(el.dataset.timeout, 10) || 300,
    });

    if (!sent) {
      appendOutput(id, "bridge not connected — run: python bridge.py\n", "stderr");
      finalizeBlock(id, 1, 0);
    }
  }

  function runWithDependencies(targetId) {
    var chain = resolveDag(targetId);
    enqueue(chain);
  }

  function cancelBlock(id) {
    sendRaw({ type: "cancel", id: id });
  }

  function finalizeBlock(id, exitCode, elapsedMs) {
    stopElapsed(id);
    var b = blocks[id];
    if (b) {
      b.exitCode = exitCode;
      b.elapsed = elapsedMs;
    }

    var state = exitCode === 0 ? "done" : "failed";
    transitionBlock(id, state);

    var el = document.getElementById(id);
    var intent = el ? (el.dataset.intent || "run") : "run";

    if (intent === "setup" && exitCode === 0) {
      setupCache[id] = b ? b.output : "";
    }

    if (intent === "assert" && exitCode === 0) {
      checkAssert(id);
    }

    var exitLabel = exitCode === -1 ? "cancelled" : "exit " + exitCode;
    appendOutput(id, "\u2500\u2500 " + exitLabel + " \u2500\u2500\n", "system");

    tryRenderJson(id);
    showOutputControls(id);

    if (queueActive && queueCurrentId === id) {
      queueCurrentId = null;
      if (exitCode !== 0 && exitCode !== -1) {
        abandonQueue();
      } else {
        advanceQueue();
      }
    }
  }

  function replayCache(id) {
    clearOutput(id);
    appendOutput(id, setupCache[id], "stdout");
    appendOutput(id, "\u2500\u2500 cached \u2500\u2500\n", "system");
    transitionBlock(id, "done");
    showOutputControls(id);

    if (queueActive && queueCurrentId === id) {
      queueCurrentId = null;
      advanceQueue();
    }
  }


  /* ═══ Queue / Run-All / Run-From-Here ═════════════════ */

  function enqueue(ids) {
    if (queueActive) return;
    queue = ids.slice();
    queueActive = true;
    updateRunAllUi(true);
    advanceQueue();
  }

  function advanceQueue() {
    if (queue.length === 0) {
      queueActive = false;
      queueCurrentId = null;
      updateRunAllUi(false);
      return;
    }
    var nextId = queue.shift();
    var b = blocks[nextId];
    var el = document.getElementById(nextId);
    var intent = el ? (el.dataset.intent || "run") : "run";

    if (intent === "setup" && setupCache[nextId] !== undefined) {
      queueCurrentId = nextId;
      replayCache(nextId);
      return;
    }

    queueCurrentId = nextId;
    runSingleBlock(nextId);
  }

  function abandonQueue() {
    queue = [];
    queueActive = false;
    queueCurrentId = null;
    updateRunAllUi(false);
  }

  function cancelQueue() {
    if (queueCurrentId) cancelBlock(queueCurrentId);
    abandonQueue();
  }

  function runAll() {
    var all = allBlockIds();
    enqueue(all);
  }

  function runFromHere(startId) {
    var all = allBlockIds();
    var idx = all.indexOf(startId);
    if (idx === -1) return;

    var deps = resolveDag(startId);
    var after = all.slice(idx);
    var merged = [];
    var seen = {};

    for (var i = 0; i < deps.length; i++) {
      if (!seen[deps[i]]) { merged.push(deps[i]); seen[deps[i]] = true; }
    }
    for (var j = 0; j < after.length; j++) {
      if (!seen[after[j]]) { merged.push(after[j]); seen[after[j]] = true; }
    }

    enqueue(merged);
  }

  function allBlockIds() {
    var els = document.querySelectorAll(".ur-block");
    var ids = [];
    for (var i = 0; i < els.length; i++) ids.push(els[i].id);
    return ids;
  }

  function drainQueueOnDisconnect() {
    for (var id in blocks) {
      if (blocks[id].state === "running") {
        stopElapsed(id);
        transitionBlock(id, "failed");
        appendOutput(id, "\u2500\u2500 connection lost \u2500\u2500\n", "system");
      }
    }
    abandonQueue();
  }


  /* ═══ Assert ══════════════════════════════════════════ */

  function checkAssert(id) {
    var el = document.getElementById(id);
    if (!el) return;
    var expected = (el.dataset.expected || "").trim();
    if (!expected) return;

    var b = blocks[id];
    var actual = (b ? b.output : "").trim();
    var passed = actual === expected;

    var assertEl = document.getElementById(id + "-assert");
    if (!assertEl) return;

    assertEl.className = "ur-assert-result " + (passed ? "ur-assert-pass" : "ur-assert-fail");
    assertEl.textContent = passed
      ? "\u2713 PASS"
      : "\u2717 FAIL — expected: " + expected;
    assertEl.style.display = "block";

    if (!passed) transitionBlock(id, "failed");
  }


  /* ═══ Output Rendering ════════════════════════════════ */

  function appendOutput(id, text, stream) {
    var b = blocks[id];
    if (b && stream === "stdout") b.output += text;

    var outputEl = document.getElementById(id + "-output");
    if (!outputEl) return;

    var panel = document.getElementById(id + "-panel");
    if (panel) panel.classList.add("has-content");

    var span = document.createElement("span");
    span.className = "ur-output-" + stream;
    span.textContent = text;
    outputEl.appendChild(span);
    outputEl.scrollTop = outputEl.scrollHeight;
  }

  function clearOutput(id) {
    var b = blocks[id];
    if (b) b.output = "";

    var outputEl = document.getElementById(id + "-output");
    if (outputEl) { outputEl.innerHTML = ""; }

    var panel = document.getElementById(id + "-panel");
    if (panel) panel.classList.remove("has-content");

    var assertEl = document.getElementById(id + "-assert");
    if (assertEl) { assertEl.style.display = "none"; assertEl.textContent = ""; }

    hideOutputControls(id);
  }

  function tryRenderJson(id) {
    var b = blocks[id];
    if (!b || !b.output) return;

    var el = document.getElementById(id);
    var fmt = el ? (el.dataset.format || "auto") : "auto";
    if (fmt === "raw") return;

    var trimmed = b.output.trim();
    if (fmt === "auto") {
      if (trimmed[0] !== "{" && trimmed[0] !== "[") return;
    }

    try {
      var parsed = JSON.parse(trimmed);
      var formatted = JSON.stringify(parsed, null, 2);
      var outputEl = document.getElementById(id + "-output");
      if (!outputEl) return;

      var existingSpans = outputEl.querySelectorAll(".ur-output-stdout");
      for (var i = 0; i < existingSpans.length; i++) existingSpans[i].remove();

      var pre = document.createElement("span");
      pre.className = "ur-output-stdout ur-output-json";
      pre.textContent = formatted + "\n";
      var firstChild = outputEl.firstChild;
      if (firstChild) { outputEl.insertBefore(pre, firstChild); }
      else { outputEl.appendChild(pre); }
    } catch (e) {}
  }


  /* ═══ Elapsed Timer ═══════════════════════════════════ */

  function startElapsed(id) {
    stopElapsed(id);
    var el = document.getElementById(id + "-elapsed");
    if (!el) return;
    var t0 = Date.now();
    el.textContent = "0s";
    elapsedTimers[id] = setInterval(function () {
      var sec = Math.floor((Date.now() - t0) / 1000);
      var m = Math.floor(sec / 60);
      var s = sec % 60;
      el.textContent = m > 0 ? m + "m " + s + "s" : s + "s";
    }, 1000);
  }

  function stopElapsed(id) {
    if (elapsedTimers[id]) {
      clearInterval(elapsedTimers[id]);
      delete elapsedTimers[id];
    }
  }


  /* ═══ UI Rendering ════════════════════════════════════ */

  function setConnectionUi(state) {
    var dot = document.getElementById("ur-dot");
    var text = document.getElementById("ur-status-text");
    var btn = document.getElementById("ur-run-all-btn");

    if (dot) dot.className = "ur-status-dot ur-" + state;
    if (text) text.textContent = { disconnected: "Disconnected", connecting: "Connecting\u2026", connected: "Connected" }[state] || state;
    if (btn) btn.disabled = (state !== "connected");
  }

  function renderBlockState(id, state) {
    var el = document.getElementById(id);
    if (!el) return;
    el.setAttribute("data-state", state);

    var runBtn = el.querySelector(".ur-run-btn");
    if (runBtn) {
      if (state === "running") {
        runBtn.classList.add("is-running");
        runBtn.title = "Stop";
      } else {
        runBtn.classList.remove("is-running");
        runBtn.title = "Run";
      }
    }
  }

  function updateRunAllUi(active) {
    var btn = document.getElementById("ur-run-all-btn");
    if (!btn) return;
    if (active) {
      btn.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="4" y="4" width="16" height="16" rx="2"/></svg> Stop All';
      btn.classList.add("is-running");
    } else {
      btn.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,3 19,12 5,21"/></svg> Run All';
      btn.classList.remove("is-running");
    }
  }

  function showOutputControls(id) {
    var el = document.getElementById(id);
    if (!el) return;
    var fold = el.querySelector(".ur-fold-btn");
    var copyOut = el.querySelector(".ur-copy-output-btn");
    if (fold) fold.style.display = "";
    if (copyOut) copyOut.style.display = "";
  }

  function hideOutputControls(id) {
    var el = document.getElementById(id);
    if (!el) return;
    var fold = el.querySelector(".ur-fold-btn");
    var copyOut = el.querySelector(".ur-copy-output-btn");
    if (fold) fold.style.display = "none";
    if (copyOut) copyOut.style.display = "none";
  }


  /* ═══ Fold / Copy ═════════════════════════════════════ */

  function toggleFold(id) {
    var b = blocks[id];
    if (!b) return;
    b.folded = !b.folded;
    var panel = document.getElementById(id + "-panel");
    if (panel) panel.classList.toggle("ur-folded", b.folded);
  }

  function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text);
      return;
    }
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.style.cssText = "position:fixed;opacity:0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
  }

  function copyCode(id) {
    var el = document.getElementById(id);
    if (!el) return;
    var code = el.querySelector("pre code, code");
    if (code) copyToClipboard(code.textContent);
  }

  function copyOutput(id) {
    var b = blocks[id];
    if (b) copyToClipboard(b.output);
  }


  /* ═══ Focused Block (for keyboard shortcuts) ══════════ */

  function focusedBlockId() {
    var sel = window.getSelection();
    if (!sel || !sel.anchorNode) return null;
    var node = sel.anchorNode.nodeType === 3 ? sel.anchorNode.parentElement : sel.anchorNode;
    var block = node ? node.closest(".ur-block") : null;
    return block ? block.id : null;
  }

  function firstBlockId() {
    var el = document.querySelector(".ur-block");
    return el ? el.id : null;
  }


  /* ═══ Event Delegation ════════════════════════════════ */

  document.addEventListener("click", function (e) {
    var btn = e.target.closest(".ur-btn");
    if (!btn) return;
    var target = btn.dataset.target;

    if (btn.classList.contains("ur-run-btn")) {
      if (target && blocks[target] && blocks[target].state === "running") {
        cancelBlock(target);
      } else if (target) {
        runWithDependencies(target);
      }
      return;
    }

    if (btn.classList.contains("ur-clear-btn")) {
      if (target) clearOutput(target);
      var elapsed = document.getElementById(target + "-elapsed");
      if (elapsed) elapsed.textContent = "";
      transitionBlock(target, "idle");
      return;
    }

    if (btn.classList.contains("ur-copy-code-btn")) {
      if (target) copyCode(target);
      return;
    }

    if (btn.classList.contains("ur-copy-output-btn")) {
      if (target) copyOutput(target);
      return;
    }

    if (btn.classList.contains("ur-fold-btn")) {
      if (target) toggleFold(target);
      return;
    }

    if (btn.classList.contains("ur-from-here-btn")) {
      if (target) runFromHere(target);
      return;
    }

    if (btn.id === "ur-run-all-btn") {
      if (queueActive) cancelQueue();
      else runAll();
      return;
    }
  });


  /* ═══ Keyboard Shortcuts ══════════════════════════════ */

  document.addEventListener("keydown", function (e) {
    if (!e.ctrlKey && !e.metaKey) return;

    if (e.key === "Enter" && e.shiftKey) {
      e.preventDefault();
      if (!queueActive && connected) runAll();
      return;
    }

    if (e.key === "Enter") {
      e.preventDefault();
      var id = focusedBlockId() || firstBlockId();
      if (id && connected) runWithDependencies(id);
      return;
    }
  });


  /* ═══ Init ════════════════════════════════════════════ */

  function init() {
    loadRegistry();
    var els = document.querySelectorAll(".ur-block");
    for (var i = 0; i < els.length; i++) initBlockState(els[i]);
    openConnection();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
