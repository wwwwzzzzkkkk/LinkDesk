import {
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { homedir, networkInterfaces } from "node:os";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import {
  INKBRIDGE_APP_VERSION,
  INKBRIDGE_PROTOCOL_VERSION,
  VIEWPORT_INTERACTION_PHASES,
  normalizePDFViewport,
  normalizeWhiteboardViewport,
} from "./public/inkbridge-protocol.js";

const directory = dirname(fileURLToPath(import.meta.url));
const publicDirectory = join(directory, "public");
const port = Number.parseInt(process.env.PORT ?? "3210", 10);
const relayVersion = 13;
const serverSourceId = "inkbridge-relay";
const rooms = new Map();
const persistenceDirectory = process.env.INKBRIDGE_DATA_DIR
  || join(homedir(), "Library", "Application Support", "InkBridge");
const projectDirectory = join(persistenceDirectory, "projects");
const roomDirectory = join(persistenceDirectory, "rooms");
const roundTripDirectory = join(persistenceDirectory, "roundtrip");
const types = { ".css": "text/css; charset=utf-8", ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".png": "image/png", ".svg": "image/svg+xml", ".wasm": "application/wasm" };
// The tablet needs the original file to make page-relative ink reliable.
// Keep a practical cap so a malformed request cannot exhaust the Mac.
const maxDocumentBytes = 250 * 1024 * 1024;
const roomRetentionMs = 15 * 60 * 1000;
const documentTransferTimeoutMs = 120 * 1000;
const viewportControlLeaseMs = 550;
const maxHistoryOperations = 20_000;
const maxEventsPerStroke = 2_500;
const roundTripReturns = new Map();

let nextUploadSequence = 0;
let nextServerSequence = 0;
mkdirSync(projectDirectory, { recursive: true });
mkdirSync(roomDirectory, { recursive: true });
mkdirSync(roundTripDirectory, { recursive: true });

const appearancePath = join(persistenceDirectory, "appearance.json");
const storedAppearance = readJSON(appearancePath);
let sharedAppearance = storedAppearance
  && ["automatic", "light", "dark"].includes(storedAppearance.preference)
  && ["light", "dark"].includes(storedAppearance.appearance)
  && Number.isSafeInteger(storedAppearance.revision) && storedAppearance.revision >= 0
  ? storedAppearance : { preference: "automatic", appearance: "light", revision: 0 };

function createRoom() {
  return {
    clients: new Set(),
    histories: { pdf: [], whiteboard: [] },
    operations: { pdf: [], whiteboard: [] },
    historyCursor: { pdf: 0, whiteboard: 0 },
    historyRevision: 0,
    nextHistorySequence: 0,
    pendingStrokes: new Map(),
    mode: "pdf",
    preview: null,
    viewport: null,
    viewportControl: null,
    whiteboardViewport: null,
    whiteboardViewportControl: null,
    strokeProgress: new Map(),
    document: null,
    viewportsByDocumentHash: new Map(),
    revision: 0,
    readyClients: new Map(),
    pendingUploadSequence: 0,
    cleanupTimer: null,
    persistenceTimer: null,
  };
}

function atomicWrite(path, data) {
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporary, data);
  renameSync(temporary, path);
}

function projectPaths(hash) {
  return {
    pdf: join(projectDirectory, `${hash}.pdf`),
    state: join(projectDirectory, `${hash}.json`),
  };
}

function roomStatePath(roomCode) {
  return join(roomDirectory, `${roomCode}.json`);
}

function flattenedOperations(room, mode) {
  return room.operations[mode].flatMap((operation) => operation.events);
}

function rebuildHistory(room, mode) {
  room.histories[mode] = flattenedOperations(room, mode);
}

function trimOperationHistory(room, mode) {
  const operations = room.operations[mode];
  if (operations.length <= maxHistoryOperations) return;
  const removed = operations.length - maxHistoryOperations;
  operations.splice(0, removed);
  room.historyCursor[mode] = Math.max(0, room.historyCursor[mode] - removed);
}

function rebuildStrokeProgress(room) {
  room.strokeProgress.clear();
  for (const mode of ["pdf", "whiteboard"]) {
    for (const event of room.histories[mode]) {
      if (event.type === "stroke:end" && event.sourceId && event.strokeId) {
        room.strokeProgress.set(`${event.sourceId}:${event.strokeId}`, {
          sequence: Number(event.strokeSequence || 0),
          ended: true,
        });
      }
    }
  }
}

function rebindDocumentEvents(events, document) {
  return events.map((event) => ({
    ...event,
    documentId: document.id,
    documentVersion: document.version,
    documentHash: document.hash,
  }));
}

function serializedProject(room) {
  if (!room.document) return null;
  const viewport = room.viewport ? storedViewport(room.viewport) : null;
  return {
    schemaVersion: 1,
    savedAt: Date.now(),
    name: room.document.name,
    documentHash: room.document.hash,
    historyRevision: room.historyRevision,
    nextHistorySequence: room.nextHistorySequence,
    operations: room.operations.pdf,
    historyCursor: room.historyCursor.pdf,
    viewport,
  };
}

function serializedWhiteboard(room) {
  return {
    operations: room.operations.whiteboard,
    historyCursor: room.historyCursor.whiteboard,
    viewport: room.whiteboardViewport ? storedWhiteboardViewport(room.whiteboardViewport) : null,
  };
}

function persistRoomNow(roomCode, room) {
  if (room.document) {
    const project = serializedProject(room);
    const paths = projectPaths(room.document.hash);
    if (!existsSync(paths.pdf)) atomicWrite(paths.pdf, room.document.data);
    atomicWrite(paths.state, JSON.stringify(project));
  }
  const state = {
    schemaVersion: 2,
    savedAt: Date.now(),
    mode: room.mode,
    historyRevision: room.historyRevision,
    nextHistorySequence: room.nextHistorySequence,
    whiteboard: serializedWhiteboard(room),
    document: room.document ? {
      name: room.document.name,
      id: room.document.id,
      version: room.document.version,
      hash: room.document.hash,
      transactionId: room.document.transactionId,
    } : null,
  };
  atomicWrite(roomStatePath(roomCode), JSON.stringify(state));
}

function schedulePersistRoom(roomCode, room, immediate = false) {
  if (room.persistenceTimer) {
    clearTimeout(room.persistenceTimer);
    room.persistenceTimer = null;
  }
  if (immediate) {
    persistRoomNow(roomCode, room);
    return;
  }
  room.persistenceTimer = setTimeout(() => {
    room.persistenceTimer = null;
    persistRoomNow(roomCode, room);
  }, 180);
}

