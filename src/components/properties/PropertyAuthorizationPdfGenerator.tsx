import { useEffect, useState } from "react";
import { PDFDocument, rgb, StandardFonts } from "pdf-lib";
import { Download, FileText, Loader2, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { fetchPropertyAuthorization, fetchPropertyAuthorizationPdfs, reservePdfVersion, finalizePdfVersion, type Property, type PropertyAuthorizationPdf } from "@/lib/properties";
import { supabase } from "@/lib/supabase";

// Official authorization forms must be supplied by this client before generation.
const authorizationTemplateReady = false;

export function PropertyAuthorizationPdfGenerator({
  property,
}: {
  property: Property;
}) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [pdfs, setPdfs] = useState<PropertyAuthorizationPdf[]>([]);
  const [fetchingPdfs, setFetchingPdfs] = useState(true);
  const [isAuthorized, setIsAuthorized] = useState(false);

  useEffect(() => {
    let active = true;

    async function checkAuthAndFetch() {
      try {
        const { data: userData, error: userError } = await supabase.auth.getUser();
        if (userError || !userData.user) return;

        const { data: hasAccess } = await supabase.rpc("can_access_property_authorization", {
          p_property_id: property.id,
          p_user_id: userData.user.id
        });

        if (hasAccess) {
          setIsAuthorized(true);
          const fetchedPdfs = await fetchPropertyAuthorizationPdfs(property.id);
          // Only show finalized
          if (active) setPdfs(fetchedPdfs.filter(p => p.status === 'FINALIZED'));
        }
      } catch (err) {
        console.error(err);
      } finally {
        if (active) setFetchingPdfs(false);
      }
    }

    void checkAuthAndFetch();

    return () => {
      active = false;
    };
  }, [property.id]);

  const generatePdf = async () => {
    setLoading(true);
    setError("");
    try {
      const authData = await fetchPropertyAuthorization(property.id);
      if (!authData) {
        throw new Error("Dados de autorização não encontrados para este imóvel.");
      }

      const isExclusive = authData.modalidade === "Com exclusividade";
      const isNonExclusive = authData.modalidade === "Termo sem exclusividade";

      if (!isExclusive && !isNonExclusive) {
        throw new Error("Geração de PDF bloqueada: este imóvel foi cadastrado sem termo de autorização.");
      }

      // Buscar captador de forma segura, se não tiver dá erro
      const { data: capturerData, error: capturerError } = await supabase
        .rpc("get_property_capturer_details", { p_property_id: property.id });

      let capturerName = "";
      if (!capturerError && capturerData && capturerData.length > 0) {
        capturerName = capturerData[0].name || "";
      }

      if (!capturerName) {
         throw new Error("Não foi possível identificar o captador real do imóvel para a geração do documento.");
      }

      const templatePath = isExclusive
        ? "/modelo_autorizacao_2026.pdf"
        : "/modelo_autorizacao_sem_exclusividade_2026.pdf";
      const templateRes = await fetch(templatePath);
      if (!templateRes.ok) {
        throw new Error("Modelo oficial do PDF não encontrado.");
      }
      const templateBlob = await templateRes.blob();
      const existingPdfBytes = await templateBlob.arrayBuffer();

      const pdfDoc = await PDFDocument.load(existingPdfBytes);
      const font = await pdfDoc.embedFont(StandardFonts.Helvetica);

      const pages = pdfDoc.getPages();
      const firstPage = pages[0];
      const secondPage = pages[1];
      const fourthPage = pages[3] || pages[pages.length - 1]; // Fallback

      const generationDate = new Date();

      const drawAdaptiveText = (
        page: any,
        text: string,
        x: number,
        y: number,
        maxWidth: number,
        maxHeight: number,
        initialSize: number,
        minSize: number,
        maxLines: number,
        lineHeightRatio: number = 1.2
      ) => {
        if (!text) return;
        let size = initialSize;
        let lines: string[] = [];

        while (size >= minSize) {
          lines = [];
          const words = text.split(' ');
          let currentLine = '';

          for (const word of words) {
            const testLine = currentLine ? `${currentLine} ${word}` : word;
            const width = font.widthOfTextAtSize(testLine, size);
            if (width > maxWidth && currentLine) {
              lines.push(currentLine);
              currentLine = word;
            } else {
              currentLine = testLine;
            }
          }
          if (currentLine) lines.push(currentLine);

          const totalHeight = lines.length * (size * lineHeightRatio);
          if (lines.length <= maxLines && totalHeight <= maxHeight) {
            break;
          }
          size -= 0.5;
        }

        // Final draw
        let currentY = y;
        for (let i = 0; i < Math.min(lines.length, maxLines); i++) {
          page.drawText(lines[i], { x, y: currentY, size, font, color: rgb(0, 0, 0) });
          currentY -= (size * lineHeightRatio);
        }
      };

      const p1Size = 8;
      const p1MinSize = 6;

      // PAGE 1
      drawAdaptiveText(firstPage, property.title || "", 187, 639, 380, 20, p1Size, p1MinSize, 2);
      drawAdaptiveText(firstPage, authData.saldoDevedor !== null && authData.saldoDevedor !== undefined ? Number(authData.saldoDevedor).toLocaleString("pt-BR", { style: 'currency', currency: 'BRL' }) : "", 187, 616, 200, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.valorPrestacao !== null && authData.valorPrestacao !== undefined ? Number(authData.valorPrestacao).toLocaleString("pt-BR", { style: 'currency', currency: 'BRL' }) : "", 421, 616, 150, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.agenteFinanceiro || "", 187, 595, 200, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.metragem !== null && authData.metragem !== undefined ? `${authData.metragem} m²` : "", 421, 595, 150, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.valorPretendido !== null && authData.valorPretendido !== undefined ? Number(authData.valorPretendido).toLocaleString("pt-BR", { style: 'currency', currency: 'BRL' }) : "", 187, 564, 200, 15, p1Size, p1MinSize, 1);

      const iptuInfo = [authData.numeroInscricao, authData.iptu !== null && authData.iptu !== undefined ? Number(authData.iptu).toLocaleString("pt-BR", { style: 'currency', currency: 'BRL' }) : ""]
        .filter(Boolean)
        .join(" / ");
      drawAdaptiveText(firstPage, iptuInfo, 421, 564, 150, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.vagasGaragem !== null && authData.vagasGaragem !== undefined ? `${authData.vagasGaragem}` : "", 187, 543, 200, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, capturerName, 421, 543, 150, 15, p1Size, p1MinSize, 1);

      const condInfo = [authData.administradoraCondominio, authData.telefoneCondominio, authData.valorCondominio !== null && authData.valorCondominio !== undefined ? Number(authData.valorCondominio).toLocaleString("pt-BR", { style: 'currency', currency: 'BRL' }) : ""]
        .filter(Boolean)
        .join(" / ");
      drawAdaptiveText(firstPage, condInfo, 294, 522, 280, 15, p1Size, p1MinSize, 1);

      // PROP 1
      drawAdaptiveText(firstPage, authData.prop1Nome || "", 187, 479, 380, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.prop1Profissao || "", 187, 452, 200, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.prop1EstadoCivil || "", 421, 452, 150, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.prop1Cpf || "", 187, 424, 200, 15, p1Size, p1MinSize, 1);
      const prop1DocInfo = [authData.prop1CnhRg, authData.prop1OrgaoExpedidor, authData.prop1Uf].filter(Boolean).join(" / ");
      drawAdaptiveText(firstPage, prop1DocInfo, 421, 424, 150, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.prop1Nacionalidade || "", 187, 396, 200, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.prop1Telefone || "", 421, 396, 150, 15, p1Size, p1MinSize, 1);
      drawAdaptiveText(firstPage, authData.prop1Email || "", 187, 368, 380, 15, p1Size, p1MinSize, 1);

      // PROP 2
      if (authData.prop2Nome) {
        drawAdaptiveText(firstPage, authData.prop2Nome || "", 187, 340, 380, 15, p1Size, p1MinSize, 1);
        drawAdaptiveText(firstPage, authData.prop2Profissao || "", 187, 313, 200, 15, p1Size, p1MinSize, 1);
        drawAdaptiveText(firstPage, authData.prop2EstadoCivil || "", 421, 313, 150, 15, p1Size, p1MinSize, 1);
        drawAdaptiveText(firstPage, authData.prop2Cpf || "", 187, 285, 200, 15, p1Size, p1MinSize, 1);
        const prop2DocInfo = [authData.prop2CnhRg, authData.prop2OrgaoExpedidor, authData.prop2Uf].filter(Boolean).join(" / ");
        drawAdaptiveText(firstPage, prop2DocInfo, 421, 285, 150, 15, p1Size, p1MinSize, 1);
        drawAdaptiveText(firstPage, authData.prop2Nacionalidade || "", 187, 257, 200, 15, p1Size, p1MinSize, 1);
        drawAdaptiveText(firstPage, authData.prop2Telefone || "", 421, 257, 150, 15, p1Size, p1MinSize, 1);
        drawAdaptiveText(firstPage, authData.prop2Email || "", 187, 229, 380, 15, p1Size, p1MinSize, 1);
      }

      // OBS
      if (authData.observacoesCliente) {
        drawAdaptiveText(firstPage, authData.observacoesCliente, 187, 202, 380, 25, 8, 5, 2);
      }

      const numeroParaExtenso = (num: number): string => {
        if (num === 0) return "zero";
        if (num === 100) return "cem";
        const unidades = ["", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove"];
        const especiais = ["dez", "onze", "doze", "treze", "quatorze", "quinze", "dezesseis", "dezessete", "dezoito", "dezenove"];
        const dezenas = ["", "", "vinte", "trinta", "quarenta", "cinquenta", "sessenta", "setenta", "oitenta", "noventa"];
        const centenas = ["", "cento", "duzentos", "trezentos", "quatrocentos", "quinhentos", "seiscentos", "setecentos", "oitocentos", "novecentos"];
        let ext = "";
        const c = Math.floor(num / 100);
        const r = num % 100;
        const d = Math.floor(r / 10);
        const u = r % 10;
        if (c > 0) ext += centenas[c];
        if (c > 0 && r > 0) ext += " e ";
        if (d === 1) {
          ext += especiais[u];
        } else {
          if (d > 1) ext += dezenas[d];
          if (d > 1 && u > 0) ext += " e ";
          if (d !== 1 && u > 0) ext += unidades[u];
        }
        return ext;
      };
      const numeroDecimalParaExtenso = (num: number): string => {
        const [integerPart, decimalPart] = num.toFixed(2).replace(/0+$/, "").split(".");
        if (!decimalPart) return numeroParaExtenso(Number(integerPart));
        return `${numeroParaExtenso(Number(integerPart))} vírgula ${decimalPart
          .split("")
          .map((digit) => numeroParaExtenso(Number(digit)))
          .join(" ")}`;
      };

      // O modelo com exclusividade possui o placeholder '___' nessa região.
      // O modelo sem exclusividade já traz a modalidade escrita no texto original.
      if (isExclusive) {
        firstPage.drawRectangle({ x: 202.8, y: 132.0, width: 21.2, height: 14.2, color: rgb(1, 1, 1) });
        firstPage.drawText("com", { x: 204.8, y: 135.5, size: 7.9, font, color: rgb(0, 0, 0) });
      }

      if (authData.prazoClausula2 !== null && authData.prazoClausula2 !== undefined) {
        const pNum = Number(authData.prazoClausula2);
        const deadlineText = `${pNum} (${numeroParaExtenso(pNum)})`;
        const deadlineFontSize = 9.5;
        const deadlineSpace = isExclusive
          ? { x: 275.6, width: 177.4 }
          : { x: 282.2, width: 167.0 };
        // A caixa cobre somente o sublinhado de cada modelo, preservando as palavras ao redor.
        secondPage.drawRectangle({ x: deadlineSpace.x, y: 581.8, width: deadlineSpace.width, height: 16.4, color: rgb(1, 1, 1) });
        secondPage.drawText(deadlineText, {
          // Entre a posição antiga (à esquerda) e a atual (encostada em "dias"),
          // este deslocamento deixa o prazo visualmente centralizado no espaço livre.
          x: deadlineSpace.x + Math.max(0, (deadlineSpace.width - font.widthOfTextAtSize(deadlineText, deadlineFontSize)) / 2),
          y: 586.4,
          size: deadlineFontSize,
          font,
          color: rgb(0, 0, 0),
        });
      }
      if (authData.honorariosClausula4Pct !== null && authData.honorariosClausula4Pct !== undefined) {
        const hNum = Number(authData.honorariosClausula4Pct);
        const formattedPercentage = new Intl.NumberFormat("pt-BR", {
          maximumFractionDigits: 2,
        }).format(hNum);
        const percentageDescription = `${numeroDecimalParaExtenso(hNum)} por cento`;
        const percentageText = `${formattedPercentage}% (${percentageDescription})`;
        const percentageFontSize = 9.5;
        const percentageSpace = isExclusive
          ? { x: 176.8, width: 158.2 }
          : { x: 177.7, width: 123.0 };
        // A caixa cobre somente o sublinhado de cada modelo, preservando as palavras ao redor.
        secondPage.drawRectangle({ x: percentageSpace.x, y: 402.5, width: percentageSpace.width, height: 16.7, color: rgb(1, 1, 1) });
        secondPage.drawText(percentageText, {
          x: percentageSpace.x + Math.max(0, percentageSpace.width - font.widthOfTextAtSize(percentageText, percentageFontSize) - 2),
          y: 407.4,
          size: percentageFontSize,
          font,
          color: rgb(0, 0, 0),
        });
      }

      const formatterDia = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', timeZone: 'America/Sao_Paulo' });
      const formatterMes = new Intl.DateTimeFormat('pt-BR', { month: 'long', timeZone: 'America/Sao_Paulo' });
      const formatterAno = new Intl.DateTimeFormat('pt-BR', { year: 'numeric', timeZone: 'America/Sao_Paulo' });

      const dia = formatterDia.format(generationDate);
      const mes = formatterMes.format(generationDate).toLocaleLowerCase('pt-BR');
      const ano = formatterAno.format(generationDate);
      const dataFormatada = `Brasília, ${dia} de ${mes} de ${ano}.`;

      // A data fica em alturas diferentes nos dois modelos. As coordenadas abaixo
      // foram extraídas diretamente de cada PDF para preservar o alinhamento original.
      const dateLayout = isExclusive
        ? { maskX: 400.6, maskY: 595.0, maskWidth: 147.4, textX: 402.8, textY: 601.0 }
        : { maskX: 402.6, maskY: 569.6, maskWidth: 147.4, textX: 404.8, textY: 575.6 };

      fourthPage.drawRectangle({
        x: dateLayout.maskX,
        y: dateLayout.maskY,
        width: dateLayout.maskWidth,
        height: 18.5,
        color: rgb(1, 1, 1),
      });

      fourthPage.drawText(dataFormatada, { x: dateLayout.textX, y: dateLayout.textY, size: 8.2, font, color: rgb(0, 0, 0) });

      let reservation = await reservePdfVersion(property.id);

      const pdfBytes = await pdfDoc.save();
      const pdfBlob = new Blob([new Uint8Array(pdfBytes)], { type: 'application/pdf' });

      let { error: uploadError } = await supabase.storage.from("property-authorizations").upload(reservation.storage_path, pdfBlob, {
        contentType: 'application/pdf',
        upsert: false
      });

      // Se uma tentativa anterior deixou o objeto no Storage sem finalizar a
      // reserva, peça um caminho novo e tente novamente sem sobrescrever nada.
      if (uploadError?.message.toLocaleLowerCase('en-US').includes('already exists')) {
        reservation = await reservePdfVersion(property.id);
        const retry = await supabase.storage.from("property-authorizations").upload(reservation.storage_path, pdfBlob, {
          contentType: 'application/pdf',
          upsert: false
        });
        uploadError = retry.error;
      }

      if (uploadError) {
        // Uma tentativa anterior pode ter enviado o objeto e falhado apenas na chamada de finalização.
        // Nesse caso a mesma reserva é reutilizada e o backend decide com segurança se o objeto existe.
        try {
          await finalizePdfVersion(property.id, reservation.version, reservation.storage_path);
        } catch {
          throw new Error("Erro ao salvar PDF no Storage: " + uploadError.message);
        }
      } else {
        await finalizePdfVersion(property.id, reservation.version, reservation.storage_path);
      }

      const fetchedPdfs = await fetchPropertyAuthorizationPdfs(property.id);
      setPdfs(fetchedPdfs.filter(p => p.status === 'FINALIZED'));

    } catch (err) {
      setError(err instanceof Error ? err.message : "Erro ao gerar PDF.");
    } finally {
      setLoading(false);
    }
  };

  const downloadPdf = async (storagePath: string, version: number) => {
    try {
      const { data, error } = await supabase.storage.from("property-authorizations").download(storagePath);
      if (error || !data) throw new Error(error?.message || "Arquivo não encontrado.");

      const link = document.createElement('a');
      const objectUrl = URL.createObjectURL(data);
      link.href = objectUrl;
      link.download = `Autorizacao_v${version}_${property.id}.pdf`;
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(objectUrl);
    } catch (err) {
      alert("Erro ao baixar PDF: " + (err as Error).message);
    }
  };

  if (!isAuthorized) {
    return (
      <div className="p-4 rounded-xl border border-white/5 bg-black/20 text-center">
        <p className="text-sm text-muted-foreground">Você não possui acesso aos documentos de autorização deste imóvel.</p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 p-4 rounded-xl border border-white/5 bg-black/20">
        <div>
          <h4 className="text-sm font-medium text-white mb-1">Autorização de Venda</h4>
          <p className="text-xs text-muted-foreground max-w-md">
            A geração aguarda os modelos oficiais de autorização da Sônia Lima.
          </p>
        </div>

        <Button
          onClick={generatePdf}
          disabled={loading || !authorizationTemplateReady}
          className="bg-copper hover:bg-copper/90 text-white whitespace-nowrap"
        >
          {loading ? (
            <><Loader2 className="w-4 h-4 mr-2 animate-spin" /> Gerando...</>
          ) : (
            <><Plus className="w-4 h-4 mr-2" /> {authorizationTemplateReady ? "Gerar Nova Versão" : "Aguardando modelo"}</>
          )}
        </Button>
      </div>

      {error && (
        <div className="p-3 rounded-lg bg-red-500/10 border border-red-500/20 text-red-500 text-sm">
          {error}
        </div>
      )}

      {fetchingPdfs ? (
        <div className="flex items-center justify-center py-8">
          <Loader2 className="w-6 h-6 animate-spin text-copper" />
        </div>
      ) : pdfs.length > 0 ? (
        <div className="space-y-2">
          <h4 className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-3">Versões Geradas</h4>
          {pdfs.map((pdf) => (
            <div key={pdf.id} className="flex items-center justify-between p-3 rounded-lg border border-white/5 bg-white/5 hover:bg-white/10 transition-colors">
              <div className="flex items-center gap-3">
                <div className="w-8 h-8 rounded-full bg-copper/20 flex items-center justify-center">
                  <FileText className="w-4 h-4 text-copper" />
                </div>
                <div>
                  <p className="text-sm font-medium text-white">Versão {pdf.versionNumber}</p>
                  <p className="text-xs text-muted-foreground">
                    {new Date(pdf.generatedAt || new Date()).toLocaleString("pt-BR", {
                      day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "America/Sao_Paulo"
                    })}
                  </p>
                </div>
              </div>

              <Button
                variant="ghost"
                size="sm"
                onClick={() => downloadPdf(pdf.storagePath, pdf.versionNumber)}
                className="text-copper hover:text-copper/80 hover:bg-copper/10"
              >
                <Download className="w-4 h-4" />
              </Button>
            </div>
          ))}
        </div>
      ) : (
        <div className="text-center py-8 border border-dashed border-white/10 rounded-xl">
          <p className="text-sm text-muted-foreground">Nenhuma versão gerada ainda.</p>
        </div>
      )}
    </div>
  );
}
