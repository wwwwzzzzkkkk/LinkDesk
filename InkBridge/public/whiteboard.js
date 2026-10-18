import {
  WHITEBOARD_COORDINATE_SPACE,
  WHITEBOARD_MAX_ZOOM,
  WHITEBOARD_MIN_ZOOM,
  createProtocolClient,
  normalizeWhiteboardViewport,
} from "/inkbridge-protocol.js";

const params = new URLSearchParams(location.search);
const isPad = params.get("role") === "pad";
const nativeInput = params.get("nativeInput") === "true";
const nativeTransport = ["wifi", "usb"].includes(params.get("transport"))
  ? params.get("transport")
  : "";
const nativeTransportPreference = ["automatic", "wifi", "usb"].includes(params.get("transportPreference"))
  ? params.get("transportPreference")
  : "wifi";
const nativeTransportRequestId = (params.get("transportRequestId") || "").replace(/[^A-Za-z0-9._:-]/g, "").slice(0, 72);
const HIGHLIGHTER_HOLD_DELAY_MS = 2000;
const HIGHLIGHTER_HOLD_SLOP_PX = 18;
const protocol = createProtocolClient(isPad ? "pad" : "board");
let room = (params.get("room") || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 6);
if (room.length !== 6) room = makeRoomCode();
if (!params.get("room")) {
  params.set("room", room);
  params.set("role", isPad ? "pad" : "board");
  history.replaceState(null, "", `?${params}`);
}

const canvas = document.querySelector(isPad ? "#padCanvas" : "#drawCanvas");
const context = canvas.getContext("2d");
const gridCanvas = document.createElement("canvas");
gridCanvas.className = "whiteboard-grid-canvas";
gridCanvas.setAttribute("aria-hidden", "true");
canvas.insertAdjacentElement("beforebegin", gridCanvas);
const gridContext = gridCanvas.getContext("2d");
const liveHighlighterCanvas = document.createElement("canvas");
liveHighlighterCanvas.className = "live-highlighter-canvas";
liveHighlighterCanvas.setAttribute("aria-hidden", "true");
canvas.insertAdjacentElement("afterend", liveHighlighterCanvas);
const liveHighlighterContext = liveHighlighterCanvas.getContext("2d");
const empty = document.querySelector("#boardEmpty");
const eraserCursor = document.querySelector("#eraserCursor");
const hoverCursor = document.querySelector(isPad ? "#padApp #hoverCursor" : "#boardApp #hoverCursor");
const pdfPreview = document.querySelector("#pdfPreview");
const pressureThreshold = 0.90;
const defaultWritingAspect = 3 / 2;
const whiteboardWorldHeight = 1000;
const state = {
  color: "#152441",
  width: 4.5,
  tool: "ink",
  highlighterWidth: 14,
  highlighterOpacity: 0.32,
  highlighterColor: "#FFE55B",
  eraserSize: 48,
  log: [],
  historyCursor: 0,
  historyRevision: 0,
  active: new Map(),
  liveHighlighters: new Map(),
  renderedStrokeSequences: new Map(),
  hasInk: false,
  socket: null,
  reconnect: null,
  pending: [],
  flushFrame: null,
  pendingStroke: null,
  pendingStrokeSequence: 0,
  lastNativePoint: null,
  nativeStartPoint: null,
  lastNativeSampleIndex: -1,
  nativeHighlighterHoldTimer: null,
  nativeHighlighterPausePoint: null,
  nativeHighlighterStraightLocked: false,
  activeTool: "ink",
  inputMode: "pen",
  manualEraser: false,
  pressureEraser: true,
  toastTimer: null,
  hoverFrame: null,
  pendingHover: null,
  strokeOutbox: new Map(),
  strokeAckByMessageId: new Map(),
  awaitingSnapshot: true,
  appMode: "whiteboard",
  connected: false,
  whiteboardViewport: { centerX: 0, centerY: 0, zoom: 1 },
  viewportPointers: new Map(),
  viewportGesture: null,
  viewportSendFrame: null,
};

document.querySelector("#boardApp").hidden = isPad;
document.querySelector("#padApp").hidden = !isPad;
if (nativeInput) document.documentElement.classList.add("native-pad-mode");
document.querySelector(isPad ? "#padRoomCode" : "#roomCode").textContent = room;

function makeRoomCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const values = crypto.getRandomValues(new Uint8Array(6));
  return [...values].map((value) => alphabet[value % alphabet.length]).join("");
}

function setConnection(kind, text) {
  const dot = document.querySelector(isPad ? "#padConnectionDot" : "#connectionDot");
  dot.className = kind || "";
  document.querySelector(isPad ? "#padConnectionText" : "#connectionText").textContent = text;
}

function showPDFPreview(preview) {
  if (!isPad || !pdfPreview || typeof preview !== "string") return;
  pdfPreview.src = preview;
  pdfPreview.hidden = false;
}

function pdfInputViewport() {
  const rect = canvas.getBoundingClientRect();
  if (!isPad || !pdfPreview || pdfPreview.hidden || !pdfPreview.naturalWidth || !pdfPreview.naturalHeight) {
    return { left: 0, top: 0, width: rect.width, height: rect.height };
  }
  const imageAspect = pdfPreview.naturalWidth / pdfPreview.naturalHeight;
  const stageAspect = rect.width / rect.height;
  if (stageAspect > imageAspect) {
    const height = rect.height;
    const width = height * imageAspect;
    return { left: (rect.width - width) / 2, top: 0, width, height };
  }
  const width = rect.width;
  const height = width / imageAspect;
  return { left: 0, top: (rect.height - height) / 2, width, height };
}

function isInsideInputViewport(event) {
  const rect = canvas.getBoundingClientRect();
  const viewport = pdfInputViewport();
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;
  return x >= viewport.left && x <= viewport.left + viewport.width && y >= viewport.top && y <= viewport.top + viewport.height;
}

function resetPadInkForNewPDFViewport() {
  if (!isPad || drawing) return;
  state.log = [];
  state.active.clear();
  state.liveHighlighters.clear();
  state.hasInk = false;
  clearPixels();
  clearLiveHighlighterPixels();
}

if (pdfPreview) pdfPreview.addEventListener("load", () => {
  resetPadInkForNewPDFViewport();
  redraw();
});

function fitCanvas() {
  const rect = canvas.getBoundingClientRect();
  const ratio = Math.min(devicePixelRatio || 1, 2);
  canvas.width = Math.max(1, Math.round(rect.width * ratio));
  canvas.height = Math.max(1, Math.round(rect.height * ratio));
  gridCanvas.width = canvas.width;
  gridCanvas.height = canvas.height;
  liveHighlighterCanvas.width = canvas.width;
  liveHighlighterCanvas.height = canvas.height;
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  gridContext.setTransform(ratio, 0, 0, ratio, 0, 0);
  liveHighlighterContext.setTransform(ratio, 0, 0, ratio, 0, 0);
  drawWorldGrid();
  redraw();
  redrawLiveHighlighters();
}

function localViewportSize() {
  const rect = canvas.getBoundingClientRect();
  return { width: Math.max(1, rect.width), height: Math.max(1, rect.height) };
}

function worldScale(zoom = state.whiteboardViewport.zoom) {
  return localViewportSize().height / whiteboardWorldHeight * zoom;
}

