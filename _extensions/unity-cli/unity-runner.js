(() => {
	var BRIDGE_URL = "ws://localhost:7890";
	var RECONNECT_BASE_MS = 1500;
	var RECONNECT_CAP_MS = 10000;
	var CONNECT_TIMEOUT_MS = 3000;

	var ws = null;
	var reconnectDelay = RECONNECT_BASE_MS;
	var reconnectTimer = null;
	var connectTimer = null;
	var blockStates = {};
	var elapsedTimers = {};
	var runAllQueue = [];
	var runAllActive = false;

	/* ── Connection ──────────────────────────────────────── */

	function connect() {
		if (
			ws &&
			(ws.readyState === WebSocket.CONNECTING ||
				ws.readyState === WebSocket.OPEN)
		) {
			return;
		}

		setConnectionUI("connecting");

		try {
			ws = new WebSocket(BRIDGE_URL);
		} catch (e) {
			setConnectionUI("disconnected");
			scheduleReconnect();
			return;
		}

		connectTimer = setTimeout(() => {
			if (ws && ws.readyState === WebSocket.CONNECTING) {
				ws.close();
			}
		}, CONNECT_TIMEOUT_MS);

		ws.onopen = () => {
			clearTimeout(connectTimer);
			reconnectDelay = RECONNECT_BASE_MS;
			setConnectionUI("connected");
		};

		ws.onclose = () => {
			clearTimeout(connectTimer);
			setConnectionUI("disconnected");
			markAllBlocksIdle();
			scheduleReconnect();
		};

		ws.onerror = () => {};

		ws.onmessage = (event) => {
			dispatch(JSON.parse(event.data));
		};
	}

	function scheduleReconnect() {
		if (reconnectTimer) return;
		reconnectTimer = setTimeout(() => {
			reconnectTimer = null;
			connect();
		}, reconnectDelay);
		reconnectDelay = Math.min(reconnectDelay * 1.5, RECONNECT_CAP_MS);
	}

	function send(msg) {
		if (ws && ws.readyState === WebSocket.OPEN) {
			ws.send(JSON.stringify(msg));
			return true;
		}
		return false;
	}

	/* ── Message Dispatch ────────────────────────────────── */

	function dispatch(msg) {
		switch (msg.type) {
			case "stdout":
				appendOutput(msg.id, msg.data, "stdout");
				break;
			case "stderr":
				appendOutput(msg.id, msg.data, "stderr");
				break;
			case "exit":
				handleExit(msg.id, msg.code);
				break;
			case "error":
				appendOutput(msg.id, msg.message + "\n", "stderr");
				handleExit(msg.id, 1);
				break;
		}
	}

	/* ── Block Actions ───────────────────────────────────── */

	function runBlock(blockId) {
		var block = document.getElementById(blockId);
		if (!block) return;

		// Prefer the hidden runnable code (exec blocks store heredoc form here)
		var runCodeEl = block.querySelector("pre.unity-run-code");
		var codeEl = block.querySelector("pre code, code");
		if (!runCodeEl && !codeEl) return;

		var code = runCodeEl ? runCodeEl.textContent : codeEl.textContent;
		var execType = block.dataset.execType || "cli";

		clearOutput(blockId);
		setBlockState(blockId, "running");
		startElapsed(blockId);

		var sent = send({
			type: "run",
			id: blockId,
			code: code,
			exec_type: execType,
		});

		if (!sent) {
			appendOutput(
				blockId,
				"Bridge not connected. Start with: python bridge.py\n",
				"stderr",
			);
			handleExit(blockId, 1);
		}
	}

	function cancelBlock(blockId) {
		send({ type: "cancel", id: blockId });
	}

	function clearOutput(blockId) {
		var output = document.getElementById(blockId + "-output");
		if (output) {
			output.innerHTML = "";
			output.classList.remove("has-content");
		}
	}

	function handleExit(blockId, exitCode) {
		stopElapsed(blockId);

		var finalState = exitCode === 0 ? "done" : "failed";
		setBlockState(blockId, finalState);

		var exitLabel = exitCode === -1 ? "cancelled" : "exit " + exitCode;
		appendOutput(
			blockId,
			"\u2500\u2500 " + exitLabel + " \u2500\u2500\n",
			"system",
		);

		if (runAllActive) {
			if (exitCode !== 0 && exitCode !== -1) {
				runAllQueue = [];
				runAllActive = false;
				updateRunAllBtn();
			} else {
				advanceRunAll();
			}
		}
	}

	/* ── Run All ─────────────────────────────────────────── */

	function startRunAll() {
		if (runAllActive) return;

		var blocks = document.querySelectorAll(".unity-block");
		runAllQueue = [];
		for (var i = 0; i < blocks.length; i++) {
			runAllQueue.push(blocks[i].id);
		}
		runAllActive = true;
		updateRunAllBtn();
		advanceRunAll();
	}

	function advanceRunAll() {
		if (runAllQueue.length === 0) {
			runAllActive = false;
			updateRunAllBtn();
			return;
		}
		var nextId = runAllQueue.shift();
		runBlock(nextId);
	}

	function cancelRunAll() {
		var currentBlock = null;
		for (var id in blockStates) {
			if (blockStates[id] === "running") {
				currentBlock = id;
				break;
			}
		}
		runAllQueue = [];
		runAllActive = false;
		updateRunAllBtn();
		if (currentBlock) {
			cancelBlock(currentBlock);
		}
	}

	function updateRunAllBtn() {
		var btn = document.getElementById("unity-run-all-btn");
		if (!btn) return;
		if (runAllActive) {
			btn.innerHTML =
				'<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="4" y="4" width="16" height="16" rx="2"/></svg> Stop All';
			btn.classList.add("is-running");
		} else {
			btn.innerHTML =
				'<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,3 19,12 5,21"/></svg> Run All';
			btn.classList.remove("is-running");
		}
	}

	/* ── Elapsed Timer ───────────────────────────────────── */

	function startElapsed(blockId) {
		stopElapsed(blockId);
		var el = document.getElementById(blockId + "-elapsed");
		if (!el) return;

		var startMs = Date.now();
		el.textContent = "0s";

		elapsedTimers[blockId] = setInterval(() => {
			var totalSec = Math.floor((Date.now() - startMs) / 1000);
			var min = Math.floor(totalSec / 60);
			var sec = totalSec % 60;
			el.textContent = min > 0 ? min + "m " + sec + "s" : sec + "s";
		}, 1000);
	}

	function stopElapsed(blockId) {
		if (elapsedTimers[blockId]) {
			clearInterval(elapsedTimers[blockId]);
			delete elapsedTimers[blockId];
		}
	}

	/* ── Output Rendering ───────────────────────────────── */

	function appendOutput(blockId, text, stream) {
		var output = document.getElementById(blockId + "-output");
		if (!output) return;

		output.classList.add("has-content");

		var span = document.createElement("span");
		span.className = "unity-output-" + stream;
		span.textContent = text;
		output.appendChild(span);

		output.scrollTop = output.scrollHeight;
	}

	/* ── UI State ────────────────────────────────────────── */

	function setConnectionUI(state) {
		var dot = document.getElementById("unity-dot");
		var text = document.getElementById("unity-status-text");
		var runAllBtn = document.getElementById("unity-run-all-btn");

		if (dot) {
			dot.className = "unity-status-dot " + state;
		}

		var labels = {
			disconnected: "Disconnected",
			connecting: "Connecting\u2026",
			connected: "Connected",
		};

		if (text) {
			text.textContent = labels[state] || state;
		}

		if (runAllBtn) {
			runAllBtn.disabled = state !== "connected";
		}
	}

	function setBlockState(blockId, state) {
		blockStates[blockId] = state;

		var btn = document.querySelector(
			'.unity-run-btn[data-target="' + blockId + '"]',
		);
		if (!btn) return;

		if (state === "running") {
			btn.classList.add("is-running");
			btn.title = "Stop";
		} else {
			btn.classList.remove("is-running");
			btn.title = "Run";
		}
	}

	function markAllBlocksIdle() {
		for (var id in blockStates) {
			if (blockStates[id] === "running") {
				stopElapsed(id);
				setBlockState(id, "failed");
				appendOutput(
					id,
					"\u2500\u2500 connection lost \u2500\u2500\n",
					"system",
				);
			}
		}
		if (runAllActive) {
			runAllQueue = [];
			runAllActive = false;
			updateRunAllBtn();
		}
	}

	/* ── Copy to Clipboard ──────────────────────────────── */

	function copyCode(blockId) {
		var block = document.getElementById(blockId);
		if (!block) return;

		var codeEl = block.querySelector("pre code, code");
		if (!codeEl) return;

		var text = codeEl.textContent;
		if (navigator.clipboard && navigator.clipboard.writeText) {
			navigator.clipboard.writeText(text);
		} else {
			var ta = document.createElement("textarea");
			ta.value = text;
			ta.style.position = "fixed";
			ta.style.opacity = "0";
			document.body.appendChild(ta);
			ta.select();
			document.execCommand("copy");
			document.body.removeChild(ta);
		}
	}

	/* ── Event Delegation ────────────────────────────────── */

	document.addEventListener("click", (e) => {
		var target = e.target.closest(".unity-btn");
		if (!target) return;

		if (target.classList.contains("unity-run-btn")) {
			var blockId = target.dataset.target;
			if (blockStates[blockId] === "running") {
				cancelBlock(blockId);
			} else {
				runBlock(blockId);
			}
			return;
		}

		if (target.classList.contains("unity-clear-btn")) {
			clearOutput(target.dataset.target);
			var elapsed = document.getElementById(target.dataset.target + "-elapsed");
			if (elapsed) elapsed.textContent = "";
			return;
		}

		if (target.classList.contains("unity-copy-btn")) {
			copyCode(target.dataset.target);
			return;
		}

		if (target.id === "unity-run-all-btn") {
			if (runAllActive) {
				cancelRunAll();
			} else {
				startRunAll();
			}
			return;
		}
	});

	/* ── Init ────────────────────────────────────────────── */

	if (document.readyState === "loading") {
		document.addEventListener("DOMContentLoaded", connect);
	} else {
		connect();
	}
})();
