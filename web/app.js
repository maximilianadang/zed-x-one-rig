import { parseEnvelope, STREAM_IDS } from "./protocol.js";

window.__zedAppStarted = true;

const query = new URLSearchParams(window.location.search);
const token = query.get("token") || sessionStorage.getItem("zedGatewayToken") || "";
const mode = query.get("mode") === "replay" ? "replay" : "live";
let theme = "light";
try {
  theme = localStorage.getItem("zedFieldTheme") === "dark" ? "dark" : "light";
} catch (error) {
  theme = "light";
}
document.documentElement.dataset.theme = theme;
if (token) {
  sessionStorage.setItem("zedGatewayToken", token);
  const clean = new URL(window.location.href);
  clean.searchParams.delete("token");
  history.replaceState({}, "", clean);
}

const elements = Object.fromEntries(
  [
    "connection-pill", "mode-pill", "profile-pill", "recording-banner",
    "controller-pill",
    "record-elapsed", "record-bytes", "record-rate", "rgb-view", "rgb-empty",
    "rgb-health", "rgb-stat", "depth-view", "depth-empty", "depth-health",
    "depth-stat", "depth-range", "cloud-view", "cloud-empty", "cloud-health",
    "cloud-stat", "reset-view", "control-state", "live-controls",
    "replay-controls", "record-start", "record-stop", "live-stop",
    "replay-toggle", "replay-next", "replay-slower", "replay-faster",
    "replay-loop", "replay-stop", "datasets", "datasets-refresh",
    "dataset-index", "dataset-open",
    "session-details", "operator-message", "global-alert", "theme-toggle",
  ].map((id) => [id, document.getElementById(id)]),
);

function updateThemeToggle() {
  elements["theme-toggle"].textContent =
    document.documentElement.dataset.theme === "dark" ? "Light mode" : "Dark mode";
}

updateThemeToggle();
elements["theme-toggle"].addEventListener("click", () => {
  const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  try {
    localStorage.setItem("zedFieldTheme", next);
  } catch (error) {
    // Theme persistence is optional when browser storage is unavailable.
  }
  updateThemeToggle();
});

const streams = {
  rgb: { id: STREAM_IDS.rgb, last: 0, received: [], rendered: [], drops: 0, queueDrops: 0, age: 0, socket: null, backoff: 500, disabled: false },
  depth: { id: STREAM_IDS.depth, last: 0, received: [], rendered: [], drops: 0, queueDrops: 0, age: 0, socket: null, backoff: 500, disabled: false },
  cloud: { id: STREAM_IDS.cloud, last: 0, received: [], rendered: [], drops: 0, queueDrops: 0, age: 0, socket: null, backoff: 500, disabled: false },
};

let status = {};
const controllerId = Array.from(crypto.getRandomValues(new Uint8Array(16)))
  .map((byte) => byte.toString(16).padStart(2, "0"))
  .join("");
let controllerActive = false;
let selectedDataset = 0;
let datasets = [];
let commandBusy = false;
let priorRecordBytes = 0;
let priorRecordTime = 0;
let rgbUrl = null;
let depthPending = false;
let depthPendingFrame = null;
let depthQueued = null;
let cloudPending = false;
let cloudPendingFrame = null;
let cloudQueued = null;

function setMessage(message, error = false) {
  elements["operator-message"].textContent = message;
  elements["operator-message"].style.color = error ? "var(--red)" : "var(--amber)";
  if (error) {
    elements["global-alert"].textContent = message;
    elements["global-alert"].classList.remove("hidden");
  }
}

function humanBytes(value) {
  let amount = Number(value) || 0;
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit += 1;
  }
  return `${amount >= 10 || unit === 0 ? amount.toFixed(0) : amount.toFixed(1)} ${units[unit]}`;
}

