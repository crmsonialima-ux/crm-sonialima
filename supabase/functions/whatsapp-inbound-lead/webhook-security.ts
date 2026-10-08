const encoder = new TextEncoder();

function hexToBytes(hex: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[0-9a-f]{64}$/i.test(hex)) return null;
  const bytes = new Uint8Array(new ArrayBuffer(hex.length / 2));
  for (let index = 0; index < hex.length; index += 2) {
    bytes[index / 2] = Number.parseInt(hex.slice(index, index + 2), 16);
  }
  return bytes;
}

/** Validates Meta's `X-Hub-Signature-256` over the untouched request body. */
export async function validateMetaSignature(
  appSecret: string,
  body: ArrayBuffer,
  signatureHeader: string | null,
): Promise<boolean> {
  if (!appSecret || !signatureHeader?.startsWith("sha256=")) return false;
  const signature = hexToBytes(signatureHeader.slice("sha256=".length));
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify("HMAC", key, signature, body);
}

export async function createMetaSignatureForTest(
  appSecret: string,
  body: ArrayBuffer,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  return `sha256=${Array.from(signature, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}
