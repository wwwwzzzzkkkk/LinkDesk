import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import WebSocket from "ws";
import {
  boundedCanvasPixelRatio,
  createProtocolClient,
  normalizePDFViewport,
  normalizeWhiteboardViewport,
  scaledCursorDiameter,
  sha256HexPortable,
  viewportAnchorPage,
  viewportDocumentEdges,
} from "../public/inkbridge-protocol.js";

test("portable SHA-256 keeps PDF verification available without WebCrypto", async () => {
  const digest = await sha256HexPortable(new TextEncoder().encode("abc"));
  assert.equal(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

const room = "P1TEST";
let relay;
let baseURL;
const dataDirectory = mkdtempSync(join(tmpdir(), "inkbridge-phase5-"));

async function unusedPort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function waitUntilReady(url) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${url}/config`);
      if (response.ok) return response.json();
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("relay did not start");
}

function makeClient(role, id, roomCode = room) {
  let sequence = 0;
  const messages = [];
  const waiters = [];
  const socket = new WebSocket(baseURL.replace("http", "ws") + "/ws");
  socket.on("message", (raw) => {
    const message = JSON.parse(raw.toString());
    messages.push(message);
    for (const waiter of [...waiters]) {
      if (waiter.predicate(message)) {
        waiters.splice(waiters.indexOf(waiter), 1);
        clearTimeout(waiter.timer);
        waiter.resolve(message);
      }
    }
  });

  function envelope(type, fields = {}, requiresAck = false) {
    sequence += 1;
    return {
      type,
      ...fields,
      protocolVersion: 2,
      appVersion: "1.6.10",
      sourceId: id,
      sequence,
      messageId: `${id}:${sequence}`,
      sentAt: Date.now(),
      requiresAck,
    };
  }

  function waitFor(predicate, timeout = 3_000) {
    const existing = messages.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve, timer: null };
      waiter.timer = setTimeout(() => {
        const index = waiters.indexOf(waiter);
        if (index >= 0) waiters.splice(index, 1);
        reject(new Error(`timed out waiting for ${role} message`));
      }, timeout);
      waiters.push(waiter);
    });
  }

  async function join() {
    if (socket.readyState !== WebSocket.OPEN) {
      await new Promise((resolve, reject) => {
        socket.once("open", resolve);
        socket.once("error", reject);
      });
    }
    socket.send(JSON.stringify(envelope("join", {
      room: roomCode,
      role,
      capabilities: ["snapshot", "document-ready", "revision", "ack"],
    })));
    await waitFor((message) => message.type === "session:welcome");
    return waitFor((message) => message.type === "session:snapshot");
  }

  return {
    socket,
    messages,
    envelope,
    waitFor,
    join,
    close: () => socket.close(),
  };
}

function testPDF(label) {
  return Buffer.from(`%PDF-1.4\n% InkBridge ${label}\n1 0 obj<</Type/Catalog>>endobj\n%%EOF\n`);
}

async function uploadPDF(pdf, {
  id,
  version,
  transactionId,
  name = `${id}.pdf`,
  hash = createHash("sha256").update(pdf).digest("hex"),
} = {}) {
  return fetch(`${baseURL}/api/pdf/${room}`, {
    method: "POST",
    headers: {
      "content-type": "application/pdf",
      "x-pdf-name": encodeURIComponent(name),
      "x-pdf-id": id,
      "x-pdf-version": String(version),
      "x-pdf-sha256": hash,
      "x-pdf-transaction-id": transactionId,
    },
    body: pdf,
  });
}

async function responseBody(response) {
  const chunks = [];
  for await (const chunk of response) chunks.push(chunk);
  return Buffer.concat(chunks);
}

async function startSlowUpload(pdf, fields) {
  const url = new URL(`${baseURL}/api/pdf/${room}`);
  let resolveResponse;
  let rejectResponse;
  const responsePromise = new Promise((resolve, reject) => {
    resolveResponse = resolve;
    rejectResponse = reject;
  });
  const hash = createHash("sha256").update(pdf).digest("hex");
  const request = httpRequest({
    hostname: url.hostname,
    port: url.port,
    path: url.pathname,
    method: "POST",
    headers: {
      "content-type": "application/pdf",
      "content-length": String(pdf.length),
      "x-pdf-name": encodeURIComponent(fields.name),
      "x-pdf-id": fields.id,
      "x-pdf-version": String(fields.version),
      "x-pdf-sha256": hash,
      "x-pdf-transaction-id": fields.transactionId,
    },
  });
  request.once("response", async (response) => {
    const body = await responseBody(response);
    resolveResponse({ status: response.statusCode, body });
  });
  request.once("error", rejectResponse);
  const split = Math.max(5, Math.floor(pdf.length / 2));
  request.write(pdf.subarray(0, split));
  await new Promise((resolve) => setTimeout(resolve, 80));
  return {
    finish() {
      request.end(pdf.subarray(split));
      return responsePromise;
    },
  };
}

before(async () => {
  const port = await unusedPort();
  baseURL = `http://127.0.0.1:${port}`;
  relay = spawn(process.execPath, ["local-server.mjs"], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(port), INKBRIDGE_DATA_DIR: dataDirectory },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const config = await waitUntilReady(baseURL);
  assert.equal(config.appVersion, "1.6.10");
  assert.equal(config.protocolVersion, 2);
  assert.equal(config.relayVersion, 16);
});

after(() => {
  relay?.kill("SIGTERM");
  rmSync(dataDirectory, { recursive: true, force: true });
});

test("a new socket accepts a fresh relay revision after the relay restarts", () => {
  const client = createProtocolClient("restart-test");
  assert.equal(client.accept({ type: "presence", sourceId: "relay-a", sequence: 1, revision: 20 }), true);
  assert.equal(client.accept({ type: "presence", sourceId: "relay-a", sequence: 2, revision: 1 }), false);
  client.resetForConnection();
  assert.equal(client.accept({ type: "presence", sourceId: "relay-b", sequence: 1, revision: 1 }), true);
});

test("transport control validates requests and confirms Wi-Fi or USB after reconnect", async () => {
  const desktop = makeClient("desktop", "mac-transport-test");
  const pad = makeClient("pdfpad", "pad-transport-test");
  await desktop.join();
  await pad.join();

  const request = desktop.envelope("transport:request", {
    transport: "usb",
    transportPreference: "automatic",
    requestId: "switch-to-usb-1",
  }, true);
  desktop.socket.send(JSON.stringify(request));
  const receivedRequest = await pad.waitFor((message) =>
    message.type === "transport:request" && message.requestId === "switch-to-usb-1"
  );
  assert.equal(receivedRequest.transport, "usb");
  assert.equal(receivedRequest.transportPreference, "automatic");
  const requestAck = await desktop.waitFor((message) =>
    message.type === "ack" && message.ackMessageId === request.messageId
  );
  assert.equal(requestAck.status, "accepted");

  const status = pad.envelope("transport:status", {
    transport: "usb",
    transportPreference: "automatic",
    requestId: "switch-to-usb-1",
    deviceId: "pad-transport-test",
  }, true);
  pad.socket.send(JSON.stringify(status));
  const confirmed = await desktop.waitFor((message) =>
    message.type === "transport:status" && message.requestId === "switch-to-usb-1"
  );
  assert.equal(confirmed.transport, "usb");
  assert.equal(confirmed.deviceId, "pad-transport-test");

  const invalid = desktop.envelope("transport:request", {
    transport: "bluetooth",
    transportPreference: "automatic",
    requestId: "invalid-transport-1",
  }, true);
  desktop.socket.send(JSON.stringify(invalid));
  await assert.rejects(
    pad.waitFor((message) => message.requestId === "invalid-transport-1", 180),
    /timed out/,
  );

  desktop.close();
  pad.close();
});

test("screen mirror control starts or stops from either endpoint", async () => {
  const desktop = makeClient("desktop", "mac-screen-mirror-test");
  const pad = makeClient("pdfpad", "pad-screen-mirror-test");
  await desktop.join();
  await pad.join();

  const start = desktop.envelope("screen-mirror:request", {
    action: "start",
    requestId: "mirror-start-1",
  }, true);
  desktop.socket.send(JSON.stringify(start));
  const receivedStart = await pad.waitFor((message) =>
    message.type === "screen-mirror:request" && message.requestId === "mirror-start-1"
  );
  assert.equal(receivedStart.action, "start");

  const started = pad.envelope("screen-mirror:status", {
    status: "started",
    requestId: "mirror-start-1",
  }, true);
  pad.socket.send(JSON.stringify(started));
  const confirmed = await desktop.waitFor((message) =>
    message.type === "screen-mirror:status" && message.requestId === "mirror-start-1"
  );
  assert.equal(confirmed.status, "started");

  const stop = pad.envelope("screen-mirror:request", {
    action: "stop",
    requestId: "mirror-stop-from-pad-1",
  }, true);
  pad.socket.send(JSON.stringify(stop));
  const receivedStop = await desktop.waitFor((message) =>
    message.type === "screen-mirror:request" && message.requestId === "mirror-stop-from-pad-1"
  );
  assert.equal(receivedStop.action, "stop");

  const invalid = desktop.envelope("screen-mirror:request", {
    action: "toggle-unvalidated",
    requestId: "mirror-invalid-1",
  }, true);
  desktop.socket.send(JSON.stringify(invalid));
  await assert.rejects(
    pad.waitFor((message) => message.requestId === "mirror-invalid-1", 180),
    /timed out/,
  );

  desktop.close();
  pad.close();
});

test("PDF round trip opens on the tablet and returns a verified copy to the Mac", async () => {
  const desktop = makeClient("desktop", "mac-roundtrip-test");
  const pad = makeClient("pdfpad", "pad-roundtrip-test");
  await desktop.join();
  await pad.join();

  const source = testPDF("roundtrip-source");
  const sourceHash = createHash("sha256").update(source).digest("hex");
  const upload = await uploadPDF(source, {
    id: "roundtrip-source-id",
    version: 1,
    transactionId: "roundtrip-source-transaction",
    name: "roundtrip-source.pdf",
    hash: sourceHash,
  });
  assert.equal(upload.status, 201);

  const open = desktop.envelope("roundtrip:open", {
    roundTripId: "roundtrip-task-1",
    name: "roundtrip-source.pdf",
    documentId: "roundtrip-source-id",
    documentVersion: 1,
    documentHash: sourceHash,
    documentSize: source.length,
  }, true);
  desktop.socket.send(JSON.stringify(open));
  const receivedOpen = await pad.waitFor((message) =>
    message.type === "roundtrip:open" && message.roundTripId === "roundtrip-task-1"
  );
  assert.equal(receivedOpen.documentHash, sourceHash);

  const annotated = testPDF("roundtrip-annotated");
  const returnedResponse = await fetch(`${baseURL}/api/roundtrip/return/${room}`, {
    method: "POST",
    headers: {
      "content-type": "application/pdf",
      "x-roundtrip-id": "roundtrip-task-1",
      "x-roundtrip-name": encodeURIComponent("roundtrip-source_已批注.pdf"),
    },
    body: annotated,
  });
  assert.equal(returnedResponse.status, 201);
  const returnedMetadata = await returnedResponse.json();
  const ready = await desktop.waitFor((message) =>
    message.type === "roundtrip:return-ready" && message.roundTripId === "roundtrip-task-1"
  );
  assert.equal(ready.returnId, returnedMetadata.returnId);
  const download = await fetch(`${baseURL}/api/roundtrip/return/${room}/${returnedMetadata.returnId}`);
  assert.equal(download.status, 200);
  assert.deepEqual(Buffer.from(await download.arrayBuffer()), annotated);

  desktop.close();
  pad.close();
});

test("page-local offsets cannot masquerade as document edges", () => {
  assert.deepEqual(
    viewportDocumentEdges({ pageIndex: 4, offset: 0 }, 10),
    { top: false, bottom: false },
  );
  assert.deepEqual(
    viewportDocumentEdges({ pageIndex: 4, offset: 1 }, 10),
    { top: false, bottom: false },
  );
  assert.deepEqual(
    viewportDocumentEdges({ pageIndex: 0, offset: 0 }, 10),
    { top: true, bottom: false },
  );
  assert.deepEqual(
    viewportDocumentEdges({ pageIndex: 9, offset: 1 }, 10),
    { top: false, bottom: true },
  );
});

test("PDF canvas backing stores stay inside the tablet graphics-memory budget", () => {
  const ratio = boundedCanvasPixelRatio({
    devicePixelRatio: 2,
    cssPixelArea: 92_000_000,
    maximumCssEdge: 7_000,
    memoryBudgetBytes: 192 * 1024 * 1024,
    maximumCanvasEdge: 4096,
  });
  assert.ok(ratio < 0.75);
  assert.ok(92_000_000 * 2 * 4 * ratio * ratio <= 192 * 1024 * 1024 + 1);
  assert.ok(7_000 * ratio <= 4096 + 1);
  assert.equal(boundedCanvasPixelRatio({
    devicePixelRatio: 2,
    cssPixelArea: 1_000_000,
    maximumCssEdge: 1_000,
  }), 2);
});

test("eraser cursor keeps its document-relative scale", () => {
  assert.equal(scaledCursorDiameter(48, 0.5), 24);
  assert.equal(scaledCursorDiameter(48, 2), 96);
});

test("phase 3 normalizes viewport geometry and chooses the page at the visual center", () => {
  assert.deepEqual(
    normalizePDFViewport({
      pageIndex: 3,
      zoom: 9,
      offset: -2,
      anchorX: 1.4,
      anchorY: -0.4,
      viewportWidth: 1280,
      viewportHeight: 720,
      interactionId: "gesture-1",
      interactionPhase: "update",
    }),
    {
      pageIndex: 3,
      zoom: 4,
      offset: 0,
      anchorX: 1,
      anchorY: 0,
      viewportWidth: 1280,
      viewportHeight: 720,
      interactionId: "gesture-1",
      interactionPhase: "update",
    },
  );
  const pages = [
    { index: 0, top: 0, height: 800 },
    { index: 1, top: 818, height: 800 },
    { index: 2, top: 1636, height: 800 },
  ];
  assert.equal(viewportAnchorPage(pages, 790).index, 0);
  assert.equal(viewportAnchorPage(pages, 809).index, 0);
  assert.equal(viewportAnchorPage(pages, 1_100).index, 1);
  assert.equal(viewportAnchorPage(pages, 2_430).index, 2);
});

test("infinite whiteboard accepts unbounded centers with a normal zoom range", () => {
  assert.deepEqual(normalizeWhiteboardViewport({
    centerX: -348_219.5,
    centerY: 927_440.25,
    zoom: 2.5,
    viewportWidth: 1280,
    viewportHeight: 800,
    interactionId: "whiteboard-gesture-1",
    interactionPhase: "update",
  }), {
    centerX: -348_219.5,
    centerY: 927_440.25,
    zoom: 2.5,
    viewportWidth: 1280,
    viewportHeight: 800,
    interactionId: "whiteboard-gesture-1",
    interactionPhase: "update",
  });
  assert.equal(normalizeWhiteboardViewport({
    centerX: 0, centerY: 0, zoom: 0.24, viewportWidth: 1280, viewportHeight: 800,
  }), null);
  assert.equal(normalizeWhiteboardViewport({
    centerX: 0, centerY: 0, zoom: 8.01, viewportWidth: 1280, viewportHeight: 800,
  }), null);
  assert.equal(normalizeWhiteboardViewport({
    centerX: Number.POSITIVE_INFINITY, centerY: 0, zoom: 1, viewportWidth: 1280, viewportHeight: 800,
  }), null);
});

test("whiteboard viewport and world-coordinate strokes survive snapshots without replacing PDF viewport", async () => {
  const pad = makeClient("pad", "infinite-whiteboard-pad");
  const desktop = makeClient("desktop", "infinite-whiteboard-desktop");
  await pad.join();
  await desktop.join();

  const viewport = pad.envelope("whiteboard:viewport", {
    centerX: -12_345.5,
    centerY: 67_890.25,
    zoom: 1.75,
    viewportWidth: 1280,
    viewportHeight: 800,
    interactionId: "infinite-pan-1",
    interactionPhase: "end",
  }, true);
  pad.socket.send(JSON.stringify(viewport));
  const receivedViewport = await desktop.waitFor((message) =>
    message.type === "whiteboard:viewport" && message.centerX === -12_345.5
  );
  assert.equal(receivedViewport.zoom, 1.75);

  const strokeId = "world-stroke-1";
  const start = pad.envelope("stroke:start", {
    strokeId,
    strokeSequence: 0,
    coordinateSpace: "whiteboard-world-v1",
    canvasAspect: 1.6,
    tool: "ink",
    color: "#152441",
    width: 4.5,
    point: { x: -12_700.25, y: 68_120.75, p: 0.5 },
  });
  const end = pad.envelope("stroke:end", {
    strokeId,
    strokeSequence: 1,
    coordinateSpace: "whiteboard-world-v1",
    tool: "ink",
  }, true);
  pad.socket.send(JSON.stringify(start));
  pad.socket.send(JSON.stringify(end));
  await pad.waitFor((message) => message.type === "ack" && message.ackMessageId === end.messageId);

  const observer = makeClient("pad", "infinite-whiteboard-observer");
  const snapshot = await observer.join();
  assert.equal(snapshot.whiteboardViewport.centerX, -12_345.5);
  assert.equal(snapshot.whiteboardViewport.centerY, 67_890.25);
  assert.equal(snapshot.whiteboardViewport.zoom, 1.75);
  const restoredStart = snapshot.history.find((message) => message.strokeId === strokeId && message.type === "stroke:start");
  assert.equal(restoredStart.coordinateSpace, "whiteboard-world-v1");
  assert.deepEqual(restoredStart.point, { x: -12_700.25, y: 68_120.75, p: 0.5 });

  observer.close();
  desktop.close();
  pad.close();
});

test("whiteboard clear, undo, redo, and role-specific cursors survive snapshots", async () => {
  const pad = makeClient("pad", "whiteboard-history-pad");
  const desktop = makeClient("desktop", "whiteboard-history-desktop");
  const initial = await pad.join();
  await desktop.join();
  const initialLength = initial.whiteboardHistoryLength ?? initial.historyLength ?? 0;

  const strokeId = "whiteboard-history-stroke";
  const start = pad.envelope("stroke:start", {
    mode: "whiteboard",
    strokeId,
    strokeSequence: 0,
    coordinateSpace: "whiteboard-world-v1",
    tool: "ink",
    color: "#152441",
    width: 4.5,
    point: { x: 48, y: -72, p: 0.45 },
  });
  const end = pad.envelope("stroke:end", {
    mode: "whiteboard",
    strokeId,
    strokeSequence: 1,
    coordinateSpace: "whiteboard-world-v1",
    tool: "ink",
  }, true);
  pad.socket.send(JSON.stringify(start));
  pad.socket.send(JSON.stringify(end));
  await pad.waitFor((message) => message.type === "ack" && message.ackMessageId === end.messageId);

  const clear = desktop.envelope("clear", { mode: "whiteboard" }, true);
  desktop.socket.send(JSON.stringify(clear));
  const canonicalClear = await pad.waitFor((message) =>
    message.type === "clear"
      && message.mode === "whiteboard"
      && message.sourceId === "inkbridge-relay"
      && message.historyLength === initialLength + 2);
  assert.equal(canonicalClear.historyCursor, initialLength + 2);

  const undo = desktop.envelope("history:undo", { mode: "whiteboard" }, true);
  desktop.socket.send(JSON.stringify(undo));
  const canonicalUndo = await pad.waitFor((message) =>
    message.type === "history:undo"
      && message.mode === "whiteboard"
      && message.sourceId === "inkbridge-relay"
      && message.historyRevision > canonicalClear.historyRevision);
  assert.equal(canonicalUndo.historyCursor, initialLength + 1);

  const padObserver = makeClient("pad", "whiteboard-history-pad-observer");
  const padSnapshot = await padObserver.join();
  assert.equal(padSnapshot.historyCursor, initialLength + 1);
  assert.equal(padSnapshot.whiteboardHistoryCursor, initialLength + 1);
  assert.equal(padSnapshot.whiteboardHistoryLength, initialLength + 2);
  assert.equal(padSnapshot.history.some((message) => message.type === "clear"), true);

  const desktopObserver = makeClient("desktop", "whiteboard-history-desktop-observer");
  const desktopSnapshot = await desktopObserver.join();
  assert.equal(desktopSnapshot.whiteboardHistoryCursor, initialLength + 1);
  assert.equal(desktopSnapshot.whiteboardHistoryLength, initialLength + 2);

  const boardObserver = makeClient("board", "whiteboard-history-board-observer");
  const boardSnapshot = await boardObserver.join();
  assert.equal(boardSnapshot.historyCursor, initialLength + 1);
  assert.equal(boardSnapshot.history.every((message) => message.pageIndex == null && message.documentId == null), true);

  const redo = desktop.envelope("history:redo", { mode: "whiteboard" }, true);
  desktop.socket.send(JSON.stringify(redo));
  const canonicalRedo = await pad.waitFor((message) =>
    message.type === "history:redo"
      && message.mode === "whiteboard"
      && message.sourceId === "inkbridge-relay"
      && message.historyRevision > canonicalUndo.historyRevision);
  assert.equal(canonicalRedo.historyCursor, initialLength + 2);

  boardObserver.close();
  desktopObserver.close();
  padObserver.close();
  desktop.close();
  pad.close();
});

test("pure whiteboard history, cursor, and viewport survive a relay process restart", async () => {
  const whiteboardRoom = "WBPERS";
  const pad = makeClient("pad", "pure-whiteboard-pad", whiteboardRoom);
  await pad.join();

  const viewport = pad.envelope("whiteboard:viewport", {
    centerX: -45_678.25,
    centerY: 98_765.5,
    zoom: 6.25,
    viewportWidth: 1280,
    viewportHeight: 800,
    interactionId: "pure-whiteboard-viewport",
    interactionPhase: "end",
  }, true);
  pad.socket.send(JSON.stringify(viewport));
  await pad.waitFor((message) => message.type === "ack" && message.ackMessageId === viewport.messageId);

  const strokeId = "pure-whiteboard-stroke";
  pad.socket.send(JSON.stringify(pad.envelope("stroke:start", {
    mode: "whiteboard",
    strokeId,
    strokeSequence: 0,
    coordinateSpace: "whiteboard-world-v1",
    tool: "ink",
    color: "#2269ef",
    width: 5.5,
    point: { x: -45_700, y: 98_800, p: 0.6 },
  })));
  const end = pad.envelope("stroke:end", {
    mode: "whiteboard",
    strokeId,
    strokeSequence: 1,
    coordinateSpace: "whiteboard-world-v1",
    tool: "ink",
  }, true);
  pad.socket.send(JSON.stringify(end));
  await pad.waitFor((message) => message.type === "ack" && message.ackMessageId === end.messageId);

  const clear = pad.envelope("clear", { mode: "whiteboard" }, true);
  pad.socket.send(JSON.stringify(clear));
  const canonicalClear = await pad.waitFor((message) =>
    message.type === "clear" && message.sourceId === "inkbridge-relay");
  assert.equal(canonicalClear.historyCursor, 2);

  const undo = pad.envelope("history:undo", { mode: "whiteboard" }, true);
  pad.socket.send(JSON.stringify(undo));
  const canonicalUndo = await pad.waitFor((message) =>
    message.type === "history:undo"
      && message.sourceId === "inkbridge-relay"
      && message.historyRevision > canonicalClear.historyRevision);
  assert.equal(canonicalUndo.historyCursor, 1);
  const persistedBeforeRestart = JSON.parse(readFileSync(
    join(dataDirectory, "rooms", `${whiteboardRoom}.json`),
    "utf8",
  ));
  assert.equal(persistedBeforeRestart.whiteboard.historyCursor, 1);
  pad.close();

  await new Promise((resolve) => {
    relay.once("exit", resolve);
    relay.kill("SIGTERM");
  });
  const port = Number(new URL(baseURL).port);
  relay = spawn(process.execPath, ["local-server.mjs"], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(port), INKBRIDGE_DATA_DIR: dataDirectory },
    stdio: ["ignore", "pipe", "pipe"],
  });
  await waitUntilReady(baseURL);

  const recovered = makeClient("pad", "pure-whiteboard-recovered", whiteboardRoom);
  const snapshot = await recovered.join();
  assert.equal(snapshot.document, null);
  assert.equal(snapshot.historyCursor, 1);
  assert.equal(snapshot.historyLength, 2);
  assert.equal(snapshot.whiteboardHistoryCursor, 1);
  assert.equal(snapshot.history.some((message) => message.type === "clear"), true);
  assert.equal(snapshot.history.some((message) => message.strokeId === strokeId), true);
  assert.equal(snapshot.whiteboardViewport.centerX, -45_678.25);
  assert.equal(snapshot.whiteboardViewport.centerY, 98_765.5);
  assert.equal(snapshot.whiteboardViewport.zoom, 6.25);
  recovered.close();
});