function readJSON(path) {
  try { return JSON.parse(readFileSync(path, "utf8")); }
  catch { return null; }
}

function loadProject(hash, document) {
  if (!/^[a-f0-9]{64}$/.test(hash)) return null;
  const state = readJSON(projectPaths(hash).state);
  if (!state || state.schemaVersion !== 1 || !Array.isArray(state.operations)) return null;
  const operations = state.operations
    .filter((operation) => operation && Array.isArray(operation.events))
    .map((operation) => ({
      operationId: String(operation.operationId || randomUUID()).slice(0, 120),
      historySequence: Math.max(1, Number(operation.historySequence || 1)),
      events: rebindDocumentEvents(operation.events, document),
    }));
  return {
    operations,
    cursor: Math.max(0, Math.min(operations.length, Number(state.historyCursor ?? operations.length))),
    historyRevision: Math.max(0, Number(state.historyRevision || 0)),
    nextHistorySequence: Math.max(
      Number(state.nextHistorySequence || 0),
      ...operations.map((operation) => operation.historySequence),
      0,
    ),
    viewport: state.viewport,
  };
}

function loadWhiteboard(state) {
  if (!state || !Array.isArray(state.operations)) return null;
  const sourceOperations = state.operations
    .filter((operation) => operation && Array.isArray(operation.events));
  const removed = Math.max(0, sourceOperations.length - maxHistoryOperations);
  const operations = sourceOperations.slice(-maxHistoryOperations).map((operation) => {
    const events = operation.events.slice(0, maxEventsPerStroke).flatMap((event) => {
      if (!event || (event.type !== "clear" && !String(event.type || "").startsWith("stroke:"))) return [];
      const normalized = { ...event, mode: "whiteboard" };
      delete normalized.documentId;
      delete normalized.documentVersion;
      delete normalized.documentHash;
      delete normalized.pageIndex;
      return validDrawing(normalized) ? [normalized] : [];
    });
    return {
      operationId: String(operation.operationId || randomUUID()).slice(0, 120),
      historySequence: Math.max(1, Number(operation.historySequence || 1)),
      events,
    };
  }).filter((operation) => operation.events.length > 0);
  const sourceCursor = Math.max(0, Number(state.historyCursor ?? sourceOperations.length) - removed);
  return {
    operations,
    cursor: Math.max(0, Math.min(operations.length, sourceCursor)),
    nextHistorySequence: Math.max(
      ...operations.map((operation) => operation.historySequence),
      0,
    ),
    viewport: storedWhiteboardViewport(state.viewport),
  };
}

function loadPersistedRoom(roomCode) {
  const saved = readJSON(roomStatePath(roomCode));
  if (!saved || (saved.schemaVersion !== 1 && saved.schemaVersion !== 2)) return null;
  const room = createRoom();
  room.mode = saved.mode === "whiteboard" ? "whiteboard" : "pdf";
  let restored = false;
  if (saved.document && /^[a-f0-9]{64}$/.test(saved.document.hash || "")) {
    const paths = projectPaths(saved.document.hash);
    let data = null;
    try { if (existsSync(paths.pdf)) data = readFileSync(paths.pdf); } catch {}
    if (data?.subarray(0, 5).toString() === "%PDF-") {
      room.document = {
        data,
        name: String(saved.document.name || "document.pdf").slice(0, 260),
        id: String(saved.document.id || `sha256-${saved.document.hash}`).slice(0, 72),
        version: Math.max(1, Number(saved.document.version || 1)),
        hash: saved.document.hash,
        transactionId: String(saved.document.transactionId || randomUUID()).slice(0, 72),
        restoreAvailable: true,
      };
      const project = loadProject(room.document.hash, room.document);
      if (project) {
        room.operations.pdf = project.operations;
        room.historyCursor.pdf = project.cursor;
        room.historyRevision = project.historyRevision;
        room.nextHistorySequence = project.nextHistorySequence;
        rebuildHistory(room, "pdf");
        if (project.viewport) {
          room.viewport = {
            type: "pdf:viewport",
            ...project.viewport,
            ...documentMetadata(room.document),
          };
        }
      }
      restored = true;
    }
  }
  const whiteboard = loadWhiteboard(saved.whiteboard);
  if (whiteboard) {
    room.operations.whiteboard = whiteboard.operations;
    room.historyCursor.whiteboard = whiteboard.cursor;
    room.historyRevision = Math.max(room.historyRevision, Number(saved.historyRevision || 0));
    room.nextHistorySequence = Math.max(
      room.nextHistorySequence,
      Number(saved.nextHistorySequence || 0),
      whiteboard.nextHistorySequence,
    );
    rebuildHistory(room, "whiteboard");
    if (whiteboard.viewport) {
      room.whiteboardViewport = {
        type: "whiteboard:viewport",
        ...whiteboard.viewport,
      };
    }
    restored = true;
  }
  rebuildStrokeProgress(room);
  return restored ? room : null;
}

function roomFor(roomCode) {
  const room = rooms.get(roomCode) ?? loadPersistedRoom(roomCode) ?? createRoom();
  rooms.set(roomCode, room);
  if (room.cleanupTimer) {
    clearTimeout(room.cleanupTimer);
    room.cleanupTimer = null;
  }
  return room;
}
function retainIdleRoom(roomCode, room) {
  if (room.clients.size || room.cleanupTimer) return;
  schedulePersistRoom(roomCode, room, true);
  room.cleanupTimer = setTimeout(() => {
    if (!room.clients.size && rooms.get(roomCode) === room) rooms.delete(roomCode);
  }, roomRetentionMs);
}

