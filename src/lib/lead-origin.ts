const PORTAL_DECORATORS = ["whatsapp", "vrsync", "portal", "meta"] as const;

function compactOrigin(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "");
}

function isDecoratedPortalOrigin(value: string, aliases: readonly string[]) {
  return aliases.some(
    (alias) =>
      value === alias ||
      PORTAL_DECORATORS.some(
        (decorator) => value === `${alias}${decorator}` || value === `${decorator}${alias}`,
      ),
  );
}

/**
 * Converte somente identificadores conhecidos das integrações em nomes de portal.
 * Qualquer canal manual ou histórico desconhecido é devolvido sem alterações.
 */
export function canonicalLeadOrigin(value?: string | null) {
  const original = value?.trim();
  if (!original) return undefined;

  const compact = compactOrigin(original);
  if (isDecoratedPortalOrigin(compact, ["dfimoveis", "dfimaveis"])) {
    return "DF Imóveis";
  }
  if (
    isDecoratedPortalOrigin(compact, ["wimoveis", "wimaveis", "imovelweb"]) ||
    compact === "grupoolxwimoveis" ||
    compact === "grupoolxwimaveis"
  ) {
    return "W Imóveis";
  }

  return original;
}
