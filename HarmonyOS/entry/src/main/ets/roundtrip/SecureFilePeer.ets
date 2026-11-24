import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';

interface FilePeer {
  room: string;
  key: string;
}

interface PairingReply {
  proof: string;
}

interface PairingAccess {
  keyboardKey: string;
}

class RequestMetadata {
  time: number = Date.now();
  name?: string;
  annotationID?: string;
}

const PACKET_OVERHEAD: number = 28;
const FILE_LIMIT: number = 64 * 1024 * 1024;
const PEER_KEY: string = 'trustedFilePeerV1';

export class SecureFilePeer {
  private static encoder: util.TextEncoder = new util.TextEncoder();
  private static base64: util.Base64Helper = new util.Base64Helper();

  private static store(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: 'ink_bridge_connection' });
  }

  private static hex(bytes: Uint8Array): string {
    return Array.from(bytes).map((byte: number) => byte.toString(16).padStart(2, '0')).join('');
  }

  private static async key(value: string): Promise<cryptoFramework.SymKey> {
    if (!/^[a-f0-9]{64}$/.test(value)) throw new Error('invalid-pairing-key');
    const bytes = new Uint8Array(32);
    for (let index = 0; index < bytes.length; index++) {
      bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
    }
    return cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: bytes });
  }

  private static async seal(key: cryptoFramework.SymKey, label: string, input: Uint8Array): Promise<Uint8Array> {
    const nonce = cryptoFramework.createRandom().generateRandomSync(12).data;
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec', iv: { data: nonce }, aad: { data: SecureFilePeer.encoder.encodeInto(label) },
      authTag: { data: new Uint8Array(16) }
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
    const encrypted = await cipher.doFinal({ data: input });
    const packet = new Uint8Array(nonce.length + encrypted.data.length);
    packet.set(nonce);
    packet.set(encrypted.data, nonce.length);
    return packet;
  }

  private static async open(key: cryptoFramework.SymKey, label: string, packet: Uint8Array): Promise<Uint8Array> {
    if (packet.length < PACKET_OVERHEAD) throw new Error('invalid-secure-packet');
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec', iv: { data: packet.slice(0, 12) }, aad: { data: SecureFilePeer.encoder.encodeInto(label) },
      authTag: { data: packet.slice(-16) }
    };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
    return (await cipher.doFinal({ data: packet.subarray(12, -16) })).data;
  }

  static async pair(context: common.Context, host: string, room: string, id: string, secret: string): Promise<string> {
    const key = await SecureFilePeer.key(secret);
    const deviceKey = SecureFilePeer.hex(cryptoFramework.createRandom().generateRandomSync(32).data);
    const label = `LinkDesk/Pair/1\n${room}\n${id}`;
    const claim = await SecureFilePeer.seal(key, label + '\nclaim',
      SecureFilePeer.encoder.encodeInto(JSON.stringify({ key: deviceKey })));
    const data = JSON.stringify({ id: id, room: room, proof: SecureFilePeer.base64.encodeToStringSync(claim) });
    const address = host.includes(':') ? '[' + host + ']' : host;
    const client = http.createHttp();
    try {
      const result = await client.request(`http://${address}:3210/api/file-pairing`, {
        method: http.RequestMethod.POST, header: { 'Content-Type': 'application/json' },
        extraData: data, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 2500, readTimeout: 3500, maxLimit: 4096, usingCache: false
      });
      if (result.responseCode !== 200 || typeof result.result !== 'string') throw new Error('pairing-rejected');
      const response = JSON.parse(result.result) as PairingReply;
      const plain = await SecureFilePeer.open(key, label + '\naccepted', SecureFilePeer.base64.decodeSync(response.proof));
      const access = JSON.parse(new util.TextDecoder().decodeWithStream(plain)) as PairingAccess;
      const store = SecureFilePeer.store(context);
      store.putSync(PEER_KEY, JSON.stringify({ room: room, key: deviceKey }));
      store.flushSync();
      return access.keyboardKey;
    } finally { client.destroy(); }
  }

  static hasPairing(context: common.Context, room: string): boolean {
    return !!SecureFilePeer.peer(context, room);
  }

  private static peer(context: common.Context, room: string): FilePeer | undefined {
    try {
      const saved = JSON.parse(SecureFilePeer.store(context).getSync(PEER_KEY, '{}') as string) as FilePeer;
      if (saved.room === room && /^[a-f0-9]{64}$/.test(saved.key)) return saved;
    } catch (_) {}
    return undefined;
  }

  static async request(client: http.HttpRequest, origin: string, path: string, room: string,
    options: http.HttpRequestOptions, context: common.Context, name?: string, annotationID?: string): Promise<http.HttpResponse> {
    const peer = SecureFilePeer.peer(context, room);
    if (!peer) throw new Error('secure-pairing-required');
    const key = await SecureFilePeer.key(peer.key);
    const method = options.method ?? http.RequestMethod.GET;
    const label = `LinkDesk/File/1\n${method}\n${path}`;
    const metadata = new RequestMetadata();
    metadata.name = name;
    metadata.annotationID = annotationID;
    const proof = await SecureFilePeer.seal(key, label + '\nrequest',
      SecureFilePeer.encoder.encodeInto(JSON.stringify(metadata)));
    const nonce = SecureFilePeer.hex(proof.subarray(0, 12));
    const headers: Record<string, string> = { 'Content-Type': 'application/octet-stream',
      'X-LinkDesk-File-Proof': SecureFilePeer.base64.encodeToStringSync(proof) };
    const content = options.extraData instanceof ArrayBuffer ?
      (await SecureFilePeer.seal(key, label + '\ncontent', new Uint8Array(options.extraData))).buffer : undefined;
    const response = await client.request(origin + path, {
      method: method, header: headers, extraData: content, expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: options.connectTimeout, readTimeout: options.readTimeout,
      maxLimit: (options.maxLimit ?? 128 * 1024) + PACKET_OVERHEAD, usingCache: false
    });
    if (response.responseCode === 401) return response;
    if (!(response.result instanceof ArrayBuffer) || response.result.byteLength > FILE_LIMIT + PACKET_OVERHEAD) {
      throw new Error('invalid-secure-response');
    }
    const plaintext = await SecureFilePeer.open(key, label + `\nresponse\n${nonce}\n${response.responseCode}`,
      new Uint8Array(response.result));
    response.result = options.expectDataType === http.HttpDataType.ARRAY_BUFFER ?
      plaintext.buffer : new util.TextDecoder().decodeWithStream(plaintext);
    return response;
  }
}
