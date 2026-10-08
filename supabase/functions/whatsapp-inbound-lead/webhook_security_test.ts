import { createMetaSignatureForTest, validateMetaSignature } from "./webhook-security.ts";

function assert(condition: unknown, message = "Assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("validates Meta SHA-256 HMAC against the untouched body", async () => {
  const secret = "test-app-secret";
  const body = new TextEncoder().encode('{"object":"whatsapp_business_account"}').buffer;
  const signature = await createMetaSignatureForTest(secret, body);
  assert(await validateMetaSignature(secret, body, signature));
  const replacement = signature.endsWith("0") ? "1" : "0";
  assert(!(await validateMetaSignature(secret, body, signature.slice(0, -1) + replacement)));
  assert(!(await validateMetaSignature("wrong-secret", body, signature)));
  assert(!(await validateMetaSignature(secret, body, null)));
});

Deno.test("rejects malformed signature headers", async () => {
  const body = new TextEncoder().encode("{}").buffer;
  assert(!(await validateMetaSignature("secret", body, "sha256=abc")));
  assert(!(await validateMetaSignature("secret", body, "sha1=" + "0".repeat(40))));
});
