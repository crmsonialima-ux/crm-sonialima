import { Component, lazy, Suspense, type ReactNode } from "react";

const CaptureRanking = lazy(() =>
  import("./CaptureRanking").then((module) => ({ default: module.CaptureRanking })),
);

class CaptureRankingBoundary extends Component<{ children: ReactNode }, { failed: boolean; message: string }> {
  state = { failed: false, message: "" };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error: Error) {
    console.error("Falha ao carregar ranking de captação", error);
    this.setState({ message: error.message || "Erro sem detalhes." });
  }

  render() {
    if (this.state.failed) {
      return (
        <div className="rounded-xl border border-destructive/30 bg-destructive/5 p-5 text-sm text-muted-foreground">
          Não foi possível carregar o ranking de captação: {this.state.message}
        </div>
      );
    }
    return this.props.children;
  }
}

export function CaptureRankingPanel() {
  return (
    <CaptureRankingBoundary>
      <Suspense fallback={<div className="skeleton h-72 rounded-xl" />}>
        <CaptureRanking />
      </Suspense>
    </CaptureRankingBoundary>
  );
}