function screenToWorld(x, y, viewport = state.whiteboardViewport) {
  const size = localViewportSize();
  const scale = worldScale(viewport.zoom);
  return {
    x: viewport.centerX + (x - size.width / 2) / scale,
    y: viewport.centerY + (y - size.height / 2) / scale,
  };
}

function worldToScreen(point, viewport = state.whiteboardViewport) {
  const size = localViewportSize();
  const scale = worldScale(viewport.zoom);
  return {
    x: size.width / 2 + (point.x - viewport.centerX) * scale,
    y: size.height / 2 + (point.y - viewport.centerY) * scale,
  };
}

function legacyPointToWorld(point, canvasAspect = defaultWritingAspect) {
  const aspect = Number.isFinite(canvasAspect) && canvasAspect > 0 ? canvasAspect : defaultWritingAspect;
  return {
    ...point,
    x: (point.x - 0.5) * whiteboardWorldHeight * aspect,
    y: (point.y - 0.5) * whiteboardWorldHeight,
  };
}

function pointToScreen(point, stroke) {
  const world = stroke.coordinateSpace === WHITEBOARD_COORDINATE_SPACE
    ? point
    : legacyPointToWorld(point, stroke.canvasAspect);
  return worldToScreen(world);
}

function screenStrokeWidth(value, stroke) {
  const width = Number.isFinite(value) ? value : 1;
  return width * state.whiteboardViewport.zoom;
}

function drawWorldGrid() {
  const size = localViewportSize();
  const scale = worldScale();
  const candidates = [12, 24, 48, 96, 192, 384, 768, 1536, 3072, 6144];
  const spacing = candidates.find((candidate) => candidate * scale >= 18) || candidates[candidates.length - 1];
  const visibleLeft = state.whiteboardViewport.centerX - size.width / (2 * scale);
  const visibleTop = state.whiteboardViewport.centerY - size.height / (2 * scale);
  const startX = Math.floor(visibleLeft / spacing) * spacing;
  const startY = Math.floor(visibleTop / spacing) * spacing;
  gridContext.save();
  gridContext.setTransform(1, 0, 0, 1, 0, 0);
  gridContext.clearRect(0, 0, gridCanvas.width, gridCanvas.height);
  const ratio = Math.min(devicePixelRatio || 1, 2);
  gridContext.setTransform(ratio, 0, 0, ratio, 0, 0);
  gridContext.fillStyle = "rgba(174, 184, 202, 0.54)";
  const radius = Math.min(1.25, Math.max(0.7, scale * spacing / 34));
  for (let worldY = startY; worldY <= visibleTop + size.height / scale + spacing; worldY += spacing) {
    for (let worldX = startX; worldX <= visibleLeft + size.width / scale + spacing; worldX += spacing) {
      const point = worldToScreen({ x: worldX, y: worldY });
      gridContext.beginPath();
      gridContext.arc(point.x, point.y, radius, 0, Math.PI * 2);
      gridContext.fill();
    }
  }
  gridContext.restore();
}

function clearPixels() {
  context.save();
  context.globalCompositeOperation = "source-over";
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.restore();
}

function clearLiveHighlighterPixels() {
  liveHighlighterContext.save();
  liveHighlighterContext.setTransform(1, 0, 0, 1, 0, 0);
  liveHighlighterContext.clearRect(0, 0, liveHighlighterCanvas.width, liveHighlighterCanvas.height);
  liveHighlighterContext.restore();
  liveHighlighterCanvas.style.opacity = "1";
  liveHighlighterCanvas.dataset.strokeId = "";
}

function pressureWidth(pressure, baseWidth, tool, eraserSize) {
  if (tool === "eraser") return eraserSize || Math.max(30, baseWidth * 8);
  if (tool === "highlighter") return Math.max(1.2, baseWidth);
  const p = Number.isFinite(pressure) && pressure > 0 ? pressure : 0.52;
  return Math.max(1.2, baseWidth * (0.38 + p * 0.85));
}

function strokeViewport(stroke) {
  const rect = canvas.getBoundingClientRect();
  const canvasAspect = rect.width / rect.height;
  const strokeAspect = Number.isFinite(stroke.canvasAspect) && stroke.canvasAspect > 0 ? stroke.canvasAspect : canvasAspect;
  if (canvasAspect > strokeAspect) {
    const height = rect.height;
    const width = height * strokeAspect;
    return { left: (rect.width - width) / 2, top: 0, width, height };
  }
  const width = rect.width;
  const height = width / strokeAspect;
  return { left: 0, top: (rect.height - height) / 2, width, height };
}

function scaledEraserSize(stroke, viewport) {
  if (!Number.isFinite(stroke.eraserRatio)) return stroke.eraserSize;
  return stroke.eraserRatio * Math.min(viewport.width, viewport.height);
}

function drawDot(point, color, width, tool, eraserSize, stroke, opacity = 1) {
  const location = pointToScreen(point, stroke);
  const diameter = screenStrokeWidth(pressureWidth(point.p, width, tool, eraserSize), stroke);
  context.save();
  context.globalCompositeOperation = tool === "eraser" ? "destination-out" : "source-over";
  context.globalAlpha = tool === "highlighter" ? opacity : 1;
  context.fillStyle = color;
  context.beginPath();
  context.arc(location.x, location.y, diameter / 2, 0, Math.PI * 2);
  context.fill();
  context.restore();
}

function drawSegment(before, point, color, width, tool, eraserSize, stroke, opacity = 1) {
  const start = pointToScreen(before, stroke);
  const end = pointToScreen(point, stroke);
  context.save();
  context.globalCompositeOperation = tool === "eraser" ? "destination-out" : "source-over";
  context.globalAlpha = tool === "highlighter" ? opacity : 1;
  context.strokeStyle = color;
  context.lineCap = "round";
  context.lineJoin = "round";
  context.lineWidth = screenStrokeWidth(pressureWidth((before.p + point.p) / 2, width, tool, eraserSize), stroke);
  context.beginPath();
  context.moveTo(start.x, start.y);
  context.lineTo(end.x, end.y);
  context.stroke();
  context.restore();
}

function effectiveStrokeEvents(events) {
  let replaceIndex = -1;
  for (let index = 0; index < events.length; index += 1) {
    if (events[index].type === "stroke:replace") replaceIndex = index;
  }
  return replaceIndex >= 0 ? events.slice(replaceIndex) : events;
}

function drawHighlighterStroke(points, stroke, targetContext = context) {
  targetContext.save();
  targetContext.globalCompositeOperation = "source-over";
  targetContext.globalAlpha = stroke.opacity;
  targetContext.strokeStyle = stroke.color;
  targetContext.fillStyle = stroke.color;
  targetContext.lineCap = "round";
  targetContext.lineJoin = "round";
  targetContext.lineWidth = Math.max(1.2, screenStrokeWidth(stroke.width, stroke));
  if (points.length === 1) {
    const point = points[0];
    const { x, y } = pointToScreen(point, stroke);
    targetContext.beginPath();
    targetContext.arc(x, y, targetContext.lineWidth / 2, 0, Math.PI * 2);
    targetContext.fill();
  } else if (points.length > 1) {
    const first = points[0];
    targetContext.beginPath();
    const start = pointToScreen(first, stroke);
    targetContext.moveTo(start.x, start.y);
    for (const point of points.slice(1)) {
      const next = pointToScreen(point, stroke);
      targetContext.lineTo(next.x, next.y);
    }
    targetContext.stroke();
  }
  targetContext.restore();
}

