// The legacy build includes compatibility shims required by some HarmonyOS
// browser versions (notably Promise.withResolvers). Keep it local so the
// document never leaves the user's network.
import * as pdfjsLib from "/pdfjs/pdf.legacy.mjs";
import {
  boundedCanvasPixelRatio,
  createProtocolClient,
  documentMatches,
  normalizePDFViewport,
  scaledCursorDiameter,
  sha256Hex,
  viewportAnchorPage,
  viewportDocumentEdges,
} from "/inkbridge-protocol.js";

pdfjsLib.GlobalWorkerOptions.workerSrc = "/pdfjs/pdf.worker.legacy.mjs";

const params = new URLSearchParams(location.search);
const room = (params.get("room") || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
const nativeInput = params.get("nativeInput") === "true";
const nativeTransport = ["wifi", "usb"].includes(params.get("transport"))
  ? params.get("transport")
  : "";
const nativeTransportPreference = ["automatic", "wifi", "usb"].includes(params.get("transportPreference"))
  ? params.get("transportPreference")
  : "wifi";
const nativeTransportRequestId = (params.get("transportRequestId") || "").replace(/[^A-Za-z0-9._:-]/g, "").slice(0, 72);
const protocol = createProtocolClient("pdfpad");
const app = document.querySelector("#pdfPadApp");
const scroll = document.querySelector("#pdfScroll");
const pagesElement = document.querySelector("#pdfPages");
const loading = document.querySelector("#pdfLoading");
const documentName = document.querySelector("#pdfDocumentName");
const connectionText = document.querySelector("#pdfConnectionText");
const connectionDot = document.querySelector("#pdfConnectionDot");
const zoomValue = document.querySelector("#pdfZoomValue");

document.documentElement.classList.add("pdf-pad-mode");
if (nativeInput) document.documentElement.classList.add("native-pad-mode");
app.hidden = false;

const state = {
  socket: null,
  reconnect: null,
  pdf: null,
  loadingPDF: false,
  pdfLoadGeneration: 0,
  pdfFetchController: null,
  pdfLoadingTask: null,
  pendingDocument: null,
  documentId: "",
  documentVersion: 0,
  documentHash: "",
  pages: new Map(),
  log: [],
  historyCursor: 0,
  historyRevision: 0,
  active: new Map(),
  liveHighlighters: new Map(),
  renderedStrokeSequences: new Map(),
  drawing: null,
  penIsDown: false,
  touchScroll: null,
  touches: new Map(),
  pinch: null,
  pinchPending: false,
  pendingPinchAnchor: null,
  zoom: 1,
  renderedZoom: 1,
  preview: { scale: 1, translateX: 0, translateY: 0 },
  applyingViewport: false,
  remoteViewportGeneration: 0,
  remoteViewportQueued: null,
  remoteViewportWorkerRunning: false,
  remoteViewportFrame: null,
  remotePreviewCommitTimer: null,
  viewportTimer: null,
  viewportPending: false,
  scrollFallbackEndTimer: null,
  lastViewportSentAt: 0,
  localViewportInteraction: null,
  zoomCommitGeneration: 0,
  inertiaFrame: null,
  inertia: null,
  retryTimer: null,
  lastDocumentName: "",
  color: "#152441",
  width: 3.5,
  tool: "ink",
  highlighterWidth: 14,
  highlighterOpacity: 0.32,
  highlighterColor: "#FFE55B",
  eraserSize: 48,
  manualEraser: false,
  hoverFrame: null,
  pendingHover: null,
  nativeMoveFrame: null,
  nativePendingSamples: [],
  strokeOutbox: new Map(),
  strokeAckByMessageId: new Map(),
  awaitingSnapshot: true,
  connected: false,
  pendingViewport: null,
  appMode: "pdf",
};

// Cap viewport traffic at 120 Hz. requestAnimationFrame and the timer cadence
// naturally fall back to the physical refresh rate, so a 60/90 Hz display
// never accumulates synthetic frames while a 120/144 Hz panel stays fluid.
const VIEWPORT_SYNC_INTERVAL = 1000 / 120;
const INERTIA_DECAY_PER_MS = 0.0042;
const INERTIA_START_SPEED = 0.06;
const INERTIA_STOP_SPEED = 0.025;
const PEN_HOVER_SIZE = 7;
const HIGHLIGHTER_HOLD_DELAY_MS = 2000;
const HIGHLIGHTER_HOLD_SLOP_PX = 18;

function nativeState() {
  return {
    connected: state.connected,
    documentName: state.lastDocumentName || "等待 Mac 打开 PDF",
    zoom: state.zoom,
    color: state.color,
    width: state.width,
    eraser: state.manualEraser,
    tool: state.manualEraser ? "eraser" : state.tool,
    highlighterWidth: state.highlighterWidth,
    highlighterOpacity: state.highlighterOpacity,
    eraserSize: state.eraserSize,
    mode: state.appMode,
    canUndo: state.historyCursor > 0,
    canRedo: state.historyCursor < historyOperations().length,
  };
}

function notifyNativeState() {
  try {
    window.__nativeHost?.postMessage(JSON.stringify({ type: "state", ...nativeState() }));
  } catch (_) {}
}

function notifyNativeMode(mode) {
  try {
    window.__nativeHost?.postMessage(JSON.stringify({ type: "mode", mode }));
  } catch (_) {}
}

function notifyNativeTransportRequest(message) {
  if (!nativeInput || !window.__nativeHost?.postMessage) return;
  try {
    window.__nativeHost.postMessage(JSON.stringify({
      type: "transport",
      mode: message.transport,
      preference: message.transportPreference,
      requestId: message.requestId,
    }));
  } catch (_) {}
}

function reportNativeTransportStatus(mode = nativeTransport, requestId = nativeTransportRequestId) {
  if (!nativeInput || !["wifi", "usb"].includes(mode)) return;
  send({
    type: "transport:status",
    transport: mode,
    transportPreference: nativeTransportPreference,
    requestId: requestId || undefined,
    deviceId: protocol.clientId,
  });
}

function notifyNativeScreenMirrorRequest(message) {
  if (!nativeInput || !window.__nativeHost?.postMessage) return;
  try {
    window.__nativeHost.postMessage(JSON.stringify({
      type: "screenMirror",
      action: message.action,
      requestId: message.requestId,
    }));
  } catch (_) {}
}

function reportNativeScreenMirrorStatus(status, requestId = "", error = "") {
  if (!nativeInput || !["started", "stopped", "failed"].includes(status)) return;
  send({
    type: "screen-mirror:status",
    status,
    requestId: requestId || undefined,
    error: error || undefined,
  });
}

function requestNativeScreenMirror(action, requestId = "") {
  if (!nativeInput || !["start", "stop"].includes(action)) return;
  send({
    type: "screen-mirror:request",
    action,
    requestId: requestId || undefined,
  });
}

function notifyNativeRoundTripOpen(message) {
  if (!nativeInput || !window.__nativeHost?.postMessage) return;
  try {
    window.__nativeHost.postMessage(JSON.stringify({
      type: "roundTripOpen",
      roundTripId: message.roundTripId,
      name: message.name,
      documentId: message.documentId,
      documentVersion: message.documentVersion,
      documentHash: message.documentHash,
    }));
  } catch (_) {}
}

function setConnection(kind, text) {
  connectionDot.className = kind || "";
  connectionText.textContent = text;
}

function scopedMessage(message) {
  const pdfScoped = message.type?.startsWith("pdf:")
    || message.type?.startsWith("stroke:")
    || message.type?.startsWith("history:")
    || message.type?.startsWith("cursor:")
    || (message.type === "clear" && (message.mode === "pdf" || state.appMode === "pdf"));
  const scopeDocumentId = message.documentId || state.documentId;
  const scopeDocumentVersion = Number(message.documentVersion || state.documentVersion || 0);
  const scopeDocumentHash = message.documentHash || state.documentHash;
  return pdfScoped && scopeDocumentId
    ? {
      ...message,
      documentId: scopeDocumentId,
      documentVersion: scopeDocumentVersion,
      documentHash: scopeDocumentHash,
    }
    : message;
}

function transmit(message) {
  if (state.socket?.readyState !== WebSocket.OPEN
    || (state.awaitingSnapshot && message.type?.startsWith("stroke:"))) return false;
  const prepared = protocol.prepare(message);
  state.socket.send(JSON.stringify(prepared));
  if (message.type === "stroke:end" && message.strokeId) {
    state.strokeAckByMessageId.set(prepared.messageId, message.strokeId);
  }
  return true;
}

function rememberStroke(message) {
  if (!message.strokeId) return;
  const events = state.strokeOutbox.get(message.strokeId) || [];
  events.push(message);
  state.strokeOutbox.set(message.strokeId, events);
}

function acknowledgeStroke(message) {
  const strokeId = state.strokeAckByMessageId.get(message.ackMessageId);
  if (!strokeId) return;
  state.strokeAckByMessageId.delete(message.ackMessageId);
  if (typeof message.status === "string") {
    state.strokeOutbox.delete(strokeId);
  }
}

function replayStrokeOutbox() {
  if (state.awaitingSnapshot) return;
  for (const [strokeId, events] of [...state.strokeOutbox]) {
    const relevant = events.filter((event) => documentMatches(event, state));
    if (!relevant.length) {
      state.strokeOutbox.delete(strokeId);
      continue;
    }
    for (const event of relevant) {
      renderMessage(event);
      transmit(event);
    }
  }
}

function send(message) {
  const scoped = scopedMessage(message);
  if (scoped.type === "clear") {
    state.strokeOutbox.clear();
    state.strokeAckByMessageId.clear();
  }
  if (scoped.type?.startsWith("stroke:")) rememberStroke(scoped);
  transmit(scoped);
}

function descriptorFrom(documentOrName, legacyDocumentId = "") {
  const descriptor = typeof documentOrName === "object" && documentOrName
    ? documentOrName
    : {
      name: documentOrName,
      documentId: legacyDocumentId,
      documentVersion: legacyDocumentId ? 1 : 0,
      documentHash: "",
    };
  return {
    name: descriptor.name || state.lastDocumentName || "document.pdf",
    documentId: descriptor.documentId || "",
    documentVersion: Number(descriptor.documentVersion || 0),
    documentHash: descriptor.documentHash || "",
    documentSize: Math.max(0, Number(descriptor.documentSize || 0)),
    transactionId: descriptor.transactionId || "",
    restoreAvailable: Boolean(descriptor.restoreAvailable),
  };
}

function descriptorMatches(message, descriptor) {
  if (!message || !descriptor?.documentId) return false;
  return message.documentId === descriptor.documentId
    && Number(message.documentVersion || 0) === descriptor.documentVersion
    && (!message.documentHash || !descriptor.documentHash || message.documentHash === descriptor.documentHash);
}

function reportDocumentProgress(descriptor, phase, loadedBytes, totalBytes, progress) {
  const safeTotal = Math.max(0, Number(totalBytes || 0));
  const safeLoaded = Math.max(0, Number(loadedBytes || 0));
  send({
    type: "pdf:progress",
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    transactionId: descriptor.transactionId,
    phase,
    loadedBytes: safeLoaded,
    totalBytes: safeTotal,
    progress: Math.max(0, Math.min(1, Number(progress || 0))),
  });
}

function clearInkCanvas(view) {
  view.inkContext.save();
  view.inkContext.setTransform(view.pixelRatio, 0, 0, view.pixelRatio, 0, 0);
  view.inkContext.clearRect(0, 0, view.width, view.height);
  view.inkContext.restore();
}

function clearLiveInkCanvas(view) {
  if (!view?.liveInkContext) return;
  view.liveInkContext.save();
  view.liveInkContext.setTransform(view.pixelRatio, 0, 0, view.pixelRatio, 0, 0);
  view.liveInkContext.clearRect(0, 0, view.width, view.height);
  view.liveInkContext.restore();
  view.liveInkCanvas.style.opacity = "1";
  view.liveHighlighterStrokeId = "";
}

function prepareLiveInkCanvas(view) {
  if (!view?.liveInkCanvas) return;
  const width = Math.max(1, Math.ceil(view.width * view.pixelRatio));
  const height = Math.max(1, Math.ceil(view.height * view.pixelRatio));
  if (view.liveInkCanvas.width !== width || view.liveInkCanvas.height !== height) {
    view.liveInkCanvas.width = width;
    view.liveInkCanvas.height = height;
    view.liveInkContext.setTransform(view.pixelRatio, 0, 0, view.pixelRatio, 0, 0);
    view.liveInkCanvas.style.opacity = "1";
    view.liveHighlighterStrokeId = "";
  }
}

function releaseLiveInkCanvas(pageIndex) {
  const stillActive = [...state.liveHighlighters.values()]
    .some((stroke) => stroke.pageIndex === pageIndex);
  if (stillActive) return;
  const view = state.pages.get(pageIndex);
  if (!view?.liveInkCanvas) return;
  view.liveInkCanvas.width = 1;
  view.liveInkCanvas.height = 1;
  view.liveInkCanvas.style.opacity = "1";
  view.liveHighlighterStrokeId = "";
}

function historyOperations(messages = state.log) {
  const operations = [];
  const byId = new Map();
  for (const message of messages) {
    if (!message || (message.type !== "clear" && !message.type?.startsWith("stroke:"))) continue;
    const operationId = message.operationId
      || (message.type.startsWith("stroke:") && message.strokeId ? `stroke:${message.strokeId}` : `clear:${operations.length}`);
    let operation = byId.get(operationId);
    if (!operation) {
      operation = { operationId, events: [] };
      byId.set(operationId, operation);
      operations.push(operation);
    }
    operation.events.push(message);
  }
  return operations;
}

function effectiveStrokeEvents(events) {
  let replaceIndex = -1;
  for (let index = 0; index < events.length; index += 1) {
    if (events[index].type === "stroke:replace") replaceIndex = index;
  }
  return replaceIndex >= 0 ? events.slice(replaceIndex) : events;
}

function truncateRedoHistory() {
  const operations = historyOperations();
  if (state.historyCursor >= operations.length) return;
  state.log = operations.slice(0, state.historyCursor).flatMap((operation) => operation.events);
}

function recordHistoryMessage(message) {
  if (message.type === "clear" || message.type === "stroke:start") truncateRedoHistory();
  state.log.push(message);
  if (message.type === "clear" || message.type === "stroke:end") {
    state.historyCursor = historyOperations().length;
    setToolButtons();
    notifyNativeState();
  }
}

function pressureWidth(point, width, tool) {
  if (tool === "eraser") return state.eraserSize;
  if (tool === "highlighter") return Math.max(1.2, width);
  const pressure = Number.isFinite(point.p) && point.p > 0 ? point.p : 0.52;
  return Math.max(1.1, width * (0.4 + pressure * 0.9));
}

function widthRatioForView(view) {
  if (state.tool === "highlighter") return state.highlighterWidth / Math.max(1, view.width);
  return state.width / Math.max(1, view.width);
}

function drawDot(view, point, stroke) {
  const ctx = view.inkContext;
  ctx.save();
  ctx.globalCompositeOperation = stroke.tool === "eraser" ? "destination-out" : "source-over";
  ctx.globalAlpha = stroke.tool === "highlighter" ? stroke.opacity : 1;
  ctx.fillStyle = stroke.color;
  ctx.beginPath();
  ctx.arc(point.x * view.width, point.y * view.height, pressureWidth(point, stroke.width, stroke.tool) / 2, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

function drawSegment(view, before, point, stroke) {
  const ctx = view.inkContext;
  ctx.save();
  ctx.globalCompositeOperation = stroke.tool === "eraser" ? "destination-out" : "source-over";
  ctx.globalAlpha = stroke.tool === "highlighter" ? stroke.opacity : 1;
  ctx.strokeStyle = stroke.color;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.lineWidth = pressureWidth({ p: (before.p + point.p) / 2 }, stroke.width, stroke.tool);
  ctx.beginPath();
  ctx.moveTo(before.x * view.width, before.y * view.height);
  ctx.lineTo(point.x * view.width, point.y * view.height);
  ctx.stroke();
  ctx.restore();
}

function drawHighlighterPath(view, points, stroke, context = view?.inkContext) {
  if (!view || !points.length) return;
  const ctx = context;
  if (!ctx) return;
  const first = points[0];
  ctx.save();
  ctx.globalCompositeOperation = "source-over";
  ctx.globalAlpha = stroke.opacity;
  ctx.strokeStyle = stroke.color;
  ctx.fillStyle = stroke.color;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.lineWidth = Math.max(1.2, stroke.width);
  if (points.length === 1) {
    ctx.beginPath();
    ctx.arc(first.x * view.width, first.y * view.height, ctx.lineWidth / 2, 0, Math.PI * 2);
    ctx.fill();
  } else {
    ctx.beginPath();
    ctx.moveTo(first.x * view.width, first.y * view.height);
    for (const point of points.slice(1)) ctx.lineTo(point.x * view.width, point.y * view.height);
    ctx.stroke();
  }
  ctx.restore();
}

function redrawLiveHighlighters(pageIndex = null) {
  const pageIndexes = Number.isInteger(pageIndex) ? [pageIndex] : [...state.pages.keys()];
  for (const targetPageIndex of pageIndexes) {
    const view = state.pages.get(targetPageIndex);
    if (!view) continue;
    clearLiveInkCanvas(view);
    const strokes = [...state.liveHighlighters.entries()]
      .filter(([, stroke]) => stroke.pageIndex === targetPageIndex);
    if (!strokes.length) continue;
    prepareLiveInkCanvas(view);
    if (strokes.length === 1) {
      const [strokeId, stroke] = strokes[0];
      // Keep the live mask opaque and apply opacity once at the canvas layer.
      // Incremental segments can then overlap at their joins without making
      // the highlighter darker than the final committed single-pass path.
      view.liveInkCanvas.style.opacity = String(stroke.opacity);
      view.liveHighlighterStrokeId = strokeId;
      drawHighlighterPath(view, stroke.points, { ...stroke, opacity: 1 }, view.liveInkContext);
    } else {
      for (const [, stroke] of strokes) {
        drawHighlighterPath(view, stroke.points, stroke, view.liveInkContext);
      }
    }
    for (const [strokeId, stroke] of strokes) {
      if (Number.isInteger(stroke.maximumSequence)) {
        state.renderedStrokeSequences.set(strokeId, stroke.maximumSequence);
      }
    }
  }
}

function appendLiveHighlighter(strokeId, stroke, previousPointCount, forceRedraw = false) {
  const view = state.pages.get(stroke.pageIndex);
  if (!view) return;
  const liveCount = [...state.liveHighlighters.values()]
    .filter((candidate) => candidate.pageIndex === stroke.pageIndex).length;
  if (forceRedraw || liveCount !== 1 || view.liveHighlighterStrokeId !== strokeId) {
    redrawLiveHighlighters(stroke.pageIndex);
    return;
  }
  prepareLiveInkCanvas(view);
  view.liveInkCanvas.style.opacity = String(stroke.opacity);
  const firstNewIndex = Math.max(0, previousPointCount - 1);
  const incrementalPoints = stroke.points.slice(firstNewIndex);
  if (incrementalPoints.length > 1) {
    drawHighlighterPath(view, incrementalPoints, { ...stroke, opacity: 1 }, view.liveInkContext);
  }
}

function renderLiveHighlighter(message) {
  const stroke = state.liveHighlighters.get(message.strokeId) || {
    pageIndex: message.pageIndex,
    color: message.color || state.highlighterColor,
    width: message.width || state.highlighterWidth,
    tool: "highlighter",
    opacity: Number.isFinite(message.opacity) ? message.opacity : state.highlighterOpacity,
    points: [],
    maximumSequence: -1,
  };
  const previousPointCount = stroke.points.length;
  const previousStyle = `${stroke.color}:${stroke.width}:${stroke.opacity}`;
  if (Number.isInteger(message.pageIndex)) stroke.pageIndex = message.pageIndex;
  if (message.color) stroke.color = message.color;
  if (Number.isFinite(message.width)) stroke.width = message.width;
  if (Number.isFinite(message.opacity)) stroke.opacity = Math.max(0.05, Math.min(1, message.opacity));
  const replaced = message.type === "stroke:replace";
  if (replaced) stroke.points.length = 0;
  const next = message.type === "stroke:move" || message.type === "stroke:replace"
    ? message.points
    : [message.point];
  for (const point of next || []) {
    if (point && Number.isFinite(point.x) && Number.isFinite(point.y)) stroke.points.push(point);
  }
  if (Number.isInteger(message.strokeSequence)) {
    stroke.maximumSequence = Math.max(stroke.maximumSequence, message.strokeSequence);
    state.renderedStrokeSequences.set(message.strokeId, stroke.maximumSequence);
  }
  if (message.type === "stroke:end") {
    const pageIndex = stroke.pageIndex;
    state.liveHighlighters.delete(message.strokeId);
    clearLiveInkCanvas(state.pages.get(pageIndex));
    drawHighlighterPath(state.pages.get(pageIndex), stroke.points, stroke);
    releaseLiveInkCanvas(pageIndex);
    redrawLiveHighlighters(pageIndex);
    return;
  }
  state.liveHighlighters.set(message.strokeId, stroke);
  const styleChanged = previousStyle !== `${stroke.color}:${stroke.width}:${stroke.opacity}`;
  appendLiveHighlighter(message.strokeId, stroke, replaced ? 0 : previousPointCount, replaced || styleChanged);
}

function applyHighlighterOperation(events) {
  const seed = events.find((message) => Number.isInteger(message.pageIndex));
  if (!seed || !documentMatches(seed, state)) return;
  const stroke = {
    pageIndex: seed.pageIndex,
    color: seed.color || state.highlighterColor,
    width: seed.width || state.highlighterWidth,
    tool: "highlighter",
    opacity: Number.isFinite(seed.opacity) ? seed.opacity : state.highlighterOpacity,
    last: null,
  };
  const points = [];
  let ended = false;
  let maximumSequence = -1;
  for (const message of events) {
    if (message.color) stroke.color = message.color;
    if (Number.isFinite(message.width)) stroke.width = message.width;
    if (Number.isFinite(message.opacity)) stroke.opacity = Math.max(0.05, Math.min(1, message.opacity));
    if (message.type === "stroke:replace") points.length = 0;
    const next = message.type === "stroke:move" || message.type === "stroke:replace"
      ? message.points
      : [message.point];
    for (const point of next || []) {
      if (point && Number.isFinite(point.x) && Number.isFinite(point.y)) points.push(point);
    }
    if (Number.isInteger(message.strokeSequence)) maximumSequence = Math.max(maximumSequence, message.strokeSequence);
    if (message.type === "stroke:end") ended = true;
  }
  const view = state.pages.get(stroke.pageIndex);
  drawHighlighterPath(view, points, stroke);
  stroke.last = points[points.length - 1] || null;
  if (maximumSequence >= 0) state.renderedStrokeSequences.set(seed.strokeId, maximumSequence);
  if (ended) state.active.delete(seed.strokeId);
  else state.active.set(seed.strokeId, stroke);
}

function applyRenderedMessage(message) {
  if (!documentMatches(message, state)) return;
  if (message.type === "clear") {
    state.active.clear();
    state.liveHighlighters.clear();
    state.renderedStrokeSequences.clear();
    state.pages.forEach(clearInkCanvas);
    state.pages.forEach(clearLiveInkCanvas);
    return;
  }
  if (!message.type?.startsWith("stroke:") || !Number.isInteger(message.pageIndex)) return;
  if (Number.isInteger(message.strokeSequence)) {
    const previous = state.renderedStrokeSequences.get(message.strokeId);
    if (Number.isInteger(previous) && message.strokeSequence <= previous) return;
    state.renderedStrokeSequences.set(message.strokeId, message.strokeSequence);
  }
  const stroke = state.active.get(message.strokeId) || {
    pageIndex: message.pageIndex,
    color: message.color || state.color,
    width: message.width || state.width,
    tool: ["ink", "highlighter", "eraser"].includes(message.tool) ? message.tool : "ink",
    opacity: Number.isFinite(message.opacity) ? message.opacity : 1,
    last: null,
  };
  if (["ink", "highlighter", "eraser"].includes(message.tool)) stroke.tool = message.tool;
  if (Number.isFinite(message.opacity)) stroke.opacity = Math.max(0.05, Math.min(1, message.opacity));
  if (message.type === "stroke:replace") stroke.last = null;
  const points = message.type === "stroke:move" || message.type === "stroke:replace"
    ? message.points
    : [message.point];
  const view = state.pages.get(stroke.pageIndex);
  for (const point of points || []) {
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) continue;
    if (view) {
      if (stroke.last) drawSegment(view, stroke.last, point, stroke);
      else drawDot(view, point, stroke);
    }
    stroke.last = point;
  }
  if (message.type === "stroke:end") state.active.delete(message.strokeId);
  else state.active.set(message.strokeId, stroke);
}

function renderMessage(message, save = true) {
  if (!documentMatches(message, state)) return;
  if (save && (message.type === "clear" || message.type?.startsWith("stroke:"))) {
    recordHistoryMessage(message);
  }
  const activeTool = state.liveHighlighters.get(message.strokeId)?.tool
    || state.active.get(message.strokeId)?.tool;
  if (message.tool === "highlighter" || activeTool === "highlighter") {
    renderLiveHighlighter(message);
  }
  else if (message.type === "stroke:replace") {
    redrawInk(true);
  }
  else applyRenderedMessage(message);
}

function redrawInk(includePending = false) {
  state.pages.forEach(clearInkCanvas);
  state.active.clear();
  state.renderedStrokeSequences.clear();
  const operations = historyOperations();
  state.historyCursor = Math.max(0, Math.min(operations.length, state.historyCursor));
  const visibleOperations = operations.slice(0, state.historyCursor);
  if (includePending) {
    for (const operation of operations.slice(state.historyCursor)) {
      if (!operation.events.some((event) => event.type === "stroke:end")) visibleOperations.push(operation);
    }
  }
  for (const operation of visibleOperations) {
    const events = effectiveStrokeEvents(operation.events);
    if (events.some((message) => message.tool === "highlighter")) applyHighlighterOperation(events);
    else for (const message of events) applyRenderedMessage(message);
  }
  redrawLiveHighlighters();
  notifyNativeState();
}

function applyHistoryState(message) {
  const operations = historyOperations();
  const requested = Number(message.historyCursor);
  if (Number.isInteger(requested)) {
    state.historyCursor = Math.max(0, Math.min(operations.length, requested));
  } else if (message.type === "history:undo") {
    state.historyCursor = Math.max(0, state.historyCursor - 1);
  } else if (message.type === "history:redo") {
    state.historyCursor = Math.min(operations.length, state.historyCursor + 1);
  }
  if (Number.isFinite(message.historyRevision)) {
    state.historyRevision = Math.max(state.historyRevision, message.historyRevision);
  }
  redrawInk();
}

function requestHistoryChange(type) {
  if (type !== "history:undo" && type !== "history:redo") return;
  send({ type, mode: "pdf" });
}

function pointInPage(event, view) {
  const rect = view.inkCanvas.getBoundingClientRect();
  return {
    x: Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width)),
    y: Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height)),
    p: event.pointerType === "pen" ? Math.max(0.08, event.pressure || 0.52) : 0.52,
  };
}

