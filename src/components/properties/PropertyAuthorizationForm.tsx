import type { ReactNode } from "react";
import type { PropertyAuthorizationInput } from "@/lib/properties";

export type AuthFormState = {
  saldoDevedor: string;
  valorPrestacao: string;
  agenteFinanceiro: string;
  metragem: string;
  valorPretendido: string;
  valorAvaliacao: string;
  iptu: string;
  numeroInscricao: string;
  vagasGaragem: string;
  administradoraCondominio: string;
  telefoneCondominio: string;
  valorCondominio: string;
  prop1Nome: string;
  prop1Profissao: string;
  prop1EstadoCivil: string;
  prop1Cpf: string;
  prop1CnhRg: string;
  prop1OrgaoExpedidor: string;
  prop1Uf: string;
  prop1Nacionalidade: string;
  prop1Telefone: string;
  prop1Email: string;
  prop2Nome: string;
  prop2Profissao: string;
  prop2EstadoCivil: string;
  prop2Cpf: string;
  prop2CnhRg: string;
  prop2OrgaoExpedidor: string;
  prop2Uf: string;
  prop2Nacionalidade: string;
  prop2Telefone: string;
  prop2Email: string;
  modalidade: "Com exclusividade" | "Termo sem exclusividade" | "Sem termo de autorização";
  observacoesCliente: string;
  prazoClausula2: string;
  honorariosClausula4Pct: string;
  regularizacaoStatus: "Regularizado" | "Não regularizado";
  escrituraStatus: "Com escritura" | "Sem escritura";
  observacoesProprietario: string;
  informacoesRelevantes: string;
};

export const initialAuthForm = (): AuthFormState => ({
  saldoDevedor: "",
  valorPrestacao: "",
  agenteFinanceiro: "",
  metragem: "",
  valorPretendido: "",
  valorAvaliacao: "",
  iptu: "",
  numeroInscricao: "",
  vagasGaragem: "",
  administradoraCondominio: "",
  telefoneCondominio: "",
  valorCondominio: "",
  prop1Nome: "",
  prop1Profissao: "",
  prop1EstadoCivil: "",
  prop1Cpf: "",
  prop1CnhRg: "",
  prop1OrgaoExpedidor: "",
  prop1Uf: "",
  prop1Nacionalidade: "",
  prop1Telefone: "",
  prop1Email: "",
  prop2Nome: "",
  prop2Profissao: "",
  prop2EstadoCivil: "",
  prop2Cpf: "",
  prop2CnhRg: "",
  prop2OrgaoExpedidor: "",
  prop2Uf: "",
  prop2Nacionalidade: "",
  prop2Telefone: "",
  prop2Email: "",
  modalidade: "Com exclusividade",
  observacoesCliente: "",
  prazoClausula2: "",
  honorariosClausula4Pct: "",
  regularizacaoStatus: "Regularizado",
  escrituraStatus: "Com escritura",
  observacoesProprietario: "",
  informacoesRelevantes: "",
});

