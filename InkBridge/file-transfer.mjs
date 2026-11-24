import { createHash } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

const maxBytes = 64 * 1024 * 1024;
const maxPending = 24;
const transferId = "[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}";
const route = new RegExp(`^/api/files/([A-Z0-9]{6})/(mac|tablet)(?:/(${transferId}))?$`);
const validId = new RegExp(`^${transferId}$`);
const isLocal = (address) => ["::1", "::ffff:127.0.0.1", "127.0.0.1"].includes(address);
const json = (response, status, value) => {
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify(value));
};

function filename(value) {
  const name = decodeURIComponent(value ?? "").replace(/[\\/\u0000-\u001f\u007f]/g, "_").trim();
  if (!name || name === "." || name === ".." || new TextEncoder().encode(name).length > 200) {
    throw new Error("invalid-name");
  }
  return name;
}

export function createFileTransfer(root, hasRoom, security) {
  const uploads = new Set();
  const secureDownloads = new Set();
  return async function handle(request, response, url) {
    const match = route.exec(url.pathname);
    if (!match) return false;
    const [, room, destination, id] = match;
    const method = request.method;
    const fromMac = method === "PUT" ? destination === "tablet" : destination === "mac";
    const local = isLocal(request.socket.remoteAddress);
    const wantsSecure = request.headers["x-linkdesk-file-proof"] !== undefined;
    const channel = !fromMac && wantsSecure ? security.authenticate(request, url.pathname, room) : undefined;
    const finish = (status, value) => {
      if (channel) channel.send(response, status, Buffer.from(JSON.stringify(value)));
      else json(response, status, value);
      return true;
    };
    const error = (status, reason) => finish(status, { error: reason });
    if ((!local || wantsSecure) && !channel) {
      request.resume();
      return error(401, "secure-pairing-required");
    }
    if ((!channel && request.headers.origin) || !hasRoom(room)) {
      request.resume();
      return error(404, "pairing-not-available");
    }
    const directory = join(root, room, destination);
    const recordPath = id && join(directory, id + ".json");
    const dataPath = id && join(directory, id + ".file");
    const existing = async () => {
      try { return JSON.parse(await readFile(recordPath, "utf8")); } catch { return null; }
    };
    const records = async () => {
      const files = await readdir(directory).catch((e) => {
        if (e.code === "ENOENT") return [];
        throw e;
      });
      return files.filter((name) => name.endsWith(".json") && validId.test(name.slice(0, -5)));
    };
    try {
      if (method === "GET" && !id) {
        const all = await Promise.all((await records()).map(async (name) => {
          try { return JSON.parse(await readFile(join(directory, name), "utf8")); }
          catch { return null; }
        }));
        return finish(200, all.filter((item) => item && !item.received).sort((a, b) => a.createdAt - b.createdAt));
      }
      if (method === "GET" && id) {
        const item = await existing();
        if (!item || item.received) return error(404, "file-not-available");
        if (channel) {
          if (secureDownloads.has(room)) return error(409, "download-in-progress");
          secureDownloads.add(room);
          response.once("close", () => secureDownloads.delete(room));
          const data = await readFile(dataPath);
          if (response.destroyed) return true;
          if (!channel.current()) return error(401, "secure-pairing-required");
          channel.send(response, 200, data);
          return true;
        }
        response.writeHead(200, { "content-type": "application/octet-stream", "content-length": item.size,
          "cache-control": "no-store" });
        const stream = createReadStream(dataPath);
        stream.on("error", () => response.destroy());
        response.on("close", () => stream.destroy());
        stream.pipe(response);
        return true;
      }
      if (method === "DELETE" && id) {
        const item = await existing();
        if (item && !item.received) {
          if (channel && !channel.current()) return error(401, "secure-pairing-required");
          await writeFile(recordPath + ".ack", JSON.stringify({ ...item, received: true }), { mode: 0o600 });
          await rename(recordPath + ".ack", recordPath);
          await rm(dataPath, { force: true });
        }
        return finish(200, {});
      }
      if (method !== "PUT" || !id) return error(405, "method-not-allowed");
      const lock = `${room}/${destination}`;
      if (uploads.has(lock)) { request.resume(); return error(409, "upload-in-progress"); }
      uploads.add(lock);
      try {
        const previous = await existing();
        if (previous) { request.resume(); return finish(200, previous); }
        let name;
        try { name = filename(channel ? channel.metadata.name : request.headers["x-file-name"]); }
        catch { request.resume(); return error(422, "invalid-name"); }
        const length = Number(request.headers["content-length"]);
        if (!channel && Number.isFinite(length) && length > maxBytes) {
          request.resume();
          return error(413, "file-too-large");
        }
        if ((await records()).length >= maxPending) {
          const all = await Promise.all((await records()).map(async (record) => {
            const path = join(directory, record);
            const item = JSON.parse(await readFile(path, "utf8"));
            return { path, item };
          }));
          const receipts = all.filter(({ item }) => item.received).sort((a, b) => a.item.createdAt - b.item.createdAt);
          if (!receipts.length) { request.resume(); return error(429, "inbox-full"); }
          await rm(receipts[0].path, { force: true });
        }
        const purpose = request.headers["x-file-purpose"];
        const requested = channel ? channel.metadata.annotationID : request.headers["x-annotation-id"];
        const annotationID = destination === "tablet" && purpose === "annotate" && /\.pdf$/i.test(name) ? id :
          (destination === "mac" && typeof requested === "string" && validId.test(requested) ? requested : null);
        await mkdir(directory, { recursive: true, mode: 0o700 });
        const hash = createHash("sha256");
        let size = 0;
        const counter = new Transform({
          transform(chunk, _, callback) {
            size += chunk.length;
            if (size > maxBytes) { callback(new Error("file-too-large")); return; }
            hash.update(chunk);
            callback(null, chunk);
          },
        });
        const temp = dataPath + ".part";
        try {
          if (channel) {
            const bytes = await channel.read(maxBytes);
            await pipeline(Readable.from([bytes]), counter, createWriteStream(temp, { mode: 0o600 }));
            if (!channel.current()) return error(401, "secure-pairing-required");
          } else {
            // Keep the request separate so a failed upload can still report an error.
            request.on("error", (cause) => counter.destroy(cause));
            request.on("aborted", () => counter.destroy(new Error("upload-interrupted")));
            request.pipe(counter);
            await pipeline(counter, createWriteStream(temp, { mode: 0o600 }));
            if (Number.isFinite(length) && size !== length) throw new Error("size-mismatch");
          }
          const item = { id, name, size, sha256: hash.digest("hex"), annotationID,
            transport: local && destination === "mac" ? "USB" :
              (destination === "mac" ? "Wi‑Fi" : null), createdAt: Date.now() };
          await rename(temp, dataPath);
          await writeFile(recordPath + ".part", JSON.stringify(item), { mode: 0o600 });
          await rename(recordPath + ".part", recordPath);
          return finish(201, item);
        } finally {
          await rm(temp, { force: true });
        }
      } finally {
        uploads.delete(lock);
      }
    } catch (cause) {
      request.resume();
      if (response.destroyed || response.headersSent) return true;
      if (cause.message === "file-too-large") return error(413, "file-too-large");
      if (cause.message === "invalid-content") return error(422, "invalid-content");
      return error(500, "transfer-failed");
    }
  };
}