function redrawLiveHighlighters() {
  clearLiveHighlighterPixels();
  let hasLiveInk = false;
  const strokes = [...state.liveHighlighters.entries()];
  if (strokes.length === 1) {
    const [strokeId, stroke] = strokes[0];
    // Draw an opaque live mask and apply opacity once to the layer. This keeps
    // incremental segment joins at the same visual density as the final path.
    liveHighlighterCanvas.style.opacity = String(stroke.opacity);
    liveHighlighterCanvas.dataset.strokeId = strokeId;
    drawHighlighterStroke(stroke.points, { ...stroke, opacity: 1 }, liveHighlighterContext);
  } else {
    for (const [, stroke] of strokes) {
      drawHighlighterStroke(stroke.points, stroke, liveHighlighterContext);
    }
  }
  for (const [strokeId, stroke] of strokes) {
    hasLiveInk ||= stroke.points.length > 0;
    if (Number.isInteger(stroke.maximumSequence)) {
      state.renderedStrokeSequences.set(strokeId, stroke.maximumSequence);
    }
  }
  state.hasInk ||= hasLiveInk;
  if (empty && state.hasInk) empty.hidden = true;
}

function appendLiveHighlighter(strokeId, stroke, previousPointCount, forceRedraw = false) {
  if (forceRedraw
    || state.liveHighlighters.size !== 1
    || liveHighlighterCanvas.dataset.strokeId !== strokeId) {
    redrawLiveHighlighters();
    return;
  }
  liveHighlighterCanvas.style.opacity = String(stroke.opacity);
  const firstNewIndex = Math.max(0, previousPointCount - 1);
  const incrementalPoints = stroke.points.slice(firstNewIndex);
  if (incrementalPoints.length > 1) {
    drawHighlighterStroke(incrementalPoints, { ...stroke, opacity: 1 }, liveHighlighterContext);
  }
}

function renderLiveHighlighter(message) {
  const stroke = state.liveHighlighters.get(message.strokeId) || {
    color: message.color || state.highlighterColor,
    width: message.width || state.highlighterWidth,
    tool: "highlighter",
    opacity: Number.isFinite(message.opacity) ? message.opacity : state.highlighterOpacity,
    canvasAspect: Number.isFinite(message.canvasAspect) ? message.canvasAspect : defaultWritingAspect,
    coordinateSpace: message.coordinateSpace,
    points: [],
    maximumSequence: -1,
  };
  const previousPointCount = stroke.points.length;
  const previousStyle = `${stroke.color}:${stroke.width}:${stroke.opacity}:${stroke.canvasAspect}:${stroke.coordinateSpace}`;
  if (message.color) stroke.color = message.color;
  if (Number.isFinite(message.width)) stroke.width = message.width;
  if (Number.isFinite(message.opacity)) stroke.opacity = Math.max(0.05, Math.min(1, message.opacity));
  if (Number.isFinite(message.canvasAspect)) stroke.canvasAspect = message.canvasAspect;
  if (message.coordinateSpace === WHITEBOARD_COORDINATE_SPACE) stroke.coordinateSpace = message.coordinateSpace;
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
    state.liveHighlighters.delete(message.strokeId);
    clearLiveHighlighterPixels();
    drawHighlighterStroke(stroke.points, stroke);
    state.hasInk = state.hasInk || stroke.points.length > 0;
    redrawLiveHighlighters();
    if (empty) empty.hidden = state.hasInk;
    return;
  }
  state.liveHighlighters.set(message.strokeId, stroke);
  const styleChanged = previousStyle
    !== `${stroke.color}:${stroke.width}:${stroke.opacity}:${stroke.canvasAspect}:${stroke.coordinateSpace}`;
  appendLiveHighlighter(message.strokeId, stroke, replaced ? 0 : previousPointCount, replaced || styleChanged);
  state.hasInk = state.hasInk || stroke.points.length > 0;
  if (empty && state.hasInk) empty.hidden = true;
}

function renderHighlighterOperation(events) {
  const seed = events[0];
  if (!seed?.strokeId) return;
  const stroke = {
    color: seed.color || state.highlighterColor,
    width: seed.width || state.highlighterWidth,
    tool: "highlighter",
    opacity: Number.isFinite(seed.opacity) ? seed.opacity : state.highlighterOpacity,
    eraserSize: state.eraserSize,
    eraserRatio: null,
    canvasAspect: Number.isFinite(seed.canvasAspect) ? seed.canvasAspect : defaultWritingAspect,
    coordinateSpace: seed.coordinateSpace,
    last: null,
  };
  const points = [];
  let ended = false;
  let maximumSequence = -1;
  for (const message of events) {
    if (message.color) stroke.color = message.color;
    if (Number.isFinite(message.width)) stroke.width = message.width;
    if (Number.isFinite(message.opacity)) stroke.opacity = Math.max(0.05, Math.min(1, message.opacity));
    if (Number.isFinite(message.canvasAspect)) stroke.canvasAspect = message.canvasAspect;
    if (message.coordinateSpace === WHITEBOARD_COORDINATE_SPACE) stroke.coordinateSpace = message.coordinateSpace;
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
  drawHighlighterStroke(points, stroke);
  if (points.length) state.hasInk = true;
  stroke.last = points[points.length - 1] || null;
  if (maximumSequence >= 0) state.renderedStrokeSequences.set(seed.strokeId, maximumSequence);
  if (ended) state.active.delete(seed.strokeId);
  else state.active.set(seed.strokeId, stroke);
}

function render(message, save = true) {
  if (message.type === "clear") {
    if (save) recordHistoryMessage(message);
    state.active.clear();
    state.liveHighlighters.clear();
    state.renderedStrokeSequences.clear();
    state.hasInk = false;
    clearPixels();
    clearLiveHighlighterPixels();
    if (empty) empty.hidden = false;
    return;
  }
  if (!message.type?.startsWith("stroke:")) return;
  if (Number.isInteger(message.strokeSequence)) {
    const previous = state.renderedStrokeSequences.get(message.strokeId);
    if (Number.isInteger(previous) && message.strokeSequence <= previous) return;
    state.renderedStrokeSequences.set(message.strokeId, message.strokeSequence);
  }
  if (save) recordHistoryMessage(message);
  if (message.type === "stroke:start" && !Number.isFinite(message.canvasAspect)) {
    message.canvasAspect = defaultWritingAspect;
  }
  const activeTool = state.liveHighlighters.get(message.strokeId)?.tool
    || state.active.get(message.strokeId)?.tool;
  if (save && (message.tool === "highlighter" || activeTool === "highlighter")) {
    renderLiveHighlighter(message);
    return;
  }
  if (save && message.type === "stroke:replace") {
    redraw();
    return;
  }

  const stroke = state.active.get(message.strokeId) || {
    color: message.color || state.color,
    width: message.width || 4.5,
    tool: ["ink", "highlighter", "eraser"].includes(message.tool) ? message.tool : "ink",
    opacity: Number.isFinite(message.opacity) ? message.opacity : 1,
    eraserSize: Number.isFinite(message.eraserSize) ? message.eraserSize : Math.max(30, (message.width || 4.5) * 8),
    eraserRatio: Number.isFinite(message.eraserRatio) ? message.eraserRatio : null,
    canvasAspect: Number.isFinite(message.canvasAspect) ? message.canvasAspect : null,
    coordinateSpace: message.coordinateSpace,
    last: null,
  };
  if (message.color) stroke.color = message.color;
  if (message.width) stroke.width = message.width;
  if (["ink", "highlighter", "eraser"].includes(message.tool)) stroke.tool = message.tool;
  if (Number.isFinite(message.opacity)) stroke.opacity = Math.max(0.05, Math.min(1, message.opacity));
  if (Number.isFinite(message.eraserSize)) stroke.eraserSize = message.eraserSize;
  if (Number.isFinite(message.eraserRatio)) stroke.eraserRatio = message.eraserRatio;
  if (Number.isFinite(message.canvasAspect)) stroke.canvasAspect = message.canvasAspect;
  if (message.coordinateSpace === WHITEBOARD_COORDINATE_SPACE) stroke.coordinateSpace = message.coordinateSpace;
  if (message.type === "stroke:replace") stroke.last = null;
  const points = message.type === "stroke:move" || message.type === "stroke:replace"
    ? message.points
    : [message.point];

  for (const point of points) {
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) continue;
    const legacyViewport = strokeViewport(stroke);
    const eraserSize = stroke.coordinateSpace === WHITEBOARD_COORDINATE_SPACE
      ? stroke.eraserSize
      : scaledEraserSize(stroke, legacyViewport);
    if (stroke.last) drawSegment(stroke.last, point, stroke.color, stroke.width, stroke.tool, eraserSize, stroke, stroke.opacity);
    else drawDot(point, stroke.color, stroke.width, stroke.tool, eraserSize, stroke, stroke.opacity);
    stroke.last = point;
    state.hasInk = true;
  }
  if (empty && state.hasInk) empty.hidden = true;
  if (message.type === "stroke:end") state.active.delete(message.strokeId);
  else state.active.set(message.strokeId, stroke);
}

