export const INKBRIDGE_APP_VERSION = "1.6.10";
export const INKBRIDGE_PROTOCOL_VERSION = 2;
export const WHITEBOARD_COORDINATE_SPACE = "whiteboard-world-v1";
export const WHITEBOARD_MIN_ZOOM = 0.25;
export const WHITEBOARD_MAX_ZOOM = 8;

export const VIEWPORT_INTERACTION_PHASES = new Set(["begin", "update", "end"]);

const ACK_TYPES = new Set([
  "app:mode",
  "clear",
  "history:undo",
  "history:redo",
  "pdf:ready",
  "pdf:error",
  "pdf:reload",
  "pdf:viewport",
  "whiteboard:viewport",
  "stroke:end",
  "transport:request",
  "transport:status",
  "screen-mirror:request",
  "screen-mirror:status",
  "roundtrip:open",
  "roundtrip:return-ready",
]);

function fallbackId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`;
}

export function createProtocolClient(role) {
  const storageKey = `inkbridge-client-id:${role}`;
  let clientId = "";
  try {
    clientId = sessionStorage.getItem(storageKey) || "";
    if (!clientId) {
      clientId = globalThis.crypto?.randomUUID?.() || fallbackId();
      sessionStorage.setItem(storageKey, clientId);
    }
  } catch {
    clientId = fallbackId();
  }

  let sequence = 0;
  let lastRevision = 0;
  const lastSequenceBySource = new Map();

  function resetForConnection() {
    lastRevision = 0;
    lastSequenceBySource.clear();
  }

  function prepare(message) {
    sequence += 1;
    return {
      ...message,
      protocolVersion: INKBRIDGE_PROTOCOL_VERSION,
      appVersion: INKBRIDGE_APP_VERSION,
      sourceId: clientId,
      sequence,
      messageId: `${clientId}:${sequence}`,
      sentAt: Date.now(),
      requiresAck: ACK_TYPES.has(message.type),
    };
  }

  function join(room, capabilities = []) {
    return prepare({
      type: "join",
      room,
      role,
      capabilities,
    });
  }

  function accept(message) {
    if (!message || typeof message !== "object") return false;
    if (message.sourceId === clientId) return false;
    if (Number.isFinite(message.revision) && message.revision < lastRevision) return false;
    if (typeof message.sourceId === "string" && Number.isFinite(message.sequence)) {
      const previous = lastSequenceBySource.get(message.sourceId) || 0;
      if (message.sequence <= previous) return false;
      lastSequenceBySource.set(message.sourceId, message.sequence);
    }
    if (Number.isFinite(message.revision)) lastRevision = Math.max(lastRevision, message.revision);
    return true;
  }

  function acceptSnapshot(message) {
    if (!message || message.type !== "session:snapshot") return false;
    if (Number.isFinite(message.revision) && message.revision < lastRevision) return false;
    if (Number.isFinite(message.revision)) lastRevision = message.revision;
    return true;
  }

  return {
    clientId,
    role,
    prepare,
    join,
    accept,
    acceptSnapshot,
    resetForConnection,
    get lastRevision() { return lastRevision; },
  };
}

export function documentMatches(message, documentState) {
  if (!message?.documentId && !message?.documentVersion) return true;
  if (!documentState?.documentId) return false;
  return message.documentId === documentState.documentId
    && Number(message.documentVersion || 0) === Number(documentState.documentVersion || 0);
}

export function viewportDocumentEdges(viewport, pageCount) {
  const count = Number.isInteger(pageCount) && pageCount > 0 ? pageCount : 1;
  return {
    top: viewport?.pageIndex === 0 && Number(viewport.offset) <= 0.0001,
    bottom: viewport?.pageIndex === count - 1 && Number(viewport.offset) >= 0.9999,
  };
}

export function normalizePDFViewport(viewport) {
  if (!viewport || typeof viewport !== "object" || !Number.isInteger(viewport.pageIndex)) return null;
  const finite = (value, fallback) => Number.isFinite(Number(value)) ? Number(value) : fallback;
  const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));
  const phase = VIEWPORT_INTERACTION_PHASES.has(viewport.interactionPhase)
    ? viewport.interactionPhase
    : undefined;
  const interactionId = typeof viewport.interactionId === "string" && viewport.interactionId.length > 0
    ? viewport.interactionId.slice(0, 120)
    : undefined;
  return {
    pageIndex: Math.max(0, viewport.pageIndex),
    zoom: clamp(finite(viewport.zoom, 1), 0.5, 4),
    offset: clamp(finite(viewport.offset, 0), 0, 1),
    anchorX: clamp(finite(viewport.anchorX, 0.5), 0, 1),
    anchorY: clamp(finite(viewport.anchorY, 0.5), 0, 1),
    viewportWidth: clamp(finite(viewport.viewportWidth, 1), 1, 20_000),
    viewportHeight: clamp(finite(viewport.viewportHeight, 1), 1, 20_000),
    ...(interactionId ? { interactionId } : {}),
    ...(phase ? { interactionPhase: phase } : {}),
  };
}

export function normalizeWhiteboardViewport(viewport) {
  if (!viewport || typeof viewport !== "object") return null;
  const centerX = Number(viewport.centerX);
  const centerY = Number(viewport.centerY);
  const zoom = Number(viewport.zoom);
  const viewportWidth = Number(viewport.viewportWidth);
  const viewportHeight = Number(viewport.viewportHeight);
  if (!Number.isFinite(centerX) || !Number.isFinite(centerY)
    || !Number.isFinite(zoom) || !Number.isFinite(viewportWidth) || !Number.isFinite(viewportHeight)) return null;
  if (Math.abs(centerX) > 1_000_000_000 || Math.abs(centerY) > 1_000_000_000
    || zoom < WHITEBOARD_MIN_ZOOM || zoom > WHITEBOARD_MAX_ZOOM
    || viewportWidth < 1 || viewportWidth > 20_000
    || viewportHeight < 1 || viewportHeight > 20_000) return null;
  const phase = VIEWPORT_INTERACTION_PHASES.has(viewport.interactionPhase)
    ? viewport.interactionPhase
    : undefined;
  const interactionId = typeof viewport.interactionId === "string" && viewport.interactionId.length > 0
    ? viewport.interactionId.slice(0, 120)
    : undefined;
  if (Boolean(interactionId) !== Boolean(phase)) return null;
  return {
    centerX,
    centerY,
    zoom,
    viewportWidth,
    viewportHeight,
    ...(interactionId ? { interactionId } : {}),
    ...(phase ? { interactionPhase: phase } : {}),
  };
}

export function viewportAnchorPage(pageRects, centerY) {
  if (!Array.isArray(pageRects) || !pageRects.length || !Number.isFinite(centerY)) return null;
  let closest = null;
  let closestDistance = Number.POSITIVE_INFINITY;
  for (const page of pageRects) {
    if (!page || !Number.isInteger(page.index) || !Number.isFinite(page.top) || !Number.isFinite(page.height) || page.height <= 0) continue;
    const bottom = page.top + page.height;
    if (centerY >= page.top && centerY <= bottom) return page;
    const distance = centerY < page.top ? page.top - centerY : centerY - bottom;
    if (distance < closestDistance) {
      closest = page;
      closestDistance = distance;
    }
  }
  return closest;
}

export function boundedCanvasPixelRatio({
  devicePixelRatio = 1,
  cssPixelArea = 0,
  maximumCssEdge = 0,
  canvasCount = 2,
  memoryBudgetBytes = 192 * 1024 * 1024,
  maximumCanvasEdge = 4096,
} = {}) {
  const finitePositive = (value, fallback) => {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? number : fallback;
  };
  const requestedRatio = Math.min(4, finitePositive(devicePixelRatio, 1));
  const area = Math.max(0, Number(cssPixelArea) || 0);
  const count = finitePositive(canvasCount, 2);
  const budget = finitePositive(memoryBudgetBytes, 192 * 1024 * 1024);
  const edge = Math.max(0, Number(maximumCssEdge) || 0);
  const edgeLimit = finitePositive(maximumCanvasEdge, 4096);
  const ratioForBudget = area > 0
    ? Math.sqrt(budget / (area * count * 4))
    : requestedRatio;
  const ratioForEdge = edge > 0 ? edgeLimit / edge : requestedRatio;
  return Math.max(0.01, Math.min(requestedRatio, ratioForBudget, ratioForEdge));
}

export function scaledCursorDiameter(baseDiameter, pageZoom) {
  const base = Number(baseDiameter);
  const zoom = Number(pageZoom);
  const safeBase = Number.isFinite(base) && base > 0 ? base : 1;
  const safeZoom = Number.isFinite(zoom) && zoom > 0 ? zoom : 1;
  return safeBase * safeZoom;
}

const SHA256_ROUND_CONSTANTS = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

function rotateRight(value, amount) {
  return (value >>> amount) | (value << (32 - amount));
}

// ArkWeb does not expose WebCrypto on every non-HTTPS local-network page.
// Keep document verification mandatory by providing an incremental fallback
// instead of accepting an unverified PDF.
export async function sha256HexPortable(bytes) {
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const paddedLength = Math.ceil((data.byteLength + 9) / 64) * 64;
  const bitLengthHigh = Math.floor(data.byteLength / 0x20000000) >>> 0;
  const bitLengthLow = (data.byteLength << 3) >>> 0;
  const schedule = new Uint32Array(64);
  const hash = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);

  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let word = 0; word < 16; word += 1) {
      let value = 0;
      for (let byte = 0; byte < 4; byte += 1) {
        const index = offset + word * 4 + byte;
        let next = 0;
        if (index < data.byteLength) next = data[index];
        else if (index === data.byteLength) next = 0x80;
        else if (index >= paddedLength - 8) {
          const shift = (paddedLength - 1 - index) * 8;
          next = shift >= 32
            ? (bitLengthHigh >>> (shift - 32)) & 0xff
            : (bitLengthLow >>> shift) & 0xff;
        }
        value = (value << 8) | next;
      }
      schedule[word] = value >>> 0;
    }
    for (let word = 16; word < 64; word += 1) {
      const before15 = schedule[word - 15];
      const before2 = schedule[word - 2];
      const sigma0 = rotateRight(before15, 7) ^ rotateRight(before15, 18) ^ (before15 >>> 3);
      const sigma1 = rotateRight(before2, 17) ^ rotateRight(before2, 19) ^ (before2 >>> 10);
      schedule[word] = (schedule[word - 16] + sigma0 + schedule[word - 7] + sigma1) >>> 0;
    }

    let [a, b, c, d, e, f, g, h] = hash;
    for (let round = 0; round < 64; round += 1) {
      const sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      const choice = (e & f) ^ (~e & g);
      const temp1 = (h + sum1 + choice + SHA256_ROUND_CONSTANTS[round] + schedule[round]) >>> 0;
      const sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (sum0 + majority) >>> 0;
      h = g; g = f; f = e; e = (d + temp1) >>> 0;
      d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
    }
    hash[0] = (hash[0] + a) >>> 0;
    hash[1] = (hash[1] + b) >>> 0;
    hash[2] = (hash[2] + c) >>> 0;
    hash[3] = (hash[3] + d) >>> 0;
    hash[4] = (hash[4] + e) >>> 0;
    hash[5] = (hash[5] + f) >>> 0;
    hash[6] = (hash[6] + g) >>> 0;
    hash[7] = (hash[7] + h) >>> 0;

    // Yield every 2 MiB so large documents do not freeze the tablet UI.
    if (offset > 0 && offset % (2 * 1024 * 1024) === 0) {
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  }
  return [...hash].map((value) => value.toString(16).padStart(8, "0")).join("");
}

export async function sha256Hex(bytes) {
  if (globalThis.crypto?.subtle) {
    try {
      const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
      return [...new Uint8Array(digest)].map((value) => value.toString(16).padStart(2, "0")).join("");
    } catch {}
  }
  return sha256HexPortable(bytes);
}