function pointFromClient(x, y, pressure, view, metadata = null) {
  const rect = view.inkCanvas.getBoundingClientRect();
  const rawPressure = Number(pressure);
  const point = {
    x: Math.max(0, Math.min(1, (x - rect.left) / rect.width)),
    y: Math.max(0, Math.min(1, (y - rect.top) / rect.height)),
    p: Number.isFinite(rawPressure) ? Math.max(0.08, Math.min(1, rawPressure || 0.52)) : 0.52,
  };
  const tiltX = Number(metadata?.tiltX);
  const tiltY = Number(metadata?.tiltY);
  const rollAngle = Number(metadata?.rollAngle);
  const timestamp = Number(metadata?.timestamp);
  const sampleIndex = Number(metadata?.sampleIndex);
  if (Number.isFinite(tiltX)) point.tiltX = Math.max(-90, Math.min(90, tiltX));
  if (Number.isFinite(tiltY)) point.tiltY = Math.max(-90, Math.min(90, tiltY));
  if (Number.isFinite(rollAngle)) point.rollAngle = Math.max(-360, Math.min(360, rollAngle));
  if (Number.isFinite(timestamp) && timestamp >= 0) point.timestamp = timestamp;
  if (Number.isInteger(sampleIndex) && sampleIndex >= 0) point.sampleIndex = sampleIndex;
  return point;
}