function redraw() {
  drawWorldGrid();
  clearPixels();
  const operations = historyOperations();
  state.historyCursor = Math.max(0, Math.min(operations.length, state.historyCursor));
  const visibleOperations = operations.slice(0, state.historyCursor);
  for (const operation of operations.slice(state.historyCursor)) {
    if (operation.events.some((message) => message.type?.startsWith("stroke:"))
      && !operation.events.some((message) => message.type === "stroke:end")) {
      visibleOperations.push(operation);
    }
  }
  state.active.clear();
  state.renderedStrokeSequences.clear();
  state.hasInk = false;
  for (const operation of visibleOperations) {
    if (operation.events.some((message) => message.type === "clear")) {
      render(operation.events.find((message) => message.type === "clear"), false);
      continue;
    }
    if (state.liveHighlighters.has(operation.events[0]?.strokeId)) continue;
    const events = effectiveStrokeEvents(operation.events);
    if (events.some((message) => message.tool === "highlighter")) renderHighlighterOperation(events);
    else for (const message of events) render(message, false);
  }
  if (empty) empty.hidden = state.hasInk;
}

function historyOperations(messages = state.log) {
  const operations = [];
  const byId = new Map();
  for (const message of messages) {
    if (!message || (message.type !== "clear" && !message.type?.startsWith("stroke:"))) continue;
    const operationId = message.operationId
      || (message.type.startsWith("stroke:") && message.strokeId
        ? `stroke:${message.strokeId}`
        : `clear:${operations.length}`);
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

function truncateRedoHistory() {
  const operations = historyOperations();
  if (state.historyCursor >= operations.length) return;
  state.log = operations.slice(0, state.historyCursor).flatMap((operation) => operation.events);
}

function recordHistoryMessage(message) {
  if (message.type === "clear" || message.type === "stroke:start") truncateRedoHistory();
  state.log.push(message);
  if (message.type === "clear" || message.type === "stroke:end") {
    const operationCount = historyOperations().length;
    state.historyCursor = Number.isInteger(message.historyCursor)
      ? Math.max(0, Math.min(operationCount, message.historyCursor))
      : operationCount;
    if (Number.isFinite(message.historyRevision)) {
      state.historyRevision = Math.max(state.historyRevision, message.historyRevision);
    }
    notifyNativeState();
  }
}

function restoreHistory(messages, cursor, revision) {
  state.log = Array.isArray(messages)
    ? messages.filter((message) => message?.type === "clear" || message?.type?.startsWith("stroke:"))
    : [];
  const operationCount = historyOperations().length;
  state.historyCursor = Number.isInteger(cursor)
    ? Math.max(0, Math.min(operationCount, cursor))
    : operationCount;
  state.historyRevision = Math.max(0, Number(revision || 0));
  state.active.clear();
  state.liveHighlighters.clear();
  state.renderedStrokeSequences.clear();
  clearLiveHighlighterPixels();
  redraw();
  notifyNativeState();
}

function applyHistoryState(message) {
  const operationCount = historyOperations().length;
  if (Number.isInteger(message.historyCursor)) {
    state.historyCursor = Math.max(0, Math.min(operationCount, message.historyCursor));
  } else if (message.type === "history:undo") {
    state.historyCursor = Math.max(0, state.historyCursor - 1);
  } else if (message.type === "history:redo") {
    state.historyCursor = Math.min(operationCount, state.historyCursor + 1);
  }
  if (Number.isFinite(message.historyRevision)) {
    state.historyRevision = Math.max(state.historyRevision, message.historyRevision);
  }
  state.liveHighlighters.clear();
  clearLiveHighlighterPixels();
  redraw();
  notifyNativeState();
}

function normalized(event) {
  const rect = canvas.getBoundingClientRect();
  const world = screenToWorld(event.clientX - rect.left, event.clientY - rect.top);
  return {
    x: world.x,
    y: world.y,
    p: event.pointerType === "pen" ? Math.max(0.08, event.pressure || 0.52) : 0.52,
  };
}

function viewportPayload(interactionPhase) {
  const size = localViewportSize();
  return {
    type: "whiteboard:viewport",
    centerX: state.whiteboardViewport.centerX,
    centerY: state.whiteboardViewport.centerY,
    zoom: state.whiteboardViewport.zoom,
    viewportWidth: size.width,
    viewportHeight: size.height,
    interactionId: state.viewportGesture?.interactionId,
    interactionPhase,
  };
}

function applyWhiteboardViewport(message) {
  const viewport = normalizeWhiteboardViewport(message);
  if (!viewport) return;
  state.whiteboardViewport = {
    centerX: viewport.centerX,
    centerY: viewport.centerY,
    zoom: viewport.zoom,
  };
  redraw();
  redrawLiveHighlighters();
  notifyNativeState();
}

function sendWhiteboardViewport(phase = "update", immediate = false) {
  if (!state.viewportGesture?.interactionId) return;
  if (immediate) {
    if (state.viewportSendFrame) cancelAnimationFrame(state.viewportSendFrame);
    state.viewportSendFrame = null;
    transmit(viewportPayload(phase));
    return;
  }
  if (state.viewportSendFrame) return;
  state.viewportSendFrame = requestAnimationFrame(() => {
    state.viewportSendFrame = null;
    transmit(viewportPayload(phase));
  });
}

function beginViewportGesture() {
  if (state.viewportGesture) return;
  const first = state.viewportPointers.values().next().value;
  if (!first) return;
  state.viewportGesture = {
    interactionId: `whiteboard-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
    mode: "pan",
    last: first,
  };
  sendWhiteboardViewport("begin", true);
}

function rebasePinchGesture() {
  const points = [...state.viewportPointers.values()];
  if (points.length < 2 || !state.viewportGesture) return;
  const centroid = { x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2 };
  state.viewportGesture.mode = "pinch";
  state.viewportGesture.initialDistance = Math.max(1, Math.hypot(points[1].x - points[0].x, points[1].y - points[0].y));
  state.viewportGesture.initialZoom = state.whiteboardViewport.zoom;
  state.viewportGesture.worldFocus = screenToWorld(centroid.x, centroid.y);
}

function updateViewportGesture() {
  const gesture = state.viewportGesture;
  const points = [...state.viewportPointers.values()];
  if (!gesture || !points.length) return;
  if (points.length >= 2) {
    if (gesture.mode !== "pinch") rebasePinchGesture();
    const centroid = { x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2 };
    const distance = Math.max(1, Math.hypot(points[1].x - points[0].x, points[1].y - points[0].y));
    const zoom = Math.max(WHITEBOARD_MIN_ZOOM, Math.min(
      WHITEBOARD_MAX_ZOOM,
      gesture.initialZoom * distance / gesture.initialDistance,
    ));
    const size = localViewportSize();
    const scale = size.height / whiteboardWorldHeight * zoom;
    state.whiteboardViewport = {
      centerX: gesture.worldFocus.x - (centroid.x - size.width / 2) / scale,
      centerY: gesture.worldFocus.y - (centroid.y - size.height / 2) / scale,
      zoom,
    };
  } else {
    const point = points[0];
    if (gesture.mode !== "pan") {
      gesture.mode = "pan";
      gesture.last = point;
      return;
    }
    const scale = worldScale();
    state.whiteboardViewport.centerX -= (point.x - gesture.last.x) / scale;
    state.whiteboardViewport.centerY -= (point.y - gesture.last.y) / scale;
    gesture.last = point;
  }
  redraw();
  redrawLiveHighlighters();
  notifyNativeState();
  sendWhiteboardViewport("update");
}

function endViewportPointer(pointerId) {
  state.viewportPointers.delete(pointerId);
  const gesture = state.viewportGesture;
  if (!gesture) return;
  if (!state.viewportPointers.size) {
    sendWhiteboardViewport("end", true);
    state.viewportGesture = null;
    return;
  }
  if (state.viewportPointers.size === 1) {
    gesture.mode = "pan";
    gesture.last = state.viewportPointers.values().next().value;
  } else {
    rebasePinchGesture();
  }
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
  for (const events of state.strokeOutbox.values()) {
    for (const event of events) {
      render(event);
      transmit(event);
    }
  }
}

function send(message) {
  if (message.type === "clear") {
    state.strokeOutbox.clear();
    state.strokeAckByMessageId.clear();
  }
  if (message.type?.startsWith("stroke:")) rememberStroke(message);
  transmit(message);
}

function nativeState() {
  const tool = state.manualEraser ? "eraser" : state.tool;
  const operationCount = historyOperations().length;
  return {
    connected: state.connected,
    documentName: "实时白板",
    zoom: state.whiteboardViewport.zoom,
    color: state.color,
    width: state.width,
    tool,
    highlighterWidth: state.highlighterWidth,
    highlighterOpacity: state.highlighterOpacity,
    eraser: state.manualEraser,
    eraserSize: state.eraserSize,
    mode: state.appMode,
    canUndo: state.historyCursor > 0,
    canRedo: state.historyCursor < operationCount,
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

function showHoverCursor(point, canvasAspect, coordinateSpace) {
  if (!hoverCursor || !point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return;
  const location = pointToScreen(point, { canvasAspect, coordinateSpace });
  hoverCursor.hidden = false;
  hoverCursor.style.left = `${location.x}px`;
  hoverCursor.style.top = `${location.y}px`;
}

function showEraserCursorAt(point, canvasAspect, coordinateSpace) {
  if (!eraserCursor || !point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return;
  const location = pointToScreen(point, { canvasAspect, coordinateSpace });
  eraserCursor.hidden = false;
  eraserCursor.style.setProperty("--cursor-size", `${state.eraserSize * state.whiteboardViewport.zoom}px`);
  eraserCursor.style.left = `${location.x}px`;
  eraserCursor.style.top = `${location.y}px`;
}

function hideHoverCursor() {
  if (hoverCursor) hoverCursor.hidden = true;
}

function queueHover(event) {
  if (!isPad || drawing || state.inputMode !== "pen" || event.pointerType !== "pen" || !isInsideInputViewport(event)) return;
  const point = normalized(event);
  const viewport = localViewportSize();
  const canvasAspect = viewport.width / viewport.height;
  showHoverCursor(point, canvasAspect, WHITEBOARD_COORDINATE_SPACE);
  state.pendingHover = { point, canvasAspect, coordinateSpace: WHITEBOARD_COORDINATE_SPACE };
  if (state.hoverFrame) return;
  state.hoverFrame = requestAnimationFrame(() => {
    state.hoverFrame = null;
    const hover = state.pendingHover;
    state.pendingHover = null;
    if (hover) send({ type: "cursor:move", ...hover });
  });
}

function sendHoverHidden() {
  if (!isPad) return;
  state.pendingHover = null;
  hideHoverCursor();
  hideEraserCursor();
  send({ type: "cursor:hide" });
}

function beginStroke(point, tool) {
  const strokeId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  state.pendingStroke = strokeId;
  state.pendingStrokeSequence = 0;
  state.activeTool = tool;
  const viewport = localViewportSize();
  const eraserRatio = state.eraserSize / Math.min(viewport.width, viewport.height);
  const canvasAspect = viewport.width / viewport.height;
  const message = {
    type: "stroke:start",
    strokeId,
    strokeSequence: 0,
    color: tool === "highlighter" ? state.highlighterColor : state.color,
    width: tool === "highlighter" ? state.highlighterWidth : state.width,
    opacity: tool === "highlighter" ? state.highlighterOpacity : 1,
    tool,
    eraserSize: state.eraserSize,
    eraserRatio,
    canvasAspect,
    coordinateSpace: WHITEBOARD_COORDINATE_SPACE,
    point,
  };
  render(message);
  send(message);
}

function flush() {
  state.flushFrame = null;
  if (!state.pending.length || !state.pendingStroke) return;
  while (state.pending.length) {
    const message = {
      type: "stroke:move",
      strokeId: state.pendingStroke,
      strokeSequence: ++state.pendingStrokeSequence,
      tool: state.activeTool,
      coordinateSpace: WHITEBOARD_COORDINATE_SPACE,
      eraserSize: state.eraserSize,
      eraserRatio: state.eraserSize / Math.min(localViewportSize().width, localViewportSize().height),
      points: state.pending.splice(0, 40),
    };
    render(message);
    send(message);
  }
}

function scheduleFlush() {
  if (!state.flushFrame) state.flushFrame = requestAnimationFrame(flush);
}

function endActiveStroke() {
  if (state.flushFrame) cancelAnimationFrame(state.flushFrame);
  flush();
  if (!state.pendingStroke) return;
  const message = {
    type: "stroke:end",
    strokeId: state.pendingStroke,
    strokeSequence: ++state.pendingStrokeSequence,
    tool: state.activeTool,
    coordinateSpace: WHITEBOARD_COORDINATE_SPACE,
  };
  render(message);
  send(message);
  state.pendingStroke = null;
  state.pendingStrokeSequence = 0;
  state.activeTool = "ink";
}

function shouldUsePressureEraser(event) {
  return isPad
    && state.inputMode === "pen"
    && state.pressureEraser
    && !state.manualEraser
    && event.pointerType === "pen"
    && event.pressure >= pressureThreshold;
}

function eraserPreviewActive(event) {
  if (!isPad) return false;
  if (state.pendingStroke) return state.activeTool === "eraser";
  return state.manualEraser || shouldUsePressureEraser(event);
}

function updateEraserCursor(event) {
  if (!eraserCursor || !eraserPreviewActive(event)) return hideEraserCursor();
  const rect = canvas.parentElement.getBoundingClientRect();
  eraserCursor.hidden = false;
  eraserCursor.style.setProperty("--cursor-size", `${state.eraserSize}px`);
  eraserCursor.style.left = `${event.clientX - rect.left}px`;
  eraserCursor.style.top = `${event.clientY - rect.top}px`;
}

function hideEraserCursor() {
  if (eraserCursor) eraserCursor.hidden = true;
}

function collect(event) {
  const events = event.getCoalescedEvents ? event.getCoalescedEvents() : [event];
  for (const item of events) {
    // The tool is selected only on pointerdown and remains locked for this stroke.
    state.pending.push(normalized(item));
  }
  scheduleFlush();
}

function acceptsPointer(event) {
  if (!isPad) return !(event.pointerType === "mouse" && event.button !== 0);
  return state.inputMode === "pen" ? event.pointerType === "pen" : event.pointerType === "touch";
}

let drawing = false;
canvas.addEventListener("pointerdown", (event) => {
  if (isPad && event.pointerType === "touch") {
    if (drawing) return;
    event.preventDefault();
    const rect = canvas.getBoundingClientRect();
    state.viewportPointers.set(event.pointerId, { x: event.clientX - rect.left, y: event.clientY - rect.top });
    canvas.setPointerCapture(event.pointerId);
    beginViewportGesture();
    if (state.viewportPointers.size === 2) rebasePinchGesture();
    return;
  }
  if (drawing || !acceptsPointer(event) || !isInsideInputViewport(event)) return;
  event.preventDefault();
  sendHoverHidden();
  canvas.setPointerCapture(event.pointerId);
  drawing = true;
  const tool = shouldUsePressureEraser(event) ? "eraser" : (state.manualEraser ? "eraser" : "ink");
  beginStroke(normalized(event), tool);
  if (tool === "eraser") updateEraserCursor(event);
  if (tool === "eraser" && shouldUsePressureEraser(event)) showToolToast("已切换为橡皮擦 · 抬笔后恢复书写");
});
canvas.addEventListener("pointermove", (event) => {
  if (state.viewportPointers.has(event.pointerId)) {
    event.preventDefault();
    const rect = canvas.getBoundingClientRect();
    state.viewportPointers.set(event.pointerId, { x: event.clientX - rect.left, y: event.clientY - rect.top });
    updateViewportGesture();
    return;
  }
  updateEraserCursor(event);
  if (!drawing) {
    queueHover(event);
    return;
  }
  event.preventDefault();
  collect(event);
});
function finish(event) {
  if (state.viewportPointers.has(event.pointerId)) {
    event.preventDefault();
    endViewportPointer(event.pointerId);
    return;
  }
  if (!drawing) return;
  event.preventDefault();
  endActiveStroke();
  drawing = false;
  if (!state.manualEraser) hideEraserCursor();
}
canvas.addEventListener("pointerup", finish);
canvas.addEventListener("pointercancel", finish);
canvas.addEventListener("pointerleave", () => {
  if (!drawing) {
    hideEraserCursor();
    sendHoverHidden();
  }
});

function showToolToast(text) {
  if (!isPad) return;
  const toast = document.querySelector("#toolToast");
  toast.textContent = text;
  toast.classList.add("visible");
  clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => toast.classList.remove("visible"), 1800);
}

function updatePadControls() {
  if (!isPad) return;
  document.querySelectorAll("[data-input-mode]").forEach((button) => {
    button.classList.toggle("selected", button.dataset.inputMode === state.inputMode);
  });
  const manual = document.querySelector("#manualEraser");
  const pressure = document.querySelector("#pressureEraser");
  const size = document.querySelector("#eraserSize");
  const sizeValue = document.querySelector("#eraserSizeValue");
  manual.setAttribute("aria-pressed", String(state.manualEraser));
  pressure.setAttribute("aria-pressed", String(state.pressureEraser));
  pressure.disabled = state.inputMode !== "pen";
  size.value = String(state.eraserSize);
  sizeValue.value = String(state.eraserSize);
  sizeValue.textContent = String(state.eraserSize);
  if (state.inputMode === "finger" || !state.manualEraser) hideEraserCursor();
  document.querySelector("#inputHint").textContent = state.inputMode === "pen"
    ? "手写笔模式 · 手指与手掌不会落笔"
    : "手指模式 · 仅手指会落笔";
}

function connect() {
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
      "revision",
      nativeInput ? "native-input" : "pointer-input",
      "native-pen-v2",
      "highlighter-v1",
      "stroke-replace-v1",
      "stroke-batch-v2",
      "stroke-idempotency",
      "transport-control-v1",
      "whiteboard-viewport-v1",
      "whiteboard-world-v1",
    ])));
    reportNativeTransportStatus();
    notifyNativeState();
  });
  state.socket.addEventListener("message", (event) => {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message.type === "session:snapshot") {
      if (!protocol.acceptSnapshot(message)) return;
      if (message.whiteboardViewport) applyWhiteboardViewport(message.whiteboardViewport);
      restoreHistory(
        message.history,
        message.whiteboardHistoryCursor ?? message.historyCursor,
        message.whiteboardHistoryRevision ?? message.historyRevision,
      );
      if (message.mode === "pdf" || message.mode === "whiteboard") {
        state.appMode = message.mode;
        notifyNativeMode(message.mode);
      }
      if (message.preview?.preview) showPDFPreview(message.preview.preview);
      state.awaitingSnapshot = false;
      replayStrokeOutbox();
      notifyNativeState();
      return;
    }
    if (!protocol.accept(message)) return;
    if (message.type === "ack") {
      acknowledgeStroke(message);
      return;
    }
    if (message.type === "session:welcome") return;
    if (message.type === "sync") {
      restoreHistory(message.history, message.historyCursor, message.historyRevision);
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
    if (message.type === "whiteboard:viewport") {
      applyWhiteboardViewport(message);
      return;
    }
    if ((message.type === "history:undo" || message.type === "history:redo")
      && message.mode === "whiteboard") {
      applyHistoryState(message);
      return;
    }
    if (message.type === "presence") {
      if (!isPad) document.querySelector("#peopleText").textContent = message.count > 1 ? `已有 ${message.count - 1} 台平板连接` : "等待平板加入";
      return;
    }
    if (message.type === "pdf:preview") {
      showPDFPreview(message.preview);
      return;
    }
    if (message.type === "cursor:move") {
      showHoverCursor(message.point, message.canvasAspect, message.coordinateSpace);
      return;
    }
    if (message.type === "cursor:hide") {
      hideHoverCursor();
      return;
    }
    render(message);
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

function select(selector, event) {
  document.querySelectorAll(selector).forEach((node) => node.classList.remove("selected"));
  event.currentTarget.classList.add("selected");
}

document.querySelectorAll("[data-color]").forEach((button) => button.addEventListener("click", (event) => {
  state.color = button.dataset.color;
  if (isPad) state.manualEraser = false;
  select(isPad ? ".pad-color" : ".color", event);
  updatePadControls();
}));
document.querySelectorAll("[data-width]").forEach((button) => button.addEventListener("click", (event) => {
  state.width = Number(button.dataset.width);
  select(isPad ? ".pad-width" : ".width", event);
}));
document.querySelectorAll("[data-input-mode]").forEach((button) => button.addEventListener("click", () => {
  state.inputMode = button.dataset.inputMode;
  state.manualEraser = false;
  updatePadControls();
  showToolToast(state.inputMode === "pen" ? "手写笔模式 · 已开启防误触" : "手指模式 · 可用手指书写");
}));
document.querySelector("#manualEraser")?.addEventListener("click", () => {
  state.manualEraser = !state.manualEraser;
  updatePadControls();
  showToolToast(state.manualEraser ? "橡皮擦已开启" : "已恢复书写");
});
document.querySelector("#pressureEraser")?.addEventListener("click", () => {
  state.pressureEraser = !state.pressureEraser;
  updatePadControls();
  showToolToast(state.pressureEraser ? "重按橡皮擦已开启" : "重按橡皮擦已关闭");
});
document.querySelector("#eraserSize")?.addEventListener("input", (event) => {
  state.eraserSize = Number(event.currentTarget.value);
  updatePadControls();
  showToolToast(`橡皮擦大小：${state.eraserSize}`);
});

function clearBoard() {
  if (state.hasInk && !confirm("确定要清空这块白板吗？")) return;
  const message = { type: "clear", mode: "whiteboard" };
  send(message);
}
document.querySelector("#clearBoard")?.addEventListener("click", clearBoard);
document.querySelector("#padClear")?.addEventListener("click", clearBoard);

async function copy(text, button) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const area = document.createElement("textarea");
    area.value = text;
    document.body.append(area);
    area.select();
    document.execCommand("copy");
    area.remove();
  }
  const old = button.textContent;
  button.textContent = "已复制";
  setTimeout(() => { button.textContent = old; }, 1100);
}

async function pair() {
  const dialog = document.querySelector("#pairDialog");
  let base = location.origin;
  try {
    const config = await fetch("/config", { cache: "no-store" }).then((response) => response.json());
    base = config.urls?.[0] || base;
  } catch { /* The current local URL is a usable fallback. */ }
  const link = `${base}/?role=pad&room=${room}`;
  document.querySelector("#padLink").textContent = link;
  const qrCode = document.querySelector("#qrCode");
  const showLinkOnly = () => {
    qrCode.hidden = true;
    dialog.querySelector("small").textContent = "请复制上方链接，在平板浏览器打开。";
  };
  qrCode.hidden = false;
  if (window.QRCode?.toDataURL) {
    window.QRCode.toDataURL(link, { errorCorrectionLevel: "M", margin: 1, width: 360, color: { dark: "#152441", light: "#FFFFFFFF" } })
      .then((dataURL) => { qrCode.src = dataURL; })
      .catch(showLinkOnly);
  } else {
    showLinkOnly();
  }
  dialog.showModal();
  document.querySelector("#copyLink").onclick = () => copy(link, document.querySelector("#copyLink"));
}
document.querySelector("#connectPad")?.addEventListener("click", pair);
document.querySelector("#closePair")?.addEventListener("click", () => document.querySelector("#pairDialog").close());
document.querySelector("#copyRoom")?.addEventListener("click", (event) => copy(room, event.currentTarget));

new ResizeObserver(fitCanvas).observe(canvas.parentElement);
fitCanvas();
updatePadControls();
connect();

function nativePoint(x, y, pressure, metadata = null) {
  const world = screenToWorld(Number(x), Number(y));
  const point = {
    x: world.x,
    y: world.y,
    p: Math.max(0.08, Math.min(1, Number(pressure) || 0.52)),
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

function startNativeStroke(sampleOrX, yOrEraser, legacyPressure, legacyPressureEraser = false) {
  if (!isPad || drawing) return;
  const sample = sampleOrX && typeof sampleOrX === "object"
    ? sampleOrX
    : { x: sampleOrX, y: yOrEraser, p: legacyPressure };
  const pressureEraser = sampleOrX && typeof sampleOrX === "object"
    ? Boolean(yOrEraser)
    : Boolean(legacyPressureEraser);
  if (!Number.isFinite(Number(sample.x)) || !Number.isFinite(Number(sample.y))) return;
  if (state.viewportGesture) sendWhiteboardViewport("end", true);
  state.viewportGesture = null;
  state.viewportPointers.clear();
  sendHoverHidden();
  drawing = true;
  state.lastNativeSampleIndex = Number.isInteger(sample.sampleIndex) ? sample.sampleIndex : -1;
  state.lastNativePoint = nativePoint(sample.x, sample.y, sample.p, sample);
  state.nativeStartPoint = state.lastNativePoint;
  state.nativeHighlighterPausePoint = state.lastNativePoint;
  state.nativeHighlighterStraightLocked = false;
  const tool = Boolean(pressureEraser) || state.manualEraser ? "eraser" : state.tool;
  beginStroke(state.lastNativePoint, tool);
  if (tool === "highlighter") scheduleNativeHighlighterHold();
  if (tool === "eraser") {
    const viewport = localViewportSize();
    showEraserCursorAt(state.lastNativePoint, viewport.width / viewport.height, WHITEBOARD_COORDINATE_SPACE);
  }
}

function clearNativeHighlighterHold() {
  clearTimeout(state.nativeHighlighterHoldTimer);
  state.nativeHighlighterHoldTimer = null;
}

function scheduleNativeHighlighterHold() {
  if (!drawing || state.activeTool !== "highlighter" || state.nativeHighlighterStraightLocked) return;
  clearNativeHighlighterHold();
  const strokeId = state.pendingStroke;
  state.nativeHighlighterHoldTimer = setTimeout(() => {
    if (!drawing || state.pendingStroke !== strokeId
      || state.activeTool !== "highlighter" || state.nativeHighlighterStraightLocked) return;
    const start = state.nativeStartPoint;
    const end = state.lastNativePoint;
    if (!start || !end) return;
    const startScreen = worldToScreen(start);
    const endScreen = worldToScreen(end);
    if (Math.hypot(endScreen.x - startScreen.x, endScreen.y - startScreen.y) < 10) return;
    state.nativeHighlighterStraightLocked = true;
    replaceNativeStrokeWithStraight();
  }, HIGHLIGHTER_HOLD_DELAY_MS);
}

function updateNativeHighlighterHold(point) {
  if (!drawing || state.activeTool !== "highlighter"
    || state.nativeHighlighterStraightLocked || !point) return;
  const pause = state.nativeHighlighterPausePoint;
  if (!pause) {
    state.nativeHighlighterPausePoint = point;
    scheduleNativeHighlighterHold();
    return;
  }
  const pauseScreen = worldToScreen(pause);
  const pointScreen = worldToScreen(point);
  if (Math.hypot(pointScreen.x - pauseScreen.x, pointScreen.y - pauseScreen.y)
    >= HIGHLIGHTER_HOLD_SLOP_PX) {
    state.nativeHighlighterPausePoint = point;
    scheduleNativeHighlighterHold();
  }
}

function moveNativeStroke(samples) {
  if (!drawing || !Array.isArray(samples)) return;
  if (state.activeTool === "highlighter" && state.nativeHighlighterStraightLocked) {
    const latest = samples[samples.length - 1];
    if (latest) replaceNativeStrokeWithStraight(latest);
    return;
  }
  for (const sample of samples) {
    if (!Number.isFinite(sample?.x) || !Number.isFinite(sample?.y)) continue;
    if (Number.isInteger(sample.sampleIndex) && sample.sampleIndex <= state.lastNativeSampleIndex) continue;
    const point = nativePoint(sample.x, sample.y, sample.p, sample);
    if (state.lastNativePoint
      && Math.hypot(point.x - state.lastNativePoint.x, point.y - state.lastNativePoint.y) < 0.000_025
      && Math.abs(point.p - state.lastNativePoint.p) < 0.01) continue;
    if (Number.isInteger(sample.sampleIndex)) state.lastNativeSampleIndex = sample.sampleIndex;
    state.lastNativePoint = point;
    state.pending.push(point);
  }
  updateNativeHighlighterHold(state.lastNativePoint);
  if (state.activeTool === "eraser" && state.lastNativePoint) {
    const viewport = localViewportSize();
    showEraserCursorAt(state.lastNativePoint, viewport.width / viewport.height, WHITEBOARD_COORDINATE_SPACE);
  }
  // ArkTS already coalesces the current touch frame and its historical pen
  // samples. Forward that batch immediately instead of waiting for a second
  // animation frame in ArkWeb. Pointer Events still use frame coalescing.
  if (state.pending.length) {
    if (state.flushFrame) cancelAnimationFrame(state.flushFrame);
    flush();
  }
}

function replaceNativeStrokeWithStraight(finalSample = null) {
  if (!isPad || !drawing || state.activeTool !== "highlighter" || !state.pendingStroke) return;
  clearNativeHighlighterHold();
  state.nativeHighlighterStraightLocked = true;
  if (finalSample && Number.isFinite(finalSample.x) && Number.isFinite(finalSample.y)) {
    state.lastNativePoint = nativePoint(finalSample.x, finalSample.y, finalSample.p, finalSample);
  }
  if (state.flushFrame) cancelAnimationFrame(state.flushFrame);
  state.flushFrame = null;
  state.pending = [];
  const start = state.nativeStartPoint;
  const end = state.lastNativePoint;
  if (!start || !end) return;
  const viewport = localViewportSize();
  const message = {
    type: "stroke:replace",
    strokeId: state.pendingStroke,
    strokeSequence: ++state.pendingStrokeSequence,
    color: state.highlighterColor,
    width: state.highlighterWidth,
    opacity: state.highlighterOpacity,
    tool: "highlighter",
    canvasAspect: viewport.width / viewport.height,
    coordinateSpace: WHITEBOARD_COORDINATE_SPACE,
    points: [start, end],
  };
  render(message);
  send(message);
}

function endNativeStroke(finalSample = null) {
  if (!drawing) return;
  if (state.activeTool === "highlighter" && state.nativeHighlighterStraightLocked) {
    if (finalSample) replaceNativeStrokeWithStraight(finalSample);
  } else if (finalSample) {
    moveNativeStroke([finalSample]);
  }
  clearNativeHighlighterHold();
  endActiveStroke();
  drawing = false;
  state.lastNativePoint = null;
  state.nativeStartPoint = null;
  state.nativeHighlighterPausePoint = null;
  state.nativeHighlighterStraightLocked = false;
  state.lastNativeSampleIndex = -1;
  hideEraserCursor();
}

function cancelNativeStroke() {
  endNativeStroke();
}

function switchNativeStrokeToEraser() {
  // Kept for older native clients. Mid-stroke switching is intentionally disabled.
}

function reportNativeHover(x, y) {
  if (!isPad || drawing) return;
  const point = nativePoint(x, y, 0.52);
  const viewport = localViewportSize();
  const canvasAspect = viewport.width / viewport.height;
  const tool = state.manualEraser ? "eraser" : state.tool;
  if (tool === "eraser") {
    hideHoverCursor();
    showEraserCursorAt(point, canvasAspect, WHITEBOARD_COORDINATE_SPACE);
  } else {
    hideEraserCursor();
    showHoverCursor(point, canvasAspect, WHITEBOARD_COORDINATE_SPACE);
  }
  send({
    type: "cursor:move",
    point,
    canvasAspect,
    coordinateSpace: WHITEBOARD_COORDINATE_SPACE,
    tool,
    eraserSize: tool === "eraser" ? state.eraserSize : undefined,
    eraserRatio: tool === "eraser" ? state.eraserSize / Math.min(viewport.width, viewport.height) : undefined,
  });
}

window.nativeGetState = () => {
  notifyNativeState();
  return JSON.stringify(nativeState());
};
window.nativeSetColor = (color) => {
  if (typeof color === "string" && /^#[0-9a-f]{6}$/i.test(color)) state.color = color;
  state.manualEraser = false;
  updatePadControls();
  notifyNativeState();
};
window.nativeSetWidth = (width) => {
  const value = Number(width);
  if (Number.isFinite(value)) state.width = Math.max(0.8, Math.min(20, value));
  notifyNativeState();
};
window.nativeSetEraser = (enabled) => {
  state.manualEraser = Boolean(enabled);
  updatePadControls();
  notifyNativeState();
};
window.nativeSetTool = (tool) => {
  if (!["ink", "highlighter", "eraser"].includes(tool)) return;
  state.manualEraser = tool === "eraser";
  if (tool !== "eraser") state.tool = tool;
  updatePadControls();
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
  updatePadControls();
  notifyNativeState();
};
function changeWhiteboardZoom(multiplier) {
  const center = screenToWorld(localViewportSize().width / 2, localViewportSize().height / 2);
  state.whiteboardViewport.zoom = Math.max(
    WHITEBOARD_MIN_ZOOM,
    Math.min(WHITEBOARD_MAX_ZOOM, state.whiteboardViewport.zoom * multiplier),
  );
  state.whiteboardViewport.centerX = center.x;
  state.whiteboardViewport.centerY = center.y;
  const interactionId = `whiteboard-button-${Date.now().toString(36)}`;
  state.viewportGesture = { interactionId, mode: "button" };
  redraw();
  redrawLiveHighlighters();
  sendWhiteboardViewport("begin", true);
  sendWhiteboardViewport("end", true);
  state.viewportGesture = null;
  notifyNativeState();
}
window.nativeZoomOut = () => changeWhiteboardZoom(0.8);
window.nativeZoomIn = () => changeWhiteboardZoom(1.25);
window.nativeUndo = () => send({ type: "history:undo", mode: "whiteboard" });
window.nativeRedo = () => send({ type: "history:redo", mode: "whiteboard" });
window.nativeClear = clearBoard;
window.nativeReportHover = reportNativeHover;
window.nativeReportHoverHidden = sendHoverHidden;
window.nativePenStart = startNativeStroke;
window.nativePenMove = moveNativeStroke;
window.nativePenEnd = endNativeStroke;
window.nativePenCancel = cancelNativeStroke;
window.nativePenStraighten = () => replaceNativeStrokeWithStraight();
window.nativePenUpdateStraight = (sample) => replaceNativeStrokeWithStraight(sample);
window.nativePenSwitchToEraser = switchNativeStrokeToEraser;
window.nativeSwitchMode = (mode) => {
  if (mode !== "pdf" && mode !== "whiteboard") return;
  state.appMode = mode;
  send({ type: "app:mode", mode });
  notifyNativeState();
};
window.nativeReportTransportStatus = reportNativeTransportStatus;
window.nativeReportScreenMirrorStatus = reportNativeScreenMirrorStatus;
window.nativeRequestScreenMirror = requestNativeScreenMirror;
