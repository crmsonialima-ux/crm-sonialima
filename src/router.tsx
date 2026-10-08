import { MutationCache, QueryCache, QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";
import { reportCrmClientError } from "./lib/audit-client";

export const getRouter = () => {
  const queryClient = new QueryClient({
    queryCache: new QueryCache({
      onError: (error, query) => {
        void reportCrmClientError(error, {
          area: "query",
          operation: `Carregar ${String(query.queryKey[0] ?? "dados")}`,
          details: { queryKey: query.queryKey },
        });
      },
    }),
    mutationCache: new MutationCache({
      onError: (error, _variables, _context, mutation) => {
        void reportCrmClientError(error, {
          area: "mutation",
          operation: `Executar ${String(mutation.options.mutationKey?.[0] ?? "alteração")}`,
          details: { mutationKey: mutation.options.mutationKey },
        });
      },
    }),
  });

  const router = createRouter({
    routeTree,
    context: { queryClient },
    scrollRestoration: true,
    defaultPreloadStaleTime: 0,
  });

  return router;
};
