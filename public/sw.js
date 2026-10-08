const CACHE_PREFIX = "sonialima-crm-";
const CACHE_VERSION = "v7";
const APP_SHELL_CACHE = `${CACHE_PREFIX}shell-${CACHE_VERSION}`;
const RUNTIME_CACHE = `${CACHE_PREFIX}runtime-${CACHE_VERSION}`;
const ACTIVE_CACHES = new Set([APP_SHELL_CACHE, RUNTIME_CACHE]);
const APP_SHELL = ["/", "/site.webmanifest", "/favicon.png", "/favicon-transparent.png"];
const STATIC_DESTINATIONS = new Set(["script", "style", "image", "font", "manifest"]);

const WINDOWS_1252_BYTES = new Map([
  [0x20ac, 0x80],
  [0x201a, 0x82],
  [0x0192, 0x83],
  [0x201e, 0x84],
  [0x2026, 0x85],
  [0x2020, 0x86],
  [0x2021, 0x87],
  [0x02c6, 0x88],
  [0x2030, 0x89],
  [0x0160, 0x8a],
  [0x2039, 0x8b],
  [0x0152, 0x8c],
  [0x017d, 0x8e],
  [0x2018, 0x91],
  [0x2019, 0x92],
  [0x201c, 0x93],
  [0x201d, 0x94],
  [0x2022, 0x95],
  [0x2013, 0x96],
  [0x2014, 0x97],
  [0x02dc, 0x98],
  [0x2122, 0x99],
  [0x0161, 0x9a],
  [0x203a, 0x9b],
  [0x0153, 0x9c],
  [0x017e, 0x9e],
  [0x0178, 0x9f],
]);

function windows1252Byte(character) {
  const codePoint = character.codePointAt(0);
  if (codePoint === undefined) return null;
  if (codePoint <= 0xff) return codePoint;
  return WINDOWS_1252_BYTES.get(codePoint) ?? null;
}

function utf8SequenceLength(firstByte) {
  if (firstByte >= 0xc2 && firstByte <= 0xdf) return 2;
  if (firstByte >= 0xe0 && firstByte <= 0xef) return 3;
  if (firstByte >= 0xf0 && firstByte <= 0xf4) return 4;
  return 0;
}

function decodeMojibakePass(value) {
  const characters = Array.from(value);
  let result = "";
  let changed = false;

  for (let index = 0; index < characters.length;) {
    const firstByte = windows1252Byte(characters[index]);
    const length = firstByte === null ? 0 : utf8SequenceLength(firstByte);
    const sequence = length > 0 ? characters.slice(index, index + length) : [];
    const bytes = sequence.map(windows1252Byte);
    const validSequence =
      length > 0 &&
      sequence.length === length &&
      bytes.every(
        (byte, offset) => byte !== null && (offset === 0 || (byte >= 0x80 && byte <= 0xbf)),
      );

    if (validSequence) {
      try {
        result += new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(bytes));
        index += length;
        changed = true;
        continue;
      } catch {
        // Preserve legitimate text that only resembles a broken UTF-8 sequence.
      }
    }

    result += characters[index];
    index += 1;
  }

  return { value: result, changed };
}

function displayText(value) {
  let normalized = String(value ?? "");
  for (let pass = 0; pass < 3; pass += 1) {
    const decoded = decodeMojibakePass(normalized);
    normalized = decoded.value;
    if (!decoded.changed) break;
  }
  return normalized;
}
const AUDIT_DB_NAME = "sonialima-crm-notification-audit";
const AUDIT_STORE_NAME = "pending-events";

function openAuditDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(AUDIT_DB_NAME, 1);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(AUDIT_STORE_NAME)) {
        database.createObjectStore(AUDIT_STORE_NAME, { keyPath: "id" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function createAuditEventId(notificationId, eventType) {
  return `${notificationId}:${eventType}:${Date.now()}:${Math.random().toString(36).slice(2)}`;
}

async function storeAuditEvent(
  notificationId,
  eventType,
  happenedAt = new Date().toISOString(),
  clientEventId,
  details = {},
) {
  if (!notificationId) return;
  const database = await openAuditDb();
  const id = clientEventId || createAuditEventId(notificationId, eventType);
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(AUDIT_STORE_NAME, "readwrite");
    transaction.objectStore(AUDIT_STORE_NAME).put({
      id,
      clientEventId: id,
      notificationId,
      eventType,
      happenedAt,
      details,
    });
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
  database.close();
  return id;
}

async function pendingAuditEvents() {
  const database = await openAuditDb();
  const events = await new Promise((resolve, reject) => {
    const request = database
      .transaction(AUDIT_STORE_NAME, "readonly")
      .objectStore(AUDIT_STORE_NAME)
      .getAll();
    request.onsuccess = () => resolve(request.result || []);
    request.onerror = () => reject(request.error);
  });
  database.close();
  return events;
}

async function removeAuditEvents(ids) {
  if (!Array.isArray(ids) || !ids.length) return;
  const database = await openAuditDb();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(AUDIT_STORE_NAME, "readwrite");
    const store = transaction.objectStore(AUDIT_STORE_NAME);
    ids.forEach((id) => store.delete(id));
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
  database.close();
}

async function safelyStoreAuditEvent(...args) {
  try {
    return await storeAuditEvent(...args);
  } catch (error) {
    console.warn("[Sônia Lima CRM] Não foi possível guardar a auditoria local.", error);
    return null;
  }
}

async function safelyRemoveAuditEvents(ids) {
  try {
    await removeAuditEvents(ids);
  } catch (error) {
    console.warn("[Sônia Lima CRM] Não foi possível limpar a auditoria local.", error);
  }
}

async function sendPendingEvents(targetClient) {
  const events = await pendingAuditEvents();
  if (!events.length) return;
  if (targetClient) {
    targetClient.postMessage({ type: "crm-notification-events", events });
    return;
  }
  const windows = await clients.matchAll({ type: "window", includeUncontrolled: true });
  windows.forEach((client) => client.postMessage({ type: "crm-notification-events", events }));
}

async function safelySendPendingEvents(targetClient) {
  try {
    await sendPendingEvents(targetClient);
  } catch (error) {
    console.warn("[Sônia Lima CRM] Não foi possível sincronizar a auditoria local.", error);
  }
}

function canCache(request, response) {
  if (!response?.ok || !["basic", "default"].includes(response.type)) return false;
  if (request.headers.has("authorization") || request.headers.has("range")) return false;
  const cacheControl = response.headers.get("cache-control") ?? "";
  return !/(?:no-store|private)/i.test(cacheControl);
}

async function storeRuntimeResponse(request, response) {
  if (!canCache(request, response)) return;
  try {
    const cache = await caches.open(RUNTIME_CACHE);
    await cache.put(request, response.clone());
  } catch (error) {
    console.warn("[Sônia Lima CRM] O recurso foi carregado, mas não entrou no cache.", error);
  }
}

async function handleNavigationRequest(request) {
  try {
    const response = await fetch(request);
    await storeRuntimeResponse(request, response);
    return response;
  } catch {
    const cachedPage = await caches.match(request, { ignoreSearch: true });
    if (cachedPage) return cachedPage;
    const appShell = await caches.match("/");
    if (appShell) return appShell;
    return new Response(
      '<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Sônia Lima CRM</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#171211;color:#fff;font:16px system-ui}main{max-width:28rem;padding:2rem;text-align:center}p{color:#c8bfba}</style><main><h1>Você está sem conexão</h1><p>Reconecte-se à internet e abra novamente o Sônia Lima CRM.</p></main></html>',
      { status: 503, headers: { "content-type": "text/html; charset=utf-8" } },
    );
  }
}

async function handleStaticRequest(request) {
  try {
    const response = await fetch(request);
    await storeRuntimeResponse(request, response);
    return response;
  } catch {
    return (await caches.match(request)) ?? Response.error();
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(APP_SHELL_CACHE);
      await Promise.allSettled(
        APP_SHELL.map((url) => cache.add(new Request(url, { cache: "reload" }))),
      );
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => key.startsWith(CACHE_PREFIX) && !ACTIVE_CACHES.has(key))
            .map((key) => caches.delete(key)),
        ),
      ),
  );
  event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  if (event.request.mode === "navigate") {
    event.respondWith(handleNavigationRequest(event.request));
    return;
  }

  if (url.pathname === "/sw.js") return;
  if (STATIC_DESTINATIONS.has(event.request.destination)) {
    event.respondWith(handleStaticRequest(event.request));
  }
});

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data?.json?.() ?? {};
  } catch {
    payload = {
      title: "Sônia Lima CRM",
      body: "Uma notificação foi recebida, mas os dados estavam inválidos.",
    };
  }
  const isLead = payload.kind === "lead_assignment";
  const title = displayText(payload.title || "Sônia Lima CRM");
  const options = {
    body: displayText(payload.body || "Você tem uma nova atualização."),
    icon: "/favicon-transparent.png",
    badge: "/favicon.png",
    tag: payload.tag || "sonialima-update",
    renotify: true,
    silent: false,
    requireInteraction: true,
    vibrate: isLead ? [500, 250, 500, 250, 500, 250, 500, 250, 500] : [200, 100, 200],
    sound: isLead ? "/lead-notification.mp3" : "/notification.mp3",
    data: {
      url: payload.url || "/leads",
      notificationId: payload.notificationId || payload.tag || null,
      kind: payload.kind || null,
    },
  };
  event.waitUntil(
    (async () => {
      try {
        await self.registration.showNotification(title, options);
        await safelyStoreAuditEvent(options.data.notificationId, "browser_presented");
      } catch (error) {
        await safelyStoreAuditEvent(
          options.data.notificationId,
          "notification_client_error",
          new Date().toISOString(),
          undefined,
          {
            operation: "show_notification",
            message: error instanceof Error ? error.message : String(error),
          },
        );
      }
      await safelySendPendingEvents();
    })(),
  );
});