function viewAtClientPoint(x, y) {
  for (const view of state.pages.values()) {
    const rect = view.inkCanvas.getBoundingClientRect();
    if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) return view;
  }
  return null;
}

function pageRenderZoom(view) {
  return Number.isFinite(view?.renderZoom) && view.renderZoom > 0
    ? view.renderZoom
    : state.renderedZoom;
}

function penHoverSize() {
  return PEN_HOVER_SIZE;
}

function eraserDisplaySize(view) {
  return scaledCursorDiameter(state.eraserSize, pageRenderZoom(view));
}

function eraserRatioForView(view) {
  return eraserDisplaySize(view) / Math.max(1, Math.min(view.width, view.height));
}

function showHover(view, point, options = {}) {
  if (!view?.hoverCursor || !point) return;
  const tool = options.tool || (state.manualEraser ? "eraser" : "ink");
  const size = Number.isFinite(options.size)
    ? options.size
    : (tool === "eraser" ? eraserDisplaySize(view) : penHoverSize());
  for (const candidate of state.pages.values()) {
    if (candidate !== view && candidate.hoverCursor) candidate.hoverCursor.hidden = true;
  }
  view.hoverCursor.hidden = false;
  view.hoverCursor.classList.toggle("is-eraser", tool === "eraser");
  view.hoverCursor.style.width = `${size}px`;
  view.hoverCursor.style.height = `${size}px`;
  view.hoverCursor.style.left = `${point.x * view.width}px`;
  view.hoverCursor.style.top = `${point.y * view.height}px`;
}

function hideHover() {
  state.pendingHover = null;
  for (const view of state.pages.values()) if (view.hoverCursor) view.hoverCursor.hidden = true;
}

function queueHover(event, view) {
  if (event.pointerType !== "pen" || state.drawing) return;
  const point = pointInPage(event, view);
  const tool = state.manualEraser ? "eraser" : state.tool;
  showHover(view, point, { tool });
  state.pendingHover = {
    pageIndex: view.index,
    point,
    tool,
    eraserSize: tool === "eraser" ? state.eraserSize : undefined,
    eraserRatio: tool === "eraser" ? eraserRatioForView(view) : undefined,
  };
  if (state.hoverFrame) return;
  state.hoverFrame = requestAnimationFrame(() => {
    state.hoverFrame = null;
    const hover = state.pendingHover;
    state.pendingHover = null;
    if (hover) send({ type: "cursor:move", ...hover });
  });
}

function sendHoverHidden() {
  hideHover();
  send({ type: "cursor:hide" });
}

function releaseTouchCaptures() {
  for (const touch of state.touches.values()) {
    if (scroll.hasPointerCapture?.(touch.pointerId)) scroll.releasePointerCapture(touch.pointerId);
  }
}

function startStroke(event, view) {
  if (state.drawing || event.pointerType !== "pen") return;
  event.preventDefault();
  sendHoverHidden();
  stopInertia(true);
  const needsPinchCommit = Boolean(state.pinch || state.pinchPending);
  const pinchAnchor = state.pinch?.anchor || state.pendingPinchAnchor;
  releaseTouchCaptures();
  state.touchScroll = null;
  state.touches.clear();
  state.pinch = null;
  state.pinchPending = false;
  state.pendingPinchAnchor = null;
  if (needsPinchCommit) void commitPinchZoom(pinchAnchor);
  state.penIsDown = true;
  view.inkCanvas.setPointerCapture(event.pointerId);
  const strokeId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const tool = state.manualEraser ? "eraser" : state.tool;
  state.drawing = {
    pointerId: event.pointerId,
    strokeId,
    pageIndex: view.index,
    tool,
    strokeSequence: 0,
  };
  const message = {
    type: "stroke:start", strokeId, pageIndex: view.index,
    color: tool === "highlighter" ? state.highlighterColor : state.color,
    width: tool === "highlighter" ? state.highlighterWidth : state.width,
    widthRatio: widthRatioForView(view),
    opacity: tool === "highlighter" ? state.highlighterOpacity : 1,
    tool, eraserSize: state.eraserSize,
    eraserRatio: eraserRatioForView(view),
    strokeSequence: 0,
    point: pointInPage(event, view),
  };
  renderMessage(message);
  send(message);
  if (tool === "eraser") showHover(view, message.point, { tool, size: eraserDisplaySize(view) });
}

function moveStroke(event, view) {
  if (!state.drawing || state.drawing.pointerId !== event.pointerId) return;
  event.preventDefault();
  const samples = event.getCoalescedEvents ? event.getCoalescedEvents() : [event];
  const points = [...samples].map((sample) => pointInPage(sample, view));
  while (points.length) {
    const message = {
      type: "stroke:move", strokeId: state.drawing.strokeId, pageIndex: state.drawing.pageIndex,
      tool: state.drawing.tool, eraserSize: state.eraserSize,
      eraserRatio: eraserRatioForView(view),
      strokeSequence: ++state.drawing.strokeSequence,
      points: points.splice(0, 40),
    };
    renderMessage(message);
    send(message);
    if (state.drawing.tool === "eraser") {
      showHover(view, message.points[message.points.length - 1], {
        tool: "eraser",
        size: eraserDisplaySize(view),
      });
    }
  }
}

function endStroke(event) {
  if (!state.drawing || state.drawing.pointerId !== event.pointerId) return;
  event.preventDefault();
  const message = {
    type: "stroke:end",
    strokeId: state.drawing.strokeId,
    pageIndex: state.drawing.pageIndex,
    tool: state.drawing.tool,
    strokeSequence: ++state.drawing.strokeSequence,
  };
  renderMessage(message);
  send(message);
  if (state.drawing.tool === "eraser") hideHover();
  state.drawing = null;
  state.penIsDown = false;
}

function prepareNativePenInput() {
  stopInertia(true);
  const needsPinchCommit = Boolean(state.pinch || state.pinchPending);
  const pinchAnchor = state.pinch?.anchor || state.pendingPinchAnchor;
  releaseTouchCaptures();
  state.touchScroll = null;
  state.touches.clear();
  state.pinch = null;
  state.pinchPending = false;
  state.pendingPinchAnchor = null;
  if (needsPinchCommit) void commitPinchZoom(pinchAnchor);
}

function startNativeStroke(sampleOrX, yOrEraser, legacyPressure, legacyPressureEraser = false) {
  if (!nativeInput || state.drawing) return;
  const sample = sampleOrX && typeof sampleOrX === "object"
    ? sampleOrX
    : { x: sampleOrX, y: yOrEraser, p: legacyPressure };
  const pressureEraser = sampleOrX && typeof sampleOrX === "object"
    ? Boolean(yOrEraser)
    : Boolean(legacyPressureEraser);
  const x = Number(sample.x);
  const y = Number(sample.y);
  const pressure = Number(sample.p);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return;
  const view = viewAtClientPoint(x, y);
  if (!view) return;
  sendHoverHidden();
  prepareNativePenInput();
  state.penIsDown = true;
  const strokeId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const tool = state.manualEraser || pressureEraser ? "eraser" : state.tool;
  state.nativePendingSamples = [];
  state.drawing = {
    pointerId: "native",
    strokeId,
    pageIndex: view.index,
    tool,
    strokeSequence: 0,
    lastSampleIndex: Number.isInteger(sample.sampleIndex) ? sample.sampleIndex : -1,
    lastNativePoint: null,
    startNativePoint: null,
    highlighterPausePoint: null,
    highlighterHoldTimer: null,
    highlighterStraightLocked: false,
  };
  const message = {
    type: "stroke:start", strokeId, pageIndex: view.index,
    color: tool === "highlighter" ? state.highlighterColor : state.color,
    width: tool === "highlighter" ? state.highlighterWidth : state.width,
    widthRatio: widthRatioForView(view),
    opacity: tool === "highlighter" ? state.highlighterOpacity : 1,
    tool, eraserSize: state.eraserSize,
    eraserRatio: eraserRatioForView(view),
    strokeSequence: 0,
    point: pointFromClient(x, y, pressure, view, sample),
  };
  state.drawing.lastNativePoint = message.point;
  state.drawing.startNativePoint = message.point;
  state.drawing.highlighterPausePoint = message.point;
  renderMessage(message);
  send(message);
  if (tool === "highlighter") scheduleNativeHighlighterHold();
  if (tool === "eraser") showHover(view, message.point, { tool, size: eraserDisplaySize(view) });
}

function clearNativeHighlighterHold() {
  if (!state.drawing) return;
  clearTimeout(state.drawing.highlighterHoldTimer);
  state.drawing.highlighterHoldTimer = null;
}

function scheduleNativeHighlighterHold() {
  if (!state.drawing || state.drawing.tool !== "highlighter"
    || state.drawing.highlighterStraightLocked) return;
  clearNativeHighlighterHold();
  const strokeId = state.drawing.strokeId;
  state.drawing.highlighterHoldTimer = setTimeout(() => {
    if (!state.drawing || state.drawing.strokeId !== strokeId
      || state.drawing.tool !== "highlighter" || state.drawing.highlighterStraightLocked) return;
    const view = state.pages.get(state.drawing.pageIndex);
    const start = state.drawing.startNativePoint;
    const end = state.drawing.lastNativePoint;
    if (!view || !start || !end
      || Math.hypot((end.x - start.x) * view.width, (end.y - start.y) * view.height) < 10) return;
    state.drawing.highlighterStraightLocked = true;
    replaceNativeStrokeWithStraight();
  }, HIGHLIGHTER_HOLD_DELAY_MS);
}

