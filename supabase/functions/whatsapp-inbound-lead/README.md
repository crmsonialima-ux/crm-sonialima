# WhatsApp inbound lead webhook

Supabase Edge Function for the official Meta/WhatsApp Cloud API webhook. It:

- answers Meta's `GET` verification challenge;
- validates every `POST` with `X-Hub-Signature-256` before parsing JSON;
- extracts inbound text messages, contact name, E.164 phone, message ID and
  timestamp;
- recognizes safe DF Imóveis and W Imóveis/Imovelweb property references;
- forwards every inbound text message to a database RPC, including messages with
  no recognized property reference so the database can audit them as ignored;
- never embeds credentials in source code.

## Required Edge Function secrets

- `WHATSAPP_WEBHOOK_VERIFY_TOKEN`: private value also entered in Meta Developers
  when registering the callback URL.
- `WHATSAPP_APP_SECRET`: App Secret from Meta Developers, used only server-side
  for HMAC validation.
- `SUPABASE_URL`: provided by Supabase.
- `SUPABASE_SERVICE_ROLE_KEY`: provided by Supabase to Edge Functions; never
  expose it to the browser.

Optional:

- `WHATSAPP_PHONE_NUMBER_ID`: when set, events for any other WhatsApp number are
  ignored.
- `WHATSAPP_INBOUND_RPC`: overrides the default RPC name
  `process_whatsapp_inbound_message`.

The expected RPC signature is:

```text
process_whatsapp_inbound_message(
  p_message_id text,
  p_phone text,
  p_contact_name text,
  p_message_text text,
  p_received_at timestamptz,
  p_portal text,
  p_external_code text,
  p_phone_number_id text,
  p_parse_status text,
  p_parse_reason text,
  p_payload jsonb
)
```

`p_parse_status` is `matched_candidate`, `ignored`, or `ambiguous`. A
conflicting set of recognized portal codes is never resolved by guessing; the
RPC receives `ambiguous` with no portal/code so it can persist and notify the
administrator.

The RPC must own idempotency and queue locking because Meta may retry a webhook
and multiple Edge Function instances can execute concurrently.

Deploy the function with JWT verification disabled: Meta cannot send a Supabase
JWT. Authenticity is enforced by the Meta HMAC signature instead.