function addresses() {
  const result = [];
  for (const entries of Object.values(networkInterfaces())) for (const entry of entries ?? []) {
    if (entry.family === "IPv4" && !entry.internal) result.push(entry.address);
  }
  return [...new Set(result)];
}
function send(socket, data) { if (socket.readyState === 1) socket.send(JSON.stringify(data)); }
function broadcastRaw(room, data, except = null) {
  const payload = JSON.stringify(data);
  for (const client of room.clients) if (client !== except && client.readyState === 1) client.send(payload);
}
function serverEnvelope(room, data, advanceRevision = false) {
  if (advanceRevision) room.revision += 1;
  nextServerSequence += 1;
  return {
    ...data,
    protocolVersion: INKBRIDGE_PROTOCOL_VERSION,
    appVersion: INKBRIDGE_APP_VERSION,
    sourceId: serverSourceId,
    sequence: nextServerSequence,
    messageId: `${serverSourceId}:${nextServerSequence}`,
    revision: room.revision,
    sentAt: Date.now(),
  };
}
function sendServer(socket, room, data) {
  send(socket, serverEnvelope(room, data));
}
function broadcastServer(room, data, except = null, advanceRevision = false) {
  const message = serverEnvelope(room, data, advanceRevision);
  broadcastRaw(room, message, except);
  return message;
}
function validRoom(room) { return typeof room === "string" && /^[A-Z0-9]{6}$/.test(room); }
function validIdentifier(value, max = 120) {
  return typeof value === "string" && value.length > 0 && value.length <= max && /^[A-Za-z0-9:._-]+$/.test(value);
}
function documentMetadata(document) {
  if (!document) return null;
  return {
    name: document.name,
    documentId: document.id,
    documentVersion: document.version,
    documentHash: document.hash,
    documentSize: document.data.length,
    transactionId: document.transactionId,
    restoreAvailable: Boolean(document.restoreAvailable),
  };
}
function historyForRole(room, role) {
  if (role === "pdfpad") return room.histories.pdf;
  if (role === "pad" || role === "board") return room.histories.whiteboard;
  return [...room.histories.pdf, ...room.histories.whiteboard];
}
function historyModeForRole(room, role) {
  if (role === "pad" || role === "board") return "whiteboard";
  return "pdf";
}
function snapshotFor(room, role) {
  const historyMode = historyModeForRole(room, role);
  return {
    type: "session:snapshot",
    mode: room.mode,
    document: documentMetadata(room.document),
    viewport: room.viewport,
    whiteboardViewport: room.whiteboardViewport,
    history: historyForRole(room, role),
    historyCursor: room.historyCursor[historyMode],
    historyLength: room.operations[historyMode].length,
    historyRevision: room.historyRevision,
    whiteboardHistoryCursor: room.historyCursor.whiteboard,
    whiteboardHistoryLength: room.operations.whiteboard.length,
    whiteboardHistoryRevision: room.historyRevision,
    preview: room.preview,
  };
}
function sendAck(socket, room, message, status = "accepted") {
  if (!message.requiresAck || !message.messageId) return;
  sendServer(socket, room, {
    type: "ack",
    ackMessageId: message.messageId,
    status,
  });
}
function pdfNameFromHeader(value) {
  const raw = typeof value === "string" ? value : "";
  try { return (decodeURIComponent(raw) || "document.pdf").slice(0, 260); }
  catch { return (raw || "document.pdf").slice(0, 260); }
}
function validDrawing(data) {
  if (!data || typeof data !== "object") return false;
  if (data.type === "app:mode") return data.mode === "pdf" || data.mode === "whiteboard";
  if (data.type === "transport:request") {
    return (data.transport === "wifi" || data.transport === "usb")
      && (data.transportPreference === "automatic"
        || data.transportPreference === "wifi"
        || data.transportPreference === "usb")
      && validIdentifier(data.requestId, 72);
  }
  if (data.type === "transport:status") {
    return (data.transport === "wifi" || data.transport === "usb")
      && (data.requestId === undefined || validIdentifier(data.requestId, 72))
      && (data.deviceId === undefined || validIdentifier(data.deviceId, 72));
  }
  if (data.type === "screen-mirror:request") {
    return (data.action === "start" || data.action === "stop")
      && validIdentifier(data.requestId, 72);
  }
  if (data.type === "screen-mirror:status") {
    return (data.status === "started" || data.status === "stopped" || data.status === "failed")
      && (data.requestId === undefined || validIdentifier(data.requestId, 72))
      && (data.error === undefined || (typeof data.error === "string" && data.error.length <= 240));
  }
  if (data.type === "roundtrip:open") {
    return validIdentifier(data.roundTripId, 72)
      && validIdentifier(data.documentId, 72)
      && Number.isInteger(data.documentVersion) && data.documentVersion > 0
      && /^[a-f0-9]{64}$/.test(data.documentHash ?? "")
      && typeof data.name === "string" && data.name.length > 0 && data.name.length <= 260;
  }
  if (data.type === "pdf:ready" || data.type === "pdf:error") {
    return validIdentifier(data.documentId, 72) && Number.isInteger(data.documentVersion) && data.documentVersion > 0
      && (data.type !== "pdf:ready" || (Number.isInteger(data.pageCount) && data.pageCount > 0));
  }
  if (data.type === "pdf:progress") {
    return validIdentifier(data.documentId, 72)
      && Number.isInteger(data.documentVersion) && data.documentVersion > 0
      && Number.isFinite(data.loadedBytes) && data.loadedBytes >= 0
      && Number.isFinite(data.totalBytes) && data.totalBytes >= 0
      && Number.isFinite(data.progress) && data.progress >= 0 && data.progress <= 1
      && (data.phase === "download" || data.phase === "verify" || data.phase === "render");
  }
  if (data.type === "pdf:reload") {
    return validIdentifier(data.documentId, 72)
      && Number.isInteger(data.documentVersion) && data.documentVersion > 0;
  }
  const validPoint = (point, coordinateSpace) => point && Number.isFinite(point.x) && Number.isFinite(point.y)
    && (coordinateSpace === "whiteboard-world-v1"
      ? Math.abs(point.x) <= 1_000_000_000 && Math.abs(point.y) <= 1_000_000_000
      : point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1)
    && (point.p === undefined || (Number.isFinite(point.p) && point.p >= 0 && point.p <= 1))
    && (point.tiltX === undefined || (Number.isFinite(point.tiltX) && Math.abs(point.tiltX) <= 90))
    && (point.tiltY === undefined || (Number.isFinite(point.tiltY) && Math.abs(point.tiltY) <= 90))
    && (point.rollAngle === undefined || (Number.isFinite(point.rollAngle) && Math.abs(point.rollAngle) <= 360))
    && (point.timestamp === undefined || (Number.isFinite(point.timestamp) && point.timestamp >= 0))
    && (point.sampleIndex === undefined || (Number.isInteger(point.sampleIndex) && point.sampleIndex >= 0));
  if (data.type === "pdf:document") return typeof data.name === "string" && data.name.length > 0 && data.name.length <= 260;
  if (data.type === "pdf:viewport") {
    const hasInteractionId = data.interactionId !== undefined;
    const hasInteractionPhase = data.interactionPhase !== undefined;
    return Number.isInteger(data.pageIndex) && data.pageIndex >= 0
      && Number.isFinite(data.zoom) && data.zoom >= 0.5 && data.zoom <= 4
      && Number.isFinite(data.offset) && data.offset >= 0 && data.offset <= 1
      && (data.anchorX === undefined || (Number.isFinite(data.anchorX) && data.anchorX >= 0 && data.anchorX <= 1))
      && (data.anchorY === undefined || (Number.isFinite(data.anchorY) && data.anchorY >= 0 && data.anchorY <= 1))
      && (data.viewportWidth === undefined || (Number.isFinite(data.viewportWidth) && data.viewportWidth > 0 && data.viewportWidth <= 20_000))
      && (data.viewportHeight === undefined || (Number.isFinite(data.viewportHeight) && data.viewportHeight > 0 && data.viewportHeight <= 20_000))
      && (!hasInteractionId || validIdentifier(data.interactionId))
      && (!hasInteractionPhase || VIEWPORT_INTERACTION_PHASES.has(data.interactionPhase))
      && (hasInteractionId === hasInteractionPhase);
  }
  if (data.type === "whiteboard:viewport") {
    return normalizeWhiteboardViewport(data) !== null;
  }
  if (data.type === "pdf:preview") return typeof data.preview === "string" && data.preview.length > 0 && data.preview.length <= 420_000;
  if (data.type === "clear") return true;
  if (data.type === "history:undo" || data.type === "history:redo") {
    return data.mode === "pdf" || data.mode === "whiteboard";
  }
  if (data.type === "cursor:hide") return true;
  if (data.type === "cursor:move") return (data.coordinateSpace === undefined
      || data.coordinateSpace === "whiteboard-world-v1")
    && validPoint(data.point, data.coordinateSpace)
    && (data.pageIndex === undefined || (Number.isInteger(data.pageIndex) && data.pageIndex >= 0))
    && (data.canvasAspect === undefined || (Number.isFinite(data.canvasAspect) && data.canvasAspect > 0));
  if (!["stroke:start", "stroke:move", "stroke:replace", "stroke:end"].includes(data.type)
    || !validIdentifier(data.strokeId, 72)
    || (data.coordinateSpace !== undefined && data.coordinateSpace !== "whiteboard-world-v1")
    || (data.tool !== undefined && !["ink", "highlighter", "eraser"].includes(data.tool))
    || (data.opacity !== undefined
      && (!Number.isFinite(data.opacity) || data.opacity < 0.05 || data.opacity > 1))
    || (data.strokeSequence !== undefined
      && (!Number.isInteger(data.strokeSequence) || data.strokeSequence < 0 || data.strokeSequence > 1_000_000))) return false;
  if (data.type === "stroke:start") return validPoint(data.point, data.coordinateSpace);
  if (data.type === "stroke:move" || data.type === "stroke:replace") {
    return Array.isArray(data.points) && data.points.length > 0 && data.points.length <= 40
      && data.points.every((point) => validPoint(point, data.coordinateSpace));
  }
  return true;
}