function updateNativeHighlighterHold(point) {
  if (!state.drawing || state.drawing.tool !== "highlighter"
    || state.drawing.highlighterStraightLocked || !point) return;
  const view = state.pages.get(state.drawing.pageIndex);
  const pause = state.drawing.highlighterPausePoint;
  if (!view || !pause
    || Math.hypot((point.x - pause.x) * view.width, (point.y - pause.y) * view.height)
      >= HIGHLIGHTER_HOLD_SLOP_PX) {
    state.drawing.highlighterPausePoint = point;
    scheduleNativeHighlighterHold();
  }
}

function queueNativeSamples(samples) {
  if (!nativeInput || !state.drawing || state.drawing.pointerId !== "native") return;
  const view = state.pages.get(state.drawing.pageIndex);
  if (!view || !Array.isArray(samples) || !samples.length) return;
  for (const sample of samples) {
    if (!Number.isFinite(sample?.x) || !Number.isFinite(sample?.y)) continue;
    if (Number.isInteger(sample.sampleIndex)
      && sample.sampleIndex <= state.drawing.lastSampleIndex) continue;
    const point = pointFromClient(sample.x, sample.y, sample.p, view, sample);
    const previous = state.drawing.lastNativePoint;
    if (previous
      && Math.hypot(point.x - previous.x, point.y - previous.y) < 0.000_025
      && Math.abs(point.p - previous.p) < 0.01) continue;
    if (Number.isInteger(sample.sampleIndex)) state.drawing.lastSampleIndex = sample.sampleIndex;
    state.drawing.lastNativePoint = point;
    state.nativePendingSamples.push(point);
  }
}

function flushNativeSamples() {
  state.nativeMoveFrame = null;
  if (!nativeInput || !state.drawing || state.drawing.pointerId !== "native") return;
  const view = state.pages.get(state.drawing.pageIndex);
  if (!view) {
    state.nativePendingSamples = [];
    return;
  }
  while (state.nativePendingSamples.length) {
    const points = state.nativePendingSamples.splice(0, 40);
    const message = {
      type: "stroke:move", strokeId: state.drawing.strokeId, pageIndex: state.drawing.pageIndex,
      tool: state.drawing.tool, eraserSize: state.eraserSize,
      eraserRatio: eraserRatioForView(view),
      strokeSequence: ++state.drawing.strokeSequence,
      points,
    };
    renderMessage(message);
    send(message);
    if (state.drawing.tool === "eraser") {
      showHover(view, points[points.length - 1], {
        tool: "eraser",
        size: eraserDisplaySize(view),
      });
    }
  }
}

function moveNativeStroke(samples) {
  if (state.drawing?.tool === "highlighter" && state.drawing.highlighterStraightLocked) {
    const latest = Array.isArray(samples) ? samples[samples.length - 1] : null;
    if (latest) replaceNativeStrokeWithStraight(latest);
    return;
  }
  queueNativeSamples(samples);
  updateNativeHighlighterHold(state.drawing?.lastNativePoint);
  // ArkTS already supplies one touch frame together with its historical pen
  // samples. Send that batch now instead of adding another ArkWeb frame of
  // latency. Browser Pointer Events remain coalesced by the browser itself.
  if (state.nativePendingSamples.length) flushNativeSamples();
}

function replaceNativeStrokeWithStraight(finalSample = null) {
  if (!nativeInput || !state.drawing || state.drawing.pointerId !== "native"
    || state.drawing.tool !== "highlighter") return;
  const view = state.pages.get(state.drawing.pageIndex);
  if (!view) return;
  clearNativeHighlighterHold();
  state.drawing.highlighterStraightLocked = true;
  if (finalSample && Number.isFinite(finalSample.x) && Number.isFinite(finalSample.y)) {
    state.drawing.lastNativePoint = pointFromClient(
      finalSample.x, finalSample.y, finalSample.p, view, finalSample,
    );
  }
  if (state.nativeMoveFrame) cancelAnimationFrame(state.nativeMoveFrame);
  state.nativeMoveFrame = null;
  state.nativePendingSamples = [];
  const start = state.drawing.startNativePoint;
  const end = state.drawing.lastNativePoint;
  if (!start || !end) return;
  const message = {
    type: "stroke:replace",
    strokeId: state.drawing.strokeId,
    pageIndex: state.drawing.pageIndex,
    color: state.highlighterColor,
    width: state.highlighterWidth,
    widthRatio: state.highlighterWidth / Math.max(1, view.width),
    opacity: state.highlighterOpacity,
    tool: "highlighter",
    strokeSequence: ++state.drawing.strokeSequence,
    points: [start, end],
  };
  renderMessage(message);
  send(message);
}

function endNativeStroke(finalSample = null) {
  if (!nativeInput || !state.drawing || state.drawing.pointerId !== "native") return;
  if (state.drawing.tool === "highlighter" && state.drawing.highlighterStraightLocked) {
    if (finalSample) replaceNativeStrokeWithStraight(finalSample);
  } else if (finalSample) {
    queueNativeSamples([finalSample]);
  }
  clearNativeHighlighterHold();
  if (state.nativeMoveFrame) cancelAnimationFrame(state.nativeMoveFrame);
  flushNativeSamples();
  const message = {
    type: "stroke:end", strokeId: state.drawing.strokeId,
    pageIndex: state.drawing.pageIndex, tool: state.drawing.tool,
    strokeSequence: ++state.drawing.strokeSequence,
  };
  renderMessage(message);
  send(message);
  if (state.drawing.tool === "eraser") hideHover();
  state.drawing = null;
  state.penIsDown = false;
  if (state.nativeMoveFrame) cancelAnimationFrame(state.nativeMoveFrame);
  state.nativeMoveFrame = null;
  state.nativePendingSamples = [];
}

function cancelNativeStroke() {
  endNativeStroke();
}

function switchNativeStrokeToEraser() {
  // Kept for older native clients. Mid-stroke switching is intentionally disabled.
}

function reportNativeHover(x, y) {
  if (!nativeInput || state.drawing) return;
  const view = viewAtClientPoint(x, y);
  if (!view) {
    sendHoverHidden();
    return;
  }
  const point = pointFromClient(x, y, 0.52, view);
  const tool = state.manualEraser ? "eraser" : "ink";
  showHover(view, point, { tool });
  state.pendingHover = {
    pageIndex: view.index,
    point,
    tool,
    eraserSize: tool === "eraser" ? state.eraserSize : undefined,
    eraserRatio: tool === "eraser" ? eraserRatioForView(view) : undefined,
  };
  if (state.hoverFrame) return;
  state.hoverFrame = requestAnimationFrame(() => {
    state.hoverFrame = null;
    const hover = state.pendingHover;
    state.pendingHover = null;
    if (hover) send({ type: "cursor:move", ...hover });
  });
}

function clampZoom(value) {
  return Math.max(0.5, Math.min(4, value));
}

function updateZoomLabel() {
  zoomValue.textContent = `${Math.round(state.zoom * 100)}%`;
}

function setPinchPreview(scale, anchor, center) {
  const previous = state.preview;
  const rect = pagesElement.getBoundingClientRect();
  // Keep scrollTop unchanged while pinching. HarmonyOS asynchronously updates
  // transformed overflow, so changing it in this same frame makes the view
  // briefly snap to an incorrect position.
  const baseLeft = rect.left - previous.translateX;
  const baseTop = rect.top - previous.translateY;
  const translateX = center.x - baseLeft - scale * anchor.localX;
  const translateY = center.y - baseTop - scale * anchor.localY;
  pagesElement.style.transform = `translate(${translateX}px, ${translateY}px) scale(${scale})`;
  pagesElement.style.transformOrigin = "0 0";
  state.preview = { scale, translateX, translateY };
}

function clearPinchPreview() {
  pagesElement.style.removeProperty("transform");
  pagesElement.style.removeProperty("transform-origin");
  state.preview = { scale: 1, translateX: 0, translateY: 0 };
}

function touchPair() {
  const touches = [...state.touches.values()];
  return touches.length >= 2 ? touches.slice(0, 2) : null;
}

function touchCenter(pair) {
  return {
    x: (pair[0].x + pair[1].x) / 2,
    y: (pair[0].y + pair[1].y) / 2,
  };
}

function pinchAnchorAt(center) {
  const rect = pagesElement.getBoundingClientRect();
  const scale = state.preview.scale || 1;
  const localX = (center.x - rect.left) / scale;
  const localY = (center.y - rect.top) / scale;
  const anchor = { localX, localY, clientX: center.x, clientY: center.y };
  for (const view of state.pages.values()) {
    const pageX = localX - view.element.offsetLeft;
    const pageY = localY - view.element.offsetTop;
    if (pageX >= 0 && pageX <= view.width && pageY >= 0 && pageY <= view.height) {
      return {
        ...anchor,
        pageIndex: view.index,
        x: pageX / view.width,
        y: pageY / view.height,
      };
    }
  }
  return anchor;
}

function beginPinch() {
  const pair = touchPair();
  if (!pair) return;
  const startDistance = Math.max(8, Math.hypot(pair[0].x - pair[1].x, pair[0].y - pair[1].y));
  const anchor = pinchAnchorAt(touchCenter(pair));
  stopInertia(false);
  cancelScheduledViewport();
  beginViewportInteraction();
  state.touchScroll = null;
  state.pinchPending = false;
  state.pendingPinchAnchor = null;
  state.pinch = { startDistance, startZoom: state.zoom, anchor };
}

async function commitPinchZoom(anchor = state.pendingPinchAnchor) {
  const generation = ++state.zoomCommitGeneration;
  state.pendingPinchAnchor = null;
  try {
    if (anchor?.pageIndex !== undefined) await renderPDF({ pinchAnchor: anchor });
  } finally {
    if (generation === state.zoomCommitGeneration) endViewportInteraction();
  }
}