test("phase 4 keeps native pen batches idempotent across reconnects", async () => {
  const observer = makeClient("board", "phase4-observer");
  await observer.join();
  const first = makeClient("pad", "phase4-native-pen");
  await first.join();
  const strokeId = "phase4-stroke-1";
  const events = [
    first.envelope("stroke:start", {
      strokeId,
      strokeSequence: 0,
      color: "#152441",
      width: 1.5,
      tool: "ink",
      point: {
        x: 0.1,
        y: 0.2,
        p: 0.25,
        tiltX: 12,
        tiltY: -8,
        timestamp: 100,
        sampleIndex: 0,
      },
    }),
    first.envelope("stroke:move", {
      strokeId,
      strokeSequence: 1,
      tool: "ink",
      points: Array.from({ length: 40 }, (_, index) => ({
        x: 0.1 + index / 100,
        y: 0.2 + index / 200,
        p: 0.25 + index / 100,
        tiltX: 12,
        tiltY: -8,
        timestamp: 101 + index,
        sampleIndex: index + 1,
      })),
    }),
    first.envelope("stroke:end", {
      strokeId,
      strokeSequence: 2,
      tool: "ink",
    }, true),
  ];
  for (const event of events) first.socket.send(JSON.stringify(event));
  await observer.waitFor((message) => message.type === "stroke:end" && message.strokeId === strokeId);
  const deliveredBeforeReplay = observer.messages.filter((message) => message.strokeId === strokeId).length;
  first.close();

  const replay = makeClient("pad", "phase4-native-pen");
  await replay.join();
  const replayEvents = [
    replay.envelope("stroke:start", { ...events[0], messageId: undefined, sequence: undefined }),
    replay.envelope("stroke:move", { ...events[1], messageId: undefined, sequence: undefined }),
    replay.envelope("stroke:end", { ...events[2], messageId: undefined, sequence: undefined }, true),
  ];
  for (const event of replayEvents) replay.socket.send(JSON.stringify(event));
  const duplicateAck = await replay.waitFor((message) => (
    message.type === "ack"
      && message.ackMessageId === replayEvents[2].messageId
  ));
  assert.equal(duplicateAck.status, "duplicate");
  await new Promise((resolve) => setTimeout(resolve, 80));
  assert.equal(
    observer.messages.filter((message) => message.strokeId === strokeId).length,
    deliveredBeforeReplay,
  );
  replay.close();
  observer.close();
});

