import { parseEnvelope, STREAM_IDS } from "./protocol.js";

window.__zedAppStarted = true;

const query = new URLSearchParams(window.location.search);
const fragment = new URLSearchParams(window.location.hash.replace(/^#/, ""));
let storedToken = "";
try {
  storedToken = sessionStorage.getItem("zedGatewayToken") || "";
} catch (error) {
  storedToken = "";
}
const token = query.get("token") || fragment.get("token") || storedToken;
const mode = query.get("mode") === "replay" ? "replay" : "live";
let theme = "light";
try {
  theme = localStorage.getItem("zedFieldTheme") === "dark" ? "dark" : "light";
} catch (error) {
  theme = "light";
}
document.documentElement.dataset.theme = theme;
if (token) {
  try {
    sessionStorage.setItem("zedGatewayToken", token);
  } catch (error) {
    // The URL fragment remains the refresh-safe fallback when storage is blocked.
  }
  if (query.has("token") || fragment.get("token") !== token) {
    const clean = new URL(window.location.href);
    clean.searchParams.delete("token");
    const cleanFragment = new URLSearchParams(clean.hash.replace(/^#/, ""));
    cleanFragment.set("token", token);
    clean.hash = cleanFragment.toString();
    history.replaceState({}, "", clean);
  }
}

const elements = Object.fromEntries(
  [
    "connection-pill", "mode-pill", "profile-pill", "recording-banner",
    "controller-pill",
    "record-elapsed", "record-bytes", "record-rate", "rgb-view", "rgb-empty",
    "rgb-health", "rgb-stat", "right-view", "right-empty", "right-health",
    "right-stat", "depth-view", "depth-empty", "depth-health",
    "depth-stat", "depth-range", "depth-hover", "cloud-view", "cloud-empty",
    "cloud-health", "cloud-hover",
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
  right: { id: STREAM_IDS.right, last: 0, received: [], rendered: [], drops: 0, queueDrops: 0, age: 0, socket: null, backoff: 500, disabled: false },
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
let rightUrl = null;
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
    complete && open ? "STREAMING"
      : open ? `CONNECTING ${open}/${available.length}` : "RECONNECTING";
  elements["connection-pill"].className =
    complete && open ? "pill" : "pill warning";
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

async function renderRight(frame) {
  const blob = new Blob([frame.payload], { type: "image/jpeg" });
  const nextUrl = URL.createObjectURL(blob);
  const oldUrl = rightUrl;
  elements["right-view"].onload = () => {
    elements["right-empty"].classList.add("hidden");
    if (oldUrl) URL.revokeObjectURL(oldUrl);
    accountRendered("right", frame);
  };
  elements["right-view"].src = nextUrl;
  rightUrl = nextUrl;
  elements["right-health"].textContent = frame.metadata.frame_id || "live";
}

let depthWorker = null;
let latestDepth = null;

function positionReadout(readout, event, container) {
  readout.classList.remove("hidden");
  const bounds = container.getBoundingClientRect();
  const preferredLeft = event.clientX - bounds.left + 12;
  const preferredTop = event.clientY - bounds.top + 12;
  const maximumLeft = Math.max(6, container.clientWidth - readout.offsetWidth - 6);
  const maximumTop = Math.max(6, container.clientHeight - readout.offsetHeight - 6);
  readout.style.left = `${Math.max(6, Math.min(maximumLeft, preferredLeft))}px`;
  readout.style.top = `${Math.max(6, Math.min(maximumTop, preferredTop))}px`;
}

function depthPixelAt(event) {
  if (!latestDepth) return null;
  const canvas = elements["depth-view"];
  const bounds = canvas.getBoundingClientRect();
  const imageAspect = latestDepth.width / latestDepth.height;
  const boxAspect = bounds.width / bounds.height;
  let displayWidth = bounds.width;
  let displayHeight = bounds.height;
  let offsetX = 0;
  let offsetY = 0;
  if (boxAspect > imageAspect) {
    displayWidth = bounds.height * imageAspect;
    offsetX = (bounds.width - displayWidth) / 2;
  } else {
    displayHeight = bounds.width / imageAspect;
    offsetY = (bounds.height - displayHeight) / 2;
  }
  const localX = event.clientX - bounds.left - offsetX;
  const localY = event.clientY - bounds.top - offsetY;
  if (localX < 0 || localY < 0 || localX >= displayWidth || localY >= displayHeight) {
    return null;
  }
  const x = Math.min(
    latestDepth.width - 1,
    Math.floor(localX / displayWidth * latestDepth.width),
  );
  const y = Math.min(
    latestDepth.height - 1,
    Math.floor(localY / displayHeight * latestDepth.height),
  );
  return { x, y, value: latestDepth.values[y * latestDepth.width + x] };
}

elements["depth-view"].addEventListener("pointermove", (event) => {
  const sample = depthPixelAt(event);
  const readout = elements["depth-hover"];
  if (!sample) {
    readout.classList.add("hidden");
    return;
  }
  readout.textContent = Number.isFinite(sample.value)
    ? `Z DEPTH  ${sample.value.toFixed(sample.value < 10 ? 2 : 1)} m\nPIXEL    ${sample.x}, ${sample.y}`
    : `NO VALID DEPTH\nPIXEL  ${sample.x}, ${sample.y}`;
  positionReadout(readout, event, elements["depth-view"].parentElement);
});
elements["depth-view"].addEventListener("pointerleave", () => {
  elements["depth-hover"].classList.add("hidden");
});

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
        latestDepth = null;
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
        latestDepth = {
          width: event.data.width,
          height: event.data.height,
          values: new Float32Array(event.data.depth),
        };
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
  let hoverPointer = null;
  let cloudPoints = null;
  const projectedPoint = new THREE.Vector3();
  const localPoint = new THREE.Vector3();
  const worldPoint = new THREE.Vector3();
  const clipMatrix = new THREE.Matrix4();

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
    elements["cloud-hover"].classList.add("hidden");
    pointer = { id: event.pointerId, x: event.clientX, y: event.clientY, button: event.button };
    renderer.domElement.setPointerCapture(event.pointerId);
  });
  renderer.domElement.addEventListener("pointermove", (event) => {
    hoverPointer = { clientX: event.clientX, clientY: event.clientY };
    if (!pointer || pointer.id !== event.pointerId) {
      updateCloudHover(hoverPointer);
      return;
    }
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
  renderer.domElement.addEventListener("pointerleave", () => {
    hoverPointer = null;
    elements["cloud-hover"].classList.add("hidden");
  });
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
  const hoverMarkerGeometry = new THREE.BufferGeometry();
  hoverMarkerGeometry.setAttribute(
    "position",
    new THREE.Float32BufferAttribute([0, 0, 0], 3),
  );
  const hoverMarker = new THREE.Points(
    hoverMarkerGeometry,
    new THREE.PointsMaterial({
      color: 0xffdf4d,
      size: 10,
      sizeAttenuation: false,
      depthTest: false,
    }),
  );
  hoverMarker.visible = false;
  hoverMarker.renderOrder = 10;
  scene.add(hoverMarker);

  function updateCloudHover(event) {
    const readout = elements["cloud-hover"];
    if (!cloudPoints || !event) {
      readout.classList.add("hidden");
      hoverMarker.visible = false;
      return;
    }
    const bounds = renderer.domElement.getBoundingClientRect();
    const cursorX = event.clientX - bounds.left;
    const cursorY = event.clientY - bounds.top;
    const positions = cloudPoints.geometry.getAttribute("position");
    cloudPoints.updateMatrixWorld(true);
    camera.updateMatrixWorld(true);
    clipMatrix.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
    clipMatrix.multiply(cloudPoints.matrixWorld);
    let selected = -1;
    let selectedDistanceSquared = 7 * 7;
    for (let index = 0; index < positions.count; index += 1) {
      projectedPoint.set(
        positions.getX(index),
        positions.getY(index),
        positions.getZ(index),
      ).applyMatrix4(clipMatrix);
      if (projectedPoint.z < -1 || projectedPoint.z > 1) continue;
      const screenX = (projectedPoint.x * 0.5 + 0.5) * bounds.width;
      const screenY = (-projectedPoint.y * 0.5 + 0.5) * bounds.height;
      const distanceSquared =
        (screenX - cursorX) ** 2 + (screenY - cursorY) ** 2;
      if (distanceSquared < selectedDistanceSquared) {
        selected = index;
        selectedDistanceSquared = distanceSquared;
      }
    }
    if (selected < 0) {
      readout.classList.add("hidden");
      hoverMarker.visible = false;
      return;
    }
    localPoint.set(
      positions.getX(selected),
      positions.getY(selected),
      positions.getZ(selected),
    );
    worldPoint.copy(localPoint).applyMatrix4(cloudPoints.matrixWorld);
    const { x, y, z } = worldPoint;
    const range = Math.hypot(x, y, z);
    const decimals = range < 10 ? 2 : range < 100 ? 1 : 0;
    hoverMarkerGeometry.getAttribute("position").setXYZ(0, x, y, z);
    hoverMarkerGeometry.getAttribute("position").needsUpdate = true;
    hoverMarker.visible = true;
    readout.textContent =
      `RANGE  ${range.toFixed(decimals)} m\n` +
      `X FWD  ${x.toFixed(decimals)} m\n` +
      `Y LEFT ${y.toFixed(decimals)} m\n` +
      `Z UP   ${z.toFixed(decimals)} m`;
    positionReadout(readout, event, elements["cloud-view"]);
  }

  function resetView() {
    target.set(0, 0, 0);
    radius = 5;
    azimuth = Math.PI;
    elevation = 0.35;
    updateCamera();
  }
  resetView();
  elements["reset-view"].addEventListener("click", resetView);

  const cloudWorker = new Worker("/cloud_worker.js", { type: "module" });
  let pendingCloudMetadata = null;

  function submitCloud(frame) {
    const declaredPoints =
      (Number(frame.metadata.width) || 0) * (Number(frame.metadata.height) || 0);
    if (declaredPoints < 32) {
      if (cloudPoints) {
        scene.remove(cloudPoints);
        cloudPoints.geometry.dispose();
        cloudPoints.material.dispose();
        cloudPoints = null;
      }
      elements["cloud-health"].textContent = `${declaredPoints} valid points · too sparse`;
      elements["cloud-empty"].textContent =
        `WAITING FOR VALID DEPTH\n${declaredPoints} points available`;
      elements["cloud-empty"].classList.remove("error", "hidden");
      return;
    }
    if (cloudPending) {
      if (cloudQueued) streams.cloud.queueDrops += 1;
      cloudQueued = frame;
      return;
    }
    cloudPending = true;
    cloudPendingFrame = frame;
    pendingCloudMetadata = frame.metadata;
    cloudWorker.postMessage(
      {
        id: frame.sequence,
        payload: frame.payload,
        format: frame.metadata.format,
        expectedPoints: declaredPoints,
      },
      [frame.payload],
    );
  }

  cloudWorker.onmessage = (event) => {
    cloudPending = false;
    if (event.data.error) {
      setMessage(`Point-cloud decoder: ${event.data.error}`, true);
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
      const nearest = Number(event.data.nearestRange);
      elements["cloud-health"].textContent =
        `${event.data.count.toLocaleString()} points · ` +
        `${Number.isFinite(nearest) ? `nearest ${nearest.toFixed(nearest < 10 ? 2 : 1)} m · ` : ""}` +
        `${pendingCloudMetadata?.frame_id || "live"}`;
      updateCloudHover(hoverPointer);
      accountRendered("cloud", cloudPendingFrame);
    }
    cloudPendingFrame = null;
    if (cloudQueued) {
      const queued = cloudQueued;
      cloudQueued = null;
      submitCloud(queued);
    }
  };
  cloudWorker.onerror = (event) => {
    disableStream("cloud", `Point-cloud decoder failed: ${event.message || "worker error"}`);
  };

  let resizeFrame = 0;
  let renderedWidth = 0;
  let renderedHeight = 0;

  function resizeCloud() {
    resizeFrame = 0;
    const area = elements["cloud-view"];
    const width = Math.max(1, area.clientWidth);
    const height = Math.max(1, area.clientHeight);
    if (width === renderedWidth && height === renderedHeight) return;
    renderedWidth = width;
    renderedHeight = height;
    // Keep the Retina-resolution drawing buffer while sizing the DOM canvas
    // to the pane's logical CSS dimensions. Without this, a 2x DPR canvas is
    // clipped to its upper-left quarter and the view center appears bottom-right.
    renderer.setSize(width, height, true);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  }

  function scheduleCloudResize() {
    if (!resizeFrame) resizeFrame = requestAnimationFrame(resizeCloud);
  }

  if (typeof ResizeObserver === "function") {
    new ResizeObserver(scheduleCloudResize).observe(elements["cloud-view"]);
  } else {
    window.addEventListener("resize", scheduleCloudResize);
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
  connectStream("right", renderRight);
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