function zoomAroundViewport(nextZoom) {
  stopInertia(true);
  beginViewportInteraction();
  const rect = scroll.getBoundingClientRect();
  const center = { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  const anchor = pinchAnchorAt(center);
  state.zoom = clampZoom(nextZoom);
  updateZoomLabel();
  setPinchPreview(state.zoom / state.renderedZoom, anchor, center);
  void commitPinchZoom(anchor);
}

function startTouchGesture(event) {
  if (event.pointerType !== "touch") return;
  // A touch during a pen stroke is a palm contact, never a navigation gesture.
  event.preventDefault();
  if (state.penIsDown) return;
  stopInertia(true);
  scroll.setPointerCapture(event.pointerId);
  state.touches.set(event.pointerId, { pointerId: event.pointerId, x: event.clientX, y: event.clientY });
  beginViewportInteraction();
  if (state.touches.size >= 2) {
    beginPinch();
  } else {
    state.touchScroll = {
      pointerId: event.pointerId,
      lastX: event.clientX,
      lastY: event.clientY,
      lastTime: performance.now(),
      velocityX: 0,
      velocityY: 0,
      moved: false,
    };
  }
}

function moveTouchGesture(event) {
  if (event.pointerType !== "touch") return;
  const touch = state.touches.get(event.pointerId);
  if (!touch) return;
  event.preventDefault();
  touch.x = event.clientX;
  touch.y = event.clientY;
  if (state.penIsDown) return;

  if (state.pinch) {
    const pair = touchPair();
    if (!pair) return;
    const distance = Math.hypot(pair[0].x - pair[1].x, pair[0].y - pair[1].y);
    const center = touchCenter(pair);
    state.zoom = clampZoom(state.pinch.startZoom * (distance / state.pinch.startDistance));
    state.pinch.anchor.clientX = center.x;
    state.pinch.anchor.clientY = center.y;
    updateZoomLabel();
    setPinchPreview(state.zoom / state.renderedZoom, state.pinch.anchor, center);
    // The transformed preview already represents the exact visible viewport.
    // Publish it while both fingers are still down so the Mac follows every
    // pinch frame instead of jumping only after the expensive PDF rerender.
    scheduleViewport({ allowDuringPinch: true });
    return;
  }

  const gesture = state.touchScroll;
  if (!gesture || gesture.pointerId !== event.pointerId) return;
  if (state.pinchPending) state.pendingPinchAnchor = null;
  const now = performance.now();
  const elapsed = Math.max(1, Math.min(50, now - gesture.lastTime));
  const deltaX = gesture.lastX - event.clientX;
  const deltaY = gesture.lastY - event.clientY;
  const beforeX = scroll.scrollLeft;
  const beforeY = scroll.scrollTop;
  scroll.scrollLeft += deltaX;
  scroll.scrollTop += deltaY;
  const appliedX = scroll.scrollLeft - beforeX;
  const appliedY = scroll.scrollTop - beforeY;
  const sampleX = appliedX / elapsed;
  const sampleY = appliedY / elapsed;
  const blend = gesture.moved ? 0.38 : 1;
  gesture.velocityX += (sampleX - gesture.velocityX) * blend;
  gesture.velocityY += (sampleY - gesture.velocityY) * blend;
  if (Math.abs(appliedX - deltaX) > 0.5) gesture.velocityX = 0;
  if (Math.abs(appliedY - deltaY) > 0.5) gesture.velocityY = 0;
  gesture.lastX = event.clientX;
  gesture.lastY = event.clientY;
  gesture.lastTime = now;
  gesture.moved ||= Math.abs(appliedX) > 0.1 || Math.abs(appliedY) > 0.1;
  scheduleViewport();
}

function endTouchGesture(event) {
  if (event.pointerType !== "touch") return;
  const touch = state.touches.get(event.pointerId);
  if (!touch) return;
  event.preventDefault();
  state.touches.delete(event.pointerId);
  let releasedScroll = null;
  if (state.touchScroll?.pointerId === event.pointerId) {
    releasedScroll = state.touchScroll;
    state.touchScroll = null;
  }

  if (state.pinch) {
    if (state.touches.size >= 2) {
      // Keep a third finger from causing a sudden jump when one finger lifts.
      beginPinch();
      return;
    }
    state.pendingPinchAnchor = state.pinch.anchor;
    state.pinch = null;
    state.pinchPending = true;
  }

  // Do not rebuild canvases while a finger is still held down: HarmonyOS can
  // then omit its final pointerup, leaving a stale touch that looks like a
  // second finger in the next gesture.
  if (!state.touches.size && state.pinchPending) {
    state.pinchPending = false;
    void commitPinchZoom(state.pendingPinchAnchor);
    return;
  }

  if (!state.touches.size && releasedScroll) {
    const idleTime = Math.max(0, performance.now() - releasedScroll.lastTime - 16);
    const releaseDamping = Math.exp(-idleTime / 55);
    const velocityX = releasedScroll.velocityX * releaseDamping;
    const velocityY = releasedScroll.velocityY * releaseDamping;
    if (event.type === "pointerup" && releasedScroll.moved) {
      startInertia(velocityX, velocityY);
    } else {
      endViewportInteraction();
    }
    return;
  }

  // After zooming, the remaining finger can immediately continue to scroll.
  const [remaining] = state.touches.values();
  if (!state.penIsDown && remaining && !state.touchScroll) {
    state.touchScroll = {
      pointerId: remaining.pointerId,
      lastX: remaining.x,
      lastY: remaining.y,
      lastTime: performance.now(),
      velocityX: 0,
      velocityY: 0,
      moved: false,
    };
  }
}

function startPointer(event, view) {
  if (event.pointerType === "pen" && !nativeInput) startStroke(event, view);
}

function movePointer(event, view) {
  if (event.pointerType === "pen" && !nativeInput) {
    if (state.drawing) moveStroke(event, view);
    else queueHover(event, view);
  }
}

function endPointer(event) {
  if (event.pointerType === "pen" && !nativeInput) endStroke(event);
}

async function buildRenderedPages(pdf, renderZoom, isCurrent = () => true, onProgress = null) {
  const availableWidth = Math.max(280, scroll.clientWidth - 44);
  const fragment = document.createDocumentFragment();
  const pages = new Map();
  const sourcePages = [];
  let maximumPageWidth = 1;
  try {
    for (let index = 0; index < pdf.numPages; index += 1) {
      if (!isCurrent()) throw new DOMException("PDF load superseded", "AbortError");
      const page = await pdf.getPage(index + 1);
      if (!isCurrent()) throw new DOMException("PDF load superseded", "AbortError");
      const unscaled = page.getViewport({ scale: 1 });
      sourcePages.push({ index, page, unscaled });
      maximumPageWidth = Math.max(maximumPageWidth, unscaled.width);
    }
    const scale = (availableWidth / maximumPageWidth) * renderZoom;
    let cssPixelArea = 0;
    let maximumCssEdge = 0;
    for (const { unscaled } of sourcePages) {
      const width = unscaled.width * scale;
      const height = unscaled.height * scale;
      cssPixelArea += width * height;
      maximumCssEdge = Math.max(maximumCssEdge, width, height);
    }
    // PDF and ink each use a full-page RGBA canvas. Bound their aggregate
    // backing-store memory so long documents and restored zoom levels cannot
    // make ArkWeb exceed the tablet's graphics-memory limit.
    const pixelRatio = boundedCanvasPixelRatio({
      devicePixelRatio: devicePixelRatio || 1,
      cssPixelArea,
      maximumCssEdge,
    });
    for (const { index, page } of sourcePages) {
      if (!isCurrent()) throw new DOMException("PDF load superseded", "AbortError");
      const viewport = page.getViewport({ scale });
      const wrapper = document.createElement("article");
      wrapper.className = "pdf-page";
      wrapper.style.width = `${viewport.width}px`;
      wrapper.style.height = `${viewport.height}px`;
      const renderCanvas = document.createElement("canvas");
      renderCanvas.className = "pdf-render";
      renderCanvas.width = Math.max(1, Math.ceil(viewport.width * pixelRatio));
      renderCanvas.height = Math.max(1, Math.ceil(viewport.height * pixelRatio));
      const inkCanvas = document.createElement("canvas");
      inkCanvas.className = "pdf-ink";
      inkCanvas.width = Math.max(1, Math.ceil(viewport.width * pixelRatio));
      inkCanvas.height = Math.max(1, Math.ceil(viewport.height * pixelRatio));
      const liveInkCanvas = document.createElement("canvas");
      liveInkCanvas.className = "pdf-live-ink";
      // Allocate the full backing store only while a highlighter stroke is live.
      // A transparent 1x1 canvas still supplies the correctly sized CSS overlay.
      liveInkCanvas.width = 1;
      liveInkCanvas.height = 1;
      const hoverCursor = document.createElement("div");
      hoverCursor.className = "pdf-hover-cursor";
      hoverCursor.hidden = true;
      hoverCursor.setAttribute("aria-hidden", "true");
      wrapper.append(renderCanvas, inkCanvas, liveInkCanvas, hoverCursor);
      fragment.append(wrapper);
      const renderContext = renderCanvas.getContext("2d", { alpha: false });
      await page.render({ canvasContext: renderContext, viewport, transform: [pixelRatio, 0, 0, pixelRatio, 0, 0] }).promise;
      if (!isCurrent()) throw new DOMException("PDF load superseded", "AbortError");
      const view = {
        index,
        element: wrapper,
        renderCanvas,
        inkCanvas,
        inkContext: inkCanvas.getContext("2d"),
        liveInkCanvas,
        liveInkContext: liveInkCanvas.getContext("2d"),
        liveHighlighterStrokeId: "",
        hoverCursor,
        width: viewport.width,
        height: viewport.height,
        pixelRatio,
        renderZoom,
      };
      view.inkContext.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
      view.liveInkContext.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
      inkCanvas.addEventListener("pointerdown", (event) => startPointer(event, view));
      inkCanvas.addEventListener("pointermove", (event) => movePointer(event, view));
      inkCanvas.addEventListener("pointerup", endPointer);
      inkCanvas.addEventListener("pointercancel", endPointer);
      inkCanvas.addEventListener("pointerleave", (event) => {
        if (event.pointerType === "pen" && !state.drawing) sendHoverHidden();
      });
      pages.set(index, view);
      onProgress?.(index + 1, pdf.numPages);
    }
    return { pages, fragment };
  } catch (error) {
    releaseRenderedPages(pages);
    throw error;
  }
}

function releaseRenderedPages(pages) {
  for (const view of pages?.values?.() || []) {
    view.renderCanvas.width = 1;
    view.renderCanvas.height = 1;
    view.inkCanvas.width = 1;
    view.inkCanvas.height = 1;
    view.liveInkCanvas.width = 1;
    view.liveInkCanvas.height = 1;
  }
  pages?.clear?.();
}

async function renderPDF({ pinchAnchor = null, targetViewport = null } = {}) {
  if (!state.pdf) return;
  // Prepare the complete page tree offscreen, then swap it in one frame. This
  // keeps remote zoom changes and document replacements from exposing a
  // temporary empty/top-left layout.
  const pdf = state.pdf;
  const restore = targetViewport || currentViewport();
  const renderZoom = state.zoom;
  const generation = state.pdfLoadGeneration;
  let rendered;
  try {
    rendered = await buildRenderedPages(
      pdf,
      renderZoom,
      () => state.pdf === pdf
        && generation === state.pdfLoadGeneration
        && renderZoom === state.zoom,
    );
  } catch (error) {
    if (error?.name === "AbortError") return;
    throw error;
  }
  if (state.pdf !== pdf
    || generation !== state.pdfLoadGeneration
    || renderZoom !== state.zoom) {
    releaseRenderedPages(rendered.pages);
    return;
  }
  clearPinchPreview();
  const previousPages = state.pages;
  state.pages = rendered.pages;
  pagesElement.replaceChildren(rendered.fragment);
  state.renderedZoom = renderZoom;
  redrawInk();
  if (pinchAnchor?.pageIndex !== undefined) scrollToPinchAnchor(pinchAnchor);
  else if (restore) scrollToViewport(restore, true);
  releaseRenderedPages(previousPages);
}

function currentViewport() {
  if (!state.pages.size) return null;
  const scrollRect = scroll.getBoundingClientRect();
  const pagesRect = pagesElement.getBoundingClientRect();
  const top = (scrollRect.top + scroll.clientTop - pagesRect.top) / state.preview.scale;
  const centerX = (scrollRect.left + scroll.clientLeft + scroll.clientWidth / 2 - pagesRect.left) / state.preview.scale;
  const centerY = (scrollRect.top + scroll.clientTop + scroll.clientHeight / 2 - pagesRect.top) / state.preview.scale;
  const selectedRect = viewportAnchorPage(
    [...state.pages.values()].map((view) => ({
      index: view.index,
      top: view.element.offsetTop,
      height: view.height,
    })),
    centerY,
  );
  const selected = state.pages.get(selectedRect?.index) || [...state.pages.values()][0];
  const viewTop = selected.element.offsetTop;
  const lastPageIndex = Math.max(0, (state.pdf?.numPages || state.pages.size) - 1);
  const atDocumentTop = selected.index === 0 && scroll.scrollTop <= 1;
  const atDocumentBottom = selected.index === lastPageIndex
    && scroll.scrollTop >= Math.max(0, scroll.scrollHeight - scroll.clientHeight - 1);
  return {
    pageIndex: selected.index,
    zoom: state.zoom,
    // Exact 0/1 values are document-edge sentinels. They avoid small,
    // platform-specific PDF gutters keeping the other device a few pixels
    // away from the real top or bottom.
    offset: atDocumentTop ? 0 : (atDocumentBottom ? 1 : Math.max(0, Math.min(1, (top - viewTop) / selected.height))),
    anchorX: Math.max(0, Math.min(1, (centerX - selected.element.offsetLeft) / selected.width)),
    anchorY: Math.max(0, Math.min(1, (centerY - viewTop) / selected.height)),
    viewportWidth: Math.max(1, scroll.clientWidth),
    viewportHeight: Math.max(1, scroll.clientHeight),
  };
}

function sendViewport(force = false, interactionPhase = null) {
  if (state.applyingViewport && !force) return;
  const viewport = currentViewport();
  if (!viewport) return;
  const interaction = state.localViewportInteraction;
  send({
    type: "pdf:viewport",
    ...viewport,
    ...(interaction && interactionPhase
      ? { interactionId: interaction.id, interactionPhase }
      : {}),
  });
}

function cancelScheduledViewport() {
  clearTimeout(state.viewportTimer);
  state.viewportTimer = null;
  state.viewportPending = false;
}

function cancelScrollFallbackEnd() {
  clearTimeout(state.scrollFallbackEndTimer);
  state.scrollFallbackEndTimer = null;
}

function sendViewportNow(force = false, interactionPhase = null) {
  cancelScheduledViewport();
  state.lastViewportSentAt = performance.now();
  sendViewport(force, interactionPhase);
}

function beginViewportInteraction() {
  if (state.localViewportInteraction) return;
  state.localViewportInteraction = {
    id: globalThis.crypto?.randomUUID?.()
      || `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`,
  };
  sendViewportNow(true, "begin");
}

function endViewportInteraction() {
  cancelScrollFallbackEnd();
  if (!state.localViewportInteraction) {
    sendViewportNow(true);
    return;
  }
  sendViewportNow(true, "end");
  state.localViewportInteraction = null;
}

function cancelViewportInteraction() {
  state.localViewportInteraction = null;
}

function scheduleViewport({ allowDuringPinch = false } = {}) {
  const pinchActive = Boolean(state.pinch || state.pinchPending);
  if ((!allowDuringPinch && pinchActive) || state.loadingPDF || state.pendingViewport) return;
  if (state.applyingViewport) return;
  state.viewportPending = true;
  if (state.viewportTimer !== null) return;
  const elapsed = performance.now() - state.lastViewportSentAt;
  const wait = Math.max(0, VIEWPORT_SYNC_INTERVAL - elapsed);
  state.viewportTimer = setTimeout(() => {
    state.viewportTimer = null;
    if (!state.viewportPending) return;
    state.viewportPending = false;
    const pinchStillActive = Boolean(state.pinch || state.pinchPending);
    if ((!allowDuringPinch && pinchStillActive)
      || state.loadingPDF
      || state.pendingViewport
      || state.applyingViewport) return;
    state.lastViewportSentAt = performance.now();
    sendViewport(false, state.localViewportInteraction ? "update" : null);
  }, wait);
}

function handleNativeScrollFallback() {
  if (state.applyingViewport || state.loadingPDF || state.pendingViewport || state.pinch || state.pinchPending) return;
  // Normal finger and inertia paths already own an interaction. Some ArkWeb
  // versions perform system scrolling without Pointer Events; only that path
  // needs this fallback lease and idle-based final snapshot.
  if (state.localViewportInteraction) {
    scheduleViewport();
  } else {
    beginViewportInteraction();
    scheduleViewport();
  }
  cancelScrollFallbackEnd();
  state.scrollFallbackEndTimer = setTimeout(() => {
    state.scrollFallbackEndTimer = null;
    if (!state.pinch && !state.pinchPending) endViewportInteraction();
  }, 120);
}

function stopInertia(syncFinal = false) {
  const wasRunning = Boolean(state.inertia || state.inertiaFrame);
  if (state.inertiaFrame !== null) cancelAnimationFrame(state.inertiaFrame);
  state.inertiaFrame = null;
  state.inertia = null;
  if (syncFinal && wasRunning) endViewportInteraction();
}

function startInertia(velocityX, velocityY) {
  stopInertia(false);
  if (Math.hypot(velocityX, velocityY) < INERTIA_START_SPEED) {
    endViewportInteraction();
    return;
  }
  state.inertia = {
    velocityX,
    velocityY,
    lastTime: performance.now(),
  };
  const step = (timestamp) => {
    const inertia = state.inertia;
    if (!inertia) return;
    const elapsed = Math.max(1, Math.min(34, timestamp - inertia.lastTime));
    inertia.lastTime = timestamp;
    const decay = Math.exp(-INERTIA_DECAY_PER_MS * elapsed);
    const travelFactor = (1 + decay) / 2;
    const deltaX = inertia.velocityX * elapsed * travelFactor;
    const deltaY = inertia.velocityY * elapsed * travelFactor;
    const beforeX = scroll.scrollLeft;
    const beforeY = scroll.scrollTop;
    scroll.scrollLeft += deltaX;
    scroll.scrollTop += deltaY;
    const appliedX = scroll.scrollLeft - beforeX;
    const appliedY = scroll.scrollTop - beforeY;
    const blockedX = Math.abs(deltaX) > 0.01 && Math.abs(appliedX) < 0.01;
    const blockedY = Math.abs(deltaY) > 0.01 && Math.abs(appliedY) < 0.01;
    inertia.velocityX = blockedX || Math.abs(appliedX - deltaX) > 0.5 ? 0 : inertia.velocityX * decay;
    inertia.velocityY = blockedY || Math.abs(appliedY - deltaY) > 0.5 ? 0 : inertia.velocityY * decay;
    scheduleViewport();
    if (Math.hypot(inertia.velocityX, inertia.velocityY) <= INERTIA_STOP_SPEED) {
      state.inertia = null;
      state.inertiaFrame = null;
      endViewportInteraction();
      return;
    }
    state.inertiaFrame = requestAnimationFrame(step);
  };
  state.inertiaFrame = requestAnimationFrame(step);
}

function scrollToViewport(viewport, silent = false) {
  const view = state.pages.get(viewport.pageIndex);
  if (!view) return;
  const generation = ++state.remoteViewportGeneration;
  if (silent) state.applyingViewport = true;
  const pageCount = state.pdf?.numPages || state.pages.size;
  // Offset 0/1 only means a whole-document edge when it is paired with the
  // first/last page. A page-local offset may legitimately reach either value
  // while the Mac viewport crosses a page boundary.
  const { top: atDocumentTop, bottom: atDocumentBottom } = viewportDocumentEdges(viewport, pageCount);
  if (atDocumentTop) {
    scroll.scrollTop = 0;
  } else if (atDocumentBottom) {
    scroll.scrollTop = Math.max(0, scroll.scrollHeight - scroll.clientHeight);
  } else if (Number.isFinite(viewport.anchorX) && Number.isFinite(viewport.anchorY)) {
    const targetX = view.element.offsetLeft + view.width * viewport.anchorX;
    const targetY = view.element.offsetTop + view.height * viewport.anchorY;
    scroll.scrollLeft = pagesElement.offsetLeft + state.preview.translateX + state.preview.scale * targetX - scroll.clientWidth / 2;
    scroll.scrollTop = pagesElement.offsetTop + state.preview.translateY + state.preview.scale * targetY - scroll.clientHeight / 2;
  } else {
    const target = view.element.offsetTop + view.height * viewport.offset;
    scroll.scrollTop = pagesElement.offsetTop + state.preview.translateY + state.preview.scale * target;
  }
  if (silent) setTimeout(() => {
    if (state.remoteViewportGeneration === generation) state.applyingViewport = false;
  }, 220);
}

function scrollToPinchAnchor(anchor) {
  const view = state.pages.get(anchor.pageIndex);
  if (!view) return;
  const rect = scroll.getBoundingClientRect();
  const generation = ++state.remoteViewportGeneration;
  state.applyingViewport = true;
  scroll.scrollLeft = pagesElement.offsetLeft + view.element.offsetLeft + view.width * anchor.x - (anchor.clientX - rect.left);
  scroll.scrollTop = pagesElement.offsetTop + view.element.offsetTop + view.height * anchor.y - (anchor.clientY - rect.top);
  setTimeout(() => {
    if (state.remoteViewportGeneration === generation) state.applyingViewport = false;
  }, 220);
}

function hasViewportPreview() {
  return Math.abs(state.preview.scale - 1) > 0.0005
    || Math.abs(state.preview.translateX) > 0.5
    || Math.abs(state.preview.translateY) > 0.5;
}

function previewRemoteViewport(viewport) {
  const view = state.pages.get(viewport.pageIndex);
  if (!view) return false;
  const rect = scroll.getBoundingClientRect();
  const center = {
    x: rect.left + rect.width / 2,
    y: rect.top + rect.height / 2,
  };
  const anchor = {
    localX: view.element.offsetLeft + view.width * viewport.anchorX,
    localY: view.element.offsetTop + view.height * viewport.anchorY,
  };
  setPinchPreview(state.zoom / state.renderedZoom, anchor, center);
  return true;
}

function cancelRemotePreviewCommit() {
  clearTimeout(state.remotePreviewCommitTimer);
  state.remotePreviewCommitTimer = null;
}

function scheduleRemotePreviewCommit(viewport, generation) {
  cancelRemotePreviewCommit();
  state.remotePreviewCommitTimer = setTimeout(() => {
    state.remotePreviewCommitTimer = null;
    if (state.remoteViewportGeneration !== generation || state.localViewportInteraction) return;
    void applyViewportNow({ ...viewport, interactionPhase: "end" });
  }, 260);
}

async function applyViewportNow(viewport) {
  const normalized = normalizePDFViewport(viewport);
  if (!normalized || !documentMatches(viewport, state)) return;
  const target = { ...viewport, ...normalized };
  // The relay grants a short viewport lease to the actively gesturing device.
  // A remote update that reaches this client is therefore safe to apply only
  // after the local interaction has completed.
  if (state.localViewportInteraction || state.pinch || state.pinchPending) return;
  // Mark the whole remote zoom operation as silent before renderPDF clears
  // and rebuilds the page elements. Otherwise that temporary empty/top-left
  // layout fires a scroll event and is echoed to the Mac as a real viewport.
  stopInertia(false);
  cancelScheduledViewport();
  state.applyingViewport = true;
  const generation = ++state.remoteViewportGeneration;
  const isLiveInteraction = target.interactionId && target.interactionPhase !== "end";
  try {
    if (isLiveInteraction
      && (Math.abs(target.zoom - state.renderedZoom) > 0.002 || hasViewportPreview())) {
      state.zoom = clampZoom(target.zoom);
      updateZoomLabel();
      if (previewRemoteViewport(target)) {
        scheduleRemotePreviewCommit(target, generation);
        return;
      }
    }
    cancelRemotePreviewCommit();
    if (Math.abs(target.zoom - state.renderedZoom) > 0.002 || hasViewportPreview()) {
      state.zoom = clampZoom(target.zoom);
      updateZoomLabel();
      await renderPDF({ targetViewport: target });
    } else {
      scrollToViewport(target, true);
    }
  } catch (error) {
    if (state.remoteViewportGeneration === generation) state.applyingViewport = false;
    throw error;
  }
}

function queueRemoteViewport(viewport) {
  if (!viewport || !documentMatches(viewport, state)) return;
  state.remoteViewportQueued = viewport;
  if (state.remoteViewportWorkerRunning || state.remoteViewportFrame !== null) return;
  state.remoteViewportFrame = requestAnimationFrame(() => {
    state.remoteViewportFrame = null;
    const latest = state.remoteViewportQueued;
    state.remoteViewportQueued = null;
    if (!latest) return;
    state.remoteViewportWorkerRunning = true;
    void applyViewportNow(latest).finally(() => {
      state.remoteViewportWorkerRunning = false;
      if (state.remoteViewportQueued) queueRemoteViewport(state.remoteViewportQueued);
    });
  });
}

function cancelRemoteViewportFrame() {
  if (state.remoteViewportFrame !== null) cancelAnimationFrame(state.remoteViewportFrame);
  state.remoteViewportFrame = null;
  state.remoteViewportQueued = null;
  cancelRemotePreviewCommit();
}

async function disposePDF(pdf, loadingTask = null) {
  try {
    if (loadingTask && typeof loadingTask.destroy === "function") {
      await loadingTask.destroy();
      return;
    }
    if (pdf && typeof pdf.destroy === "function") {
      await pdf.destroy();
      return;
    }
    // Some HarmonyOS ArkWeb builds expose cleanup(), but omit destroy() from
    // PDFDocumentProxy. Releasing resources must never block the next render.
    if (pdf && typeof pdf.cleanup === "function") await pdf.cleanup();
  } catch (error) {
    console.warn("PDF cleanup skipped", error);
  }
}

async function clearPDFForEmptySnapshot() {
  stopInertia(false);
  cancelScheduledViewport();
  cancelScrollFallbackEnd();
  ++state.pdfLoadGeneration;
  state.pdfFetchController?.abort();
  state.pdfFetchController = null;
  clearTimeout(state.retryTimer);
  const loadingTask = state.pdfLoadingTask;
  const previousPDF = state.pdf;
  state.pdfLoadingTask = null;
  state.pendingDocument = null;
  state.pdf = null;
  state.loadingPDF = false;
  state.pendingViewport = null;
  cancelRemoteViewportFrame();
  state.documentId = "";
  state.documentVersion = 0;
  state.documentHash = "";
  state.log = [];
  state.historyCursor = 0;
  state.historyRevision = 0;
  state.active.clear();
  state.liveHighlighters.clear();
  state.renderedStrokeSequences.clear();
  state.drawing = null;
  state.penIsDown = false;
  if (state.nativeMoveFrame) cancelAnimationFrame(state.nativeMoveFrame);
  state.nativeMoveFrame = null;
  state.nativePendingSamples = [];
  releaseTouchCaptures();
  state.touches.clear();
  state.touchScroll = null;
  state.pinch = null;
  state.pinchPending = false;
  state.pendingPinchAnchor = null;
  cancelViewportInteraction();
  hideHover();
  clearPinchPreview();
  releaseRenderedPages(state.pages);
  pagesElement.replaceChildren();
  loading.hidden = false;
  loading.textContent = "PDF 尚未就绪，请在 Mac 打开 PDF";
  documentName.textContent = "等待 Mac 打开 PDF";
  await disposePDF(null, loadingTask);
  await disposePDF(previousPDF);
}

function resetDocumentGestures() {
  stopInertia(false);
  cancelScheduledViewport();
  cancelScrollFallbackEnd();
  state.drawing = null;
  state.penIsDown = false;
  if (state.nativeMoveFrame) cancelAnimationFrame(state.nativeMoveFrame);
  state.nativeMoveFrame = null;
  state.nativePendingSamples = [];
  releaseTouchCaptures();
  state.touches.clear();
  state.touchScroll = null;
  state.pinch = null;
  state.pinchPending = false;
  state.pendingPinchAnchor = null;
  cancelRemoteViewportFrame();
  cancelViewportInteraction();
  hideHover();
}

async function readPDFBytes(response, descriptor, generation) {
  const headerLength = Number(response.headers.get("content-length") || 0);
  const totalBytes = Math.max(headerLength, descriptor.documentSize, 0);
  if (!response.body?.getReader) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    reportDocumentProgress(descriptor, "download", bytes.byteLength, totalBytes || bytes.byteLength, 0.85);
    return bytes;
  }

  const reader = response.body.getReader();
  const chunks = [];
  let loadedBytes = 0;
  let lastReportAt = 0;
  while (true) {
    if (generation !== state.pdfLoadGeneration) {
      await reader.cancel();
      throw new DOMException("PDF load superseded", "AbortError");
    }
    const { done, value } = await reader.read();
    if (done) break;
    if (!value?.byteLength) continue;
    chunks.push(value);
    loadedBytes += value.byteLength;
    const now = performance.now();
    if (now - lastReportAt >= 80) {
      const fraction = totalBytes > 0 ? loadedBytes / totalBytes : 0;
      const percent = totalBytes > 0 ? Math.round(Math.min(1, fraction) * 100) : 0;
      loading.textContent = totalBytes > 0 ? `正在接收新的 PDF ${percent}%` : "正在接收新的 PDF…";
      reportDocumentProgress(descriptor, "download", loadedBytes, totalBytes, Math.min(0.85, fraction * 0.85));
      lastReportAt = now;
    }
  }
  const result = new Uint8Array(loadedBytes);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  reportDocumentProgress(descriptor, "download", loadedBytes, totalBytes || loadedBytes, 0.85);
  return result;
}