function acceptsViewportControl(room, data, clientId) {
  const now = Date.now();
  if (room.viewportControl?.expiresAt <= now) room.viewportControl = null;
  const current = room.viewportControl;
  if (!data.interactionId && !data.interactionPhase) return !current;
  const interactionId = data.interactionId;
  const interactionPhase = data.interactionPhase;
  if (current && (current.sourceId !== clientId || current.interactionId !== interactionId)) {
    return false;
  }
  room.viewportControl = {
    sourceId: clientId,
    interactionId,
    expiresAt: now + viewportControlLeaseMs,
  };
  if (interactionPhase === "end") room.viewportControl = null;
  return true;
}

function acceptsWhiteboardViewportControl(room, data, clientId) {
  const now = Date.now();
  if (room.whiteboardViewportControl?.expiresAt <= now) room.whiteboardViewportControl = null;
  const current = room.whiteboardViewportControl;
  if (!data.interactionId && !data.interactionPhase) return !current;
  if (current && (current.sourceId !== clientId || current.interactionId !== data.interactionId)) return false;
  room.whiteboardViewportControl = {
    sourceId: clientId,
    interactionId: data.interactionId,
    expiresAt: now + viewportControlLeaseMs,
  };
  if (data.interactionPhase === "end") room.whiteboardViewportControl = null;
  return true;
}

function storedViewport(viewport) {
  const normalized = normalizePDFViewport(viewport);
  if (!normalized) return null;
  const { interactionId: _interactionId, interactionPhase: _interactionPhase, ...geometry } = normalized;
  return geometry;
}