test("highlighter metadata and straight-line replacement survive the relay snapshot", async () => {
  const pad = makeClient("pad", "highlighter-pad");
  await pad.join();
  const strokeId = "highlighter-straight-1";
  const start = { x: 0.12, y: 0.34, p: 0.5 };
  const end = { x: 0.82, y: 0.37, p: 0.5 };
  const events = [
    pad.envelope("stroke:start", {
      strokeId, strokeSequence: 0, tool: "highlighter",
      color: "#FFE55B", width: 14, opacity: 0.28, point: start,
    }),
    pad.envelope("stroke:move", {
      strokeId, strokeSequence: 1, tool: "highlighter",
      points: [{ x: 0.45, y: 0.52, p: 0.5 }],
    }),
    pad.envelope("stroke:replace", {
      strokeId, strokeSequence: 2, tool: "highlighter",
      color: "#FFE55B", width: 14, opacity: 0.28, points: [start, end],
    }),
    pad.envelope("stroke:end", {
      strokeId, strokeSequence: 3, tool: "highlighter",
    }, true),
  ];
  for (const event of events) pad.socket.send(JSON.stringify(event));
  await pad.waitFor((message) => message.type === "ack" && message.ackMessageId === events[3].messageId);

  const observer = makeClient("board", "highlighter-observer");
  const snapshot = await observer.join();
  const restored = snapshot.history.filter((message) => message.strokeId === strokeId);
  assert.deepEqual(restored.map((message) => message.type), [
    "stroke:start", "stroke:move", "stroke:replace", "stroke:end",
  ]);
  assert.equal(restored[2].tool, "highlighter");
  assert.equal(restored[2].opacity, 0.28);
  assert.deepEqual(restored[2].points, [start, end]);
  observer.close();
  pad.close();
});