async function loadPDF(
  documentOrName,
  legacyDocumentId = "",
  {
    force = false,
    initialViewport = null,
    initialHistory = [],
    initialHistoryCursor = null,
    initialHistoryRevision = 0,
  } = {},
) {
  const descriptor = descriptorFrom(documentOrName, legacyDocumentId);
  const {
    name,
    documentId,
    documentVersion,
    documentHash,
  } = descriptor;
  if (!documentId || !documentVersion) return false;

  if (!force
    && state.pendingDocument
    && descriptorMatches(descriptor, state.pendingDocument.descriptor)) {
    if (descriptorMatches(initialViewport, descriptor)) {
      state.pendingDocument.viewport = initialViewport;
    }
    if (Array.isArray(initialHistory)) {
      state.pendingDocument.history = initialHistory.filter((item) => descriptorMatches(item, descriptor));
    }
    if (Number.isInteger(initialHistoryCursor)) {
      state.pendingDocument.historyCursor = initialHistoryCursor;
    }
    if (Number.isFinite(initialHistoryRevision)) {
      state.pendingDocument.historyRevision = initialHistoryRevision;
    }
    return true;
  }

  const isActiveVersion = documentId === state.documentId
    && documentVersion === state.documentVersion
    && (!documentHash || documentHash === state.documentHash);
  if (!force && isActiveVersion && state.pdf) {
    send({
      type: "pdf:ready",
      documentId,
      documentVersion,
      documentHash,
      transactionId: descriptor.transactionId,
      pageCount: state.pdf.numPages,
    });
    return true;
  }

  // Reopening identical bytes only changes their transaction/version binding.
  // Keep the rendered pages, clear the previous annotation session, and let
  // the server's restored viewport reposition this exact document.
  if (!force && state.pdf && documentHash && documentHash === state.documentHash) {
    ++state.pdfLoadGeneration;
    state.pdfFetchController?.abort();
    if (state.pdfLoadingTask) void disposePDF(null, state.pdfLoadingTask);
    state.pdfFetchController = null;
    state.pdfLoadingTask = null;
    state.pendingDocument = null;
    state.loadingPDF = false;
    clearTimeout(state.retryTimer);
    resetDocumentGestures();
    state.documentId = documentId;
    state.documentVersion = documentVersion;
    state.documentHash = documentHash;
    state.lastDocumentName = name;
    state.log = Array.isArray(initialHistory)
      ? initialHistory.filter((item) => descriptorMatches(item, descriptor))
      : [];
    state.historyCursor = Number.isInteger(initialHistoryCursor)
      ? initialHistoryCursor
      : historyOperations().length;
    state.historyRevision = Math.max(0, Number(initialHistoryRevision || 0));
    state.active.clear();
    state.liveHighlighters.clear();
    redrawInk();
    documentName.textContent = name;
    loading.hidden = true;
    send({
      type: "pdf:ready",
      documentId,
      documentVersion,
      documentHash,
      transactionId: descriptor.transactionId,
      pageCount: state.pdf.numPages,
    });
    notifyNativeState();
    return true;
  }

  const generation = ++state.pdfLoadGeneration;
  resetDocumentGestures();
  state.pdfFetchController?.abort();
  if (state.pdfLoadingTask) void disposePDF(null, state.pdfLoadingTask);
  const controller = new AbortController();
  state.pdfFetchController = controller;
  clearTimeout(state.retryTimer);
  let timedOut = false;
  const pending = {
    descriptor,
    generation,
    viewport: descriptorMatches(initialViewport, descriptor) ? initialViewport : null,
    history: Array.isArray(initialHistory)
      ? initialHistory.filter((item) => descriptorMatches(item, descriptor))
      : [],
    historyCursor: Number.isInteger(initialHistoryCursor) ? initialHistoryCursor : null,
    historyRevision: Math.max(0, Number(initialHistoryRevision || 0)),
    pdf: null,
  };
  const timeout = setTimeout(() => {
    if (generation !== state.pdfLoadGeneration || state.pendingDocument !== pending) return;
    timedOut = true;
    controller.abort();
    if (pending.pdf || state.pdfLoadingTask) {
      void disposePDF(pending.pdf, state.pdfLoadingTask);
    }
  }, 120_000);
  state.pendingDocument = pending;
  state.loadingPDF = true;
  state.pendingViewport = null;
  loading.hidden = false;
  loading.textContent = "正在接收新的 PDF…";
  reportDocumentProgress(descriptor, "download", 0, descriptor.documentSize, 0);
  let preparedRender = null;
  try {
    const query = new URLSearchParams();
    if (documentId) query.set("id", documentId);
    if (documentVersion) query.set("version", String(documentVersion));
    if (documentHash) query.set("hash", documentHash);
    const response = await fetch(`/api/pdf/${room}?${query}`, {
      cache: "no-store",
      headers: { Accept: "application/pdf" },
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(response.status === 404
        ? "Mac 端尚未收到 PDF 文件"
        : `Mac 返回了 HTTP ${response.status}`);
    }
    const bytes = await readPDFBytes(response, descriptor, generation);
    if (timedOut
      || generation !== state.pdfLoadGeneration
      || state.pendingDocument !== pending) {
      throw new DOMException("PDF load superseded", "AbortError");
    }
    if (bytes.byteLength < 5) throw new Error("收到的 PDF 文件为空");
    const responseId = response.headers.get("x-pdf-id") || documentId;
    const responseVersion = Number(response.headers.get("x-pdf-version") || documentVersion || 0);
    const responseHash = response.headers.get("x-pdf-sha256") || documentHash;
    if (documentId && responseId !== documentId) throw new Error("PDF 文件标识已过期");
    if (documentVersion && responseVersion !== documentVersion) throw new Error("PDF 文件版本已过期");
    if (responseHash) {
      loading.textContent = "正在校验新的 PDF…";
      reportDocumentProgress(descriptor, "verify", bytes.byteLength, bytes.byteLength, 0.9);
      const actualHash = await sha256Hex(bytes);
      if (!actualHash) throw new Error("当前系统无法执行 PDF 完整性校验");
      if (actualHash !== responseHash) throw new Error("PDF 完整性校验失败");
    }
    if (timedOut
      || generation !== state.pdfLoadGeneration
      || state.pendingDocument !== pending) {
      throw new DOMException("PDF load superseded", "AbortError");
    }
    loading.textContent = "正在后台打开新的 PDF…";
    reportDocumentProgress(descriptor, "render", bytes.byteLength, bytes.byteLength, 0.92);
    const loadingTask = pdfjsLib.getDocument({ data: bytes });
    state.pdfLoadingTask = loadingTask;
    const nextPDF = await loadingTask.promise;
    pending.pdf = nextPDF;
    if (timedOut
      || generation !== state.pdfLoadGeneration
      || state.pendingDocument !== pending) {
      await disposePDF(nextPDF, loadingTask);
      throw new DOMException("PDF load superseded", "AbortError");
    }
    let renderZoom = pending.viewport?.zoom ? clampZoom(pending.viewport.zoom) : 1;
    let rendered = await buildRenderedPages(
      nextPDF,
      renderZoom,
      () => !timedOut
        && generation === state.pdfLoadGeneration
        && state.pendingDocument === pending,
      (completed, count) => {
        const progress = 0.92 + 0.08 * completed / Math.max(1, count);
        loading.textContent = `正在后台打开新的 PDF ${completed}/${count} 页`;
        reportDocumentProgress(descriptor, "render", bytes.byteLength, bytes.byteLength, progress);
      },
    );
    preparedRender = rendered;
    if (timedOut
      || generation !== state.pdfLoadGeneration
      || state.pendingDocument !== pending) {
      await disposePDF(nextPDF, loadingTask);
      throw new DOMException("PDF load superseded", "AbortError");
    }

    // A restored viewport can arrive while PDF.js is rendering. If its zoom
    // differs, prepare one final offscreen tree before the atomic swap.
    const restoredZoom = pending.viewport?.zoom ? clampZoom(pending.viewport.zoom) : renderZoom;
    if (Math.abs(restoredZoom - renderZoom) > 0.02) {
      releaseRenderedPages(rendered.pages);
      preparedRender = null;
      renderZoom = restoredZoom;
      rendered = await buildRenderedPages(
        nextPDF,
        renderZoom,
        () => !timedOut
          && generation === state.pdfLoadGeneration
          && state.pendingDocument === pending,
      );
      preparedRender = rendered;
    }
    if (timedOut
      || generation !== state.pdfLoadGeneration
      || state.pendingDocument !== pending) {
      await disposePDF(nextPDF, loadingTask);
      throw new DOMException("PDF load superseded", "AbortError");
    }

    const previousPDF = state.pdf;
    const previousPages = state.pages;
    state.pdf = nextPDF;
    state.pdfLoadingTask = null;
    state.pendingDocument = null;
    state.documentId = responseId;
    state.documentVersion = responseVersion;
    state.documentHash = responseHash;
    state.lastDocumentName = name;
    state.zoom = renderZoom;
    state.renderedZoom = renderZoom;
    updateZoomLabel();
    state.log = [...pending.history];
    state.historyCursor = Number.isInteger(pending.historyCursor)
      ? pending.historyCursor
      : historyOperations().length;
    state.historyRevision = pending.historyRevision;
    state.active.clear();
    state.liveHighlighters.clear();
    clearPinchPreview();
    state.pages = rendered.pages;
    pagesElement.replaceChildren(rendered.fragment);
    preparedRender = null;
    releaseRenderedPages(previousPages);
    redrawInk();
    documentName.textContent = name;
    if (pending.viewport && documentMatches(pending.viewport, state)) {
      scrollToViewport(pending.viewport, true);
    } else {
      scroll.scrollLeft = 0;
      scroll.scrollTop = 0;
    }
    loading.hidden = true;
    send({
      type: "pdf:ready",
      documentId: responseId,
      documentVersion: responseVersion,
      documentHash: responseHash,
      transactionId: descriptor.transactionId,
      pageCount: nextPDF.numPages,
    });
    notifyNativeState();
    if (previousPDF && previousPDF !== nextPDF) void disposePDF(previousPDF);
    return true;
  } catch (error) {
    if (preparedRender?.pages) releaseRenderedPages(preparedRender.pages);
    if (generation !== state.pdfLoadGeneration || state.pendingDocument !== pending) return false;
    if (error?.name === "AbortError" && !timedOut) return false;
    const fallback = timedOut ? "PDF 下载或打开超过 120 秒" : "未知错误";
    const message = String(timedOut ? fallback : (error?.message || fallback)).replace(/\s+/g, " ").slice(0, 140);
    console.error("PDF load failed", error);
    loading.textContent = `PDF 加载失败：${message}`;
    send({
      type: "pdf:error",
      documentId,
      documentVersion,
      documentHash,
      transactionId: descriptor.transactionId,
      error: message,
    });
    state.pendingDocument = null;
    if (state.pdfLoadingTask) void disposePDF(null, state.pdfLoadingTask);
    state.pdfLoadingTask = null;
    return false;
  } finally {
    clearTimeout(timeout);
    if (generation === state.pdfLoadGeneration) {
      state.loadingPDF = false;
      state.pdfFetchController = null;
    }
  }
}

async function applySnapshot(message) {
  if (!protocol.acceptSnapshot(message)) return;
  try {
    if (message.mode === "pdf" || message.mode === "whiteboard") {
      state.appMode = message.mode;
      notifyNativeMode(message.mode);
    }
    if (message.document) {
      await loadPDF(message.document, "", {
        initialViewport: message.viewport,
        initialHistory: message.history,
        initialHistoryCursor: message.historyCursor,
        initialHistoryRevision: message.historyRevision,
      });
    } else {
      await clearPDFForEmptySnapshot();
    }
    if (!message.document || !descriptorMatches(message.document, state)) {
      notifyNativeState();
      return;
    }
    state.log = Array.isArray(message.history) ? [...message.history] : [];
    state.historyCursor = Number.isInteger(message.historyCursor)
      ? message.historyCursor
      : historyOperations().length;
    state.historyRevision = Math.max(0, Number(message.historyRevision || 0));
    state.active.clear();
    state.liveHighlighters.clear();
    state.renderedStrokeSequences.clear();
    state.pages.forEach(clearInkCanvas);
    state.pages.forEach(clearLiveInkCanvas);
    redrawInk();
    if (message.viewport) {
      if (state.pdf && documentMatches(message.viewport, state)) queueRemoteViewport(message.viewport);
    }
    notifyNativeState();
  } finally {
    state.awaitingSnapshot = false;
    replayStrokeOutbox();
  }
}

function setToolButtons() {
  document.querySelectorAll("[data-pdf-color]").forEach((button) => button.classList.toggle("selected", button.dataset.pdfColor === state.color));
  document.querySelectorAll("[data-pdf-width]").forEach((button) => button.classList.toggle("selected", Number(button.dataset.pdfWidth) === state.width));
  document.querySelector("#pdfEraser").setAttribute("aria-pressed", String(state.manualEraser));
  const operationCount = historyOperations().length;
  const undo = document.querySelector("#pdfUndo");
  const redo = document.querySelector("#pdfRedo");
  if (undo) undo.disabled = state.historyCursor <= 0;
  if (redo) redo.disabled = state.historyCursor >= operationCount;
}

function connect() {
  if (!room) { setConnection("failed", "缺少房间号"); return; }
  clearTimeout(state.reconnect);
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  state.socket = new WebSocket(`${scheme}//${location.host}/ws`);
  state.awaitingSnapshot = true;
  setConnection("", "正在连接");
  state.socket.addEventListener("open", () => {
    state.connected = true;
    setConnection("connected", "已连接");
    protocol.resetForConnection();
    state.socket.send(JSON.stringify(protocol.join(room, [
      "snapshot",
      "document-ready",
      "document-hash",
      "document-lifecycle",
      "document-progress",
      "document-reload",
      "viewport-v3",
      "viewport-control",
      "page-coordinate-v2",
      "native-input",
      "native-pen-v2",
      "stroke-batch-v2",
      "highlighter-v1",
      "stroke-replace-v1",
      "stroke-idempotency",
      "history-v1",
      "durable-project-v1",
      "transport-control-v1",
    ])));
    reportNativeTransportStatus();
    notifyNativeState();
  });
  state.socket.addEventListener("message", async (event) => {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message.type === "session:snapshot") {
      await applySnapshot(message);
      return;
    }
    if (!protocol.accept(message)) return;
    if (message.type === "ack") {
      acknowledgeStroke(message);
      return;
    }
    if (message.type === "session:welcome") return;
    if (message.type === "sync") {
      state.log = Array.isArray(message.history) ? [...message.history] : [];
      state.historyCursor = Number.isInteger(message.historyCursor)
        ? message.historyCursor
        : historyOperations().length;
      state.historyRevision = Math.max(0, Number(message.historyRevision || 0));
      state.active.clear();
      state.liveHighlighters.clear();
      state.renderedStrokeSequences.clear();
      let latestViewport = null;
      for (const item of state.log) {
        if (item.type === "pdf:viewport") latestViewport = item;
      }
      redrawInk();
      if (latestViewport) {
        if (state.pdf) queueRemoteViewport(latestViewport);
        else state.pendingViewport = latestViewport;
      }
      return;
    }
    if (message.type === "app:mode") {
      if (message.mode === "pdf" || message.mode === "whiteboard") {
        state.appMode = message.mode;
        notifyNativeMode(message.mode);
        notifyNativeState();
      }
      return;
    }
    if (message.type === "transport:request") {
      notifyNativeTransportRequest(message);
      return;
    }
    if (message.type === "transport:status") return;
    if (message.type === "screen-mirror:request") {
      notifyNativeScreenMirrorRequest(message);
      return;
    }
    if (message.type === "screen-mirror:status") return;
    if (message.type === "roundtrip:open") {
      notifyNativeRoundTripOpen(message);
      return;
    }
    if (message.type === "roundtrip:return-ready") return;
    if (message.type === "pdf:document") {
      await loadPDF(message, "", {
        initialHistory: message.history,
        initialHistoryCursor: message.historyCursor,
        initialHistoryRevision: message.historyRevision,
      });
      return;
    }
    if (message.type === "pdf:reload") {
      if (documentMatches(message, state)
        || descriptorMatches(message, state.pendingDocument?.descriptor)) {
        await loadPDF(message, "", { force: true });
      }
      return;
    }
    if (message.type === "pdf:viewport") {
      if (descriptorMatches(message, state.pendingDocument?.descriptor)) {
        state.pendingDocument.viewport = message;
        return;
      }
      if (state.pdf && documentMatches(message, state)) queueRemoteViewport(message);
      return;
    }
    if (descriptorMatches(message, state.pendingDocument?.descriptor)) {
      if (message.type === "clear") {
        state.pendingDocument.history.push(message);
        if (Number.isInteger(message.historyCursor)) state.pendingDocument.historyCursor = message.historyCursor;
        if (Number.isFinite(message.historyRevision)) state.pendingDocument.historyRevision = message.historyRevision;
      } else if (message.type?.startsWith("stroke:")) {
        state.pendingDocument.history.push(message);
        if (message.type === "stroke:end" && Number.isInteger(message.historyCursor)) {
          state.pendingDocument.historyCursor = message.historyCursor;
        }
        if (message.type === "stroke:end" && Number.isFinite(message.historyRevision)) {
          state.pendingDocument.historyRevision = message.historyRevision;
        }
      }
      else if ((message.type === "history:undo" || message.type === "history:redo")
        && message.mode !== "whiteboard") {
        state.pendingDocument.historyCursor = message.historyCursor;
        state.pendingDocument.historyRevision = message.historyRevision;
      }
      return;
    }
    if ((message.type === "history:undo" || message.type === "history:redo")
      && message.mode !== "whiteboard") {
      applyHistoryState(message);
      return;
    }
    if (message.type === "cursor:move" && Number.isInteger(message.pageIndex)) {
      showHover(state.pages.get(message.pageIndex), message.point, {
        tool: message.tool,
        size: message.tool === "eraser" && Number.isFinite(message.eraserRatio)
          ? message.eraserRatio * Math.min(
            state.pages.get(message.pageIndex)?.width || 1,
            state.pages.get(message.pageIndex)?.height || 1,
          )
          : undefined,
      });
      return;
    }
    if (message.type === "cursor:hide") { hideHover(); return; }
    renderMessage(message);
  });
  state.socket.addEventListener("close", () => {
    state.connected = false;
    state.awaitingSnapshot = true;
    state.strokeAckByMessageId.clear();
    setConnection("failed", "连接已断开");
    notifyNativeState();
    state.reconnect = setTimeout(connect, 1600);
  });
  state.socket.addEventListener("error", () => state.socket.close());
}