function storedWhiteboardViewport(viewport) {
  const normalized = normalizeWhiteboardViewport(viewport);
  if (!normalized) return null;
  const { interactionId: _interactionId, interactionPhase: _interactionPhase, ...geometry } = normalized;
  return geometry;
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  if (url.pathname === "/config") {
    const localAddresses = addresses();
    response.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
    response.end(JSON.stringify({
      relayVersion,
      appVersion: INKBRIDGE_APP_VERSION,
      protocolVersion: INKBRIDGE_PROTOCOL_VERSION,
      urls: localAddresses.map((address) => `http://${address}:${port}`),
    }));
    return;
  }
  if (url.pathname === "/api/appearance") {
    const reply = (status, value) => {
      response.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      response.end(JSON.stringify(value));
    };
    if (request.method === "GET") return reply(200, sharedAppearance);
    if (request.method !== "PUT") return reply(405, { error: "method-not-allowed" });
    let body = "";
    try {
      for await (const chunk of request) {
        body += chunk.toString();
        if (Buffer.byteLength(body) > 2048) return reply(413, { error: "theme-too-large" });
      }
      const value = JSON.parse(body);
      if (!["automatic", "light", "dark"].includes(value.preference)
          || !["light", "dark"].includes(value.appearance)
          || (value.preference !== "automatic" && value.preference !== value.appearance)) {
        return reply(422, { error: "invalid-theme" });
      }
      if (value.baseRevision !== sharedAppearance.revision) return reply(409, sharedAppearance);
      sharedAppearance = { preference: value.preference, appearance: value.appearance, revision: sharedAppearance.revision + 1 };
      atomicWrite(appearancePath, JSON.stringify(sharedAppearance));
      return reply(200, sharedAppearance);
    } catch { return reply(400, { error: "invalid-json" }); }
  }
  const documentMatch = url.pathname.match(/^\/api\/pdf\/([A-Z0-9]{6})$/);
  if (documentMatch) {
    const roomCode = documentMatch[1];
    const room = rooms.get(roomCode);
    if (request.method === "GET") {
      if (!room?.document) return response.writeHead(404).end("PDF not available");
      const requestedId = url.searchParams.get("id");
      if (requestedId && requestedId !== room.document.id) return response.writeHead(409).end("A newer PDF is available");
      const requestedVersion = Number.parseInt(url.searchParams.get("version") ?? "", 10);
      if (Number.isInteger(requestedVersion) && requestedVersion !== room.document.version) {
        return response.writeHead(409).end("A newer PDF version is available");
      }
      const requestedHash = url.searchParams.get("hash");
      if (requestedHash && requestedHash !== room.document.hash) return response.writeHead(409).end("PDF hash mismatch");
      response.writeHead(200, {
        "content-type": "application/pdf",
        "content-length": room.document.data.length,
        "content-disposition": `inline; filename*=UTF-8''${encodeURIComponent(room.document.name)}`,
        "cache-control": "no-store",
        etag: `"sha256-${room.document.hash}"`,
        "x-pdf-id": room.document.id,
        "x-pdf-version": String(room.document.version),
        "x-pdf-sha256": room.document.hash,
      });
      return response.end(room.document.data);
    }
    if (request.method === "POST") {
      const target = roomFor(roomCode);
      const uploadSequence = ++nextUploadSequence;
      target.pendingUploadSequence = uploadSequence;
      const declaredLength = Number.parseInt(request.headers["content-length"]?.toString() ?? "", 10);
      if (Number.isFinite(declaredLength) && declaredLength > maxDocumentBytes) {
        response.writeHead(413).end("PDF exceeds 250 MB limit");
        request.resume();
        return;
      }
      const headerId = request.headers["x-pdf-id"]?.toString() ?? "";
      const documentId = /^[A-Za-z0-9-]{1,72}$/.test(headerId) ? headerId : randomUUID();
      const headerHash = request.headers["x-pdf-sha256"]?.toString().toLowerCase() ?? "";
      if (headerHash && !/^[a-f0-9]{64}$/.test(headerHash)) {
        response.writeHead(422).end("Invalid PDF hash");
        request.resume();
        return;
      }
      const expectedHash = /^[a-f0-9]{64}$/.test(headerHash) ? headerHash : "";
      const headerTransactionId = request.headers["x-pdf-transaction-id"]?.toString() ?? "";
      const transactionId = validIdentifier(headerTransactionId, 72) ? headerTransactionId : randomUUID();
      const requestedVersion = Number.parseInt(request.headers["x-pdf-version"]?.toString() ?? "", 10);
      let bytes = 0;
      const chunks = [];
      let tooLarge = false;
      let aborted = false;
      request.setTimeout(documentTransferTimeoutMs, () => {
        aborted = true;
        if (!response.headersSent) response.writeHead(408).end("PDF upload timed out");
        request.destroy();
      });
      request.on("aborted", () => { aborted = true; });
      request.on("data", (chunk) => {
        bytes += chunk.length;
        if (bytes > maxDocumentBytes) tooLarge = true;
        else chunks.push(chunk);
      });
      request.on("end", () => {
        if (aborted || response.writableEnded) return;
        if (!validRoom(roomCode) || !chunks.length || tooLarge) return response.writeHead(413).end("PDF exceeds 250 MB limit");
        if (target.pendingUploadSequence !== uploadSequence) return response.writeHead(409).end("Superseded by a newer PDF");
        let data;
        try {
          data = Buffer.concat(chunks);
        } catch {
          return response.writeHead(507).end("Not enough memory to receive PDF");
        }
        if (data.subarray(0, 5).toString() !== "%PDF-") return response.writeHead(422).end("Invalid PDF data");
        const actualHash = createHash("sha256").update(data).digest("hex");
        if (expectedHash && expectedHash !== actualHash) return response.writeHead(422).end("PDF hash mismatch");
        const nextVersion = Math.max(
          (target.document?.version ?? 0) + 1,
          Number.isInteger(requestedVersion) && requestedVersion > 0 ? requestedVersion : 1,
        );
        if (target.document && target.viewport
          && target.viewport.documentId === target.document.id
          && target.viewport.documentVersion === target.document.version) {
          target.viewportsByDocumentHash.set(target.document.hash, storedViewport(target.viewport));
        }
        if (target.document) schedulePersistRoom(roomCode, target, true);
        const projectState = readJSON(projectPaths(actualHash).state);
        const restoredViewport = projectState?.viewport
          ?? target.viewportsByDocumentHash.get(actualHash)
          ?? null;
        target.document = {
          data,
          name: pdfNameFromHeader(request.headers["x-pdf-name"]),
          id: documentId,
          version: nextVersion,
          hash: actualHash,
          transactionId,
          restoreAvailable: Boolean(projectState || restoredViewport),
        };
        const restoredProject = loadProject(actualHash, target.document);
        target.operations.pdf = restoredProject?.operations ?? [];
        target.historyCursor.pdf = restoredProject?.cursor ?? target.operations.pdf.length;
        target.historyRevision = Math.max(target.historyRevision, restoredProject?.historyRevision ?? 0);
        target.nextHistorySequence = Math.max(
          target.nextHistorySequence,
          restoredProject?.nextHistorySequence ?? 0,
        );
        rebuildHistory(target, "pdf");
        target.pendingStrokes.clear();
        rebuildStrokeProgress(target);
        target.preview = null;
        target.viewport = null;
        target.viewportControl = null;
        target.readyClients.clear();
        rooms.set(roomCode, target);
        broadcastServer(target, {
          type: "clear",
          mode: "pdf",
          phase: "document-switch",
          ...documentMetadata(target.document),
        }, null, true);
        broadcastServer(target, {
          type: "pdf:document",
          ...documentMetadata(target.document),
          history: target.histories.pdf,
          historyCursor: target.historyCursor.pdf,
          historyLength: target.operations.pdf.length,
          historyRevision: target.historyRevision,
        }, null, true);
        if (restoredViewport) {
          const restoredMessage = broadcastServer(target, {
            type: "pdf:viewport",
            ...restoredViewport,
            ...documentMetadata(target.document),
          }, null, true);
          target.viewport = restoredMessage;
        }
        schedulePersistRoom(roomCode, target, true);
        response.writeHead(201, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
        response.end(JSON.stringify(documentMetadata(target.document)));
      });
      return;
    }
    return response.writeHead(405).end("Method not allowed");
  }
  const roundTripUploadMatch = url.pathname.match(/^\/api\/roundtrip\/return\/([A-Z0-9]{6})$/);
  if (roundTripUploadMatch) {
    if (request.method !== "POST") return response.writeHead(405).end("Method not allowed");
    const roomCode = roundTripUploadMatch[1];
    const room = rooms.get(roomCode);
    if (!room) return response.writeHead(404).end("Room not available");
    const roundTripId = request.headers["x-roundtrip-id"]?.toString() ?? "";
    if (!validIdentifier(roundTripId, 72)) return response.writeHead(422).end("Invalid round trip id");
    const declaredLength = Number.parseInt(request.headers["content-length"]?.toString() ?? "", 10);
    if (Number.isFinite(declaredLength) && declaredLength > maxDocumentBytes) {
      request.resume();
      return response.writeHead(413).end("PDF exceeds 250 MB limit");
    }
    const chunks = [];
    let bytes = 0;
    let tooLarge = false;
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes > maxDocumentBytes) tooLarge = true;
      else chunks.push(chunk);
    });
    request.on("end", () => {
      if (tooLarge || !chunks.length) return response.writeHead(413).end("PDF exceeds 250 MB limit");
      const data = Buffer.concat(chunks);
      if (data.subarray(0, 5).toString() !== "%PDF-") return response.writeHead(422).end("Invalid PDF data");
      const hash = createHash("sha256").update(data).digest("hex");
      const returnId = randomUUID();
      const name = pdfNameFromHeader(request.headers["x-roundtrip-name"]);
      const path = join(roundTripDirectory, `${returnId}.pdf`);
      atomicWrite(path, data);
      const metadata = {
        roomCode,
        roundTripId,
        returnId,
        name,
        documentHash: hash,
        documentSize: statSync(path).size,
        path,
        createdAt: Date.now(),
      };
      roundTripReturns.set(returnId, metadata);
      broadcastServer(room, {
        type: "roundtrip:return-ready",
        roundTripId,
        returnId,
        name,
        documentHash: hash,
        documentSize: metadata.documentSize,
      }, null, true);
      response.writeHead(201, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      response.end(JSON.stringify({ roundTripId, returnId, name, documentHash: hash, documentSize: metadata.documentSize }));
    });
    return;
  }
  const roundTripDownloadMatch = url.pathname.match(
    /^\/api\/roundtrip\/return\/([A-Z0-9]{6})\/([A-Za-z0-9-]{1,72})$/,
  );
  if (roundTripDownloadMatch) {
    if (request.method !== "GET") return response.writeHead(405).end("Method not allowed");
    const [, roomCode, returnId] = roundTripDownloadMatch;
    const item = roundTripReturns.get(returnId);
    if (!item || item.roomCode !== roomCode || !existsSync(item.path)) {
      return response.writeHead(404).end("Returned PDF not available");
    }
    response.writeHead(200, {
      "content-type": "application/pdf",
      "content-length": item.documentSize,
      "content-disposition": `attachment; filename*=UTF-8''${encodeURIComponent(item.name)}`,
      "cache-control": "no-store",
      "x-pdf-sha256": item.documentHash,
    });
    return createReadStream(item.path).pipe(response);
  }
  const requested = url.pathname === "/" ? "/whiteboard.html" : url.pathname;
  const file = normalize(join(publicDirectory, decodeURIComponent(requested)));
  if (!file.startsWith(publicDirectory) || !existsSync(file)) return response.writeHead(404).end("Not found");
  response.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream", "cache-control": "no-cache" });
  createReadStream(file).pipe(response);
});

