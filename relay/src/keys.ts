const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";
const ROOM_PATTERN = /^[a-z2-7]{32}$/;
const encoder = new TextEncoder();

export function isRoom(value: string): boolean {
  return ROOM_PATTERN.test(value);
}

/** RFC 4648 base32, lowercase, no padding. */
export function base32(bytes: Uint8Array): string {
  let out = "";
  let value = 0;
  let bits = 0;
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out += BASE32_ALPHABET[(value >>> bits) & 31];
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) out += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

export function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64Url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  try {
    const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(binary, (char) => char.charCodeAt(0));
  } catch {
    return null;
  }
}

export async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

/** The room of a Mac relay key: base32 of the first 20 bytes of SHA-256(public key). */
export async function roomForKey(publicKey: Uint8Array): Promise<string> {
  return base32((await sha256(publicKey)).subarray(0, 20));
}

export async function verifyEd25519(publicKey: Uint8Array, signature: Uint8Array, message: Uint8Array): Promise<boolean> {
  if (publicKey.length !== 32 || signature.length !== 64) return false;
  try {
    const verifier = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, verifier, signature, message);
  } catch {
    return false;
  }
}

export function hostChallengeMessage(room: string, nonce: string): Uint8Array {
  return encoder.encode(`yardlet-relay-host/1\n${room}\n${nonce}`);
}

/** Checks that `key` owns `room` and signed the challenge `nonce`. */
export async function verifyHostAuth(room: string, nonce: string, key: string, sig: string): Promise<boolean> {
  const publicKey = fromBase64Url(key);
  const signature = fromBase64Url(sig);
  if (publicKey?.length !== 32 || signature?.length !== 64) return false;
  if ((await roomForKey(publicKey)) !== room) return false;
  return verifyEd25519(publicKey, signature, hostChallengeMessage(room, nonce));
}