test("protocol v2 transfers, verifies, acknowledges, and snapshots a PDF", async () => {
  const desktop = makeClient("desktop", "test-desktop");
  const pad = makeClient("pdfpad", "test-pad");
  await desktop.join();
  await pad.join();

  const pdf = Buffer.from("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n%%EOF\n");
  const expectedHash = createHash("sha256").update(pdf).digest("hex");
  const documentId = "phase1-document";
  const upload = await fetch(`${baseURL}/api/pdf/${room}`, {
    method: "POST",
    headers: {
      "content-type": "application/pdf",
      "x-pdf-name": encodeURIComponent("阶段一.pdf"),
      "x-pdf-id": documentId,
      "x-pdf-version": "11",
      "x-pdf-sha256": expectedHash,
      "x-pdf-transaction-id": "phase1-transaction",
    },
    body: pdf,
  });
  assert.equal(upload.status, 201);
  const descriptor = await upload.json();
  assert.deepEqual(descriptor, {
    name: "阶段一.pdf",
    documentId,
    documentVersion: 11,
    documentHash: expectedHash,
    documentSize: pdf.length,
    transactionId: "phase1-transaction",
    restoreAvailable: false,
  });

  const announced = await pad.waitFor((message) =>
    message.type === "pdf:document" && message.documentId === documentId);
  assert.equal(announced.documentHash, expectedHash);

  const downloaded = await fetch(
    `${baseURL}/api/pdf/${room}?id=${documentId}&version=11&hash=${expectedHash}`,
    { cache: "no-store" },
  );
  assert.equal(downloaded.status, 200);
  assert.equal(downloaded.headers.get("x-pdf-sha256"), expectedHash);
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), pdf);

  const stale = await fetch(`${baseURL}/api/pdf/${room}?id=${documentId}&version=10`);
  assert.equal(stale.status, 409);

  pad.socket.send(JSON.stringify(pad.envelope("pdf:ready", {
    documentId,
    documentVersion: 11,
    documentHash: expectedHash,
    pageCount: 1,
  }, true)));
  const ready = await desktop.waitFor((message) =>
    message.type === "pdf:ready" && message.documentId === documentId);
  assert.equal(ready.pageCount, 1);
  const reconnectedDesktop = makeClient("desktop", "test-desktop-reconnected");
  await reconnectedDesktop.join();
  const replayedReady = await reconnectedDesktop.waitFor((message) =>
    message.type === "pdf:ready" && message.documentId === documentId);
  assert.equal(replayedReady.pageCount, 1);

  desktop.socket.send(JSON.stringify(desktop.envelope("pdf:viewport", {
    documentId,
    documentVersion: 11,
    documentHash: expectedHash,
    pageIndex: 0,
    zoom: 1.25,
    offset: 0.42,
    anchorX: 0.55,
    anchorY: 0.44,
  }, true)));
  const viewport = await pad.waitFor((message) =>
    message.type === "pdf:viewport" && message.zoom === 1.25);
  assert.equal(viewport.documentVersion, 11);

  pad.close();
  const reconnected = makeClient("pdfpad", "test-pad-reconnected");
  const snapshot = await reconnected.join();
  assert.equal(snapshot.document.documentId, documentId);
  assert.equal(snapshot.document.documentHash, expectedHash);
  assert.equal(snapshot.viewport.zoom, 1.25);
  assert.equal(snapshot.viewport.documentVersion, 11);

  reconnected.close();
  reconnectedDesktop.close();
  desktop.close();
});