scroll.addEventListener("pointerdown", startTouchGesture);
scroll.addEventListener("pointermove", moveTouchGesture);
scroll.addEventListener("pointerup", endTouchGesture);
scroll.addEventListener("pointercancel", endTouchGesture);
scroll.addEventListener("scroll", handleNativeScrollFallback, { passive: true });
document.querySelectorAll("[data-pdf-color]").forEach((button) => button.addEventListener("click", () => {
  state.color = button.dataset.pdfColor;
  state.manualEraser = false;
  setToolButtons();
  notifyNativeState();
}));
document.querySelectorAll("[data-pdf-width]").forEach((button) => button.addEventListener("click", () => {
  state.width = Number(button.dataset.pdfWidth);
  setToolButtons();
  notifyNativeState();
}));
document.querySelector("#pdfEraser").addEventListener("click", () => {
  state.manualEraser = !state.manualEraser;
  setToolButtons();
  notifyNativeState();
});
document.querySelector("#pdfZoomOut").addEventListener("click", () => {
  zoomAroundViewport(state.zoom / 1.2);
  notifyNativeState();
});
document.querySelector("#pdfZoomIn").addEventListener("click", () => {
  zoomAroundViewport(state.zoom * 1.2);
  notifyNativeState();
});
document.querySelector("#pdfUndo")?.addEventListener("click", () => requestHistoryChange("history:undo"));
document.querySelector("#pdfRedo")?.addEventListener("click", () => requestHistoryChange("history:redo"));
document.querySelector("#pdfClear").addEventListener("click", () => {
  if (state.historyCursor > 0 && !confirm("确定要清空全部 PDF 批注吗？清空后仍可撤销。")) return;
  send({ type: "clear", mode: "pdf" });
});

