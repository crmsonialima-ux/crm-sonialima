import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  Link,
  createRootRouteWithContext,
  useRouter,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";
import { useEffect, type ReactNode } from "react";

import appCss from "../styles.css?url";
import { reportLovableError } from "../lib/lovable-error-reporting";
import { AuthGate, AuthProvider, ClientAuditBridge, useAuth } from "@/components/auth/AuthProvider";
import { PwaInstallPrompt } from "@/components/pwa/PwaInstallPrompt";
import { MobileRefreshButton } from "@/components/pwa/MobileRefreshButton";
import { HorizontalDragScroll } from "@/components/ui/HorizontalDragScroll";
import { NotificationSubjectDialog } from "@/components/notifications/NotificationSubjectDialog";
import { useTheme } from "@/hooks/use-theme";
import { reportCrmClientError } from "@/lib/audit-client";

const THEME_BOOTSTRAP_SCRIPT = `
  (() => {
    const valid = (value) => value === "light" || value === "dark";
    let theme = null;
    try {
      const lastUserId = localStorage.getItem("sonialima:last-user-id");
      theme = lastUserId ? localStorage.getItem("sonialima:theme:" + lastUserId) : null;
      if (!valid(theme)) theme = localStorage.getItem("sonialima:theme");
    } catch {}
    if (!valid(theme)) {
      const match = document.cookie.match(/(?:^|;\\s*)sonialima_theme=(light|dark)(?:;|$)/);
      theme = match ? match[1] : "dark";
    }
    const root = document.documentElement;
    root.classList.toggle("light", theme === "light");
    root.classList.toggle("dark", theme !== "light");
    root.dataset.theme = theme;
    root.style.colorScheme = theme;
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", theme === "light" ? "#f7f3ed" : "#171211");
  })();
`;

function NotFoundComponent() {
  return (
    <div className="flex min-h-dvh items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-7xl font-bold text-foreground">404</h1>
        <h2 className="mt-4 text-xl font-semibold text-foreground">Página não encontrada</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          A página que você procura não existe ou foi movida.
        </p>
        <div className="mt-6">
          <Link
            to="/"
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Voltar ao início
          </Link>
        </div>
      </div>
    </div>
  );
}

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  useEffect(() => {
    reportLovableError(error, { boundary: "tanstack_root_error_component" });
    void reportCrmClientError(error, {
      area: "react",
      operation: "Falha no carregamento da página",
      details: { boundary: "tanstack_root_error_component" },
    });
  }, [error]);

  return (
    <div className="flex min-h-dvh items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="text-xl font-semibold tracking-tight text-foreground">
          Não foi possível carregar esta página
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Ocorreu uma falha inesperada. Tente carregar novamente ou volte ao início.
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => {
              router.invalidate();
              reset();
            }}
            className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Tentar novamente
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-md border border-input bg-background px-4 py-2 text-sm font-medium text-foreground transition-colors hover:bg-accent"
          >
            Voltar ao início
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      {
        name: "viewport",
        content:
          "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover, interactive-widget=resizes-content",
      },
      { name: "theme-color", content: "#171211" },
      { name: "mobile-web-app-capable", content: "yes" },
      { name: "application-name", content: "Sônia Lima CRM" },
      { name: "apple-mobile-web-app-capable", content: "yes" },
      { name: "apple-mobile-web-app-title", content: "Sônia Lima CRM" },
      { name: "apple-mobile-web-app-status-bar-style", content: "default" },
      { name: "format-detection", content: "telephone=no" },
      { title: "Sônia Lima — CRM Executivo" },
      {
        name: "description",
        content:
          "Plataforma executiva Sônia Lima — gestão premium de leads, corretores, imóveis e desempenho comercial.",
      },
      { name: "author", content: "Sônia Lima" },
      { property: "og:title", content: "Sônia Lima — CRM Executivo" },
      {
        property: "og:description",
        content:
          "Plataforma executiva Sônia Lima — gestão premium de leads, corretores, imóveis e desempenho comercial.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:site", content: "@SoniaLima" },
    ],
    links: [
      {
        rel: "stylesheet",
        href: appCss,
      },
      { rel: "icon", href: "/favicon-transparent.png", type: "image/png" },
      { rel: "manifest", href: "/site.webmanifest" },
      { rel: "apple-touch-icon", href: "/favicon.png", sizes: "192x192" },
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&display=swap",
      },
    ],
  }),
  shellComponent: RootShell,
  component: RootComponent,
  notFoundComponent: NotFoundComponent,
  errorComponent: ErrorComponent,
});

function RootShell({ children }: { children: ReactNode }) {
  return (
    <html lang="pt-BR" suppressHydrationWarning>
      <head>
        <HeadContent />
        <script dangerouslySetInnerHTML={{ __html: THEME_BOOTSTRAP_SCRIPT }} />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function RootComponent() {
  const { queryClient } = Route.useRouteContext();

  useEffect(() => {
    if (!("serviceWorker" in navigator) || !window.isSecureContext) return;
    let cancelled = false;
    void navigator.serviceWorker
      .register("/sw.js", { scope: "/", updateViaCache: "none" })
      .then((registration) => {
        if (!cancelled) void registration.update();
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        void reportCrmClientError(error, {
          area: "pwa",
          operation: "Registrar aplicativo no dispositivo",
        });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <UserThemeBridge />
        <UserZoomBridge />
        <ClientAuditBridge />
        <AuthGate>
          <Outlet />
          <NotificationSubjectDialog />
          <HorizontalDragScroll />
          <MobileRefreshButton />
          <PwaInstallPrompt />
        </AuthGate>
      </AuthProvider>
    </QueryClientProvider>
  );
}

function UserZoomBridge() {
  const { profile } = useAuth();
  useEffect(() => {
    if (profile?.email === "unassigned-institutional@example.invalid") {
      document.documentElement.style.fontSize = "135%";
    } else {
      document.documentElement.style.fontSize = "";
    }
  }, [profile?.email]);
  return null;
}

function UserThemeBridge() {
  const { profile } = useAuth();
  useTheme(profile?.id, profile?.preferredTheme);
  return null;
}