test("phase 2 keeps the latest valid PDF, restores its viewport, and forwards lifecycle state", async () => {
  const desktop = makeClient("desktop", "phase2-desktop");
  const pad = makeClient("pdfpad", "phase2-pad");
  await desktop.join();
  await pad.join();

  let finalBatchPDF;
  let finalBatchHash;
  for (let index = 0; index < 30; index += 1) {
    const pdf = testPDF(`batch-${index}`);
    const hash = createHash("sha256").update(pdf).digest("hex");
    const response = await uploadPDF(pdf, {
      id: `batch-document-${index}`,
      version: 100 + index,
      transactionId: `batch-transaction-${index}`,
    });
    assert.equal(response.status, 201, `batch upload ${index + 1}/30`);
    const descriptor = await response.json();
    assert.equal(descriptor.documentHash, hash);
    assert.equal(descriptor.transactionId, `batch-transaction-${index}`);
    assert.equal(descriptor.restoreAvailable, false);
    finalBatchPDF = pdf;
    finalBatchHash = hash;
  }

  const lastBatchAnnouncement = await pad.waitFor((message) =>
    message.type === "pdf:document" && message.transactionId === "batch-transaction-29");
  assert.equal(lastBatchAnnouncement.documentHash, finalBatchHash);

  const slowPDF = testPDF("slow-obsolete");
  const slow = await startSlowUpload(slowPDF, {
    id: "slow-obsolete",
    version: 300,
    transactionId: "slow-obsolete-transaction",
    name: "slow-obsolete.pdf",
  });
  const winnerPDF = testPDF("fast-winner");
  const winnerHash = createHash("sha256").update(winnerPDF).digest("hex");
  const winnerResponse = await uploadPDF(winnerPDF, {
    id: "fast-winner",
    version: 301,
    transactionId: "fast-winner-transaction",
  });
  assert.equal(winnerResponse.status, 201);
  const winner = await winnerResponse.json();
  assert.equal(winner.documentHash, winnerHash);
  const obsoleteResponse = await slow.finish();
  assert.equal(obsoleteResponse.status, 409);

  const invalidPDF = testPDF("wrong-hash");
  const invalidResponse = await uploadPDF(invalidPDF, {
    id: "invalid-hash",
    version: 302,
    transactionId: "invalid-hash-transaction",
    hash: "0".repeat(64),
  });
  assert.equal(invalidResponse.status, 422);
  const winnerStillActive = await fetch(
    `${baseURL}/api/pdf/${room}?id=${winner.documentId}&version=${winner.documentVersion}&hash=${winnerHash}`,
  );
  assert.equal(winnerStillActive.status, 200);
  assert.deepEqual(Buffer.from(await winnerStillActive.arrayBuffer()), winnerPDF);

  desktop.socket.send(JSON.stringify(desktop.envelope("pdf:viewport", {
    documentId: winner.documentId,
    documentVersion: winner.documentVersion,
    documentHash: winnerHash,
    pageIndex: 0,
    zoom: 1.72,
    offset: 0.64,
    anchorX: 0.31,
    anchorY: 0.57,
  }, true)));
  await pad.waitFor((message) =>
    message.type === "pdf:viewport"
      && message.documentId === winner.documentId
      && message.zoom === 1.72);

  const interimPDF = finalBatchPDF;
  const interimResponse = await uploadPDF(interimPDF, {
    id: "interim-document",
    version: 303,
    transactionId: "interim-transaction",
  });
  assert.equal(interimResponse.status, 201);

  const reopenResponse = await uploadPDF(winnerPDF, {
    id: "fast-winner",
    version: 304,
    transactionId: "fast-winner-reopen",
  });
  assert.equal(reopenResponse.status, 201);
  const reopened = await reopenResponse.json();
  assert.equal(reopened.documentHash, winnerHash);
  assert.equal(reopened.restoreAvailable, true);
  const restoredViewport = await pad.waitFor((message) =>
    message.type === "pdf:viewport"
      && message.documentVersion === reopened.documentVersion
      && message.zoom === 1.72);
  assert.equal(restoredViewport.offset, 0.64);
  assert.equal(restoredViewport.anchorX, 0.31);
  assert.equal(restoredViewport.anchorY, 0.57);

  pad.socket.send(JSON.stringify(pad.envelope("pdf:progress", {
    documentId: reopened.documentId,
    documentVersion: reopened.documentVersion,
    documentHash: reopened.documentHash,
    transactionId: reopened.transactionId,
    phase: "download",
    loadedBytes: 40,
    totalBytes: 100,
    progress: 0.4,
  })));
  const progress = await desktop.waitFor((message) =>
    message.type === "pdf:progress"
      && message.documentVersion === reopened.documentVersion
      && message.progress === 0.4);
  assert.equal(progress.phase, "download");

  const reload = desktop.envelope("pdf:reload", {
    documentId: reopened.documentId,
    documentVersion: reopened.documentVersion,
    documentHash: reopened.documentHash,
  }, true);
  desktop.socket.send(JSON.stringify(reload));
  const forwardedReload = await pad.waitFor((message) =>
    message.type === "pdf:reload"
      && message.documentVersion === reopened.documentVersion);
  assert.equal(forwardedReload.transactionId, "fast-winner-reopen");
  const reloadAck = await desktop.waitFor((message) =>
    message.type === "ack" && message.ackMessageId === reload.messageId);
  assert.equal(reloadAck.status, "accepted");

  const lateClient = makeClient("pdfpad", "phase2-late-pad");
  const snapshot = await lateClient.join();
  assert.equal(snapshot.document.transactionId, "fast-winner-reopen");
  assert.equal(snapshot.document.documentHash, winnerHash);
  assert.equal(snapshot.document.restoreAvailable, true);
  assert.equal(snapshot.viewport.documentVersion, reopened.documentVersion);
  assert.equal(snapshot.viewport.zoom, 1.72);

  lateClient.close();
  pad.close();
  desktop.close();
});

