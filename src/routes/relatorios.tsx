import { Navigate, createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/relatorios")({ component: ReportsRedirect });

function ReportsRedirect() {
  return <Navigate to="/" />;
}
