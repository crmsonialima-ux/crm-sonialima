const brokerLabels: Record<string, string> = {
  allyson: "crmallyson",
  crmallyson: "crmallyson",
  "crmsoniaallyson@gmail.com": "crmallyson",
  crmdaniel: "Daniel",
  crmderley: "Derley",
  crmthiago: "Thiago",
  crmvitor: "Vitor",
  acessocrm: "Sônia Lima",
  "unassigned-institutional@example.invalid": "Sônia Lima",
};

export function displayBrokerName(name?: string | null) {
  if (!name) return "";
  const normalized = name.trim().toLocaleLowerCase("pt-BR").replace(/\s+/g, "");
  const emailPrefix = normalized.split("@")[0];
  return brokerLabels[normalized] ?? brokerLabels[emailPrefix] ?? name;
}