test("phase 3 grants one viewport controller, rejects stale documents, and snapshots final geometry", async () => {
  const pdf = testPDF("phase-3");
  const hash = createHash("sha256").update(pdf).digest("hex");
  const documentId = `sha256-${hash}`;
  const upload = await uploadPDF(pdf, {
    id: documentId,
    version: 1_300,
    transactionId: "phase3-viewport-document",
    hash,
  });
  assert.equal(upload.status, 201);
  const descriptor = await upload.json();

  const desktop = makeClient("desktop", "phase3-desktop");
  const pad = makeClient("pdfpad", "phase3-pad");
  await desktop.join();
  await pad.join();

  const padBegin = pad.envelope("pdf:viewport", {
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    pageIndex: 2,
    zoom: 2.4,
    offset: 0.42,
    anchorX: 0.27,
    anchorY: 0.61,
    viewportWidth: 1_600,
    viewportHeight: 980,
    interactionId: "pad-gesture-1",
    interactionPhase: "begin",
  }, true);
  pad.socket.send(JSON.stringify(padBegin));
  const forwardedBegin = await desktop.waitFor((message) => message.messageId === padBegin.messageId);
  assert.equal(forwardedBegin.interactionPhase, "begin");
  assert.equal(forwardedBegin.viewportWidth, 1_600);

  const competing = desktop.envelope("pdf:viewport", {
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    pageIndex: 0,
    zoom: 1.1,
    offset: 0,
    anchorX: 0.5,
    anchorY: 0.5,
    viewportWidth: 900,
    viewportHeight: 700,
    interactionId: "desktop-gesture-blocked",
    interactionPhase: "begin",
  }, true);
  desktop.socket.send(JSON.stringify(competing));
  const lockedAck = await desktop.waitFor((message) =>
    message.type === "ack" && message.ackMessageId === competing.messageId);
  assert.equal(lockedAck.status, "viewport-locked");
  await new Promise((resolve) => setTimeout(resolve, 80));
  assert.equal(pad.messages.some((message) => message.messageId === competing.messageId), false);

  const padEnd = pad.envelope("pdf:viewport", {
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    pageIndex: 2,
    zoom: 2.75,
    offset: 0.48,
    anchorX: 0.33,
    anchorY: 0.58,
    viewportWidth: 1_600,
    viewportHeight: 980,
    interactionId: "pad-gesture-1",
    interactionPhase: "end",
  }, true);
  pad.socket.send(JSON.stringify(padEnd));
  const forwardedEnd = await desktop.waitFor((message) => message.messageId === padEnd.messageId);
  assert.equal(forwardedEnd.interactionPhase, "end");
  assert.equal(forwardedEnd.zoom, 2.75);

  const desktopBegin = desktop.envelope("pdf:viewport", {
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    pageIndex: 1,
    zoom: 1.65,
    offset: 0.26,
    anchorX: 0.72,
    anchorY: 0.34,
    viewportWidth: 1_120,
    viewportHeight: 760,
    interactionId: "desktop-gesture-accepted",
    interactionPhase: "begin",
  }, true);
  desktop.socket.send(JSON.stringify(desktopBegin));
  const acceptedDesktop = await pad.waitFor((message) => message.messageId === desktopBegin.messageId);
  assert.equal(acceptedDesktop.anchorX, 0.72);

  const stale = desktop.envelope("pdf:viewport", {
    documentId: "stale-document",
    documentVersion: descriptor.documentVersion - 1,
    documentHash: descriptor.documentHash,
    pageIndex: 0,
    zoom: 1,
    offset: 0,
    anchorX: 0.5,
    anchorY: 0.5,
    viewportWidth: 1_120,
    viewportHeight: 760,
    interactionId: "desktop-stale",
    interactionPhase: "begin",
  }, true);
  desktop.socket.send(JSON.stringify(stale));
  const staleAck = await desktop.waitFor((message) =>
    message.type === "ack" && message.ackMessageId === stale.messageId);
  assert.equal(staleAck.status, "stale-document");

  for (let index = 0; index < 100; index += 1) {
    desktop.socket.send(JSON.stringify(desktop.envelope("pdf:viewport", {
      documentId: descriptor.documentId,
      documentVersion: descriptor.documentVersion,
      documentHash: descriptor.documentHash,
      pageIndex: 1,
      zoom: 1.65 + index / 1_000,
      offset: 0.26 + index / 1_000,
      anchorX: 0.72,
      anchorY: 0.34 + index / 2_000,
      viewportWidth: 1_120,
      viewportHeight: 760,
      interactionId: "desktop-gesture-accepted",
      interactionPhase: "update",
    })));
  }
  const desktopEnd = desktop.envelope("pdf:viewport", {
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    pageIndex: 1,
    zoom: 1.75,
    offset: 0.36,
    anchorX: 0.81,
    anchorY: 0.39,
    viewportWidth: 1_120,
    viewportHeight: 760,
    interactionId: "desktop-gesture-accepted",
    interactionPhase: "end",
  }, true);
  desktop.socket.send(JSON.stringify(desktopEnd));
  const finalViewport = await pad.waitFor((message) => message.messageId === desktopEnd.messageId);
  assert.equal(finalViewport.interactionPhase, "end");
  assert.equal(finalViewport.anchorX, 0.81);

  const lateClient = makeClient("pdfpad", "phase3-late-pad");
  const snapshot = await lateClient.join();
  assert.equal(snapshot.viewport.messageId, desktopEnd.messageId);
  assert.equal(snapshot.viewport.pageIndex, 1);
  assert.equal(snapshot.viewport.anchorX, 0.81);
  assert.equal(snapshot.viewport.interactionPhase, "end");
  assert.equal(snapshot.viewport.viewportWidth, 1_120);

  lateClient.close();
  pad.close();
  desktop.close();
});

