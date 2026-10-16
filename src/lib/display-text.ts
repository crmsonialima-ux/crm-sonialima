const WINDOWS_1252_BYTES = new Map<number, number>([
  [0x20ac, 0x80],
  [0x201a, 0x82],
  [0x0192, 0x83],
  [0x201e, 0x84],
  [0x2026, 0x85],
  [0x2020, 0x86],
  [0x2021, 0x87],
  [0x02c6, 0x88],
  [0x2030, 0x89],
  [0x0160, 0x8a],
  [0x2039, 0x8b],
  [0x0152, 0x8c],
  [0x017d, 0x8e],
  [0x2018, 0x91],
  [0x2019, 0x92],
  [0x201c, 0x93],
  [0x201d, 0x94],
  [0x2022, 0x95],
  [0x2013, 0x96],
  [0x2014, 0x97],
  [0x02dc, 0x98],
  [0x2122, 0x99],
  [0x0161, 0x9a],
  [0x203a, 0x9b],
  [0x0153, 0x9c],
  [0x017e, 0x9e],
  [0x0178, 0x9f],
]);

function windows1252Byte(character: string) {
  const codePoint = character.codePointAt(0);
  if (codePoint === undefined) return null;
  if (codePoint <= 0xff) return codePoint;
  return WINDOWS_1252_BYTES.get(codePoint) ?? null;
}

function utf8SequenceLength(firstByte: number) {
  if (firstByte >= 0xc2 && firstByte <= 0xdf) return 2;
  if (firstByte >= 0xe0 && firstByte <= 0xef) return 3;
  if (firstByte >= 0xf0 && firstByte <= 0xf4) return 4;
  return 0;
}

function decodeMojibakePass(value: string) {
  const characters = Array.from(value);
  let result = "";
  let changed = false;

  for (let index = 0; index < characters.length;) {
    const firstByte = windows1252Byte(characters[index]);
    const length = firstByte === null ? 0 : utf8SequenceLength(firstByte);
    const sequence = length > 0 ? characters.slice(index, index + length) : [];
    const bytes = sequence.map(windows1252Byte);
    const validSequence =
      length > 0 &&
      sequence.length === length &&
      bytes.every(
        (byte, offset) => byte !== null && (offset === 0 || (byte >= 0x80 && byte <= 0xbf)),
      );

    if (validSequence) {
      try {
        const decoded = new TextDecoder("utf-8", { fatal: true }).decode(
          Uint8Array.from(bytes as number[]),
        );
        result += decoded;
        index += length;
        changed = true;
        continue;
      } catch {
        // A sequencia parecia UTF-8, mas era texto legitimo. Preserve-a.
      }
    }

    result += characters[index];
    index += 1;
  }

  return { value: result, changed };
}

/** Corrige, inclusive em textos mistos, UTF-8 interpretado como Windows-1252. */
export function displayText(value?: string | null) {
  let normalized = value ?? "";
  for (let pass = 0; pass < 3; pass += 1) {
    const decoded = decodeMojibakePass(normalized);
    normalized = decoded.value;
    if (!decoded.changed) break;
  }
  const exactTranslations: Record<string, string> = {
    queued: "Na fila",
    processing: "Em processamento",
    sent: "Enviado",
    failed: "Falhou",
    pending: "Pendente",
    accepted: "Aceito",
    expired: "Expirado",
    exhausted: "Fila encerrada",
    approved: "Aprovado",
    rejected: "Rejeitado",
    insert: "Inclus\u00e3o",
    update: "Altera\u00e7\u00e3o",
    delete: "Exclus\u00e3o",
    admin: "crmallyson",
    broker: "Corretor",
    unknown: "N\u00e3o identificado",
    before: "Antes",
    after: "Depois",
    no_subscription: "Sem dispositivo cadastrado",
    invalid_subscription: "Dispositivo inv\u00e1lido",
    processed_legacy: "Processado pelo sistema anterior",
  };
  const exact = exactTranslations[normalized.trim().toLowerCase()];
  if (exact) return exact;

  if (/column reference .* is ambiguous/i.test(normalized)) {
    return "N\u00e3o foi poss\u00edvel concluir a opera\u00e7\u00e3o por uma inconsist\u00eancia interna. Tente novamente.";
  }
  if (/permission denied|not authorized|unauthorized/i.test(normalized)) {
    return "Voc\u00ea n\u00e3o tem permiss\u00e3o para realizar esta opera\u00e7\u00e3o.";
  }
  if (/duplicate key|already exists/i.test(normalized)) {
    return "Este registro j\u00e1 existe no sistema.";
  }
  if (/failed to fetch|network request failed|networkerror/i.test(normalized)) {
    return "N\u00e3o foi poss\u00edvel conectar ao sistema. Verifique a internet e tente novamente.";
  }

  return normalized
    .replace(/\bDashboard\b/gi, "Painel")
    .replace(/\bValidation\b/gi, "Valida\u00e7\u00e3o")
    .replace(/\bNotifications?\b/gi, (word) =>
      word.toLowerCase().endsWith("s") ? "Notifica\u00e7\u00f5es" : "Notifica\u00e7\u00e3o",
    )
    .replace(/\bError\b/gi, "Erro")
    .replace(/\bWarning\b/gi, "Aviso")
    .replace(/\bCreated\b/gi, "Criado")
    .replace(/\bUpdated\b/gi, "Atualizado")
    .replace(/\bDeleted\b/gi, "Exclu\u00eddo");
}
