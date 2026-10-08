import { handler } from "./index.ts";
import { createMetaSignatureForTest } from "./webhook-security.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) {
    throw new Error(`Expected ${String(expected)}, received ${String(actual)}`);
  }
}

async function withEnvironment(
  values: Record<string, string>,
  callback: () => Promise<void>,
): Promise<void> {
  const previous = new Map<string, string | undefined>();
  for (const [name, value] of Object.entries(values)) {
    previous.set(name, Deno.env.get(name));
    Deno.env.set(name, value);
  }
  try {
    await callback();
  } finally {
    for (const [name, value] of previous) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
}

Deno.test("answers Meta's webhook verification challenge", async () => {
  await withEnvironment({ WHATSAPP_WEBHOOK_VERIFY_TOKEN: "verify-me" }, async () => {
    const valid = await handler(
      new Request(
        "https://example.supabase.co/functions/v1/whatsapp-inbound-lead" +
          "?hub.mode=subscribe&hub.verify_token=verify-me&hub.challenge=123456",
      ),
    );
    assertEquals(valid.status, 200);
    assertEquals(await valid.text(), "123456");

    const invalid = await handler(
      new Request(
        "https://example.supabase.co/functions/v1/whatsapp-inbound-lead" +
          "?hub.mode=subscribe&hub.verify_token=wrong&hub.challenge=123456",
      ),
    );
    assertEquals(invalid.status, 403);
  });
});

Deno.test("accepts a signed status-only webhook without creating a lead", async () => {
  await withEnvironment({ WHATSAPP_APP_SECRET: "meta-app-secret" }, async () => {
    const body = JSON.stringify({
      object: "whatsapp_business_account",
      entry: [
        {
          id: "waba-1",
          changes: [
            {
              field: "messages",
              value: {
                messaging_product: "whatsapp",
                statuses: [{ id: "wamid.status", status: "delivered" }],
              },
            },
          ],
        },
      ],
    });
    const encoded = new TextEncoder().encode(body);
    const signature = await createMetaSignatureForTest("meta-app-secret", encoded.buffer);
    const response = await handler(
      new Request("https://example.supabase.co/functions/v1/whatsapp-inbound-lead", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-hub-signature-256": signature,
        },
        body,
      }),
    );
    assertEquals(response.status, 200);
    const result = await response.json();
    assertEquals(result.received, true);
    assertEquals(result.processed, 0);
  });
});

Deno.test("rejects a webhook with an invalid Meta signature", async () => {
  await withEnvironment({ WHATSAPP_APP_SECRET: "meta-app-secret" }, async () => {
    const response = await handler(
      new Request("https://example.supabase.co/functions/v1/whatsapp-inbound-lead", {
        method: "POST",
        headers: { "x-hub-signature-256": `sha256=${"0".repeat(64)}` },
        body: '{"object":"whatsapp_business_account"}',
      }),
    );
    assertEquals(response.status, 401);
  });
});