test("phase 5 persists complete operations and keeps undo/redo canonical across restart", async () => {
  const pdf = testPDF("phase-5-durable-history");
  const hash = createHash("sha256").update(pdf).digest("hex");
  const upload = await uploadPDF(pdf, {
    id: `sha256-${hash}`,
    version: 1_500,
    transactionId: "phase5-durable-document",
    hash,
  });
  assert.equal(upload.status, 201);
  const descriptor = await upload.json();

  const desktop = makeClient("desktop", "phase5-desktop");
  const pad = makeClient("pdfpad", "phase5-pad");
  await desktop.join();
  await pad.join();

  function strokeEvents(strokeId, x) {
    const scope = {
      documentId: descriptor.documentId,
      documentVersion: descriptor.documentVersion,
      documentHash: descriptor.documentHash,
      pageIndex: 0,
      mode: "pdf",
      strokeId,
      tool: "ink",
    };
    return [
      pad.envelope("stroke:start", {
        ...scope,
        strokeSequence: 0,
        color: "#152441",
        width: 1.5,
        point: { x, y: 0.2, p: 0.3 },
      }),
      pad.envelope("stroke:move", {
        ...scope,
        strokeSequence: 1,
        points: [{ x: x + 0.04, y: 0.24, p: 0.7 }],
      }),
      pad.envelope("stroke:end", {
        ...scope,
        strokeSequence: 2,
      }, true),
    ];
  }

  for (const event of strokeEvents("phase5-stroke-a", 0.1)) {
    pad.socket.send(JSON.stringify(event));
  }
  const firstEnd = await desktop.waitFor((message) =>
    message.type === "stroke:end" && message.strokeId === "phase5-stroke-a");
  assert.equal(firstEnd.historyCursor, 1);
  assert.equal(firstEnd.historyLength, 1);

  for (const event of strokeEvents("phase5-stroke-b", 0.4)) {
    pad.socket.send(JSON.stringify(event));
  }
  const secondEnd = await desktop.waitFor((message) =>
    message.type === "stroke:end" && message.strokeId === "phase5-stroke-b");
  assert.equal(secondEnd.historyCursor, 2);

  const clear = desktop.envelope("clear", {
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    mode: "pdf",
  }, true);
  desktop.socket.send(JSON.stringify(clear));
  const canonicalClear = await desktop.waitFor((message) =>
    message.type === "clear" && message.sourceId === "inkbridge-relay" && message.historyCursor === 3);
  assert.equal(canonicalClear.historyLength, 3);

  let lastHistoryRevision = canonicalClear.historyRevision;
  for (let index = 0; index < 100; index += 1) {
    const type = index % 2 === 0 ? "history:undo" : "history:redo";
    const request = desktop.envelope(type, {
      documentId: descriptor.documentId,
      documentVersion: descriptor.documentVersion,
      documentHash: descriptor.documentHash,
      mode: "pdf",
    }, true);
    desktop.socket.send(JSON.stringify(request));
    const canonical = await pad.waitFor((message) =>
      message.type === type
        && message.sourceId === "inkbridge-relay"
        && message.historyRevision > lastHistoryRevision);
    lastHistoryRevision = canonical.historyRevision;
    assert.equal(canonical.historyCursor, index % 2 === 0 ? 2 : 3);
    assert.equal(canonical.historyLength, 3);
  }

  const finalUndo = desktop.envelope("history:undo", {
    documentId: descriptor.documentId,
    documentVersion: descriptor.documentVersion,
    documentHash: descriptor.documentHash,
    mode: "pdf",
  }, true);
  desktop.socket.send(JSON.stringify(finalUndo));
  const finalHistory = await pad.waitFor((message) =>
    message.type === "history:undo"
      && message.sourceId === "inkbridge-relay"
      && message.historyRevision > lastHistoryRevision);
  assert.equal(finalHistory.historyCursor, 2);

  const beforeRestart = makeClient("pdfpad", "phase5-before-restart");
  const snapshot = await beforeRestart.join();
  assert.equal(snapshot.historyCursor, 2);
  assert.equal(snapshot.historyLength, 3);
  assert.equal(new Set(snapshot.history.map((message) => message.operationId)).size, 3);
  beforeRestart.close();
  desktop.close();
  pad.close();

  await new Promise((resolve) => {
    relay.once("exit", resolve);
    relay.kill("SIGTERM");
  });
  const port = Number(new URL(baseURL).port);
  relay = spawn(process.execPath, ["local-server.mjs"], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(port), INKBRIDGE_DATA_DIR: dataDirectory },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const configuration = await waitUntilReady(baseURL);
  assert.equal(configuration.relayVersion, 16);

  const recovered = makeClient("pdfpad", "phase5-after-restart");
  const recoveredSnapshot = await recovered.join();
  assert.equal(recoveredSnapshot.document.documentHash, hash);
  assert.equal(recoveredSnapshot.document.restoreAvailable, true);
  assert.equal(recoveredSnapshot.historyCursor, 2);
  assert.equal(recoveredSnapshot.historyLength, 3);
  assert.equal(recoveredSnapshot.history.some((message) => message.type === "clear"), true);
  recovered.close();
});