function safeNotificationUrl(value) {
  try {
    const target = new URL(value || "/leads", self.location.origin);
    return target.origin === self.location.origin
      ? target
      : new URL("/leads", self.location.origin);
  } catch {
    return new URL("/leads", self.location.origin);
  }
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = event.notification.data?.url || "/leads";
  const notificationId = event.notification.data?.notificationId;
  const happenedAt = new Date().toISOString();
  const clientEventId = notificationId ? createAuditEventId(notificationId, "push_clicked") : null;
  const targetUrl = safeNotificationUrl(url);
  if (notificationId) {
    targetUrl.searchParams.set("crmNotification", notificationId);
    targetUrl.searchParams.set("crmNotificationEvent", "push_clicked");
    targetUrl.searchParams.set("crmNotificationAt", happenedAt);
    targetUrl.searchParams.set("crmNotificationClientEvent", clientEventId);
  }
  const auditTask = safelyStoreAuditEvent(
    notificationId,
    "push_clicked",
    happenedAt,
    clientEventId,
  );
  const navigationTask = (async () => {
    const windows = await clients.matchAll({ type: "window", includeUncontrolled: true });
    const existing =
      windows.find((client) => new URL(client.url).pathname === targetUrl.pathname) ?? windows[0];
    if (existing) {
      if ("navigate" in existing) {
        try {
          await existing.navigate(targetUrl.href);
        } catch (error) {
          console.warn("[Sônia Lima CRM] Não foi possível navegar a janela existente.", error);
        }
      }
      return existing.focus();
    }
    return clients.openWindow(targetUrl.href);
  })();

  event.waitUntil(
    (async () => {
      await Promise.allSettled([navigationTask, auditTask]);
      await safelySendPendingEvents();
    })(),
  );
});

self.addEventListener("notificationclose", (event) => {
  const notificationId = event.notification.data?.notificationId;
  event.waitUntil(
    (async () => {
      await safelyStoreAuditEvent(notificationId, "push_closed");
      await safelySendPendingEvents();
    })(),
  );
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "crm-notification-events:flush") {
    event.waitUntil(safelySendPendingEvents(event.source));
  }
  if (event.data?.type === "crm-notification-events:ack") {
    event.waitUntil(safelyRemoveAuditEvents(event.data.ids));
  }
});
