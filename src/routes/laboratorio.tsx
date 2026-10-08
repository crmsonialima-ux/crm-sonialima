import { createFileRoute } from "@tanstack/react-router";
import { BellRing, FlaskConical, Play, RotateCcw, Timer } from "lucide-react";
import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

export const Route = createFileRoute("/laboratorio")({
  component: InternalLabPage,
});

function InternalLabPage() {
  const [status, setStatus] = useState("Pronto para testar.");
  const [visitAt, setVisitAt] = useState(() => Date.now() + 5 * 60_000);
  const [now, setNow] = useState(() => Date.now());
  const [startingQueueTest, setStartingQueueTest] = useState(false);
  const [queueTestMessage, setQueueTestMessage] = useState("");
  const [resettingTests, setResettingTests] = useState(false);
  const [separationTestMessage, setSeparationTestMessage] = useState("");
  const [startingSeparationTest, setStartingSeparationTest] = useState(false);
  const [separationTest, setSeparationTest] = useState<{
    sale_broker_email: string;
    rental_broker_email: string;
    sale_brokers_count: number;
    rental_brokers_count: number;
  } | null>(null);
  const [queueTest, setQueueTest] = useState<{
    status: string;
    current_index: number;
    next_deadline_at: string;
    broker_emails: string[];
  } | null>(null);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, []);

  const simulateNotification = async (kind: "start" | "follow-up" | "attendance-reminder") => {
    const title =
      kind === "start"
        ? "Hora da visita"
        : kind === "follow-up"
          ? "Como foi a visita?"
          : "Atendimento vence em 30 minutos";
    const body =
      kind === "start"
        ? "Teste: a visita com Cliente de teste começa agora."
        : kind === "follow-up"
          ? "Teste: já se passaram 2 horas. Registre como foi a visita."
          : "Teste: avance a etapa ou registre Ainda em atendimento.";
    if (!("Notification" in window)) {
      setStatus("Este navegador não oferece notificações.");
      return;
    }
    const permission =
      Notification.permission === "granted" ? "granted" : await Notification.requestPermission();
    if (permission !== "granted") {
      setStatus("Permita as notificações no navegador para testar o alerta.");
      return;
    }
    const registration = await navigator.serviceWorker?.ready;
    const options: NotificationOptions = {
      body,
      icon: "/favicon-transparent.png",
      badge: "/favicon.png",
      tag: `lab-${kind}-${Date.now()}`,
      silent: false,
      data: { url: "/leads" },
    };
    if (registration) await registration.showNotification(title, options);
    else new Notification(title, options);
    setStatus(`Notificação de teste enviada: ${title}.`);
  };

  const startQueueTest = async (leadType: "Venda" | "Aluguel") => {
    setStartingQueueTest(true);
    setQueueTestMessage("");
    const { data, error } = await supabase.rpc("start_real_assignment_test", {
      p_lead_type: leadType,
    });
    setStartingQueueTest(false);
    if (error) {
      setQueueTestMessage(error.message);
      return;
    }
    const run = Array.isArray(data) ? data[0] : data;
    setQueueTestMessage(
      `Lead real marcado como TESTE criado. A fila real de ${leadType} foi girada.`,
    );
    setQueueTest(
      run
        ? {
            status: "running",
            current_index: 0,
            next_deadline_at: run.deadline_at,
            broker_emails: run.queue_emails,
          }
        : null,
    );
  };

  const startSeparationTest = async () => {
    setStartingSeparationTest(true);
    setSeparationTestMessage("");
    const { data, error } = await supabase.rpc("start_queue_separation_test");
    setStartingSeparationTest(false);
    if (error) {
      setSeparationTestMessage(error.message);
      return;
    }
    const result = Array.isArray(data) ? data[0] : data;
    if (!result) {
      setSeparationTestMessage("Não foi possível obter as filas para o teste.");
      return;
    }
    setSeparationTest(result);
    setSeparationTestMessage(
      "Teste enviado: uma notificação de Venda e outra de Aluguel foram criadas sem alterar leads.",
    );
  };

  const resetTests = async () => {
    setResettingTests(true);
    const { data, error } = await supabase.rpc("reset_assignment_notification_tests");
    const { data: removedLeads, error: clearError } = await supabase.rpc("clear_real_lab_leads");
    setResettingTests(false);
    if (error || clearError) {
      setQueueTestMessage(
        error?.message || clearError?.message || "Não foi possível reiniciar os testes.",
      );
      return;
    }
    setQueueTest(null);
    setSeparationTest(null);
    setSeparationTestMessage("");
    setQueueTestMessage(
      `Testes reiniciados. ${Number(removedLeads ?? 0)} lead(s) de teste e ${Number(data ?? 0)} notificação(ões) foram removidos.`,
    );
  };

  const remaining = visitAt - now;
  return (
    <main className="min-h-dvh bg-background px-5 py-10 text-foreground">
      <section className="mx-auto max-w-3xl">
        <div className="flex items-center gap-3">
          <div className="grid h-11 w-11 place-items-center rounded-xl border border-copper/30 bg-copper/10 text-copper">
            <FlaskConical size={21} />
          </div>
          <div>
            <p className="text-xs uppercase tracking-[0.2em] text-muted-foreground">Área interna</p>
            <h1 className="text-2xl font-semibold">Laboratório de esteira e notificações</h1>
          </div>
        </div>

        <div className="mt-7 grid gap-4 md:grid-cols-2">
          <section className="glass rounded-2xl p-5">
            <div className="flex items-center gap-2 text-copper">
              <Timer size={17} /> Simulador de visita
            </div>
            <p className="mt-4 text-sm text-muted-foreground">Cliente de teste · Visita agendada</p>
            <p className="mt-2 font-mono text-2xl font-semibold tabular-nums">
              {remaining >= 0
                ? `Visita em ${formatTime(remaining)}`
                : `Em visita há ${formatTime(-remaining)}`}
            </p>
            <div className="mt-5 flex flex-wrap gap-2">
              <button
                onClick={() => setVisitAt(Date.now() + 5 * 60_000)}
                className="rounded-lg border border-white/10 px-3 py-2 text-sm"
              >
                Em 5 min
              </button>
              <button
                onClick={() => setVisitAt(Date.now() - 2 * 60 * 60 * 1_000)}
                className="rounded-lg border border-white/10 px-3 py-2 text-sm"
              >
                Há 2 horas
              </button>
            </div>
          </section>

          <section className="glass rounded-2xl p-5">
            <div className="flex items-center gap-2 text-copper">
              <BellRing size={17} /> Simular celular
            </div>
            <p className="mt-3 text-sm text-muted-foreground">
              Dispara uma notificação nativa neste aparelho.
            </p>
            <div className="mt-5 grid gap-2">
              <button
                onClick={() => void simulateNotification("start")}
                className="flex items-center justify-center gap-2 rounded-lg border border-white/10 px-3 py-2 text-sm"
              >
                <Play size={14} /> Testar hora da visita
              </button>
              <button
                onClick={() => void simulateNotification("follow-up")}
                className="flex items-center justify-center gap-2 rounded-lg bg-copper px-3 py-2 text-sm font-medium text-white"
              >
                <BellRing size={14} /> Testar “Como foi a visita?”
              </button>
              <button
                onClick={() => void simulateNotification("attendance-reminder")}
                className="flex items-center justify-center gap-2 rounded-lg border border-amber-300/30 px-3 py-2 text-sm text-amber-200"
              >
                <BellRing size={14} /> Testar lembrete de 30 min
              </button>
            </div>
          </section>
        </div>
        {
          <section className="glass mt-4 rounded-2xl p-5">
            <div className="flex items-center gap-2 text-copper">
              <FlaskConical size={17} /> Teste real de distribuição e notificações
            </div>
            <p className="mt-2 text-sm text-muted-foreground">
              Cria um lead real identificado como TESTE e usa a fila real de Venda. O primeiro
              corretor recebe 20 minutos; os demais recebem 10 minutos. Se ninguém aceitar, a fila
              percorre os corretores uma segunda vez antes de ficar esgotada.
            </p>
            <button
              onClick={() => void resetTests()}
              disabled={resettingTests}
              className="mt-4 inline-flex items-center gap-1.5 rounded-lg border border-white/10 px-3 py-2 text-xs text-muted-foreground transition hover:border-copper/40 hover:text-copper disabled:opacity-60"
            >
              <RotateCcw size={14} className={resettingTests ? "animate-spin" : ""} />
              {resettingTests ? "Zerando…" : "Reiniciar testes"}
            </button>
            {queueTest ? (
              <div className="mt-4 rounded-xl border border-white/10 bg-white/[0.03] p-3 text-sm">
                <p className="font-medium text-foreground">Teste em andamento</p>
                <p className="mt-1 text-muted-foreground">
                  Próximo avanço: {new Date(queueTest.next_deadline_at).toLocaleString("pt-BR")} ·{" "}
                  {formatTime(Math.max(0, new Date(queueTest.next_deadline_at).getTime() - now))}
                </p>
                <ol className="mt-3 space-y-1 text-xs text-muted-foreground">
                  {queueTest.broker_emails.map((email, index) => (
                    <li
                      key={email}
                      className={index === queueTest.current_index ? "text-copper" : ""}
                    >
                      {index + 1}. {email}
                      {index === 0 ? " · 20 min" : " · 10 min"}
                    </li>
                  ))}
                </ol>
                <div className="mt-4 border-t border-white/10 pt-3 text-xs text-muted-foreground">
                  <p>Fila simulada apos este recebimento (a fila real nao e alterada):</p>
                  <p className="mt-1 text-copper">
                    {[...queueTest.broker_emails.slice(1), queueTest.broker_emails[0]].join(
                      "  →  ",
                    )}
                  </p>
                </div>
              </div>
            ) : (
              <div className="mt-4 flex flex-wrap gap-2">
                <button
                  onClick={() => void startQueueTest("Venda")}
                  disabled={startingQueueTest}
                  className="rounded-lg bg-copper px-4 py-2.5 text-sm font-medium text-white disabled:opacity-60"
                >
                  {startingQueueTest ? "Iniciando…" : "Testar esteira real de Venda"}
                </button>
                <button
                  onClick={() => void startQueueTest("Aluguel")}
                  disabled={startingQueueTest}
                  className="rounded-lg border border-copper/40 px-4 py-2.5 text-sm font-medium text-copper disabled:opacity-60"
                >
                  Testar esteira real de Aluguel
                </button>
              </div>
            )}
            {queueTestMessage && (
              <p className="mt-3 text-sm text-muted-foreground">{queueTestMessage}</p>
            )}
          </section>
        }
        <section className="glass mt-4 rounded-2xl p-5">
          <div className="flex items-center gap-2 text-copper">
            <FlaskConical size={17} /> Teste de separação: Venda e Aluguel
          </div>
          <p className="mt-2 text-sm text-muted-foreground">
            Confere os próximos corretores de cada esteira e cria dois alertas de teste separados.
            Não cadastra, transfere ou altera nenhum lead.
          </p>
          {separationTest ? (
            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              <div className="rounded-xl border border-white/10 bg-white/[0.03] p-3 text-sm">
                <p className="text-muted-foreground">Próximo de Venda</p>
                <p className="mt-1 font-medium">{separationTest.sale_broker_email}</p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {separationTest.sale_brokers_count} corretor(es) disponível(is)
                </p>
              </div>
              <div className="rounded-xl border border-white/10 bg-white/[0.03] p-3 text-sm">
                <p className="text-muted-foreground">Próximo de Aluguel</p>
                <p className="mt-1 font-medium">{separationTest.rental_broker_email}</p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {separationTest.rental_brokers_count} corretor(es) disponível(is)
                </p>
              </div>
            </div>
          ) : (
            <button
              onClick={() => void startSeparationTest()}
              disabled={startingSeparationTest}
              className="mt-4 rounded-lg border border-copper/40 px-4 py-2.5 text-sm font-medium text-copper disabled:opacity-60"
            >
              {startingSeparationTest ? "Verificando filas…" : "Testar esteiras separadas"}
            </button>
          )}
          {separationTestMessage && (
            <p className="mt-3 text-sm text-muted-foreground">{separationTestMessage}</p>
          )}
        </section>
        <p className="mt-5 text-sm text-muted-foreground">{status}</p>
      </section>
    </main>
  );
}

function formatTime(milliseconds: number) {
  const total = Math.floor(milliseconds / 1_000);
  const hours = Math.floor(total / 3_600);
  const minutes = Math.floor((total % 3_600) / 60);
  const seconds = total % 60;
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}