class LocalWebSocket {
  constructor(socket, head, onMessage, onClose) {
    this.socket = socket;
    this.onMessage = onMessage;
    this.onClose = onClose;
    this.buffer = Buffer.alloc(0);
    this.readyState = 1;
    socket.on("data", (chunk) => this.receive(chunk));
    socket.on("close", () => this.finish());
    socket.on("end", () => this.finish());
    socket.on("error", () => this.finish());
    if (head?.length) this.receive(head);
  }

  send(text) {
    if (this.readyState !== 1) return;
    this.writeFrame(0x1, Buffer.from(text));
  }

  receive(chunk) {
    if (this.readyState !== 1) return;
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      const final = (first & 0x80) !== 0;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2); offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        const bigLength = this.buffer.readBigUInt64BE(2);
        if (bigLength > 512_000n) return this.close(1009);
        length = Number(bigLength); offset = 10;
      }
      if (!masked || length > 512_000) return this.close(1009);
      if (this.buffer.length < offset + 4 + length) return;
      const mask = this.buffer.subarray(offset, offset + 4);
      offset += 4;
      const payload = Buffer.from(this.buffer.subarray(offset, offset + length));
      for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
      this.buffer = this.buffer.subarray(offset + length);
      if (!final && opcode !== 0x0) return this.close(1003);
      if (opcode === 0x8) return this.close();
      if (opcode === 0x9) { this.writeFrame(0xA, payload); continue; }
      // Browser clients use text frames, while URLSessionWebSocketTask on the
      // Mac sends the same JSON as a binary frame. Both carry UTF-8 relay data.
      if ((opcode === 0x1 || opcode === 0x2) && final) this.onMessage(payload.toString("utf8"));
    }
  }

  writeFrame(opcode, payload) {
    if (this.readyState !== 1 || this.socket.destroyed) return;
    const length = payload.length;
    let header;
    if (length < 126) header = Buffer.from([0x80 | opcode, length]);
    else if (length <= 0xffff) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(length, 2); }
    else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(length), 2); }
    this.socket.write(Buffer.concat([header, payload]));
  }

  close(code = 1000) {
    if (this.readyState !== 1) return;
    this.writeFrame(0x8, Buffer.from([code >> 8, code & 0xff]));
    this.socket.end();
    this.finish();
  }

  finish() {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.onClose();
  }
}

