export type PortalKind = "dfimoveis" | "wimoveis";

export type PortalReference = {
  portal: PortalKind;
  origin: "DF Imóveis" | "W Imóveis";
  externalCode: string;
  matchedBy: "explicit_code" | "portal_url";
};

export type PortalParseAnalysis = {
  status: "matched_candidate" | "ignored" | "ambiguous";
  reason: string;
  reference: PortalReference | null;
};

export type InboundWhatsAppMessage = {
  messageId: string;
  phone: string;
  contactName: string;
  text: string;
  receivedAt: string | null;
  phoneNumberId: string;
  businessAccountId: string;
  portalReference: PortalReference | null;
  parseStatus: PortalParseAnalysis["status"];
  parseReason: string;
  rawPayload: Record<string, unknown>;
};

type JsonRecord = Record<string, unknown>;

const MAX_MESSAGE_LENGTH = 8_000;
const MAX_NAME_LENGTH = 160;
const MAX_ID_LENGTH = 256;
const MIN_EXTERNAL_CODE_LENGTH = 4;
const MAX_EXTERNAL_CODE_LENGTH = 20;

const DF_HOSTS = new Set(["dfimoveis.com.br"]);
const W_HOSTS = new Set(["imovelweb.com.br", "wimoveis.com.br"]);

export function isRecord(value: unknown): value is JsonRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function cleanText(value: unknown, maxLength: number): string {
  if (typeof value !== "string") return "";
  // Webhook text must drop C0/DEL controls while preserving tabs and line breaks.
  return (
    value
      // eslint-disable-next-line no-control-regex
      .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
      .trim()
      .slice(0, maxLength)
  );
}

export function normalizePhone(value: unknown): string {
  return cleanText(value, 64).replace(/\D/g, "").slice(0, 32);
}

function normalizeForMatching(value: string): string {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
}

function isOfficialHost(hostname: string, officialHosts: Set<string>): boolean {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  for (const officialHost of officialHosts) {
    if (host === officialHost || host.endsWith(`.${officialHost}`)) return true;
  }
  return false;
}

/**
 * Extracts HTTP(S) URLs without consuming Markdown delimiters. Query strings are
 * retained for URL parsing but never inspected for a property code.
 */