function elapsed(seconds) {
  const safe = Math.max(0, Math.floor(seconds || 0));
  const hours = Math.floor(safe / 3600);
  const minutes = Math.floor((safe % 3600) / 60);
  const remainder = safe % 60;
  return hours
    ? `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
    : `${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`;
}

function parseMachine(text) {
  const values = {};
  for (const line of text.split(/\r?\n/)) {
    const split = line.indexOf("=");
    if (split > 0) values[line.slice(0, split)] = line.slice(split + 1);
  }
  return values;
}

async function api(path, { method = "GET", body = null, quiet = false } = {}) {
  const response = await fetch(path, {
    method,
    cache: "no-store",
    headers: {
      "X-ZED-Token": token,
      "X-ZED-Controller": controllerId,
      ...(body === null ? {} : { "Content-Type": "text/plain" }),
    },
    body,
  });
  const text = await response.text();
  if (!response.ok) {
    if (!quiet) setMessage(text.trim() || `HTTP ${response.status}`, true);
    throw new Error(text.trim() || `HTTP ${response.status}`);
  }
  return text;
}

function accountStream(name, frame) {
  const state = streams[name];
  if (state.last && frame.sequence > state.last + 1) {
    state.drops += frame.sequence - state.last - 1;
  }
  state.last = frame.sequence;
  const now = performance.now();
  frame.receivedAt = now;
  state.received.push(now);
  while (state.received.length && state.received[0] < now - 5000) state.received.shift();
}

function streamRate(name) {
  const samples = streams[name].received;
  if (samples.length < 2) return 0;
  return ((samples.length - 1) * 1000) / (samples[samples.length - 1] - samples[0]);
}

function renderedRate(name) {
  const samples = streams[name].rendered;
  if (samples.length < 2) return 0;
  return ((samples.length - 1) * 1000) / (samples[samples.length - 1] - samples[0]);
}

function accountRendered(name, frame) {
  const state = streams[name];
  const now = performance.now();
  state.rendered.push(now);
  while (state.rendered.length && state.rendered[0] < now - 5000) state.rendered.shift();
  const sourceTime = Number(frame.stampSec) * 1000 + Number(frame.stampNsec) / 1e6;
  state.age = mode === "live"
    ? Math.max(0, Date.now() - sourceTime)
    : Math.max(0, performance.now() - frame.receivedAt);
}

function websocketUrl(name) {
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}/api/v1/stream/${name}?v=1&token=${encodeURIComponent(token)}`;
}

function connectStream(name, handler) {
  const state = streams[name];
  const socket = new WebSocket(websocketUrl(name));
  state.socket = socket;
  socket.binaryType = "arraybuffer";
  socket.onopen = () => {
    state.backoff = 500;
    updateConnection();
  };
  socket.onmessage = (event) => {
    try {
      const frame = parseEnvelope(event.data, state.id);
      accountStream(name, frame);
      handler(frame);
    } catch (error) {
      setMessage(`${name}: ${error.message}`, true);
    }
  };
  socket.onerror = () => socket.close();
  socket.onclose = () => {
    updateConnection();
    window.setTimeout(() => connectStream(name, handler), state.backoff);
    state.backoff = Math.min(8000, state.backoff * 1.7);
  };
}

function updateConnection() {
  const available = Object.values(streams).filter((item) => !item.disabled);
  const open = available.filter((item) => item.socket?.readyState === WebSocket.OPEN).length;
  const complete = open === available.length;
  elements["connection-pill"].textContent =
    complete && available.length === 3 ? "STREAMING"
      : complete && open ? `STREAMING ${open}/3`
        : open ? `CONNECTING ${open}/3` : "RECONNECTING";
  elements["connection-pill"].className =
    complete && available.length === 3 ? "pill" : "pill warning";
}

function disableStream(name, message) {
  streams[name].disabled = true;
  elements[`${name}-health`].textContent = "UNAVAILABLE";
  const empty = elements[`${name}-empty`];
  if (empty) {
    empty.textContent = message;
    empty.classList.add("error");
    empty.classList.remove("hidden");
  }
  setMessage(message, true);
  updateConnection();
}

async function renderRgb(frame) {
  const blob = new Blob([frame.payload], { type: "image/jpeg" });
  const nextUrl = URL.createObjectURL(blob);
  const oldUrl = rgbUrl;
  elements["rgb-view"].onload = () => {
    elements["rgb-empty"].classList.add("hidden");
    if (oldUrl) URL.revokeObjectURL(oldUrl);
    accountRendered("rgb", frame);
  };
  elements["rgb-view"].src = nextUrl;
  rgbUrl = nextUrl;
  elements["rgb-health"].textContent = frame.metadata.frame_id || "live";
}

let depthWorker = null;

function submitDepth(frame) {
  if (depthPending) {
    if (depthQueued) streams.depth.queueDrops += 1;
    depthQueued = frame;
    return;
  }
  depthPending = true;
  depthPendingFrame = frame;
  depthWorker.postMessage(
    { id: frame.sequence, payload: frame.payload, format: frame.metadata.format || "" },
    [frame.payload],
  );
  elements["depth-health"].textContent = frame.metadata.frame_id || "live";
}

function initializeDepth() {
  try {
    depthWorker = new Worker("/depth_worker.js", { type: "module" });
    depthWorker.onmessage = (event) => {
      depthPending = false;
      if (event.data.error) {
        setMessage(`depth decoder: ${event.data.error}`, true);
      } else {
        const canvas = elements["depth-view"];
        canvas.width = event.data.width;
        canvas.height = event.data.height;
        const context = canvas.getContext("2d", { alpha: false });
        context.putImageData(
          new ImageData(
            new Uint8ClampedArray(event.data.pixels),
            event.data.width,
            event.data.height,
          ),
          0,
          0,
        );
        elements["depth-empty"].classList.add("hidden");
        elements["depth-range"].textContent =
          `${event.data.low.toFixed(2)}–${event.data.high.toFixed(2)} m · ` +
          `${event.data.valid.toLocaleString()} valid`;
        accountRendered("depth", depthPendingFrame);
      }
      depthPendingFrame = null;
      if (depthQueued) {
        const queued = depthQueued;
        depthQueued = null;
        submitDepth(queued);
      }
    };
    depthWorker.onerror = (event) => {
      disableStream("depth", `Depth renderer failed: ${event.message || "worker error"}`);
    };
    connectStream("depth", submitDepth);
  } catch (error) {
    disableStream("depth", `Depth renderer could not start: ${error.message}`);
  }
}

async function initializeCloud() {
  elements["cloud-health"].textContent = "starting 3D renderer";
  elements["cloud-empty"].textContent = "STARTING 3D RENDERER…";
  const threeUrl = new URL("./vendor/three.field.module.min.js", import.meta.url);
  threeUrl.searchParams.set("session", `${Date.now()}-${controllerId.slice(0, 8)}`);
  const THREE = await import(threeUrl.href);
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x030506);
  const camera = new THREE.PerspectiveCamera(55, 1, 0.01, 1000);
  camera.up.set(0, 0, 1);
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("webgl2", {
    antialias: true,
    powerPreference: "high-performance",
  });
  if (!context) {
    throw new Error("WebGL 2 is unavailable in this browser");
  }
  const renderer = new THREE.WebGLRenderer({
    canvas,
    context,
    antialias: true,
    powerPreference: "high-performance",
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  elements["cloud-view"].prepend(renderer.domElement);
  const target = new THREE.Vector3(0, 0, 0);
  let radius = 5;
  let azimuth = Math.PI;
  let elevation = 0.35;
  let pointer = null;

  function updateCamera() {
    const horizontal = radius * Math.cos(elevation);
    camera.position.set(
      target.x + horizontal * Math.cos(azimuth),
      target.y + horizontal * Math.sin(azimuth),
      target.z + radius * Math.sin(elevation),
    );
    camera.lookAt(target);
  }

  renderer.domElement.addEventListener("contextmenu", (event) => event.preventDefault());
  renderer.domElement.addEventListener("pointerdown", (event) => {
    pointer = { id: event.pointerId, x: event.clientX, y: event.clientY, button: event.button };
    renderer.domElement.setPointerCapture(event.pointerId);
  });
  renderer.domElement.addEventListener("pointermove", (event) => {
    if (!pointer || pointer.id !== event.pointerId) return;
    const dx = event.clientX - pointer.x;
    const dy = event.clientY - pointer.y;
    pointer.x = event.clientX;
    pointer.y = event.clientY;
    if (pointer.button === 0) {
      azimuth -= dx * 0.006;
      elevation = Math.max(-1.45, Math.min(1.45, elevation + dy * 0.006));
    } else {
      const scale = radius * 0.0018;
      target.x += (Math.sin(azimuth) * dx) * scale;
      target.y -= (Math.cos(azimuth) * dx) * scale;
      target.z += dy * scale;
    }
    updateCamera();
  });
  const releasePointer = (event) => {
    if (pointer?.id === event.pointerId) pointer = null;
  };
  renderer.domElement.addEventListener("pointerup", releasePointer);
  renderer.domElement.addEventListener("pointercancel", releasePointer);
  renderer.domElement.addEventListener("wheel", (event) => {
    event.preventDefault();
    radius = Math.max(0.1, Math.min(500, radius * Math.exp(event.deltaY * 0.001)));
    updateCamera();
  }, { passive: false });

  function makeGrid(size = 20, step = 1) {
    const positions = [];
    const half = size / 2;
    for (let value = -half; value <= half; value += step) {
      positions.push(-half, value, 0, half, value, 0);
      positions.push(value, -half, 0, value, half, 0);
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute("position", new THREE.Float32BufferAttribute(positions, 3));
    return new THREE.LineSegments(
      geometry,
      new THREE.LineBasicMaterial({
        color: 0xa0a0a4,
        transparent: true,
        opacity: 0.5,
      }),
    );
  }

  scene.add(makeGrid());
  scene.add(new THREE.AxesHelper(1));
  let cloudPoints = null;

  function resetView() {
    target.set(0, 0, 0);
    radius = 5;
    azimuth = Math.PI;
    elevation = 0.35;
    updateCamera();
  }
  resetView();
  elements["reset-view"].addEventListener("click", resetView);

  const dracoWorker = new Worker("/draco_worker.js");
  let pendingCloudMetadata = null;

  function submitCloud(frame) {
    if (cloudPending) {
      if (cloudQueued) streams.cloud.queueDrops += 1;
      cloudQueued = frame;
      return;
    }
    cloudPending = true;
    cloudPendingFrame = frame;
    pendingCloudMetadata = frame.metadata;
    dracoWorker.postMessage(
      { id: frame.sequence, payload: frame.payload },
      [frame.payload],
    );
  }

  dracoWorker.onmessage = (event) => {
    cloudPending = false;
    if (event.data.error) {
      setMessage(`Draco decoder: ${event.data.error}`, true);
    } else {
      if (cloudPoints) {
        scene.remove(cloudPoints);
        cloudPoints.geometry.dispose();
        cloudPoints.material.dispose();
      }
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute(
        "position",
        new THREE.BufferAttribute(new Float32Array(event.data.positions), 3),
      );
      if (event.data.colors) {
        geometry.setAttribute(
          "color",
          new THREE.BufferAttribute(new Uint8Array(event.data.colors), 3, true),
        );
      }
      const material = new THREE.PointsMaterial({
        size: 2,
        sizeAttenuation: false,
        vertexColors: Boolean(event.data.colors),
        color: event.data.colors ? 0xffffff : 0x67d5dc,
      });
      cloudPoints = new THREE.Points(geometry, material);
      const translation = pendingCloudMetadata?.fixed_translation || [0, 0, 0];
      cloudPoints.position.set(translation[0], translation[1], translation[2]);
      scene.add(cloudPoints);
      elements["cloud-empty"].classList.add("hidden");
      elements["cloud-health"].textContent =
        `${event.data.count.toLocaleString()} points · ` +
        `${pendingCloudMetadata?.frame_id || "live"}`;
      accountRendered("cloud", cloudPendingFrame);
    }
    cloudPendingFrame = null;
    if (cloudQueued) {
      const queued = cloudQueued;
      cloudQueued = null;
      submitCloud(queued);
    }
  };
  dracoWorker.onerror = (event) => {
    disableStream("cloud", `Point-cloud decoder failed: ${event.message || "worker error"}`);
  };

  function resizeCloud() {
    const area = elements["cloud-view"];
    const width = Math.max(1, area.clientWidth);
    const height = Math.max(1, area.clientHeight);
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  }
  if (typeof ResizeObserver === "function") {
    new ResizeObserver(resizeCloud).observe(elements["cloud-view"]);
  } else {
    window.addEventListener("resize", resizeCloud);
  }
  resizeCloud();

  function animate() {
    renderer.render(scene, camera);
    requestAnimationFrame(animate);
  }
  requestAnimationFrame(animate);
  elements["cloud-health"].textContent = "renderer ready";
  connectStream("cloud", submitCloud);
}

function renderDetails(values) {
  const preferred = mode === "live"
    ? ["STATE", "UNIT", "NODE", "MODE", "DDS_PROFILE", "FILE_BYTES", "FREE_BYTES", "EST_LOSSLESS_MINUTES", "RECORDING_PATH", "LAST_PATH", "FAILED_PATH"]
    : ["STATE", "UNIT", "DDS_PROFILE", "SVO", "SVO_BYTES", "FRAME_ID", "TOTAL_FRAMES", "FPS", "RATE", "LOOP", "LOOP_COUNT"];
  const rows = [];
  for (const key of preferred) {
    if (values[key] === undefined || values[key] === "") continue;
    let value = values[key];
    if (key.endsWith("_BYTES")) value = humanBytes(value);
    rows.push(`<dt>${key.replaceAll("_", " ")}</dt><dd>${escapeHtml(value)}</dd>`);
  }
  elements["session-details"].innerHTML = rows.join("");
}

function escapeHtml(value) {
  const node = document.createElement("span");
  node.textContent = String(value);
  return node.innerHTML;
}

async function refreshStatus() {
  try {
    status = parseMachine(await api(`/api/v1/status?mode=${mode}`, { quiet: true }));
    renderDetails(status);
    elements["control-state"].textContent = status.STATE || "UNKNOWN";
    elements["mode-pill"].textContent = status.STATE || (mode === "replay" ? "REPLAY" : "VIEW ONLY");
    elements["profile-pill"].textContent = `PROFILE ${status.MODE || status.PROFILE?.split("/").pop()?.replace(".yaml", "").toUpperCase() || "—"}`;
    if (elements["profile-pill"].textContent === "PROFILE FIELD") {
      elements["profile-pill"].textContent = "PROFILE STANDARD";
    }
    const recording = status.STATE === "RECORDING";
    elements["recording-banner"].classList.toggle("hidden", !recording);
    elements["mode-pill"].className = recording ? "pill danger" : "pill";
    if (recording) {
      const now = Date.now() / 1000;
      const started = Number(status.STARTED_EPOCH) || now;
      const bytes = Number(status.FILE_BYTES) || 0;
      elements["record-elapsed"].textContent = elapsed(now - started);
      elements["record-bytes"].textContent = humanBytes(bytes);
      if (priorRecordTime && now > priorRecordTime && bytes >= priorRecordBytes) {
        elements["record-rate"].textContent =
          `${((bytes - priorRecordBytes) / (now - priorRecordTime) / 1e6).toFixed(1)} MB/s`;
      }
      priorRecordBytes = bytes;
      priorRecordTime = now;
    } else {
      priorRecordBytes = 0;
      priorRecordTime = 0;
    }
  } catch (error) {
    elements["control-state"].textContent = "UNREACHABLE";
  }
}

async function control(path, label, body = null) {
  if (commandBusy || !controllerActive) {
    setMessage("This viewer is read-only until it holds the control lease.", true);
    return;
  }
  commandBusy = true;
  setMutationAvailability(false);
  setMessage(`${label}…`);
  try {
    const response = await api(path, { method: "POST", body });
    setMessage(response.trim() || `${label}: complete`);
    await refreshStatus();
  } catch (error) {
    setMessage(error.message, true);
  } finally {
    commandBusy = false;
    setMutationAvailability(controllerActive);
  }
}

function setMutationAvailability(available) {
  document.querySelectorAll("[data-mutation]").forEach((button) => {
    button.disabled = !available;
  });
}

async function refreshLease() {
  try {
    await api("/api/v1/lease", { method: "POST", quiet: true });
    if (!controllerActive) setMessage("Controller lease acquired. Mutating controls are active.");
    controllerActive = true;
    elements["controller-pill"].textContent = "CONTROLLER";
    elements["controller-pill"].className = "pill";
  } catch (error) {
    controllerActive = false;
    elements["controller-pill"].textContent = "READ ONLY";
    elements["controller-pill"].className = "pill warning";
  }
  if (!commandBusy) setMutationAvailability(controllerActive);
}

elements["record-start"].addEventListener("click", () =>
  control("/api/v1/live/record-start", "Starting lossless recording"));
elements["record-stop"].addEventListener("click", () =>
  control("/api/v1/live/record-stop", "Finalizing and validating recording"));
elements["live-stop"].addEventListener("click", () =>
  control("/api/v1/live/stop", "Safely stopping live session"));
elements["replay-toggle"].addEventListener("click", () =>
  control("/api/v1/replay/toggle", "Toggling replay"));
elements["replay-next"].addEventListener("click", () =>
  control("/api/v1/replay/next", "Advancing one frame"));
elements["replay-slower"].addEventListener("click", () =>
  control("/api/v1/replay/speed", "Reducing replay speed", "down"));
elements["replay-faster"].addEventListener("click", () =>
  control("/api/v1/replay/speed", "Increasing replay speed", "up"));
elements["replay-stop"].addEventListener("click", () =>
  control("/api/v1/replay/stop", "Stopping replay"));

function formatDate(epoch) {
  return new Date(Number(epoch) * 1000).toLocaleString();
}

function drawDatasets() {
  elements.datasets.innerHTML = "";
  datasets.forEach((dataset, index) => {
    const button = document.createElement("button");
    button.className = `dataset${index === selectedDataset ? " selected" : ""}`;
    button.setAttribute("role", "option");
    button.setAttribute("aria-selected", index === selectedDataset ? "true" : "false");
    const name = dataset.path.split("/").pop();
    button.innerHTML =
      `<span>${dataset.index}</span><span><span class="name">${escapeHtml(name)}</span>` +
      `<span class="meta">${escapeHtml(formatDate(dataset.modified))}</span></span>` +
      `<span>${humanBytes(dataset.bytes)}</span>`;
    button.addEventListener("click", () => {
      selectedDataset = index;
      elements["dataset-index"].value = dataset.index;
      drawDatasets();
    });
    button.addEventListener("dblclick", openDataset);
    elements.datasets.append(button);
  });
  elements.datasets.children[selectedDataset]?.scrollIntoView({ block: "nearest" });
}

async function loadDatasets() {
  try {
    const text = await api("/api/v1/datasets");
    datasets = text.trim().split(/\r?\n/).filter(Boolean).map((line) => {
      const [index, modified, bytes, path] = line.split("\t");
      return { index: Number(index), modified: Number(modified), bytes: Number(bytes), path };
    });
    selectedDataset = Math.min(selectedDataset, Math.max(0, datasets.length - 1));
    if (datasets[selectedDataset]) {
      elements["dataset-index"].value = datasets[selectedDataset].index;
    }
    drawDatasets();
  } catch (error) {
    setMessage(error.message, true);
  }
}

async function openDataset() {
  const requested = Number(elements["dataset-index"].value);
  const requestedPosition = datasets.findIndex((dataset) => dataset.index === requested);
  if (requestedPosition < 0) {
    setMessage("Enter a dataset number shown in the finalized SVO2 list.", true);
    return;
  }
  selectedDataset = requestedPosition;
  drawDatasets();
  const dataset = datasets[selectedDataset];
  if (!dataset) return;
  await control(
    "/api/v1/replay/select",
    `Opening ${dataset.path.split("/").pop()}`,
    `index=${dataset.index}&loop=${elements["replay-loop"].checked ? 1 : 0}`,
  );
}

elements["datasets-refresh"].addEventListener("click", loadDatasets);
elements["dataset-open"].addEventListener("click", openDataset);
elements["dataset-index"].addEventListener("input", () => {
  const requested = Number(elements["dataset-index"].value);
  const match = datasets.findIndex((dataset) => dataset.index === requested);
  if (match >= 0) {
    selectedDataset = match;
    drawDatasets();
  }
});
elements["dataset-index"].addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    openDataset();
  }
});
elements.datasets.addEventListener("keydown", (event) => {
  if (event.key === "ArrowUp" || event.key === "ArrowDown") {
    event.preventDefault();
    selectedDataset = Math.max(
      0,
      Math.min(datasets.length - 1, selectedDataset + (event.key === "ArrowDown" ? 1 : -1)),
    );
    elements["dataset-index"].value = datasets[selectedDataset]?.index || "";
    drawDatasets();
  } else if (event.key === "Enter") {
    event.preventDefault();
    openDataset();
  }
});

