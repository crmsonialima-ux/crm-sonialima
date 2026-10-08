import { createFileRoute, Navigate } from "@tanstack/react-router";

export const Route = createFileRoute("/preenchimento-diario")({ component: Page });

function Page() {
  return <Navigate to="/vendas" replace />;
}