test("shared appearance validates choices and rejects stale writes", async () => {
  const url = `${baseURL}/api/appearance`;
  const initial = await (await fetch(url)).json();
  assert.deepEqual(initial, { preference: "automatic", appearance: "light", revision: 0 });
  const update = (value) => fetch(url, { method: "PUT", body: JSON.stringify(value) });
  const written = await update({ preference: "dark", appearance: "dark", baseRevision: 0 });
  assert.equal(written.status, 200);
  assert.deepEqual(await written.json(), { preference: "dark", appearance: "dark", revision: 1 });
  assert.equal((await update({ preference: "light", appearance: "light", baseRevision: 0 })).status, 409);
  assert.equal((await update({ preference: "light", appearance: "dark", baseRevision: 1 })).status, 422);
  assert.equal((await update({ preference: "invalid", appearance: "dark", baseRevision: 1 })).status, 422);
  assert.equal((await fetch(url, { method: "PUT", body: "{" })).status, 400);
  assert.equal((await (await fetch(url)).json()).preference, "dark");
  assert.equal((await fetch(url, { method: "PUT", body: "x".repeat(2049) })).status, 413);
});

test("appearance persists through a relay restart without needing a PDF", async () => {
  const port = await unusedPort();
  const nextURL = `http://127.0.0.1:${port}`;
  const second = spawn(process.execPath, ["local-server.mjs"], {
    cwd: process.cwd(), env: { ...process.env, PORT: String(port), INKBRIDGE_DATA_DIR: dataDirectory },
    stdio: ["ignore", "pipe", "pipe"]
  });
  try {
    await waitUntilReady(nextURL);
    assert.deepEqual(await (await fetch(`${nextURL}/api/appearance`)).json(), { preference: "dark", appearance: "dark", revision: 1 });
  } finally { second.kill("SIGTERM"); }
});