window.nativeGetState = () => {
  notifyNativeState();
  return JSON.stringify(nativeState());
};
window.nativeSetColor = (color) => {
  if (typeof color === "string" && /^#[0-9a-f]{6}$/i.test(color)) state.color = color;
  state.manualEraser = false;
  setToolButtons();
  notifyNativeState();
};
window.nativeSetWidth = (width) => {
  const value = Number(width);
  if (Number.isFinite(value)) state.width = Math.max(0.8, Math.min(20, value));
  setToolButtons();
  notifyNativeState();
};
window.nativeSetEraser = (enabled) => {
  state.manualEraser = Boolean(enabled);
  setToolButtons();
  notifyNativeState();
};
window.nativeSetTool = (tool) => {
  if (!["ink", "highlighter", "eraser"].includes(tool)) return;
  state.manualEraser = tool === "eraser";
  if (tool !== "eraser") state.tool = tool;
  setToolButtons();
  notifyNativeState();
};
window.nativeSetHighlighterWidth = (width) => {
  const value = Number(width);
  if (Number.isFinite(value)) state.highlighterWidth = Math.max(4, Math.min(48, value));
  notifyNativeState();
};
window.nativeSetHighlighterOpacity = (opacity) => {
  const value = Number(opacity);
  if (Number.isFinite(value)) state.highlighterOpacity = Math.max(0.05, Math.min(0.8, value));
  notifyNativeState();
};
window.nativeSetEraserSize = (size) => {
  const value = Number(size);
  if (Number.isFinite(value)) state.eraserSize = Math.max(24, Math.min(144, value));
  notifyNativeState();
};
window.nativeZoomOut = () => {
  zoomAroundViewport(state.zoom / 1.2);
  notifyNativeState();
};
window.nativeZoomIn = () => {
  zoomAroundViewport(state.zoom * 1.2);
  notifyNativeState();
};
window.nativeClear = () => {
  send({ type: "clear", mode: "pdf" });
};
window.nativeUndo = () => requestHistoryChange("history:undo");
window.nativeRedo = () => requestHistoryChange("history:redo");
window.nativeSwitchMode = (mode) => {
  if (mode !== "pdf" && mode !== "whiteboard") return;
  state.appMode = mode;
  send({ type: "app:mode", mode });
  notifyNativeState();
};
window.nativeReportTransportStatus = reportNativeTransportStatus;
window.nativeReportScreenMirrorStatus = reportNativeScreenMirrorStatus;
window.nativeRequestScreenMirror = requestNativeScreenMirror;
window.nativeReportHover = reportNativeHover;
window.nativeReportHoverHidden = sendHoverHidden;
window.nativePenStart = startNativeStroke;
window.nativePenMove = moveNativeStroke;
window.nativePenEnd = endNativeStroke;
window.nativePenCancel = cancelNativeStroke;
window.nativePenStraighten = () => replaceNativeStrokeWithStraight();
window.nativePenUpdateStraight = (sample) => replaceNativeStrokeWithStraight(sample);
window.nativePenSwitchToEraser = switchNativeStrokeToEraser;

setToolButtons();
connect();