window.addEventListener("keydown", (event) => {
  if (mode !== "replay" || ["INPUT", "BUTTON"].includes(document.activeElement?.tagName)) return;
  if (event.code === "Space") {
    event.preventDefault();
    control("/api/v1/replay/toggle", "Toggling replay");
  } else if (event.key === ".") {
    control("/api/v1/replay/next", "Advancing one frame");
  }
});

function updateStats() {
  for (const name of Object.keys(streams)) {
    const dropped = streams[name].drops + streams[name].queueDrops;
    elements[`${name}-stat`].textContent =
      `${streamRate(name).toFixed(1)} rx / ${renderedRate(name).toFixed(1)} render Hz · ` +
      `${Math.round(streams[name].age)} ms · ${dropped} drops`;
  }
}

if (!token) {
  setMessage("Missing gateway token. Launch this page with scripts/zed_web_console.sh.", true);
} else {
  elements["live-controls"].classList.toggle("hidden", mode !== "live");
  elements["replay-controls"].classList.toggle("hidden", mode !== "replay");
  connectStream("rgb", renderRgb);
  initializeDepth();
  initializeCloud().catch((error) => {
    disableStream("cloud", `3D renderer could not start: ${error.message}`);
  });
  setMutationAvailability(false);
  refreshLease();
  refreshStatus();
  window.setInterval(refreshLease, 5000);
  window.setInterval(refreshStatus, 1000);
  window.setInterval(updateStats, 1000);
  if (mode === "replay") loadDatasets();
}

window.addEventListener("pagehide", () => {
  if (!controllerActive) return;
  fetch("/api/v1/lease/release", {
    method: "POST",
    keepalive: true,
    headers: {
      "X-ZED-Token": token,
      "X-ZED-Controller": controllerId,
    },
  }).catch(() => {});
});