export function PropertyAuthorizationForm({
  form,
  onChange,
  readOnly,
  requireValidations,
}: {
  form: AuthFormState;
  onChange: <K extends keyof AuthFormState>(key: K, value: AuthFormState[K]) => void;
  readOnly?: boolean;
  requireValidations?: boolean;
}) {
  const update = onChange;
  const isRequired = false;

  const hasProp2 = Boolean(
    form.prop2Nome ||
    form.prop2Profissao ||
    form.prop2EstadoCivil ||
    form.prop2Cpf ||
    form.prop2CnhRg ||
    form.prop2OrgaoExpedidor ||
    form.prop2Uf ||
    form.prop2Nacionalidade ||
    form.prop2Telefone ||
    form.prop2Email
  );
  const prop2Required = false;

  const formatCurrency = (val: string) => {
    const digits = val.replace(/\D/g, "");
    if (!digits) return "";
    const num = parseInt(digits, 10) / 100;
    return new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(num);
  };

  const formatPhone = (val: string) => {
    const digits = val.replace(/\D/g, "");
    if (!digits) return "";
    if (digits.length <= 2) return `(${digits}`;
    if (digits.length <= 6) return `(${digits.slice(0, 2)}) ${digits.slice(2)}`;
    if (digits.length <= 10) return `(${digits.slice(0, 2)}) ${digits.slice(2, 6)}-${digits.slice(6)}`;
    return `(${digits.slice(0, 2)}) ${digits.slice(2, 7)}-${digits.slice(7, 11)}`;
  };

  return (
    <div className="space-y-6">
      <div className="space-y-4">
        <h3 className="text-sm font-medium text-copper">Informações do Imóvel</h3>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Metragem (m²)" required={isRequired}>
            <input value={form.metragem} onChange={(e) => update("metragem", e.target.value.replace(/\D/g, ""))} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Vagas de garagem" required={isRequired}>
            <input value={form.vagasGaragem} onChange={(e) => update("vagasGaragem", e.target.value.replace(/\D/g, ""))} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Valor pretendido de venda" required={isRequired}>
            <input value={form.valorPretendido} onChange={(e) => update("valorPretendido", e.target.value.replace(/\D/g, "").replace(/\B(?=(\d{3})+(?!\d))/g, "."))} className={inputClass} placeholder="Ex.: 500.000" required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Valor de avaliação" required={isRequired}>
            <input value={form.valorAvaliacao} onChange={(e) => update("valorAvaliacao", e.target.value.replace(/\D/g, "").replace(/\B(?=(\d{3})+(?!\d))/g, "."))} className={inputClass} placeholder="Ex.: 450.000" required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Saldo devedor" required={isRequired}>
            <input value={form.saldoDevedor} onChange={(e) => update("saldoDevedor", e.target.value.replace(/\D/g, "").replace(/\B(?=(\d{3})+(?!\d))/g, "."))} className={inputClass} placeholder="Ex.: 50.000" required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Valor da prestação" required={isRequired}>
            <input value={form.valorPrestacao} onChange={(e) => update("valorPrestacao", e.target.value.replace(/\D/g, "").replace(/\B(?=(\d{3})+(?!\d))/g, "."))} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Agente financeiro" required={isRequired}>
            <input value={form.agenteFinanceiro} onChange={(e) => update("agenteFinanceiro", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Valor do condomínio" required={isRequired}>
            <input value={form.valorCondominio} onChange={(e) => update("valorCondominio", e.target.value.replace(/\D/g, "").replace(/\B(?=(\d{3})+(?!\d))/g, "."))} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Administradora do condomínio" required={isRequired}>
            <input value={form.administradoraCondominio} onChange={(e) => update("administradoraCondominio", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Telefone do condomínio" required={isRequired}>
            <input value={form.telefoneCondominio} onChange={(e) => update("telefoneCondominio", formatPhone(e.target.value))} className={inputClass} required={isRequired} disabled={readOnly} maxLength={15} />
          </Field>
          <Field label="IPTU" required={isRequired}>
            <input value={form.iptu} onChange={(e) => update("iptu", formatCurrency(e.target.value))} className={inputClass} placeholder="Ex.: R$ 1.250,50" required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Número da inscrição (IPTU)" required={isRequired}>
            <input value={form.numeroInscricao} onChange={(e) => update("numeroInscricao", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
        </div>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-medium text-copper">Proprietário 1</h3>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Nome" required={isRequired} className="sm:col-span-2">
            <input value={form.prop1Nome} onChange={(e) => update("prop1Nome", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Profissão" required={isRequired}>
            <input value={form.prop1Profissao} onChange={(e) => update("prop1Profissao", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Estado civil" required={isRequired}>
            <input value={form.prop1EstadoCivil} onChange={(e) => update("prop1EstadoCivil", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="CPF" required={isRequired}>
            <input value={form.prop1Cpf} onChange={(e) => update("prop1Cpf", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="CNH ou RG" required={isRequired}>
            <input value={form.prop1CnhRg} onChange={(e) => update("prop1CnhRg", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Órgão Expedidor" required={isRequired}>
            <input value={form.prop1OrgaoExpedidor} onChange={(e) => update("prop1OrgaoExpedidor", e.target.value)} className={inputClass} placeholder="Ex.: SSP" required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="UF do Documento" required={isRequired}>
            <input value={form.prop1Uf} onChange={(e) => update("prop1Uf", e.target.value)} className={inputClass} placeholder="Ex.: DF" maxLength={2} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Nacionalidade" required={isRequired}>
            <input value={form.prop1Nacionalidade} onChange={(e) => update("prop1Nacionalidade", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Telefone" required={isRequired}>
            <input value={form.prop1Telefone} onChange={(e) => update("prop1Telefone", formatPhone(e.target.value))} className={inputClass} required={isRequired} disabled={readOnly} maxLength={15} />
          </Field>
          <Field label="E-mail" required={isRequired} className="sm:col-span-2">
            <input type="email" value={form.prop1Email} onChange={(e) => update("prop1Email", e.target.value)} className={inputClass} required={isRequired} disabled={readOnly} />
          </Field>
        </div>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-medium text-copper">Proprietário 2 (Opcional)</h3>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Nome" required={prop2Required} className="sm:col-span-2">
            <input value={form.prop2Nome} onChange={(e) => update("prop2Nome", e.target.value)} className={inputClass} disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="Profissão" required={prop2Required}>
            <input value={form.prop2Profissao} onChange={(e) => update("prop2Profissao", e.target.value)} className={inputClass} disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="Estado civil" required={prop2Required}>
            <input value={form.prop2EstadoCivil} onChange={(e) => update("prop2EstadoCivil", e.target.value)} className={inputClass} disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="CPF" required={prop2Required}>
            <input value={form.prop2Cpf} onChange={(e) => update("prop2Cpf", e.target.value)} className={inputClass} disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="CNH ou RG" required={prop2Required}>
            <input value={form.prop2CnhRg} onChange={(e) => update("prop2CnhRg", e.target.value)} className={inputClass} disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="Órgão Expedidor" required={prop2Required}>
            <input value={form.prop2OrgaoExpedidor} onChange={(e) => update("prop2OrgaoExpedidor", e.target.value)} className={inputClass} placeholder="Ex.: SSP" disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="UF do Documento" required={prop2Required}>
            <input value={form.prop2Uf} onChange={(e) => update("prop2Uf", e.target.value)} className={inputClass} placeholder="Ex.: DF" maxLength={2} disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="Nacionalidade" required={prop2Required}>
            <input value={form.prop2Nacionalidade} onChange={(e) => update("prop2Nacionalidade", e.target.value)} className={inputClass} disabled={readOnly} required={prop2Required} />
          </Field>
          <Field label="Telefone" required={prop2Required}>
            <input value={form.prop2Telefone} onChange={(e) => update("prop2Telefone", formatPhone(e.target.value))} className={inputClass} disabled={readOnly} required={prop2Required} maxLength={15} />
          </Field>
          <Field label="E-mail" required={prop2Required} className="sm:col-span-2">
            <input type="email" value={form.prop2Email} onChange={(e) => update("prop2Email", e.target.value)} className={inputClass} disabled={readOnly} required={prop2Required} />
          </Field>
        </div>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-medium text-copper">Informações Contratuais</h3>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Modalidade" required={isRequired} className="sm:col-span-2">
            <select value={form.modalidade} onChange={(e) => update("modalidade", e.target.value as any)} className={inputClass} required={isRequired} disabled={readOnly}>
              <option value="Com exclusividade">Com exclusividade</option>
              <option value="Termo sem exclusividade">Termo sem exclusividade</option>
              <option value="Sem termo de autorização">Sem termo de autorização</option>
            </select>
          </Field>
          <Field label="Prazo referente à Cláusula 02" required={isRequired}>
            <input value={form.prazoClausula2} onChange={(e) => update("prazoClausula2", e.target.value.replace(/\D/g, ""))} className={inputClass} inputMode="numeric" placeholder="Ex.: 180" required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Honorários de corretagem (Cláusula 04) - %" required={isRequired}>
            <input value={form.honorariosClausula4Pct} onChange={(e) => update("honorariosClausula4Pct", e.target.value.replace(/[^\d,]/g, ""))} className={inputClass} placeholder="Ex.: 5 ou 3,5" required={isRequired} disabled={readOnly} />
          </Field>
          <Field label="Observações sobre o cliente/contratante" required={isRequired} className="sm:col-span-2">
            <textarea value={form.observacoesCliente} onChange={(e) => update("observacoesCliente", e.target.value)} className={`${inputClass} min-h-24`} required={isRequired} disabled={readOnly} />
          </Field>
        </div>
      </div>

      <div className="space-y-4">
        <h3 className="text-sm font-medium text-copper">Informações Internas</h3>
        <p className="text-xs text-muted-foreground mb-2">Essas informações não saem no PDF.</p>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Regularização" required={isRequired}>
            <select value={form.regularizacaoStatus} onChange={(e) => update("regularizacaoStatus", e.target.value as any)} className={inputClass} required={isRequired} disabled={readOnly}>
              <option value="Regularizado">Regularizado</option>
              <option value="Não regularizado">Não regularizado</option>
            </select>
          </Field>
          <Field label="Escritura" required={isRequired}>
            <select value={form.escrituraStatus} onChange={(e) => update("escrituraStatus", e.target.value as any)} className={inputClass} required={isRequired} disabled={readOnly}>
              <option value="Com escritura">Com escritura</option>
              <option value="Sem escritura">Sem escritura</option>
            </select>
          </Field>
          <Field label="Observações do Imóvel/Proprietário" className="sm:col-span-2">
            <textarea value={form.observacoesProprietario} onChange={(e) => update("observacoesProprietario", e.target.value)} className={`${inputClass} min-h-24`} disabled={readOnly} />
          </Field>
          <Field label="Informações Relevantes" className="sm:col-span-2">
            <textarea value={form.informacoesRelevantes} onChange={(e) => update("informacoesRelevantes", e.target.value)} className={`${inputClass} min-h-24`} disabled={readOnly} />
          </Field>
        </div>
      </div>
    </div>
  );
}

function Field({ label, required, className, children }: { label: string; required?: boolean; className?: string; children: ReactNode }) {
  return (
    <label className={`block text-xs text-muted-foreground ${className ?? ""}`}>
      {label}
      {required && <span className="text-copper"> *</span>}
      <span className="mt-1.5 block">{children}</span>
    </label>
  );
}

const inputClass =
  "w-full rounded-lg border border-white/10 bg-white/[0.03] px-3 py-2.5 text-sm text-foreground outline-none transition focus:border-copper/50 disabled:cursor-not-allowed disabled:opacity-70";
