import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { createConnection } from 'node:net';

const header = Buffer.from([0x4c, 0x44, 0x4d, 0x57, 0, 0, 0xbb, 0x80, 0, 0, 0, 1, 0, 0, 0, 1]);
const maxPCM = 1920;
const leaseMilliseconds = 2400;

export function createWirelessMicRelay(pairingKey, controlPort = 24834, audioPort = 24835) {
  const key = /^[a-f0-9]{64}$/.test(pairingKey ?? '') ? Buffer.from(pairingKey, 'hex') : null;
  let owner = null;
  let turningOff = false;

  function control(command) {
    return new Promise((resolve) => {
      const socket = createConnection({ host: '127.0.0.1', port: controlPort }, () => socket.write(command));
      let result = '';
      socket.setTimeout(800, () => socket.destroy());
      socket.on('data', (data) => { result = data.toString(); socket.destroy(); });
      socket.on('error', () => {});
      socket.on('close', () => resolve(result));
    });
  }

  return function accept(peer, wired = false) {
    if (!key) { peer.close(1008); return null; }
    const challenge = randomBytes(24).toString('hex');
    const inbound = Buffer.from(`LDWM1:${challenge}:tablet`);
    const outbound = Buffer.from(`LDWM1:${challenge}:mac`);
    let sequence = 0;
    let audio;
    let active = false;
    let closed = false;
    let timer;
    function refreshLease() {
      clearTimeout(timer);
      timer = setTimeout(() => close(), leaseMilliseconds);
      timer.unref();
    }
    function close() {
      if (closed) return;
      closed = true;
      clearTimeout(timer);
      audio?.destroy();
      peer.close();
      if (owner === close) {
        owner = null;
        turningOff = true;
        // Wait for a pending ON, so the final command always releases the input.
        activated.then(() => control('LDWMOFF1')).finally(() => { turningOff = false; });
      }
    }
    let activated = Promise.resolve('');
    function reply(text) {
      const nonce = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', key, nonce);
      cipher.setAAD(outbound);
      const encoded = Buffer.concat([nonce, cipher.update(text, 'utf8'), cipher.final(), cipher.getAuthTag()]);
      peer.send(JSON.stringify({ proof: encoded.toString('base64') }));
    }
    function openAudio() {
      if (closed || owner || turningOff) return close();
      owner = close;
      activated = control(wired ? 'LDWMUSB1' : 'LDWMON01');
      activated.then(result => {
        if (closed || result !== '1') return close();
        audio = createConnection({ host: '127.0.0.1', port: audioPort }, () => audio.write(header));
        audio.setNoDelay(true);
        audio.on('error', close);
        audio.on('close', close);
        audio.once('data', data => {
          if (data.length !== 1 || data[0] !== 1) return close();
          active = true;
          refreshLease();
          reply('ready');
        });
      });
    }
    function message(raw) {
      if (closed || raw.length > 3000) return close();
      try {
        const packet = Buffer.from(raw, 'base64');
        if (packet.length < 32 || packet.length > maxPCM + 32) return close();
        const decipher = createDecipheriv('aes-256-gcm', key, packet.subarray(0, 12));
        decipher.setAAD(inbound);
        decipher.setAuthTag(packet.subarray(-16));
        const decoded = Buffer.concat([decipher.update(packet.subarray(12, -16)), decipher.final()]);
        if (decoded.length < 4 || decoded.readUInt32BE(0) !== sequence++) return close();
        const pcm = decoded.subarray(4);
        if (sequence === 1) {
          if (pcm.length) return close();
          openAudio();
          return;
        }
        if (!active || pcm.length > maxPCM || pcm.length % 2 || audio.writableLength > 12 * 1024) return close();
        refreshLease();
        const length = Buffer.alloc(4);
        length.writeUInt32BE(pcm.length);
        audio.write(Buffer.concat([length, pcm]));
      } catch (_) { close(); }
    }
    refreshLease();
    peer.send(JSON.stringify({ challenge }));
    return { message, close };
  };
}
