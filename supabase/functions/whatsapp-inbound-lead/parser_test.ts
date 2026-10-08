import {
  analyzePortalReference,
  extractInboundWhatsAppMessages,
  parsePortalReference,
} from "./parser.ts";

function assert(condition: unknown, message = "Assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
  const actualJson = JSON.stringify(actual);
  const expectedJson = JSON.stringify(expected);
  if (actualJson !== expectedJson) {
    throw new Error(`Expected ${expectedJson}, received ${actualJson}`);
  }
}

Deno.test("ignores normal messages and unrelated numbers", () => {
  assertEquals(parsePortalReference("Bom dia"), null);
  assertEquals(parsePortalReference("Meu telefone é 61999999999"), null);
  assertEquals(parsePortalReference("Código 1377664"), null);
  assertEquals(
    parsePortalReference("Veja https://example.com/imovel-3041676384.html?n_pg=1"),
    null,
  );
});

Deno.test("extracts a DF Imóveis explicit code", () => {
  assertEquals(
    parsePortalReference(
      "DF IMÓVEIS: Gostaria de maiores informações sobre este imóvel (Código 1377664).",
    ),
    {
      portal: "dfimoveis",
      origin: "DF Imóveis",
      externalCode: "1377664",
      matchedBy: "explicit_code",
    },
  );
});

Deno.test("extracts a DF Imóveis code from official short and property URLs", () => {
  assertEquals(parsePortalReference("https://www.dfimoveis.com.br/g/1397552?origem=whatsapp"), {
    portal: "dfimoveis",
    origin: "DF Imóveis",
    externalCode: "1397552",
    matchedBy: "portal_url",
  });
  assertEquals(
    parsePortalReference(
      "http://dfimoveis.com.br/imovel/casa-condominio-4-quartos-venda-park-way-brasilia-df-smpw-quadra-15-1375890",
    )?.externalCode,
    "1375890",
  );
});

Deno.test("extracts only the final Imovelweb pathname identifier", () => {
  const text =
    "Olá! Quero ser contatado sobre este imóvel que encontrei no imovelweb. " +
    "https://www.imovelweb.com.br/propriedades/cobertura-exclusiva-na-quadra-300-do-sudoeste-alto-3041676384.html" +
    "?n_src=Listado&n_pg=1&n_pos=1&n_search_id=23bfdca6-30ff-4d1c-974f-ff716793da8f";
  assertEquals(parsePortalReference(text), {
    portal: "wimoveis",
    origin: "W Imóveis",
    externalCode: "3041676384",
    matchedBy: "portal_url",
  });
});

Deno.test("the W/Imovelweb parser does not depend on the listing slug", () => {
  const first = parsePortalReference(
    "https://www.imovelweb.com.br/propriedades/apartamento-aguas-claras-3041676384.html",
  );
  const second = parsePortalReference(
    "https://www.imovelweb.com.br/propriedades/slug-totalmente-diferente-3041676384.html?n_pg=999",
  );
  assertEquals(first?.externalCode, "3041676384");
  assertEquals(second?.externalCode, "3041676384");
});

Deno.test("supports Markdown-formatted Imovelweb links", () => {
  const url = "https://www.imovelweb.com.br/propriedades/imovel-3041676384.html?n_pg=1";
  assertEquals(parsePortalReference(`[${url}](${url})`)?.externalCode, "3041676384");
});

Deno.test("rejects query-only codes and deceptive domains", () => {
  assertEquals(parsePortalReference("https://www.imovelweb.com.br/busca?n_pos=3041676384"), null);
  assertEquals(
    parsePortalReference("https://imovelweb.com.br.evil.example/propriedades/a-3041676384.html"),
    null,
  );
});

Deno.test("marks conflicting recognized property codes as ambiguous", () => {
  assertEquals(
    analyzePortalReference("DF IMÓVEIS (Código 1377664) https://www.dfimoveis.com.br/g/9999999"),
    {
      status: "ambiguous",
      reason: "conflicting_portal_property_codes",
      reference: null,
    },
  );
  assertEquals(analyzePortalReference("Bom dia").status, "ignored");
});

Deno.test("extracts inbound Cloud API text fields and skips statuses", () => {
  const payload = {
    object: "whatsapp_business_account",
    entry: [
      {
        id: "waba-1",
        changes: [
          {
            field: "messages",
            value: {
              messaging_product: "whatsapp",
              metadata: { phone_number_id: "phone-number-1" },
              contacts: [
                {
                  wa_id: "5561999999999",
                  profile: { name: "Cliente Teste" },
                },
              ],
              messages: [
                {
                  from: "+55 (61) 99999-9999",
                  id: "wamid.test-1",
                  timestamp: "1785931200",
                  type: "text",
                  text: {
                    body: "DF IMÓVEIS: informações do imóvel (Código 1377664).",
                  },
                },
              ],
              statuses: [{ id: "wamid.delivery", status: "delivered" }],
            },
          },
        ],
      },
    ],
  };

  const messages = extractInboundWhatsAppMessages(payload, "phone-number-1");
  assertEquals(messages.length, 1);
  assertEquals(messages[0].messageId, "wamid.test-1");
  assertEquals(messages[0].phone, "5561999999999");
  assertEquals(messages[0].contactName, "Cliente Teste");
  assertEquals(messages[0].businessAccountId, "waba-1");
  assertEquals(messages[0].portalReference?.externalCode, "1377664");
  assertEquals(messages[0].parseStatus, "matched_candidate");
  assert(messages[0].receivedAt?.endsWith("Z"));
  assertEquals(extractInboundWhatsAppMessages(payload, "another-number"), []);
});

Deno.test("skips messages without a stable ID, phone, text, or text type", () => {
  const payload = {
    object: "whatsapp_business_account",
    entry: [
      {
        changes: [
          {
            field: "messages",
            value: {
              messaging_product: "whatsapp",
              messages: [
                {
                  from: "5561",
                  id: "image-1",
                  type: "image",
                  image: { id: "media" },
                },
                { from: "5561", type: "text", text: { body: "sem id" } },
              ],
            },
          },
        ],
      },
    ],
  };
  assertEquals(extractInboundWhatsAppMessages(payload), []);
});
