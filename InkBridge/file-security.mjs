import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto";
import { readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const packetOverhead = 28;
const trustedRoom = /^[A-Z0-9]{6}$/;
const secretPattern = /^[a-f0-9]{64}$/;
const invitationLifetime = 120_000;
const proofWindow = 120_000;
const maxRememberedProofs = 2048;

export function sealPacket(key, context, bytes) {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(Buffer.from(context));
  return Buffer.concat([nonce, cipher.update(bytes), cipher.final(), cipher.getAuthTag()]);
}

export function openPacket(key, context, packet) {
  if (packet.length < packetOverhead) throw new Error("invalid-packet");
  const decipher = createDecipheriv("aes-256-gcm", key, packet.subarray(0, 12));
  decipher.setAAD(Buffer.from(context));
  decipher.setAuthTag(packet.subarray(-16));
  return Buffer.concat([decipher.update(packet.subarray(12, -16)), decipher.final()]);
}

async function readBounded(request, maximum) {
  const length = Number(request.headers["content-length"]);
  if (length > maximum) throw new Error("file-too-large");
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maximum) throw new Error("file-too-large");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size);
}

const headers = { "cache-control": "no-store" };
function replyJSON(response, status, value) {
  response.writeHead(status, { ...headers, "content-type": "application/json" });
  response.end(JSON.stringify(value));
}

export function createFileSecurity(directory, room, keyboardKey) {
  const trustPath = join(directory, "trusted-file-tablet.json");
  let peer;
  try {
    const saved = JSON.parse(readFileSync(trustPath, "utf8"));
    if (saved.room === room && secretPattern.test(saved.key)) peer = Buffer.from(saved.key, "hex");
  } catch { /* The user has not paired a tablet yet. */ }
  let invitation;
  const nonces = new Map();

  function privateRequest(request, response, path) {
    if (path === "/file-pairing/device" && request.method === "GET") {
      replyJSON(response, 200, { paired: !!peer });
      return true;
    }
    if (path === "/file-pairing/device" && request.method === "DELETE") {
      try {
        rmSync(trustPath, { force: true });
        peer = undefined;
        invitation = undefined;
        nonces.clear();
        response.writeHead(204, headers).end();
      } catch {
        replyJSON(response, 500, { error: "could-not-forget-device" });
      }
      return true;
    }
    if (path === "/file-pairing/invite" && request.method === "POST") {
      invitation = { id: randomUUID(), key: randomBytes(32), expires: Date.now() + invitationLifetime };
      replyJSON(response, 201, { id: invitation.id, secret: invitation.key.toString("hex") });
      return true;
    }
    if (request.method === "DELETE" && path.startsWith("/file-pairing/invite/")) {
      if (invitation && path.endsWith("/" + invitation.id)) invitation = undefined;
      response.writeHead(204, headers).end();
      return true;
    }
    return false;
  }

  async function claim(request, response, url) {
    if (url.pathname !== "/api/file-pairing") return false;
    const candidate = invitation;
    if (request.method !== "POST" || !candidate || Date.now() >= candidate.expires) {
      request.resume();
      replyJSON(response, 403, { error: "invitation-unavailable" });
      return true;
    }
    try {
      const input = JSON.parse(await readBounded(request, 2048));
      if (candidate !== invitation || Date.now() >= candidate.expires ||
          input.id !== candidate.id || input.room !== room ||
          typeof input.proof !== "string" || input.proof.length > 512) throw new Error("invalid-invitation");
      const context = `LinkDesk/Pair/1\n${room}\n${candidate.id}`;
      const packet = Buffer.from(input.proof, "base64");
      const proof = JSON.parse(openPacket(candidate.key, context + "\nclaim", packet));
      if (!secretPattern.test(proof.key)) throw new Error("invalid-device");
      if (candidate.reply) {
        // Only the same ciphertext can retry after an acknowledgement is lost.
        if (input.proof !== candidate.proof) throw new Error("invitation-already-used");
        replyJSON(response, 200, { proof: candidate.reply });
        return true;
      }
      const value = JSON.stringify({ room, key: proof.key });
      writeFileSync(trustPath + ".tmp", value, { mode: 0o600 });
      renameSync(trustPath + ".tmp", trustPath);
      peer = Buffer.from(proof.key, "hex");
      nonces.clear();
      candidate.proof = input.proof;
      candidate.reply = sealPacket(candidate.key, context + "\naccepted",
        Buffer.from(JSON.stringify({ keyboardKey: secretPattern.test(keyboardKey ?? "") ? keyboardKey : "" }))).toString("base64");
      replyJSON(response, 200, { proof: candidate.reply });
    } catch {
      if (!response.destroyed) replyJSON(response, 403, { error: "invitation-rejected" });
    }
    return true;
  }

  function authenticate(request, path, requestedRoom) {
    const key = peer;
    const value = request.headers["x-linkdesk-file-proof"];
    if (!trustedRoom.test(room) || requestedRoom !== room || !key ||
        typeof value !== "string" || value.length > 1536) return undefined;
    try {
      const context = `LinkDesk/File/1\n${request.method}\n${path}`;
      const packet = Buffer.from(value, "base64");
      const metadata = JSON.parse(openPacket(key, context + "\nrequest", packet));
      const nonce = packet.subarray(0, 12).toString("hex");
      const now = Date.now();
      if (!Number.isSafeInteger(metadata.time) || Math.abs(now - metadata.time) > proofWindow ||
          nonces.has(nonce)) return undefined;
      for (const [pastNonce, expires] of nonces) {
        if (expires < now) nonces.delete(pastNonce);
      }
      if (nonces.size >= maxRememberedProofs) return undefined;
      nonces.set(nonce, metadata.time + proofWindow);
      return {
        metadata,
        current: () => key === peer,
        async read(maximum) {
          try {
            return openPacket(key, context + "\ncontent", await readBounded(request, maximum + packetOverhead));
          } catch (error) {
            if (error.message === "file-too-large") throw error;
            throw new Error("invalid-content");
          }
        },
        send(response, status, data) {
          const bytes = sealPacket(key, context + `\nresponse\n${nonce}\n${status}`, data);
          response.writeHead(status, { ...headers, "content-type": "application/octet-stream", "content-length": bytes.length });
          response.end(bytes);
        },
      };
    } catch { return undefined; }
  }

  return { privateRequest, claim, authenticate };
}