server.on("upgrade", (request, socket, head) => {
  if (new URL(request.url ?? "/", "http://localhost").pathname !== "/ws") return socket.destroy();
  const key = request.headers["sec-websocket-key"];
  if (typeof key !== "string") return socket.destroy();
  const accept = createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
  socket.write(["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", `Sec-WebSocket-Accept: ${accept}`, "", ""].join("\r\n"));
  attachWebSocket(socket, head);
});
function attachWebSocket(rawSocket, head) {
  // Ink samples are small, latency-sensitive frames. Disable Nagle's
  // algorithm so a move frame is not held while TCP waits for an ACK.
  rawSocket.setNoDelay(true);
  let roomCode = null;
  let role = "unknown";
  let clientId = "";
  let lastClientSequence = 0;
  const socket = new LocalWebSocket(rawSocket, head, (raw) => {
    let data; try { data = JSON.parse(raw.toString()); } catch { return; }
    if (data.type === "join") {
      if (roomCode || !validRoom(data.room)) return socket.close(1008, "Invalid room");
      roomCode = data.room;
      role = typeof data.role === "string" ? data.role : "unknown";
      const isProtocolV2 = data.protocolVersion === INKBRIDGE_PROTOCOL_VERSION && validIdentifier(data.sourceId);
      clientId = isProtocolV2 ? data.sourceId : `legacy-${randomUUID()}`;
      lastClientSequence = Number.isFinite(data.sequence) ? data.sequence : 0;
      const room = roomFor(roomCode); room.clients.add(socket);
      if (isProtocolV2) {
        sendServer(socket, room, {
          type: "session:welcome",
          clientId,
          role,
          room: roomCode,
          capabilities: [
            "snapshot",
            "document-ready",
            "document-hash",
            "document-lifecycle",
            "document-progress",
            "document-reload",
            "viewport-v3",
            "viewport-control",
            "whiteboard-viewport-v1",
            "page-coordinate-v2",
            "native-pen-v2",
            "stroke-batch-v2",
            "highlighter-v1",
            "stroke-replace-v1",
            "stroke-idempotency",
            "history-v1",
            "durable-project-v1",
            "transport-control-v1",
            "revision",
            "ack",
          ],
        });
        sendServer(socket, room, snapshotFor(room, role));
        if (role === "desktop" && room.document) {
          const ready = [...room.readyClients.values()].find((entry) =>
            entry.documentId === room.document.id
            && entry.documentVersion === room.document.version
            && entry.pageCount > 0
          );
          if (ready) {
            sendServer(socket, room, {
              type: "pdf:ready",
              ...documentMetadata(room.document),
              pageCount: ready.pageCount,
            });
          }
        }
      } else {
        send(socket, { type: "app:mode", mode: room.mode });
        send(socket, { type: "sync", history: historyForRole(room, role) });
        if (room.document) send(socket, { type: "pdf:document", ...documentMetadata(room.document) });
        if (room.preview) send(socket, room.preview);
      }
      const presence = { type: "presence", count: room.clients.size };
      broadcastServer(room, presence, socket);
      return sendServer(socket, room, presence);
    }
    if (!roomCode || !validDrawing(data)) return;
    const room = rooms.get(roomCode); if (!room) return;
    const isProtocolV2 = data.protocolVersion === INKBRIDGE_PROTOCOL_VERSION && data.sourceId === clientId;
    if (isProtocolV2 && Number.isFinite(data.sequence)) {
      if (data.sequence <= lastClientSequence) {
        sendAck(socket, room, data, "duplicate");
        return;
      }
      lastClientSequence = data.sequence;
    }
    if (data.type === "pdf:ready"
      || data.type === "pdf:error"
      || data.type === "pdf:progress"
      || data.type === "pdf:reload") {
      if (!room.document
        || data.documentId !== room.document.id
        || data.documentVersion !== room.document.version) {
        sendAck(socket, room, data, "stale-document");
        return;
      }
    }
    if (data.type === "pdf:viewport") {
      if (!room.document
        || data.documentId !== room.document.id
        || data.documentVersion !== room.document.version
        || (data.documentHash && data.documentHash !== room.document.hash)) {
        sendAck(socket, room, data, "stale-document");
        return;
      }
      if (!acceptsViewportControl(room, data, clientId)) {
        sendAck(socket, room, data, "viewport-locked");
        return;
      }
    }
    if (data.type === "whiteboard:viewport" && !acceptsWhiteboardViewportControl(room, data, clientId)) {
      sendAck(socket, room, data, "viewport-locked");
      return;
    }
    if (data.type.startsWith("stroke:")
      && Number.isInteger(data.pageIndex)
      && (!room.document
        || data.documentId !== room.document.id
        || data.documentVersion !== room.document.version
        || (data.documentHash && data.documentHash !== room.document.hash))) {
      sendAck(socket, room, data, "stale-document");
      return;
    }
    if (((data.type === "history:undo" || data.type === "history:redo") && data.mode === "pdf"
      || (data.type === "clear" && data.mode === "pdf"))
      && (!room.document
        || data.documentId !== room.document.id
        || data.documentVersion !== room.document.version
        || (data.documentHash && data.documentHash !== room.document.hash))) {
      sendAck(socket, room, data, "stale-document");
      return;
    }
    if (data.type.startsWith("stroke:")
      && Number.isInteger(data.strokeSequence)
      && validIdentifier(data.strokeId, 72)) {
      const strokeKey = `${clientId}:${data.strokeId}`;
      const progress = room.strokeProgress.get(strokeKey);
      if (progress?.ended || (progress && data.strokeSequence <= progress.sequence)) {
        sendAck(socket, room, data, "duplicate");
        return;
      }
      room.strokeProgress.set(strokeKey, {
        sequence: data.strokeSequence,
        ended: data.type === "stroke:end",
      });
      if (room.strokeProgress.size > 6_000) {
        const oldest = room.strokeProgress.keys().next().value;
        if (oldest) room.strokeProgress.delete(oldest);
      }
    }
    const messageMode = data.mode === "whiteboard" || data.mode === "pdf"
      ? data.mode
      : (Number.isInteger(data.pageIndex) || data.type.startsWith("pdf:") ? "pdf" : "whiteboard");
    let accepted = isProtocolV2
      ? { ...data, role, revision: ++room.revision }
      : serverEnvelope(room, { ...data, role, legacy: true }, true);
    let pendingStroke = null;
    let pendingStrokeKey = null;
    if (data.type.startsWith("stroke:") && validIdentifier(data.strokeId, 72)) {
      pendingStrokeKey = `${clientId}:${data.strokeId}`;
      pendingStroke = room.pendingStrokes.get(pendingStrokeKey);
      if (!pendingStroke) {
        const historySequence = ++room.nextHistorySequence;
        pendingStroke = {
          mode: messageMode,
          operationId: `op-${historySequence}-${String(data.strokeId).slice(0, 72)}`,
          historySequence,
          events: [],
        };
        room.pendingStrokes.set(pendingStrokeKey, pendingStroke);
      }
      accepted = {
        ...accepted,
        operationId: pendingStroke.operationId,
        historySequence: pendingStroke.historySequence,
      };
      pendingStroke.events.push(accepted);
      if (pendingStroke.events.length > maxEventsPerStroke) {
        pendingStroke.events.splice(1, pendingStroke.events.length - maxEventsPerStroke);
      }
    }
    if (data.type === "app:mode") {
      room.mode = data.mode;
      sendAck(socket, room, accepted);
      broadcastRaw(room, accepted, socket);
      schedulePersistRoom(roomCode, room);
      return;
    }
    if (data.type === "transport:request" || data.type === "transport:status"
      || data.type === "screen-mirror:request" || data.type === "screen-mirror:status") {
      sendAck(socket, room, accepted);
      broadcastRaw(room, accepted, socket);
      return;
    }
    if (data.type === "roundtrip:open") {
      sendAck(socket, room, accepted);
      broadcastRaw(room, accepted, socket);
      return;
    }
    if (data.type === "pdf:reload") {
      const reload = {
        ...accepted,
        ...documentMetadata(room.document),
      };
      sendAck(socket, room, reload);
      broadcastRaw(room, reload, socket);
      return;
    }
    if (data.type === "history:undo" || data.type === "history:redo") {
      const operations = room.operations[messageMode];
      const previousCursor = room.historyCursor[messageMode];
      const nextCursor = data.type === "history:undo"
        ? Math.max(0, previousCursor - 1)
        : Math.min(operations.length, previousCursor + 1);
      room.historyCursor[messageMode] = nextCursor;
      room.historyRevision += 1;
      const affected = data.type === "history:undo"
        ? operations[nextCursor]
        : operations[nextCursor - 1];
      accepted = {
        ...accepted,
        operationId: affected?.operationId,
        historySequence: affected?.historySequence,
        historyCursor: nextCursor,
        historyLength: operations.length,
        historyRevision: room.historyRevision,
        status: nextCursor === previousCursor ? "unchanged" : "accepted",
      };
      schedulePersistRoom(roomCode, room, true);
      sendAck(socket, room, accepted, accepted.status);
      broadcastRaw(room, serverEnvelope(room, {
        ...accepted,
        requestSourceId: clientId,
      }));
      return;
    }
    if (data.type === "pdf:ready" || data.type === "pdf:error" || data.type === "pdf:progress") {
      if (data.type === "pdf:ready") {
        room.readyClients.set(clientId, {
          documentId: data.documentId,
          documentVersion: data.documentVersion,
          pageCount: data.pageCount,
          role,
        });
      }
      sendAck(socket, room, accepted);
      broadcastRaw(room, accepted, socket);
      return;
    }
    if (data.type === "pdf:preview") room.preview = accepted;
    else if (data.type === "pdf:viewport") {
      const normalized = normalizePDFViewport(accepted);
      room.viewport = normalized ? { ...accepted, ...normalized } : accepted;
      if (room.document
        && room.viewport.documentId === room.document.id
        && room.viewport.documentVersion === room.document.version) {
        room.viewportsByDocumentHash.set(room.document.hash, storedViewport(room.viewport));
      }
      schedulePersistRoom(roomCode, room);
    }
    else if (data.type === "whiteboard:viewport") {
      const normalized = normalizeWhiteboardViewport(accepted);
      room.whiteboardViewport = normalized ? { ...accepted, ...normalized } : accepted;
      schedulePersistRoom(roomCode, room, data.interactionPhase === "end");
    }
    else if (data.type === "clear") {
      const historySequence = ++room.nextHistorySequence;
      const operation = {
        operationId: `op-${historySequence}-clear`,
        historySequence,
        events: [{
          ...accepted,
          operationId: `op-${historySequence}-clear`,
          historySequence,
        }],
      };
      room.operations[messageMode].splice(room.historyCursor[messageMode]);
      room.operations[messageMode].push(operation);
      room.historyCursor[messageMode] = room.operations[messageMode].length;
      trimOperationHistory(room, messageMode);
      room.historyCursor[messageMode] = room.operations[messageMode].length;
      room.historyRevision += 1;
      accepted = {
        ...operation.events[0],
        historyCursor: room.historyCursor[messageMode],
        historyLength: room.operations[messageMode].length,
        historyRevision: room.historyRevision,
      };
      operation.events[0] = accepted;
      rebuildHistory(room, messageMode);
      schedulePersistRoom(roomCode, room, true);
    }
    else if (data.type === "stroke:end" && pendingStroke && pendingStrokeKey) {
      room.pendingStrokes.delete(pendingStrokeKey);
      room.operations[messageMode].splice(room.historyCursor[messageMode]);
      room.operations[messageMode].push(pendingStroke);
      room.historyCursor[messageMode] = room.operations[messageMode].length;
      trimOperationHistory(room, messageMode);
      room.historyCursor[messageMode] = room.operations[messageMode].length;
      room.historyRevision += 1;
      accepted = {
        ...accepted,
        historyCursor: room.historyCursor[messageMode],
        historyLength: room.operations[messageMode].length,
        historyRevision: room.historyRevision,
      };
      pendingStroke.events[pendingStroke.events.length - 1] = accepted;
      rebuildHistory(room, messageMode);
      schedulePersistRoom(roomCode, room, true);
    }
    const outgoing = data.type === "pdf:viewport"
      ? room.viewport
      : (data.type === "whiteboard:viewport" ? room.whiteboardViewport : accepted);
    sendAck(socket, room, outgoing);
    if (data.type === "clear") {
      broadcastRaw(room, serverEnvelope(room, {
        ...accepted,
        requestSourceId: clientId,
      }));
      return;
    }
    broadcastRaw(room, outgoing, socket);
  }, () => {
    const room = rooms.get(roomCode); if (!room) return;
    room.clients.delete(socket);
    room.readyClients.delete(clientId);
    for (const key of room.pendingStrokes.keys()) {
      if (key.startsWith(`${clientId}:`)) room.pendingStrokes.delete(key);
    }
    if (!room.clients.size) retainIdleRoom(roomCode, room);
    else broadcastServer(room, { type: "presence", count: room.clients.size });
  });
}
server.listen(port, "0.0.0.0", () => {
  console.log(`\nLinkDesk ${INKBRIDGE_APP_VERSION}（协议 v${INKBRIDGE_PROTOCOL_VERSION}）已启动： http://localhost:${port}`);
  for (const address of addresses()) console.log(`平板连接地址： http://${address}:${port}`);
  console.log("在 Mac 浏览器打开地址后，用页面二维码连接平板。\n");
});