export function extractHttpUrls(text: string): URL[] {
  const matches = text.match(/https?:\/\/[^\s<>"'()[\]{}]+/gi) ?? [];
  const urls: URL[] = [];
  for (const match of matches) {
    const candidate = match.replace(/&amp;/gi, "&").replace(/[.,;:!?]+$/, "");
    try {
      const parsed = new URL(candidate);
      if (parsed.protocol === "http:" || parsed.protocol === "https:") {
        urls.push(parsed);
      }
    } catch {
      // Malformed URLs are deliberately ignored.
    }
  }
  return urls;
}

function validExternalCode(value: string | undefined): string | null {
  if (!value) return null;
  if (!/^\d+$/.test(value)) return null;
  if (value.length < MIN_EXTERNAL_CODE_LENGTH || value.length > MAX_EXTERNAL_CODE_LENGTH) {
    return null;
  }
  return value;
}

function referenceFromPortalUrl(url: URL): PortalReference | null {
  const pathname = url.pathname;

  if (isOfficialHost(url.hostname, W_HOSTS)) {
    // The listing identifier is only the numeric suffix immediately before
    // `.html`. Search/query parameters such as n_pg and n_pos are ignored.
    const match = pathname.match(/^\/propriedades\/[^/]*-(\d{4,20})\.html\/?$/i);
    const externalCode = validExternalCode(match?.[1]);
    if (externalCode) {
      return {
        portal: "wimoveis",
        origin: "W Imóveis",
        externalCode,
        matchedBy: "portal_url",
      };
    }
  }

  if (isOfficialHost(url.hostname, DF_HOSTS)) {
    const shortLink = pathname.match(/^\/g\/(\d{4,20})\/?$/i);
    const propertyLink = pathname.match(/^\/imovel\/[^/]*-(\d{4,20})\/?$/i);
    const externalCode = validExternalCode(shortLink?.[1] ?? propertyLink?.[1]);
    if (externalCode) {
      return {
        portal: "dfimoveis",
        origin: "DF Imóveis",
        externalCode,
        matchedBy: "portal_url",
      };
    }
  }

  return null;
}

function explicitCodes(text: string): string[] {
  const matches = text.matchAll(
    /\bc[oó]digo\s*(?:do\s+im[oó]vel\s*)?[:#-]?\s*\(?\s*(\d{4,20})\s*\)?/gi,
  );
  return Array.from(matches, (match) => validExternalCode(match[1])).filter(
    (value): value is string => Boolean(value),
  );
}

/**
 * Recognizes only portal-bound property references. Arbitrary numbers, prices,
 * phone numbers and codes in query parameters are never accepted.
 */
export function analyzePortalReference(messageText: string): PortalParseAnalysis {
  const text = cleanText(messageText, MAX_MESSAGE_LENGTH);
  if (!text) {
    return { status: "ignored", reason: "empty_message", reference: null };
  }

  const candidates: PortalReference[] = [];
  for (const url of extractHttpUrls(text)) {
    const reference = referenceFromPortalUrl(url);
    if (reference) candidates.push(reference);
  }

  const normalized = normalizeForMatching(text);
  const codes = explicitCodes(text);
  const hasDfMarker = /\bdf\s*imoveis\b/.test(normalized);
  const hasWMarker = /\bw\s*imoveis\b/.test(normalized) || /\bimovelweb\b/.test(normalized);
  if (hasDfMarker && !hasWMarker) {
    for (const code of codes) {
      candidates.push({
        portal: "dfimoveis",
        origin: "DF Imóveis",
        externalCode: code,
        matchedBy: "explicit_code",
      });
    }
  }
  if (hasWMarker && !hasDfMarker) {
    for (const code of codes) {
      candidates.push({
        portal: "wimoveis",
        origin: "W Imóveis",
        externalCode: code,
        matchedBy: "explicit_code",
      });
    }
  }

  const unique = new Map<string, PortalReference>();
  for (const candidate of candidates) {
    const key = `${candidate.portal}:${candidate.externalCode}`;
    const current = unique.get(key);
    // Prefer the structurally stronger URL match when both representations agree.
    if (!current || candidate.matchedBy === "portal_url") {
      unique.set(key, candidate);
    }
  }

  if (unique.size === 0) {
    return {
      status: "ignored",
      reason: "no_supported_portal_reference",
      reference: null,
    };
  }
  if (unique.size > 1 || (hasDfMarker && hasWMarker && codes.length > 0)) {
    return {
      status: "ambiguous",
      reason: "conflicting_portal_property_codes",
      reference: null,
    };
  }
  return {
    status: "matched_candidate",
    reason: "safe_portal_property_reference",
    reference: unique.values().next().value ?? null,
  };
}

export function parsePortalReference(messageText: string): PortalReference | null {
  return analyzePortalReference(messageText).reference;
}

function timestampToIso(value: unknown): string | null {
  const seconds =
    typeof value === "string" && /^\d{9,13}$/.test(value)
      ? Number(value)
      : typeof value === "number"
        ? value
        : Number.NaN;
  if (!Number.isFinite(seconds)) return null;
  const milliseconds = seconds > 10_000_000_000 ? seconds : seconds * 1_000;
  const date = new Date(milliseconds);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function contactForMessage(contacts: unknown, phone: string): JsonRecord | null {
  if (!Array.isArray(contacts)) return null;
  const records = contacts.filter(isRecord);
  return (
    records.find((contact) => normalizePhone(contact.wa_id) === phone) ??
    (records.length === 1 ? records[0] : null)
  );
}

function contactName(contact: JsonRecord | null): string {
  if (!contact || !isRecord(contact.profile)) return "";
  return cleanText(contact.profile.name, MAX_NAME_LENGTH);
}

/**
 * Flattens official WhatsApp Cloud API webhook entries into inbound text
 * messages. Delivery/read statuses and non-text content are ignored.
 */
export function extractInboundWhatsAppMessages(
  payload: unknown,
  expectedPhoneNumberId = "",
): InboundWhatsAppMessage[] {
  if (!isRecord(payload) || payload.object !== "whatsapp_business_account") {
    return [];
  }
  if (!Array.isArray(payload.entry)) return [];

  const result: InboundWhatsAppMessage[] = [];
  for (const entry of payload.entry) {
    if (!isRecord(entry) || !Array.isArray(entry.changes)) continue;
    const businessAccountId = cleanText(entry.id, MAX_ID_LENGTH);

    for (const change of entry.changes) {
      if (!isRecord(change) || change.field !== "messages" || !isRecord(change.value)) continue;
      const value = change.value;
      if (value.messaging_product !== "whatsapp") continue;
      const metadata = isRecord(value.metadata) ? value.metadata : {};
      const phoneNumberId = cleanText(metadata.phone_number_id, MAX_ID_LENGTH);
      if (expectedPhoneNumberId && phoneNumberId !== expectedPhoneNumberId) {
        continue;
      }
      if (!Array.isArray(value.messages)) continue;

      for (const message of value.messages) {
        if (!isRecord(message) || message.type !== "text" || !isRecord(message.text)) continue;
        const messageId = cleanText(message.id, MAX_ID_LENGTH);
        const phone = normalizePhone(message.from);
        const text = cleanText(message.text.body, MAX_MESSAGE_LENGTH);
        if (!messageId || !phone || !text) continue;

        const contact = contactForMessage(value.contacts, phone);
        const analysis = analyzePortalReference(text);
        result.push({
          messageId,
          phone,
          contactName: contactName(contact),
          text,
          receivedAt: timestampToIso(message.timestamp),
          phoneNumberId,
          businessAccountId,
          portalReference: analysis.reference,
          parseStatus: analysis.status,
          parseReason: analysis.reason,
          rawPayload: {
            entryId: businessAccountId,
            field: change.field,
            metadata,
            contact,
            message,
          },
        });
      }
    }
  }
  return result;
}
